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

private func executable(named name: String) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
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

private func statusProviderIcon(codex: Bool, warning: Bool) -> NSImage {
    let size = NSSize(width: 12, height: 10)
    let codexIcon = "/Applications/Codex.app/Contents/Resources/icon-codex-dark-color.png"
    if codex, let image = NSImage(contentsOfFile: codexIcon) {
        return image
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
        drawProviderIcon(codex: true, connected: codexConnected, x: 0)
        drawProviderIcon(codex: false, connected: claudeConnected, x: bounds.width - 15)
        drawDivider()
        drawRow(
            window5h: snapshot?.codex.fiveHour ?? empty,
            weekly: snapshot?.codex.weekly ?? empty,
            providerOK: snapshot?.codex.status == "ok",
            x: 16,
            width: bounds.width - 32,
            y: 1
        )
        drawRow(
            window5h: snapshot?.claude.fiveHour ?? empty,
            weekly: snapshot?.claude.weekly ?? empty,
            providerOK: snapshot?.claude.status == "ok",
            x: 16,
            width: bounds.width - 32,
            y: 11
        )
    }

    private func drawProviderIcon(codex: Bool, connected: Bool?, x: CGFloat) {
        statusProviderIcon(codex: codex, warning: connected == false)
            .draw(in: NSRect(x: x, y: 4, width: 15, height: 14))
        if connected == false {
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + 11, y: 14, width: 4, height: 4)).fill()
        }
    }

    private func drawDivider() {
        NSColor.separatorColor.withAlphaComponent(0.7).setFill()
        NSRect(x: 14, y: 10.5, width: bounds.width - 28, height: 0.5).fill()
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

@MainActor
private final class QuotaDashboardView: NSView {
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
        return "Codex, 5 heures \(remainingText(snapshot.codex.fiveHour)), semaine \(remainingText(snapshot.codex.weekly)). Claude, 5 heures \(remainingText(snapshot.claude.fiveHour)), semaine \(remainingText(snapshot.claude.weekly)), Fable \(remainingText(snapshot.claude.fableWeekly)). API ESP32 \(apiOnline ? "en ligne" : "hors ligne") à \(snapshot.apiAddress). Dernière actualisation \(dateText(snapshot.refreshedAt, timeOnly: true))."
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let card = bounds.insetBy(dx: 8, dy: 6)
        NSColor.controlBackgroundColor.withAlphaComponent(0.46).setFill()
        NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()

        let empty = ProviderQuotas(
            status: "loading",
            fiveHour: QuotaWindow(usedPercent: nil, resetsAt: nil),
            weekly: QuotaWindow(usedPercent: nil, resetsAt: nil),
            fableWeekly: QuotaWindow(usedPercent: nil, resetsAt: nil),
            bankedResets: nil
        )
        drawProvider(
            title: "Codex",
            provider: snapshot?.codex ?? empty,
            y: 16,
            compactLabel: "Resets en banque",
            compactWindow: nil,
            compactCount: snapshot?.codex.bankedResets
        )
        NSColor.separatorColor.setFill()
        NSRect(x: 22, y: 124, width: bounds.width - 44, height: 1).fill()
        drawProvider(
            title: "Claude Code",
            provider: snapshot?.claude ?? empty,
            y: 136,
            compactLabel: "Fable",
            compactWindow: snapshot?.claude.fableWeekly,
            compactCount: nil
        )
        drawText(
            "Dernière actualisation · \(dateText(snapshot?.refreshedAt, timeOnly: true))",
            in: NSRect(x: 22, y: 248, width: bounds.width - 44, height: 16),
            font: .systemFont(ofSize: 11, weight: .medium),
            color: .secondaryLabelColor,
            alignment: .center
        )
        drawAPIStatus(y: 272)
    }

    private func drawProvider(
        title: String,
        provider: ProviderQuotas,
        y: CGFloat,
        compactLabel: String,
        compactWindow: QuotaWindow?,
        compactCount: Int?
    ) {
        let stateColor: NSColor = provider.status == "ok"
            ? .systemGreen
            : provider.status == "stale" ? .systemOrange : .systemRed
        stateColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 22, y: y + 7, width: 7, height: 7)).fill()
        drawText(
            title,
            in: NSRect(x: 36, y: y, width: 170, height: 22),
            font: .systemFont(ofSize: 15, weight: .bold),
            color: .labelColor
        )
        drawText(
            resetCountdown(provider),
            in: NSRect(x: 220, y: y + 1, width: 182, height: 20),
            font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            color: .secondaryLabelColor,
            alignment: .right
        )
        drawQuotaRow(label: "5 h", window: provider.fiveHour, y: y + 28)
        drawQuotaRow(label: "1 sem", window: provider.weekly, y: y + 58)
        if let compactWindow {
            drawCompactQuota(label: compactLabel, window: compactWindow, y: y + 91)
        } else {
            drawResetCount(label: compactLabel, count: compactCount, y: y + 91)
        }
    }

    private func drawQuotaRow(label: String, window: QuotaWindow, y: CGFloat) {
        drawText(
            label,
            in: NSRect(x: 22, y: y - 2, width: 46, height: 18),
            font: .systemFont(ofSize: 12, weight: .medium),
            color: .secondaryLabelColor
        )
        let bar = NSRect(x: 72, y: y, width: 292, height: 10)
        drawBar(in: bar, percent: window.remainingPercent)
        drawSegments(in: NSRect(x: 72, y: y + 14, width: 292, height: 5), percent: window.remainingPercent)
        drawText(
            remainingText(window),
            in: NSRect(x: 372, y: y - 5, width: 45, height: 22),
            font: .monospacedDigitSystemFont(ofSize: 14, weight: .bold),
            color: window.remainingPercent == nil ? .secondaryLabelColor : .labelColor,
            alignment: .right
        )
    }

    private func drawBar(in rect: NSRect, percent: Int?) {
        NSColor.tertiaryLabelColor.withAlphaComponent(0.34).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        guard let percent, percent > 0 else { return }
        let fill = NSRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(percent) / 100, height: rect.height)
        let path = NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [.systemBlue, .systemTeal])?.draw(in: fill, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSegments(in rect: NSRect, percent: Int?) {
        let count = 8
        let gap: CGFloat = 4
        let width = (rect.width - CGFloat(count - 1) * gap) / CGFloat(count)
        let filled = percent.map { Int(ceil(CGFloat($0) / 100 * CGFloat(count))) } ?? 0
        for index in 0..<count {
            let segment = NSRect(
                x: rect.minX + CGFloat(index) * (width + gap),
                y: rect.minY,
                width: width,
                height: rect.height
            )
            (index < filled ? NSColor.systemBlue.withAlphaComponent(0.64) : NSColor.tertiaryLabelColor.withAlphaComponent(0.28)).setFill()
            NSBezierPath(roundedRect: segment, xRadius: 2.5, yRadius: 2.5).fill()
        }
    }

    private func drawCompactQuota(label: String, window: QuotaWindow, y: CGFloat) {
        drawText(
            label,
            in: NSRect(x: 72, y: y - 2, width: 48, height: 16),
            font: .systemFont(ofSize: 10, weight: .semibold),
            color: .secondaryLabelColor
        )
        drawBar(in: NSRect(x: 122, y: y + 1, width: 242, height: 6), percent: window.remainingPercent)
        drawText(
            remainingText(window),
            in: NSRect(x: 372, y: y - 4, width: 45, height: 16),
            font: .monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            color: .secondaryLabelColor,
            alignment: .right
        )
    }

    private func drawResetCount(label: String, count: Int?, y: CGFloat) {
        drawText(
            label,
            in: NSRect(x: 72, y: y - 3, width: 118, height: 16),
            font: .systemFont(ofSize: 10, weight: .semibold),
            color: .secondaryLabelColor
        )
        let value = count.map(String.init) ?? "—"
        drawText(
            value,
            in: NSRect(x: 190, y: y - 3, width: 24, height: 16),
            font: .monospacedDigitSystemFont(ofSize: 11, weight: .bold),
            color: .secondaryLabelColor
        )
        for index in 0..<min(count ?? 0, 8) {
            NSColor.systemBlue.withAlphaComponent(0.72).setFill()
            NSBezierPath(ovalIn: NSRect(x: 224 + CGFloat(index) * 14, y: y, width: 7, height: 7)).fill()
        }
    }

    private func resetCountdown(_ provider: ProviderQuotas) -> String {
        let resets = [provider.fiveHour.resetsAt, provider.weekly.resetsAt, provider.fableWeekly.resetsAt]
            .compactMap { $0 }
            .filter { $0 > Int(Date().timeIntervalSince1970) }
        guard let reset = resets.min() else { return "◷  —" }
        let hours = Double(reset - Int(Date().timeIntervalSince1970)) / 3600
        return String(format: "◷  dans %.1f h", locale: Locale(identifier: "fr_CA"), hours)
    }

    private func drawAPIStatus(y: CGFloat) {
        let color: NSColor = apiOnline ? .systemGreen : .systemRed
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 96, y: y + 4, width: 7, height: 7)).fill()
        drawText(
            "API ESP32",
            in: NSRect(x: 110, y: y, width: 76, height: 16),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: .secondaryLabelColor
        )
        drawText(
            apiOnline ? "en ligne" : "hors ligne",
            in: NSRect(x: 188, y: y, width: 66, height: 16),
            font: .systemFont(ofSize: 11, weight: .semibold),
            color: color
        )
        drawText(
            snapshot?.apiAddress ?? "port 8788",
            in: NSRect(x: 256, y: y, width: 150, height: 16),
            font: .monospacedDigitSystemFont(ofSize: 10, weight: .medium),
            color: .secondaryLabelColor,
            alignment: .right
        )
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
    private let dashboard = QuotaDashboardView(frame: NSRect(x: 0, y: 0, width: 430, height: 294))
    private let refreshItem = NSMenuItem(title: "Actualiser les quotas", action: nil, keyEquivalent: "r")
    private let autoLaunchItem = NSMenuItem(title: "Démarrer l’API avec la session", action: nil, keyEquivalent: "")
    private let bridgeLabel = "com.pducharme.quota-display"
    private let launchDomain = "gui/\(getuid())"
    private var codexConnected: Bool?
    private var claudeConnected: Bool?
    private var snapshot: QuotaSnapshot?
    private var bridgeOnline = false
    private var checking = false
    private var loadingQuotas = false
    private var loginProcesses: [String: Process] = [:]
    private var autoPrompted = Set<String>()

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
        statusItem.length = 82
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
        autoLaunchItem.target = self
        autoLaunchItem.action = #selector(toggleAutoLaunch)
        autoLaunchItem.state = .mixed
        autoLaunchItem.toolTip = "Contrôle le démarrage du pont API Python à la prochaine ouverture de session."
        menu.addItem(autoLaunchItem)
        let connectionsItem = NSMenuItem(title: "Connexions", action: nil, keyEquivalent: "")
        let connections = NSMenu()
        codexStatus.isEnabled = false
        claudeStatus.isEnabled = false
        connections.addItem(codexStatus)
        connections.addItem(NSMenuItem(title: "Reconnecter Codex…", action: #selector(loginCodex), keyEquivalent: ""))
        connections.addItem(.separator())
        connections.addItem(claudeStatus)
        connections.addItem(NSMenuItem(title: "Reconnecter Claude Max…", action: #selector(loginClaude), keyEquivalent: ""))
        connectionsItem.submenu = connections
        menu.addItem(connectionsItem)
        statusItem.menu = menu
        renderStatusTitle()
    }

    func menuWillOpen(_ menu: NSMenu) {
        checkAuthentication(autoPrompt: false)
        loadAutoLaunchState()
        loadQuotas()
    }

    private func checkAuthentication(autoPrompt: Bool) {
        guard !checking else { return }
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
        compactStatus.snapshot = snapshot
        compactStatus.bridgeOnline = bridgeOnline
        compactStatus.codexConnected = codexConnected
        compactStatus.claudeConnected = claudeConnected
        compactStatus.needsDisplay = true
        statusItem.button?.toolTip = snapshot?.refreshedAt.map {
            "5 h / semaine · dernière actualisation \(dateText($0, timeOnly: true))"
        } ?? "5 h / semaine · en attente du pont"
    }

    private func bridgeRequest(path: String, method: String = "GET") -> URLRequest? {
        let tokenURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Quota Display/token")
        guard
            let token = try? String(contentsOf: tokenURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: "http://127.0.0.1:8788\(path)")
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func loadQuotas() {
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
        guard loginProcesses[provider] == nil else { return }
        let path = executable(named: provider)
        guard let path else {
            setStatus(provider: provider, text: "commande introuvable")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = provider == "claude"
            ? ["auth", "login", "--claudeai"]
            : ["login"]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loginProcesses.removeValue(forKey: provider)
                if finished.terminationStatus == 0 {
                    self.setStatus(provider: provider, text: "connexion réussie")
                    self.triggerRefresh()
                } else {
                    self.setStatus(provider: provider, text: "connexion annulée")
                }
                self.checkAuthentication(autoPrompt: false)
            }
        }
        do {
            try process.run()
            loginProcesses[provider] = process
            setStatus(provider: provider, text: "connexion web en cours…")
        } catch {
            setStatus(provider: provider, text: "échec du lancement")
        }
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
            let sample = #"{"api":{"status":"online","address":"192.168.1.252:8788"},"refresh":{"completed_at":1785776996},"providers":{"codex":{"status":"ok","five_hour":{"used_percent":null,"resets_at":null},"weekly":{"used_percent":7,"resets_at":1786172449},"fable_weekly":{"used_percent":null,"resets_at":null},"banked_resets":{"available_count":2}},"claude":{"status":"ok","five_hour":{"used_percent":0,"resets_at":null},"weekly":{"used_percent":15,"resets_at":1785859200},"fable_weekly":{"used_percent":28,"resets_at":1785859200}}}}"#
            let quotas = quotaSnapshot(from: Data(sample.utf8))
            let autoLaunchOn = autoLaunchEnabled(from: CommandResult(status: 0, output: "disabled services = {}"), label: "test")
            let autoLaunchOff = autoLaunchEnabled(from: CommandResult(status: 0, output: "\"test\" => disabled"), label: "test")
            guard
                claudeGood, !claudeWrongMode, codexGood, !codexWrongMode,
                quotas?.codex.weekly.remainingPercent == 93,
                quotas?.claude.fiveHour.remainingPercent == 100,
                quotas?.claude.fableWeekly.remainingPercent == 72,
                compactRemainingText(quotas!.codex.weekly, percent: true) == "93%",
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
