import XCTest
@testable import Awake

/// Records what the phone would have typed; types nothing.
final class FakeTmuxTyper: TmuxTyping, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _refusal: String?
    /// "enter %1" or "type %1 <text>", in order.
    var sent: [String] { lock.withLock { _sent } }
    /// When set, every send is refused with this.
    var refusal: String? {
        get { lock.withLock { _refusal } }
        set { lock.withLock { _refusal = newValue } }
    }

    func enter(paneId: String) async -> String? {
        lock.withLock {
            if let _refusal { return _refusal }
            _sent.append("enter \(paneId)")
            return nil
        }
    }

    func type(paneId: String, text: String) async -> String? {
        lock.withLock {
            if let _refusal { return _refusal }
            _sent.append("type \(paneId) \(text)")
            return nil
        }
    }
}

/// The phone's agent actions over a fake tmux and the fake process control:
/// each action's success and each refusal.
@MainActor
final class AgentActionsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ kind: AgentKind, pid: Int32, children: [Int32] = [], pane: String? = nil, sudo: Bool = false) -> AgentRecord {
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
        r.tmuxPaneId = pane
        r.tmuxTarget = pane.map { _ in "work:0.0" }
        return r
    }

    private func hookOnly() -> AgentRecord {
        AgentRecord(id: "hook-s1", kind: .hookOnly, name: "claude", rootPid: nil, identity: nil, firstSeen: t0, lastSeen: t0, machine: AgentStateMachine(firstSeen: t0))
    }

    /// What `ps` would say about process groups; empty means every
    /// process is unknown to it, which reads as "the agent is in front".
    private final class FakePaneFront: PaneFrontReading, @unchecked Sendable {
        private let lock = NSLock()
        private var _groups: [Int32: ProcessGroups]? = [:]
        var table: [Int32: ProcessGroups]? {
            get { lock.withLock { _groups } }
            set { lock.withLock { _groups = newValue } }
        }
        func groups(of pids: [Int32]) async -> [Int32: ProcessGroups]? {
            guard let table else { return nil }
            return table.filter { pids.contains($0.key) }
        }
    }

    @MainActor
    private final class Fixture {
        let front = FakePaneFront()
        let h = Harness()
        let tmux = FakeTmux()
        let typer = FakeTmuxTyper()
        var records: [AgentRecord]? = []
        var manager: SessionManager!
        var pauser: AgentPauser!
        var actions: AgentActions!
    }

    private func fixture(_ records: [AgentRecord], panes: [TmuxPane] = []) async -> Fixture {
        let f = Fixture()
        f.records = records
        f.tmux.paneList = panes
        let m = f.h.makeManager()
        await m.start(duration: 3600)
        let clock = f.h.clock
        let freezer = FakeFreezer(apps: [], processes: [], control: f.h.procs)
        f.manager = m
        f.pauser = AgentPauser(manager: m, freezer: freezer, notifier: f.h.notifier, clock: { clock.now }, stepInterval: 60) { [f] in f.records ?? [] }
        f.actions = AgentActions(manager: m, pauser: f.pauser, tmux: f.tmux, typer: f.typer, control: f.h.procs, front: f.front) { [f] in f.records }
        return f
    }

    private func marked(_ id: String, pid: Int32 = 5) -> TmuxPane { TmuxPane(id: id, target: "work:0.0", pid: pid, marked: true) }

    // MARK: available

    func testAvailableOnlyWhileASessionRunsAndTheTrackerExists() async {
        let f = await fixture([agent(.claude, pid: 10)])
        defer { f.h.home.destroy() }
        XCTAssertTrue(f.actions.available)
        f.records = nil
        XCTAssertFalse(f.actions.available, "no tracker")
        f.records = [agent(.claude, pid: 10)]
        await f.manager.end(reason: .user)
        XCTAssertFalse(f.actions.available, "no session")
        let refused = await [f.actions.nudge(id: "claude-10"), f.actions.answer(id: "claude-10", text: "y"), f.actions.pause(id: "claude-10"), f.actions.resume(id: "claude-10"), f.actions.stop(id: "claude-10")]
        XCTAssertEqual(refused, Array(repeating: .failed("no session is running"), count: 5))
        XCTAssertTrue(f.typer.sent.isEmpty)
        XCTAssertTrue(f.h.procs.suspended.isEmpty)
        XCTAssertTrue(f.h.procs.terminated.isEmpty)
    }

    func testAnUnknownIdIsRefusedByEveryAction() async {
        let f = await fixture([agent(.claude, pid: 10, pane: "%1")], panes: [marked("%1")])
        defer { f.h.home.destroy() }
        let refused = await [f.actions.nudge(id: "nope"), f.actions.answer(id: "nope", text: "y"), f.actions.pause(id: "nope"), f.actions.resume(id: "nope"), f.actions.stop(id: "nope")]
        XCTAssertEqual(refused, Array(repeating: .failed("no such agent"), count: 5))
        XCTAssertTrue(f.typer.sent.isEmpty)
        XCTAssertTrue(f.h.procs.suspended.isEmpty)
        XCTAssertTrue(f.h.procs.terminated.isEmpty)
    }

    // MARK: nudge

    func testNudgeSendsEnterToTheMarkedPane() async {
        let f = await fixture([agent(.claude, pid: 10, pane: "%1")], panes: [marked("%1")])
        defer { f.h.home.destroy() }
        let result = await f.actions.nudge(id: "claude-10")
        XCTAssertEqual(result, .done("Sent Enter to claude."))
        XCTAssertEqual(f.typer.sent, ["enter %1"])
    }

    func testNudgeIsRefusedWithoutAMarkedLivePane() async {
        let f = await fixture([agent(.claude, pid: 10), agent(.codex, pid: 20, pane: "%2"), agent(.aider, pid: 30, pane: "%3"), agent(.gemini, pid: 40, pane: "%4"), hookOnly()], panes: [
            TmuxPane(id: "%2", target: "work:0.1", pid: 6, marked: false),
            TmuxPane(id: "%3", target: "work:0.2", pid: 7, marked: true, dead: true),
        ])
        defer { f.h.home.destroy() }
        for id in ["claude-10", "codex-20", "aider-30", "gemini-40", "hook-s1"] {
            let result = await f.actions.nudge(id: id)
            XCTAssertEqual(result, .failed("agent is not in a marked tmux pane"), id)
        }
        XCTAssertTrue(f.typer.sent.isEmpty, "no pane, an unmarked pane, a dead pane, a pane tmux no longer lists, hook-only")
    }

    func testNudgeReportsWhatTmuxRefused() async {
        let f = await fixture([agent(.claude, pid: 10, pane: "%1")], panes: [marked("%1")])
        defer { f.h.home.destroy() }
        f.typer.refusal = "pane %1 is in copy/choose mode; keys would not reach the program"
        let result = await f.actions.nudge(id: "claude-10")
        XCTAssertEqual(result, .failed("pane %1 is in copy/choose mode; keys would not reach the program"))
    }

    // MARK: answer

    func testAnswerTypesTheTextLiterallyThenEnter() async {
        let f = await fixture([agent(.claude, pid: 10, pane: "%1")], panes: [marked("%1")])
        defer { f.h.home.destroy() }
        let result = await f.actions.answer(id: "claude-10", text: "-y; rm -rf $HOME")
        XCTAssertEqual(result, .done("Sent the answer to claude."))
        XCTAssertEqual(f.typer.sent, ["type %1 -y; rm -rf $HOME"], "one literal string; the typer adds Enter")
    }

    func testAnswerRefusesMoreThanOneLineOrFiveHundredCharacters() async {
        let f = await fixture([agent(.claude, pid: 10, pane: "%1")], panes: [marked("%1")])
        defer { f.h.home.destroy() }
        let empty = await f.actions.answer(id: "claude-10", text: "")
        XCTAssertEqual(empty, .failed("the answer is empty"))
        for text in ["yes\nrm -rf /", "yes\r", "a\u{2028}b", "a\u{1B}[A", "tab\there"] {
            let result = await f.actions.answer(id: "claude-10", text: text)
            XCTAssertEqual(result, .failed("the answer must be one line"), text.debugDescription)
        }
        let long = await f.actions.answer(id: "claude-10", text: String(repeating: "a", count: 501))
        XCTAssertEqual(long, .failed("the answer is longer than 500 characters"))
        XCTAssertTrue(f.typer.sent.isEmpty)
        let limit = await f.actions.answer(id: "claude-10", text: String(repeating: "a", count: 500))
        XCTAssertTrue(limit.ok)
        XCTAssertEqual(f.typer.sent.count, 1)
    }

    func testAnswerIsRefusedWithoutAMarkedPaneAndReportsWhatTmuxRefused() async {
        let f = await fixture([agent(.claude, pid: 10, pane: "%1"), agent(.codex, pid: 20, pane: "%2"), hookOnly()], panes: [marked("%1"), TmuxPane(id: "%2", target: "work:0.1", pid: 6)])
        defer { f.h.home.destroy() }
        for id in ["codex-20", "hook-s1"] {
            let result = await f.actions.answer(id: id, text: "y")
            XCTAssertEqual(result, .failed("agent is not in a marked tmux pane"), id)
        }
        f.typer.refusal = "tmux send-keys to %1 failed"
        let failed = await f.actions.answer(id: "claude-10", text: "y")
        XCTAssertEqual(failed, .failed("tmux send-keys to %1 failed"))
        XCTAssertTrue(f.typer.sent.isEmpty)
    }

    // MARK: pause / resume

    func testPauseJournalsBeforeTheSignalAndResumeClearsTheJournal() async throws {
        let f = await fixture([agent(.claude, pid: 10), agent(.codex, pid: 20, children: [21])])
        defer { f.h.home.destroy() }
        let store = f.h.store
        nonisolated(unsafe) var journaledAtSignal: [[FrozenProcess]] = []
        f.h.procs.onSuspend = { _ in journaledAtSignal.append((try? store.loadState())??.frozenProcesses ?? []) }

        let paused = await f.actions.pause(id: "codex-20")
        XCTAssertEqual(paused, .done("Paused codex. It resumes when you resume it or the session ends."))
        XCTAssertEqual(f.h.procs.suspended, [[20, 21]])
        XCTAssertEqual(journaledAtSignal, [[FrozenProcess(pid: 20, identity: nil), FrozenProcess(pid: 21, identity: nil)]], "journaled without identity before the signal")
        XCTAssertEqual(try store.loadState()?.frozenProcesses, [FrozenProcess(pid: 20, startedAt: 20), FrozenProcess(pid: 21, startedAt: 21)], "promoted once confirmed")
        XCTAssertEqual(f.pauser.held.map(\.id), ["codex-20"])

        let again = await f.actions.pause(id: "codex-20")
        XCTAssertEqual(again, .done("codex is already paused."))
        XCTAssertEqual(f.h.procs.suspended.count, 1, "not stopped twice")

        // No pressure: the priority pause leaves what the phone paused.
        await f.pauser.update(pressure: [])
        XCTAssertEqual(f.h.procs.stoppedNow, [20, 21])

        let resumed = await f.actions.resume(id: "codex-20")
        XCTAssertEqual(resumed, .done("Resumed codex."))
        XCTAssertEqual(f.h.procs.resumed.last, [20, 21])
        XCTAssertEqual(f.h.procs.stoppedNow, [])
        XCTAssertEqual(try store.loadState()?.frozenProcesses, [])
        XCTAssertEqual(f.pauser.held, [])
    }

    func testPauseRefusals() async throws {
        let f = await fixture([agent(.claude, pid: 10, sudo: true), agent(.codex, pid: 20), hookOnly()])
        defer { f.h.home.destroy() }
        let sudo = await f.actions.pause(id: "claude-10")
        XCTAssertEqual(sudo, .failed("claude cannot be paused: sudo is running under it"))
        let hook = await f.actions.pause(id: "hook-s1")
        XCTAssertEqual(hook, .failed("claude cannot be paused: no process"))
        // The kernel side finds another process under the pid.
        f.h.procs.refuseSuspend = [20]
        let reused = await f.actions.pause(id: "codex-20")
        XCTAssertEqual(reused, .failed("codex could not be paused; it was left running"))
        XCTAssertEqual(try f.h.store.loadState()?.frozenProcesses, [], "nothing stays journaled")
        XCTAssertEqual(f.pauser.held, [])
        XCTAssertEqual(f.h.procs.stoppedNow, [])
    }

    func testResumeRefusals() async throws {
        let f = await fixture([agent(.codex, pid: 20), hookOnly()])
        defer { f.h.home.destroy() }
        let notPaused = await f.actions.resume(id: "codex-20")
        XCTAssertEqual(notPaused, .failed("codex is not paused by Awake"))
        let hook = await f.actions.resume(id: "hook-s1")
        XCTAssertEqual(hook, .failed("claude is not paused by Awake"))
        XCTAssertTrue(f.h.procs.resumed.isEmpty, "a process somebody else stopped is not Awake's to continue")

        _ = await f.actions.pause(id: "codex-20")
        f.h.procs.failResume = [20]
        let failed = await f.actions.resume(id: "codex-20")
        XCTAssertEqual(failed, .failed("1 process(es) could not be resumed and stay journaled; the next lid open or session end retries them"))
        XCTAssertEqual(try f.h.store.loadState()?.frozenProcesses, [FrozenProcess(pid: 20, startedAt: 20)], "still journaled, so the end retries it")
        XCTAssertEqual(f.pauser.held.map(\.id), ["codex-20"])
    }

    func testTheSessionEndResumesAnAgentThePhonePaused() async throws {
        let f = await fixture([agent(.codex, pid: 20, children: [21])])
        defer { f.h.home.destroy() }
        _ = await f.actions.pause(id: "codex-20")
        XCTAssertEqual(f.h.procs.stoppedNow, [20, 21])
        await f.manager.end(reason: .user)
        XCTAssertEqual(f.h.procs.stoppedNow, [], "the end undoes it like any freeze")
        XCTAssertEqual(try f.h.store.loadState()?.frozenProcesses ?? [], [])
    }

    func testALaunchAfterACrashResumesAnAgentThePhonePaused() async throws {
        let f = await fixture([agent(.codex, pid: 20)])
        defer { f.h.home.destroy() }
        _ = await f.actions.pause(id: "codex-20")
        XCTAssertEqual(try f.h.store.loadState()?.frozenProcesses, [FrozenProcess(pid: 20, startedAt: 20)])
        // The app dies here; the journal is all that is left. The session
        // is over by the time the next launch reconciles.
        f.h.clock.advance(7200)
        let next = f.h.makeManager()
        await next.reconcile()
        XCTAssertFalse(next.isActive)
        XCTAssertEqual(f.h.procs.stoppedNow, [], "recovery resumes it from the journal")
        XCTAssertEqual(try f.h.store.loadState()?.frozenProcesses ?? [], [])
    }

    func testALidOpenResumesItAndThePhoneSeesItRunning() async throws {
        let f = await fixture([agent(.codex, pid: 20)])
        defer { f.h.home.destroy() }
        _ = await f.actions.pause(id: "codex-20")
        await f.manager.undoLidActions()
        XCTAssertEqual(f.h.procs.stoppedNow, [])
        let resumed = await f.actions.resume(id: "codex-20")
        XCTAssertEqual(resumed, .failed("codex is not paused by Awake"))
        let paused = await f.actions.pause(id: "codex-20")
        XCTAssertTrue(paused.ok)
        XCTAssertEqual(f.h.procs.suspended, [[20], [20]])
    }

    // MARK: stop

    func testStopSendsSIGTERMToTheRootPidOnly() async {
        let f = await fixture([agent(.codex, pid: 20, children: [21, 22])])
        defer { f.h.home.destroy() }
        let result = await f.actions.stop(id: "codex-20")
        XCTAssertEqual(result, .done("Asked codex to stop (SIGTERM to pid 20)."))
        XCTAssertEqual(f.h.procs.terminated, [20])
    }

    // MARK: who is in front of the pane

    /// A pane whose shell (pid 5) started the agent (pid 10) as a job.
    private func shellPane(_ id: String = "%1") -> TmuxPane {
        TmuxPane(id: id, target: "work:0.0", pid: 5, marked: true, currentCommand: "zsh")
    }

    func testPsOutputIsReadAsGroups() {
        let table = PaneFront.parse("  5     5    10\n   10    10    10\njunk line\n 11 10\n")
        XCTAssertEqual(table, [5: ProcessGroups(group: 5, foreground: 10), 10: ProcessGroups(group: 10, foreground: 10)])
    }

    /// After SIGSTOP and SIGCONT an agent started from an interactive shell
    /// is a background job, and the shell reads the pane's keys. Seen on a
    /// real Mac: the phone's answer ran as a shell command.
    func testNothingIsTypedWhileThePanesShellIsInFrontOfTheAgent() async {
        let f = await fixture([agent(.claude, pid: 10, children: [11], pane: "%1")], panes: [shellPane()])
        defer { f.h.home.destroy() }
        f.front.table = [5: ProcessGroups(group: 5, foreground: 5), 10: ProcessGroups(group: 10, foreground: 5), 11: ProcessGroups(group: 10, foreground: 5)]
        let refusal = AgentActions.notInFront("claude")
        let answered = await f.actions.answer(id: "claude-10", text: "rm -rf x")
        XCTAssertEqual(answered, .failed(refusal))
        let nudged = await f.actions.nudge(id: "claude-10")
        XCTAssertEqual(nudged, .failed(refusal))
        XCTAssertTrue(f.typer.sent.isEmpty)

        // The agent in front again (fg): keys go through.
        f.front.table = [5: ProcessGroups(group: 5, foreground: 10), 10: ProcessGroups(group: 10, foreground: 10), 11: ProcessGroups(group: 10, foreground: 10)]
        let again = await f.actions.answer(id: "claude-10", text: "y")
        XCTAssertTrue(again.ok)
        XCTAssertEqual(f.typer.sent, ["type %1 y"])
    }

    func testNothingIsTypedWhenTheFrontOfThePaneCannotBeRead() async {
        let f = await fixture([agent(.claude, pid: 10, pane: "%1")], panes: [shellPane()])
        defer { f.h.home.destroy() }
        f.front.table = nil
        let answered = await f.actions.answer(id: "claude-10", text: "y")
        XCTAssertEqual(answered, .failed(AgentActions.frontUnreadable))
        let nudged = await f.actions.nudge(id: "claude-10")
        XCTAssertEqual(nudged, .failed(AgentActions.frontUnreadable))
        XCTAssertTrue(f.typer.sent.isEmpty)
    }

    func testAShellInFrontIsOnlyARefusalWhenTheAgentIsAJobBehindIt() {
        let shell = shellPane()
        // A marked pane with nothing but its shell: the shell is the agent.
        XCTAssertFalse(PaneFront.shellInFront(pane: shell, agentPids: [5], groups: [5: ProcessGroups(group: 5, foreground: 5)]))
        // A script run as the pane's command (`tmux new-window 'bash build.sh'`):
        // no job control, its children share its group.
        let script = TmuxPane(id: "%2", target: "work:1.0", pid: 5, marked: true, currentCommand: "bash")
        XCTAssertFalse(PaneFront.shellInFront(pane: script, agentPids: [5, 6], groups: [5: ProcessGroups(group: 5, foreground: 5), 6: ProcessGroups(group: 5, foreground: 5)]))
        // A program that is the pane's first process, with a detached child.
        let program = TmuxPane(id: "%3", target: "work:2.0", pid: 5, marked: true, currentCommand: "node")
        XCTAssertFalse(PaneFront.shellInFront(pane: program, agentPids: [5, 6], groups: [5: ProcessGroups(group: 5, foreground: 5), 6: ProcessGroups(group: 6, foreground: 5)]))
        // The agent in front of its shell.
        XCTAssertFalse(PaneFront.shellInFront(pane: shell, agentPids: [5, 10], groups: [5: ProcessGroups(group: 5, foreground: 10), 10: ProcessGroups(group: 10, foreground: 10)]))
        // The agent a job behind a login shell ("-zsh").
        let login = TmuxPane(id: "%4", target: "work:3.0", pid: 5, marked: true, currentCommand: "-zsh")
        XCTAssertTrue(PaneFront.shellInFront(pane: login, agentPids: [5, 10], groups: [5: ProcessGroups(group: 5, foreground: 5), 10: ProcessGroups(group: 10, foreground: 5)]))
        // The job has exited: only the shell is left.
        XCTAssertFalse(PaneFront.shellInFront(pane: shell, agentPids: [5, 10], groups: [5: ProcessGroups(group: 5, foreground: 5)]))
    }

    /// A marked pane is tracked from its first process, an interactive
    /// shell that ignores SIGTERM. Seen on a real Mac: Stop reported "ok"
    /// and the agent kept running. The signal is for the job in the pane.
    func testStopOfAMarkedPaneIsForTheJobInFrontNotThePanesShell() async {
        let pane = shellPane()
        let f = await fixture([agent(.tmuxPane, pid: 5, children: [10, 11], pane: "%1")], panes: [pane])
        defer { f.h.home.destroy() }
        f.front.table = [5: ProcessGroups(group: 5, foreground: 10), 10: ProcessGroups(group: 10, foreground: 10), 11: ProcessGroups(group: 10, foreground: 10)]
        let result = await f.actions.stop(id: "tmux-5")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(f.h.procs.terminated, [10])
    }

    func testStopOfAMarkedPaneFindsTheShellsOnlyJobBehindIt() async {
        let f = await fixture([agent(.tmuxPane, pid: 5, children: [10, 11], pane: "%1")], panes: [shellPane()])
        defer { f.h.home.destroy() }
        f.front.table = [5: ProcessGroups(group: 5, foreground: 5), 10: ProcessGroups(group: 10, foreground: 5), 11: ProcessGroups(group: 10, foreground: 5)]
        _ = await f.actions.stop(id: "tmux-5")
        XCTAssertEqual(f.h.procs.terminated, [10])
    }

    func testStopFallsBackToThePanesFirstProcess() {
        let shell = shellPane()
        let idle = [Int32(5): ProcessGroups(group: 5, foreground: 5)]
        XCTAssertNil(PaneFront.jobToStop(pane: shell, agentPids: [5], groups: idle), "nothing but the shell")
        XCTAssertNil(PaneFront.jobToStop(pane: shell, agentPids: [5, 10], groups: [:]), "ps knew none of them")
        let two = [Int32(5): ProcessGroups(group: 5, foreground: 5), 10: ProcessGroups(group: 10, foreground: 5), 12: ProcessGroups(group: 12, foreground: 5)]
        XCTAssertNil(PaneFront.jobToStop(pane: shell, agentPids: [5, 10, 12], groups: two), "two jobs: which one is not Awake's to guess")
        let untracked = [Int32(5): ProcessGroups(group: 5, foreground: 99)]
        XCTAssertNil(PaneFront.jobToStop(pane: shell, agentPids: [5], groups: untracked), "the job in front is not one Awake tracks")
        let program = TmuxPane(id: "%3", target: "work:2.0", pid: 5, marked: true, currentCommand: "node")
        XCTAssertNil(PaneFront.jobToStop(pane: program, agentPids: [5, 6], groups: [5: ProcessGroups(group: 5, foreground: 5), 6: ProcessGroups(group: 6, foreground: 5)]), "the first process is the agent")
    }

    /// An agent found by its own process (claude under a shell) is
    /// signalled as before, whatever the pane says.
    func testStopOfAnAgentThatIsNotThePanesFirstProcessIsUnchanged() async {
        let f = await fixture([agent(.claude, pid: 10, children: [11], pane: "%1")], panes: [shellPane()])
        defer { f.h.home.destroy() }
        f.front.table = [5: ProcessGroups(group: 5, foreground: 11), 10: ProcessGroups(group: 10, foreground: 11), 11: ProcessGroups(group: 11, foreground: 11)]
        _ = await f.actions.stop(id: "claude-10")
        XCTAssertEqual(f.h.procs.terminated, [10])
    }

    func testStopRefusals() async {
        var exited = agent(.aider, pid: 30)
        exited.machine.ingest(AgentSample(at: t0, present: false))
        let f = await fixture([agent(.codex, pid: 20), exited, hookOnly()])
        defer { f.h.home.destroy() }
        let hook = await f.actions.stop(id: "hook-s1")
        XCTAssertEqual(hook, .failed("claude is known only from hooks; there is no process to stop"))
        let gone = await f.actions.stop(id: "aider-30")
        XCTAssertEqual(gone, .failed("aider has exited"))
        f.h.procs.notTheSame = [20]
        let reused = await f.actions.stop(id: "codex-20")
        XCTAssertEqual(reused, .failed("codex is gone or pid 20 is another process now; nothing was sent"))
        XCTAssertTrue(f.h.procs.terminated.isEmpty)
    }

    func testStopOfAPausedAgentResumesItFirstSoTheSignalIsActedOn() async throws {
        let f = await fixture([agent(.codex, pid: 20, children: [21])])
        defer { f.h.home.destroy() }
        _ = await f.actions.pause(id: "codex-20")
        let result = await f.actions.stop(id: "codex-20")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(f.h.procs.stoppedNow, [])
        XCTAssertEqual(try f.h.store.loadState()?.frozenProcesses, [])
        XCTAssertEqual(f.h.procs.terminated, [20])
    }

    // MARK: the kernel side of stop

    func testTerminateSignalsOnlyTheSameProcess() {
        let boot = "boot-1"
        let mine = ProcessIdentity(startedAt: 100, startedAtMicros: 0, bootSession: boot)
        nonisolated(unsafe) var sent: [(Int32, Int32)] = []
        let table: [Int32: ProcessLookup] = [
            10: .present(ProcessSignalState(ppid: 1, stopped: false, identity: mine)),
            11: .present(ProcessSignalState(ppid: 1, stopped: false, identity: ProcessIdentity(startedAt: 999, startedAtMicros: 0, bootSession: boot))),
            12: .unreadable(EPERM),
            14: .present(ProcessSignalState(ppid: 1, stopped: true, identity: mine)),
        ]
        let control = SignalProcessControl(stateLookup: { table[$0] ?? .absent }, send: { pid, signal in
            sent.append((pid, signal))
            return 0
        })
        XCTAssertEqual(control.terminate(FrozenProcess(pid: 10, identity: mine)), .sent)
        XCTAssertEqual(control.terminate(FrozenProcess(pid: 14, identity: mine)), .sent, "stopped or not")
        XCTAssertEqual(control.terminate(FrozenProcess(pid: 11, identity: mine)), .notTheSameProcess, "pid reused")
        XCTAssertEqual(control.terminate(FrozenProcess(pid: 13, identity: mine)), .notTheSameProcess, "exited")
        XCTAssertEqual(control.terminate(FrozenProcess(pid: 12, identity: mine)), .failed, "unknown is not a match")
        XCTAssertEqual(control.terminate(FrozenProcess(pid: 10, identity: nil)), .failed, "never without identity")
        XCTAssertEqual(control.terminate(FrozenProcess(pid: 10, identity: ProcessIdentity(startedAt: 100, startedAtMicros: 0, bootSession: ""))), .failed, "never without a boot session")
        XCTAssertEqual(sent.map(\.0), [10, 14])
        XCTAssertTrue(sent.allSatisfy { $0.1 == SIGTERM })
    }

    // MARK: wiring

    func testAppServicesHandsThePhoneTheActionsForTheSessionOnly() async {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 3600)
        let services = AppServices(paths: h.home.paths, notifier: h.notifier, audio: h.audio, processControl: h.procs, locationPermission: LocationPermission(authorizationStatus: .notDetermined), lidSimulation: nil, lidSimulationEnabled: false)
        let probe = FakeAgentProbe()
        probe.add(20, exe: "/opt/homebrew/bin/codex")
        let tmux = FakeTmux()
        let typer = FakeTmuxTyper()
        services.agentDependencies.probe = probe
        services.agentDependencies.tmux = tmux
        services.agentDependencies.tmuxTyping = typer
        services.agentDependencies.git = AgentGit(runner: FakeShellRunner(), git: nil)
        services.agentDependencies.dialogs = FakeDialogProbe()
        services.agentDependencies.hookSocket = false
        let phone = PhoneAppController(paths: h.home.paths, session: FakePhoneSession(), locker: RecordingScreenLock(), machine: FakePhoneMachine(), screen: FakeScreenCapture(), deviceStore: MemoryPhoneDeviceStore(), interfaces: { [] }, shell: FakePhoneShell())
        services.attachPhone(phone)
        XCTAssertFalse(phone.agentActions.available)
        XCTAssertTrue(phone.agentActions is UnavailableAgentActions)

        services.startAgents(for: m)
        XCTAssertTrue(phone.agentActions.available)
        XCTAssertTrue(phone.agentActions === services.agentActions)
        await services.agentTracker?.poll()
        guard let id = services.agentTracker?.agents.first?.id else { return XCTFail("the tracker found no agent") }
        let stopped = await phone.agentActions.stop(id: id)
        XCTAssertTrue(stopped.ok, stopped.message)
        XCTAssertEqual(h.procs.terminated, [20], "through the app's own process control")

        services.stopAgents()
        XCTAssertNil(services.agentActions)
        XCTAssertTrue(phone.agentActions is UnavailableAgentActions)
        let after = await phone.agentActions.stop(id: id)
        XCTAssertEqual(after, .failed("not available yet"))
        await m.end(reason: .user)
    }

    func testAPhoneAppCreatedDuringASessionGetsItsActions() async {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 3600)
        let services = AppServices(paths: h.home.paths, notifier: h.notifier, audio: h.audio, processControl: h.procs, locationPermission: LocationPermission(authorizationStatus: .notDetermined), lidSimulation: nil, lidSimulationEnabled: false)
        services.agentDependencies.probe = FakeAgentProbe()
        services.agentDependencies.tmux = NoTmuxReader()
        services.agentDependencies.git = AgentGit(runner: FakeShellRunner(), git: nil)
        services.agentDependencies.dialogs = FakeDialogProbe()
        services.agentDependencies.hookSocket = false
        services.startAgents(for: m)
        let phone = PhoneAppController(paths: h.home.paths, session: FakePhoneSession(), locker: RecordingScreenLock(), machine: FakePhoneMachine(), screen: FakeScreenCapture(), deviceStore: MemoryPhoneDeviceStore(), interfaces: { [] }, shell: FakePhoneShell())
        services.attachPhone(phone)
        XCTAssertTrue(phone.agentActions === services.agentActions)
        services.stopAgents()
        await m.end(reason: .user)
    }
}
