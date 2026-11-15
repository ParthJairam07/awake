import AppKit
import XCTest
@testable import Awake

/// Step E: when the app updates itself with Sparkle and when it explains
/// instead, the menu item, and the setting. Nothing here creates a Sparkle
/// object: the test process is not an app bundle, which is one of the cases.
@MainActor
final class UpdaterTests: XCTestCase {
    private let key = "oLs+QL40I8rnQvpZV8QTYgRII43U9qmdBrHWvQ5qUbY="
    private let feed = "https://github.com/ParthJairam07/awake/releases/latest/download/appcast.xml"

    func testTheUpdaterNeedsABundleAKeyAFeedAndADeveloperIDSignature() {
        XCTAssertEqual(UpdaterAvailability.decide(inAppBundle: true, publicKey: key, feedURL: feed, developerIDSigned: true), .available)
        XCTAssertEqual(UpdaterAvailability.decide(inAppBundle: false, publicKey: key, feedURL: feed, developerIDSigned: true), .unavailable(.notAnAppBundle))
        for empty in [nil, "", "  \n"] as [String?] {
            XCTAssertEqual(UpdaterAvailability.decide(inAppBundle: true, publicKey: empty, feedURL: feed, developerIDSigned: true), .unavailable(.noUpdateKey),
                           "an empty key file leaves no SUPublicEDKey; Sparkle must not start")
        }
        for bad in [nil, "", "http://example.com/appcast.xml", "not a url"] as [String?] {
            XCTAssertEqual(UpdaterAvailability.decide(inAppBundle: true, publicKey: key, feedURL: bad, developerIDSigned: true), .unavailable(.noFeed), "\(bad ?? "nil")")
        }
        XCTAssertEqual(UpdaterAvailability.decide(inAppBundle: true, publicKey: key, feedURL: feed, developerIDSigned: false), .unavailable(.notDeveloperIDSigned),
                       "an ad-hoc build is pinned by its cdhash; an update in place would strand the recovery agent")
        // The key is checked before the signature: today's builds have neither.
        XCTAssertEqual(UpdaterAvailability.decide(inAppBundle: true, publicKey: nil, feedURL: feed, developerIDSigned: false), .unavailable(.noUpdateKey))
    }

    /// The test process is no app bundle, so the live answer is the first
    /// refusal and the updater built on it starts nothing.
    func testOutsideAnAppBundleTheUpdaterStaysOffAndStartDoesNothing() {
        XCTAssertEqual(UpdaterAvailability.current(), .unavailable(.notAnAppBundle))
        let updater = AppUpdater(sessionActive: { false })
        XCTAssertEqual(updater.availability, .unavailable(.notAnAppBundle))
        updater.start(automaticChecks: true)
        updater.setAutomaticChecks(false)
    }

    /// The bundle's Info.plist names the feed the Release workflow
    /// publishes, over https, and carries no key of its own: build-app.sh
    /// adds SUPublicEDKey from scripts/sparkle-public-key.txt.
    func testInfoPlistNamesTheFeedAndLeavesTheKeyToTheBuild() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["SUFeedURL"] as? String, feed)
        XCTAssertNil(info["SUPublicEDKey"])
        XCTAssertEqual(UpdaterAvailability.decide(inAppBundle: true, publicKey: key, feedURL: info["SUFeedURL"] as? String, developerIDSigned: true), .available)
    }

    /// The Developer ID requirement: Apple's anchor, the Developer ID
    /// intermediate and a Developer ID Application leaf. An ad-hoc signed
    /// scratch bundle and an unsigned file do not satisfy it.
    func testAnAdHocBundleIsNotDeveloperIDSigned() throws {
        XCTAssertEqual(DeveloperIDSignature.requirement,
                       "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists")
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("updater-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        let app = scratch.appendingPathComponent("Awake.app", isDirectory: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Awake").path)
        try Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.parthjairam.awake</string><key>CFBundleExecutable</key><string>Awake</string></dict></plist>
            """.utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        let exit = ProcessExit(sign)
        try sign.run()
        exit.wait()
        XCTAssertEqual(sign.terminationStatus, 0)

        XCTAssertFalse(DeveloperIDSignature.holds(for: app), "ad-hoc")
        let plain = scratch.appendingPathComponent("plain.txt")
        try Data("x".utf8).write(to: plain)
        XCTAssertFalse(DeveloperIDSignature.holds(for: plain), "unsigned")
        // Apple's own code is signed by Apple, not with Developer ID.
        XCTAssertFalse(DeveloperIDSignature.holds(for: URL(fileURLWithPath: "/usr/bin/true")))
    }

    /// Each reason reads as a full sentence, and the alert behind the menu
    /// item names the installed version and both ways to upgrade.
    func testEveryRefusalExplainsItselfAndTheAlertSaysHowToUpgrade() {
        let reasons: [UpdaterAvailability.Reason] = [.notAnAppBundle, .noUpdateKey, .noFeed, .notDeveloperIDSigned]
        XCTAssertEqual(Set(reasons.map(\.explanation)).count, reasons.count)
        for reason in reasons {
            XCTAssertTrue(reason.explanation.hasSuffix("."), reason.explanation)
            let prompt = UpdaterUnavailablePrompt(reason: reason, installed: AppBuild(version: "0.2.0", build: "0.2.0"))
            XCTAssertEqual(prompt.title, "Awake 0.2.0 (0.2.0) does not update itself")
            XCTAssertTrue(prompt.message.hasPrefix(reason.explanation), prompt.message)
            XCTAssertTrue(prompt.message.contains("run its installer again"), prompt.message)
            XCTAssertTrue(prompt.message.contains("brew upgrade --cask awake"), prompt.message)
            XCTAssertEqual(SettingsView.updateNote(.unavailable(reason)), "\(reason.explanation) The button above still tells you whether a newer release exists.")
        }
        XCTAssertTrue(UpdaterAvailability.Reason.notDeveloperIDSigned.explanation.contains("unsigned (ad-hoc) build"))
        XCTAssertTrue(SettingsView.updateNote(.available).contains("never during a session"))
    }

    /// No check runs during a session: Sparkle asks the delegate before
    /// every check, scheduled or from the menu, and the refusal carries the
    /// sentence Sparkle shows.
    func testNoUpdateCheckRunsWhileASessionIsActive() {
        let during = AppUpdater(sessionActive: { true })
        XCTAssertThrowsError(try during.refuseDuringSession()) { error in
            XCTAssertEqual(error.localizedDescription, AppUpdater.sessionRunningMessage)
        }
        let idle = AppUpdater(sessionActive: { false })
        XCTAssertNoThrow(try idle.refuseDuringSession())
        XCTAssertTrue(AppUpdater.sessionRunningMessage.contains("A session is running"))
        XCTAssertTrue(AppUpdater.sessionRunningMessage.contains("ends the session"))
    }

    /// "Check for Updates…" sits between Settings… and Quit, and only in a
    /// menu whose controller has an updater: the item list the other tests
    /// pin is unchanged without one.
    func testTheMenuGetsCheckForUpdatesAfterSettingsOnlyWhenWired() {
        let plain = StatusMenu.items(sessionActive: false, sleepHeld: false, machine: "Lid: open", actions: nil, throttledBrowsers: [], error: nil)
        XCTAssertEqual(StatusMenu.withAppItems(plain, checkForUpdates: false), plain)
        let wired = StatusMenu.withAppItems(plain, checkForUpdates: true)
        XCTAssertEqual(wired.map(\.kind), [.info, .separator, .settings, .checkForUpdates, .quit])
        XCTAssertEqual(wired[3].title, "Check for Updates\u{2026}")

        final class Target: NSObject {
            @objc func settings() {}
            @objc func quit() {}
            @objc func relaunch(_ sender: NSMenuItem) {}
            @objc func stopWaiting(_ sender: NSMenuItem) {}
            @objc func updates() {}
        }
        let target = Target()
        let menu = StatusMenu.menu(wired, target: target, settings: #selector(Target.settings), quit: #selector(Target.quit),
                                   relaunchBrowser: #selector(Target.relaunch(_:)), stopWaitingForOutput: #selector(Target.stopWaiting(_:)),
                                   checkForUpdates: #selector(Target.updates))
        let item = try? XCTUnwrap(menu.items.first { $0.title == StatusMenu.checkForUpdatesTitle })
        XCTAssertEqual(item?.action, #selector(Target.updates))
        XCTAssertEqual(item?.isEnabled, true)
        XCTAssertTrue(item?.target === target)
        // Built without the selector, the item is left out, not dead.
        let without = StatusMenu.menu(wired, target: target, settings: #selector(Target.settings), quit: #selector(Target.quit),
                                      relaunchBrowser: #selector(Target.relaunch(_:)), stopWaitingForOutput: #selector(Target.stopWaiting(_:)))
        XCTAssertNil(without.items.first { $0.title == StatusMenu.checkForUpdatesTitle })
    }

    /// A status item with an updater calls it from the menu; one without
    /// (every other test's) has no such item.
    func testTheStatusItemCallsTheUpdaterItWasGiven() {
        let h = Harness()
        let controller = StatusItemController(manager: h.makeManager(), status: PlaceholderStatus(), showSettings: {})
        XCTAssertNil(controller.checkForUpdates)
        var calls = 0
        controller.checkForUpdates = { calls += 1 }
        controller.perform(NSSelectorFromString("menuCheckForUpdates"))
        XCTAssertEqual(calls, 1)
    }

    /// The setting defaults to on, survives a round trip, and a config.json
    /// an earlier build wrote (no key) reads as the default.
    func testAutomaticUpdatesDefaultsOnAndDecodesFromAnOlderConfig() throws {
        XCTAssertTrue(Config().automaticUpdates)
        let older = try JSONDecoder().decode(Config.self, from: Data(#"{"launchAtLogin": true}"#.utf8))
        XCTAssertTrue(older.automaticUpdates)
        XCTAssertTrue(older.launchAtLogin)
        var config = Config()
        config.automaticUpdates = false
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertFalse(back.automaticUpdates)
        XCTAssertEqual(back, config)
    }
}
