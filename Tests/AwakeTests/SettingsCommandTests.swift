import AppKit
import SwiftUI
import XCTest
@testable import Awake

/// The app menu's "Settings…" used to come from an empty SwiftUI `Settings`
/// scene and opened an empty "Awake Settings" window. There is one settings
/// window, and the app menu, Cmd-comma and the status item all open it.
@MainActor
final class SettingsCommandTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Comments aside, so the explanation of the old scene does not count.
    private func code(_ path: String) throws -> String {
        try source(path).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testTheAppHasNoSwiftUISettingsSceneAndNoWindowScene() throws {
        let app = try code("Sources/Awake/AwakeApp.swift")
        XCTAssertNil(app.range(of: #"\bSettings\s*\{"#, options: .regularExpression), "a SwiftUI Settings scene makes its own (empty) window")
        XCTAssertNil(app.range(of: #"\b(WindowGroup|Window|DocumentGroup)\s*[\(\{]"#, options: .regularExpression), "a window scene the app does not need")
        XCTAssertTrue(app.contains("isInserted: .constant(false)"), "the placeholder scene must never be inserted")
    }

    func testTheAppMenuItemReplacesTheSystemOneAndOpensTheRealWindow() throws {
        let app = try code("Sources/Awake/AwakeApp.swift")
        XCTAssertTrue(app.contains("CommandGroup(replacing: .appSettings)"))
        XCTAssertTrue(app.contains("Button(SettingsCommand.title) { delegate.showSettings() }"))
        XCTAssertTrue(app.contains(".keyboardShortcut(SettingsCommand.key, modifiers: .command)"))
        XCTAssertEqual(SettingsCommand.title, "Settings…")
        XCTAssertEqual(SettingsCommand.key, KeyEquivalent(","))
        // The status item opens settings the same way.
        XCTAssertTrue(app.contains("self?.showSettings()"))
        XCTAssertEqual(app.components(separatedBy: "settingsWindow?.show()").count - 1, 1, "one place shows the settings window")
        XCTAssertEqual(app.components(separatedBy: "SettingsWindow {").count - 1, 1, "one settings window is made")
    }

    /// The window is made once, with the content it was given, and every
    /// request gets that same window.
    func testThereIsOneSettingsWindowWithTheRealContent() {
        var built = 0
        let settings = SettingsWindow {
            built += 1
            return AnyView(Text("real settings").frame(width: 320, height: 200))
        }
        let first = settings.prepared()
        let second = settings.prepared()
        XCTAssertTrue(first === second)
        XCTAssertEqual(built, 1)
        XCTAssertEqual(first.title, "Awake Settings")
        XCTAssertFalse(first.isReleasedWhenClosed)
        XCTAssertGreaterThanOrEqual(first.contentRect(forFrameRect: first.frame).width, 320, "the window has the size of its content, not of an empty view")
        XCTAssertFalse(first.isVisible, "preparing the window does not show it")
    }
}
