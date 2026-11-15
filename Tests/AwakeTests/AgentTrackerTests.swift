import XCTest
@testable import Awake

@MainActor
final class AgentTrackerTests: XCTestCase {
    private let probe = FakeAgentProbe()
    private let tmux = FakeTmux()
    private let notifier = RecordingNotifier()
    private let shell = FakeShellRunner()
    private let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
    private var config = Config()
    private var report = SessionReport(startedAt: Date(timeIntervalSince1970: 1_800_000_000), plannedEnd: Date(timeIntervalSince1970: 1_800_003_600), batteryStart: 90)
    private var published: [[AgentStatus]] = []

    private func makeTracker() -> AgentTracker {
        let clock = self.clock
        let tracker = AgentTracker(
            probe: probe, tmux: tmux, notifier: notifier,
            git: AgentGit(runner: shell, git: "/usr/bin/git"),
            clock: { clock.now },
            repoRoot: { $0.hasPrefix("/Users/x/api") ? "/Users/x/api" : nil },
            logModified: { _ in nil },
            pollInterval: 3600,
            config: { [unowned self] in self.config }
        )
        tracker.onChange = { [unowned self] in self.published.append($0) }
        tracker.onReport = { [unowned self] change in change(&self.report) }
        tracker.start()
        return tracker
    }

    /// One poll, then `seconds` later.
    private func poll(_ tracker: AgentTracker, after seconds: TimeInterval = 20) async {
        clock.advance(seconds)
        await tracker.poll()
    }

    private func claudeInPane(_ text: String) {
        probe.add(500, exe: "/bin/zsh")
        probe.add(501, parent: 500, exe: "/x/claude", cwd: "/Users/x/api/src")
        tmux.paneList = [TmuxPane(id: "%1", target: "main:0.0", pid: 500)]
        tmux.text = ["%1": text]
    }

    func testWaitingAlertIsPostedOncePerTransitionWithThePromptAndRepo() async {
        claudeInPane("Do you want to proceed?\n❯ 1. Yes\n  2. No")
        let tracker = makeTracker()
        defer { tracker.stop() }
        await poll(tracker)
        XCTAssertTrue(notifier.posts.isEmpty, "one sighting is not an agent yet")
        XCTAssertTrue(published.last?.isEmpty ?? false)
        await poll(tracker)
        XCTAssertEqual(notifier.titles, ["Agent waiting: claude"])
        XCTAssertEqual(notifier.posts[0].body, "Do you want to proceed? (api)")
        await poll(tracker)
        await poll(tracker)
        XCTAssertEqual(notifier.titles.count, 1, "once per transition")
        let status = try? XCTUnwrap(published.last?.first)
        XCTAssertEqual(status?.state, .waitingForInput)
        XCTAssertEqual(status?.waitingPrompt, "Do you want to proceed?")
        XCTAssertEqual(status?.repo, "api")
        XCTAssertEqual(status?.tmuxTarget, "main:0.0")
        XCTAssertEqual(status?.kind, "claude")
        XCTAssertEqual(status?.lastOutputAgeSeconds, 60)
        // Answered, then asked again: a second alert.
        tmux.text = ["%1": "Running…"]
        await poll(tracker)
        tmux.text = ["%1": "Allow? (y/n)"]
        await poll(tracker)
        await poll(tracker)
        XCTAssertEqual(notifier.titles, ["Agent waiting: claude", "Agent waiting: claude"])
        XCTAssertEqual(report.agents?["claude-501-501.0"]?.waited, true)
    }

    func testStalledAndExitedAlerts() async {
        config.agentStallMinutes = 2
        claudeInPane("✻ Working… (esc to interrupt)")
        let tracker = makeTracker()
        defer { tracker.stop() }
        await poll(tracker)
        await poll(tracker)
        await poll(tracker, after: 60)
        XCTAssertTrue(notifier.posts.isEmpty)
        await poll(tracker, after: 60)
        XCTAssertEqual(notifier.titles, ["Agent stalled: claude"])
        XCTAssertEqual(notifier.posts[0].body, "No output for 2 min, api.")
        probe.remove(501)
        await poll(tracker)
        XCTAssertEqual(notifier.titles, ["Agent stalled: claude", "Agent exited: claude"])
        XCTAssertEqual(notifier.posts[1].body, "The process is gone; exit status unknown (api).")
        XCTAssertEqual(report.agents?["claude-501-501.0"], AgentReportEntry(name: "claude", repo: "api", lastState: .exited, stalled: true))
    }

    func testEachAlertHasItsToggle() async {
        config.agentWaitingAlerts = false
        config.agentExitedAlerts = false
        claudeInPane("Allow? (y/n)")
        let tracker = makeTracker()
        defer { tracker.stop() }
        await poll(tracker)
        await poll(tracker)
        probe.remove(501)
        await poll(tracker)
        XCTAssertTrue(notifier.posts.isEmpty)
        XCTAssertEqual(published.last?.first?.state, .exited, "the state is tracked whatever the alerts say")
    }

    func testAllAgentsFinishedOnceAfterTheWaitAndAgainOnlyAfterWork() async {
        config.allDoneMinutes = 1
        claudeInPane("Done.\n❯ ")
        probe.add(600, exe: "/x/codex")
        probe.add(700, exe: "/usr/local/bin/ollama", args: ["ollama", "serve"])
        let tracker = makeTracker()
        defer { tracker.stop() }
        await poll(tracker)
        probe.burn(700, seconds: 15) // the model server stays busy throughout
        await poll(tracker)
        XCTAssertEqual(Set(published.last?.map(\.state) ?? []), [.idle, .busy])
        probe.burn(700, seconds: 15)
        await poll(tracker, after: 40)
        XCTAssertFalse(notifier.titles.contains(AgentLines.allDoneTitle), "not yet a minute")
        probe.burn(700, seconds: 15)
        await poll(tracker, after: 20)
        XCTAssertEqual(notifier.titles, [AgentLines.allDoneTitle])
        XCTAssertEqual(notifier.posts[0].body, "Every tracked agent has been idle or gone for 1 min: claude (api), codex.")
        await poll(tracker, after: 120)
        XCTAssertEqual(notifier.titles.count, 1, "once")
        // Work, then rest again: announced again.
        probe.burn(600, seconds: 10)
        await poll(tracker)
        await poll(tracker)
        await poll(tracker, after: 60)
        XCTAssertEqual(notifier.titles.filter { $0 == AgentLines.allDoneTitle }.count, 2)
    }

    func testAllDoneNeedsAConversationalAgentAndRespectsItsToggle() async {
        config.allDoneMinutes = 1
        config.allDoneAlert = false
        probe.add(700, exe: "/usr/local/bin/ollama", args: ["ollama", "serve"])
        let tracker = makeTracker()
        defer { tracker.stop() }
        await poll(tracker)
        await poll(tracker)
        await poll(tracker, after: 600)
        XCTAssertTrue(notifier.posts.isEmpty, "a model server alone never finishes")
        probe.add(600, exe: "/x/codex")
        await poll(tracker)
        await poll(tracker)
        await poll(tracker, after: 600)
        XCTAssertTrue(notifier.posts.isEmpty, "toggle off")
    }

    func testHookEventsReachTheMatchingAgentAndUnmatchedOnesMakeAHookOnlyAgent() async {
        probe.add(600, exe: "/x/claude", cwd: "/Users/x/api")
        let tracker = makeTracker()
        defer { tracker.stop() }
        await poll(tracker)
        await poll(tracker)
        tracker.ingest(hook: AgentHookEvent(kind: "claude", action: .waiting("Claude needs your permission to use Bash"), pid: 600, sessionId: "s1"))
        XCTAssertEqual(notifier.titles, ["Agent waiting: claude"])
        XCTAssertEqual(notifier.posts[0].body, "Claude needs your permission to use Bash (api)")
        XCTAssertEqual(published.last?.map(\.state), [.waitingForInput])
        tracker.ingest(hook: AgentHookEvent(kind: "claude", action: .finished, sessionId: "s1"))
        XCTAssertEqual(published.last?.map(\.state), [.idle])

        tracker.ingest(hook: AgentHookEvent(kind: "codex", action: .waiting(nil), sessionId: "t9", cwd: "/Users/x/other"))
        XCTAssertEqual(notifier.titles.last, "Agent waiting: codex")
        XCTAssertEqual(notifier.posts.last?.body, "needs your input")
        XCTAssertEqual(published.last?.map(\.kind), ["claude", "hook"])
        XCTAssertEqual(report.agents?["hook-codex-t9"]?.lastState, .waitingForInput)
        tracker.ingest(hook: AgentHookEvent(kind: "codex", action: .ended("logout"), sessionId: "t9"))
        XCTAssertEqual(notifier.posts.last?.title, "Agent exited: codex")
        XCTAssertEqual(notifier.posts.last?.body, "Session ended: logout.")
    }

    func testTrackingOffFindsNothingAndIgnoresHooks() async {
        config.agentTracking = false
        probe.add(600, exe: "/x/claude")
        let tracker = makeTracker()
        defer { tracker.stop() }
        await poll(tracker)
        await poll(tracker)
        tracker.ingest(hook: AgentHookEvent(kind: "claude", action: .waiting(nil)))
        XCTAssertTrue(tracker.agents.isEmpty)
        XCTAssertTrue(notifier.posts.isEmpty)
        // Turned on mid-session: found at the next polls.
        config.agentTracking = true
        await poll(tracker)
        await poll(tracker)
        XCTAssertEqual(tracker.statuses().map(\.name), ["claude"])
        // And off again: the list empties.
        config.agentTracking = false
        await poll(tracker)
        XCTAssertTrue(tracker.agents.isEmpty)
        XCTAssertEqual(published.last, [])
    }

    func testStopClearsTheListAndHooksAfterStopAreDropped() async {
        probe.add(600, exe: "/x/claude")
        let tracker = makeTracker()
        await poll(tracker)
        await poll(tracker)
        XCTAssertEqual(tracker.statuses().count, 1)
        tracker.stop()
        XCTAssertEqual(published.last, [])
        tracker.ingest(hook: AgentHookEvent(kind: "claude", action: .waiting(nil)))
        await tracker.poll()
        XCTAssertTrue(tracker.agents.isEmpty)
        XCTAssertTrue(notifier.posts.isEmpty, "no exit alert for a session that ended")
    }

    func testUnpushedCommitsAreCountedPerRepoAndWrittenToTheReport() async {
        probe.add(600, exe: "/x/claude", cwd: "/Users/x/api/src")
        probe.add(601, exe: "/x/codex", cwd: "/Users/x/api")
        probe.add(602, exe: "/x/aider", cwd: "/tmp/norepo")
        shell.on(["log", "@{u}.."], FakeShellRunner.ok("a1 one\nb2 two\nc3 three\n"))
        let tracker = makeTracker()
        defer { tracker.stop() }
        await poll(tracker)
        await poll(tracker)
        XCTAssertEqual(tracker.repos, ["/Users/x/api"])
        await tracker.refreshUnpushed()
        XCTAssertEqual(report.unpushed, ["/Users/x/api": 3])
        let call = try? XCTUnwrap(shell.calls.last)
        XCTAssertEqual(call?.exe, "/usr/bin/env")
        XCTAssertEqual(call?.args, ["GIT_TERMINAL_PROMPT=0", "/usr/bin/git", "-C", "/Users/x/api", "log", "@{u}..", "--oneline"])
    }

    func testARepoWithoutAnUpstreamIsSkipped() async {
        probe.add(600, exe: "/x/claude", cwd: "/Users/x/api")
        shell.fallback = FakeShellRunner.fail(128, "fatal: no upstream configured for branch 'main'")
        let tracker = makeTracker()
        defer { tracker.stop() }
        await poll(tracker)
        await poll(tracker)
        await tracker.refreshUnpushed()
        XCTAssertEqual(report.unpushed ?? [:], [:])
        XCTAssertEqual(tracker.unpushed, ["/Users/x/api": 0])
        XCTAssertEqual(report.agentParts().filter { $0.hasPrefix("Unpushed") }, [])
    }
}

final class AgentLinesTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ kind: AgentKind = .claude, name: String = "claude", repo: String? = "/Users/x/repo-name", pane: String? = nil) -> AgentRecord {
        var r = AgentRecord(id: "\(kind.rawValue)-1-1.0", kind: kind, name: name, rootPid: 1, identity: ProcessIdentity(startedAt: 1), firstSeen: t0, lastSeen: t0, machine: AgentStateMachine(firstSeen: t0))
        r.repo = repo
        r.tmuxTarget = pane
        r.sightings = 2
        return r
    }

    func testMenuLineIsMarkNameStateAgeAndRepo() {
        var r = record()
        r.machine.ingest(AgentSample(at: t0))
        r.machine.ingest(AgentSample(at: t0.addingTimeInterval(20), cpuPercent: 50))
        let status = AgentStatus(r, now: t0.addingTimeInterval(200))
        XCTAssertEqual(AgentLines.menuLine(status, now: t0.addingTimeInterval(200)), "● claude  busy  3m  repo-name")
        let pane = AgentStatus(record(.tmuxPane, name: "nightly", repo: nil, pane: "main:0.1"), now: t0)
        XCTAssertEqual(AgentLines.menuLine(pane, now: t0.addingTimeInterval(5)), "● nightly  alive  5s  main:0.1")
        XCTAssertEqual(AgentLines.menuLine(AgentStatus(record(repo: nil), now: t0), now: t0), "● claude  alive  0s")
    }

    func testAgesAndMarks() {
        XCTAssertEqual(AgentLines.age(59), "59s")
        XCTAssertEqual(AgentLines.age(60), "1m")
        XCTAssertEqual(AgentLines.age(3600), "1h")
        XCTAssertEqual(AgentLines.age(7500), "2h 5m")
        XCTAssertEqual(AgentLines.age(-5), "0s")
        XCTAssertEqual(Set(AgentState.allCases.map(AgentLines.mark)).count, 5, "alive and busy share a mark")
    }

    func testMenuLinesAreCapped() {
        let many = (0..<11).map { i -> AgentStatus in
            var s = AgentStatus(record(), now: t0)
            s.id = "a\(i)"
            return s
        }
        let lines = AgentLines.menuLines(many, now: t0)
        XCTAssertEqual(lines.count, 9)
        XCTAssertEqual(lines.last, "… and 3 more agents")
        XCTAssertEqual(AgentLines.menuLines([], now: t0), [])
    }

    func testStatusMenuShowsAgentLinesAfterTheMachineLines() {
        let items = StatusMenu.items(sessionActive: true, sleepHeld: true, machine: "Lid open", actions: "2 frozen", agents: ["● claude  busy  3m  api", " "], throttledBrowsers: [], error: nil)
        let titles = items.map(\.title)
        XCTAssertEqual(titles.firstIndex(of: "● claude  busy  3m  api"), (titles.firstIndex(of: "2 frozen") ?? -9) + 1)
        XCTAssertEqual(items.first { $0.title.hasPrefix("●") }?.kind, .info)
        XCTAssertFalse(titles.contains(" "), "blank lines are dropped")
        XCTAssertEqual(StatusMenu.items(sessionActive: false, sleepHeld: false, machine: nil, actions: nil, throttledBrowsers: [], error: nil).map(\.kind), [.settings, .quit], "no agents, no lines")
    }

    func testSnapshotCarriesAgentsAndAnOlderFileDecodesWithout() throws {
        var s = StatusSnapshot(updatedAt: t0, active: true, startedAt: nil, endsAt: nil, remainingSeconds: nil, lidClosed: false, lidOnDesk: false, batteryPercent: nil, isCharging: false, chargerDraining: false, thermalState: "nominal", lowPowerSetByUs: false, wifiSSID: nil, lastOutageSeconds: nil, frozenCount: 0, dockerPaused: false)
        XCTAssertEqual(s.agents, [])
        var r = record(pane: "main:0.0")
        r.machine.ingest(hook: .waiting("Allow?"), at: t0, hasProcess: true)
        s.agents = [AgentStatus(r, now: t0.addingTimeInterval(30))]
        let data = try StatusSnapshot.encode(s)
        let text = String(decoding: data, as: UTF8.self)
        for key in ["\"agents\"", "\"id\"", "\"kind\"", "\"name\"", "\"state\"", "\"repo\"", "\"tmuxTarget\"", "\"waitingPrompt\"", "waitingForInput"] {
            XCTAssertTrue(text.contains(key), key)
        }
        let decoded = try Store.makeDecoder().decode(StatusSnapshot.self, from: data)
        XCTAssertEqual(decoded.agents.first?.waitingPrompt, "Allow?")
        XCTAssertEqual(decoded.agents.first?.repo, "repo-name")
        XCTAssertNil(decoded.agents.first?.lastOutputAgeSeconds)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["agents"] = nil
        let older = try Store.makeDecoder().decode(StatusSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.agents, [])
        XCTAssertTrue(older.active)
    }
}

final class AgentSummaryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func report() -> SessionReport {
        var r = SessionReport(startedAt: t0, plannedEnd: t0.addingTimeInterval(3600), batteryStart: 100)
        r.endedAt = t0.addingTimeInterval(3600)
        r.endReason = "timer"
        r.batteryEnd = 80
        r.restored = true
        return r
    }

    func testSummaryWithoutAgentsIsUnchanged() {
        XCTAssertEqual(report().summary(now: t0, endReasonText: SessionManager.reasonText), "Ran 1h (time was up). Battery 100% → 80%. Everything restored.")
        XCTAssertEqual(report().agentParts(), [])
    }

    func testAgentsUnpushedAndWipAreAppendedAtTheEnd() {
        var r = report()
        r.agents = [
            "a": AgentReportEntry(name: "claude", repo: "api", lastState: .exited),
            "b": AgentReportEntry(name: "codex", repo: "web", lastState: .idle, stalled: true),
            "c": AgentReportEntry(name: "aider", repo: nil, lastState: .waitingForInput, waited: true),
        ]
        r.unpushed = ["/Users/x/web": 1, "/Users/x/api": 3, "/Users/x/clean": 0]
        r.wipPushed = ["/Users/x/api", "/Users/x/web"]
        r.wipFailed = ["/Users/x/docs"]
        XCTAssertEqual(r.agentParts(), [
            "Agents: 3 ran, 2 finished, 1 stalled, 1 waiting for input at the end.",
            "Unpushed commits: api (3), web (1).",
            "wip pushed: 2 repos, failed: 1.",
        ])
        XCTAssertTrue(r.summary(now: t0, endReasonText: SessionManager.reasonText).hasSuffix("Everything restored. Agents: 3 ran, 2 finished, 1 stalled, 1 waiting for input at the end. Unpushed commits: api (3), web (1). wip pushed: 2 repos, failed: 1."))
    }

    func testOneRepoPushedAndNoFailures() {
        var r = report()
        r.wipPushed = ["/Users/x/api"]
        XCTAssertEqual(r.agentParts(), ["wip pushed: 1 repo."])
        r.wipPushed = nil
        r.wipFailed = ["/a", "/b"]
        XCTAssertEqual(r.agentParts(), ["wip pushed: 0 repos, failed: 2."])
    }

    func testAReportFromBeforePhaseTwoDecodes() throws {
        let old = #"{"startedAt":"2027-01-15T08:00:00Z","plannedEnd":"2027-01-15T09:00:00Z","lidCloses":1,"lowPowerEvents":0,"thermalEvents":0,"chargerWeakEvents":0,"outages":0,"outageSeconds":0,"summaryPosted":false}"#
        let r = try Store.makeDecoder().decode(SessionReport.self, from: Data(old.utf8))
        XCTAssertNil(r.agents)
        XCTAssertEqual(r.lidCloses, 1)
        var new = r
        new.agents = ["a": AgentReportEntry(name: "claude", repo: "api", lastState: .busy)]
        let round = try Store.makeDecoder().decode(SessionReport.self, from: Store.makeEncoder().encode(new))
        XCTAssertEqual(round, new)
    }
}

final class AgentConfigTests: XCTestCase {
    func testPhaseTwoDefaults() {
        let c = Config()
        XCTAssertTrue(c.agentTracking)
        XCTAssertTrue(c.agentWaitingAlerts && c.agentStalledAlerts && c.agentExitedAlerts && c.allDoneAlert)
        XCTAssertEqual(c.agentStallMinutes, 10)
        XCTAssertEqual(c.allDoneMinutes, 5)
        XCTAssertTrue(c.showAgentsInMenu)
        XCTAssertTrue(c.dialogAlerts)
        XCTAssertFalse(c.preEndHooks)
        XCTAssertFalse(c.wipCommitOnEnd)
        XCTAssertFalse(c.priorityPause)
        XCTAssertEqual(c.agentPriorities, [:])
    }

    func testAConfigFromBeforePhaseTwoLoadsWithTheDefaultsAndRoundTrips() throws {
        let old = try Store.makeDecoder().decode(Config.self, from: Data(#"{"lowPowerFloor":35,"lidCloseDefaultsApplied":true}"#.utf8))
        var expected = Config()
        expected.lowPowerFloor = 35
        XCTAssertEqual(old, expected)
        var c = Config()
        c.agentTracking = false
        c.agentStallMinutes = 25
        c.allDoneMinutes = 2
        c.preEndHooks = true
        c.wipCommitOnEnd = true
        c.priorityPause = true
        c.agentPriorities = ["codex": -1, "claude": 1]
        c.dialogAlerts = false
        c.showAgentsInMenu = false
        c.agentExitedAlerts = false
        XCTAssertEqual(try Store.makeDecoder().decode(Config.self, from: Store.makeEncoder().encode(c)), c)
    }

    func testMinutesBelowOneAreRaisedToOne() throws {
        let c = try Store.makeDecoder().decode(Config.self, from: Data(#"{"agentStallMinutes":0,"allDoneMinutes":-3}"#.utf8))
        XCTAssertEqual(c.agentStallMinutes, 1)
        XCTAssertEqual(c.allDoneMinutes, 1)
    }
}
