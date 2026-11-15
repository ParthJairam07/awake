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
        lastStep = nil
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
        let tier = PausePlanner.nextTier(agents: agents(), paused: Set(paused.map(\.id)), config: config)
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
        if paused.count != before { lastStep = nil }
    }

    /// One agent, journal first. True when at least one of its processes
    /// was stopped.
    private func pause(_ agent: AgentRecord, manager: SessionManager) async -> Bool {
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
                manager.fail("priority pause: could not journal the pause of \(agent.label): \(error.localizedDescription); it was left running")
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
                manager.fail("priority pause: could not confirm the pause of \(agent.label) in the journal: \(error.localizedDescription); resumed \(undo.resumed.count) of the \(confirmed.count) pid(s) it had just stopped")
                return
            }
            stopped = confirmed
            Log.info("priority pause: stopped \(agent.label) (\(confirmed.count) pid(s), \(report.skipped.count) skipped)")
        }
        guard ran, !stopped.isEmpty else { return false }
        paused.append(Paused(id: agent.id, name: agent.label, processes: stopped))
        return true
    }

    private func resumeAll(_ manager: SessionManager, because why: String) async {
        let entries = paused
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
                Log.error("priority pause: could not clear \(done.count) resumed pid(s) from the journal: \(error.localizedDescription); the next undo clears them")
            }
            Log.info("priority pause: resumed \(report.resumed.count) pid(s); \(report.gone.count) gone, \(keep.count) kept in the journal")
        }
        // A refused transaction (lock busy, a power command running)
        // leaves the list as it is; the next evaluation tries again.
        guard ran else { return }
        let names = entries.map(\.name)
        paused = []
        lastStep = nil
        let trouble = failed > 0 ? " \(failed) process(es) could not be resumed and stay journaled; the next lid open or session end retries them." : ""
        notifier.post(title: "Agents resumed", body: "Resumed \(names.joined(separator: ", ")): \(why).\(trouble)")
    }
}
