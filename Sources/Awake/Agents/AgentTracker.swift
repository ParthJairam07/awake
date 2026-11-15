import Foundation

/// Phase 2: knows the agents. Polls the process table and tmux, feeds the
/// registry and its state machines, takes hook events, and posts the agent
/// alerts through the app's notifier (and so to the phone). Runs only
/// while a session does.
@MainActor
final class AgentTracker {
    typealias LogReader = @Sendable (AgentRecord) -> Date?

    static let pollInterval: TimeInterval = 20
    /// How often each repo is asked for its unpushed commits.
    static let unpushedInterval: TimeInterval = 300

    private let probe: any AgentProcessProbing
    private let tmux: any TmuxReading
    private let notifier: any Notifying
    private let git: AgentGit
    private let clock: @Sendable () -> Date
    private let config: @MainActor () -> Config
    private let repoRoot: @Sendable (String) -> String?
    private let logModified: LogReader
    private let interval: TimeInterval

    private(set) var registry = AgentRegistry()
    private(set) var running = false
    private var timer: (any DispatchSourceTimer)?
    private var polling = false
    private var pollAgain = false
    /// Since when every conversational agent has been idle or gone.
    private var settledSince: Date?
    private var allDoneAnnounced = false
    private var unpushedCheckedAt: Date?
    private var unpushedTask: Task<Void, Never>?
    private(set) var unpushed: [String: Int] = [:]

    /// The statuses changed (a poll or a hook). AppServices mirrors them
    /// into the menu and status.json.
    var onChange: (@MainActor ([AgentStatus]) -> Void)?
    /// Something for the session report changed.
    var onReport: (@MainActor ((inout SessionReport) -> Void) -> Void)?

    init(
        probe: any AgentProcessProbing = LiveAgentProbe(),
        tmux: any TmuxReading = LiveTmuxReader(),
        notifier: any Notifying,
        git: AgentGit = AgentGit(),
        clock: @escaping @Sendable () -> Date = { Date() },
        repoRoot: @escaping @Sendable (String) -> String? = { GitRepoLocator.root(of: $0) },
        logModified: @escaping LogReader = { AgentLogs.modified(for: $0) },
        pollInterval: TimeInterval = AgentTracker.pollInterval,
        config: @escaping @MainActor () -> Config
    ) {
        self.probe = probe
        self.tmux = tmux
        self.notifier = notifier
        self.git = git
        self.clock = clock
        self.repoRoot = repoRoot
        self.logModified = logModified
        self.interval = pollInterval
        self.config = config
    }

    var agents: [AgentRecord] { registry.agents }

    func statuses(now: Date? = nil) -> [AgentStatus] {
        let now = now ?? clock()
        return registry.agents.filter(\.isConfirmed).map { AgentStatus($0, now: now) }
    }

    /// Repos the tracked agents work in, each once, sorted.
    var repos: [String] {
        Array(Set(registry.agents.filter(\.isConfirmed).compactMap(\.repo))).sorted()
    }

    func start() {
        guard !running else { return }
        running = true
        registry.reset()
        settledSince = nil
        allDoneAnnounced = false
        unpushed = [:]
        unpushedCheckedAt = nil
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: interval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in await self?.poll() }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        unpushedTask?.cancel()
        unpushedTask = nil
        registry.reset()
        publish()
    }

    /// One poll, also on demand (the menu opening, a test). A poll asked
    /// for while one runs is run once more after it.
    func poll() async {
        guard running, config().agentTracking else {
            if !registry.records.isEmpty {
                registry.reset()
                publish()
            }
            return
        }
        guard !polling else {
            pollAgain = true
            return
        }
        polling = true
        defer { polling = false }
        repeat {
            pollAgain = false
            await pollOnce()
        } while pollAgain && running
    }

    private func pollOnce() async {
        let probe = self.probe
        let (processes, apps) = await Task.detached(priority: .utility) { (probe.processes(), probe.apps()) }.value
        let panes = await tmux.panes()
        guard running else { return }
        let discovered = AgentRegistry.discover(processes: processes, apps: apps, panes: panes)

        let pids = discovered.flatMap(\.pids)
        let usage = await Task.detached(priority: .utility) {
            var out: [Int32: AgentProcessUsage] = [:]
            for pid in pids { out[pid] = probe.usage(pid: pid) }
            return out
        }.value
        var readings = AgentRegistry.Readings(usage: usage)
        for paneId in Set(discovered.compactMap { $0.pane?.id }) {
            if let text = await tmux.capture(paneId: paneId) { readings.paneText[paneId] = text }
        }
        guard running else { return }
        let known = registry.records
        for found in discovered {
            let record = known[found.id] ?? AgentRecord(
                id: found.id, kind: found.kind, name: found.name, rootPid: found.rootPid, identity: found.identity,
                firstSeen: clock(), lastSeen: clock(), machine: AgentStateMachine(firstSeen: clock())
            )
            var withCwd = record
            withCwd.cwd = record.cwd ?? usage[found.rootPid]?.cwd
            if let modified = logModified(withCwd) { readings.logModified[found.id] = modified }
        }
        for record in known.values where record.rootPid == nil {
            if let modified = logModified(record) { readings.logModified[record.id] = modified }
        }

        let now = clock()
        let before = Set(registry.records.values.filter(\.isConfirmed).map(\.id))
        let events = registry.apply(discovered, readings: readings, now: now, stallAfter: stallAfter, repoRoot: repoRoot)
        let newlyConfirmed = registry.records.values.filter { $0.isConfirmed && !before.contains($0.id) }
        if !newlyConfirmed.isEmpty { note(newlyConfirmed) }
        for event in events { handle(event) }
        checkAllDone(now: now)
        refreshUnpushedIfDue(now: now)
        publish()
    }

    /// A hook event, from the socket or the loopback port.
    func ingest(hook event: AgentHookEvent) {
        guard running, config().agentTracking else { return }
        let probe = self.probe
        let before = Set(registry.records.keys)
        let result = registry.apply(hook: event, now: clock(), parentOf: { probe.parent(of: $0) }, repoRoot: repoRoot)
        let created = registry.records.values.filter { !before.contains($0.id) }
        if !created.isEmpty { note(created) }
        if let result { handle(result) }
        checkAllDone(now: clock())
        publish()
    }

    private var stallAfter: TimeInterval { TimeInterval(max(1, config().agentStallMinutes)) * 60 }

    private func handle(_ event: AgentEvent) {
        let agent = event.agent
        let c = config()
        Log.info("agent \(agent.label) [\(agent.id)]: \(event.transition.from.label) -> \(event.transition.to.label)")
        note([agent])
        switch event.transition.to {
        case .waitingForInput where c.agentWaitingAlerts:
            let text = AgentLines.waiting(agent)
            notifier.post(title: text.title, body: text.body)
        case .stalled where c.agentStalledAlerts:
            let text = AgentLines.stalled(agent, minutes: c.agentStallMinutes)
            notifier.post(title: text.title, body: text.body)
        case .exited where c.agentExitedAlerts:
            let text = AgentLines.exited(agent)
            notifier.post(title: text.title, body: text.body)
        default:
            break
        }
    }

    /// "All agents finished": every conversational agent idle or gone for
    /// `allDoneMinutes`, announced once until one of them works again.
    private func checkAllDone(now: Date) {
        let tracked = registry.agents.filter { $0.isConfirmed && $0.kind.isConversational }
        guard !tracked.isEmpty, tracked.allSatisfy({ $0.state.isSettled }) else {
            settledSince = nil
            allDoneAnnounced = false
            return
        }
        // Settled since the latest of their own transitions, so a poll
        // interval cannot shorten the wait.
        let since = settledSince ?? tracked.map(\.machine.since).max() ?? now
        settledSince = since
        let c = config()
        guard !allDoneAnnounced, now.timeIntervalSince(since) >= TimeInterval(max(1, c.allDoneMinutes)) * 60 else { return }
        allDoneAnnounced = true
        guard c.allDoneAlert else { return }
        notifier.post(title: AgentLines.allDoneTitle, body: AgentLines.allDone(names: tracked.map(\.label), minutes: c.allDoneMinutes))
    }

    /// Write the agents' latest state into the session report.
    private func note(_ agents: [AgentRecord]) {
        guard !agents.isEmpty else { return }
        onReport? { report in
            var entries = report.agents ?? [:]
            for agent in agents {
                var entry = entries[agent.id] ?? AgentReportEntry(name: agent.name, repo: agent.repoName, lastState: agent.state)
                entry.name = agent.name
                entry.repo = agent.repoName ?? entry.repo
                entry.lastState = agent.state
                if agent.state == .stalled { entry.stalled = true }
                if agent.state == .waitingForInput { entry.waited = true }
                entries[agent.id] = entry
            }
            report.agents = entries
        }
    }

    // MARK: Unpushed commits

    private func refreshUnpushedIfDue(now: Date) {
        if let last = unpushedCheckedAt, now.timeIntervalSince(last) < Self.unpushedInterval, Set(repos).isSubset(of: Set(unpushed.keys)) { return }
        guard unpushedTask == nil, !repos.isEmpty else { return }
        unpushedCheckedAt = now
        unpushedTask = Task { @MainActor [weak self] in
            await self?.refreshUnpushed()
            self?.unpushedTask = nil
        }
    }

    /// Ask every agent repo now; the summary reads what this leaves.
    func refreshUnpushed() async {
        var counts: [String: Int] = [:]
        for repo in repos {
            if Task.isCancelled || !running { return }
            // A repo without an upstream is recorded as 0: asked, nothing
            // to report.
            counts[repo] = await git.unpushedCount(repo: repo) ?? 0
        }
        guard running, counts != unpushed else { return }
        unpushed = counts
        onReport? { $0.unpushed = counts.filter { $0.value > 0 } }
    }

    private func publish() {
        // Ages change every poll, so every poll is published.
        onChange?(statuses())
    }
}

/// Where an agent writes as it works, for the "last output" age of an
/// agent outside tmux.
enum AgentLogs {
    /// The transcript a hook named, else Claude Code's newest transcript
    /// for the agent's directory (`~/.claude/projects/<dir with every
    /// non-alphanumeric as ->/*.jsonl`).
    static func modified(for record: AgentRecord, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Date? {
        if let path = record.transcriptPath, let date = modified(path) { return date }
        guard record.kind == .claude, let cwd = record.cwd else { return nil }
        let directory = home.appendingPathComponent(".claude/projects/\(claudeProjectSlug(cwd))", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.filter { $0.pathExtension == "jsonl" }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
    }

    static func claudeProjectSlug(_ cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    private static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }
}
