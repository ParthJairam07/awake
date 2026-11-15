import XCTest
@testable import Awake

final class FakeDialogProbe: DialogProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _trusted = true
    private var _dialogs: [DetectedDialog] = []
    private var _asked: [[DialogTarget]] = []
    private var _requests = 0
    var trusted: Bool {
        get { lock.withLock { _trusted } }
        set { lock.withLock { _trusted = newValue } }
    }
    var found: [DetectedDialog] {
        get { lock.withLock { _dialogs } }
        set { lock.withLock { _dialogs = newValue } }
    }
    var asked: [[DialogTarget]] { lock.withLock { _asked } }
    var requests: Int { lock.withLock { _requests } }
    func isTrusted() -> Bool { trusted }
    func dialogs(in targets: [DialogTarget]) -> [DetectedDialog] {
        lock.withLock { _asked.append(targets) }
        return found
    }
    func requestTrust() { lock.withLock { _requests += 1 } }
}

@MainActor
final class DialogDetectorTests: XCTestCase {
    private let probe = FakeDialogProbe()
    private let notifier = RecordingNotifier()
    private var config = Config()
    private var idle: Double = 600
    private let keychain = DetectedDialog(app: "SecurityAgent", title: "", text: "git wants to use your confidential information stored in \"github.com\" in your keychain.", buttons: ["Always Allow", "Deny", "Allow"])

    private final class Idle: @unchecked Sendable { var value: Double = 600 }
    private let idleBox = Idle()

    private func makeWatcher() -> DialogWatcher {
        let box = idleBox
        let watcher = DialogWatcher(probe: probe, notifier: notifier, idleSeconds: { box.value }, pollInterval: 3600, config: { [unowned self] in self.config }) {
            [DialogTarget(pid: 77, name: "SecurityAgent", systemPrompt: true)]
        }
        watcher.start()
        return watcher
    }

    func testADialogIsReportedOnceWithTitleTextAndButtons() async {
        probe.found = [DetectedDialog(app: "Terminal", title: "Close this window?", text: "Closing will terminate claude.", buttons: ["Cancel", "Terminate"]), keychain]
        let watcher = makeWatcher()
        defer { watcher.stop() }
        await watcher.check()
        await watcher.check()
        XCTAssertEqual(notifier.titles, ["Dialog blocking: Terminal \u{2014} Close this window?", "Dialog blocking: SecurityAgent"])
        XCTAssertEqual(notifier.posts[0].body, "Closing will terminate claude. Buttons: Cancel, Terminate.")
        XCTAssertTrue(notifier.posts[1].body.hasSuffix("Buttons: Always Allow, Deny, Allow."))
        XCTAssertEqual(probe.asked.first, [DialogTarget(pid: 77, name: "SecurityAgent", systemPrompt: true)])
    }

    func testTheSameDialogComingBackLaterIsReportedAgain() async {
        probe.found = [keychain]
        let watcher = makeWatcher()
        defer { watcher.stop() }
        await watcher.check()
        probe.found = []
        await watcher.check()
        probe.found = [keychain]
        await watcher.check()
        XCTAssertEqual(notifier.posts.count, 1, "gone for one check is a flicker")
        probe.found = []
        await watcher.check()
        await watcher.check()
        probe.found = [keychain]
        await watcher.check()
        XCTAssertEqual(notifier.posts.count, 2)
    }

    func testNothingIsReadWithoutPermissionOrWithTheToggleOffOrWhileSomeoneIsAtTheMac() async {
        probe.found = [keychain]
        let watcher = makeWatcher()
        defer { watcher.stop() }
        probe.trusted = false
        await watcher.check()
        probe.trusted = true
        config.dialogAlerts = false
        await watcher.check()
        config.dialogAlerts = true
        idleBox.value = 5
        await watcher.check()
        XCTAssertTrue(probe.asked.isEmpty)
        XCTAssertTrue(notifier.posts.isEmpty)
        idleBox.value = 60
        await watcher.check()
        XCTAssertEqual(notifier.posts.count, 1)
        XCTAssertEqual(probe.requests, 0, "the watcher never asks for permission itself")
    }

    func testStoppedWatcherDoesNothing() async {
        probe.found = [keychain]
        let watcher = makeWatcher()
        watcher.stop()
        await watcher.check()
        XCTAssertTrue(notifier.posts.isEmpty)
    }

    func testTargetsAreSystemPromptsTheFrontmostAppAndAgentApps() {
        let apps = [
            RunningApp(pid: 10, bundleId: "com.apple.finder", name: "Finder"),
            RunningApp(pid: 11, bundleId: "com.apple.Terminal", name: "Terminal"),
            RunningApp(pid: 12, bundleId: "com.apple.Safari", name: "Safari"),
            RunningApp(pid: 13, bundleId: nil, name: "SecurityAgent", activationPolicy: .accessory),
            RunningApp(pid: 14, bundleId: "com.apple.UserNotificationCenter", name: "UserNotificationCenter", activationPolicy: .accessory),
            RunningApp(pid: 15, bundleId: Paths.bundleIdentifier, name: "Awake", activationPolicy: .accessory),
            RunningApp(pid: 16, bundleId: "com.example.editor", name: "Editor"),
        ]
        let targets = DialogRules.targets(apps: apps, frontmostPid: 12, agentBundleIds: ["com.apple.Terminal"], agentPids: [16], selfPid: 15)
        XCTAssertEqual(targets.map(\.pid), [13, 14, 11, 12, 16])
        XCTAssertEqual(targets.map(\.systemPrompt), [true, true, false, false, false])
        XCTAssertTrue(DialogRules.targets(apps: apps, frontmostPid: 15, agentBundleIds: [], selfPid: 15).allSatisfy(\.systemPrompt), "never Awake's own windows")
    }

    func testDialogKeyIsAppTitleAndText() {
        let a = DetectedDialog(app: "A", title: "T", text: "x", buttons: ["OK"])
        XCTAssertEqual(a.key, DetectedDialog(app: "A", title: "T", text: "x", buttons: ["Cancel"]).key)
        XCTAssertNotEqual(a.key, DetectedDialog(app: "A", title: "T", text: "y", buttons: ["OK"]).key)
        XCTAssertNotEqual(a.key, DetectedDialog(app: "AT", title: "", text: "x", buttons: []).key)
    }

    func testAlertForAnEmptyDialogAndPermissionText() {
        let alert = DialogRules.alert(for: DetectedDialog(app: "CoreServicesUIAgent", title: " ", text: "", buttons: []))
        XCTAssertEqual(alert.title, "Dialog blocking: CoreServicesUIAgent")
        XCTAssertEqual(alert.body, "A dialog is waiting for an answer.")
        XCTAssertTrue(DialogRules.permissionStatus(trusted: false).contains("not allowed"))
        XCTAssertTrue(DialogRules.permissionStatus(trusted: true).hasPrefix("Accessibility is allowed"))
    }

    /// The real reader compiles and, without the permission (the test
    /// runner has none), reads nothing.
    func testRealProbeReadsNothingWithoutPermission() {
        let real = AXDialogProbe()
        if !real.isTrusted() {
            XCTAssertEqual(real.dialogs(in: [DialogTarget(pid: getpid(), name: "xctest")]), [])
        }
    }
}

final class AgentGitTests: XCTestCase {
    private let shell = FakeShellRunner()
    private var git: AgentGit { AgentGit(runner: shell, git: "/opt/homebrew/bin/git") }

    private func gitArgs() -> [[String]] { shell.calls.map { Array($0.args.dropFirst(4)) } }

    func testWipCommitRunsStatusAddCommitPushWithPromptsOffAndNoForce() async {
        shell.on(["status", "--porcelain"], FakeShellRunner.ok(" M main.swift\n"))
        let result = await git.wipCommit(repo: "/Users/x/api")
        XCTAssertEqual(result, .pushed)
        XCTAssertEqual(gitArgs(), [["status", "--porcelain"], ["add", "-A"], ["commit", "--no-verify", "-m", "wip: awake auto-save before session end"], ["push"]])
        for call in shell.calls {
            XCTAssertEqual(call.exe, "/usr/bin/env")
            XCTAssertEqual(Array(call.args.prefix(4)), ["GIT_TERMINAL_PROMPT=0", "/opt/homebrew/bin/git", "-C", "/Users/x/api"])
            XCTAssertLessThanOrEqual(call.timeout, 60)
            XCTAssertFalse(call.args.contains { $0.contains("force") || $0 == "-f" || $0 == "sudo" })
        }
    }

    func testACleanRepoIsLeftAlone() async {
        let result = await git.wipCommit(repo: "/r")
        XCTAssertEqual(result, .clean)
        XCTAssertEqual(gitArgs(), [["status", "--porcelain"]])
    }

    func testAFailedStepStopsTheRestAndNamesItself() async {
        shell.on(["status", "--porcelain"], FakeShellRunner.ok("?? new.txt\n"))
        shell.on(["push"], FakeShellRunner.fail(128, "fatal: The current branch wip has no upstream branch.\n"))
        let pushFailed = await git.wipCommit(repo: "/r")
        XCTAssertEqual(pushFailed, .failed("push: exit 128: fatal: The current branch wip has no upstream branch."))

        let second = FakeShellRunner()
        second.on(["status", "--porcelain"], FakeShellRunner.ok("?? new.txt\n"))
        second.on(["commit"], .timedOut)
        let commitFailed = await AgentGit(runner: second, git: "/g").wipCommit(repo: "/r")
        XCTAssertEqual(commitFailed, .failed("commit: timed out"))
        XCTAssertFalse(second.calls.contains { $0.args.contains("push") })
    }

    func testTheSixtySecondsAreOneBudgetForTheWholeRepo() async {
        shell.on(["status", "--porcelain"], FakeShellRunner.ok(" M a\n"))
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        // Every git call "takes" 25 s.
        let slow = SlowRunner(inner: shell) { clock.advance(25) }
        let result = await AgentGit(runner: slow, git: "/g").wipCommit(repo: "/r", now: { clock.now })
        XCTAssertEqual(shell.calls.map(\.timeout), [60, 35, 10])
        XCTAssertEqual(result, .failed("push: timed out"), "nothing is started once the budget is spent")
    }

    private struct SlowRunner: ShellRunning {
        let inner: FakeShellRunner
        let tick: @Sendable () -> Void
        func run(_ exe: String, _ args: [String], timeout: TimeInterval) async -> ShellOutcome {
            let outcome = await inner.run(exe, args, timeout: timeout)
            tick()
            return outcome
        }
    }

    func testWithoutGitNothingRuns() async {
        let none = AgentGit(runner: shell, git: nil)
        let wip = await none.wipCommit(repo: "/r")
        let count = await none.unpushedCount(repo: "/r")
        XCTAssertEqual(wip, .failed("git not found"))
        XCTAssertNil(count)
        XCTAssertTrue(shell.calls.isEmpty)
        XCTAssertFalse(AgentGit.candidates.contains("/usr/bin/git"), "the shim opens an install dialog on a Mac without the developer tools")
    }

    /// The live runner against a throwaway repo in a temp directory with a
    /// local bare remote: no network.
    func testWipCommitAndUnpushedAgainstARealLocalRepo() async throws {
        guard let gitPath = Shell.locate(AgentGit.candidates) else { throw XCTSkip("git is not installed") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("awake-git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let remote = root.appendingPathComponent("remote.git").path
        let work = root.appendingPathComponent("work").path
        try FileManager.default.createDirectory(atPath: root.path, withIntermediateDirectories: true)
        func run(_ args: [String]) async throws {
            let r = try await Shell.run(gitPath, args, timeout: 30)
            XCTAssertTrue(r.succeeded, "\(args): \(r.stderr)")
        }
        try await run(["init", "--bare", "-q", remote])
        try await run(["init", "-q", "-b", "main", work])
        for (key, value) in [("user.name", "Awake Test"), ("user.email", "test@example.invalid"), ("commit.gpgsign", "false")] {
            try await run(["-C", work, "config", key, value])
        }
        try Data("one\n".utf8).write(to: URL(fileURLWithPath: work + "/a.txt"))
        try await run(["-C", work, "add", "-A"])
        try await run(["-C", work, "commit", "-q", "-m", "first"])
        let live = AgentGit(git: gitPath)
        let noUpstream = await live.unpushedCount(repo: work)
        XCTAssertNil(noUpstream, "no upstream: skipped")
        try await run(["-C", work, "remote", "add", "origin", remote])
        try await run(["-C", work, "push", "-q", "-u", "origin", "main"])
        let none = await live.unpushedCount(repo: work)
        XCTAssertEqual(none, 0)

        let clean = await live.wipCommit(repo: work)
        XCTAssertEqual(clean, .clean)
        try Data("two\n".utf8).write(to: URL(fileURLWithPath: work + "/b.txt"))
        let pushed = await live.wipCommit(repo: work)
        XCTAssertEqual(pushed, .pushed)
        let log = try await Shell.run(gitPath, ["--git-dir", remote, "log", "-1", "--format=%s", "main"], timeout: 30)
        XCTAssertEqual(log.stdout, "wip: awake auto-save before session end\n", "the commit reached the remote")
        try Data("three\n".utf8).write(to: URL(fileURLWithPath: work + "/c.txt"))
        try await run(["-C", work, "add", "-A"])
        try await run(["-C", work, "commit", "-q", "-m", "local only"])
        let behind = await live.unpushedCount(repo: work)
        XCTAssertEqual(behind, 1)
    }
}

@MainActor
final class PreEndTests: XCTestCase {
    private let shell = FakeShellRunner()

    private func makeRunner(_ h: Harness, config: Config, repos: [String]) -> (PreEndRunner, () -> SessionReport) {
        let clock = h.clock
        let runner = PreEndRunner(paths: h.home.paths, notifier: h.notifier, git: AgentGit(runner: shell, git: "/g"), clock: { clock.now }, config: { config }, repos: { repos })
        let box = ReportBox()
        runner.onReport = { change in change(&box.report) }
        return (runner, { box.report })
    }

    @MainActor
    private final class ReportBox {
        var report = SessionReport(startedAt: Date(timeIntervalSince1970: 0), plannedEnd: Date(timeIntervalSince1970: 10), batteryStart: nil)
    }

    private func journal(_ h: Harness) throws -> PreEndJournal? {
        try h.store.read(PreEndJournal.self, from: h.home.paths.preEndFile)
    }

    func testOffByDefaultNothingHappens() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let (runner, _) = makeRunner(h, config: Config(), repos: ["/r"])
        await runner.run(reason: .batteryFloor)
        XCTAssertTrue(h.notifier.posts.isEmpty)
        XCTAssertTrue(shell.calls.isEmpty)
        XCTAssertNil(try journal(h))
    }

    func testNoticeAndJournalWithoutTheWipCommit() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        var config = Config()
        config.preEndHooks = true
        let (runner, report) = makeRunner(h, config: config, repos: ["/Users/x/api"])
        await runner.run(reason: .timer)
        XCTAssertEqual(h.notifier.titles, ["Session ending"])
        XCTAssertEqual(h.notifier.posts[0].body, "Ending now: time was up.")
        XCTAssertTrue(shell.calls.isEmpty, "wip commit is its own opt-in")
        let j = try XCTUnwrap(try journal(h))
        XCTAssertEqual(j.reason, "timer")
        XCTAssertFalse(j.wipCommit)
        XCTAssertEqual(j.repos, [])
        XCTAssertNotNil(j.finishedAt)
        XCTAssertNil(report().wipPushed)
    }

    func testWipCommitJournalsIntentBeforeEachRepoAndResultsAfter() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        var config = Config()
        config.preEndHooks = true
        config.wipCommitOnEnd = true
        shell.on(["status", "--porcelain"], FakeShellRunner.ok(" M x\n"))
        shell.on(["-C", "/Users/x/web", "push"], FakeShellRunner.fail(1, "rejected"))
        let store = h.store, file = h.home.paths.preEndFile
        // What the journal says at the moment each repo's first git runs.
        let seen = Seen()
        let spy = SpyRunner(inner: shell) { args in
            guard args.contains("status") else { return }
            if let j = (try? store.read(PreEndJournal.self, from: file)) ?? nil { seen.add(j) }
        }
        let clock = h.clock
        let runner = PreEndRunner(paths: h.home.paths, notifier: h.notifier, git: AgentGit(runner: spy, git: "/g"), clock: { clock.now }, config: { config }, repos: { ["/Users/x/api", "/Users/x/web", "/Users/x/docs"] })
        let box = ReportBox()
        runner.onReport = { change in change(&box.report) }
        await runner.run(reason: .batteryFloor)

        XCTAssertEqual(seen.journals.map(\.running), ["/Users/x/api", "/Users/x/web", "/Users/x/docs"], "intent on disk before the repo is touched")
        XCTAssertEqual(seen.journals[1].results, ["/Users/x/api": .pushed], "result on disk after")
        XCTAssertNil(seen.journals[0].finishedAt)
        XCTAssertEqual(h.notifier.titles, ["Session ending"])
        XCTAssertEqual(h.notifier.posts[0].body, "Ending now: battery floor. Saving work in 3 repos first (commit and push, up to 60 s each).")
        let j = try XCTUnwrap(try journal(h))
        XCTAssertEqual(j.results, ["/Users/x/api": .pushed, "/Users/x/web": .failed("push: exit 1: rejected"), "/Users/x/docs": .pushed])
        XCTAssertNil(j.running)
        XCTAssertNotNil(j.finishedAt)
        XCTAssertEqual(box.report.wipPushed, ["/Users/x/api", "/Users/x/docs"])
        XCTAssertEqual(box.report.wipFailed, ["/Users/x/web"])
        XCTAssertEqual(box.report.agentParts(), ["wip pushed: 2 repos, failed: 1."])
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _journals: [PreEndJournal] = []
        var journals: [PreEndJournal] { lock.withLock { _journals } }
        func add(_ j: PreEndJournal) { lock.withLock { _journals.append(j) } }
    }

    private struct SpyRunner: ShellRunning {
        let inner: FakeShellRunner
        let before: @Sendable ([String]) -> Void
        func run(_ exe: String, _ args: [String], timeout: TimeInterval) async -> ShellOutcome {
            before(args)
            return await inner.run(exe, args, timeout: timeout)
        }
    }

    func testIfTheJournalCannotBeWrittenNothingIsCommitted() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        var config = Config()
        config.preEndHooks = true
        config.wipCommitOnEnd = true
        // A directory where the file should go: the atomic rename fails.
        try FileManager.default.createDirectory(at: h.home.paths.preEndFile.appendingPathComponent("x"), withIntermediateDirectories: true)
        let (runner, _) = makeRunner(h, config: config, repos: ["/r"])
        await runner.run(reason: .batteryHot)
        XCTAssertTrue(shell.calls.isEmpty, "journal first: no record, no git")
        XCTAssertEqual(h.notifier.posts.map(\.body), ["Ending now: battery too hot."])
    }

    func testASecondCallWhileOneRunsDoesNotSaveTwice() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        var config = Config()
        config.preEndHooks = true
        config.wipCommitOnEnd = true
        let (runner, _) = makeRunner(h, config: config, repos: ["/r"])
        async let first: Void = runner.run(reason: .timer)
        async let second: Void = runner.run(reason: .batteryFloor)
        _ = await (first, second)
        XCTAssertEqual(h.notifier.titles, ["Session ending"])
        XCTAssertEqual(shell.calls.filter { $0.args.contains("status") }.count, 1)
    }

    func testAnUnfinishedJournalIsReportedOnceAtTheNextStart() throws {
        let h = Harness()
        defer { h.home.destroy() }
        var left = PreEndJournal(reason: "batteryFloor", startedAt: h.clock.now, wipCommit: true, repos: ["/Users/x/api", "/Users/x/web"])
        left.running = "/Users/x/api"
        try h.store.write(left, to: h.home.paths.preEndFile)
        var config = Config()
        config.preEndHooks = true
        let (runner, _) = makeRunner(h, config: config, repos: [])
        runner.settleLeftover()
        runner.settleLeftover()
        XCTAssertEqual(h.notifier.titles, ["Pre-end save interrupted"])
        XCTAssertEqual(h.notifier.posts[0].body, "The save before the last session end was cut short while saving api. Not saved: api, web. Check those repos by hand.")
        XCTAssertNotNil(try journal(h)?.finishedAt)
    }

    // MARK: Where the manager calls it

    func testFloorEndRunsThePreEndFirstAndOnlyWithTheSettingOn() async {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 3600)
        var calls: [String] = []
        m.preEnd = { reason in calls.append("\(reason.rawValue), active \(m.isActive)") }
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)

        await m.runPreEnd(.batteryFloor)
        XCTAssertEqual(calls, [], "off by default")

        m.config.preEndHooks = true
        await driver.run(battery: .percent(5), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertEqual(calls, ["batteryFloor, active true"], "before the end, while the session still holds sleep")
        XCTAssertFalse(m.isActive)
        await m.runPreEnd(.batteryFloor)
        XCTAssertEqual(calls.count, 1, "nothing outside a session")
    }

    func testASessionEndedDuringThePreEndIsNotEndedAgainByTheFloor() async {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 3600)
        m.config.preEndHooks = true
        m.preEnd = { _ in await m.end(reason: .user) }
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .percent(5), isCharging: false, thermal: .nominal, lidClosed: false)
        XCTAssertEqual(h.notifier.titles.filter { $0 == "Session ended" }.count, 1)
    }
}

@MainActor
final class AgentPauserTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ kind: AgentKind, pid: Int32, children: [Int32] = [], sudo: Bool = false, state: AgentHookAction? = nil) -> AgentRecord {
        var r = AgentRecord(id: "\(kind.rawValue)-\(pid)", kind: kind, name: kind.displayName, rootPid: pid, identity: ProcessIdentity(startedAt: Int64(pid)), firstSeen: t0, lastSeen: t0, machine: AgentStateMachine(firstSeen: t0))
        r.pids = [pid] + children
        r.parents = [pid: 1]
        r.identities = [pid: ProcessIdentity(startedAt: Int64(pid))]
        for child in children {
            r.parents[child] = pid
            r.identities[child] = ProcessIdentity(startedAt: Int64(child))
        }
        r.hasSudo = sudo
        r.sightings = 2
        if let state { r.machine.ingest(hook: state, at: t0, hasProcess: true) }
        return r
    }

    private func lowCodex() -> Config {
        var c = Config()
        c.priorityPause = true
        c.agentPriorities = ["codex": PausePlanner.low, "claude": PausePlanner.high]
        return c
    }

    func testLowestPriorityFirstAndNeverTheHighestPresent() {
        let agents = [agent(.claude, pid: 10), agent(.codex, pid: 20), agent(.aider, pid: 30), agent(.gemini, pid: 40)]
        let c = lowCodex()
        XCTAssertEqual(PausePlanner.nextTier(agents: agents, paused: [], config: c).map(\.id), ["codex-20"])
        XCTAssertEqual(PausePlanner.nextTier(agents: agents, paused: ["codex-20"], config: c).map(\.id), ["aider-30", "gemini-40"])
        XCTAssertEqual(PausePlanner.nextTier(agents: agents, paused: ["codex-20", "aider-30", "gemini-40"], config: c), [], "the highest priority keeps running")
    }

    func testWithEveryAgentAtOnePriorityNothingIsPaused() {
        var c = Config()
        c.priorityPause = true
        XCTAssertEqual(PausePlanner.nextTier(agents: [agent(.claude, pid: 10), agent(.codex, pid: 20)], paused: [], config: c), [])
        XCTAssertEqual(PausePlanner.nextTier(agents: [], paused: [], config: c), [])
    }

    func testSudoAndGoneAgentsAreNeverPaused() {
        let c = lowCodex()
        XCTAssertEqual(PausePlanner.protection(agent(.codex, pid: 20, sudo: true)), "sudo is running under it")
        XCTAssertNil(PausePlanner.protection(agent(.codex, pid: 20, state: .waiting("Allow?"))), "an ordinary question does not protect")
        var atSudo = agent(.codex, pid: 20)
        atSudo.machine.ingest(AgentSample(at: t0, paneText: "Password:"))
        atSudo.machine.ingest(AgentSample(at: t0.addingTimeInterval(20), paneText: "Password:"))
        XCTAssertEqual(PausePlanner.protection(atSudo), "it is at a sudo password prompt")
        XCTAssertEqual(PausePlanner.nextTier(agents: [agent(.claude, pid: 10), atSudo, agent(.codex, pid: 21, sudo: true)], paused: [], config: c), [])
        var hookOnly = agent(.hookOnly, pid: 0)
        hookOnly.rootPid = nil
        XCTAssertEqual(PausePlanner.protection(hookOnly), "no process")
        var gone = agent(.codex, pid: 22)
        gone.machine.ingest(AgentSample(at: t0, present: false))
        XCTAssertEqual(PausePlanner.protection(gone), "exited")
    }

    func testPriorityByNameBeatsKindAndUnlistedIsNormal() {
        var c = Config()
        c.agentPriorities = ["tmux": -1, "nightly": 1]
        var pane = agent(.tmuxPane, pid: 5)
        XCTAssertEqual(PausePlanner.priority(of: pane, config: c), -1)
        pane.name = "nightly"
        XCTAssertEqual(PausePlanner.priority(of: pane, config: c), 1)
        XCTAssertEqual(PausePlanner.priority(of: agent(.claude, pid: 1), config: c), 0)
    }

    func testPressureSources() {
        XCTAssertEqual(PausePlanner.pressure(lowPowerCause: nil, thermal: .nominal, memoryCritical: false), [])
        XCTAssertEqual(PausePlanner.pressure(lowPowerCause: .lid, thermal: .fair, memoryCritical: false), [], "a closed lid is not pressure")
        XCTAssertEqual(PausePlanner.pressure(lowPowerCause: .battery, thermal: .nominal, memoryCritical: true), [.battery, .memory])
        XCTAssertEqual(PausePlanner.pressure(lowPowerCause: .thermal, thermal: .nominal, memoryCritical: false), [.thermal])
        XCTAssertEqual(PausePlanner.pressure(lowPowerCause: nil, thermal: .serious, memoryCritical: false), [.thermal])
    }

    private func setUpPauser(_ h: Harness, agents: [AgentRecord]) async -> (SessionManager, AgentPauser) {
        let m = h.makeManager()
        await m.start(duration: 3600)
        m.config = lowCodex()
        let clock = h.clock
        let freezer = FakeFreezer(apps: [], processes: [], control: h.procs)
        let pauser = AgentPauser(manager: m, freezer: freezer, notifier: h.notifier, clock: { clock.now }, stepInterval: 60) { agents }
        return (m, pauser)
    }

    func testPausesJournalFirstOneTierAStepAndResumesInTheSameOrder() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let agents = [agent(.claude, pid: 10), agent(.codex, pid: 20, children: [21]), agent(.aider, pid: 30)]
        let (m, pauser) = await setUpPauser(h, agents: agents)
        let store = h.store
        // What state.json holds at the moment of the SIGSTOP.
        nonisolated(unsafe) var journaledAtSignal: [[FrozenProcess]] = []
        h.procs.onSuspend = { _ in journaledAtSignal.append((try? store.loadState())??.frozenProcesses ?? []) }
        let before = h.notifier.posts.count

        await pauser.update(pressure: [.battery])
        XCTAssertEqual(h.procs.suspended, [[20, 21]])
        XCTAssertEqual(journaledAtSignal, [[FrozenProcess(pid: 20, identity: nil), FrozenProcess(pid: 21, identity: nil)]], "journaled without identity before the signal")
        XCTAssertEqual(try store.loadState()?.frozenProcesses, [FrozenProcess(pid: 20, startedAt: 20), FrozenProcess(pid: 21, startedAt: 21)], "promoted once confirmed")
        XCTAssertEqual(pauser.paused.map(\.id), ["codex-20"])
        XCTAssertEqual(h.notifier.posts[before].title, "Agents paused")
        XCTAssertEqual(h.notifier.posts[before].body, "Paused codex (lowest priority first) because of battery under the Low Power Mode floor. They resume when it clears.")

        await pauser.update(pressure: [.battery])
        XCTAssertEqual(h.procs.suspended.count, 1, "one tier a minute")
        h.clock.advance(60)
        await pauser.update(pressure: [.battery, .thermal])
        XCTAssertEqual(h.procs.suspended, [[20, 21], [30]])
        h.clock.advance(60)
        await pauser.update(pressure: [.battery])
        XCTAssertEqual(h.procs.suspended.count, 2, "claude, the highest, is never paused")

        await pauser.update(pressure: [])
        XCTAssertEqual(h.procs.resumed.last, [20, 21, 30], "same order as paused")
        XCTAssertEqual(try store.loadState()?.frozenProcesses, [])
        XCTAssertEqual(pauser.paused, [])
        XCTAssertEqual(h.notifier.posts.last?.title, "Agents resumed")
        XCTAssertEqual(h.notifier.posts.last?.body, "Resumed codex, aider: the pressure cleared.")
        XCTAssertTrue(m.isActive)
    }

    func testOffByDefaultAndTurningItOffResumes() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let (m, pauser) = await setUpPauser(h, agents: [agent(.claude, pid: 10), agent(.codex, pid: 20)])
        m.config.priorityPause = false
        await pauser.update(pressure: [.memory])
        XCTAssertTrue(h.procs.suspended.isEmpty)
        m.config.priorityPause = true
        await pauser.update(pressure: [.memory])
        XCTAssertEqual(h.procs.suspended, [[20]])
        m.config.priorityPause = false
        await pauser.update(pressure: [.memory])
        XCTAssertEqual(h.procs.signaled, [20])
        XCTAssertEqual(h.notifier.posts.last?.body, "Resumed codex: priority pause was turned off.")
    }

    func testAProcessTheKernelWillNotStopIsNotJournaledOrCounted() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let (_, pauser) = await setUpPauser(h, agents: [agent(.claude, pid: 10), agent(.codex, pid: 20)])
        h.procs.refuseSuspend = [20]
        let before = h.notifier.posts.count
        await pauser.update(pressure: [.thermal])
        XCTAssertEqual(try h.store.loadState()?.frozenProcesses, [])
        XCTAssertEqual(pauser.paused, [])
        XCTAssertEqual(h.notifier.posts.count, before, "nothing paused, nothing announced")
    }

    func testTheSessionEndResumesPausedAgentsFromTheJournal() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let (m, pauser) = await setUpPauser(h, agents: [agent(.claude, pid: 10), agent(.codex, pid: 20)])
        await pauser.update(pressure: [.battery])
        XCTAssertEqual(h.procs.stoppedNow, [20])
        await m.end(reason: .user)
        XCTAssertEqual(h.procs.stoppedNow, [], "the end undoes it like any freeze")
        XCTAssertEqual(try h.store.loadState()?.frozenProcesses ?? [], [])
        pauser.stop()
        await pauser.update(pressure: [.battery])
        XCTAssertEqual(h.procs.suspended.count, 1, "nothing outside a session")
    }

    func testAgentsResumedByALidOpenArePausedAgainWhilePressureLasts() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let (m, pauser) = await setUpPauser(h, agents: [agent(.claude, pid: 10), agent(.codex, pid: 20)])
        await pauser.update(pressure: [.battery])
        await m.undoLidActions()
        XCTAssertEqual(h.procs.stoppedNow, [], "the lid open resumes everything journaled")
        await pauser.update(pressure: [.battery])
        XCTAssertEqual(h.procs.suspended, [[20], [20]])
        XCTAssertEqual(h.procs.stoppedNow, [20])
        XCTAssertEqual(pauser.paused.map(\.id), ["codex-20"])
    }
}
