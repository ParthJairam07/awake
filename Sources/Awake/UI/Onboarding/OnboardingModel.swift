import Foundation

/// Step E: the first-run Setup window's steps and what makes each one
/// complete. Pure: the readings come in as `OnboardingProbes`, which the
/// window fills from the machine (`LiveOnboardingProbe`) and tests fill by
/// hand. Every step can be skipped; none is required to finish.
enum OnboardingStep: Int, CaseIterable, Identifiable, Sendable {
    case welcome
    case notifications
    case sudoers
    case privacy
    case phoneAlerts
    case tailscale
    case done

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "What Awake does"
        case .notifications: "Notifications"
        case .sudoers: "Permission to hold the Mac awake"
        case .privacy: "Accessibility and Screen Recording"
        case .phoneAlerts: "Phone alerts"
        case .tailscale: "Tailscale"
        case .done: "Ready"
        }
    }
}

/// What a probe read. "Unknown" is its own answer: a reading that could
/// not be taken is neither granted nor missing (PLAN.md, honesty rule).
enum OnboardingReading: Equatable, Sendable {
    case yes
    case no
    case unknown
}

/// Everything the steps' status depends on, read at one moment.
struct OnboardingProbes: Equatable, Sendable {
    /// Notifications allowed for Awake.
    var notifications: OnboardingReading = .unknown
    /// `sudo -n` may run the four pmset commands (the sudoers rule works).
    var sudoersRule: OnboardingReading = .unknown
    var accessibility: OnboardingReading = .unknown
    var screenRecording: OnboardingReading = .unknown
    /// A phone service is configured (an ntfy topic or Pushover).
    var phoneConfigured: Bool = false
    /// A test alert was sent from this window and the service accepted it.
    var phoneTestSucceeded: Bool = false
    /// Tailscale is installed (its app or its command-line tool).
    var tailscaleInstalled: OnboardingReading = .unknown
}

/// Where a step stands.
enum OnboardingStatus: Equatable, Sendable {
    /// Nothing to check: the step only informs.
    case informational
    case complete
    /// Not done; the string says what is missing.
    case incomplete(String)
    /// Could not be read; the string says what was tried.
    case unknown(String)

    var isComplete: Bool { self == .complete || self == .informational }
}

enum OnboardingModel {
    /// The status of one step from the probes.
    static func status(of step: OnboardingStep, probes: OnboardingProbes) -> OnboardingStatus {
        switch step {
        case .welcome, .done:
            return .informational
        case .notifications:
            switch probes.notifications {
            case .yes: return .complete
            case .no: return .incomplete("Notifications are off for Awake. Without them a battery, heat or restore warning shows only in the menu.")
            case .unknown: return .unknown("macOS has not been asked yet, or did not answer.")
            }
        case .sudoers:
            switch probes.sudoersRule {
            case .yes: return .complete
            case .no: return .incomplete("The rule is not installed, so Awake cannot switch sleep off and no session can start.")
            case .unknown: return .unknown("sudo did not answer the check.")
            }
        case .privacy:
            // Both are optional today (the agent layer uses them), so one
            // missing is said, not treated as broken.
            let missing = [("Accessibility", probes.accessibility), ("Screen Recording", probes.screenRecording)].filter { $0.1 != .yes }
            if missing.isEmpty { return .complete }
            let names = missing.map(\.0).joined(separator: " and ")
            if missing.contains(where: { $0.1 == .unknown }) {
                return .unknown("\(names): macOS did not say whether it is granted.")
            }
            return .incomplete("\(names) not granted. Awake keeps the Mac awake without \(missing.count == 1 ? "it" : "them"); reading agent prompts and screenshots need \(missing.count == 1 ? "it" : "them").")
        case .phoneAlerts:
            if !probes.phoneConfigured { return .incomplete("No phone service is set up, so alerts stay on the Mac.") }
            return probes.phoneTestSucceeded ? .complete : .incomplete("A topic is set. Send a test to check it reaches your phone.")
        case .tailscale:
            switch probes.tailscaleInstalled {
            case .yes: return .complete
            case .no: return .incomplete("Tailscale is not installed. Only the phone app needs it; alerts work without it.")
            case .unknown: return .unknown("Could not look for Tailscale.")
            }
        }
    }

    /// The steps that still need something, in order. Informational steps
    /// never appear.
    static func outstanding(probes: OnboardingProbes) -> [OnboardingStep] {
        OnboardingStep.allCases.filter { !status(of: $0, probes: probes).isComplete }
    }

    /// The one step without which Awake cannot do its job.
    static func canStartSessions(probes: OnboardingProbes) -> Bool {
        probes.sudoersRule == .yes
    }

    /// The summary on the last step.
    static func summary(probes: OnboardingProbes) -> String {
        let left = outstanding(probes: probes)
        if left.isEmpty { return "Everything is set up." }
        let names = left.map(\.title).joined(separator: ", ")
        if !canStartSessions(probes: probes) {
            return "Not set up yet: \(names). Awake cannot start a session until the sudoers rule is installed; \"Setup\u{2026}\" in the menu brings this window back."
        }
        return "Awake can start sessions. Skipped for now: \(names). \"Setup\u{2026}\" in the menu brings this window back."
    }

    /// The next and previous steps; nil at the ends.
    static func next(after step: OnboardingStep) -> OnboardingStep? { OnboardingStep(rawValue: step.rawValue + 1) }
    static func previous(before step: OnboardingStep) -> OnboardingStep? { OnboardingStep(rawValue: step.rawValue - 1) }

    /// The sudoers rule install.sh writes, as the window shows it: the four
    /// commands for this account. Must stay the text of install.sh's step 2.
    static func sudoersRule(user: String) -> String {
        ["-a disablesleep 1", "-a disablesleep 0", "-b lowpowermode 1", "-b lowpowermode 0"]
            .map { "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset \($0)" }
            .joined(separator: "\n")
    }

    static let sudoersPath = "/etc/sudoers.d/awake"

    /// The command "Run in Terminal" runs and "Copy" copies: the install.sh
    /// sealed in this app, asked for the sudoers rule only. Single-quoted
    /// for the shell, so a space or quote in the path stays part of it.
    static func sudoersCommand(bundle: URL) -> String {
        let script = bundle.appendingPathComponent("Contents/Resources/install.sh").path
        return "/bin/bash \(shellQuoted(script)) --sudoers-only"
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// System Settings panes.
    static let accessibilityPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let screenRecordingPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let notificationsPane = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
    static let tailscaleDownload = URL(string: "https://tailscale.com/download/mac")!

    /// Where Tailscale is looked for: the app, then the command-line tool
    /// in the places Homebrew and the app's installer put it.
    static let tailscalePaths = ["/Applications/Tailscale.app", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]

    static func tailscaleInstalled(exists: (String) -> Bool) -> OnboardingReading {
        tailscalePaths.contains(where: exists) ? .yes : .no
    }
}
