import AppKit
@preconcurrency import Sparkle

/// Whether this build can update itself with Sparkle, and if not, why.
///
/// Three things must all hold. The decision is pure so it can be tested
/// without a bundle or a signature; `AppUpdater` reads the inputs.
///
/// - The process runs from an app bundle. `swift run` and the tests have no
///   bundle for Sparkle to replace.
/// - The bundle carries an update key (`SUPublicEDKey` in Info.plist, which
///   scripts/build-app.sh writes from scripts/sparkle-public-key.txt). With
///   no key there is nothing to check a download against, and Sparkle
///   refuses to start. An empty file is the state of a checkout until the
///   owner generates a key (docs/releasing.md).
/// - The bundle is signed with Developer ID. The recovery agent pins the
///   app's designated requirement. For a Developer ID build that names the
///   bundle identifier and the team, so the next version still satisfies
///   it. For an ad-hoc build it is the hash of that one build: an update
///   in place would leave the agent pinning code that is gone, and no
///   session could start until the installer ran again. Sparkle's helper
///   tools also need a real signature to be launched from a downloaded,
///   quarantined app. So an ad-hoc build updates through the installer.
enum UpdaterAvailability: Equatable, Sendable {
    case available
    case unavailable(Reason)

    enum Reason: Equatable, Sendable {
        case notAnAppBundle
        case noUpdateKey
        case noFeed
        case notDeveloperIDSigned

        /// One sentence for the log and for the alert behind the menu item.
        var explanation: String {
            switch self {
            case .notAnAppBundle:
                "Awake is not running from an app bundle, so there is nothing to update in place."
            case .noUpdateKey:
                "This build carries no update signing key, so it cannot check that a download is genuine. It does not update itself."
            case .noFeed:
                "This build names no update feed. It does not update itself."
            case .notDeveloperIDSigned:
                "This is an unsigned (ad-hoc) build. Updating it in place would break the recovery agent's check of the app, so it does not update itself."
            }
        }
    }

    static func decide(inAppBundle: Bool, publicKey: String?, feedURL: String?, developerIDSigned: Bool) -> UpdaterAvailability {
        guard inAppBundle else { return .unavailable(.notAnAppBundle) }
        guard let publicKey, !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable(.noUpdateKey)
        }
        guard let feedURL, let url = URL(string: feedURL), url.scheme == "https" else {
            return .unavailable(.noFeed)
        }
        guard developerIDSigned else { return .unavailable(.notDeveloperIDSigned) }
        return .available
    }

    /// The answer for the running process.
    static func current(bundle: Bundle = .main) -> UpdaterAvailability {
        let info = bundle.infoDictionary ?? [:]
        let inAppBundle = Notifier.runningInsideAppBundle()
        return decide(
            inAppBundle: inAppBundle,
            publicKey: info["SUPublicEDKey"] as? String,
            feedURL: info["SUFeedURL"] as? String,
            // Read last and only for a bundle: it hashes the bundle's files.
            developerIDSigned: inAppBundle && DeveloperIDSignature.holds(for: bundle.bundleURL)
        )
    }
}

/// Whether the code at a path is signed with a Developer ID Application
/// certificate that Apple issued. The requirement is the one Gatekeeper
/// uses for Developer ID: Apple's root, the Developer ID intermediate
/// (certificate 1, field 6.2.6) and a Developer ID Application leaf (field
/// 6.1.13). An ad-hoc or self-signed bundle does not satisfy it.
enum DeveloperIDSignature {
    static let requirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    static func holds(for url: URL) -> Bool {
        do {
            try CodeRequirement.verify(codeAt: url, satisfies: requirement)
            return true
        } catch {
            return false
        }
    }
}

/// What "Check for Updates…" says when this build cannot update itself.
/// Pure so the copy is testable; the updater shows it as an NSAlert.
struct UpdaterUnavailablePrompt: Equatable {
    static let openReleasesTitle = "Open releases page"
    static let closeTitle = "OK"

    let title: String
    let message: String

    init(reason: UpdaterAvailability.Reason, installed: AppBuild = .current) {
        title = "Awake \(installed.label) does not update itself"
        message = "\(reason.explanation)\n\nTo upgrade, download the newest release and run its installer again, or run `brew upgrade --cask awake` if you installed with Homebrew. Settings > App > \"Check for updates\" tells you whether a newer release exists."
    }
}

/// The app's updater: Sparkle when this build can use it, an explanation
/// when it cannot. Created once by the app delegate; the status item's
/// "Check for Updates…" calls `checkForUpdates()`.
///
/// Nothing here runs unless `availability` is `.available`, so a build
/// with an empty key never creates a Sparkle object: it logs why and the
/// menu item explains.
///
/// Sparkle only ever downloads and installs after the user says so
/// (`automaticallyDownloadsUpdates` is off). No check, automatic or by
/// hand, runs while a session is active: an install quits the app, and a
/// quit ends the session.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    let availability: UpdaterAvailability
    private let sessionActive: @MainActor () -> Bool
    private var controller: SPUStandardUpdaterController?

    static let sessionRunningMessage = "A session is running. Awake checks for updates once it has ended, because installing one quits the app and ends the session."

    init(availability: UpdaterAvailability = .current(), sessionActive: @escaping @MainActor () -> Bool) {
        self.availability = availability
        self.sessionActive = sessionActive
        super.init()
    }

    /// Starts Sparkle when this build can use it. `automaticChecks` is the
    /// user's setting (Config.automaticUpdates).
    func start(automaticChecks: Bool) {
        switch availability {
        case let .unavailable(reason):
            Log.info("updater disabled: \(reason.explanation)")
        case .available:
            let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
            // Set before the first scheduled check; also answers Sparkle's
            // "check automatically?" question so it is never asked.
            controller.updater.automaticallyChecksForUpdates = automaticChecks
            controller.updater.automaticallyDownloadsUpdates = false
            self.controller = controller
            Log.info("updater started: automatic checks \(automaticChecks ? "on" : "off"), feed \(controller.updater.feedURL?.absoluteString ?? "none")")
        }
    }

    /// Follows the Settings toggle.
    func setAutomaticChecks(_ on: Bool) {
        controller?.updater.automaticallyChecksForUpdates = on
    }

    /// The menu item. Sparkle shows its own window; a build that cannot
    /// update itself gets the explanation and a way to the releases page.
    func checkForUpdates() {
        if let controller {
            NSApp.activate(ignoringOtherApps: true)
            controller.checkForUpdates(nil)
            return
        }
        guard case let .unavailable(reason) = availability else { return }
        let prompt = UpdaterUnavailablePrompt(reason: reason)
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .informational
        alert.addButton(withTitle: UpdaterUnavailablePrompt.openReleasesTitle)
        alert.addButton(withTitle: UpdaterUnavailablePrompt.closeTitle)
        // A menu bar app has no window to carry the alert.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(GitHubReleaseFetcher.releasesPage)
        }
    }

    // MARK: SPUUpdaterDelegate

    /// Sparkle asks before every check. Refusing here covers the scheduled
    /// check and the menu item alike; for the menu item Sparkle shows the
    /// message.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try refuseDuringSession()
    }

    /// Throws the error Sparkle shows while a session is active.
    func refuseDuringSession() throws {
        if sessionActive() {
            throw NSError(domain: "com.parthjairam.awake.updater", code: 1, userInfo: [NSLocalizedDescriptionKey: Self.sessionRunningMessage])
        }
    }
}
