import AppKit
import CommonCrypto
import Darwin
import Foundation
import LocalAuthentication
import Security
import SQLite3
import Sparkle

private struct CommandResult {
    let status: Int32
    let output: String
}

private struct AuthState {
    let connected: Bool
    let label: String
}

private func applicationMenu() -> NSMenu {
    let main = NSMenu()
    let editItem = NSMenuItem(title: "Édition", action: nil, keyEquivalent: "")
    let edit = NSMenu(title: "Édition")
    edit.addItem(withTitle: "Couper", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copier", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Coller", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Tout sélectionner", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit
    main.addItem(editItem)
    return main
}

private struct ClaudeDesktopCredential {
    let accessToken: String
    let expiresAt: Date
}

private enum ClaudeDesktopError: LocalizedError {
    case unavailable
    case keychain(OSStatus)
    case invalidData
    case noAccount
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Les données de connexion de Claude Desktop sont introuvables."
        case .keychain(let status):
            return status == errSecInteractionNotAllowed
                ? "L’accès au trousseau doit être autorisé de nouveau."
                : "Le trousseau a refusé l’accès à Claude Safe Storage (\(status))."
        case .invalidData:
            return "Les données de connexion de Claude Desktop ne sont pas reconnues."
        case .noAccount:
            return "Aucun compte Claude Desktop actif avec un jeton valide n’a été trouvé."
        case .http(let status):
            return "Anthropic a refusé la lecture des quotas (HTTP \(status))."
        }
    }
}

private var claudeDesktopDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Claude")
}

private var claudeDesktopConfigURL: URL {
    claudeDesktopDirectory.appendingPathComponent("config.json")
}

private var claudeDesktopCookieURLs: [URL] {
    ["Cookies", "Network/Cookies"].map(claudeDesktopDirectory.appendingPathComponent)
}

private func claudeDesktopHasCredentialMaterial() -> Bool {
    guard
        let data = try? Data(contentsOf: claudeDesktopConfigURL),
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        root["oauth:tokenCache"] is String || root["oauth:tokenCacheV2"] is String
    else { return false }
    return claudeDesktopCookieURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
}

private func claudeSafeStorageKey(allowPrompt: Bool) throws -> Data {
    let context = LAContext()
    context.interactionNotAllowed = !allowPrompt
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Safe Storage",
        kSecAttrAccount as String: "Claude Key",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationContext as String: context,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else {
        throw ClaudeDesktopError.keychain(status)
    }
    return data
}

private func claudeDesktopKey(from password: Data) throws -> Data {
    let salt = Data("saltysalt".utf8)
    var key = Data(count: kCCKeySizeAES128)
    let keyCount = key.count
    let status = key.withUnsafeMutableBytes { keyBytes in
        password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress,
                    password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    keyBytes.bindMemory(to: UInt8.self).baseAddress,
                    keyCount
                )
            }
        }
    }
    guard status == kCCSuccess else { throw ClaudeDesktopError.invalidData }
    return key
}

private func decryptClaudeDesktop(_ encrypted: Data, key: Data) throws -> Data {
    guard encrypted.starts(with: Data("v10".utf8)) else {
        throw ClaudeDesktopError.invalidData
    }
    let payload = encrypted.dropFirst(3)
    let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    var output = Data(count: payload.count + kCCBlockSizeAES128)
    var outputLength = 0
    let capacity = output.count
    let status = output.withUnsafeMutableBytes { outputBytes in
        payload.withUnsafeBytes { payloadBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        key.count,
                        ivBytes.baseAddress,
                        payloadBytes.baseAddress,
                        payload.count,
                        outputBytes.baseAddress,
                        capacity,
                        &outputLength
                    )
                }
            }
        }
    }
    guard status == kCCSuccess else { throw ClaudeDesktopError.invalidData }
    output.count = outputLength
    return output
}

private func sha256(_ data: Data) -> Data {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { bytes in
        _ = CC_SHA256(bytes.baseAddress, CC_LONG(bytes.count), &digest)
    }
    return Data(digest)
}

private func activeClaudeDesktopOrganization(key: Data) -> String? {
    for url in claudeDesktopCookieURLs where FileManager.default.fileExists(atPath: url.path) {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            continue
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)
        let sql = "SELECT host_key, value, encrypted_value FROM cookies WHERE name='lastActiveOrg' AND host_key IN ('.claude.ai','claude.ai') ORDER BY last_update_utc DESC LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            continue
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { continue }
        let host = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "claude.ai"
        if
            let text = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
            UUID(uuidString: text) != nil
        {
            return text.lowercased()
        }
        guard let bytes = sqlite3_column_blob(statement, 2) else { continue }
        let encrypted = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 2)))
        guard let decrypted = try? decryptClaudeDesktop(encrypted, key: key) else { continue }
        let prefix = sha256(Data(host.utf8))
        guard
            decrypted.starts(with: prefix),
            let text = String(data: decrypted.dropFirst(prefix.count), encoding: .utf8),
            UUID(uuidString: text) != nil
        else { continue }
        return text.lowercased()
    }
    return nil
}

private func decodedClaudeDesktopCache(_ value: Any?, key: Data) -> [String: Any]? {
    guard
        let encoded = value as? String,
        let encrypted = Data(base64Encoded: encoded),
        let decrypted = try? decryptClaudeDesktop(encrypted, key: key)
    else { return nil }
    return try? JSONSerialization.jsonObject(with: decrypted) as? [String: Any]
}

private func bestClaudeDesktopCredential(
    in cache: [String: Any]?, organization: String,
    now: Date = Date()
) -> ClaudeDesktopCredential? {
    guard let cache else { return nil }
    let marker = ":https://api.anthropic.com:"
    let minimumExpiry = now.addingTimeInterval(120).timeIntervalSince1970 * 1000
    var candidates: [(rank: Int, value: ClaudeDesktopCredential)] = []
    for (cacheKey, raw) in cache {
        guard
            cacheKey.lowercased().contains(organization),
            let markerRange = cacheKey.range(of: marker),
            let entry = raw as? [String: Any],
            let token = entry["token"] as? String,
            !token.isEmpty,
            let expiry = (entry["expiresAt"] as? NSNumber)?.doubleValue,
            expiry > minimumExpiry
        else { continue }
        let scopes = cacheKey[markerRange.upperBound...]
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard scopes.contains("user:profile") else { continue }
        let clientID = String(cacheKey[..<markerRange.lowerBound].split(separator: ":").first ?? "")
        let inference = scopes.contains("user:inference")
        let production = clientID == "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        candidates.append((
            (production && inference ? 100 : 0) + (inference ? 10 : 0) + scopes.count,
            ClaudeDesktopCredential(
                accessToken: token,
                expiresAt: Date(timeIntervalSince1970: expiry / 1000)
            )
        ))
    }
    return candidates.max { $0.rank < $1.rank }?.value
}

private func loadClaudeDesktopCredential(allowPrompt: Bool) throws -> ClaudeDesktopCredential {
    guard
        claudeDesktopHasCredentialMaterial(),
        let configData = try? Data(contentsOf: claudeDesktopConfigURL),
        let root = try? JSONSerialization.jsonObject(with: configData) as? [String: Any]
    else { throw ClaudeDesktopError.unavailable }
    let password = try claudeSafeStorageKey(allowPrompt: allowPrompt)
    let key = try claudeDesktopKey(from: password)
    guard let organization = activeClaudeDesktopOrganization(key: key) else {
        throw ClaudeDesktopError.noAccount
    }
    let v2 = decodedClaudeDesktopCache(root["oauth:tokenCacheV2"], key: key)
    let v1 = decodedClaudeDesktopCache(root["oauth:tokenCache"], key: key)
    guard
        let credential = bestClaudeDesktopCredential(in: v2, organization: organization)
            ?? bestClaudeDesktopCredential(in: v1, organization: organization)
    else { throw ClaudeDesktopError.noAccount }
    return credential
}

private func epoch(fromISO8601 value: Any?) -> Int? {
    guard let value = value as? String, !value.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    return date.map { Int($0.timeIntervalSince1970) }
}

private func claudeDesktopWindow(_ value: Any?) -> [String: Any] {
    guard
        let value = value as? [String: Any],
        let utilization = (value["utilization"] as? NSNumber)?.doubleValue
    else { return ["used_percent": NSNull(), "resets_at": NSNull()] }
    return [
        "used_percent": max(0, min(100, Int(utilization))),
        "resets_at": epoch(fromISO8601: value["resets_at"]) ?? NSNull(),
    ]
}

private func claudePlanName(from root: [String: Any]) -> String? {
    let organization = root["organization"] as? [String: Any]
    let tier = (organization?["rate_limit_tier"] as? String)?.lowercased()
        ?? (root["rate_limit_tier"] as? String)?.lowercased()
    let multiplier = ["20x", "5x"].first { tier?.hasSuffix("_\($0)") == true }
    let stated = (organization?["subscription_type"] as? String)
        ?? (root["subscription_type"] as? String)
        ?? (organization?["organization_type"] as? String)
    let lower = stated?.lowercased() ?? tier
    guard let lower else { return nil }
    let base = lower.contains("max") ? "Max"
        : lower.contains("team") ? "Team"
        : lower.contains("enterprise") ? "Enterprise"
        : lower.contains("pro") ? "Pro"
        : lower.contains("free") ? "Free"
        : lower.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.capitalized }.joined(separator: " ")
    return multiplier.map { "\(base) \($0.uppercased())" } ?? base
}

private func claudeDesktopQuotaSnapshot(from data: Data, plan: String? = nil) -> [String: Any]? {
    guard let source = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    var value: [String: Any] = [
        "updated_at": Int(Date().timeIntervalSince1970),
        "source": "claude-desktop",
        "five_hour": claudeDesktopWindow(source["five_hour"]),
        "weekly": claudeDesktopWindow(source["seven_day"]),
        "fable_weekly": claudeDesktopWindow(source["seven_day_fable"]),
    ]
    if let plan = claudePlanName(from: source) ?? plan { value["plan"] = plan }
    let windows = ["five_hour", "weekly", "fable_weekly"]
    guard windows.contains(where: {
        (value[$0] as? [String: Any])?["used_percent"] is Int
    }) else { return nil }
    return value
}

private struct QuotaWindow {
    let usedPercent: Int?
    let resetsAt: Int?

    var remainingPercent: Int? {
        usedPercent.map { max(0, min(100, 100 - $0)) }
    }
}

private struct ProviderQuotas {
    let status: String
    let plan: String?
    let fiveHour: QuotaWindow
    let weekly: QuotaWindow
    let fableWeekly: QuotaWindow
    let bankedResets: Int?
}

private struct QuotaSnapshot {
    let codex: ProviderQuotas
    let claude: ProviderQuotas
    let refreshedAt: Int?
    let apiAddress: String
    let displayCodex: Bool?
    let displayClaude: Bool?
}

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func executable(named name: String) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var candidates = [
        name == "codex" ? "/Applications/Codex.app/Contents/Resources/codex" : "",
        name == "codex" ? "\(home)/Applications/Codex.app/Contents/Resources/codex" : "",
        "\(home)/.local/bin/\(name)",
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/usr/bin/\(name)",
    ]
    if name == "codex", let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
        candidates.insert(app.appendingPathComponent("Contents/Resources/codex").path, at: 0)
    }
    if let direct = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
        return direct
    }
    let resolved = run("/bin/zsh", ["-lic", "command -v -- \(shellQuoted(name))"])
    return resolved.output.split(separator: "\n").reversed()
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: FileManager.default.isExecutableFile(atPath:))
}

private func run(_ path: String?, _ arguments: [String]) -> CommandResult {
    guard let path else { return CommandResult(status: 127, output: "") }
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    } catch {
        return CommandResult(status: 126, output: error.localizedDescription)
    }
}

private func claudeState(from result: CommandResult) -> AuthState {
    guard
        result.status == 0,
        let data = result.output.data(using: .utf8),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["loggedIn"] as? Bool == true,
        value["authMethod"] as? String == "claude.ai"
    else {
        return AuthState(connected: false, label: "connexion requise")
    }
    let plan = (value["subscriptionType"] as? String)?.capitalized ?? "abonnement"
    return AuthState(connected: true, label: "\(plan) connecté")
}

private func codexState(from result: CommandResult) -> AuthState {
    let connected = result.status == 0 && result.output.localizedCaseInsensitiveContains("ChatGPT")
    return AuthState(
        connected: connected,
        label: connected ? "ChatGPT connecté" : "connexion requise"
    )
}

private func autoLaunchEnabled(from result: CommandResult, label: String) -> Bool? {
    guard result.status == 0 else { return nil }
    return !result.output.contains("\"\(label)\" => disabled")
}

private func launchdPID(from output: String) -> pid_t? {
    for line in output.split(separator: "\n") {
        let fields = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
        if fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces) == "pid" {
            return Int32(fields[1].trimmingCharacters(in: .whitespaces))
        }
    }
    return nil
}

private func quotaWindow(_ value: Any?) -> QuotaWindow {
    let value = value as? [String: Any]
    return QuotaWindow(
        usedPercent: value?["used_percent"] as? Int,
        resetsAt: value?["resets_at"] as? Int
    )
}

private func providerQuotas(_ value: Any?) -> ProviderQuotas? {
    guard let value = value as? [String: Any] else { return nil }
    let resets = value["banked_resets"] as? [String: Any]
    return ProviderQuotas(
        status: value["status"] as? String ?? "error",
        plan: value["plan"] as? String,
        fiveHour: quotaWindow(value["five_hour"]),
        weekly: quotaWindow(value["weekly"]),
        fableWeekly: quotaWindow(value["fable_weekly"]),
        bankedResets: resets?["available_count"] as? Int
    )
}

private func quotaSnapshot(from data: Data) -> QuotaSnapshot? {
    guard
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let providers = root["providers"] as? [String: Any],
        let codex = providerQuotas(providers["codex"]),
        let claude = providerQuotas(providers["claude"])
    else { return nil }
    let refresh = root["refresh"] as? [String: Any]
    let api = root["api"] as? [String: Any]
    let display = root["display"] as? [String: Any]
    return QuotaSnapshot(
        codex: codex,
        claude: claude,
        refreshedAt: refresh?["completed_at"] as? Int,
        apiAddress: api?["address"] as? String ?? "port 8788",
        displayCodex: display?["codex"] as? Bool,
        displayClaude: display?["claude"] as? Bool
    )
}

private func remainingText(_ window: QuotaWindow) -> String {
    window.remainingPercent.map { "\($0)%" } ?? "—%"
}

private func compactRemainingText(_ window: QuotaWindow, percent: Bool) -> String {
    guard let remaining = window.remainingPercent else { return percent ? "—%" : "—" }
    return "\(remaining)\(percent ? "%" : "")"
}

private enum StatusDisplayMode: String {
    case compact
    case codex
    case claude
}

private let showCodexPreference = "display.showCodex"
private let showClaudePreference = "display.showClaude"
private let persistentWindowPreference = "display.persistentWindow"
private let alwaysOnTopPreference = "display.alwaysOnTop"
private let statusDisplayPreference = "display.statusMode"

private func expectedRemainingPercent(
    _ window: QuotaWindow,
    durationSeconds: Int,
    now: Int = Int(Date().timeIntervalSince1970)
) -> CGFloat? {
    guard let reset = window.resetsAt, durationSeconds > 0 else { return nil }
    return max(0, min(100, CGFloat(reset - now) / CGFloat(durationSeconds) * 100))
}

private func resetCountdown(
    _ window: QuotaWindow,
    now: Int = Int(Date().timeIntervalSince1970)
) -> String {
    guard let reset = window.resetsAt, reset > now else { return "—" }
    let seconds = reset - now
    let days = seconds / 86_400
    let hours = seconds % 86_400 / 3_600
    let minutes = seconds % 3_600 / 60
    if days > 0 { return "\(days)j \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes)m" }
    return "\(minutes)m"
}

private func statusProviderIcon(codex: Bool, warning: Bool) -> NSImage {
    let size = NSSize(width: 12, height: 10)
    var iconURLs: [URL] = []
    if codex, let bundled = Bundle.main.url(forResource: "CodexIcon", withExtension: "png") {
        iconURLs.append(bundled)
    }
    let bundleIdentifier = codex ? "com.openai.codex" : "com.anthropic.claudefordesktop"
    if let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
        iconURLs.append(application.appendingPathComponent(
            codex ? "Contents/Resources/icon-codex-dark-color.png" : "Contents/Resources/electron.icns"
        ))
    }
    for url in iconURLs {
        if let image = NSImage(contentsOf: url) { return image }
    }
    return NSImage(size: size, flipped: false) { _ in
        let color: NSColor = warning ? .systemRed : codex ? .labelColor : .systemOrange
        color.setFill()
        if codex {
            let center = NSPoint(x: 6, y: 5)
            let petals = [(0.0, 3.25), (2.8, 1.6), (2.8, -1.6), (0.0, -3.25), (-2.8, -1.6), (-2.8, 1.6)]
            for (x, y) in petals {
                NSBezierPath(ovalIn: NSRect(x: center.x + x - 1.6, y: center.y + y - 1.6, width: 3.2, height: 3.2)).fill()
            }
            NSBezierPath(ovalIn: NSRect(x: 4, y: 3, width: 4, height: 4)).fill()
        } else {
            NSRect(x: 2, y: 3, width: 8, height: 6).fill()
            NSRect(x: 0, y: 5, width: 2, height: 3).fill()
            NSRect(x: 10, y: 5, width: 2, height: 3).fill()
            NSRect(x: 3, y: 0, width: 2, height: 3).fill()
            NSRect(x: 7, y: 0, width: 2, height: 3).fill()
            NSColor.controlBackgroundColor.setFill()
            NSRect(x: 4, y: 6, width: 1, height: 1).fill()
            NSRect(x: 7, y: 6, width: 1, height: 1).fill()
        }
        return true
    }
}

@MainActor
private final class CompactStatusView: NSView {
    var snapshot: QuotaSnapshot?
    var bridgeOnline = false
    var codexConnected: Bool?
    var claudeConnected: Bool?
    var showCodex = true
    var showClaude = true
    var displayMode = StatusDisplayMode.compact

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let empty = QuotaWindow(usedPercent: nil, resetsAt: nil)
        if displayMode != .compact || showCodex != showClaude {
            let useCodex = (displayMode == .codex && showCodex) || !showClaude
            drawPercentage(
                window: useCodex ? snapshot?.codex.weekly ?? empty : snapshot?.claude.weekly ?? empty,
                providerOK: useCodex ? snapshot?.codex.status == "ok" : snapshot?.claude.status == "ok",
                codex: useCodex,
                connected: useCodex ? codexConnected : claudeConnected
            )
            return
        }
        drawProviderIcon(codex: false, connected: claudeConnected, x: 0)
        drawProviderIcon(codex: true, connected: codexConnected, x: bounds.width - 20)
        drawDivider()
        drawRow(
            window5h: snapshot?.codex.fiveHour ?? empty,
            weekly: snapshot?.codex.weekly ?? empty,
            providerOK: snapshot?.codex.status == "ok",
            x: 23,
            width: bounds.width - 46,
            y: 1
        )
        drawRow(
            window5h: snapshot?.claude.fiveHour ?? empty,
            weekly: snapshot?.claude.weekly ?? empty,
            providerOK: snapshot?.claude.status == "ok",
            x: 23,
            width: bounds.width - 46,
            y: 11
        )
    }

    private func drawPercentage(window: QuotaWindow, providerOK: Bool, codex: Bool, connected: Bool?) {
        drawProviderIcon(codex: codex, connected: connected, x: 5)
        let value = NSMutableAttributedString()
        appendQuota(window, providerOK: providerOK, percent: true, to: value)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        value.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: value.length))
        value.draw(in: NSRect(x: 27, y: 5, width: bounds.width - 30, height: 14))
    }

    private func drawProviderIcon(codex: Bool, connected: Bool?, x: CGFloat) {
        statusProviderIcon(codex: codex, warning: connected == false)
            .draw(in: NSRect(x: x, y: 1, width: 20, height: 20))
        if connected == false {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 15, y: 16, width: 5, height: 5)).fill()
        }
    }

    private func drawDivider() {
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 20, y: 4.5))
        divider.line(to: NSPoint(x: 26, y: 10.5))
        divider.line(to: NSPoint(x: bounds.width - 26, y: 10.5))
        divider.line(to: NSPoint(x: bounds.width - 20, y: 17.5))
        divider.lineWidth = 1.25
        divider.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.78).setStroke()
        divider.stroke()
    }

    private func drawRow(
        window5h: QuotaWindow,
        weekly: QuotaWindow,
        providerOK: Bool,
        x: CGFloat,
        width: CGFloat,
        y: CGFloat
    ) {
        let text = NSMutableAttributedString()
        appendQuota(window5h, providerOK: providerOK, percent: false, to: text)
        text.append(NSAttributedString(
            string: "/",
            attributes: textAttributes(color: .secondaryLabelColor)
        ))
        appendQuota(weekly, providerOK: providerOK, percent: true, to: text)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        text.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: text.length))
        text.draw(in: NSRect(x: x, y: y - 1, width: width, height: 12))
    }

    private func appendQuota(
        _ window: QuotaWindow,
        providerOK: Bool,
        percent: Bool,
        to text: NSMutableAttributedString
    ) {
        let remaining = window.remainingPercent
        let color: NSColor
        if !bridgeOnline || remaining == nil {
            color = .secondaryLabelColor
        } else if !providerOK || remaining! <= 50 {
            color = remaining! <= 20 ? .systemRed : .systemOrange
        } else {
            color = .systemGreen
        }
        text.append(NSAttributedString(
            string: compactRemainingText(window, percent: percent),
            attributes: textAttributes(color: color)
        ))
    }

    private func textAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .bold),
            .foregroundColor: color,
        ]
    }
}

private func dateText(_ timestamp: Int?, timeOnly: Bool = false) -> String {
    guard let timestamp else { return "—" }
    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "fr_CA")
    if timeOnly && Calendar.current.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
        return "aujourd’hui à \(formatter.string(from: date))"
    }
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func bridgeBaseURL(from value: String?) -> URL? {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let candidate = value.isEmpty ? "http://127.0.0.1:8788" : value.contains("://") ? value : "http://\(value)"
    guard
        let components = URLComponents(string: candidate),
        ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
        components.host != nil,
        components.user == nil,
        components.password == nil,
        components.query == nil,
        components.fragment == nil,
        components.path.isEmpty || components.path == "/"
    else { return nil }
    return components.url
}

private func isLocalBridge(_ url: URL) -> Bool {
    url.host == "127.0.0.1" || url.host == "localhost" || url.host == "::1"
}

private func dashboardPanelRects(
    in screen: NSRect,
    showCodex requestedCodex: Bool,
    showClaude requestedClaude: Bool
) -> (codex: NSRect?, claude: NSRect?) {
    let showCodex = requestedCodex || !requestedClaude
    let showClaude = requestedClaude || !requestedCodex
    let both = showCodex && showClaude
    let gap: CGFloat = 8
    let width = both ? (screen.width - 24) / 2 : screen.width - 16
    let firstX = screen.minX + 8
    return (
        showCodex ? NSRect(x: firstX, y: screen.minY + 8, width: width, height: 158) : nil,
        showClaude ? NSRect(x: both ? firstX + width + gap : firstX, y: screen.minY + 8, width: width, height: 158) : nil
    )
}

@MainActor
private final class QuotaDashboardView: NSView {
    private let screenColor = NSColor(srgbRed: 7 / 255, green: 10 / 255, blue: 18 / 255, alpha: 1)
    private let cellColor = NSColor(srgbRed: 19 / 255, green: 27 / 255, blue: 43 / 255, alpha: 1)
    private let trackColor = NSColor(srgbRed: 35 / 255, green: 46 / 255, blue: 66 / 255, alpha: 1)
    private let textColor = NSColor(srgbRed: 230 / 255, green: 237 / 255, blue: 245 / 255, alpha: 1)
    private let mutedColor = NSColor(srgbRed: 124 / 255, green: 141 / 255, blue: 164 / 255, alpha: 1)
    private let codexColor = NSColor(srgbRed: 56 / 255, green: 189 / 255, blue: 248 / 255, alpha: 1)
    private let claudeColor = NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
    private let greenColor = NSColor(srgbRed: 52 / 255, green: 211 / 255, blue: 153 / 255, alpha: 1)
    private let amberColor = NSColor(srgbRed: 251 / 255, green: 191 / 255, blue: 36 / 255, alpha: 1)
    private let redColor = NSColor(srgbRed: 248 / 255, green: 113 / 255, blue: 113 / 255, alpha: 1)

    var apiOnline = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(accessibilitySummary)
        }
    }
    var snapshot: QuotaSnapshot? {
        didSet {
            needsDisplay = true
            setAccessibilityValue(accessibilitySummary)
        }
    }
    var showCodex = true {
        didSet {
            needsDisplay = true
            setAccessibilityValue(accessibilitySummary)
        }
    }
    var showClaude = true {
        didSet {
            needsDisplay = true
            setAccessibilityValue(accessibilitySummary)
        }
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Quotas Codex et Claude")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var accessibilitySummary: String {
        guard let snapshot else { return "Chargement des quotas" }
        var parts: [String] = []
        if showCodex {
            parts.append("Codex, forfait \(snapshot.codex.plan ?? "inconnu"), 5 heures \(remainingText(snapshot.codex.fiveHour)), semaine \(remainingText(snapshot.codex.weekly)).")
        }
        if showClaude {
            parts.append("Claude, forfait \(snapshot.claude.plan ?? "inconnu"), 5 heures \(remainingText(snapshot.claude.fiveHour)), semaine \(remainingText(snapshot.claude.weekly)), Fable \(remainingText(snapshot.claude.fableWeekly)).")
        }
        parts.append("API \(snapshot.apiAddress), \(apiOnline ? "en ligne" : "hors ligne"). Dernière actualisation \(dateText(snapshot.refreshedAt, timeOnly: true)).")
        return parts.joined(separator: " ")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let screen = bounds.insetBy(dx: 8, dy: 6)
        screenColor.setFill()
        NSBezierPath(roundedRect: screen, xRadius: 12, yRadius: 12).fill()

        let empty = ProviderQuotas(
            status: "loading",
            plan: nil,
            fiveHour: QuotaWindow(usedPercent: nil, resetsAt: nil),
            weekly: QuotaWindow(usedPercent: nil, resetsAt: nil),
            fableWeekly: QuotaWindow(usedPercent: nil, resetsAt: nil),
            bankedResets: nil
        )
        let panels = dashboardPanelRects(in: screen, showCodex: showCodex, showClaude: showClaude)
        if let rect = panels.codex {
            drawProviderCard(
                title: "CODEX",
                provider: snapshot?.codex ?? empty,
                rect: rect,
                panelColor: NSColor(srgbRed: 8 / 255, green: 29 / 255, blue: 48 / 255, alpha: 1),
                accent: codexColor,
                codex: true,
                compactLabel: "RESETS:",
                compactWindow: nil,
                compactCount: snapshot?.codex.bankedResets
            )
        }
        if let rect = panels.claude {
            drawProviderCard(
                title: "CLAUDE",
                provider: snapshot?.claude ?? empty,
                rect: rect,
                panelColor: NSColor(srgbRed: 43 / 255, green: 24 / 255, blue: 21 / 255, alpha: 1),
                accent: claudeColor,
                codex: false,
                compactLabel: "FABLE:",
                compactWindow: snapshot?.claude.fableWeekly,
                compactCount: nil
            )
        }
        trackColor.setFill()
        NSRect(x: screen.minX + 12, y: 180, width: screen.width - 24, height: 1).fill()
        drawText(
            "Dernière actualisation · \(dateText(snapshot?.refreshedAt, timeOnly: true))",
            in: NSRect(x: screen.minX + 12, y: 185, width: screen.width - 24, height: 16),
            font: .systemFont(ofSize: 10, weight: .semibold),
            color: mutedColor,
            alignment: .center
        )
        trackColor.setFill()
        NSRect(x: screen.minX + 12, y: 208, width: screen.width - 24, height: 1).fill()
        drawAPIStatus(y: 219)
    }

    private func drawProviderCard(
        title: String,
        provider: ProviderQuotas,
        rect: NSRect,
        panelColor: NSColor,
        accent: NSColor,
        codex: Bool,
        compactLabel: String,
        compactWindow: QuotaWindow?,
        compactCount: Int?
    ) {
        panelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        accent.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 4),
            xRadius: 2,
            yRadius: 2
        ).fill()

        statusProviderIcon(codex: codex, warning: provider.status != "ok").draw(
            in: NSRect(x: rect.minX + 12, y: rect.minY + 12, width: 18, height: 18)
        )
        drawText(
            title,
            in: NSRect(x: rect.minX + 38, y: rect.minY + 10, width: 66, height: 20),
            font: .systemFont(ofSize: 14, weight: .bold),
            color: textColor
        )
        let planRect = NSRect(x: rect.maxX - 91, y: rect.minY + 11, width: 65, height: 18)
        cellColor.setFill()
        NSBezierPath(roundedRect: planRect, xRadius: 9, yRadius: 9).fill()
        drawText(
            provider.plan?.uppercased() ?? "—",
            in: planRect.insetBy(dx: 5, dy: 3),
            font: .systemFont(ofSize: 8, weight: .bold),
            color: accent,
            alignment: .center
        )

        statusColor(provider.status).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.maxX - 17, y: rect.minY + 17, width: 7, height: 7)).fill()

        let cellGap: CGFloat = 8
        let cellWidth = (rect.width - 28) / 2
        drawQuotaCell(
            label: "5 HEURES",
            window: provider.fiveHour,
            rect: NSRect(x: rect.minX + 10, y: rect.minY + 38, width: cellWidth, height: 90),
            accent: accent,
            durationSeconds: 5 * 3_600,
            segmentCount: 5
        )
        drawQuotaCell(
            label: "SEMAINE",
            window: provider.weekly,
            rect: NSRect(x: rect.minX + 10 + cellWidth + cellGap, y: rect.minY + 38, width: cellWidth, height: 90),
            accent: accent,
            durationSeconds: 7 * 86_400,
            segmentCount: 7
        )
        if let compactWindow {
            drawCompactQuota(label: compactLabel, window: compactWindow, rect: rect, accent: accent)
        } else {
            drawResetCount(label: compactLabel, count: compactCount, rect: rect, accent: accent)
        }
    }

    private func drawQuotaCell(
        label: String,
        window: QuotaWindow,
        rect: NSRect,
        accent: NSColor,
        durationSeconds: Int,
        segmentCount: Int
    ) {
        cellColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        drawText(
            label,
            in: NSRect(x: rect.minX + 8, y: rect.minY + 5, width: rect.width - 16, height: 11),
            font: .systemFont(ofSize: 7.5, weight: .bold),
            color: mutedColor
        )
        drawText(
            remainingText(window),
            in: NSRect(x: rect.minX + 8, y: rect.minY + 19, width: rect.width - 16, height: 25),
            font: .monospacedDigitSystemFont(ofSize: 18, weight: .bold),
            color: quotaColor(window.remainingPercent)
        )
        drawText(
            window.remainingPercent == nil ? "NON FOURNI" : "LIBRE",
            in: NSRect(x: rect.minX + 8, y: rect.minY + 42, width: rect.width - 16, height: 10),
            font: .systemFont(ofSize: 7, weight: .semibold),
            color: mutedColor,
            alignment: .right
        )
        drawBar(
            in: NSRect(x: rect.minX + 8, y: rect.minY + 55, width: rect.width - 16, height: 6),
            percent: window.remainingPercent,
            accent: accent
        )
        drawTimeSegments(
            in: NSRect(x: rect.minX + 8, y: rect.minY + 65, width: rect.width - 16, height: 4),
            expectedPercent: expectedRemainingPercent(window, durationSeconds: durationSeconds),
            count: segmentCount,
            accent: accent
        )
        drawText(
            "RESET \(resetCountdown(window))",
            in: NSRect(x: rect.minX + 8, y: rect.minY + 74, width: rect.width - 16, height: 10),
            font: .monospacedDigitSystemFont(ofSize: 6.5, weight: .medium),
            color: mutedColor
        )
    }

    private func drawTimeSegments(in rect: NSRect, expectedPercent: CGFloat?, count: Int, accent: NSColor) {
        let gap: CGFloat = 2
        let width = (rect.width - CGFloat(count - 1) * gap) / CGFloat(count)
        let filled = expectedPercent.map { $0 / 100 * CGFloat(count) } ?? 0
        for index in 0..<count {
            let segment = NSRect(
                x: rect.minX + CGFloat(index) * (width + gap),
                y: rect.minY,
                width: width,
                height: rect.height
            )
            trackColor.setFill()
            NSBezierPath(roundedRect: segment, xRadius: 2, yRadius: 2).fill()
            let fraction = max(0, min(1, filled - CGFloat(index)))
            guard fraction > 0 else { continue }
            accent.withAlphaComponent(0.72).setFill()
            NSBezierPath(
                roundedRect: NSRect(x: segment.minX, y: segment.minY, width: segment.width * fraction, height: segment.height),
                xRadius: 2,
                yRadius: 2
            ).fill()
        }
    }

    private func drawBar(in rect: NSRect, percent: Int?, accent: NSColor) {
        trackColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        guard let percent, percent > 0 else { return }
        let fill = NSRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(percent) / 100, height: rect.height)
        (percent > 50 ? accent : quotaColor(percent)).setFill()
        NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
    }

    private func drawCompactQuota(label: String, window: QuotaWindow, rect: NSRect, accent: NSColor) {
        let y = rect.minY + 139
        drawText(
            label,
            in: NSRect(x: rect.minX + 10, y: y, width: 42, height: 12),
            font: .systemFont(ofSize: 8, weight: .bold),
            color: mutedColor
        )
        drawBar(
            in: NSRect(x: rect.minX + 53, y: y + 2, width: rect.width - 93, height: 7),
            percent: window.remainingPercent,
            accent: accent
        )
        drawText(
            remainingText(window),
            in: NSRect(x: rect.maxX - 38, y: y - 1, width: 28, height: 13),
            font: .monospacedDigitSystemFont(ofSize: 8, weight: .bold),
            color: quotaColor(window.remainingPercent),
            alignment: .right
        )
    }

    private func drawResetCount(label: String, count: Int?, rect: NSRect, accent: NSColor) {
        let y = rect.minY + 139
        drawText(
            label,
            in: NSRect(x: rect.minX + 10, y: y, width: 46, height: 12),
            font: .systemFont(ofSize: 8, weight: .bold),
            color: mutedColor
        )
        let value = count.map(String.init) ?? "—"
        drawText(
            value,
            in: NSRect(x: rect.minX + 57, y: y - 1, width: 18, height: 13),
            font: .monospacedDigitSystemFont(ofSize: 8, weight: .bold),
            color: accent
        )
        for index in 0..<min(count ?? 0, 6) {
            accent.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: rect.minX + 79 + CGFloat(index) * 14, y: y + 2, width: 10, height: 7),
                xRadius: 3.5,
                yRadius: 3.5
            ).fill()
        }
    }

    private func quotaColor(_ percent: Int?) -> NSColor {
        guard let percent else { return mutedColor }
        if percent <= 20 { return redColor }
        if percent <= 50 { return amberColor }
        return greenColor
    }

    private func statusColor(_ status: String) -> NSColor {
        status == "ok" ? greenColor : status == "stale" ? amberColor : redColor
    }

    private func drawAPIStatus(y: CGFloat) {
        let color = apiOnline ? greenColor : redColor
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 22, y: y + 4, width: 7, height: 7)).fill()
        let line = NSMutableAttributedString(
            string: "API  ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: mutedColor,
            ]
        )
        line.append(NSAttributedString(
            string: "[\(snapshot?.apiAddress ?? "port 8788")]",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: mutedColor.withAlphaComponent(0.72),
                .baselineOffset: 0.5,
            ]
        ))
        line.append(NSAttributedString(
            string: "  -  \(apiOnline ? "En ligne" : "Hors ligne")",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: color,
            ]
        ))
        line.draw(in: NSRect(x: 36, y: y, width: bounds.width - 58, height: 16))
    }

    private func drawText(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        (text as NSString).draw(
            in: rect,
            withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]
        )
    }
}

@MainActor
private final class MenuController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let compactStatus = CompactStatusView(frame: .zero)
    private let codexStatus = NSMenuItem(title: "Codex : vérification…", action: nil, keyEquivalent: "")
    private let claudeStatus = NSMenuItem(title: "Claude : vérification…", action: nil, keyEquivalent: "")
    private let dashboard = QuotaDashboardView(frame: NSRect(x: 0, y: 0, width: 640, height: 250))
    private let persistentDashboard = QuotaDashboardView(frame: NSRect(x: 0, y: 0, width: 640, height: 250))
    private let showCodexItem = NSMenuItem(title: "Afficher Codex", action: nil, keyEquivalent: "")
    private let showClaudeItem = NSMenuItem(title: "Afficher Claude", action: nil, keyEquivalent: "")
    private let persistentWindowItem = NSMenuItem(title: "Afficher une fenêtre permanente", action: nil, keyEquivalent: "")
    private let alwaysOnTopItem = NSMenuItem(title: "Toujours au premier plan", action: nil, keyEquivalent: "")
    private let statusDisplayItem = NSMenuItem(title: "Icône de la barre des menus", action: nil, keyEquivalent: "")
    private let compactStatusItem = NSMenuItem(title: "Vue compacte", action: nil, keyEquivalent: "")
    private let codexPercentageItem = NSMenuItem(title: "% Codex restant (semaine)", action: nil, keyEquivalent: "")
    private let claudePercentageItem = NSMenuItem(title: "% Claude restant (semaine)", action: nil, keyEquivalent: "")
    private let refreshItem = NSMenuItem(title: "Actualiser les quotas", action: nil, keyEquivalent: "r")
    private let sourceItem = NSMenuItem(title: "Source des quotas…", action: nil, keyEquivalent: "")
    private let copyAPIItem = NSMenuItem(title: "Copier la configuration API", action: nil, keyEquivalent: "")
    private let autoLaunchItem = NSMenuItem(title: "Démarrer l’API avec la session", action: nil, keyEquivalent: "")
    private let updatesItem = NSMenuItem(title: "Mises à jour", action: nil, keyEquivalent: "")
    private let checkUpdateItem = NSMenuItem(title: "Vérifier les mises à jour…", action: nil, keyEquivalent: "")
    private let automaticUpdateItem = NSMenuItem(title: "Vérifier automatiquement", action: nil, keyEquivalent: "")
    private let connectionsItem = NSMenuItem(title: "Connexions", action: nil, keyEquivalent: "")
    private let claudeActionItem = NSMenuItem(title: "Autoriser Claude Desktop…", action: nil, keyEquivalent: "")
    private let bridgeLabel = "com.pducharme.quota-display"
    private let menuLabel = "com.pducharme.quota-display-menu"
    private let launchDomain = "gui/\(getuid())"
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    private var codexConnected: Bool?
    private var claudeConnected: Bool?
    private var snapshot: QuotaSnapshot?
    private var bridgeOnline = false
    private var checking = false
    private var loadingQuotas = false
    private var refreshingClaudeDesktop = false
    private var claudeDesktopCredential: ClaudeDesktopCredential?
    private var autoPrompted = Set<String>()
    private var persistentPanel: NSPanel?
    private var displayRevision = 0

    private var appSupportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quota Display")
    }

    private var claudeDesktopAuthorizationURL: URL {
        appSupportURL.appendingPathComponent("claude-desktop-authorized")
    }

    private var claudeDesktopQuotaURL: URL {
        appSupportURL.appendingPathComponent("claude-desktop-quotas.json")
    }

    private var claudeDesktopAuthorized: Bool {
        FileManager.default.fileExists(atPath: claudeDesktopAuthorizationURL.path)
    }

    private var bundledApplicationIcon: NSImage? {
        Bundle.main.url(forResource: "QuotaDisplay", withExtension: "icns")
            .flatMap(NSImage.init(contentsOf:))
    }

    private var configuredBridgeSource: (url: URL, tokenURL: URL, remote: Bool) {
        let sourceFile = appSupportURL.appendingPathComponent("source-host")
        if
            let value = try? String(contentsOf: sourceFile, encoding: .utf8),
            let url = bridgeBaseURL(from: value),
            !isLocalBridge(url)
        {
            return (url, appSupportURL.appendingPathComponent("source-token"), true)
        }
        return (bridgeBaseURL(from: nil)!, appSupportURL.appendingPathComponent("token"), false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard claimSingleInstance() else {
            NSApp.terminate(nil)
            return
        }
        UserDefaults.standard.register(defaults: [
            showCodexPreference: true,
            showClaudePreference: true,
            persistentWindowPreference: false,
            alwaysOnTopPreference: false,
            statusDisplayPreference: StatusDisplayMode.compact.rawValue,
        ])
        NSApp.setActivationPolicy(.accessory)
        if let icon = bundledApplicationIcon {
            NSImage(named: NSImage.applicationIconName)?.setName(nil)
            _ = icon.setName(NSImage.applicationIconName)
            NSApp.applicationIconImage = icon
        }
        NSApp.mainMenu = applicationMenu()
        restartBridgeAfterUpdateIfNeeded()
        configureMenu()
        checkAuthentication(autoPrompt: true)
        refreshClaudeDesktopIfAuthorized()
        loadAutoLaunchState()
        loadQuotas()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadQuotas() }
        }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAuthentication(autoPrompt: true)
                self?.refreshClaudeDesktopIfAuthorized()
            }
        }
    }

    private func configureMenu() {
        if let button = statusItem.button {
            button.image = nil
            button.title = ""
            button.setAccessibilityLabel("Quotas Codex et Claude")
            button.toolTip = "Quota Display"
            compactStatus.frame = button.bounds
            compactStatus.autoresizingMask = [.width, .height]
            button.addSubview(compactStatus)
        }
        statusItem.length = 90
        statusItem.isVisible = true
        let menu = NSMenu()
        menu.delegate = self
        let dashboardItem = NSMenuItem()
        dashboardItem.view = dashboard
        menu.addItem(dashboardItem)
        menu.addItem(.separator())
        let options = NSMenu(title: "Options")
        showCodexItem.target = self
        showCodexItem.action = #selector(toggleCodexVisibility)
        options.addItem(showCodexItem)
        showClaudeItem.target = self
        showClaudeItem.action = #selector(toggleClaudeVisibility)
        options.addItem(showClaudeItem)
        persistentWindowItem.target = self
        persistentWindowItem.action = #selector(togglePersistentWindow)
        options.addItem(persistentWindowItem)
        alwaysOnTopItem.target = self
        alwaysOnTopItem.action = #selector(toggleAlwaysOnTop)
        options.addItem(alwaysOnTopItem)
        let statusDisplay = NSMenu()
        compactStatusItem.target = self
        compactStatusItem.action = #selector(selectCompactStatus)
        statusDisplay.addItem(compactStatusItem)
        codexPercentageItem.target = self
        codexPercentageItem.action = #selector(selectCodexPercentage)
        statusDisplay.addItem(codexPercentageItem)
        claudePercentageItem.target = self
        claudePercentageItem.action = #selector(selectClaudePercentage)
        statusDisplay.addItem(claudePercentageItem)
        statusDisplayItem.submenu = statusDisplay
        options.addItem(statusDisplayItem)
        options.addItem(.separator())
        refreshItem.target = self
        refreshItem.action = #selector(refreshQuotas)
        options.addItem(refreshItem)
        sourceItem.target = self
        sourceItem.action = #selector(chooseQuotaSource)
        options.addItem(sourceItem)
        copyAPIItem.target = self
        copyAPIItem.action = #selector(copyAPIConfiguration)
        copyAPIItem.toolTip = "Copie l’adresse et le jeton nécessaires aux mini-écrans et aux Companions distants."
        options.addItem(copyAPIItem)
        autoLaunchItem.target = self
        autoLaunchItem.action = #selector(toggleAutoLaunch)
        autoLaunchItem.state = .mixed
        autoLaunchItem.toolTip = "Contrôle le démarrage du pont API Python à la prochaine ouverture de session."
        options.addItem(autoLaunchItem)
        let updates = NSMenu()
        checkUpdateItem.target = self
        checkUpdateItem.action = #selector(checkUpdates)
        updates.addItem(checkUpdateItem)
        automaticUpdateItem.target = self
        automaticUpdateItem.action = #selector(toggleAutomaticUpdateChecks)
        automaticUpdateItem.state = updaterController.updater.automaticallyChecksForUpdates ? .on : .off
        updates.addItem(automaticUpdateItem)
        updatesItem.submenu = updates
        options.addItem(updatesItem)
        let connections = NSMenu()
        codexStatus.isEnabled = false
        claudeStatus.isEnabled = false
        connections.addItem(codexStatus)
        let reconnectCodex = NSMenuItem(title: "Reconnecter Codex…", action: #selector(loginCodex), keyEquivalent: "")
        reconnectCodex.target = self
        connections.addItem(reconnectCodex)
        connections.addItem(.separator())
        connections.addItem(claudeStatus)
        claudeActionItem.target = self
        claudeActionItem.action = #selector(loginClaude)
        connections.addItem(claudeActionItem)
        connectionsItem.submenu = connections
        options.addItem(connectionsItem)
        options.addItem(.separator())
        let aboutItem = NSMenuItem(title: "À propos de Quota Display", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        options.addItem(aboutItem)
        let quitItem = NSMenuItem(title: "Quitter Quota Display", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        options.addItem(quitItem)
        let optionsItem = NSMenuItem(title: "Options", action: nil, keyEquivalent: "")
        optionsItem.submenu = options
        menu.addItem(optionsItem)
        statusItem.menu = menu
        updateSourceItems()
        applyDisplayPreferences()
    }

    private func applyDisplayPreferences(showWindow: Bool = false) {
        let defaults = UserDefaults.standard
        let showCodex = defaults.bool(forKey: showCodexPreference)
        let showClaude = defaults.bool(forKey: showClaudePreference)
        var statusMode = StatusDisplayMode(rawValue: defaults.string(forKey: statusDisplayPreference) ?? "") ?? .compact
        if statusMode == .codex && !showCodex { statusMode = .claude }
        if statusMode == .claude && !showClaude { statusMode = .codex }
        defaults.set(statusMode.rawValue, forKey: statusDisplayPreference)

        showCodexItem.state = showCodex ? .on : .off
        showClaudeItem.state = showClaude ? .on : .off
        persistentWindowItem.state = defaults.bool(forKey: persistentWindowPreference) ? .on : .off
        alwaysOnTopItem.state = defaults.bool(forKey: alwaysOnTopPreference) ? .on : .off
        compactStatusItem.state = statusMode == .compact ? .on : .off
        codexPercentageItem.state = statusMode == .codex ? .on : .off
        claudePercentageItem.state = statusMode == .claude ? .on : .off
        codexPercentageItem.isEnabled = showCodex
        claudePercentageItem.isEnabled = showClaude

        dashboard.showCodex = showCodex
        dashboard.showClaude = showClaude
        persistentDashboard.showCodex = showCodex
        persistentDashboard.showClaude = showClaude
        compactStatus.showCodex = showCodex
        compactStatus.showClaude = showClaude
        compactStatus.displayMode = statusMode
        persistentPanel?.level = defaults.bool(forKey: alwaysOnTopPreference) ? .floating : .normal
        if defaults.bool(forKey: persistentWindowPreference) {
            showPersistentDashboard(activate: showWindow)
        } else {
            persistentPanel?.orderOut(nil)
        }
        renderStatusTitle()
    }

    @objc private func toggleCodexVisibility() {
        let defaults = UserDefaults.standard
        let next = !defaults.bool(forKey: showCodexPreference)
        guard next || defaults.bool(forKey: showClaudePreference) else {
            NSSound.beep()
            return
        }
        defaults.set(next, forKey: showCodexPreference)
        if !next && defaults.string(forKey: statusDisplayPreference) == StatusDisplayMode.codex.rawValue {
            defaults.set(StatusDisplayMode.claude.rawValue, forKey: statusDisplayPreference)
        }
        displayRevision += 1
        applyDisplayPreferences()
        syncDisplayPreferences()
    }

    @objc private func toggleClaudeVisibility() {
        let defaults = UserDefaults.standard
        let next = !defaults.bool(forKey: showClaudePreference)
        guard next || defaults.bool(forKey: showCodexPreference) else {
            NSSound.beep()
            return
        }
        defaults.set(next, forKey: showClaudePreference)
        if !next && defaults.string(forKey: statusDisplayPreference) == StatusDisplayMode.claude.rawValue {
            defaults.set(StatusDisplayMode.codex.rawValue, forKey: statusDisplayPreference)
        }
        displayRevision += 1
        applyDisplayPreferences()
        syncDisplayPreferences()
    }

    @objc private func togglePersistentWindow() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: persistentWindowPreference), forKey: persistentWindowPreference)
        applyDisplayPreferences(showWindow: true)
    }

    @objc private func toggleAlwaysOnTop() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: alwaysOnTopPreference), forKey: alwaysOnTopPreference)
        applyDisplayPreferences()
    }

    @objc private func selectCompactStatus() { selectStatusMode(.compact) }
    @objc private func selectCodexPercentage() { selectStatusMode(.codex) }
    @objc private func selectClaudePercentage() { selectStatusMode(.claude) }

    private func selectStatusMode(_ mode: StatusDisplayMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: statusDisplayPreference)
        applyDisplayPreferences()
    }

    private func showPersistentDashboard(activate: Bool) {
        if persistentPanel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 250),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            panel.title = "Quota Display"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = persistentDashboard
            panel.delegate = self
            panel.setFrameAutosaveName("QuotaDisplayPersistentWindow")
            panel.center()
            persistentPanel = panel
        }
        persistentPanel?.level = UserDefaults.standard.bool(forKey: alwaysOnTopPreference) ? .floating : .normal
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            persistentPanel?.makeKeyAndOrderFront(nil)
        } else {
            persistentPanel?.orderFrontRegardless()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === persistentPanel else { return }
        UserDefaults.standard.set(false, forKey: persistentWindowPreference)
        persistentWindowItem.state = .off
    }

    private func updateSourceItems() {
        let source = configuredBridgeSource
        if source.remote {
            let address = source.url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            sourceItem.title = "Source des quotas : \(address)…"
            connectionsItem.title = "Connexions · gérées par la source"
            connectionsItem.isEnabled = false
            codexStatus.title = "Codex : source distante"
            claudeStatus.title = "Claude : source distante"
        } else {
            sourceItem.title = "Source des quotas : ce Mac…"
            connectionsItem.title = "Connexions"
            connectionsItem.isEnabled = true
            let desktop = claudeDesktopHasCredentialMaterial()
            claudeActionItem.title = desktop
                ? (claudeDesktopAuthorized ? "Reconnecter Claude Desktop…" : "Autoriser Claude Desktop…")
                : "Reconnecter Claude Code…"
        }
    }

    @objc private func copyAPIConfiguration() {
        let source = configuredBridgeSource
        guard
            let address = snapshot?.apiAddress,
            let token = try? String(contentsOf: source.tokenURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            token.count >= 16
        else {
            copyAPIItem.title = "Configuration API indisponible"
            restoreCopyAPITitle()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Adresse: \(address)\nJeton: \(token)", forType: .string)
        copyAPIItem.title = "Configuration API copiée ✓"
        restoreCopyAPITitle()
    }

    private func restoreCopyAPITitle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copyAPIItem.title = "Copier la configuration API"
        }
    }

    @objc private func chooseQuotaSource() {
        let source = configuredBridgeSource
        let alert = NSAlert()
        alert.messageText = "Source des quotas"
        alert.informativeText = "Laisser l’adresse vide pour utiliser l’API de ce Mac. Le mode distant utilise la même adresse et le même jeton qu’un mini-écran."
        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Annuler")

        let address = NSTextField(string: source.remote ? source.url.absoluteString : "")
        address.placeholderString = "192.168.1.20:8788"
        let token = NSSecureTextField(string: "")
        token.placeholderString = source.remote ? "Laisser vide pour conserver le jeton" : "Jeton de la source distante"
        let fields = NSStackView(views: [
            NSTextField(labelWithString: "Adresse de l’API"),
            address,
            NSTextField(labelWithString: "Jeton"),
            token,
        ])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 5
        fields.frame = NSRect(x: 0, y: 0, width: 360, height: 90)
        address.widthAnchor.constraint(equalToConstant: 360).isActive = true
        token.widthAnchor.constraint(equalToConstant: 360).isActive = true
        alert.accessoryView = fields
        alert.window.initialFirstResponder = address

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        saveQuotaSource(host: address.stringValue, token: token.stringValue)
    }

    private func saveQuotaSource(host: String, token enteredToken: String) {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingToken = (try? String(
            contentsOf: appSupportURL.appendingPathComponent("source-token"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        guard let url = bridgeBaseURL(from: host) else {
            showSourceError("L’adresse de l’API n’est pas valide.")
            return
        }
        let remote = !host.isEmpty && !isLocalBridge(url)
        let token = enteredToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveToken = token.isEmpty ? existingToken : token
        guard !remote || effectiveToken.count >= 16 else {
            showSourceError("Le jeton de la source distante doit contenir au moins 16 caractères.")
            return
        }

        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
            try writePrivate(remote ? host : "", to: appSupportURL.appendingPathComponent("source-host"))
            if remote {
                try writePrivate(effectiveToken, to: appSupportURL.appendingPathComponent("source-token"))
            }
        } catch {
            showSourceError("La source n’a pas pu être enregistrée : \(error.localizedDescription)")
            return
        }

        loadingQuotas = false
        bridgeOnline = false
        snapshot = nil
        dashboard.snapshot = nil
        dashboard.apiOnline = false
        persistentDashboard.snapshot = nil
        persistentDashboard.apiOnline = false
        updateSourceItems()
        checkAuthentication(autoPrompt: false)
        loadQuotas()
        renderStatusTitle()
    }

    private func writePrivate(_ value: String, to url: URL) throws {
        try Data((value + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func showSourceError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Source des quotas"
        alert.informativeText = message
        alert.runModal()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateSourceItems()
        checkUpdateItem.isEnabled = updaterController.updater.canCheckForUpdates
        automaticUpdateItem.state = updaterController.updater.automaticallyChecksForUpdates ? .on : .off
        checkAuthentication(autoPrompt: false)
        loadAutoLaunchState()
        loadQuotas()
    }

    private func checkAuthentication(autoPrompt: Bool) {
        guard !configuredBridgeSource.remote, !checking else { return }
        checking = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let claudePath = executable(named: "claude")
            let codexPath = executable(named: "codex")
            let desktop = claudeDesktopHasCredentialMaterial()
            let cliClaude = claudeState(from: run(claudePath, ["auth", "status", "--json"]))
            let authorized = FileManager.default.fileExists(
                atPath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/Quota Display/claude-desktop-authorized").path
            )
            let claude = cliClaude.connected || !desktop
                ? cliClaude
                : AuthState(
                    connected: authorized,
                    label: authorized ? "Claude Desktop autorisé" : "Claude Desktop à autoriser"
                )
            let codex = codexState(from: run(codexPath, ["login", "status"]))
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.apply(
                    claude: claude,
                    codex: codex,
                    claudeDesktopAvailable: desktop,
                    autoPrompt: autoPrompt
                )
            }
        }
    }

    private func apply(
        claude: AuthState,
        codex: AuthState,
        claudeDesktopAvailable: Bool,
        autoPrompt: Bool
    ) {
        guard !configuredBridgeSource.remote else {
            updateSourceItems()
            return
        }
        claudeConnected = claude.connected
        codexConnected = codex.connected
        claudeStatus.title = "Claude : \(claude.label)"
        codexStatus.title = "Codex : \(codex.label)"
        claudeActionItem.title = claudeDesktopAvailable
            ? (claudeDesktopAuthorized ? "Reconnecter Claude Desktop…" : "Autoriser Claude Desktop…")
            : "Reconnecter Claude Code…"
        renderStatusTitle()

        if claude.connected { autoPrompted.remove("claude") }
        if codex.connected { autoPrompted.remove("codex") }
        if autoPrompt && !claude.connected && !claudeDesktopAvailable && autoPrompted.insert("claude").inserted {
            launchLogin(provider: "claude")
        }
        if autoPrompt && !codex.connected && autoPrompted.insert("codex").inserted {
            launchLogin(provider: "codex")
        }
    }

    private func renderStatusTitle() {
        let remote = configuredBridgeSource.remote
        compactStatus.snapshot = snapshot
        compactStatus.bridgeOnline = bridgeOnline
        compactStatus.codexConnected = remote ? snapshot.map { $0.codex.status != "error" } : codexConnected
        compactStatus.claudeConnected = remote ? snapshot.map { $0.claude.status != "error" } : claudeConnected
        compactStatus.needsDisplay = true
        let tooltip = snapshot?.refreshedAt.map {
            "5 h / semaine · dernière actualisation \(dateText($0, timeOnly: true))"
        } ?? "5 h / semaine · en attente du pont"
        statusItem.button?.toolTip = tooltip
        statusItem.button?.setAccessibilityLabel(tooltip)
    }

    private func bridgeRequest(path: String, method: String = "GET") -> URLRequest? {
        let source = configuredBridgeSource
        guard
            let token = try? String(contentsOf: source.tokenURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            token.count >= 16,
            let url = URL(string: path, relativeTo: source.url)?.absoluteURL
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func syncDisplayPreferences() {
        guard var request = bridgeRequest(path: "/v1/display", method: "POST") else {
            NSSound.beep()
            return
        }
        let defaults = UserDefaults.standard
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "codex": defaults.bool(forKey: showCodexPreference),
            "claude": defaults.bool(forKey: showClaudePreference),
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                if !ok { NSSound.beep() }
                self?.loadQuotas()
            }
        }.resume()
    }

    private func loadQuotas() {
        let sourceURL = configuredBridgeSource.url
        let requestedDisplayRevision = displayRevision
        guard !loadingQuotas, let request = bridgeRequest(path: "/v1/quotas") else {
            bridgeOnline = false
            dashboard.apiOnline = false
            persistentDashboard.apiOnline = false
            renderStatusTitle()
            return
        }
        loadingQuotas = true
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode
            let loaded = data.flatMap(quotaSnapshot(from:))
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.configuredBridgeSource.url == sourceURL else { return }
                self.loadingQuotas = false
                self.bridgeOnline = code == 200 && loaded != nil
                self.dashboard.apiOnline = self.bridgeOnline
                self.persistentDashboard.apiOnline = self.bridgeOnline
                if let loaded {
                    if self.displayRevision == requestedDisplayRevision,
                       let showCodex = loaded.displayCodex,
                       let showClaude = loaded.displayClaude,
                       showCodex || showClaude {
                        UserDefaults.standard.set(showCodex, forKey: showCodexPreference)
                        UserDefaults.standard.set(showClaude, forKey: showClaudePreference)
                        self.applyDisplayPreferences()
                    }
                    self.snapshot = loaded
                    self.dashboard.snapshot = loaded
                    self.persistentDashboard.snapshot = loaded
                }
                self.renderStatusTitle()
            }
        }.resume()
    }

    private func loadAutoLaunchState() {
        let domain = launchDomain
        let label = bridgeLabel
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = run("/bin/launchctl", ["print-disabled", domain])
            let enabled = autoLaunchEnabled(from: result, label: label)
            DispatchQueue.main.async {
                self?.autoLaunchItem.state = enabled.map { $0 ? .on : .off } ?? .mixed
            }
        }
    }

    @objc private func toggleAutoLaunch() {
        let enable = autoLaunchItem.state != .on
        let domain = launchDomain
        let target = "\(domain)/\(bridgeLabel)"
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(bridgeLabel).plist").path
        autoLaunchItem.isEnabled = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = run("/bin/launchctl", [enable ? "enable" : "disable", target])
            if enable && result.status == 0 {
                let started = run("/bin/launchctl", ["kickstart", "-k", target])
                if started.status != 0 {
                    _ = run("/bin/launchctl", ["bootstrap", domain, plist])
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.autoLaunchItem.isEnabled = true
                if result.status == 0 {
                    self.autoLaunchItem.state = enable ? .on : .off
                } else {
                    self.loadAutoLaunchState()
                }
            }
        }
    }

    @objc private func checkUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc private func toggleAutomaticUpdateChecks() {
        let enabled = !updaterController.updater.automaticallyChecksForUpdates
        updaterController.updater.automaticallyChecksForUpdates = enabled
        automaticUpdateItem.state = enabled ? .on : .off
    }

    private func claimSingleInstance() -> Bool {
        let currentPID = getpid()
        let target = "\(launchDomain)/\(menuLabel)"
        let managedPID = launchdPID(from: run("/bin/launchctl", ["print", target]).output)
        if let managedPID, managedPID != currentPID {
            return false
        }
        if let identifier = Bundle.main.bundleIdentifier {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                where app.processIdentifier != currentPID
            {
                app.terminate()
            }
        }
        return true
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let repository = "Dépôt GitHub du projet"
        let credits = NSMutableAttributedString(string: "Patrick Fortin-Ducharme\n\(repository)")
        credits.addAttribute(
            .link,
            value: URL(string: "https://github.com/pducharme/codex-claude-quota-display")!,
            range: (credits.string as NSString).range(of: repository)
        )
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.credits: credits]
        if let icon = bundledApplicationIcon {
            options[.applicationIcon] = icon
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    @objc private func quitApp() {
        _ = run("/bin/launchctl", ["bootout", "\(launchDomain)/\(menuLabel)"])
        NSApp.terminate(nil)
    }

    private func restartBridgeAfterUpdateIfNeeded() {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return }
        let key = "lastLaunchedBundleVersion"
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: key)
        defaults.set(version, forKey: key)
        guard previous != nil, previous != version else { return }
        DispatchQueue.global(qos: .utility).async { [launchDomain, bridgeLabel] in
            _ = run("/bin/launchctl", ["kickstart", "-k", "\(launchDomain)/\(bridgeLabel)"])
        }
    }

    @objc private func loginClaude() {
        guard claudeDesktopHasCredentialMaterial() else {
            launchLogin(provider: "claude")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Autoriser Claude Desktop"
        alert.informativeText = "macOS demandera la permission de lire « Claude Safe Storage ». Le jeton reste uniquement en mémoire; seuls les pourcentages et les heures de remise à zéro sont enregistrés localement."
        alert.addButton(withTitle: "Autoriser")
        alert.addButton(withTitle: "Annuler")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setStatus(provider: "claude", text: "autorisation en cours…")
        refreshClaudeDesktop(allowPrompt: true) { [weak self] success, message in
            guard let self else { return }
            if success {
                self.triggerRefresh()
            } else {
                self.showLoginError(provider: "claude", message: message)
            }
        }
    }

    @objc private func loginCodex() {
        launchLogin(provider: "codex")
    }

    private func launchLogin(provider: String) {
        let path = executable(named: provider)
        guard let path else {
            setStatus(provider: provider, text: "commande introuvable")
            showLoginError(
                provider: provider,
                message: "La commande n’est pas installée sur ce Mac. Installez-la, puis réessayez."
            )
            return
        }
        let arguments = provider == "claude"
            ? ["auth", "login", "--claudeai"]
            : ["login"]
        do {
            let command = ([path] + arguments).map(shellQuoted).joined(separator: " ")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("quota-display-login-\(UUID().uuidString).command")
            try "#!/bin/zsh\n/bin/rm -f -- \"$0\"\n\(command)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            guard NSWorkspace.shared.open(url) else {
                throw CocoaError(.fileNoSuchFile)
            }
            setStatus(provider: provider, text: "connexion ouverte dans Terminal")
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.checkAuthentication(autoPrompt: false)
            }
        } catch {
            setStatus(provider: provider, text: "Terminal indisponible")
            showLoginError(provider: provider, message: "Terminal n’a pas pu ouvrir la commande de connexion.")
        }
    }

    private func showLoginError(provider: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Connexion \(provider == "claude" ? "Claude Code" : "Codex")"
        alert.informativeText = message
        alert.runModal()
    }

    private func setStatus(provider: String, text: String) {
        if provider == "claude" {
            claudeStatus.title = "Claude : \(text)"
        } else {
            codexStatus.title = "Codex : \(text)"
        }
    }

    @objc private func refreshQuotas() {
        if !configuredBridgeSource.remote && claudeDesktopAuthorized {
            refreshClaudeDesktop(allowPrompt: false) { [weak self] _, _ in
                self?.triggerRefresh()
            }
        } else {
            triggerRefresh()
        }
    }

    private func refreshClaudeDesktopIfAuthorized() {
        guard !configuredBridgeSource.remote, claudeDesktopAuthorized else { return }
        refreshClaudeDesktop(allowPrompt: false) { [weak self] _, _ in
            self?.triggerRefresh()
        }
    }

    private func refreshClaudeDesktop(
        allowPrompt: Bool,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard !refreshingClaudeDesktop else {
            completion(false, "Une actualisation Claude Desktop est déjà en cours.")
            return
        }
        refreshingClaudeDesktop = true
        if
            let credential = claudeDesktopCredential,
            credential.expiresAt > Date().addingTimeInterval(120)
        {
            fetchClaudeDesktopUsage(credential, completion: completion)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try loadClaudeDesktopCredential(allowPrompt: allowPrompt) }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(let credential):
                    self.claudeDesktopCredential = credential
                    if allowPrompt {
                        do {
                            try FileManager.default.createDirectory(
                                at: self.appSupportURL,
                                withIntermediateDirectories: true
                            )
                            try self.writePrivate("yes", to: self.claudeDesktopAuthorizationURL)
                        } catch {
                            self.refreshingClaudeDesktop = false
                            completion(false, error.localizedDescription)
                            return
                        }
                    }
                    self.fetchClaudeDesktopUsage(credential, completion: completion)
                case .failure(let error):
                    self.refreshingClaudeDesktop = false
                    self.claudeConnected = false
                    self.setStatus(provider: "claude", text: "autorisation requise")
                    self.renderStatusTitle()
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    private func fetchClaudeDesktopUsage(
        _ credential: ClaudeDesktopCredential,
        completion: @escaping (Bool, String) -> Void
    ) {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.refreshingClaudeDesktop = false }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard
                    error == nil,
                    200...299 ~= status,
                    let data,
                    let initialValue = claudeDesktopQuotaSnapshot(from: data, plan: self.snapshot?.claude.plan)
                else {
                    if status == 401 || status == 403 { self.claudeDesktopCredential = nil }
                    self.claudeConnected = false
                    self.setStatus(provider: "claude", text: "lecture impossible")
                    self.renderStatusTitle()
                    let failure = status > 0
                        ? ClaudeDesktopError.http(status).localizedDescription
                        : (error?.localizedDescription ?? ClaudeDesktopError.invalidData.localizedDescription)
                    completion(false, failure)
                    return
                }

                let finish: ([String: Any]) -> Void = { value in
                    do {
                        let output = try JSONSerialization.data(withJSONObject: value)
                        try FileManager.default.createDirectory(
                            at: self.appSupportURL,
                            withIntermediateDirectories: true
                        )
                        try output.write(to: self.claudeDesktopQuotaURL, options: .atomic)
                        try FileManager.default.setAttributes(
                            [.posixPermissions: 0o600],
                            ofItemAtPath: self.claudeDesktopQuotaURL.path
                        )
                        self.claudeConnected = true
                        self.claudeStatus.title = "Claude : Claude Desktop connecté"
                        self.claudeActionItem.title = "Reconnecter Claude Desktop…"
                        self.renderStatusTitle()
                        completion(true, "")
                    } catch {
                        completion(false, error.localizedDescription)
                    }
                }

                guard initialValue["plan"] == nil else {
                    finish(initialValue)
                    return
                }
                var profileRequest = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
                profileRequest.setValue("application/json", forHTTPHeaderField: "Accept")
                profileRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
                profileRequest.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                profileRequest.setValue("claude-cli (external, cli)", forHTTPHeaderField: "User-Agent")
                URLSession.shared.dataTask(with: profileRequest) { profileData, profileResponse, _ in
                    let profileStatus = (profileResponse as? HTTPURLResponse)?.statusCode ?? 0
                    let plan = profileData
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        .flatMap(claudePlanName)
                    DispatchQueue.main.async {
                        let value = claudeDesktopQuotaSnapshot(from: data, plan: profileStatus == 200 ? plan : nil)
                            ?? initialValue
                        finish(value)
                    }
                }.resume()
            }
        }.resume()
    }

    private func triggerRefresh() {
        guard let request = bridgeRequest(path: "/v1/refresh", method: "POST") else {
            refreshItem.title = "Pont indisponible"
            return
        }
        refreshItem.title = "Actualisation en cours…"
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 202
            DispatchQueue.main.async {
                self?.refreshItem.title = ok ? "Actualisation lancée ✓" : "Pont indisponible"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.refreshItem.title = "Actualiser les quotas"
                    self?.loadQuotas()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                    self?.loadQuotas()
                }
            }
        }.resume()
    }
}

@main
private struct QuotaMenu {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            let claudeGood = claudeState(from: CommandResult(
                status: 0,
                output: #"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}"#
            )).connected
            let claudeWrongMode = claudeState(from: CommandResult(
                status: 0,
                output: #"{"loggedIn":true,"authMethod":"console"}"#
            )).connected
            let codexGood = codexState(from: CommandResult(status: 0, output: "Logged in using ChatGPT")).connected
            let codexWrongMode = codexState(from: CommandResult(status: 0, output: "Logged in using an API key")).connected
            let sample = #"{"api":{"status":"online","address":"192.168.1.252:8788"},"display":{"codex":true,"claude":false},"refresh":{"completed_at":1785776996},"providers":{"codex":{"status":"ok","plan":"Pro 20X","five_hour":{"used_percent":null,"resets_at":null},"weekly":{"used_percent":7,"resets_at":1786172449},"fable_weekly":{"used_percent":null,"resets_at":null},"banked_resets":{"available_count":2}},"claude":{"status":"ok","plan":"Max 5X","five_hour":{"used_percent":0,"resets_at":null},"weekly":{"used_percent":15,"resets_at":1785859200},"fable_weekly":{"used_percent":28,"resets_at":1785859200}}}}"#
            let quotas = quotaSnapshot(from: Data(sample.utf8))
            let desktopSample = #"{"subscription_type":"max","organization":{"rate_limit_tier":"default_claude_max_5x"},"five_hour":{"utilization":12.8,"resets_at":"2026-09-02T22:00:00Z"},"seven_day":{"utilization":39,"resets_at":"2026-09-08T04:00:00Z"},"seven_day_fable":{"utilization":81,"resets_at":"2026-09-08T04:00:00Z"}}"#
            let desktopQuotas = claudeDesktopQuotaSnapshot(from: Data(desktopSample.utf8))
            let editMenu = applicationMenu().items.first?.submenu
            let organization = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            let credential = bestClaudeDesktopCredential(
                in: [
                    "9d1c250a-e61b-44d9-88ed-5944d1962f5e:\(organization):https://api.anthropic.com:user:profile user:inference": [
                        "token": "test-token", "expiresAt": 2_000_000,
                    ],
                ],
                organization: organization,
                now: Date(timeIntervalSince1970: 1_000)
            )
            let autoLaunchOn = autoLaunchEnabled(from: CommandResult(status: 0, output: "disabled services = {}"), label: "test")
            let autoLaunchOff = autoLaunchEnabled(from: CommandResult(status: 0, output: "\"test\" => disabled"), label: "test")
            let parsedLaunchPID = launchdPID(from: "state = running\n\tpid = 4321\n")
            let hourlyReset = resetCountdown(QuotaWindow(usedPercent: 60, resetsAt: 19_000), now: 10_000)
            let weeklyReset = resetCountdown(QuotaWindow(usedPercent: 40, resetsAt: 450_640), now: 10_000)
            let expectedHalf = expectedRemainingPercent(
                QuotaWindow(usedPercent: 60, resetsAt: 19_000),
                durationSeconds: 18_000,
                now: 10_000
            )
            let localBridge = bridgeBaseURL(from: nil)
            let remoteBridge = bridgeBaseURL(from: "192.168.1.20:8788")
            let singleProvider = dashboardPanelRects(
                in: NSRect(x: 0, y: 0, width: 624, height: 238),
                showCodex: true,
                showClaude: false
            )
            let bothProviders = dashboardPanelRects(
                in: NSRect(x: 0, y: 0, width: 624, height: 238),
                showCodex: true,
                showClaude: true
            )
            let bundledIcon = Bundle.main.bundleURL.pathExtension != "app"
                || Bundle.main.url(forResource: "CodexIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:)) != nil
            let bundledAppIcon = Bundle.main.bundleURL.pathExtension != "app"
                || Bundle.main.url(forResource: "QuotaDisplay", withExtension: "icns").flatMap(NSImage.init(contentsOf:)) != nil
            let sparkleConfigured = Bundle.main.bundleURL.pathExtension != "app"
                || ((Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?.hasPrefix("https://") == true
                    && (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false)
            guard
                claudeGood, !claudeWrongMode, codexGood, !codexWrongMode,
                quotas?.codex.weekly.remainingPercent == 93,
                quotas?.codex.plan == "Pro 20X",
                quotas?.claude.fiveHour.remainingPercent == 100,
                quotas?.claude.plan == "Max 5X",
                quotas?.claude.fableWeekly.remainingPercent == 72,
                quotas?.displayCodex == true, quotas?.displayClaude == false,
                (desktopQuotas?["five_hour"] as? [String: Any])?["used_percent"] as? Int == 12,
                (desktopQuotas?["weekly"] as? [String: Any])?["used_percent"] as? Int == 39,
                (desktopQuotas?["fable_weekly"] as? [String: Any])?["used_percent"] as? Int == 81,
                desktopQuotas?["plan"] as? String == "Max 5X",
                credential?.accessToken == "test-token",
                editMenu?.items.first(where: { $0.keyEquivalent == "v" })?.action == #selector(NSText.paste(_:)),
                compactRemainingText(quotas!.codex.weekly, percent: true) == "93%",
                hourlyReset == "2h 30m",
                weeklyReset == "5j 2h",
                expectedHalf == 50,
                localBridge?.absoluteString == "http://127.0.0.1:8788",
                remoteBridge?.host == "192.168.1.20", remoteBridge?.port == 8788,
                bridgeBaseURL(from: "ftp://192.168.1.20:8788") == nil,
                bridgeBaseURL(from: "http://192.168.1.20:8788/extra") == nil,
                singleProvider.codex?.width == 608, singleProvider.claude == nil,
                bothProviders.codex?.width == 300, bothProviders.claude?.minX == 316,
                shellQuoted("a'b") == "'a'\\''b'",
                bundledIcon, bundledAppIcon,
                sparkleConfigured,
                quotas?.apiAddress == "192.168.1.252:8788",
                autoLaunchOn == true, autoLaunchOff == false,
                parsedLaunchPID == 4321
            else { exit(1) }
            print("quota menu self-test: ok")
            return
        }
        let app = NSApplication.shared
        let delegate = MenuController()
        app.delegate = delegate
        app.run()
    }
}
