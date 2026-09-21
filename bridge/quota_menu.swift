import AppKit
import CommonCrypto
import Darwin
import Foundation
import LocalAuthentication
import Security
import SQLite3
import Sparkle
import WebKit

private final class DesignerWindow: NSWindowController, WKNavigationDelegate {
    private let webView: WKWebView
    private let origin: URL
    init(request: URLRequest) {
        origin = request.url!
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 740),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        panel.title = "Designer — Quota Display"
        panel.minSize = NSSize(width: 740, height: 560)
        panel.contentView = webView
        panel.center()
        super.init(window: panel)
        webView.navigationDelegate = self
        webView.load(request)
    }
    required init?(coder: NSCoder) { nil }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url, url.scheme == "https",
           url.host == "pducharme.github.io", url.path.hasPrefix("/codex-claude-quota-display/") {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel); return
        }
        guard let url = navigationAction.request.url, url.scheme == origin.scheme,
              url.host == origin.host, url.port == origin.port, url.path.hasPrefix("/designer") else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Designer indisponible"
        alert.informativeText = "Vérifiez que le Companion source est en ligne et dispose de la version avec Designer."
        alert.beginSheetModal(for: window)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode != 200 {
            if let window {
                let alert = NSAlert()
                alert.messageText = "Designer indisponible sur la source"
                alert.informativeText = response.statusCode == 401
                    ? "Vérifiez la clé API dans les réglages de connexion."
                    : "Installez Quota Display 1.1.0 ou une version plus récente sur le Mac source, puis rouvrez le Designer."
                alert.beginSheetModal(for: window)
            }
            decisionHandler(.cancel)
        } else { decisionHandler(.allow) }
    }
}

private final class QuotaDiagnostics {
    static let shared = QuotaDiagnostics()
    static let disabledURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Quota Display/diagnostics-disabled")
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()
    private let lock = NSLock()
    private var lastSent: [String: Date] = [:]
    private var retryAt = Date.distantPast
    private let started = Date()
    private let sessionID = UUID().uuidString

    static func failure(_ error: Error?, status: Int? = nil) -> String {
        if let error = error as? ClaudeDesktopError {
            switch error {
            case .unavailable: return "credential_unavailable"
            case .keychain(let code): return "keychain_\(code)"
            case .invalidData: return "credential_invalid"
            case .noAccount: return "credential_missing_or_expired"
            case .http(let code): return "http_\(code)"
            }
        }
        if let error = error as NSError? {
            // Never include localizedDescription/userInfo: they can contain tokens, URLs and paths.
            let domain = [NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain].contains(error.domain)
                ? error.domain : "other"
            return "\(domain)_\(error.code)"
        }
        return status.map { "http_\($0)" } ?? "invalid_response"
    }

    func event(_ operation: String, failure: String, remote: Bool, age: Int? = nil) -> [String: Any] {
        var extra: [String: Any] = ["session": sessionID, "uptime_seconds": max(0, Int(Date().timeIntervalSince(started)))]
        if let age { extra["last_success_age_seconds"] = max(0, age) }
        return [
            "event_id": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            "timestamp": Date().timeIntervalSince1970, "platform": "other", "level": "error",
            "environment": "production", "logger": "quota-display.companion",
            "release": "quota-display@\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development")",
            "message": "\(operation): \(failure)", "fingerprint": ["companion", operation, failure],
            "tags": ["component": "companion", "operation": operation, "source_mode": remote ? "remote" : "local"],
            "contexts": ["os": ["name": "macOS", "version": ProcessInfo.processInfo.operatingSystemVersionString]],
            "extra": extra,
        ]
    }

    func capture(_ operation: String, failure: String, remote: Bool, age: Int? = nil) {
        guard !FileManager.default.fileExists(atPath: Self.disabledURL.path),
              !CommandLine.arguments.contains("--self-test") else { return }
        let now = Date()
        let key = "\(operation):\(failure):\(remote)"
        lock.lock()
        let allowed = now >= retryAt && now.timeIntervalSince(lastSent[key] ?? .distantPast) >= 900
        if allowed { lastSent[key] = now }
        lock.unlock()
        guard allowed else { return }
        var request = URLRequest(url: URL(string: "https://glitchtip.bestnetwork.cloud/api/5/store/")!, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Public ingestion key; no management credential is shipped.
        request.setValue("Sentry sentry_version=7, sentry_key=6825de160b8646f48e7ec8a1bfd3b943", forHTTPHeaderField: "X-Sentry-Auth")
        request.httpBody = try? JSONSerialization.data(withJSONObject: event(operation, failure: failure, remote: remote, age: age))
        session.dataTask(with: request) { [weak self] _, response, error in
            let http = response as? HTTPURLResponse
            guard error != nil || http?.statusCode != 200, let self else { return }
            let delay = http?.statusCode == 429
                ? max(900, Double(http?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 900) : 60
            self.lock.lock()
            self.retryAt = Date().addingTimeInterval(delay)
            self.lock.unlock()
            // ponytail: drop failed diagnostics; collection never delays quota refreshes.
        }.resume()
    }
}

private func quotaFreshnessFailures(_ data: Data) -> [(operation: String, age: Int)] {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let now = root["server_time"] as? Int, now >= 0 else { return [] }
    func age(_ value: Any?) -> Int? {
        guard let timestamp = value as? Int, timestamp >= 0, timestamp <= now else { return nil }
        return now - timestamp
    }
    let refresh = root["refresh"] as? [String: Any] ?? [:]
    let interval = min(3600, max(60, refresh["interval_seconds"] as? Int ?? 300))
    var failures: [(operation: String, age: Int)] = []
    if refresh["active"] as? Bool == true, let elapsed = age(refresh["started_at"]), elapsed > 120 {
        failures.append(("refresh_stalled", elapsed))
    }
    if let elapsed = age(refresh["completed_at"]), elapsed > max(900, interval * 3) {
        failures.append(("refresh_overdue", elapsed))
    }
    let providers = root["providers"] as? [String: [String: Any]] ?? [:]
    let display = root["display"] as? [String: Any] ?? [:]
    for provider in ["codex", "claude"] where display[provider] as? Bool != false {
        guard let value = providers[provider] else { continue }
        let status = value["status"] as? String
        let elapsed = age(value["updated_at"]) ?? 0
        if status == "stale" || status == "error" || elapsed > max(900, interval * 3) {
            failures.append(("\(provider)_quotas_stale", elapsed))
        }
    }
    return failures
}

private func quotaTimer(interval: TimeInterval, action: @escaping (Timer) -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: true, block: action)
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .eventTracking)
    return timer
}

private let quotaSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForRequest = 20
    configuration.timeoutIntervalForResource = 45
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
}()

private func quotaRetryDelay(error: Error?, attempt: Int) -> TimeInterval? {
    guard attempt >= 0, attempt < 2, let error = error as? URLError,
          [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
           .networkConnectionLost, .timedOut].contains(error.code) else { return nil }
    return TimeInterval((attempt + 1) * 5)
}

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
        let utilization = ((value["utilization"] ?? value["percent"]) as? NSNumber)?.doubleValue
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
    let fable = (source["limits"] as? [[String: Any]])?.first { limit in
        guard
            limit["kind"] as? String == "weekly_scoped",
            let scope = limit["scope"] as? [String: Any],
            let model = scope["model"] as? [String: Any],
            let name = model["display_name"] as? String
        else { return false }
        return name.caseInsensitiveCompare("Fable") == .orderedSame
    }
    var value: [String: Any] = [
        "updated_at": Int(Date().timeIntervalSince1970),
        "source": "claude-desktop",
        "five_hour": claudeDesktopWindow(source["five_hour"]),
        "weekly": claudeDesktopWindow(source["seven_day"]),
        "fable_weekly": claudeDesktopWindow(fable ?? source["seven_day_fable"]),
    ]
    if let plan = claudePlanName(from: source) ?? plan { value["plan"] = plan }
    let windows = ["five_hour", "weekly", "fable_weekly"]
    guard windows.contains(where: {
        (value[$0] as? [String: Any])?["used_percent"] is Int
    }) else { return nil }
    return value
}

private func installedBridgeURL(in launchAgent: Data?) -> URL? {
    guard
        let launchAgent,
        let plist = try? PropertyListSerialization.propertyList(from: launchAgent, format: nil) as? [String: Any],
        let arguments = plist["ProgramArguments"] as? [String],
        let path = arguments.first(where: { $0.hasPrefix("/") && $0.hasSuffix("/quota_bridge.py") })
    else { return nil }
    return URL(fileURLWithPath: path)
}

private func updateInstalledBridge(from source: URL?, to destination: URL) -> Bool {
    guard
        let source,
        let bundled = try? Data(contentsOf: source),
        (try? Data(contentsOf: destination)) != bundled
    else { return false }
    do {
        try bundled.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: destination.path
        )
        return true
    } catch {
        return false
    }
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
    let bankedResetExpirations: [Int]
}

private struct DisplaySleep: Codable, Equatable {
    var enabled = false
    var startMinute = 23 * 60
    var endMinute = 7 * 60
    var timezone = TimeZone.current.identifier

    enum CodingKeys: String, CodingKey {
        case enabled, timezone
        case startMinute = "start_minute", endMinute = "end_minute"
    }

    var valid: Bool {
        (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute)
            && startMinute != endMinute && TimeZone(identifier: timezone) != nil
    }

    static func read(_ value: Any?) -> DisplaySleep? {
        guard let value = value as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: value),
              let schedule = try? JSONDecoder().decode(Self.self, from: data),
              schedule.valid else { return nil }
        return schedule
    }
}

private func displaySleepResponseError(
    data: Data?, response: URLResponse?, error: Error?, expected: DisplaySleep? = nil
) -> String? {
    if let error {
        return (error as? URLError)?.code == .timedOut
            ? "La source met trop de temps à répondre. Vérifiez la connexion, puis réessayez."
            : "La connexion à la source a été interrompue. Vérifiez qu’elle est joignable, puis réessayez."
    }
    guard let status = (response as? HTTPURLResponse)?.statusCode else {
        return "La source n’a pas renvoyé de réponse HTTP valide."
    }
    switch status {
    case 200: break
    case 401, 403: return "La source a refusé l’accès. Vérifiez le jeton dans « Source des quotas… »."
    case 400, 422: return "La source a refusé l’horaire. Vérifiez les heures et le fuseau horaire."
    default: return "La source a renvoyé une erreur HTTP \(status). Réessayez dans quelques instants."
    }
    guard let data,
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let display = root["display"] as? [String: Any] else {
        return "La réponse de la source est incomplète. Réessayez dans quelques instants."
    }
    guard display.keys.contains("sleep") else {
        return "Mettez à jour le Companion source pour configurer la veille."
    }
    if let expected, DisplaySleep.read(display["sleep"]) != expected {
        return "La source n’a pas confirmé l’horaire demandé. Rouvrez les réglages pour vérifier l’horaire enregistré."
    }
    return nil
}

private final class DisplaySleepFields: NSStackView {
    let enabled = NSButton(checkboxWithTitle: "Activer la veille quotidienne", target: nil, action: nil)
    let start = NSDatePicker()
    let end = NSDatePicker()
    private let timezone: String

    init(schedule: DisplaySleep) {
        timezone = schedule.timezone
        super.init(frame: NSRect(x: 0, y: 0, width: 350, height: 145))
        orientation = .vertical
        alignment = .leading
        spacing = 12
        enabled.state = schedule.enabled ? .on : .off
        enabled.target = self
        enabled.action = #selector(updateEnabled)
        addArrangedSubview(enabled)
        let calendar = Calendar.current
        for (picker, minute, label) in [(start, schedule.startMinute, "Éteindre à"),
                                        (end, schedule.endMinute, "Rallumer à")] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = .hourMinute
            picker.calendar = calendar
            picker.timeZone = calendar.timeZone
            picker.locale = Locale(identifier: "fr_CA")
            picker.dateValue = calendar.date(from: DateComponents(
                year: 2001, month: 1, day: 15, hour: minute / 60, minute: minute % 60
            ))!
            picker.setAccessibilityLabel(label)
        }
        let hours = NSGridView(views: [
            [NSTextField(labelWithString: "Éteindre à"), start],
            [NSTextField(labelWithString: "Rallumer à"), end],
        ])
        hours.rowSpacing = 8
        hours.heightAnchor.constraint(equalToConstant: 56).isActive = true
        addArrangedSubview(hours)
        let zone = NSTextField(labelWithString: "Fuseau horaire : \(timezone)")
        zone.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        zone.textColor = .secondaryLabelColor
        addArrangedSubview(zone)
        updateEnabled()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func updateEnabled() {
        start.isEnabled = enabled.state == .on
        end.isEnabled = enabled.state == .on
    }

    var schedule: DisplaySleep {
        let calendar = Calendar.current
        let minutes = [start, end].map {
            calendar.component(.hour, from: $0.dateValue) * 60
                + calendar.component(.minute, from: $0.dateValue)
        }
        return DisplaySleep(enabled: enabled.state == .on, startMinute: minutes[0],
                            endMinute: minutes[1], timezone: timezone)
    }
}

private func displaySleepIcon(screen: NSImage, brightness: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: 640, height: 196), flipped: true) { _ in
        NSColor(white: 0.35, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 640, height: 196), xRadius: 18, yRadius: 18).fill()
        NSColor(white: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 2, y: 2, width: 636, height: 192), xRadius: 16, yRadius: 16).fill()
        let lcd = NSRect(x: 10, y: 11, width: 620, height: 174)
        NSColor.black.setFill()
        lcd.fill()
        screen.draw(in: lcd, from: .zero, operation: .sourceOver, fraction: brightness,
                    respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        return true
    }
}

@MainActor
private final class DisplaySleepPanel: NSWindow, NSWindowDelegate {
    let fields: DisplaySleepFields
    private let preview = NSImageView()
    private let explanation = NSTextField(wrappingLabelWithString:
        "Tous les mini-écrans liés à cette source suivent cet horaire, même lorsque le Mac dort. Leur firmware doit prendre en charge la veille.")
    private var animation: Timer?

    init(schedule: DisplaySleep, snapshot: QuotaSnapshot?) {
        fields = DisplaySleepFields(schedule: schedule)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 460),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Veille des mini-écrans"
        isReleasedWhenClosed = false
        delegate = self
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setAccessibilityLabel("Aperçu du mini-écran qui s’éteint et se rallume")
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 17, weight: .semibold)
        explanation.font = .systemFont(ofSize: 13)
        explanation.textColor = .secondaryLabelColor
        let cancel = NSButton(title: "Annuler", target: self, action: #selector(cancelSchedule))
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Enregistrer", target: self, action: #selector(saveSchedule))
        save.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, save])
        let stack = NSStackView(views: [preview, heading, explanation, fields, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: contentView!.bottomAnchor, constant: -20),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(equalTo: preview.widthAnchor, multiplier: 196 / 640),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fields.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fields.heightAnchor.constraint(equalToConstant: 112),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        let miniature = QuotaDashboardView(frame: NSRect(x: 0, y: 0, width: 640, height: 180))
        miniature.snapshot = snapshot
        if let bitmap = miniature.bitmapImageRepForCachingDisplay(in: miniature.bounds) {
            miniature.cacheDisplay(in: miniature.bounds, to: bitmap)
            let screen = NSImage(size: miniature.bounds.size)
            screen.addRepresentation(bitmap)
            preview.image = displaySleepIcon(screen: screen, brightness: 1)
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let started = ProcessInfo.processInfo.systemUptime
                let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                    let phase = (ProcessInfo.processInfo.systemUptime - started).truncatingRemainder(dividingBy: 6)
                    let brightness = phase < 3 ? min(1, 3 - phase) : max(0, phase - 5)
                    self?.preview.image = displaySleepIcon(screen: screen, brightness: CGFloat(brightness))
                }
                RunLoop.main.add(timer, forMode: .modalPanel)
                animation = timer
            }
        }
    }

    func run() -> DisplaySleep? {
        center()
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let result = NSApp.runModal(for: self)
        animation?.invalidate()
        orderOut(nil)
        return result == .OK ? fields.schedule : nil
    }

    @objc private func saveSchedule() {
        makeFirstResponder(nil)
        guard fields.schedule.valid else {
            explanation.stringValue = "Choisissez deux heures différentes pour éteindre et rallumer les écrans."
            return
        }
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancelSchedule() { NSApp.stopModal(withCode: .cancel) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelSchedule()
        return true
    }
}

private struct QuotaSnapshot {
    let codex: ProviderQuotas
    let claude: ProviderQuotas
    let refreshedAt: Int?
    let apiAddress: String
    let displayCodex: Bool?
    let displayClaude: Bool?
    let sleep: DisplaySleep?
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
        bankedResets: resets?["available_count"] as? Int,
        bankedResetExpirations: (resets?["expirations"] as? [[String: Any]] ?? [])
            .compactMap { $0["expires_at"] as? Int }.filter { $0 > 0 }.sorted()
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
        displayClaude: display?["claude"] as? Bool,
        sleep: DisplaySleep.read(display?["sleep"])
    )
}

private func remainingText(_ window: QuotaWindow) -> String {
    window.remainingPercent.map { "\($0)%" } ?? "—%"
}

private func compactRemainingText(_ window: QuotaWindow, percent: Bool) -> String {
    guard let remaining = window.remainingPercent else { return percent ? "—%" : "—" }
    return "\(remaining)\(percent ? "%" : "")"
}

private let showCodexPreference = "display.showCodex"
private let showClaudePreference = "display.showClaude"
private let persistentWindowPreference = "display.persistentWindow"
private let alwaysOnTopPreference = "display.alwaysOnTop"

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

private func bankedResetRows(_ provider: ProviderQuotas?, now: Int = Int(Date().timeIntervalSince1970)) -> [String] {
    guard let count = provider?.bankedResets else { return ["Resets en banque non disponibles"] }
    guard count > 0 else { return ["Aucun reset en banque"] }
    guard let expirations = provider?.bankedResetExpirations, !expirations.isEmpty else {
        return ["Dates d’expiration non fournies"]
    }
    return expirations.enumerated().map { index, expiry in
        let remaining = expiry > now
            ? "Dans \(resetCountdown(QuotaWindow(usedPercent: nil, resetsAt: expiry), now: now))"
            : "Expiré"
        return "#\(index + 1)   \(dateText(expiry))   ·   \(remaining)"
    }
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

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let empty = QuotaWindow(usedPercent: nil, resetsAt: nil)
        if showCodex != showClaude {
            let useCodex = showCodex
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
        return formatter.string(from: date)
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

private func apiToken(_ value: String) -> String? {
    let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return (16...256).contains(token.utf8.count)
        && token.unicodeScalars.allSatisfy { (33...126).contains($0.value) } ? token : nil
}

// Adafruit GFX classic glyphs used by the mini-screen firmware (row 8 includes descenders).
private let miniScreenGlyphs: [Character: [UInt8]] = [
    " ": [0x00, 0x00, 0x00, 0x00, 0x00],
    "%": [0x23, 0x13, 0x08, 0x64, 0x62],
    "-": [0x08, 0x08, 0x08, 0x08, 0x08],
    "—": [0x08, 0x08, 0x08, 0x08, 0x08],
    ".": [0x00, 0x00, 0x60, 0x60, 0x00],
    ":": [0x00, 0x00, 0x14, 0x00, 0x00],
    "?": [0x02, 0x01, 0x59, 0x09, 0x06],
    "[": [0x00, 0x7F, 0x41, 0x41, 0x41],
    "]": [0x00, 0x41, 0x41, 0x41, 0x7F],
    "_": [0x40, 0x40, 0x40, 0x40, 0x40],
    "0": [0x3E, 0x51, 0x49, 0x45, 0x3E],
    "1": [0x00, 0x42, 0x7F, 0x40, 0x00],
    "2": [0x72, 0x49, 0x49, 0x49, 0x46],
    "3": [0x21, 0x41, 0x49, 0x4D, 0x33],
    "4": [0x18, 0x14, 0x12, 0x7F, 0x10],
    "5": [0x27, 0x45, 0x45, 0x45, 0x39],
    "6": [0x3C, 0x4A, 0x49, 0x49, 0x31],
    "7": [0x41, 0x21, 0x11, 0x09, 0x07],
    "8": [0x36, 0x49, 0x49, 0x49, 0x36],
    "9": [0x46, 0x49, 0x49, 0x29, 0x1E],
    "A": [0x7C, 0x12, 0x11, 0x12, 0x7C],
    "B": [0x7F, 0x49, 0x49, 0x49, 0x36],
    "C": [0x3E, 0x41, 0x41, 0x41, 0x22],
    "D": [0x7F, 0x41, 0x41, 0x41, 0x3E],
    "E": [0x7F, 0x49, 0x49, 0x49, 0x41],
    "F": [0x7F, 0x09, 0x09, 0x09, 0x01],
    "G": [0x3E, 0x41, 0x41, 0x51, 0x73],
    "H": [0x7F, 0x08, 0x08, 0x08, 0x7F],
    "I": [0x00, 0x41, 0x7F, 0x41, 0x00],
    "J": [0x20, 0x40, 0x41, 0x3F, 0x01],
    "K": [0x7F, 0x08, 0x14, 0x22, 0x41],
    "L": [0x7F, 0x40, 0x40, 0x40, 0x40],
    "M": [0x7F, 0x02, 0x1C, 0x02, 0x7F],
    "N": [0x7F, 0x04, 0x08, 0x10, 0x7F],
    "O": [0x3E, 0x41, 0x41, 0x41, 0x3E],
    "P": [0x7F, 0x09, 0x09, 0x09, 0x06],
    "Q": [0x3E, 0x41, 0x51, 0x21, 0x5E],
    "R": [0x7F, 0x09, 0x19, 0x29, 0x46],
    "S": [0x26, 0x49, 0x49, 0x49, 0x32],
    "T": [0x03, 0x01, 0x7F, 0x01, 0x03],
    "U": [0x3F, 0x40, 0x40, 0x40, 0x3F],
    "V": [0x1F, 0x20, 0x40, 0x20, 0x1F],
    "W": [0x3F, 0x40, 0x38, 0x40, 0x3F],
    "X": [0x63, 0x14, 0x08, 0x14, 0x63],
    "Y": [0x03, 0x04, 0x78, 0x04, 0x03],
    "Z": [0x61, 0x59, 0x49, 0x4D, 0x43],
    "a": [0x20, 0x54, 0x54, 0x78, 0x40],
    "b": [0x7F, 0x28, 0x44, 0x44, 0x38],
    "c": [0x38, 0x44, 0x44, 0x44, 0x28],
    "d": [0x38, 0x44, 0x44, 0x28, 0x7F],
    "e": [0x38, 0x54, 0x54, 0x54, 0x18],
    "è": [0x39, 0x55, 0x54, 0x54, 0x58],
    "f": [0x00, 0x08, 0x7E, 0x09, 0x02],
    "g": [0x18, 0xA4, 0xA4, 0x9C, 0x78],
    "h": [0x7F, 0x08, 0x04, 0x04, 0x78],
    "i": [0x00, 0x44, 0x7D, 0x40, 0x00],
    "j": [0x20, 0x40, 0x40, 0x3D, 0x00],
    "k": [0x7F, 0x10, 0x28, 0x44, 0x00],
    "l": [0x00, 0x41, 0x7F, 0x40, 0x00],
    "m": [0x7C, 0x04, 0x78, 0x04, 0x78],
    "n": [0x7C, 0x08, 0x04, 0x04, 0x78],
    "o": [0x38, 0x44, 0x44, 0x44, 0x38],
    "p": [0xFC, 0x18, 0x24, 0x24, 0x18],
    "q": [0x18, 0x24, 0x24, 0x18, 0xFC],
    "r": [0x7C, 0x08, 0x04, 0x04, 0x08],
    "s": [0x48, 0x54, 0x54, 0x54, 0x24],
    "t": [0x04, 0x04, 0x3F, 0x44, 0x24],
    "u": [0x3C, 0x40, 0x40, 0x20, 0x7C],
    "v": [0x1C, 0x20, 0x40, 0x20, 0x1C],
    "w": [0x3C, 0x40, 0x30, 0x40, 0x3C],
    "x": [0x44, 0x28, 0x10, 0x28, 0x44],
    "y": [0x4C, 0x90, 0x90, 0x90, 0x7C],
    "z": [0x44, 0x64, 0x54, 0x4C, 0x44],
]

// Same geometry and two-frame motion as drawCodexLogo/drawClaudeMascot in the firmware.
private func miniScreenProviderIcon(codex: Bool, frame: Int, color: NSColor, background: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 32, height: 26), flipped: true) { _ in
        let x: CGFloat = 16, y: CGFloat = 13
        let bob = CGFloat(frame & 1)
        color.setFill()
        if codex {
            let radius = 4 + bob
            let petals: [(CGFloat, CGFloat)] = [(0, -6), (5, -3), (5, 3), (0, 6), (-5, 3), (-5, -3)]
            for (dx, dy) in petals {
                NSBezierPath(ovalIn: NSRect(x: x + dx - radius, y: y + dy - radius, width: radius * 2, height: radius * 2)).fill()
            }
            NSBezierPath(ovalIn: NSRect(x: x - radius - 1, y: y - radius - 1, width: (radius + 1) * 2, height: (radius + 1) * 2)).fill()
            background.setStroke()
            let chevron = NSBezierPath()
            chevron.move(to: NSPoint(x: x - 5, y: y - 4))
            chevron.line(to: NSPoint(x: x - 2, y: y))
            chevron.line(to: NSPoint(x: x - 5, y: y + 4))
            chevron.stroke()
            background.setFill()
            NSRect(x: x + 1, y: y + 4, width: 6, height: 1).fill()
        } else {
            let top = y - 8 - bob
            NSRect(x: x - 10, y: top, width: 20, height: 13).fill()
            NSRect(x: x - 15, y: top + 5, width: 5, height: 5).fill()
            NSRect(x: x + 10, y: top + 5, width: 5, height: 5).fill()
            for (dx, height): (CGFloat, CGFloat) in [(-9, 6 - bob), (-4, 5 + bob), (3, 5 + bob), (8, 6 - bob)] {
                NSRect(x: x + dx, y: top + 13, width: 3, height: height).fill()
            }
            background.setFill()
            NSRect(x: x - 6, y: top + 3, width: 3, height: 3).fill()
            NSRect(x: x + 4, y: top + 3, width: 3, height: 3).fill()
        }
        return true
    }
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
    private let refreshSpinner = NSProgressIndicator()
    private var iconFrame = 0
    let refreshButton = NSButton()
    let bankedResetsButton = NSButton()
    private let bankedResetsScroll = NSScrollView()
    private let bankedResetsText = NSTextField(labelWithString: "")
    private(set) var showingBankedResets = false

    var apiOnline = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(accessibilitySummary)
        }
    }
    var snapshot: QuotaSnapshot? {
        didSet {
            updateBankedResets()
            needsDisplay = true
            setAccessibilityValue(accessibilitySummary)
        }
    }
    var showCodex = true {
        didSet {
            updateBankedResets()
            needsDisplay = true
            setAccessibilityValue(accessibilitySummary)
        }
    }
    var showClaude = true {
        didSet {
            updateBankedResets()
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
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        refreshButton.imagePosition = .imageOnly
        refreshButton.imageScaling = .scaleProportionallyDown
        refreshButton.isBordered = false
        refreshButton.contentTintColor = mutedColor
        refreshButton.toolTip = "Actualiser les quotas"
        refreshButton.setAccessibilityLabel("Actualiser les quotas")
        refreshButton.frame = NSRect(x: frameRect.width - 43, y: 183, width: 20, height: 20)
        refreshButton.autoresizingMask = [.minXMargin]
        addSubview(refreshButton)
        refreshSpinner.style = .spinning
        refreshSpinner.controlSize = .small
        refreshSpinner.isIndeterminate = true
        refreshSpinner.isDisplayedWhenStopped = false
        refreshSpinner.frame = NSRect(x: frameRect.width - 40, y: 186, width: 14, height: 14)
        refreshSpinner.autoresizingMask = [.minXMargin]
        refreshSpinner.setAccessibilityLabel("Actualisation des quotas en cours")
        addSubview(refreshSpinner)
        bankedResetsButton.title = ""
        bankedResetsButton.isBordered = false
        bankedResetsButton.target = self
        bankedResetsButton.action = #selector(toggleBankedResets)
        bankedResetsScroll.drawsBackground = false
        bankedResetsScroll.hasVerticalScroller = true
        bankedResetsScroll.autohidesScrollers = true
        bankedResetsScroll.documentView = bankedResetsText
        addSubview(bankedResetsScroll)
        addSubview(bankedResetsButton)
        updateBankedResets()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let target = super.hitTest(point) else { return nil }
        return showingBankedResets && NSApp?.currentEvent?.type == .scrollWheel
            ? bankedResetsScroll : target
    }

    @objc private func toggleBankedResets() {
        showingBankedResets.toggle()
        updateBankedResets()
        needsDisplay = true
        setAccessibilityValue(accessibilitySummary)
    }

    private func updateBankedResets() {
        let screen = bounds.insetBy(dx: 8, dy: 6)
        let codex = dashboardPanelRects(in: screen, showCodex: showCodex, showClaude: showClaude).codex
        if codex == nil { showingBankedResets = false }
        let full = dashboardPanelRects(in: screen, showCodex: true, showClaude: false).codex!
        bankedResetsButton.isHidden = codex == nil
        bankedResetsButton.frame = showingBankedResets ? bounds : codex ?? .zero
        let label = showingBankedResets ? "Cliquer n’importe où pour revenir aux quotas" : "Codex : voir les dates d’expiration des resets en banque"
        bankedResetsButton.toolTip = label
        bankedResetsButton.setAccessibilityLabel(label)
        bankedResetsButton.keyEquivalent = showingBankedResets ? "\u{1b}" : ""
        bankedResetsScroll.isHidden = !showingBankedResets
        guard showingBankedResets else { return }
        bankedResetsScroll.frame = NSRect(x: full.minX + 146, y: full.minY + 48, width: full.width - 158, height: 100)
        let rows = bankedResetRows(snapshot?.codex)
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 25
        style.maximumLineHeight = 25
        bankedResetsText.attributedStringValue = NSAttributedString(string: rows.joined(separator: "\n"), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: textColor, .paragraphStyle: style,
        ])
        bankedResetsText.frame = NSRect(x: 0, y: 0, width: bankedResetsScroll.contentSize.width, height: CGFloat(rows.count) * 25)
    }

    func setRefreshing(_ active: Bool) {
        refreshButton.isHidden = active
        active ? refreshSpinner.startAnimation(nil) : refreshSpinner.stopAnimation(nil)
    }

    func animateProviderIcons() {
        guard window?.isVisible == true, !isHiddenOrHasHiddenAncestor,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        iconFrame ^= 1
        let panels = dashboardPanelRects(in: bounds.insetBy(dx: 8, dy: 6), showCodex: showCodex, showClaude: showClaude)
        for rect in [panels.codex, panels.claude].compactMap({ $0 }) {
            setNeedsDisplay(NSRect(x: rect.minX + 6, y: rect.minY + 8, width: 32, height: 26))
        }
    }

    private var accessibilitySummary: String {
        guard let snapshot else { return "Chargement des quotas" }
        var parts: [String] = []
        if showingBankedResets {
            parts.append("Codex, \(snapshot.codex.bankedResets.map(String.init) ?? "—") resets en banque. " + bankedResetRows(snapshot.codex).joined(separator: ". "))
        } else if showCodex {
            parts.append("Codex, forfait \(snapshot.codex.plan ?? "inconnu"), 5 heures \(remainingText(snapshot.codex.fiveHour)), semaine \(remainingText(snapshot.codex.weekly)).")
        }
        if showClaude && !showingBankedResets {
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
            bankedResets: nil,
            bankedResetExpirations: []
        )
        let panels = dashboardPanelRects(in: screen, showCodex: showingBankedResets || showCodex, showClaude: !showingBankedResets && showClaude)
        if showingBankedResets, let rect = panels.codex {
            drawBankedResets(in: rect)
        } else if let rect = panels.codex {
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
        drawMiniScreenText(
            "Dernière actualisation : \(dateText(snapshot?.refreshedAt, timeOnly: true))",
            in: NSRect(x: screen.minX + 12, y: 187, width: screen.width - 55, height: 12),
            scale: 1.5,
            color: mutedColor,
            alignment: .right
        )
        trackColor.setFill()
        NSRect(x: screen.minX + 12, y: 208, width: screen.width - 24, height: 1).fill()
        drawAPIStatus(y: 219)
    }

    private func drawBankedResets(in rect: NSRect) {
        NSColor(srgbRed: 8 / 255, green: 29 / 255, blue: 48 / 255, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
        codexColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 4), xRadius: 2, yRadius: 2).fill()
        miniScreenProviderIcon(codex: true, frame: iconFrame, color: codexColor, background: screenColor).draw(
            in: NSRect(x: rect.minX + 6, y: rect.minY + 8, width: 32, height: 26),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
        drawMiniScreenText("RESETS EN BANQUE", in: NSRect(x: rect.minX + 44, y: rect.minY + 12, width: 250, height: 14), scale: 2, color: textColor)
        drawText("Cliquer pour revenir", in: NSRect(x: rect.maxX - 130, y: rect.minY + 12, width: 116, height: 16), font: .systemFont(ofSize: 11, weight: .medium), color: codexColor, alignment: .right)
        drawMiniScreenText(snapshot?.codex.bankedResets.map(String.init) ?? "—", in: NSRect(x: rect.minX + 24, y: rect.minY + 58, width: 98, height: 35), scale: 5, color: codexColor, alignment: .center)
        drawText("DISPONIBLES", in: NSRect(x: rect.minX + 14, y: rect.minY + 111, width: 118, height: 12), font: .systemFont(ofSize: 9, weight: .bold), color: mutedColor, alignment: .center)
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

        miniScreenProviderIcon(codex: codex, frame: iconFrame, color: accent, background: screenColor).draw(
            in: NSRect(x: rect.minX + 6, y: rect.minY + 8, width: 32, height: 26),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
        drawMiniScreenText(
            title,
            in: NSRect(x: rect.minX + 44, y: rect.minY + 12, width: CGFloat(title.count * 12), height: 14),
            scale: 2,
            color: textColor
        )
        let plan = provider.plan?.uppercased() ?? "—"
        let planFont = NSFont.systemFont(ofSize: 9, weight: .bold)
        let planX = rect.minX + 52 + CGFloat(title.count * 12)
        let planWidth = ceil((plan as NSString).size(withAttributes: [.font: planFont]).width) + 12
        let planRect = NSRect(x: planX, y: rect.minY + 11, width: min(planWidth, rect.maxX - 26 - planX), height: 18)
        cellColor.setFill()
        NSBezierPath(roundedRect: planRect, xRadius: 9, yRadius: 9).fill()
        drawText(
            plan,
            in: planRect.insetBy(dx: 5, dy: 3),
            font: planFont,
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
        drawMiniScreenText(
            remainingText(window),
            in: NSRect(x: rect.minX + 8, y: rect.minY + 19, width: rect.width - 16, height: 25),
            scale: 3,
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
            in: NSRect(x: rect.minX + 8, y: rect.minY + 73, width: rect.width - 16, height: 14),
            font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
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
        drawMiniScreenText(
            remainingText(window),
            in: NSRect(x: rect.maxX - 38, y: y - 1, width: 28, height: 13),
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
        drawText("Voir les dates ›", in: NSRect(x: rect.maxX - 112, y: y, width: 102, height: 12), font: .systemFont(ofSize: 9, weight: .medium), color: accent, alignment: .right)
    }

    private func quotaColor(_ percent: Int?) -> NSColor {
        guard let percent else { return mutedColor }
        if percent <= 20 { return redColor }
        if percent <= 50 { return amberColor }
        return greenColor
    }

    private func drawMiniScreenText(
        _ value: String,
        in rect: NSRect,
        scale: CGFloat = 1,
        color: NSColor,
        alignment: NSTextAlignment = .left
    ) {
        let characters = Array(value == "—%" ? "--" : value)
        let width = CGFloat(max(0, characters.count * 6 - 1)) * scale
        let x = alignment == .right ? rect.maxX - width
            : alignment == .center ? rect.midX - width / 2
            : rect.minX
        color.setFill()
        for (index, character) in characters.enumerated() {
            let columns = miniScreenGlyphs[character] ?? miniScreenGlyphs["?"]!
            for (column, bits) in columns.enumerated() {
                for row in 0..<8 where bits & (1 << row) != 0 {
                    NSRect(
                        x: x + CGFloat(index * 6 + column) * scale,
                        y: rect.minY + CGFloat(row) * scale,
                        width: scale,
                        height: scale
                    ).fill()
                }
            }
        }
    }

    private func statusColor(_ status: String) -> NSColor {
        status == "ok" ? greenColor : status == "stale" ? amberColor : redColor
    }

    private func drawAPIStatus(y: CGFloat) {
        let color = apiOnline ? greenColor : redColor
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 22, y: y + 4, width: 7, height: 7)).fill()
        let status = "  -  \(apiOnline ? "En ligne" : "Hors ligne")"
        let address = "[\(snapshot?.apiAddress ?? "port 8788")]"
        let maxAddressLength = max(3, Int((bounds.width - 118 - CGFloat(status.count * 12)) / 9))
        let endpoint = address.count > maxAddressLength ? String(address.prefix(maxAddressLength - 3)) + "..." : address
        let parts: [(String, CGFloat, NSColor)] = [
            ("API  ", 2, mutedColor),
            (endpoint, 1.5, mutedColor.withAlphaComponent(0.72)),
            (status, 2, color),
        ]
        var x: CGFloat = 36
        for (text, scale, tint) in parts {
            drawMiniScreenText(text, in: NSRect(x: x, y: y + (scale < 2 ? 2 : 0), width: bounds.width - x - 22, height: 16), scale: scale, color: tint)
            x += CGFloat(text.count * 6) * scale
        }
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
    private let refreshItem = NSMenuItem(title: "Actualiser les quotas", action: nil, keyEquivalent: "r")
    private let sourceItem = NSMenuItem(title: "Source des quotas…", action: nil, keyEquivalent: "")
    private let sleepItem = NSMenuItem(title: "Veille des mini-écrans…", action: nil, keyEquivalent: "")
    private var designerWindow: DesignerWindow?
    private let copyAPIItem = NSMenuItem(title: "Copier la configuration API", action: nil, keyEquivalent: "")
    private let serverKeyItem = NSMenuItem(title: "Clé API de ce Mac…", action: nil, keyEquivalent: "")
    private let autoLaunchItem = NSMenuItem(title: "Démarrer l’API avec la session", action: nil, keyEquivalent: "")
    private let updatesItem = NSMenuItem(title: "Mises à jour", action: nil, keyEquivalent: "")
    private let checkUpdateItem = NSMenuItem(title: "Vérifier les mises à jour…", action: nil, keyEquivalent: "")
    private let automaticUpdateItem = NSMenuItem(title: "Vérifier automatiquement", action: nil, keyEquivalent: "")
    private let diagnosticsItem = NSMenuItem(title: "Partager les erreurs techniques", action: nil, keyEquivalent: "")
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
    private var quotaRequestID: UUID?
    private var quotaRetry: DispatchWorkItem?
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
        let iconTimer = Timer(timeInterval: 0.9, target: self, selector: #selector(animateProviderIcons), userInfo: nil, repeats: true)
        iconTimer.tolerance = 0.05
        RunLoop.main.add(iconTimer, forMode: .common)
        RunLoop.main.add(iconTimer, forMode: .eventTracking)
        _ = quotaTimer(interval: 60) { [weak self] _ in
            Task { @MainActor in self?.loadQuotas() }
        }
        _ = quotaTimer(interval: 300) { [weak self] _ in
            Task { @MainActor in
                self?.checkAuthentication(autoPrompt: true)
                self?.refreshClaudeDesktopIfAuthorized()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(resumeQuotaRefresh), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    @objc private func resumeQuotaRefresh() {
        loadQuotas()
        refreshQuotas()
    }

    @objc private func toggleDiagnostics() {
        do {
            if FileManager.default.fileExists(atPath: QuotaDiagnostics.disabledURL.path) {
                try FileManager.default.removeItem(at: QuotaDiagnostics.disabledURL)
            } else {
                try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
                try writePrivate("disabled", to: QuotaDiagnostics.disabledURL)
            }
            diagnosticsItem.state = FileManager.default.fileExists(atPath: QuotaDiagnostics.disabledURL.path) ? .off : .on
        } catch { showSourceError("Le réglage de diagnostic n’a pas pu être enregistré.") }
    }

    @objc private func animateProviderIcons() {
        dashboard.animateProviderIcons()
        persistentDashboard.animateProviderIcons()
    }

    private func configureMenu() {
        for view in [dashboard, persistentDashboard] {
            view.refreshButton.target = self
            view.refreshButton.action = #selector(refreshQuotas)
        }
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
        let options = NSMenu(title: "Paramètres")
        refreshItem.target = self
        refreshItem.action = #selector(refreshQuotas)
        options.addItem(refreshItem)
        options.addItem(.separator())
        let display = NSMenu(title: "Affichage")
        showCodexItem.target = self
        showCodexItem.action = #selector(toggleCodexVisibility)
        display.addItem(showCodexItem)
        showClaudeItem.target = self
        showClaudeItem.action = #selector(toggleClaudeVisibility)
        display.addItem(showClaudeItem)
        display.addItem(.separator())
        persistentWindowItem.target = self
        persistentWindowItem.action = #selector(togglePersistentWindow)
        display.addItem(persistentWindowItem)
        alwaysOnTopItem.target = self
        alwaysOnTopItem.action = #selector(toggleAlwaysOnTop)
        display.addItem(alwaysOnTopItem)
        options.addItem(withTitle: "Affichage", action: nil, keyEquivalent: "").submenu = display
        let api = NSMenu(title: "API et connexions")
        sourceItem.target = self
        sourceItem.action = #selector(chooseQuotaSource)
        api.addItem(sourceItem)
        copyAPIItem.target = self
        copyAPIItem.action = #selector(copyAPIConfiguration)
        copyAPIItem.toolTip = "Copie l’adresse et le jeton nécessaires aux mini-écrans et aux Companions distants."
        api.addItem(copyAPIItem)
        serverKeyItem.target = self
        serverKeyItem.action = #selector(editServerAPIKey)
        api.addItem(serverKeyItem)
        autoLaunchItem.target = self
        autoLaunchItem.action = #selector(toggleAutoLaunch)
        autoLaunchItem.state = .mixed
        autoLaunchItem.toolTip = "Contrôle le démarrage du pont API Python à la prochaine ouverture de session."
        api.addItem(autoLaunchItem)
        let updates = NSMenu()
        checkUpdateItem.target = self
        checkUpdateItem.action = #selector(checkUpdates)
        updates.addItem(checkUpdateItem)
        automaticUpdateItem.target = self
        automaticUpdateItem.action = #selector(toggleAutomaticUpdateChecks)
        automaticUpdateItem.state = updaterController.updater.automaticallyChecksForUpdates ? .on : .off
        updates.addItem(automaticUpdateItem)
        updates.addItem(.separator())
        diagnosticsItem.target = self
        diagnosticsItem.action = #selector(toggleDiagnostics)
        diagnosticsItem.state = FileManager.default.fileExists(atPath: QuotaDiagnostics.disabledURL.path) ? .off : .on
        diagnosticsItem.toolTip = "Envoie les erreurs, la version et l’ancienneté des quotas à GlitchTip. Aucun jeton, compte ou contenu de conversation."
        updates.addItem(diagnosticsItem)
        updatesItem.submenu = updates
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
        api.addItem(.separator())
        api.addItem(connectionsItem)
        options.addItem(withTitle: "API et connexions", action: nil, keyEquivalent: "").submenu = api
        let screens = NSMenu(title: "Mini-écrans")
        let designerItem = NSMenuItem(title: "Designer…", action: #selector(openDesigner), keyEquivalent: "")
        designerItem.target = self
        screens.addItem(designerItem)
        sleepItem.target = self
        sleepItem.action = #selector(chooseDisplaySleep)
        screens.addItem(sleepItem)
        options.addItem(withTitle: "Mini-écrans", action: nil, keyEquivalent: "").submenu = screens
        options.addItem(updatesItem)
        options.addItem(.separator())
        let aboutItem = NSMenuItem(title: "À propos de Quota Display", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        options.addItem(aboutItem)
        let quitItem = NSMenuItem(title: "Quitter Quota Display", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        options.addItem(quitItem)
        let optionsItem = NSMenuItem(title: "Paramètres", action: nil, keyEquivalent: "")
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

        showCodexItem.state = showCodex ? .on : .off
        showClaudeItem.state = showClaude ? .on : .off
        persistentWindowItem.state = defaults.bool(forKey: persistentWindowPreference) ? .on : .off
        alwaysOnTopItem.state = defaults.bool(forKey: alwaysOnTopPreference) ? .on : .off

        dashboard.showCodex = showCodex
        dashboard.showClaude = showClaude
        persistentDashboard.showCodex = showCodex
        persistentDashboard.showClaude = showClaude
        compactStatus.showCodex = showCodex
        compactStatus.showClaude = showClaude
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
            let address = source.remote ? source.url.absoluteString : snapshot?.apiAddress,
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

    @objc private func editServerAPIKey() {
        let tokenURL = appSupportURL.appendingPathComponent("token")
        let alert = NSAlert()
        alert.messageText = "Clé API de ce Mac"
        alert.informativeText = "Les mini-écrans et les Companions connectés à ce Mac doivent utiliser cette même clé. Vous pouvez remettre une ancienne clé après une réinstallation."
            + (configuredBridgeSource.remote ? " Pour modifier la clé de votre source distante, ouvrez ce réglage sur le Mac source." : "")
        alert.addButton(withTitle: "Enregistrer")
        alert.addButton(withTitle: "Annuler")
        let field = NSSecureTextField(string: (try? String(contentsOf: tokenURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        field.placeholderString = "Clé API : 16 à 256 caractères, sans espace"
        field.setAccessibilityLabel("Clé API du serveur de ce Mac")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let token = apiToken(field.stringValue) else {
            showSourceError("La clé doit contenir de 16 à 256 caractères non accentués, sans espace.", title: "Clé API de ce Mac")
            return
        }
        do {
            try FileManager.default.createDirectory(at: appSupportURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try writePrivate(token, to: tokenURL)
            if !configuredBridgeSource.remote { loadQuotas() }
        } catch {
            showSourceError("La clé API n’a pas pu être enregistrée.", title: "Clé API de ce Mac")
        }
    }

    private func restoreCopyAPITitle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.copyAPIItem.title = "Copier la configuration API"
        }
    }

    @objc private func chooseDisplaySleep() {
        guard var request = bridgeRequest(path: "/v1/quotas") else {
            showSleepMessage("La configuration API n’est pas disponible.")
            return
        }
        let sourceURL = configuredBridgeSource.url
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        sleepItem.isEnabled = false
        quotaSession.dataTask(with: request) { [weak self] data, response, error in
            let failure = displaySleepResponseError(data: data, response: response, error: error)
            if failure != nil {
                NSLog("Sleep settings read failed: HTTP %ld, network error %ld",
                      (response as? HTTPURLResponse)?.statusCode ?? 0, (error as NSError?)?.code ?? 0)
            }
            let snapshot = data.flatMap(quotaSnapshot)
            DispatchQueue.main.async {
                guard let self else { return }
                self.sleepItem.isEnabled = true
                guard self.configuredBridgeSource.url == sourceURL else { return }
                if let failure {
                    self.showSleepMessage(failure)
                } else if let snapshot {
                    self.editDisplaySleep(snapshot: snapshot, sourceURL: sourceURL)
                } else {
                    self.showSleepMessage("La réponse de la source est incomplète. Réessayez dans quelques instants.")
                }
            }
        }.resume()
    }

    private func editDisplaySleep(snapshot: QuotaSnapshot, sourceURL: URL) {
        let panel = DisplaySleepPanel(schedule: snapshot.sleep ?? DisplaySleep(), snapshot: snapshot)
        guard let schedule = panel.run() else { return }
        guard configuredBridgeSource.url == sourceURL,
              var request = bridgeRequest(path: "/v1/display", method: "POST"),
              let value = try? JSONEncoder().encode(schedule),
              let object = try? JSONSerialization.jsonObject(with: value) else {
            showSleepMessage("La configuration API n’est pas disponible.")
            return
        }
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["sleep": object])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        sleepItem.isEnabled = false
        quotaSession.dataTask(with: request) { [weak self] data, response, error in
            let failure = displaySleepResponseError(data: data, response: response, error: error, expected: schedule)
            if failure != nil {
                NSLog("Sleep settings save failed: HTTP %ld, network error %ld",
                      (response as? HTTPURLResponse)?.statusCode ?? 0, (error as NSError?)?.code ?? 0)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.sleepItem.isEnabled = true
                guard self.configuredBridgeSource.url == sourceURL else { return }
                self.loadQuotas()
                self.showSleepMessage(failure
                    ?? "Horaire enregistré. Les mini-écrans l’appliqueront à leur prochaine synchronisation.")
            }
        }.resume()
    }

    private func showSleepMessage(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Veille des mini-écrans"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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

        quotaRequestID = nil
        bridgeOnline = false
        snapshot = nil
        dashboard.snapshot = nil
        dashboard.apiOnline = false
        persistentDashboard.snapshot = nil
        persistentDashboard.apiOnline = false
        updateSourceItems()
        checkAuthentication(autoPrompt: false)
        loadQuotas()
        if !remote { refreshQuotas() }
        renderStatusTitle()
    }

    private func writePrivate(_ value: String, to url: URL) throws {
        try Data((value + "\n").utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func showSourceError(_ message: String, title: String = "Source des quotas") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
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
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    @objc private func openDesigner() {
        guard let request = bridgeRequest(path: "/designer/") else {
            showSourceError("Configurez la connexion à votre source avant d’ouvrir le Designer.")
            return
        }
        if let designerWindow, designerWindow.window?.isVisible == true {
            designerWindow.showWindow(nil)
        } else {
            designerWindow = DesignerWindow(request: request)
            designerWindow?.showWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
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
        quotaSession.dataTask(with: request) { [weak self] _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                if !ok { NSSound.beep() }
                self?.loadQuotas()
            }
        }.resume()
    }

    private func loadQuotas(retryAttempt: Int = 0) {
        guard quotaRequestID == nil else { return }
        quotaRetry?.cancel()
        quotaRetry = nil
        let sourceURL = configuredBridgeSource.url
        let requestedDisplayRevision = displayRevision
        guard let request = bridgeRequest(path: "/v1/quotas") else {
            QuotaDiagnostics.shared.capture("bridge_read", failure: "configuration_unavailable", remote: configuredBridgeSource.remote)
            bridgeOnline = false
            dashboard.apiOnline = false
            persistentDashboard.apiOnline = false
            renderStatusTitle()
            return
        }
        let requestID = UUID()
        quotaRequestID = requestID
        quotaSession.dataTask(with: request) { [weak self] data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode
            let loaded = code == 200 && error == nil ? data.flatMap(quotaSnapshot(from:)) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.quotaRequestID == requestID else { return }
                self.quotaRequestID = nil
                guard self.configuredBridgeSource.url == sourceURL else { return }
                self.bridgeOnline = code == 200 && loaded != nil
                self.dashboard.apiOnline = self.bridgeOnline
                self.persistentDashboard.apiOnline = self.bridgeOnline
                if !self.bridgeOnline {
                    if let delay = quotaRetryDelay(error: error, attempt: retryAttempt) {
                        let retry = DispatchWorkItem { [weak self] in
                            guard self?.configuredBridgeSource.url == sourceURL else { return }
                            self?.loadQuotas(retryAttempt: retryAttempt + 1)
                        }
                        self.quotaRetry = retry
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retry)
                    } else {
                        QuotaDiagnostics.shared.capture("bridge_read",
                            failure: QuotaDiagnostics.failure(error, status: code == 200 ? nil : code),
                            remote: self.configuredBridgeSource.remote)
                    }
                } else if let data {
                    for failure in quotaFreshnessFailures(data) {
                        QuotaDiagnostics.shared.capture(failure.operation, failure: "stale",
                            remote: self.configuredBridgeSource.remote, age: failure.age)
                    }
                }
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
        let versionChanged = previous != nil && previous != version
        let bundledBridge = Bundle.main.url(forResource: "quota_bridge", withExtension: "py")
        let launchAgent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(bridgeLabel).plist")
        DispatchQueue.global(qos: .utility).async { [launchDomain, bridgeLabel] in
            guard let installedBridge = installedBridgeURL(in: try? Data(contentsOf: launchAgent)) else { return }
            var bridgeUpdated = false
            if let resources = bundledBridge?.deletingLastPathComponent(), resources != installedBridge.deletingLastPathComponent() {
                let names = ["designer.py", "designer_integrations.py"] + ((try? FileManager.default.subpathsOfDirectory(atPath: resources.appendingPathComponent("designer").path)) ?? []).map { "designer/" + $0 }
                for name in names {
                    let source = resources.appendingPathComponent(name)
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
                    let target = installedBridge.deletingLastPathComponent().appendingPathComponent(name)
                    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    bridgeUpdated = updateInstalledBridge(from: source, to: target) || bridgeUpdated
                }
            }
            bridgeUpdated = updateInstalledBridge(from: bundledBridge, to: installedBridge) || bridgeUpdated
            guard versionChanged || bridgeUpdated else { return }
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

    private func setRefreshAnimation(_ active: Bool) {
        dashboard.setRefreshing(active)
        persistentDashboard.setRefreshing(active)
    }

    @objc private func refreshQuotas() {
        setRefreshAnimation(true)
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
                    QuotaDiagnostics.shared.capture("claude_credentials", failure: QuotaDiagnostics.failure(error), remote: false)
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
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        quotaSession.dataTask(with: request) { [weak self] data, response, error in
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
                    QuotaDiagnostics.shared.capture("claude_usage",
                        failure: QuotaDiagnostics.failure(error, status: (200...299 ~= status) || status == 0 ? nil : status), remote: false)
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
                        QuotaDiagnostics.shared.capture("claude_cache_write", failure: QuotaDiagnostics.failure(error), remote: false)
                        completion(false, error.localizedDescription)
                    }
                }

                guard initialValue["plan"] == nil else {
                    finish(initialValue)
                    return
                }
                var profileRequest = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!, timeoutInterval: 20)
                profileRequest.setValue("application/json", forHTTPHeaderField: "Accept")
                profileRequest.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
                profileRequest.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                profileRequest.setValue("claude-cli (external, cli)", forHTTPHeaderField: "User-Agent")
                quotaSession.dataTask(with: profileRequest) { profileData, profileResponse, _ in
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
            setRefreshAnimation(false)
            return
        }
        refreshItem.title = "Actualisation en cours…"
        let remote = configuredBridgeSource.remote
        quotaSession.dataTask(with: request) { [weak self] _, response, error in
            let ok = (response as? HTTPURLResponse)?.statusCode == 202
            if !ok {
                QuotaDiagnostics.shared.capture("bridge_refresh",
                    failure: QuotaDiagnostics.failure(error, status: (response as? HTTPURLResponse)?.statusCode), remote: remote)
            }
            DispatchQueue.main.async {
                self?.refreshItem.title = ok ? "Actualisation lancée ✓" : "Pont indisponible"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self?.refreshItem.title = "Actualiser les quotas"
                    self?.setRefreshAnimation(false)
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
        if CommandLine.arguments.contains("--diagnostics-test") {
            QuotaDiagnostics.shared.capture("diagnostic_smoke_test", failure: "synthetic", remote: false)
            RunLoop.current.run(until: Date().addingTimeInterval(12))
            print("Diagnostic test completed; verify reception in GlitchTip.")
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            precondition(apiToken("  existing-api-key-1234\n") == "existing-api-key-1234")
            for invalid in ["", "too-short", "api key with spaces", "api-key-with-é-1234", "api-key\nwith-newline-1234", String(repeating: "a", count: 257)] {
                precondition(apiToken(invalid) == nil)
            }
            precondition(quotaRetryDelay(error: URLError(.cannotConnectToHost), attempt: 0) == 5)
            precondition(quotaRetryDelay(error: URLError(.notConnectedToInternet), attempt: 1) == 10)
            precondition(quotaRetryDelay(error: URLError(.timedOut), attempt: 2) == nil)
            precondition(quotaRetryDelay(error: URLError(.userAuthenticationRequired), attempt: 0) == nil)
            precondition(quotaRetryDelay(error: nil, attempt: 0) == nil)
            let sensitiveError = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [
                NSLocalizedDescriptionKey: "Bearer test-secret user@example.test /Users/private",
                NSURLErrorFailingURLStringErrorKey: "http://private-host/?token=test-secret",
            ])
            let diagnostic = QuotaDiagnostics.shared.event("bridge_read",
                failure: QuotaDiagnostics.failure(sensitiveError), remote: true, age: 1000)
            let diagnosticJSON = String(data: try! JSONSerialization.data(withJSONObject: diagnostic), encoding: .utf8)!
            precondition(!["test-secret", "user@example", "/Users/private", "private-host"].contains { diagnosticJSON.contains($0) })
            precondition(QuotaDiagnostics.failure(ClaudeDesktopError.noAccount) == "credential_missing_or_expired")
            precondition(QuotaDiagnostics.failure(nil, status: 401) == "http_401")
            let staleData = Data(#"{"server_time":2000,"refresh":{"active":true,"started_at":1800,"completed_at":900},"display":{"claude":false},"providers":{"codex":{"status":"stale","updated_at":900},"claude":{"status":"error"}}}"#.utf8)
            precondition(quotaFreshnessFailures(staleData).map(\.operation) == ["refresh_stalled", "refresh_overdue", "codex_quotas_stale"])
            precondition(quotaFreshnessFailures(Data(#"{"server_time":2000,"refresh":{"completed_at":1990},"providers":{"codex":{"status":"ok","updated_at":1990}}}"#.utf8)).isEmpty)
            precondition(quotaFreshnessFailures(Data("invalid".utf8)).isEmpty)
            var trackingTimerFired = false
            let trackingTimer = quotaTimer(interval: 0.01) { _ in trackingTimerFired = true }
            let trackingDeadline = Date().addingTimeInterval(0.15)
            while !trackingTimerFired && Date() < trackingDeadline {
                RunLoop.main.run(mode: .eventTracking, before: trackingDeadline)
            }
            trackingTimer.invalidate()
            guard trackingTimerFired else { exit(1) }
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
            let sample = #"{"api":{"status":"online","address":"192.168.1.252:8788"},"display":{"codex":true,"claude":false},"refresh":{"completed_at":1785776996},"providers":{"codex":{"status":"ok","plan":"Pro 20X","five_hour":{"used_percent":null,"resets_at":null},"weekly":{"used_percent":7,"resets_at":1786172449},"fable_weekly":{"used_percent":null,"resets_at":null},"banked_resets":{"available_count":2,"expirations":[{"expires_at":1791173954},{"expires_at":1791080428}]}},"claude":{"status":"ok","plan":"Max 5X","five_hour":{"used_percent":0,"resets_at":null},"weekly":{"used_percent":15,"resets_at":1785859200},"fable_weekly":{"used_percent":28,"resets_at":1785859200}}}}"#
            let quotas = quotaSnapshot(from: Data(sample.utf8))
            let sleep = DisplaySleep(enabled: true, startMinute: 1380, endMinute: 420, timezone: "America/Toronto")
            let sleepFields = DisplaySleepFields(schedule: sleep)
            let sleepRoundTrip = (try? JSONEncoder().encode(sleep))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) }
                .flatMap(DisplaySleep.read)
            var sleepingSample = (try? JSONSerialization.jsonObject(with: Data(sample.utf8))) as? [String: Any] ?? [:]
            sleepingSample["display"] = ["codex": true, "claude": false,
                                        "sleep": ["enabled": true, "start_minute": 1380,
                                                  "end_minute": 420, "timezone": "America/Toronto",
                                                  "tz": "EST5EDT,M3.2.0,M11.1.0"]]
            let sleepingData = try? JSONSerialization.data(withJSONObject: sleepingSample)
            let sleepingQuotas = sleepingData.flatMap(quotaSnapshot)
            func sleepFailure(_ data: Data?, status: Int = 200, error: Error? = nil,
                              expected: DisplaySleep? = nil) -> String? {
                displaySleepResponseError(data: data, response: HTTPURLResponse(
                    url: URL(string: "http://127.0.0.1:8788/v1/display")!,
                    statusCode: status, httpVersion: nil, headerFields: nil
                ), error: error, expected: expected)
            }
            let sleepResponsesValid = sleepFailure(sleepingData, expected: sleep) == nil
                && sleepFailure(Data(#"{"display":{"sleep":null}}"#.utf8)) == nil
                && sleepFailure(Data(sample.utf8))?.contains("Mettez à jour") == true
                && sleepFailure(sleepingData, error: URLError(.timedOut))?.contains("trop de temps") == true
                && sleepFailure(nil, error: URLError(.notConnectedToInternet))?.contains("connexion") == true
                && [401, 403].allSatisfy { sleepFailure(nil, status: $0)?.contains("jeton") == true }
                && [400, 422].allSatisfy { sleepFailure(nil, status: $0)?.contains("refusé l’horaire") == true }
                && [404, 500, 503].allSatisfy { sleepFailure(nil, status: $0)?.contains("HTTP \($0)") == true }
                && sleepFailure(Data("invalid JSON".utf8))?.contains("incomplète") == true
                && sleepFailure(sleepingData, expected: DisplaySleep())?.contains("pas confirmé") == true
            let desktopSample = #"{"subscription_type":"max","organization":{"rate_limit_tier":"default_claude_max_5x"},"five_hour":{"utilization":12.8,"resets_at":"2026-09-02T22:00:00Z"},"seven_day":{"utilization":39,"resets_at":"2026-09-08T04:00:00Z"},"seven_day_fable":{"utilization":81,"resets_at":"2026-09-08T04:00:00Z"}}"#
            let desktopQuotas = claudeDesktopQuotaSnapshot(from: Data(desktopSample.utf8))
            let desktopLimitsSample = #"{"limits":[{"kind":"weekly_scoped","percent":65,"resets_at":"2026-09-08T16:00:00Z","scope":{"model":{"display_name":"Fable"}}}]}"#
            let desktopLimitsQuotas = claudeDesktopQuotaSnapshot(from: Data(desktopLimitsSample.utf8))
            let bridgeTestRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let bridgeTestSource = bridgeTestRoot.appendingPathComponent("source.py")
            let bridgeTestDestination = bridgeTestRoot.appendingPathComponent("destination.py")
            let expectedBridge = Data("new bridge".utf8)
            try? FileManager.default.createDirectory(at: bridgeTestRoot, withIntermediateDirectories: true)
            try? expectedBridge.write(to: bridgeTestSource)
            try? Data("old bridge".utf8).write(to: bridgeTestDestination)
            let bridgeUpdated = updateInstalledBridge(from: bridgeTestSource, to: bridgeTestDestination)
                && (try? Data(contentsOf: bridgeTestDestination)) == expectedBridge
            let bridgePaths = [
                "/Users/test/.local/share/quota-display/quota_bridge.py",
                "/Users/test/Library/Application Support/Quota Display/quota_bridge.py",
                "/Applications/Quota Display.app/Contents/Resources/quota_bridge.py",
            ]
            let installedBridgePathsFound = bridgePaths.allSatisfy { path in
                let agent = try? PropertyListSerialization.data(
                    fromPropertyList: ["ProgramArguments": ["/usr/bin/python3", path, "--token-file", "/tmp/token"]],
                    format: .xml, options: 0
                )
                return installedBridgeURL(in: agent)?.path == path
            }
            try? FileManager.default.removeItem(at: bridgeTestRoot)
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
            let dashboardView = QuotaDashboardView(frame: NSRect(x: 0, y: 0, width: 640, height: 250))
            let dashboardHost = NSView(frame: dashboardView.frame)
            dashboardHost.addSubview(dashboardView)
            let statusView = CompactStatusView(frame: NSRect(x: 0, y: 0, width: 90, height: 22))
            statusView.snapshot = quotas
            let statusSnapshots = [(true, true), (true, false), (false, true), (true, true)].compactMap { codex, claude -> Data? in
                statusView.showCodex = codex
                statusView.showClaude = claude
                guard let bitmap = statusView.bitmapImageRepForCachingDisplay(in: statusView.bounds) else { return nil }
                statusView.cacheDisplay(in: statusView.bounds, to: bitmap)
                return bitmap.tiffRepresentation
            }
            let providerGlyphsPresent = "CODEXCLAUDE".allSatisfy { miniScreenGlyphs[$0]?.count == 5 }
            let footerGlyphsPresent = "Dernière actualisation : 08:15 API [Mac.local:8788] En ligne Hors ligne —".allSatisfy {
                miniScreenGlyphs[$0]?.count == 5
            }
            let providerIconsAnimate = [true, false].allSatisfy { codex in
                let frames = (0...2).map {
                    miniScreenProviderIcon(codex: codex, frame: $0, color: .white, background: .black).tiffRepresentation
                }
                return frames[0] != nil && frames[1] != nil && frames[0] != frames[1] && frames[0] == frames[2]
            }
            dashboardView.snapshot = quotas
            precondition(quotas?.codex.bankedResetExpirations == [1791080428, 1791173954])
            let resetRows = bankedResetRows(quotas?.codex, now: 1791080428 - 9000)
            precondition(resetRows.count == 2 && resetRows[0].contains(dateText(1791080428)) && resetRows[0].hasSuffix("Dans 2h 30m"))
            precondition(bankedResetRows(quotas?.codex, now: 1791080428)[0].hasSuffix("Expiré"))
            precondition(bankedResetRows(nil) == ["Resets en banque non disponibles"])
            precondition(bankedResetRows(providerQuotas(["banked_resets": ["available_count": 0]])) == ["Aucun reset en banque"])
            precondition(bankedResetRows(providerQuotas(["banked_resets": ["available_count": 2]])) == ["Dates d’expiration non fournies"])
            precondition(providerQuotas(["banked_resets": ["expirations": [["expires_at": NSNull()], ["expires_at": -1], ["expires_at": "invalid"], ["expires_at": 42]]]])?.bankedResetExpirations == [42])
            for (codex, claude) in [(true, true), (true, false), (false, true)] {
                dashboardView.showCodex = codex
                dashboardView.showClaude = claude
                precondition(dashboardView.bankedResetsButton.isHidden == !codex)
                guard codex else { continue }
                precondition(dashboardHost.hitTest(dashboardView.convert(NSPoint(x: 50, y: 30), to: dashboardHost)) === dashboardView.bankedResetsButton)
                precondition(dashboardHost.hitTest(dashboardView.convert(NSPoint(x: 605, y: 192), to: dashboardHost)) === dashboardView.refreshButton)
                dashboardView.bankedResetsButton.performClick(nil)
                precondition(dashboardView.showingBankedResets)
                precondition(dashboardView.bankedResetsButton.frame == dashboardView.bounds)
                for point in [NSPoint(x: 4, y: 4), NSPoint(x: 80, y: 90), NSPoint(x: 250, y: 80), NSPoint(x: 600, y: 160), NSPoint(x: 605, y: 192), NSPoint(x: 40, y: 225)] {
                    let button = dashboardHost.hitTest(dashboardView.convert(point, to: dashboardHost)) as? NSButton
                    precondition(button === dashboardView.bankedResetsButton)
                    button?.performClick(nil)
                    precondition(!dashboardView.showingBankedResets)
                    dashboardView.bankedResetsButton.performClick(nil)
                }
                dashboardView.snapshot = quotas
                precondition(dashboardView.showingBankedResets)
                dashboardView.bankedResetsButton.performClick(nil)
                precondition(!dashboardView.showingBankedResets)
            }
            dashboardView.showCodex = true
            dashboardView.showClaude = true
            dashboardView.bankedResetsButton.performClick(nil)
            dashboardView.showCodex = false
            precondition(!dashboardView.showingBankedResets && dashboardView.bankedResetsButton.isHidden)
            dashboardView.showCodex = true
            let iconScreen = NSImage(size: NSSize(width: 64, height: 18), flipped: true) { rect in
                NSColor.cyan.setFill()
                rect.fill()
                return true
            }
            let awakeIcon = displaySleepIcon(screen: iconScreen, brightness: 1).tiffRepresentation
            let asleepIcon = displaySleepIcon(screen: iconScreen, brightness: 0).tiffRepresentation
            dashboardView.setRefreshing(true)
            let refreshAnimationStarted = dashboardView.refreshButton.isHidden
            dashboardView.setRefreshing(false)
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
                sleepingQuotas?.sleep == sleep, sleepResponsesValid,
                sleepRoundTrip == sleep, sleepFields.schedule == sleep,
                awakeIcon != nil, asleepIcon != nil, awakeIcon != asleepIcon,
                !DisplaySleep(startMinute: 420, endMinute: 420).valid,
                !DisplaySleep(startMinute: -1).valid,
                !DisplaySleep(endMinute: 1440).valid,
                !DisplaySleep(timezone: "Missing/Zone").valid,
                (desktopQuotas?["five_hour"] as? [String: Any])?["used_percent"] as? Int == 12,
                (desktopQuotas?["weekly"] as? [String: Any])?["used_percent"] as? Int == 39,
                (desktopQuotas?["fable_weekly"] as? [String: Any])?["used_percent"] as? Int == 81,
                (desktopLimitsQuotas?["fable_weekly"] as? [String: Any])?["used_percent"] as? Int == 65,
                desktopQuotas?["plan"] as? String == "Max 5X",
                bridgeUpdated, installedBridgePathsFound,
                installedBridgeURL(in: nil) == nil,
                installedBridgeURL(in: Data("invalid plist".utf8)) == nil,
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
                statusSnapshots.count == 4, Set(statusSnapshots.prefix(3)).count == 3,
                statusSnapshots.first == statusSnapshots.last,
                dashboardView.refreshButton.image != nil,
                providerGlyphsPresent, footerGlyphsPresent, providerIconsAnimate,
                refreshAnimationStarted,
                !dashboardView.refreshButton.isHidden,
                dateText(Int(Date().timeIntervalSince1970), timeOnly: true).count == 5,
                shellQuoted("a'b") == "'a'\\''b'",
                bundledIcon, bundledAppIcon,
                sparkleConfigured,
                quotas?.apiAddress == "192.168.1.252:8788",
                autoLaunchOn == true, autoLaunchOff == false,
                parsedLaunchPID == 4321
            else { exit(1) }
            if CommandLine.arguments.contains("--banked-resets") {
                dashboardView.bankedResetsButton.performClick(nil)
            }
            if let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
               CommandLine.arguments.indices.contains(index + 1),
               let bitmap = dashboardView.bitmapImageRepForCachingDisplay(in: dashboardView.bounds) {
                dashboardView.cacheDisplay(in: dashboardView.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
                do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
                catch { fputs("Dashboard snapshot failed: \(error)\n", stderr); exit(1) }
            }
            print("quota menu self-test: ok")
            return
        }
        let app = NSApplication.shared
        let delegate = MenuController()
        app.delegate = delegate
        app.run()
    }
}
