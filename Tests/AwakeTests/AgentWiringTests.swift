import XCTest
@testable import Awake

/// The agent features as AppServices wires them, over fakes. The services
/// are not started whole (that needs the real lid and battery observers);
/// `startAgents` is the part `start` calls for phase 2.
@MainActor
final class AgentWiringTests: XCTestCase {
    private func makeServices(_ h: Harness, probe: FakeAgentProbe) -> AppServices {
        let services = AppServices(paths: h.home.paths, notifier: h.notifier, audio: h.audio, processControl: h.procs, locationPermission: LocationPermission(authorizationStatus: .notDetermined), lidSimulation: nil, lidSimulationEnabled: false)
        services.agentDependencies.probe = probe
        services.agentDependencies.tmux = NoTmuxReader()
        services.agentDependencies.git = AgentGit(runner: FakeShellRunner(), git: nil)
        services.agentDependencies.dialogs = FakeDialogProbe()
        // The temp home is too deep for a socket path.
        services.agentDependencies.hookSocket = false
        return services
    }

    func testStartAgentsInstallsTheHookScriptAndStopAgentsClearsEverything() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 3600)
        let services = makeServices(h, probe: FakeAgentProbe())
        services.startAgents(for: m)
        XCTAssertNotNil(services.agentTracker)
        XCTAssertNotNil(services.dialogWatcher)
        XCTAssertNotNil(services.preEnd)
        XCTAssertNotNil(services.agentPauser)
        XCTAssertNotNil(m.preEnd)
        XCTAssertEqual(try String(contentsOf: h.home.paths.hookScript, encoding: .utf8), HookScript.text)
        services.stopAgents()
        XCTAssertNil(services.agentTracker)
        XCTAssertNil(services.dialogWatcher)
        XCTAssertNil(services.preEnd)
        XCTAssertNil(services.agentPauser)
        XCTAssertNil(m.preEnd)
        XCTAssertEqual(services.status.agents, [])
        await m.end(reason: .user)
    }

    func testTrackingOffInstallsNoScript() async {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        m.config.agentTracking = false
        await m.start(duration: 3600)
        let services = makeServices(h, probe: FakeAgentProbe())
        services.startAgents(for: m)
        defer { services.stopAgents() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.home.paths.hookScript.path))
        await m.end(reason: .user)
    }

    func testLoopbackHookReachesTheTrackerAndTheReportAndTheSummary() async {
        let h = Harness()
        defer { h.home.destroy() }
        let m = h.makeManager()
        await m.start(duration: 3600)
        let services = makeServices(h, probe: FakeAgentProbe())
        services.startAgents(for: m)
        // What the loopback endpoint hands over for POST /hooks/claude.
        services.statusServer.onHook?(AgentHookEvent(kind: "claude", action: .waiting("Allow Bash?"), sessionId: "s1"))
        XCTAssertEqual(h.notifier.posts.last?.title, "Agent waiting: claude")
        XCTAssertEqual(services.agentTracker?.statuses().map(\.state), [.waitingForInput])
        services.stopAgents()
        await m.end(reason: .user)
        let summary = h.notifier.bodies(titled: SessionReport.title).last ?? ""
        XCTAssertTrue(summary.hasSuffix("Agents: 1 ran, 1 waiting for input at the end."), summary)
    }
}
