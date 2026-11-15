import XCTest
@testable import Awake

final class AgentCatalogTests: XCTestCase {
    func testCommandsAreMatchedByExecutableName() {
        XCTAssertEqual(AgentCatalog.kind(executable: "/opt/homebrew/bin/claude", arguments: ["claude"]), .claude)
        XCTAssertEqual(AgentCatalog.kind(executable: "/usr/local/bin/codex", arguments: ["codex", "--full-auto"]), .codex)
        XCTAssertEqual(AgentCatalog.kind(executable: "/Users/x/.local/bin/devin", arguments: []), .devin)
        XCTAssertEqual(AgentCatalog.kind(executable: "/usr/local/bin/ollama", arguments: ["ollama", "serve"]), .ollama)
        XCTAssertEqual(AgentCatalog.kind(executable: "/Users/x/.local/bin/cursor-agent", arguments: []), .cursor)
    }

    func testScriptsUnderALauncherAreMatchedByTheScript() {
        XCTAssertEqual(AgentCatalog.kind(executable: "/opt/homebrew/bin/node", arguments: ["node", "/opt/homebrew/bin/claude", "--resume"]), .claude)
        XCTAssertEqual(AgentCatalog.kind(executable: "/opt/homebrew/bin/node", arguments: ["node", "--no-warnings", "/x/lib/node_modules/@anthropic-ai/claude-code/cli.js"]), .claude)
        XCTAssertEqual(AgentCatalog.kind(executable: "/opt/homebrew/bin/node", arguments: ["node", "/x/lib/node_modules/@google/gemini-cli/dist/index.js"]), .gemini)
        XCTAssertEqual(AgentCatalog.kind(executable: "/x/python3.12", arguments: ["python3.12", "/x/venv/bin/aider", "--model", "sonnet"]), .aider)
        XCTAssertEqual(AgentCatalog.kind(executable: "/usr/bin/python3", arguments: ["python3", "-m", "aider"]), .aider)
        XCTAssertEqual(AgentCatalog.kind(executable: "/usr/bin/env", arguments: ["env", "FOO=1", "codex"]), .codex)
    }

    func testOtherProcessesAreNotAgents() {
        XCTAssertNil(AgentCatalog.kind(executable: "/Applications/Claude.app/Contents/MacOS/Claude Helper", arguments: []))
        XCTAssertNil(AgentCatalog.kind(executable: "/opt/homebrew/bin/node", arguments: ["node", "server.js"]))
        XCTAssertNil(AgentCatalog.kind(executable: "/bin/zsh", arguments: ["-zsh"]))
        XCTAssertNil(AgentCatalog.kind(executable: "/usr/bin/vim", arguments: ["vim", "claude"]), "an argument that names an agent is not the agent")
        XCTAssertNil(AgentCatalog.kind(executable: "/opt/homebrew/bin/node", arguments: ["node"]))
    }

    func testBundleIdsComeFromTheDefaultAgentList() {
        XCTAssertEqual(AgentCatalog.kind(bundleId: "com.todesktop.230313mzl4w4u92"), .cursor)
        XCTAssertEqual(AgentCatalog.kind(bundleId: "ai.elementlabs.lmstudio"), .lmStudio)
        XCTAssertEqual(AgentCatalog.kind(bundleId: "com.electron.ollama"), .ollama)
        XCTAssertNil(AgentCatalog.kind(bundleId: "com.apple.Terminal"))
        XCTAssertNil(AgentCatalog.kind(bundleId: nil))
        for id in AgentCatalog.bundleIds.keys {
            XCTAssertTrue(Config.defaultAgentList.contains(id), "\(id) should be an agent app the freezer already protects")
        }
    }

    func testOnlyCommandLineAgentsAreConversational() {
        XCTAssertEqual(Set(AgentKind.allCases.filter { !$0.isConversational }), [.cursor, .ollama, .lmStudio])
    }
}

final class AgentProbeParsingTests: XCTestCase {
    func testProcArgsBufferIsSplitIntoArgv() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array("/opt/homebrew/bin/node".utf8) + [0, 0, 0])
        for arg in ["node", "/opt/homebrew/bin/claude", "--resume"] { bytes.append(contentsOf: Array(arg.utf8) + [0]) }
        bytes.append(contentsOf: Array("HOME=/Users/x".utf8) + [0])
        XCTAssertEqual(LiveAgentProbe.parseProcArgs(bytes), ["node", "/opt/homebrew/bin/claude", "--resume"])
        XCTAssertEqual(LiveAgentProbe.parseProcArgs([]), [])
        XCTAssertEqual(LiveAgentProbe.parseProcArgs([1, 0]), [])
    }

    /// The live probe against this test process: read-only kernel calls.
    func testLiveProbeSeesThisProcess() throws {
        let probe = LiveAgentProbe()
        let me = getpid()
        XCTAssertFalse(LiveAgentProbe.path(of: me).isEmpty)
        XCTAssertFalse(LiveAgentProbe.arguments(of: me).isEmpty)
        let usage = try XCTUnwrap(probe.usage(pid: me))
        XCTAssertGreaterThan(usage.residentBytes, 0)
        XCTAssertEqual(usage.cwd.map { URL(fileURLWithPath: $0).standardizedFileURL.path },
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path)
        XCTAssertEqual(probe.parent(of: me), getppid())
        XCTAssertTrue(probe.processes().contains { $0.pid == me })
        XCTAssertNil(probe.usage(pid: -5))
    }

    func testRepoRootWalksUpToDotGit() {
        let exists: (String) -> Bool = { $0 == "/Users/x/code/api/.git" }
        XCTAssertEqual(GitRepoLocator.root(of: "/Users/x/code/api/src/lib", fileExists: exists), "/Users/x/code/api")
        XCTAssertEqual(GitRepoLocator.root(of: "/Users/x/code/api", fileExists: exists), "/Users/x/code/api")
        XCTAssertNil(GitRepoLocator.root(of: "/Users/x/other", fileExists: exists))
        XCTAssertEqual(GitRepoLocator.name(of: "/Users/x/code/api"), "api")
    }
}

final class TmuxPaneListTests: XCTestCase {
    func testParsesPanesAndMarks() {
        let output = [
            "%0|:|main:0.0|:|501|:|0|:||:|zsh|:|/Users/x/api|:|mac.local",
            "%1|:|main:0.1|:|502|:|0|:|1|:|node|:|/Users/x/web|:|✳ Claude Code",
            "%2|:|work:1.0|:|503|:|0|:||:|bash|:|/tmp|:|awake: nightly build",
            "%3|:|work:1.1|:|504|:|1|:|on|:|zsh|:|/tmp|:|dead one",
            "%4|:|work:1.2|:|505|:|0|:|off|:|zsh|:|/tmp|:|title|:|with a separator",
            "garbage",
            "%5|:|x:0.0|:|notapid|:|0|:||:|zsh|:|/tmp|:|t",
        ].joined(separator: "\n")
        let panes = TmuxPaneList.parse(output)
        XCTAssertEqual(panes.map(\.id), ["%0", "%1", "%2", "%3", "%4"])
        XCTAssertEqual(panes.map(\.marked), [false, true, true, true, false])
        XCTAssertEqual(panes[1].target, "main:0.1")
        XCTAssertEqual(panes[1].pid, 502)
        XCTAssertEqual(panes[1].currentPath, "/Users/x/web")
        XCTAssertTrue(panes[3].dead)
        XCTAssertEqual(panes[4].title, "title|:|with a separator")
        XCTAssertEqual(TmuxPaneList.name(of: panes[2]), "nightly build")
        XCTAssertEqual(TmuxPaneList.name(of: panes[1]), "node")
    }

    func testMarkValues() {
        for on in ["1", "on", "yes", "true", "anything"] { XCTAssertTrue(TmuxPaneList.isMarkValue(on), on) }
        for off in ["", " ", "0", "off", "false", "No"] { XCTAssertFalse(TmuxPaneList.isMarkValue(off), off) }
        XCTAssertEqual(TmuxPaneList.markCommand, "tmux set-option -p @awake 1")
    }
}

final class AgentRegistryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let noRepo: (String) -> String? = { _ in nil }

    private func discover(_ probe: FakeAgentProbe, panes: [TmuxPane] = []) -> [DiscoveredAgent] {
        AgentRegistry.discover(processes: probe.processes(), apps: probe.apps(), panes: panes, selfPid: 1)
    }

    private func readings(_ probe: FakeAgentProbe, paneText: [String: String] = [:]) -> AgentRegistry.Readings {
        AgentRegistry.Readings(usage: probe.usageTable, paneText: paneText)
    }

    func testFindsAgentsWithTheirTreesAndFoldsSameKindChildren() {
        let probe = FakeAgentProbe()
        probe.add(100, exe: "/bin/zsh")
        probe.add(200, parent: 100, exe: "/opt/homebrew/bin/node", args: ["node", "/opt/homebrew/bin/claude"])
        probe.add(201, parent: 200, exe: "/bin/zsh", args: ["zsh", "-c", "swift build"])
        probe.add(202, parent: 201, exe: "/usr/bin/swift")
        probe.add(300, exe: "/usr/local/bin/ollama", args: ["ollama", "serve"])
        probe.add(301, parent: 300, exe: "/usr/local/bin/ollama", args: ["ollama", "runner"])
        probe.add(400, exe: "/usr/bin/vim")
        let found = discover(probe)
        XCTAssertEqual(found.map(\.kind), [.claude, .ollama])
        XCTAssertEqual(found[0].pids, [200, 201, 202])
        XCTAssertEqual(found[0].parents, [200: 100, 201: 200, 202: 201])
        XCTAssertEqual(found[0].identities[202], ProcessIdentity(startedAt: 202))
        XCTAssertEqual(found[1].pids, [300, 301], "the runner is part of the server")
        XCTAssertEqual(found[0].id, "claude-200-200.0")
        XCTAssertFalse(found[0].hasSudo)
    }

    func testAnAgentInsideAnotherKindIsItsOwnAgentAndLeavesTheOuterTree() {
        let probe = FakeAgentProbe()
        probe.add(10, exe: "/Applications/Cursor.app/Contents/MacOS/Cursor")
        probe.appList = [RunningApp(pid: 10, bundleId: "com.todesktop.230313mzl4w4u92", name: "Cursor")]
        probe.add(11, parent: 10, exe: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper")
        probe.add(12, parent: 11, exe: "/bin/zsh")
        probe.add(13, parent: 12, exe: "/opt/homebrew/bin/claude")
        probe.add(14, parent: 13, exe: "/usr/bin/git")
        let found = discover(probe)
        XCTAssertEqual(found.map(\.kind), [.cursor, .claude])
        XCTAssertEqual(found[0].pids, [10, 11, 12])
        XCTAssertEqual(found[1].pids, [13, 14])
    }

    func testAwakeItselfIsNeverAnAgent() {
        let probe = FakeAgentProbe()
        probe.add(77, exe: "/x/claude")
        XCTAssertTrue(AgentRegistry.discover(processes: probe.processes(), apps: [], panes: [], selfPid: 77).isEmpty)
    }

    func testSudoInTheTreeIsNoticed() {
        let probe = FakeAgentProbe()
        probe.add(200, exe: "/opt/homebrew/bin/codex")
        probe.add(201, parent: 200, exe: "/usr/bin/sudo", args: ["sudo", "make", "install"])
        XCTAssertTrue(discover(probe)[0].hasSudo)
    }

    func testTmuxPaneIsAttachedAndMarkedPanesBecomeAgents() {
        let probe = FakeAgentProbe()
        probe.add(500, exe: "/bin/zsh")
        probe.add(501, parent: 500, exe: "/opt/homebrew/bin/claude")
        probe.add(600, exe: "/bin/bash")
        probe.add(601, parent: 600, exe: "/usr/bin/make")
        probe.add(700, exe: "/bin/zsh")
        let panes = [
            TmuxPane(id: "%1", target: "main:0.0", pid: 500, marked: true, title: "x", currentCommand: "node"),
            TmuxPane(id: "%2", target: "main:0.1", pid: 600, marked: true, title: "awake: nightly", currentCommand: "make", currentPath: "/Users/x/api"),
            TmuxPane(id: "%3", target: "main:0.2", pid: 700, marked: false),
            TmuxPane(id: "%4", target: "main:0.3", pid: 800, marked: true, dead: true),
        ]
        let found = discover(probe, panes: panes)
        XCTAssertEqual(found.map(\.kind), [.claude, .tmuxPane])
        XCTAssertEqual(found[0].pane?.target, "main:0.0", "the marked pane holding claude is claude's pane, not a second agent")
        XCTAssertEqual(found[1].name, "nightly")
        XCTAssertEqual(found[1].pids, [600, 601])
        XCTAssertEqual(found[1].id, "tmux-600-600.0")
    }

    func testIdsAreStableAcrossPollsAndAReusedPidIsANewAgent() {
        let probe = FakeAgentProbe()
        probe.add(200, exe: "/x/claude", cwd: "/Users/x/api")
        var registry = AgentRegistry()
        _ = registry.apply(discover(probe), readings: readings(probe), now: at(0), stallAfter: 600, repoRoot: { $0 == "/Users/x/api" ? "/Users/x/api" : nil })
        _ = registry.apply(discover(probe), readings: readings(probe), now: at(20), stallAfter: 600, repoRoot: noRepo)
        XCTAssertEqual(registry.agents.map(\.id), ["claude-200-200.0"])
        let first = registry.agents[0]
        XCTAssertEqual(first.firstSeen, at(0))
        XCTAssertEqual(first.lastSeen, at(20))
        XCTAssertEqual(first.cwd, "/Users/x/api")
        XCTAssertEqual(first.repoName, "api")
        XCTAssertEqual(first.label, "claude (api)")
        XCTAssertEqual(first.residentBytes, 1_000_000)
        XCTAssertTrue(first.isConfirmed)

        // Same pid, another process.
        probe.add(200, exe: "/x/claude", startedAt: 9999)
        let events = registry.apply(discover(probe), readings: readings(probe), now: at(40), stallAfter: 600, repoRoot: noRepo)
        XCTAssertEqual(Set(registry.agents.map(\.id)), ["claude-200-200.0", "claude-200-9999.0"])
        XCTAssertEqual(events.map(\.transition.to), [.exited])
        XCTAssertEqual(events.first?.agent.id, "claude-200-200.0")
    }

    func testCPUPercentIsTheDeltaOverTheIntervalAcrossTheTree() {
        let probe = FakeAgentProbe()
        probe.add(200, exe: "/x/claude")
        probe.add(201, parent: 200, exe: "/usr/bin/swift")
        var registry = AgentRegistry()
        _ = registry.apply(discover(probe), readings: readings(probe), now: at(0), stallAfter: 600, repoRoot: noRepo)
        XCTAssertNil(registry.agents[0].cpuPercent, "one sample has no interval")
        probe.burn(200, seconds: 2)
        probe.burn(201, seconds: 8)
        let events = registry.apply(discover(probe), readings: readings(probe), now: at(20), stallAfter: 600, repoRoot: noRepo)
        XCTAssertEqual(registry.agents[0].cpuPercent ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(events.map(\.transition), [AgentTransition(from: .alive, to: .busy)])
        // A child that exits takes its total with it: never negative.
        probe.remove(201)
        _ = registry.apply(discover(probe), readings: readings(probe), now: at(40), stallAfter: 600, repoRoot: noRepo)
        XCTAssertEqual(registry.agents[0].cpuPercent, 0)
    }

    func testAProcessSeenOnceThatGoesAwayIsForgottenQuietly() {
        let probe = FakeAgentProbe()
        probe.add(200, exe: "/x/claude")
        var registry = AgentRegistry()
        _ = registry.apply(discover(probe), readings: readings(probe), now: at(0), stallAfter: 600, repoRoot: noRepo)
        XCTAssertFalse(registry.agents[0].isConfirmed)
        probe.remove(200)
        let events = registry.apply(discover(probe), readings: readings(probe), now: at(20), stallAfter: 600, repoRoot: noRepo)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(registry.agents.isEmpty)
    }

    func testExitedAgentsAreKeptForAWhileThenDropped() {
        let probe = FakeAgentProbe()
        probe.add(200, exe: "/x/claude")
        var registry = AgentRegistry()
        _ = registry.apply(discover(probe), readings: readings(probe), now: at(0), stallAfter: 600, repoRoot: noRepo)
        _ = registry.apply(discover(probe), readings: readings(probe), now: at(20), stallAfter: 600, repoRoot: noRepo)
        probe.remove(200)
        XCTAssertEqual(registry.apply([], readings: .init(), now: at(40), stallAfter: 600, repoRoot: noRepo).map(\.transition.to), [.exited])
        XCTAssertTrue(registry.apply([], readings: .init(), now: at(60), stallAfter: 600, repoRoot: noRepo).isEmpty, "exited once")
        XCTAssertEqual(registry.agents.map(\.state), [.exited])
        _ = registry.apply([], readings: .init(), now: at(40 + AgentRegistry.exitedRetention), stallAfter: 600, repoRoot: noRepo)
        XCTAssertTrue(registry.agents.isEmpty)
    }

    func testPaneTextDrivesWaiting() {
        let probe = FakeAgentProbe()
        probe.add(500, exe: "/bin/zsh")
        probe.add(501, parent: 500, exe: "/x/codex")
        let panes = [TmuxPane(id: "%1", target: "main:0.0", pid: 500)]
        let text = ["%1": "Allow command? (y/n)"]
        var registry = AgentRegistry()
        XCTAssertTrue(registry.apply(discover(probe, panes: panes), readings: readings(probe, paneText: text), now: at(0), stallAfter: 600, repoRoot: noRepo).isEmpty)
        let events = registry.apply(discover(probe, panes: panes), readings: readings(probe, paneText: text), now: at(20), stallAfter: 600, repoRoot: noRepo)
        XCTAssertEqual(events.map(\.transition.to), [.waitingForInput])
        XCTAssertEqual(events[0].agent.machine.waitingPrompt, "Allow command? (y/n)")
        XCTAssertEqual(events[0].agent.tmuxTarget, "main:0.0")
        XCTAssertEqual(registry.agents[0].cwd, nil)
    }

    func testServersDoNotStall() {
        XCTAssertFalse(AgentRegistry.thresholds(for: .ollama, stallAfter: 60).conversational)
        XCTAssertTrue(AgentRegistry.thresholds(for: .claude, stallAfter: 60).conversational)
        XCTAssertEqual(AgentRegistry.thresholds(for: .claude, stallAfter: 60).stallAfter, 60)
    }

    // MARK: Hooks

    private func registryWithClaude(_ probe: FakeAgentProbe, cwd: String = "/Users/x/api") -> AgentRegistry {
        probe.add(200, exe: "/x/claude", cwd: cwd)
        probe.add(201, parent: 200, exe: "/bin/zsh")
        var registry = AgentRegistry()
        _ = registry.apply(discover(probe), readings: readings(probe), now: at(0), stallAfter: 600, repoRoot: noRepo)
        _ = registry.apply(discover(probe), readings: readings(probe), now: at(20), stallAfter: 600, repoRoot: noRepo)
        return registry
    }

    func testHookMatchesByPidWalkingUpFromAShellNewerThanTheLastPoll() {
        let probe = FakeAgentProbe()
        var registry = registryWithClaude(probe)
        // The hook's shell (999) started after the last poll; its parent is
        // claude's child 201.
        let event = AgentHookEvent(kind: "claude", action: .waiting("Allow Bash?"), pid: 999, sessionId: "s1")
        let result = registry.apply(hook: event, now: at(25), parentOf: { $0 == 999 ? 201 : nil }, repoRoot: noRepo)
        XCTAssertEqual(result?.agent.id, "claude-200-200.0")
        XCTAssertEqual(result?.transition.to, .waitingForInput)
        XCTAssertEqual(registry.agents.count, 1)
        XCTAssertEqual(registry.agents[0].sessionId, "s1")
    }

    func testHookMatchesBySessionIdThenByWorkingDirectory() {
        let probe = FakeAgentProbe()
        var registry = registryWithClaude(probe)
        // By cwd: no pid, no known session.
        let first = registry.apply(hook: AgentHookEvent(kind: "claude", action: .heartbeat, sessionId: "abc", cwd: "/Users/x/api", transcriptPath: "/t.jsonl"), now: at(25), repoRoot: noRepo)
        XCTAssertEqual(first?.agent.id, "claude-200-200.0")
        XCTAssertEqual(registry.agents[0].transcriptPath, "/t.jsonl")
        // By session id alone.
        let second = registry.apply(hook: AgentHookEvent(kind: "claude", action: .finished, sessionId: "abc"), now: at(30), repoRoot: noRepo)
        XCTAssertEqual(second?.agent.id, "claude-200-200.0")
        XCTAssertEqual(second?.transition.to, .idle)
        XCTAssertEqual(registry.agents.count, 1)
    }

    func testAHookOfAnotherKindDoesNotMatchByDirectory() {
        let probe = FakeAgentProbe()
        var registry = registryWithClaude(probe)
        _ = registry.apply(hook: AgentHookEvent(kind: "codex", action: .finished, cwd: "/Users/x/api"), now: at(25), repoRoot: noRepo)
        XCTAssertEqual(registry.agents.map(\.kind), [.claude, .hookOnly])
    }

    func testUnmatchedHookCreatesAHookOnlyAgentThatCanExit() {
        var registry = AgentRegistry()
        let waiting = registry.apply(hook: AgentHookEvent(kind: "claude", action: .waiting("Allow?"), sessionId: "s9", cwd: "/Users/x/web"), now: at(0), repoRoot: { _ in "/Users/x/web" })
        XCTAssertEqual(waiting?.transition.to, .waitingForInput)
        let agent = registry.agents[0]
        XCTAssertEqual(agent.id, "hook-claude-s9")
        XCTAssertEqual(agent.kind, .hookOnly)
        XCTAssertEqual(agent.name, "claude")
        XCTAssertEqual(agent.repoName, "web")
        XCTAssertNil(agent.rootPid)
        XCTAssertTrue(agent.isConfirmed)
        // The same session again is the same agent.
        _ = registry.apply(hook: AgentHookEvent(kind: "claude", action: .heartbeat, sessionId: "s9"), now: at(5), repoRoot: noRepo)
        XCTAssertEqual(registry.agents.count, 1)
        // Polls keep it; an ended hook exits it.
        XCTAssertTrue(registry.apply([], readings: .init(), now: at(20), stallAfter: 600, repoRoot: noRepo).isEmpty)
        let ended = registry.apply(hook: AgentHookEvent(kind: "claude", action: .ended("logout"), sessionId: "s9"), now: at(30), repoRoot: noRepo)
        XCTAssertEqual(ended?.transition.to, .exited)
    }

    func testAHookOnlyAgentStallsWhenItsHeartbeatsStopAndIsDroppedOnceLongAtRest() {
        var registry = AgentRegistry()
        _ = registry.apply(hook: AgentHookEvent(kind: "codex", action: .heartbeat, sessionId: "t1"), now: at(0), repoRoot: noRepo)
        XCTAssertEqual(registry.apply([], readings: .init(), now: at(100), stallAfter: 600, repoRoot: noRepo).map(\.transition.to), [.idle])
        XCTAssertEqual(registry.apply([], readings: .init(), now: at(600), stallAfter: 600, repoRoot: noRepo).map(\.transition.to), [.stalled])
        _ = registry.apply(hook: AgentHookEvent(kind: "codex", action: .finished, sessionId: "t1"), now: at(700), repoRoot: noRepo)
        _ = registry.apply([], readings: .init(), now: at(800), stallAfter: 600, repoRoot: noRepo)
        XCTAssertEqual(registry.agents.count, 1)
        _ = registry.apply([], readings: .init(), now: at(700 + AgentRegistry.hookOnlyRetention), stallAfter: 600, repoRoot: noRepo)
        XCTAssertTrue(registry.agents.isEmpty)
    }
}

/// The live reader against a private tmux server (`tmux -L`), never the
/// contributor's own panes. Skipped without tmux.
final class LiveTmuxReaderTests: XCTestCase {
    private var tmux = ""
    private let socket = "awake-agents-\(UUID().uuidString.prefix(8))"

    override func setUp() async throws {
        guard let found = Shell.locate(TmuxNudge.candidates) else { throw XCTSkip("tmux is not installed") }
        tmux = found
    }

    override func tearDown() async throws {
        guard !tmux.isEmpty else { return }
        let path = try? await Shell.run(tmux, ["-L", socket, "display-message", "-p", "#{socket_path}"], timeout: 5)
        _ = try? await Shell.run(tmux, ["-L", socket, "kill-server"], timeout: 5)
        if let p = path?.stdout.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty { try? FileManager.default.removeItem(atPath: p) }
    }

    private func run(_ args: [String]) async throws -> ShellResult {
        try await Shell.run(tmux, ["-f", "/dev/null", "-L", socket] + args, timeout: 5)
    }

    func testListsPanesReadsTheMarkAndCapturesText() async throws {
        let reader = LiveTmuxReader(socketName: socket)
        let none = await reader.panes()
        XCTAssertEqual(none, [], "no server is no panes, not an error")

        let started = try await run(["new-session", "-d", "-s", "agents", "-x", "80", "-y", "24", "printf 'Do you want to proceed? (y/n)\\n'; exec cat"])
        XCTAssertTrue(started.succeeded, started.stderr)
        let split = try await run(["split-window", "-t", "agents:0", "cat"])
        XCTAssertTrue(split.succeeded, split.stderr)
        let mark = try await run(["set-option", "-p", "-t", "%0", TmuxPaneList.markOption, "1"])
        XCTAssertTrue(mark.succeeded, mark.stderr)

        let panes = await reader.panes()
        XCTAssertEqual(panes.map(\.id), ["%0", "%1"])
        guard panes.count == 2 else { return }
        XCTAssertEqual(panes.map(\.marked), [true, false], "the mark is the pane's own")
        XCTAssertEqual(panes.map(\.target), ["agents:0.0", "agents:0.1"])
        XCTAssertTrue(panes.allSatisfy { $0.pid > 1 && !$0.dead })
        XCTAssertFalse(panes[0].currentPath.isEmpty)

        var text: String?
        for _ in 0..<50 {
            text = await reader.capture(paneId: "%0")
            if text?.contains("(y/n)") == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(PromptDetector.question(in: PromptDetector.tail(of: text ?? ""))?.excerpt, "Do you want to proceed? (y/n)")
        let missing = await reader.capture(paneId: "%99")
        XCTAssertNil(missing)
    }
}
