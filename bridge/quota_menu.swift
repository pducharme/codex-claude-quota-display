import AppKit
import Darwin
import Foundation

private struct CommandResult {
    let status: Int32
    let output: String
}

private struct AuthState {
    let connected: Bool
    let label: String
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
}

private func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func executable(named name: String) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        name == "codex" ? "/Applications/Codex.app/Contents/Resources/codex" : "",
        name == "codex" ? "\(home)/Applications/Codex.app/Contents/Resources/codex" : "",
        "\(home)/.local/bin/\(name)",
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/usr/bin/\(name)",
    ]
    return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
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
    return QuotaSnapshot(
        codex: codex,
        claude: claude,
        refreshedAt: refresh?["completed_at"] as? Int,
        apiAddress: api?["address"] as? String ?? "port 8788"
    )
}

private func remainingText(_ window: QuotaWindow) -> String {
    window.remainingPercent.map { "\($0)%" } ?? "—%"
}

private func compactRemainingText(_ window: QuotaWindow, percent: Bool) -> String {
    guard let remaining = window.remainingPercent else { return percent ? "—%" : "—" }
    return "\(remaining)\(percent ? "%" : "")"
}

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

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let empty = QuotaWindow(usedPercent: nil, resetsAt: nil)
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
        return "Codex, forfait \(snapshot.codex.plan ?? "inconnu"), 5 heures \(remainingText(snapshot.codex.fiveHour)), semaine \(remainingText(snapshot.codex.weekly)). Claude, forfait \(snapshot.claude.plan ?? "inconnu"), 5 heures \(remainingText(snapshot.claude.fiveHour)), semaine \(remainingText(snapshot.claude.weekly)), Fable \(remainingText(snapshot.claude.fableWeekly)). API \(snapshot.apiAddress), \(apiOnline ? "en ligne" : "hors ligne"). Dernière actualisation \(dateText(snapshot.refreshedAt, timeOnly: true))."
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
        let gap: CGFloat = 8
        let panelWidth = (screen.width - 24) / 2
        drawProviderCard(
            title: "CODEX",
            provider: snapshot?.codex ?? empty,
            rect: NSRect(x: screen.minX + 8, y: screen.minY + 8, width: panelWidth, height: 158),
            panelColor: NSColor(srgbRed: 8 / 255, green: 29 / 255, blue: 48 / 255, alpha: 1),
            accent: codexColor,
            codex: true,
            compactLabel: "RESETS:",
            compactWindow: nil,
            compactCount: snapshot?.codex.bankedResets
        )
        drawProviderCard(
            title: "CLAUDE",
            provider: snapshot?.claude ?? empty,
            rect: NSRect(x: screen.minX + 8 + panelWidth + gap, y: screen.minY + 8, width: panelWidth, height: 158),
            panelColor: NSColor(srgbRed: 43 / 255, green: 24 / 255, blue: 21 / 255, alpha: 1),
            accent: claudeColor,
            codex: false,
            compactLabel: "FABLE:",
            compactWindow: snapshot?.claude.fableWeekly,
            compactCount: nil
        )
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
private final class MenuController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let compactStatus = CompactStatusView(frame: .zero)
    private let codexStatus = NSMenuItem(title: "Codex : vérification…", action: nil, keyEquivalent: "")
    private let claudeStatus = NSMenuItem(title: "Claude : vérification…", action: nil, keyEquivalent: "")
    private let dashboard = QuotaDashboardView(frame: NSRect(x: 0, y: 0, width: 470, height: 250))
    private let refreshItem = NSMenuItem(title: "Actualiser les quotas", action: nil, keyEquivalent: "r")
    private let sourceItem = NSMenuItem(title: "Source des quotas…", action: nil, keyEquivalent: "")
    private let copyAPIItem = NSMenuItem(title: "Copier la configuration API", action: nil, keyEquivalent: "")
    private let autoLaunchItem = NSMenuItem(title: "Démarrer l’API avec la session", action: nil, keyEquivalent: "")
    private let connectionsItem = NSMenuItem(title: "Connexions", action: nil, keyEquivalent: "")
    private let bridgeLabel = "com.pducharme.quota-display"
    private let launchDomain = "gui/\(getuid())"
    private var codexConnected: Bool?
    private var claudeConnected: Bool?
    private var snapshot: QuotaSnapshot?
    private var bridgeOnline = false
    private var checking = false
    private var loadingQuotas = false
    private var autoPrompted = Set<String>()

    private var appSupportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quota Display")
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
        NSApp.setActivationPolicy(.accessory)
        configureMenu()
        checkAuthentication(autoPrompt: true)
        loadAutoLaunchState()
        loadQuotas()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadQuotas() }
        }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkAuthentication(autoPrompt: true) }
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
        refreshItem.target = self
        refreshItem.action = #selector(refreshQuotas)
        menu.addItem(refreshItem)
        sourceItem.target = self
        sourceItem.action = #selector(chooseQuotaSource)
        menu.addItem(sourceItem)
        copyAPIItem.target = self
        copyAPIItem.action = #selector(copyAPIConfiguration)
        copyAPIItem.toolTip = "Copie l’adresse et le jeton nécessaires aux mini-écrans et aux Companions distants."
        menu.addItem(copyAPIItem)
        autoLaunchItem.target = self
        autoLaunchItem.action = #selector(toggleAutoLaunch)
        autoLaunchItem.state = .mixed
        autoLaunchItem.toolTip = "Contrôle le démarrage du pont API Python à la prochaine ouverture de session."
        menu.addItem(autoLaunchItem)
        let connections = NSMenu()
        codexStatus.isEnabled = false
        claudeStatus.isEnabled = false
        connections.addItem(codexStatus)
        let reconnectCodex = NSMenuItem(title: "Reconnecter Codex…", action: #selector(loginCodex), keyEquivalent: "")
        reconnectCodex.target = self
        connections.addItem(reconnectCodex)
        connections.addItem(.separator())
        connections.addItem(claudeStatus)
        let reconnectClaude = NSMenuItem(title: "Reconnecter Claude Max…", action: #selector(loginClaude), keyEquivalent: "")
        reconnectClaude.target = self
        connections.addItem(reconnectClaude)
        connectionsItem.submenu = connections
        menu.addItem(connectionsItem)
        statusItem.menu = menu
        updateSourceItems()
        renderStatusTitle()
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
        checkAuthentication(autoPrompt: false)
        loadAutoLaunchState()
        loadQuotas()
    }

    private func checkAuthentication(autoPrompt: Bool) {
        guard !configuredBridgeSource.remote, !checking else { return }
        checking = true
        let claude = executable(named: "claude")
        let codex = executable(named: "codex")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let claude = claudeState(from: run(claude, ["auth", "status", "--json"]))
            let codex = codexState(from: run(codex, ["login", "status"]))
            DispatchQueue.main.async {
                guard let self else { return }
                self.checking = false
                self.apply(claude: claude, codex: codex, autoPrompt: autoPrompt)
            }
        }
    }

    private func apply(claude: AuthState, codex: AuthState, autoPrompt: Bool) {
        guard !configuredBridgeSource.remote else {
            updateSourceItems()
            return
        }
        claudeConnected = claude.connected
        codexConnected = codex.connected
        claudeStatus.title = "Claude : \(claude.label)"
        codexStatus.title = "Codex : \(codex.label)"
        renderStatusTitle()

        if claude.connected { autoPrompted.remove("claude") }
        if codex.connected { autoPrompted.remove("codex") }
        if autoPrompt && !claude.connected && autoPrompted.insert("claude").inserted {
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
        statusItem.button?.toolTip = snapshot?.refreshedAt.map {
            "5 h / semaine · dernière actualisation \(dateText($0, timeOnly: true))"
        } ?? "5 h / semaine · en attente du pont"
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

    private func loadQuotas() {
        let sourceURL = configuredBridgeSource.url
        guard !loadingQuotas, let request = bridgeRequest(path: "/v1/quotas") else {
            bridgeOnline = false
            dashboard.apiOnline = false
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
                if let loaded {
                    self.snapshot = loaded
                    self.dashboard.snapshot = loaded
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

    @objc private func loginClaude() {
        launchLogin(provider: "claude")
    }

    @objc private func loginCodex() {
        launchLogin(provider: "codex")
    }

    private func launchLogin(provider: String) {
        let path = executable(named: provider)
        guard let path else {
            setStatus(provider: provider, text: "commande introuvable")
            showLoginError(provider: provider, message: "La commande n’est pas installée sur ce Mac. Installez-la, puis réessayez.")
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
        triggerRefresh()
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
            let sample = #"{"api":{"status":"online","address":"192.168.1.252:8788"},"refresh":{"completed_at":1785776996},"providers":{"codex":{"status":"ok","plan":"Pro 20X","five_hour":{"used_percent":null,"resets_at":null},"weekly":{"used_percent":7,"resets_at":1786172449},"fable_weekly":{"used_percent":null,"resets_at":null},"banked_resets":{"available_count":2}},"claude":{"status":"ok","plan":"Max 5X","five_hour":{"used_percent":0,"resets_at":null},"weekly":{"used_percent":15,"resets_at":1785859200},"fable_weekly":{"used_percent":28,"resets_at":1785859200}}}}"#
            let quotas = quotaSnapshot(from: Data(sample.utf8))
            let autoLaunchOn = autoLaunchEnabled(from: CommandResult(status: 0, output: "disabled services = {}"), label: "test")
            let autoLaunchOff = autoLaunchEnabled(from: CommandResult(status: 0, output: "\"test\" => disabled"), label: "test")
            let hourlyReset = resetCountdown(QuotaWindow(usedPercent: 60, resetsAt: 19_000), now: 10_000)
            let weeklyReset = resetCountdown(QuotaWindow(usedPercent: 40, resetsAt: 450_640), now: 10_000)
            let expectedHalf = expectedRemainingPercent(
                QuotaWindow(usedPercent: 60, resetsAt: 19_000),
                durationSeconds: 18_000,
                now: 10_000
            )
            let localBridge = bridgeBaseURL(from: nil)
            let remoteBridge = bridgeBaseURL(from: "192.168.1.20:8788")
            let bundledIcon = Bundle.main.bundleURL.pathExtension != "app"
                || Bundle.main.url(forResource: "CodexIcon", withExtension: "png").flatMap(NSImage.init(contentsOf:)) != nil
            guard
                claudeGood, !claudeWrongMode, codexGood, !codexWrongMode,
                quotas?.codex.weekly.remainingPercent == 93,
                quotas?.codex.plan == "Pro 20X",
                quotas?.claude.fiveHour.remainingPercent == 100,
                quotas?.claude.plan == "Max 5X",
                quotas?.claude.fableWeekly.remainingPercent == 72,
                compactRemainingText(quotas!.codex.weekly, percent: true) == "93%",
                hourlyReset == "2h 30m",
                weeklyReset == "5j 2h",
                expectedHalf == 50,
                localBridge?.absoluteString == "http://127.0.0.1:8788",
                remoteBridge?.host == "192.168.1.20", remoteBridge?.port == 8788,
                bridgeBaseURL(from: "ftp://192.168.1.20:8788") == nil,
                bridgeBaseURL(from: "http://192.168.1.20:8788/extra") == nil,
                shellQuoted("a'b") == "'a'\\''b'",
                bundledIcon,
                quotas?.apiAddress == "192.168.1.252:8788",
                autoLaunchOn == true, autoLaunchOff == false
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
