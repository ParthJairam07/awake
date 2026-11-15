import Foundation

/// Why agents are being paused.
enum AgentPressure: String, Sendable, CaseIterable {
    case battery
    case thermal
    case memory

    var text: String {
        switch self {
        case .battery: "battery under the Low Power Mode floor"
        case .thermal: "heat"
        case .memory: "critical memory pressure"
        }
    }
}

/// Pure rules of the priority pause.
enum PausePlanner {
    static let low = -1
    static let normal = 0
    static let high = 1

    /// By name first (a marked pane's own name), then by kind. Unlisted
    /// is normal.
    static func priority(of agent: AgentRecord, config: Config) -> Int {
        config.agentPriorities[agent.name] ?? config.agentPriorities[agent.kind.rawValue] ?? normal
    }

    /// Why an agent must not be paused, or nil. An agent at a sudo
    /// password prompt, or with a sudo anywhere under it, is left alone:
    /// a stopped sudo holds its terminal and its timestamp in a state
    /// nothing here can undo (the never-SIGKILL-sudo rule's sibling).
    static func protection(_ agent: AgentRecord) -> String? {
        if agent.rootPid == nil || agent.pids.isEmpty { return "no process" }
        if agent.state == .exited { return "exited" }
        if agent.hasSudo { return "sudo is running under it" }
        if agent.state == .waitingForInput, agent.machine.waitingOnSudo { return "it is at a sudo password prompt" }
        return nil
    }

    /// The agents to pause next: the lowest-priority ones not paused yet,
    /// and never the highest priority present, so the work that matters
    /// most keeps running. With every agent at one priority nothing is
    /// paused.
    static func nextTier(agents: [AgentRecord], paused: Set<String>, config: Config) -> [AgentRecord] {
        let live = agents.filter { $0.rootPid != nil && $0.state != .exited && $0.isConfirmed }
        guard let top = live.map({ priority(of: $0, config: config) }).max() else { return [] }
        let candidates = live.filter { !paused.contains($0.id) && priority(of: $0, config: config) < top && protection($0) == nil }
        guard let lowest = candidates.map({ priority(of: $0, config: config) }).min() else { return [] }
        return candidates.filter { priority(of: $0, config: config) == lowest }
    }

    static func pressure(lowPowerCause: FloorRules.LowPowerCause?, thermal: ProcessInfo.ThermalState, memoryCritical: Bool) -> Set<AgentPressure> {
        var out: Set<AgentPressure> = []
        if lowPowerCause == .battery { out.insert(.battery) }
        if lowPowerCause == .thermal || thermal == .serious || thermal == .critical { out.insert(.thermal) }
        if memoryCritical { out.insert(.memory) }
        return out
    }
}

/// Phase 2, opt-in: under battery, heat or memory pressure, SIGSTOP the
/// lowest-priority agents first, one priority at a time, and SIGCONT them
/// in the same order when the pressure clears.
///
/// The stops go through the same journal as a lid-close freeze
/// (`RuntimeState.frozenProcesses`: written without identity before the
/// signal, promoted once the kernel confirms the stop), inside the same
/// exclusive transaction, so the end of the session, the recovery agent
/// and a relaunch all resume them like any frozen app. A lid open resumes
/// everything journaled, paused agents included; if the pressure is still
/// there they are paused again at the next evaluation.
@MainActor
final class AgentPauser {
    struct Paused: Equatable, Sendable {
        let id: String
        let name: String
        let processes: [FrozenProcess]
    }

    static let stepInterval: TimeInterval = 60

    private weak var manager: SessionManager?
    private let freezer: any Freezing
    private let notifier: any Notifying
    private let clock: @Sendable () -> Date
    private let agents: @MainActor () -> [AgentRecord]
    private let stepInterval: TimeInterval
    /// In pause order.
    private(set) var paused: [Paused] = []
    /// Paused by hand (the phone), in pause order. The pressure clearing
    /// does not resume these; the phone, a lid open or the session's end
    /// does.
    private(set) var held: [Paused] = []
    private var lastStep: Date?
    private var tail: Task<Void, Never>?

    init(
        manager: SessionManager,
        freezer: any Freezing,
        notifier: any Notifying,
        clock: @escaping @Sendable () -> Date = { Date() },
        stepInterval: TimeInterval = AgentPauser.stepInterval,
        agents: @escaping @MainActor () -> [AgentRecord]
    ) {
        self.manager = manager
        self.freezer = freezer
        self.notifier = notifier
        self.clock = clock
        self.stepInterval = stepInterval
        self.agents = agents
    }

    /// Evaluate with the pressure as it is now. Calls are run one after
    /// another.
    func update(pressure: Set<AgentPressure>) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await self.evaluate(pressure: pressure)
        }
        tail = task
        await task.value
    }

    /// Forget everything: the session's end resumes what is journaled.
    func stop() {
        tail?.cancel()
        tail = nil
        paused = []
        held = []
        lastStep = nil
    }

    // MARK: By hand

    /// Whether Awake holds a stop of this agent, from pressure or by hand.
    func isPaused(_ id: String) -> Bool {
        if let manager { dropWhatTheJournalNoLongerHolds(manager) }
        return (paused + held).contains { $0.id == id }
    }

    /// Pause one agent by hand, through the same journaled stop as the
    /// priority pause. nil when it is paused, else why it is not.
    func hold(_ agent: AgentRecord) async -> String? {
        guard let manager, manager.isActive else { return "no session is running" }
        guard !isPaused(agent.id) else { return nil }
        let stopped = await stop(agent, manager: manager, what: "pause by hand")
        guard !stopped.isEmpty else { return "\(agent.label) could not be paused; it was left running" }
        held.append(Paused(id: agent.id, name: agent.label, processes: stopped))
        return nil
    }

    /// Resume one agent Awake paused, by hand or under pressure. nil when
    /// it runs again, else why it does not.
    func release(id: String) async -> String? {
        guard let manager else { return "no session is running" }
        let entries = (paused + held).filter { $0.id == id }
        guard !entries.isEmpty else { return "it is not paused by Awake" }
        guard let failed = await resume(entries, manager: manager, what: "resume by hand") else {
            return "Awake is busy with another change; try again"
        }
        guard failed == 0 else {
            return "\(failed) process(es) could not be resumed and stay journaled; the next lid open or session end retries them"
        }
        paused.removeAll { $0.id == id }
        held.removeAll { $0.id == id }
        return nil
    }

    private func evaluate(pressure: Set<AgentPressure>) async {
        guard let manager, manager.isActive, !Task.isCancelled else { return }
        dropWhatTheJournalNoLongerHolds(manager)
        let config = manager.config
        guard config.priorityPause, !pressure.isEmpty else {
            if !paused.isEmpty { await resumeAll(manager, because: pressure.isEmpty ? "the pressure cleared" : "priority pause was turned off") }
            return
        }
        let now = clock()
        if let lastStep, now.timeIntervalSince(lastStep) < stepInterval { return }
        let tier = PausePlanner.nextTier(agents: agents(), paused: Set((paused + held).map(\.id)), config: config)
        guard !tier.isEmpty else { return }
        lastStep = now
        var names: [String] = []
        for agent in tier {
            if await pause(agent, manager: manager) { names.append(agent.label) }
        }
        guard !names.isEmpty else { return }
        let why = AgentPressure.allCases.filter(pressure.contains).map(\.text).joined(separator: ", ")
        notifier.post(title: "Agents paused", body: "Paused \(names.joined(separator: ", ")) (lowest priority first) because of \(why). They resume when it clears.")
    }

    /// A lid open or another undo resumed journaled stops: those agents
    /// run again, so they are no longer paused here.
    private func dropWhatTheJournalNoLongerHolds(_ manager: SessionManager) {
        let journaled = Set(manager.state.frozenPids)
        let before = paused.count
        paused.removeAll { entry in !entry.processes.contains { journaled.contains($0.pid) } }
        held.removeAll { entry in !entry.processes.contains { journaled.contains($0.pid) } }
        if paused.count != before { lastStep = nil }
    }

    /// One agent under pressure. True when at least one of its processes
    /// was stopped.
    private func pause(_ agent: AgentRecord, manager: SessionManager) async -> Bool {
        let stopped = await stop(agent, manager: manager, what: "priority pause")
        guard !stopped.isEmpty else { return false }
        paused.append(Paused(id: agent.id, name: agent.label, processes: stopped))
        return true
    }

    /// The one journaled stop: journal first, without identity, then the
    /// signals, then the confirmed stops with identity. Returns what was
    /// stopped; `what` names the caller in the log.
    private func stop(_ agent: AgentRecord, manager: SessionManager, what: String) async -> [FrozenProcess] {
        var stopped: [FrozenProcess] = []
        let ran = await manager.runExclusive("agent pause") { [freezer] in
            guard manager.isActive else { return }
            let already = Set(manager.state.frozenPids)
            let candidates = agent.pids.filter { !already.contains($0) }.compactMap { pid in
                agent.identities[pid].map { FrozenProcess(pid: pid, identity: $0) }
            }
            guard !candidates.isEmpty else { return }
            let pids = Set(candidates.map(\.pid))
            // Provisional, without identity: until the kernel has said
            // which stops are Awake's, the journal claims none.
            do {
                try manager.journal { $0.frozenProcesses.append(contentsOf: candidates.map { FrozenProcess(pid: $0.pid, identity: nil) }) }
            } catch {
                manager.fail("\(what): could not journal the pause of \(agent.label): \(error.localizedDescription); it was left running")
                return
            }
            let report = freezer.suspend(candidates, expectedParents: agent.parents)
            let suspended = Set(report.suspended)
            let confirmed = candidates.filter { suspended.contains($0.pid) }
            do {
                try manager.journal { s in
                    s.frozenProcesses.removeAll { pids.contains($0.pid) }
                    s.frozenProcesses.append(contentsOf: confirmed)
                }
            } catch {
                // Nothing on disk can resume these stops: undo them now.
                let undo = freezer.cancelStops(confirmed)
                let stuck = Set(undo.failed + undo.unverifiable + undo.unobserved)
                manager.clearUndoneFreeze(.init(pids: pids.subtracting(stuck), docker: false))
                manager.fail("\(what): could not confirm the pause of \(agent.label) in the journal: \(error.localizedDescription); resumed \(undo.resumed.count) of the \(confirmed.count) pid(s) it had just stopped")
                return
            }
            stopped = confirmed
            Log.info("\(what): stopped \(agent.label) (\(confirmed.count) pid(s), \(report.skipped.count) skipped)")
        }
        return ran ? stopped : []
    }

    /// The one journaled resume, of what the journal still holds of
    /// `entries`. The number of processes that could not be resumed and
    /// stay journaled; nil when the transaction was refused.
    private func resume(_ entries: [Paused], manager: SessionManager, what: String) async -> Int? {
        var failed = 0
        let ran = await manager.runExclusive("agent resume") { [freezer] in
            // Only what the journal still holds: anything else was resumed
            // by another undo, and is not ours to signal twice.
            let journaled = Set(manager.state.frozenProcesses)
            let processes = entries.flatMap(\.processes).filter(journaled.contains)
            guard !processes.isEmpty else { return }
            let report = freezer.resume(processes)
            let keep = Set(report.failed + report.unverifiable + report.unobserved)
            failed = keep.count
            let done = Set(processes.map(\.pid)).subtracting(keep)
            do {
                try manager.journal { $0.frozenProcesses.removeAll { done.contains($0.pid) } }
            } catch {
                // Resumed but still journaled: the next undo finds them
                // running and clears them as gone.
                Log.error("\(what): could not clear \(done.count) resumed pid(s) from the journal: \(error.localizedDescription); the next undo clears them")
            }
            Log.info("\(what): resumed \(report.resumed.count) pid(s); \(report.gone.count) gone, \(keep.count) kept in the journal")
        }
        return ran ? failed : nil
    }

    private func resumeAll(_ manager: SessionManager, because why: String) async {
        let entries = paused
        // A refused transaction (lock busy, a power command running)
        // leaves the list as it is; the next evaluation tries again.
        guard let failed = await resume(entries, manager: manager, what: "priority pause") else { return }
        let names = entries.map(\.name)
        paused = []
        lastStep = nil
        let trouble = failed > 0 ? " \(failed) process(es) could not be resumed and stay journaled; the next lid open or session end retries them." : ""
        notifier.post(title: "Agents resumed", body: "Resumed \(names.joined(separator: ", ")): \(why).\(trouble)")
    }
}
