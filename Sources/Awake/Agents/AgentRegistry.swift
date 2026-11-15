import Foundation

/// One agent found in the process table or a marked tmux pane, before any
/// per-pid reads.
struct DiscoveredAgent: Sendable, Equatable {
    let id: String
    let kind: AgentKind
    let name: String
    let rootPid: Int32
    let identity: ProcessIdentity
    /// Root first, then descendants; another agent's tree is not included.
    let pids: [Int32]
    let parents: [Int32: Int32]
    let identities: [Int32: ProcessIdentity]
    let pane: TmuxPane?
    /// A `sudo` runs somewhere in the tree.
    let hasSudo: Bool
}

/// One tracked agent.
struct AgentRecord: Sendable, Equatable {
    let id: String
    let kind: AgentKind
    var name: String
    /// nil for an agent known only from hooks.
    var rootPid: Int32?
    var identity: ProcessIdentity?
    var pids: [Int32] = []
    var parents: [Int32: Int32] = [:]
    var identities: [Int32: ProcessIdentity] = [:]
    var hasSudo = false
    var tmuxTarget: String?
    var tmuxPaneId: String?
    var cwd: String?
    /// The git work tree `cwd` is in.
    var repo: String?
    var cpuPercent: Double?
    var residentBytes: UInt64 = 0
    let firstSeen: Date
    var lastSeen: Date
    /// Polls that found it. Alerts wait for the second, so a `claude
    /// --version` that comes and goes is never announced.
    var sightings = 0
    var machine: AgentStateMachine
    /// From hooks: the agent's own session id and transcript.
    var sessionId: String?
    var transcriptPath: String?

    var state: AgentState { machine.state }
    var isConfirmed: Bool { sightings >= 2 || rootPid == nil }
    var repoName: String? { repo.map(GitRepoLocator.name) }

    /// "claude", or "claude (repo)" where a repo is known.
    var label: String {
        guard let repoName else { return name }
        return "\(name) (\(repoName))"
    }
}

/// A state change worth telling someone about.
struct AgentEvent: Sendable, Equatable {
    let agent: AgentRecord
    let transition: AgentTransition
}

/// Finds agents and keeps one record per agent across polls. Pure: the
/// tracker hands it what the probes read.
struct AgentRegistry: Sendable {
    /// How long an exited agent stays listed.
    static let exitedRetention: TimeInterval = 600
    /// How long a hook-only agent at rest stays listed without a new event.
    static let hookOnlyRetention: TimeInterval = 3600

    private(set) var records: [String: AgentRecord] = [:]
    private var previousCPU: [String: [Int32: UInt64]] = [:]
    private var previousSampleAt: [String: Date] = [:]

    /// Listed order: oldest first, so a menu line does not jump around.
    var agents: [AgentRecord] {
        records.values.sorted { ($0.firstSeen, $0.id) < ($1.firstSeen, $1.id) }
    }

    // MARK: Discovery

    static func identifier(kind: AgentKind, pid: Int32, identity: ProcessIdentity) -> String {
        "\(kind.rawValue)-\(pid)-\(identity.startedAt).\(identity.startedAtMicros)"
    }

    static func discover(processes: [AgentProcess], apps: [RunningApp], panes: [TmuxPane], selfPid: Int32 = getpid()) -> [DiscoveredAgent] {
        var byPid: [Int32: AgentProcess] = [:]
        for p in processes where byPid[p.pid] == nil { byPid[p.pid] = p }
        var children: [Int32: [Int32]] = [:]
        for p in processes where p.pid != p.entry.ppid { children[p.entry.ppid, default: []].append(p.pid) }

        var kinds: [Int32: AgentKind] = [:]
        for p in processes where p.pid != selfPid {
            if let kind = AgentCatalog.kind(executable: p.executable, arguments: p.arguments) { kinds[p.pid] = kind }
        }
        for app in apps where app.pid != selfPid && byPid[app.pid] != nil {
            if let kind = AgentCatalog.kind(bundleId: app.bundleId) { kinds[app.pid] = kind }
        }

        func ancestors(of pid: Int32) -> [Int32] {
            var out: [Int32] = []
            var seen: Set<Int32> = [pid]
            var current = pid
            while let parent = byPid[current]?.entry.ppid, parent > 1, !seen.contains(parent) {
                out.append(parent)
                seen.insert(parent)
                current = parent
            }
            return out
        }

        // A matched process under a matched ancestor of the same kind is
        // part of that agent (`ollama runner` under `ollama serve`).
        var roots: [Int32: AgentKind] = [:]
        for (pid, kind) in kinds {
            let nearest = ancestors(of: pid).first { kinds[$0] != nil }
            if let nearest, kinds[nearest] == kind { continue }
            roots[pid] = kind
        }

        func tree(of root: Int32, stoppingAt others: Set<Int32>) -> [Int32] {
            var result = [root]
            var seen: Set<Int32> = [root]
            var queue = [root]
            while !queue.isEmpty {
                let parent = queue.removeFirst()
                for child in (children[parent] ?? []).sorted() where !seen.contains(child) && !others.contains(child) {
                    seen.insert(child)
                    result.append(child)
                    queue.append(child)
                }
            }
            return result
        }

        let panesByPid = Dictionary(panes.filter { !$0.dead }.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        func pane(for pid: Int32) -> TmuxPane? {
            if let pane = panesByPid[pid] { return pane }
            return ancestors(of: pid).lazy.compactMap { panesByPid[$0] }.first
        }

        func make(root: Int32, kind: AgentKind, name: String, pane: TmuxPane?, others: Set<Int32>) -> DiscoveredAgent? {
            guard let process = byPid[root] else { return nil }
            let pids = tree(of: root, stoppingAt: others)
            var parents: [Int32: Int32] = [:]
            var identities: [Int32: ProcessIdentity] = [:]
            var sudo = false
            for pid in pids {
                guard let p = byPid[pid] else { continue }
                parents[pid] = p.entry.ppid
                identities[pid] = p.entry.identity
                if AgentCatalog.baseName(p.executable) == "sudo" { sudo = true }
            }
            return DiscoveredAgent(
                id: identifier(kind: kind, pid: root, identity: process.entry.identity),
                kind: kind, name: name, rootPid: root, identity: process.entry.identity,
                pids: pids, parents: parents, identities: identities, pane: pane, hasSudo: sudo
            )
        }

        var out: [DiscoveredAgent] = []
        let rootPids = Set(roots.keys)
        var panesWithAgents: Set<String> = []
        for (pid, kind) in roots.sorted(by: { $0.key < $1.key }) {
            let pane = pane(for: pid)
            if let pane { panesWithAgents.insert(pane.id) }
            if let agent = make(root: pid, kind: kind, name: kind.displayName, pane: pane, others: rootPids.subtracting([pid])) {
                out.append(agent)
            }
        }
        // A marked pane that runs nothing recognised is an agent itself.
        for pane in panes.sorted(by: { $0.id < $1.id }) where pane.marked && !pane.dead && !panesWithAgents.contains(pane.id) {
            guard pane.pid != selfPid, !rootPids.contains(pane.pid) else { continue }
            if let agent = make(root: pane.pid, kind: .tmuxPane, name: TmuxPaneList.name(of: pane), pane: pane, others: rootPids) {
                out.append(agent)
            }
        }
        return out
    }

    // MARK: Polls

    /// What the tracker read for one poll.
    struct Readings: Sendable {
        var usage: [Int32: AgentProcessUsage] = [:]
        /// Pane text by pane id.
        var paneText: [String: String] = [:]
        /// Log modification time by agent id.
        var logModified: [String: Date] = [:]

        init(usage: [Int32: AgentProcessUsage] = [:], paneText: [String: String] = [:], logModified: [String: Date] = [:]) {
            self.usage = usage
            self.paneText = paneText
            self.logModified = logModified
        }
    }

    /// Fold one poll in. Returns the transitions of confirmed agents.
    mutating func apply(
        _ discovered: [DiscoveredAgent],
        readings: Readings,
        now: Date,
        stallAfter: TimeInterval,
        repoRoot: (String) -> String? = { GitRepoLocator.root(of: $0) }
    ) -> [AgentEvent] {
        var events: [AgentEvent] = []
        var seen: Set<String> = []
        for found in discovered {
            seen.insert(found.id)
            var record = records[found.id] ?? AgentRecord(
                id: found.id, kind: found.kind, name: found.name, rootPid: found.rootPid, identity: found.identity,
                firstSeen: now, lastSeen: now, machine: AgentStateMachine(firstSeen: now)
            )
            record.name = found.name
            record.pids = found.pids
            record.parents = found.parents
            record.identities = found.identities
            record.hasSudo = found.hasSudo
            record.tmuxTarget = found.pane?.target
            record.tmuxPaneId = found.pane?.id
            record.lastSeen = now
            record.sightings += 1

            // CPU over the interval, summed over the pids seen at both ends.
            var cpuNow: [Int32: UInt64] = [:]
            var resident: UInt64 = 0
            for pid in found.pids {
                guard let usage = readings.usage[pid] else { continue }
                cpuNow[pid] = usage.cpuNanos
                resident += usage.residentBytes
            }
            record.residentBytes = resident
            var cpu: Double?
            if let before = previousCPU[found.id], let at = previousSampleAt[found.id] {
                let interval = now.timeIntervalSince(at)
                if interval > 0 {
                    var delta: UInt64 = 0
                    for (pid, value) in cpuNow {
                        guard let old = before[pid], value >= old else { continue }
                        delta += value - old
                    }
                    cpu = Double(delta) / (interval * 1_000_000_000) * 100
                }
            }
            previousCPU[found.id] = cpuNow
            previousSampleAt[found.id] = now
            record.cpuPercent = cpu

            let cwd = readings.usage[found.rootPid]?.cwd ?? found.pane.map(\.currentPath).flatMap { $0.isEmpty ? nil : $0 }
            if let cwd, cwd != record.cwd {
                record.cwd = cwd
                record.repo = repoRoot(cwd)
            }

            let sample = AgentSample(
                at: now,
                cpuPercent: cpu,
                paneText: found.pane.flatMap { readings.paneText[$0.id] },
                logModifiedAt: readings.logModified[found.id]
            )
            let transition = record.machine.ingest(sample, thresholds: Self.thresholds(for: found.kind, stallAfter: stallAfter))
            records[found.id] = record
            if let transition, record.isConfirmed { events.append(AgentEvent(agent: record, transition: transition)) }
        }

        for (id, var record) in records where !seen.contains(id) {
            if record.rootPid == nil {
                // Hook-only: no process to lose. It is sampled so silence
                // can make it stalled, and dropped once long at rest.
                if record.state.isSettled, now.timeIntervalSince(record.lastSeen) >= Self.hookOnlyRetention {
                    records[id] = nil
                    continue
                }
                let sample = AgentSample(at: now, logModifiedAt: readings.logModified[id])
                let transition = record.machine.ingest(sample, thresholds: Self.thresholds(for: record.kind, stallAfter: stallAfter))
                records[id] = record
                if let transition { events.append(AgentEvent(agent: record, transition: transition)) }
                continue
            }
            if record.state == .exited {
                if now.timeIntervalSince(record.machine.since) >= Self.exitedRetention { forget(id) }
                continue
            }
            guard record.isConfirmed else {
                forget(id)
                continue
            }
            record.cpuPercent = nil
            let transition = record.machine.ingest(AgentSample(at: now, present: false))
            records[id] = record
            previousCPU[id] = nil
            previousSampleAt[id] = nil
            if let transition { events.append(AgentEvent(agent: record, transition: transition)) }
        }
        return events
    }

    private mutating func forget(_ id: String) {
        records[id] = nil
        previousCPU[id] = nil
        previousSampleAt[id] = nil
    }

    static func thresholds(for kind: AgentKind, stallAfter: TimeInterval) -> AgentStateMachine.Thresholds {
        AgentStateMachine.Thresholds(stallAfter: stallAfter, conversational: kind.isConversational)
    }

    // MARK: Hooks

    /// Match a hook event to an agent (pid, then the agent's own session
    /// id, then working directory) and apply it; an event nothing matches
    /// creates a hook-only agent. `parentOf` answers for pids newer than
    /// the last poll, such as the shell a hook ran in.
    mutating func apply(
        hook event: AgentHookEvent,
        now: Date,
        parentOf: (Int32) -> Int32? = { _ in nil },
        repoRoot: (String) -> String? = { GitRepoLocator.root(of: $0) }
    ) -> AgentEvent? {
        let id = match(event, parentOf: parentOf) ?? createHookOnly(event, now: now, repoRoot: repoRoot)
        guard var record = records[id] else { return nil }
        if let session = event.sessionId { record.sessionId = session }
        if let transcript = event.transcriptPath { record.transcriptPath = transcript }
        if record.rootPid == nil { record.lastSeen = now }
        if record.cwd == nil, let cwd = event.cwd {
            record.cwd = cwd
            record.repo = repoRoot(cwd)
        }
        let transition = record.machine.ingest(hook: event.action, at: now, hasProcess: record.rootPid != nil)
        records[id] = record
        return transition.map { AgentEvent(agent: record, transition: $0) }
    }

    private func match(_ event: AgentHookEvent, parentOf: (Int32) -> Int32?) -> String? {
        let live = records.values.filter { $0.state != .exited }
        if var pid = event.pid, pid > 1 {
            var owners: [Int32: String] = [:]
            for record in live { for p in record.pids { owners[p] = record.id } }
            for _ in 0..<32 {
                if let id = owners[pid] { return id }
                guard let parent = parentOf(pid), parent > 1, parent != pid else { break }
                pid = parent
            }
        }
        if let session = event.sessionId, let hit = live.first(where: { $0.sessionId == session }) {
            return hit.id
        }
        if let cwd = event.cwd {
            let wanted = AgentKind(rawValue: event.kind)
            let hits = live.filter { $0.cwd == cwd && $0.rootPid != nil && (wanted == nil || $0.kind == wanted) && ($0.sessionId == nil || event.sessionId == nil) }
            if let hit = hits.max(by: { $0.firstSeen < $1.firstSeen }) { return hit.id }
        }
        return nil
    }

    private mutating func createHookOnly(_ event: AgentHookEvent, now: Date, repoRoot: (String) -> String?) -> String {
        let key = event.sessionId ?? event.cwd ?? event.pid.map { "pid\($0)" } ?? "unknown"
        let id = "hook-\(event.kind)-\(key)"
        if let existing = records[id], existing.state != .exited { return id }
        var record = AgentRecord(
            id: id, kind: .hookOnly, name: event.kind, rootPid: nil, identity: nil,
            firstSeen: now, lastSeen: now, machine: AgentStateMachine(firstSeen: now)
        )
        record.cwd = event.cwd
        record.repo = event.cwd.flatMap(repoRoot)
        record.sessionId = event.sessionId
        records[id] = record
        return id
    }

    /// Drop everything: the session ended.
    mutating func reset() {
        records = [:]
        previousCPU = [:]
        previousSampleAt = [:]
    }
}
