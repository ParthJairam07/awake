import AppKit
import SwiftUI

/// Menu bar app. The status item is an `NSStatusItem` hosting SwiftUI, and
/// the settings window is an `NSWindow` this app opens itself (see
/// `SettingsWindow`), so there is no SwiftUI scene with any content in it.
/// `App` still requires one, hence the empty `Settings`. main.swift starts
/// this app unless the command line asks for a one-shot mode first.
struct AwakeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let manager: SessionManager
    let status: any StatusSource
    let secrets: any HotspotSecretStore
    let phoneSecrets: any PhoneSecretStore = KeychainPhoneSecretStore()
    let locationPermission: LocationPermission
    let loginItem = LoginItem()
    let releases = ReleaseChecker()
    /// Step E: Sparkle, when this build can update itself (Updater.swift).
    private(set) lazy var updater = AppUpdater { [manager] in manager.isActive }
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindow?
    private var onboarding: OnboardingWindow?
    private var terminating = false

    override init() {
        let manager = SessionManager.live()
        self.manager = manager
        secrets = KeychainHotspotSecretStore(keychain: KeychainStore()) {
            manager.config.hotspotSSID
        }
        if let services = manager.services {
            status = LiveStatusSource(services: services)
            locationPermission = services.locationPermission
        } else {
            Log.error("live SessionManager has no AppServices; using placeholder status")
            status = PlaceholderStatus()
            locationPermission = LocationPermission()
        }
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before launch finishes, so the first notification already shows
        // while Awake is frontmost.
        ForegroundNotifications.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon even when run from `swift run` (the bundle has LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        Log.info("launched, version \(AppBuild.current.label)")
        if LidSimulationBuild.isCompiledIn {
            Log.info(LidSimulationBuild.marker)
        }
        // The login item is tied to the bundle's signature, which install.sh
        // renews on every run: register again if the flag is on, macOS no
        // longer reports the item and the install changed; follow the user
        // if they removed the item for the install macOS had on file.
        var config = manager.config
        if loginItem.healAtLaunch(config: &config) {
            manager.config = config
            do {
                try manager.store.saveConfig(config)
            } catch {
                Log.error("could not save config after the launch at login check: \(error.localizedDescription)")
            }
        }
        let settings = SettingsWindow { [manager, secrets, phoneSecrets, locationPermission, loginItem, releases, updater] in
            AnyView(
                SettingsView(
                    manager: manager,
                    secrets: secrets,
                    phoneSecrets: phoneSecrets,
                    locationPermission: locationPermission,
                    loginItem: loginItem,
                    releases: releases,
                    updater: updater
                )
            )
        }
        settingsWindow = settings
        statusItem = StatusItemController(manager: manager, status: status) { [weak settings] in
            settings?.show()
        }
        // Step E: updates.
        updater.start(automaticChecks: manager.config.automaticUpdates)
        statusItem?.checkForUpdates = { [updater] in updater.checkForUpdates() }
        // Step E: first-run setup, and "Setup…" in the menu to reopen it.
        onboarding = Onboarding.wire(manager: manager, loginItem: loginItem, statusItem: statusItem, appIsQuitting: { [weak self] in self?.terminating ?? false })
        Task {
            await manager.reconcile()
            // Phase 4: after the reconcile, so the leases meet the session
            // found on disk rather than start one beside it.
            manager.leases?.start()
            // Phase 3: the phone app runs with the app, not with a session,
            // and the phone starts sessions too. After the reconcile, so a
            // request from a paired phone meets the session found on disk
            // rather than start one beside it.
            manager.services?.startPhoneApp(for: manager)
        }
    }

    /// Quitting always ends the session (spec 1). Terminate is deferred until
    /// the end has run. A second quit while that is pending is refused rather
    /// than allowed through: `.terminateNow` there would exit mid-cleanup.
    /// If the end could not run (recovery lock busy, journal unreadable),
    /// left the journal dirty with no agent to retry, or could not remove
    /// session.json, the app stays so its own retry can finish the job;
    /// quitting then would abandon a live session. It also stays while a
    /// `sudo pmset` that ignored SIGTERM is alive. The recovery lock would
    /// outlive a quit (the command holds it through its own descriptor),
    /// but the end the command holds up would not: the app is what retries
    /// it, and confirms an undo the command finishes, the moment it exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateCancel }
        terminating = true
        Task {
            let outcome = await manager.end(reason: .quit)
            if outcome.letsQuitGo {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                Log.error("quit deferred: recovery still pending (\(outcome)); staying to retry")
                terminating = false
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
