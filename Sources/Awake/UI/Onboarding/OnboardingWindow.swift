import AppKit
import SwiftUI

/// Step E: the Setup window, owned by AppKit like `SettingsWindow`.
/// `onClose` runs when the window closes, however that happens.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let content: (@escaping () -> Void) -> AnyView
    private let onClose: () -> Void

    init(content: @escaping (@escaping () -> Void) -> AnyView, onClose: @escaping () -> Void) {
        self.content = content
        self.onClose = onClose
    }

    func show() {
        let window = window ?? make()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    private func make() -> NSWindow {
        let host = NSHostingController(rootView: content { [weak self] in self?.window?.close() })
        let window = NSWindow(contentViewController: host)
        window.title = "Awake Setup"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose()
    }
}
