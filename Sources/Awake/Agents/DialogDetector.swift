import AppKit
import ApplicationServices
import Foundation

/// A sheet, dialog or system prompt found on screen.
struct DetectedDialog: Sendable, Equatable {
    let app: String
    let title: String
    /// The static text in it, joined.
    let text: String
    let buttons: [String]

    init(app: String, title: String, text: String, buttons: [String]) {
        self.app = app
        self.title = title
        self.text = text
        self.buttons = buttons
    }

    /// The same dialog seen again has the same key: app, title and text.
    var key: UInt64 { PromptDetector.hash("\(app)\u{1F}\(title)\u{1F}\(text)") }
}

/// An app whose windows are read.
struct DialogTarget: Sendable, Equatable {
    let pid: Int32
    let name: String
    /// A process that only ever shows prompts (TCC, keychain, Gatekeeper):
    /// every window of it is one.
    let systemPrompt: Bool

    init(pid: Int32, name: String, systemPrompt: Bool = false) {
        self.pid = pid
        self.name = name
        self.systemPrompt = systemPrompt
    }
}

/// Reads dialogs through the Accessibility API. The live reader needs the
/// user to allow Awake under Privacy & Security > Accessibility; tests
/// use a fake.
protocol DialogProbing: Sendable {
    func isTrusted() -> Bool
    func dialogs(in targets: [DialogTarget]) -> [DetectedDialog]
    /// Ask macOS to show its "allow Accessibility" prompt.
    func requestTrust()
}

/// Pure pieces of the dialog detector.
enum DialogRules {
    /// Processes that exist to show a system prompt: permission requests
    /// (TCC), Gatekeeper and "downloaded from the internet", the keychain
    /// and administrator password.
    static let systemPromptProcesses: Set<String> = [
        "UserNotificationCenter", "CoreServicesUIAgent", "SecurityAgent", "universalAccessAuthWarn", "coreautha",
    ]
    static let maxTargets = 24
    /// A dialog only blocks when nobody is there to answer it.
    static let minimumIdleSeconds: Double = 60

    /// The apps to read: every system prompt process, the frontmost app,
    /// and the running agent apps (`Config.agentList`). Never Awake.
    static func targets(apps: [RunningApp], frontmostPid: Int32?, agentBundleIds: Set<String>, agentPids: Set<Int32> = [], selfPid: Int32 = getpid()) -> [DialogTarget] {
        var out: [DialogTarget] = []
        var seen: Set<Int32> = [selfPid]
        for app in apps where !seen.contains(app.pid) {
            let system = systemPromptProcesses.contains(app.name)
            let wanted = system || app.pid == frontmostPid || agentPids.contains(app.pid)
                || (app.bundleId.map(agentBundleIds.contains) ?? false)
            guard wanted else { continue }
            seen.insert(app.pid)
            out.append(DialogTarget(pid: app.pid, name: app.name, systemPrompt: system))
        }
        // System prompts first: they are the ones that matter most.
        return Array(out.sorted { $0.systemPrompt && !$1.systemPrompt }.prefix(maxTargets))
    }

    @MainActor
    static func frontmostPid() -> Int32? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func alert(for dialog: DetectedDialog) -> (title: String, body: String) {
        let name = dialog.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? "Dialog blocking: \(dialog.app)" : "Dialog blocking: \(dialog.app) \u{2014} \(PromptDetector.excerpt(name))"
        var parts: [String] = []
        let text = dialog.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { parts.append(String(text.prefix(300))) }
        if !dialog.buttons.isEmpty { parts.append("Buttons: \(dialog.buttons.joined(separator: ", ")).") }
        return (title, parts.isEmpty ? "A dialog is waiting for an answer." : parts.joined(separator: " "))
    }

    static func permissionStatus(trusted: Bool) -> String {
        trusted
            ? "Accessibility is allowed: Awake can read dialogs."
            : "Accessibility is not allowed yet, so dialogs are not read. Allow Awake under Privacy & Security > Accessibility."
    }
}

/// Polls for dialogs during a session and reports each once.
@MainActor
final class DialogWatcher {
    static let pollInterval: TimeInterval = 5

    private let probe: any DialogProbing
    private let notifier: any Notifying
    private let config: @MainActor () -> Config
    private let targets: @MainActor () -> [DialogTarget]
    private let idleSeconds: @Sendable () -> Double
    private let interval: TimeInterval
    private var timer: (any DispatchSourceTimer)?
    private var checking = false
    /// Dialogs already reported, and for how many checks each has been gone.
    private var reported: [UInt64: Int] = [:]
    private(set) var running = false

    init(
        probe: any DialogProbing,
        notifier: any Notifying,
        idleSeconds: @escaping @Sendable () -> Double = { UserInput.secondsSinceLastInput() },
        pollInterval: TimeInterval = DialogWatcher.pollInterval,
        config: @escaping @MainActor () -> Config,
        targets: @escaping @MainActor () -> [DialogTarget]
    ) {
        self.probe = probe
        self.notifier = notifier
        self.idleSeconds = idleSeconds
        self.interval = pollInterval
        self.config = config
        self.targets = targets
    }

    func start() {
        guard !running else { return }
        running = true
        reported = [:]
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in await self?.check() }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        reported = [:]
    }

    /// One check; the timer calls this, and tests call it directly.
    func check() async {
        guard running, !checking, config().dialogAlerts, probe.isTrusted() else { return }
        // Someone is at the Mac: the dialog is theirs to answer.
        guard idleSeconds() >= DialogRules.minimumIdleSeconds else { return }
        checking = true
        defer { checking = false }
        let probe = self.probe
        let targets = self.targets()
        let found = await Task.detached(priority: .utility) { probe.dialogs(in: targets) }.value
        guard running else { return }
        let present = Set(found.map(\.key))
        for dialog in found where reported[dialog.key] == nil {
            let alert = DialogRules.alert(for: dialog)
            Log.info("dialog: \(dialog.app) - \(dialog.title)")
            notifier.post(title: alert.title, body: alert.body)
        }
        for key in present { reported[key] = 0 }
        // A dialog gone for two checks is forgotten, so the same prompt
        // coming up again later is reported again.
        for (key, missed) in reported where !present.contains(key) {
            reported[key] = missed >= 1 ? nil : missed + 1
        }
    }
}

/// The real reader. Isolated here and not unit tested beyond compiling:
/// it needs the Accessibility permission and real windows.
struct AXDialogProbe: DialogProbing {
    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func requestTrust() {
        // The key's value is the documented string; reading the global
        // constant is not concurrency-safe under Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func dialogs(in targets: [DialogTarget]) -> [DetectedDialog] {
        guard AXIsProcessTrusted() else { return [] }
        var out: [DetectedDialog] = []
        for target in targets {
            let app = AXUIElementCreateApplication(target.pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            for window in Self.elements(app, kAXWindowsAttribute) {
                let role = Self.string(window, kAXRoleAttribute)
                let subrole = Self.string(window, kAXSubroleAttribute)
                if target.systemPrompt || role == "AXSheet" || subrole == "AXDialog" || subrole == "AXSystemDialog" {
                    out.append(Self.describe(window, app: target.name))
                }
                // A sheet hangs off its window as a child.
                for child in Self.elements(window, kAXChildrenAttribute) where Self.string(child, kAXRoleAttribute) == "AXSheet" {
                    out.append(Self.describe(child, app: target.name))
                }
            }
        }
        return out
    }

    private static func describe(_ element: AXUIElement, app: String) -> DetectedDialog {
        var texts: [String] = []
        var buttons: [String] = []
        var budget = 120
        collect(element, depth: 0, texts: &texts, buttons: &buttons, budget: &budget)
        return DetectedDialog(app: app, title: string(element, kAXTitleAttribute), text: texts.joined(separator: " "), buttons: buttons)
    }

    private static func collect(_ element: AXUIElement, depth: Int, texts: inout [String], buttons: inout [String], budget: inout Int) {
        guard depth < 8, budget > 0 else { return }
        for child in elements(element, kAXChildrenAttribute) {
            budget -= 1
            guard budget > 0 else { return }
            switch string(child, kAXRoleAttribute) {
            case "AXStaticText":
                let value = string(child, kAXValueAttribute)
                if !value.isEmpty { texts.append(value) }
            case "AXButton":
                let title = string(child, kAXTitleAttribute)
                if !title.isEmpty { buttons.append(title) }
            default:
                collect(child, depth: depth + 1, texts: &texts, buttons: &buttons, budget: &budget)
            }
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    /// The Accessibility pane of System Settings.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
}
