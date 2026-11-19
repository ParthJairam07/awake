import AppKit
import SwiftUI

/// Step E: the first-run Setup window. One step at a time; every step can
/// be skipped, and the status under each comes from `OnboardingModel` over a
/// fresh `OnboardingProbe` reading (on appear, on "Check again", and when
/// the app becomes active again after a trip to System Settings or Terminal).
struct OnboardingView: View {
    let manager: SessionManager
    let loginItem: LoginItem
    var probe: OnboardingProbe = .live
    let close: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var probes = OnboardingProbes()
    @State private var checking = false
    @State private var phoneTestSucceeded = false
    @State private var phoneBusy = false
    @State private var phoneNotice: String?
    @State private var terminalNotice: String?
    @State private var copied = false

    private var user: String { NSUserName() }
    private var sudoersCommand: String { OnboardingModel.sudoersCommand(bundle: Bundle.main.bundleURL) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                stepBody
                statusLine
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 560, height: 470)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    // MARK: Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(step.title).font(.title2).bold()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack {
            if let previous = OnboardingModel.previous(before: step) {
                Button("Back") { step = previous }
            }
            Spacer()
            if checking { ProgressView().controlSize(.small) }
            if let next = OnboardingModel.next(after: step) {
                if !OnboardingModel.status(of: step, probes: probes).isComplete {
                    Button("Skip") { step = next }
                }
                Button("Continue") { step = next }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch OnboardingModel.status(of: step, probes: probes) {
        case .informational:
            EmptyView()
        case .complete:
            Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .incomplete(let why):
            Label(why, systemImage: "circle").foregroundStyle(.secondary)
        case .unknown(let why):
            Label("Unknown: \(why)", systemImage: "questionmark.circle").foregroundStyle(.orange)
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .welcome: welcome
        case .notifications: notifications
        case .sudoers: sudoers
        case .privacy: privacy
        case .phoneAlerts: phoneAlerts
        case .tailscale: tailscale
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Awake keeps this Mac awake for a session you start from the menu bar, with the lid closed if you like, so coding agents keep working while you are away. A session always has an end time, and Awake ends it early when the battery or the temperature says so.")
            Text("It can fail, and here is the recovery.")
                .font(.headline)
            Text("Awake switches sleep off system-wide for the session. If the app crashes, is force quit or the Mac restarts, a small recovery agent that runs every minute switches sleep back on. If that fails too, one command in Terminal undoes it:")
            Text("sudo pmset -a disablesleep 0")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Text("A Mac that stays awake in a closed bag gets hot. Awake watches heat and battery and warns before it ends a session, but it cannot see inside the bag.")
                .foregroundStyle(.secondary)
            Text("The next steps set up what Awake needs. Each one can be skipped; \"Setup\u{2026}\" in the menu brings this window back.")
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Awake posts a notification when a session is about to end, when it ends early (battery, heat), and when something needs you. Without them these show only in the menu.")
            HStack {
                Button("Allow notifications") {
                    (manager.phoneAlerts?.local as? Notifier)?.requestAuthorizationIfNeeded()
                    // The prompt is answered whenever the person gets to
                    // it: follow the reading until macOS has an answer.
                    Task { probes.notifications = await probe.notificationsOnceDecided() }
                }
                .disabled(probes.notifications == .yes)
                Button("Open Notification settings") { NSWorkspace.shared.open(OnboardingModel.notificationsPane) }
                checkAgain
            }
            Text("macOS asks once. If you said no before, turn Awake on in Notification settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sudoers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Switching sleep off needs administrator rights. Instead of asking for your password every session, Awake uses one rule that lets your account run exactly these four commands without a password, and nothing else:")
            Text(OnboardingModel.sudoersRule(user: user))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("It is written to \(OnboardingModel.sudoersPath). Awake never asks for your password itself: the button opens Terminal with the command below, and Terminal asks.")
                .font(.callout)
            Text(sudoersCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(3)
            HStack {
                Button("Run in Terminal") {
                    terminalNotice = OnboardingActions.runInTerminal(command: sudoersCommand, directory: manager.store.paths.appSupport)
                }
                Button(copied ? "Copied" : "Copy command") {
                    OnboardingActions.copy(sudoersCommand)
                    copied = true
                }
                checkAgain
            }
            if let terminalNotice {
                Text(terminalNotice).font(.caption).foregroundStyle(.orange)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keeping the Mac awake needs neither of these. They are for the agent features: Accessibility lets Awake see when an agent's window is waiting for you, and Screen Recording lets it send your phone a picture of that window.")
            permissionRow("Accessibility", reading: probes.accessibility, pane: OnboardingModel.accessibilityPane)
            permissionRow("Screen Recording", reading: probes.screenRecording, pane: OnboardingModel.screenRecordingPane)
            HStack { checkAgain }
            Text("In System Settings, turn Awake on in each list (add it with + if it is not there). macOS may ask you to quit and reopen Awake before Screen Recording takes effect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func permissionRow(_ name: String, reading: OnboardingReading, pane: URL) -> some View {
        HStack {
            Image(systemName: reading == .yes ? "checkmark.circle.fill" : (reading == .no ? "circle" : "questionmark.circle"))
                .foregroundStyle(reading == .yes ? Color.green : Color.secondary)
            Text(name)
            Text(reading == .yes ? "granted" : (reading == .no ? "not granted" : "unknown"))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Open \(name) settings") { NSWorkspace.shared.open(pane) }
        }
    }

    private var phoneAlerts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Awake can send every notification to your phone through ntfy: install the ntfy app on the phone, subscribe to a topic, and type the same topic here. Nothing passes through a server of Awake's own.")
            TextField("ntfy topic (empty = off)", text: topic)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Send test") { Task { await sendTest() } }
                    .disabled(phoneBusy || !probes.phoneConfigured)
                if phoneBusy { ProgressView().controlSize(.small) }
            }
            if let phoneNotice {
                Text(phoneNotice).font(.caption).foregroundStyle(phoneTestSucceeded ? Color.secondary : Color.orange)
            }
            Text("A topic on ntfy.sh is public to anyone who guesses its name: use a long random one. Another server, an access token and Pushover are in Settings, Phone alerts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tailscale: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The phone app reaches this Mac over Tailscale, a private network between your own devices, so nothing is opened to the internet. Phone alerts through ntfy do not need it.")
            HStack {
                Button("Get Tailscale") { NSWorkspace.shared.open(OnboardingModel.tailscaleDownload) }
                checkAgain
            }
            Text("Awake looks for /Applications/Tailscale.app and the tailscale command. Install it on the phone too and sign in to the same account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(OnboardingModel.summary(probes: probes))
            ForEach(OnboardingStep.allCases.filter { OnboardingModel.status(of: $0, probes: probes) != .informational }) { item in
                HStack {
                    Image(systemName: OnboardingModel.status(of: item, probes: probes).isComplete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(OnboardingModel.status(of: item, probes: probes).isComplete ? Color.green : Color.secondary)
                    Button(item.title) { step = item }
                        .buttonStyle(.link)
                }
            }
            Toggle("Launch Awake at login", isOn: launchAtLogin)
            if let error = loginItem.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else if loginItem.needsApproval {
                Text("macOS wants you to approve the login item in System Settings, General, Login Items.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Start a session from the menu bar icon.")
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Actions

    private var checkAgain: some View {
        Button("Check again") { Task { await refresh() } }
            .disabled(checking)
    }

    private var topic: Binding<String> {
        Binding(
            get: { manager.config.ntfyTopic },
            set: { value in
                guard manager.config.ntfyTopic != value else { return }
                manager.config.ntfyTopic = value
                save()
                phoneTestSucceeded = false
                phoneNotice = nil
                let services = PhonePush.servicesEnabled(config: manager.config)
                probes.phoneConfigured = services.ntfy || services.pushover
                probes.phoneTestSucceeded = false
            }
        )
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginItem.isRegistered },
            set: { on in
                var config = manager.config
                _ = loginItem.set(on, config: &config)
                guard config != manager.config else { return }
                manager.config = config
                save()
            }
        )
    }

    private func save() {
        do {
            try manager.store.saveConfig(manager.config)
        } catch {
            Log.error("could not save config: \(error.localizedDescription)")
        }
    }

    private func sendTest() async {
        guard let alerts = manager.phoneAlerts else {
            phoneNotice = "Phone alerts are not wired in this build."
            return
        }
        phoneBusy = true
        defer { phoneBusy = false }
        if let problem = await alerts.sendTest() {
            phoneTestSucceeded = false
            phoneNotice = problem
        } else {
            phoneTestSucceeded = true
            phoneNotice = "Test alert sent. Check your phone."
        }
        probes.phoneTestSucceeded = phoneTestSucceeded
    }

    private func refresh() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        loginItem.refresh()
        probes = await probe.read(config: manager.config, phoneTestSucceeded: phoneTestSucceeded)
    }
}
