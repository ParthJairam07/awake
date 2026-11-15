import SwiftUI

/// Step E: the one call the app delegate makes. Builds the Setup window,
/// gives the menu its "Setup\u{2026}" item, and shows the window when setup has
/// never been finished or closed (`Config.onboardingDone == false`).
@MainActor
enum Onboarding {
    /// Whether to show the window at launch. Not while a session is running
    /// (a relaunch after a crash mid-session has recovery to do, and the
    /// user already got that far), and not for a run outside an app bundle.
    static func shouldShowAtLaunch(config: Config, sessionActive: Bool, inAppBundle: Bool) -> Bool {
        !config.onboardingDone && !sessionActive && inAppBundle
    }

    /// Record that setup was seen, so the next launch does not show it.
    static func markDone(manager: SessionManager) {
        guard !manager.config.onboardingDone else { return }
        manager.config.onboardingDone = true
        do {
            try manager.store.saveConfig(manager.config)
        } catch {
            Log.error("could not save config after setup: \(error.localizedDescription)")
        }
    }

    static func wire(manager: SessionManager, loginItem: LoginItem, statusItem: StatusItemController?) -> OnboardingWindow {
        let window = OnboardingWindow(
            content: { close in AnyView(OnboardingView(manager: manager, loginItem: loginItem, close: close)) },
            onClose: { markDone(manager: manager) }
        )
        statusItem?.showSetup = { [weak window] in window?.show() }
        if shouldShowAtLaunch(config: manager.config, sessionActive: manager.session != nil || manager.store.sessionEntryExists(), inAppBundle: Notifier.runningInsideAppBundle()) {
            Log.info("setup: first run, showing the Setup window")
            window.show()
        }
        return window
    }
}
