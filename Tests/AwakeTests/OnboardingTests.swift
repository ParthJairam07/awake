import Foundation
import XCTest
@testable import Awake

/// Step E: the Setup window's step model over fake probes, the probe over a
/// fake sudo, the text the sudoers step shows, the menu item, and
/// `install.sh --sudoers-only` with a fake sudo.
@MainActor
final class OnboardingTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private let allSet = OnboardingProbes(
        notifications: .yes, sudoersRule: .yes, accessibility: .yes, screenRecording: .yes,
        phoneConfigured: true, phoneTestSucceeded: true, tailscaleInstalled: .yes
    )

    // MARK: Step model

    func testTheSevenStepsAreInTheOrderTheWindowShowsThem() {
        XCTAssertEqual(OnboardingStep.allCases, [.welcome, .notifications, .sudoers, .privacy, .phoneAlerts, .tailscale, .done])
        XCTAssertNil(OnboardingModel.previous(before: .welcome))
        XCTAssertEqual(OnboardingModel.next(after: .welcome), .notifications)
        XCTAssertEqual(OnboardingModel.previous(before: .done), .tailscale)
        XCTAssertNil(OnboardingModel.next(after: .done))
    }

    func testEveryStepIsCompleteWhenEveryProbeSaysYes() {
        for step in OnboardingStep.allCases {
            XCTAssertTrue(OnboardingModel.status(of: step, probes: allSet).isComplete, "\(step)")
        }
        XCTAssertEqual(OnboardingModel.status(of: .welcome, probes: allSet), .informational)
        XCTAssertEqual(OnboardingModel.status(of: .done, probes: allSet), .informational)
        XCTAssertEqual(OnboardingModel.outstanding(probes: allSet), [])
        XCTAssertEqual(OnboardingModel.summary(probes: allSet), "Everything is set up.")
    }

    /// A fresh Mac: nothing read yet. The informational steps are never
    /// outstanding; everything else is, and nothing claims to be granted.
    func testNothingIsCompleteBeforeAnythingIsRead() {
        let fresh = OnboardingProbes()
        XCTAssertEqual(OnboardingModel.outstanding(probes: fresh), [.notifications, .sudoers, .privacy, .phoneAlerts, .tailscale])
        XCTAssertFalse(OnboardingModel.canStartSessions(probes: fresh))
        for step in [OnboardingStep.notifications, .sudoers, .privacy, .tailscale] {
            guard case .unknown = OnboardingModel.status(of: step, probes: fresh) else {
                return XCTFail("\(step) should be unknown, is \(OnboardingModel.status(of: step, probes: fresh))")
            }
        }
    }

    func testEachProbeDecidesItsOwnStepOnly() {
        var p = allSet
        p.notifications = .no
        XCTAssertEqual(OnboardingModel.outstanding(probes: p), [.notifications])
        p = allSet
        p.sudoersRule = .no
        XCTAssertEqual(OnboardingModel.outstanding(probes: p), [.sudoers])
        guard case .incomplete(let why) = OnboardingModel.status(of: .sudoers, probes: p) else { return XCTFail() }
        XCTAssertTrue(why.contains("no session can start"), why)
        p = allSet
        p.tailscaleInstalled = .no
        XCTAssertEqual(OnboardingModel.outstanding(probes: p), [.tailscale])
    }

    /// An unknown reading is never shown as granted and never as refused.
    func testAnUnknownReadingIsReportedAsUnknown() {
        var p = allSet
        p.sudoersRule = .unknown
        guard case .unknown = OnboardingModel.status(of: .sudoers, probes: p) else { return XCTFail() }
        XCTAssertFalse(OnboardingModel.canStartSessions(probes: p))
        p = allSet
        p.screenRecording = .unknown
        guard case .unknown(let why) = OnboardingModel.status(of: .privacy, probes: p) else { return XCTFail() }
        XCTAssertTrue(why.hasPrefix("Screen Recording:"), why)
    }

    func testThePrivacyStepNeedsBothPermissionsAndNamesTheMissingOnes() {
        var p = allSet
        p.accessibility = .no
        guard case .incomplete(let one) = OnboardingModel.status(of: .privacy, probes: p) else { return XCTFail() }
        XCTAssertTrue(one.hasPrefix("Accessibility not granted. Awake keeps the Mac awake without it;"), one)
        p.screenRecording = .no
        guard case .incomplete(let both) = OnboardingModel.status(of: .privacy, probes: p) else { return XCTFail() }
        XCTAssertTrue(both.hasPrefix("Accessibility and Screen Recording not granted. Awake keeps the Mac awake without them;"), both)
    }

    /// A topic alone is not complete: the test has to have been accepted.
    func testPhoneAlertsAreCompleteOnlyAfterATestWasAccepted() {
        var p = allSet
        p.phoneTestSucceeded = false
        guard case .incomplete(let why) = OnboardingModel.status(of: .phoneAlerts, probes: p) else { return XCTFail() }
        XCTAssertTrue(why.contains("Send a test"), why)
        p.phoneConfigured = false
        p.phoneTestSucceeded = true
        guard case .incomplete(let none) = OnboardingModel.status(of: .phoneAlerts, probes: p) else { return XCTFail() }
        XCTAssertTrue(none.contains("No phone service"), none)
    }

    /// The last step says plainly when the one required thing is missing,
    /// and otherwise lists what was skipped.
    func testTheSummarySaysWhetherSessionsCanStart() {
        var p = allSet
        p.tailscaleInstalled = .no
        p.notifications = .no
        XCTAssertEqual(OnboardingModel.summary(probes: p),
                       "Awake can start sessions. Skipped for now: Notifications, Tailscale. \"Setup\u{2026}\" in the menu brings this window back.")
        p.sudoersRule = .no
        XCTAssertTrue(OnboardingModel.summary(probes: p).contains("Awake cannot start a session until the sudoers rule is installed"))
    }

    // MARK: Sudoers text and command

    /// The rule the window shows is, line for line, the rule install.sh
    /// writes; and install.sh writes no other rule line.
    func testTheRuleShownIsTheRuleInstallShWrites() throws {
        let install = try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
        let written = install.components(separatedBy: "\n").filter { $0.hasPrefix("$USER ALL=") }.map { $0.replacingOccurrences(of: "$USER", with: "alex") }
        XCTAssertEqual(OnboardingModel.sudoersRule(user: "alex").components(separatedBy: "\n"), written)
        XCTAssertEqual(written.count, 4)
        XCTAssertTrue(install.contains("SUDOERS=\(OnboardingModel.sudoersPath)\n"))
        XCTAssertEqual(OnboardingProbe.pmsetCommands.map { "alex ALL=(root) NOPASSWD: /usr/bin/pmset " + $0.joined(separator: " ") }, written,
                       "the probe asks sudo about the same four commands")
    }

    /// The command runs the install.sh sealed in this bundle, quoted so a
    /// space or a quote in the path cannot split it or start a new command.
    func testTheTerminalCommandQuotesTheBundlePath() {
        XCTAssertEqual(OnboardingModel.sudoersCommand(bundle: URL(fileURLWithPath: "/Applications/Awake.app")),
                       "/bin/bash '/Applications/Awake.app/Contents/Resources/install.sh' --sudoers-only")
        XCTAssertEqual(OnboardingModel.sudoersCommand(bundle: URL(fileURLWithPath: "/Users/a b/it's; rm -rf x/Awake.app")),
                       #"/bin/bash '/Users/a b/it'\''s; rm -rf x/Awake.app/Contents/Resources/install.sh' --sudoers-only"#)
    }

    /// The file Terminal gets holds that one command, and only its owner
    /// can read or run it.
    func testTheCommandFileIsOwnerOnlyAndHoldsOnlyTheCommand() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("onboarding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let command = OnboardingModel.sudoersCommand(bundle: URL(fileURLWithPath: "/Applications/Awake.app"))
        var file = try OnboardingActions.writeCommandFile(command: command, directory: dir)
        file = try OnboardingActions.writeCommandFile(command: command, directory: dir) // replaces
        XCTAssertEqual(file.lastPathComponent, "setup-sudoers.command")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }, ["exec \(command)"])
        XCTAssertFalse(text.contains("sudo "), "the file itself runs no sudo; install.sh asks in Terminal")
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue, 0o700)
    }

    func testThePanesAndLinksAreTheOnesTheStepsName() {
        XCTAssertEqual(OnboardingModel.accessibilityPane.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(OnboardingModel.screenRecordingPane.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        XCTAssertEqual(OnboardingModel.tailscaleDownload.scheme, "https")
    }

    // MARK: Probe

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [[String]] = []
        var all: [[String]] { lock.withLock { _all } }
        func add(_ c: [String]) { lock.withLock { _all.append(c) } }
    }

    private struct Boom: Error {}

    private func probe(sudo: @escaping @Sendable ([String]) throws -> Int32, calls: Calls = Calls(), exists: Set<String> = []) -> OnboardingProbe {
        OnboardingProbe(
            notifications: { .yes }, accessibility: { .no }, screenRecording: { .yes },
            fileExists: { exists.contains($0) },
            run: { exe, args in
                calls.add([exe] + args)
                return ShellResult(status: try sudo(args), stdout: "", stderr: "")
            }
        )
    }

    /// The rule check lists the four commands with `sudo -n -l`, which runs
    /// none of them, and needs all four.
    func testTheSudoersProbeListsTheFourCommandsAndRunsNone() async {
        let calls = Calls()
        let granted = await probe(sudo: { _ in 0 }, calls: calls).sudoersRule()
        XCTAssertEqual(granted, .yes)
        XCTAssertEqual(calls.all, [
            ["/usr/bin/sudo", "-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "1"],
            ["/usr/bin/sudo", "-n", "-l", "/usr/bin/pmset", "-a", "disablesleep", "0"],
            ["/usr/bin/sudo", "-n", "-l", "/usr/bin/pmset", "-b", "lowpowermode", "1"],
            ["/usr/bin/sudo", "-n", "-l", "/usr/bin/pmset", "-b", "lowpowermode", "0"],
        ])
        let partial = await probe(sudo: { $0.last == "0" && $0.contains("lowpowermode") ? 1 : 0 }).sudoersRule()
        XCTAssertEqual(partial, .no, "three of four is not the rule")
        let none = await probe(sudo: { _ in 1 }).sudoersRule()
        XCTAssertEqual(none, .no)
        let broken = await probe(sudo: { _ in throw Boom() }).sudoersRule()
        XCTAssertEqual(broken, .unknown, "a sudo that could not be run is not a refusal")
    }

    func testAReadCombinesTheProbesTheConfigAndTheWindowsTestResult() async {
        var config = Config()
        var read = await probe(sudo: { _ in 0 }, exists: ["/opt/homebrew/bin/tailscale"]).read(config: config, phoneTestSucceeded: false)
        XCTAssertEqual(read, OnboardingProbes(notifications: .yes, sudoersRule: .yes, accessibility: .no, screenRecording: .yes,
                                              phoneConfigured: false, phoneTestSucceeded: false, tailscaleInstalled: .yes))
        config.ntfyTopic = "a-long-random-topic"
        read = await probe(sudo: { _ in 1 }).read(config: config, phoneTestSucceeded: true)
        XCTAssertTrue(read.phoneConfigured)
        XCTAssertTrue(read.phoneTestSucceeded)
        XCTAssertEqual(read.tailscaleInstalled, .no)
        XCTAssertEqual(read.sudoersRule, .no)
    }

    func testTailscaleIsFoundAsTheAppOrTheCommand() {
        for path in ["/Applications/Tailscale.app", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"] {
            XCTAssertEqual(OnboardingModel.tailscaleInstalled(exists: { $0 == path }), .yes, path)
        }
        XCTAssertEqual(OnboardingModel.tailscaleInstalled(exists: { _ in false }), .no)
    }

    // MARK: Config, launch and menu

    /// A config.json from before Step E has no key: setup shows once.
    func testOnboardingDoneDefaultsToFalseAndRoundTrips() throws {
        XCTAssertFalse(Config().onboardingDone)
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertFalse(old.onboardingDone)
        var config = Config()
        config.onboardingDone = true
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
        XCTAssertTrue(back.onboardingDone)
    }

    func testSetupShowsAtLaunchOnlyOnceAndNeverOverASession() {
        var config = Config()
        XCTAssertTrue(Onboarding.shouldShowAtLaunch(config: config, sessionActive: false, inAppBundle: true))
        XCTAssertFalse(Onboarding.shouldShowAtLaunch(config: config, sessionActive: true, inAppBundle: true))
        XCTAssertFalse(Onboarding.shouldShowAtLaunch(config: config, sessionActive: false, inAppBundle: false))
        config.onboardingDone = true
        XCTAssertFalse(Onboarding.shouldShowAtLaunch(config: config, sessionActive: false, inAppBundle: true))
    }

    /// "Setup…" sits after Settings… and before Check for Updates… and
    /// Quit, and a menu built without it is unchanged.
    func testTheSetupItemSitsBetweenSettingsAndCheckForUpdates() {
        let plain = StatusMenu.items(sessionActive: false, sleepHeld: false, machine: "Lid: open", actions: nil, throttledBrowsers: [], error: nil)
        XCTAssertEqual(StatusMenu.withAppItems(plain, checkForUpdates: false, setup: false), plain)
        let titles = StatusMenu.withAppItems(plain, checkForUpdates: true, setup: true).map(\.title)
        let settings = try? XCTUnwrap(titles.firstIndex(of: StatusMenu.settingsTitle))
        XCTAssertEqual(StatusMenu.setupTitle, "Setup\u{2026}")
        XCTAssertEqual(Array(titles[(settings ?? 0)...]), [StatusMenu.settingsTitle, StatusMenu.setupTitle, StatusMenu.checkForUpdatesTitle, StatusMenu.quitTitle])
        XCTAssertEqual(StatusMenu.withAppItems(plain, checkForUpdates: false, setup: true).map(\.kind).filter { $0 == .setup }.count, 1)
    }

    // MARK: install.sh --sudoers-only

    /// With a fake sudo: the rule is validated, installed and checked, and
    /// the script stops there. No bundle is built or copied, no agent is
    /// loaded, and the flag refuses to be combined with --app.
    func testSudoersOnlyWritesTheRuleAndNothingElse() throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("sudoers-only-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: scratch) }
        try fm.createDirectory(at: scratch.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        let log = scratch.appendingPathComponent("calls")
        let sudo = scratch.appendingPathComponent("sudo")
        try TestScripts.write("""
            #!/bin/bash
            printf 'sudo %s\\n' "$*" >> '\(log.path)'
            if [[ "$1" == install ]]; then /bin/cp "$8" '\(scratch.path)/installed-rule'; fi
            exit 0

            """, to: sudo)
        let forbidden = scratch.appendingPathComponent("forbidden")
        try TestScripts.write("#!/bin/bash\nprintf 'forbidden %s %s\\n' \"$0\" \"$*\" >> '\(log.path)'\nexit 1\n", to: forbidden)
        var lines = try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/install.sh"), encoding: .utf8).components(separatedBy: "\n")
        for (name, value) in ["SUDO": sudo.path, "LAUNCHCTL": forbidden.path, "CODESIGN": forbidden.path, "DITTO": forbidden.path,
                              "OSASCRIPT": forbidden.path, "PGREP": forbidden.path, "CURL": forbidden.path] {
            let hits = lines.indices.filter { lines[$0].hasPrefix("\(name)=") }
            XCTAssertEqual(hits.count, 1, "install.sh must have exactly one \(name)= line")
            lines[hits[0]] = "\(name)='\(value)'"
        }
        let script = scratch.appendingPathComponent("install.sh")
        try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)

        func run(_ args: [String]) throws -> (status: Int32, output: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path] + args
            p.environment = ["PATH": "/usr/bin:/bin", "HOME": scratch.path, "TMPDIR": scratch.appendingPathComponent("tmp").path, "USER": "alex"]
            p.currentDirectoryURL = scratch
            let outURL = scratch.appendingPathComponent("out.\(UUID().uuidString)")
            fm.createFile(atPath: outURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: outURL)
            defer { try? out.close() }
            p.standardOutput = out
            p.standardError = out
            p.standardInput = FileHandle.nullDevice
            let childExit = ProcessExit(p)
            try p.run()
            childExit.wait()
            return (p.terminationStatus, (try? String(contentsOf: outURL, encoding: .utf8)) ?? "")
        }

        let r = try run(["--sudoers-only"])
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(r.output.contains("sudoers rule verified"), r.output)
        XCTAssertTrue(r.output.contains("Nothing else was changed"), r.output)
        let calls = try String(contentsOf: log, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(calls.filter { $0.hasPrefix("forbidden") }, [], "nothing but sudo ran")
        XCTAssertEqual(calls.count, 6, "\(calls)")
        XCTAssertTrue(calls[0].hasPrefix("sudo visudo -cf "), calls[0])
        XCTAssertNotNil(calls[1].range(of: #"^sudo install -m 0440 -o root -g wheel \S+ /etc/sudoers\.d/awake$"#, options: .regularExpression), calls[1])
        XCTAssertEqual(Array(calls[2...]), OnboardingProbe.pmsetCommands.map { "sudo -n -l /usr/bin/pmset " + $0.joined(separator: " ") })
        let rule = try String(contentsOf: scratch.appendingPathComponent("installed-rule"), encoding: .utf8)
        XCTAssertEqual(rule.components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty },
                       OnboardingModel.sudoersRule(user: "alex").components(separatedBy: "\n"))
        XCTAssertFalse(fm.fileExists(atPath: scratch.appendingPathComponent("Applications").path), "no bundle was installed")
        XCTAssertFalse(fm.fileExists(atPath: scratch.appendingPathComponent("Library").path), "no agent or state was written")

        for args in [["--sudoers-only", "--app", "/x/Awake.app"], ["--sudoers-only", "--allow-unverified-origin"]] {
            let refused = try run(args)
            XCTAssertEqual(refused.status, 2, refused.output)
        }
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }.count, 6, "a refused run calls nothing")
    }
}
