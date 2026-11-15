import Foundation

/// Phase 1: what one session did, journaled to report.json as it happens
/// so the summary survives a crash. Posted as one notification when the
/// session ends, or at the next launch when Awake was not running to see
/// the end.
struct SessionReport: Codable, Equatable, Sendable {
    var startedAt: Date
    var plannedEnd: Date
    var batteryStart: Int?
    var lidCloses = 0
    var lowPowerEvents = 0
    var thermalEvents = 0
    var chargerWeakEvents = 0
    var outages = 0
    var outageSeconds: TimeInterval = 0
    var endedAt: Date?
    var endReason: String?
    var batteryEnd: Int?
    var restored: Bool?
    var summaryPosted = false
    // Phase 2. Optional so a report.json written before phase 2 decodes.
    /// Agents tracked during the session, by agent id.
    var agents: [String: AgentReportEntry]?
    /// Commits not on the upstream, by repo path, at the last check.
    var unpushed: [String: Int]?
    /// Repos the pre-end wip save pushed, and the ones it could not.
    var wipPushed: [String]?
    var wipFailed: [String]?
    /// Phase 4: leases held at some point in the session, and the most
    /// held at once. Optional, so a report.json written by a build without
    /// them still decodes.
    var leasesGranted: Int?
    var maxLeasesHeld: Int?

    init(startedAt: Date, plannedEnd: Date, batteryStart: Int?) {
        self.startedAt = startedAt
        self.plannedEnd = plannedEnd
        self.batteryStart = batteryStart
    }

    static let title = "Session summary"

    /// "Ran 7h 42m (timer). Battery 100% → 64%. Lid closed once. Low Power
    /// Mode on twice (1 for heat). 1 outage, 2m 10s in all. Everything
    /// restored."
    func summary(now: Date, endReasonText: (String) -> String) -> String {
        let end = endedAt ?? now
        var parts: [String] = []
        let ran = FailoverMachine.humanGap(max(0, end.timeIntervalSince(startedAt)))
        let reason = endReason.map { " (\(endReasonText($0)))" } ?? " (Awake was not running when it ended)"
        parts.append("Ran \(ran)\(reason).")
        switch (batteryStart, batteryEnd) {
        case let (s?, e?): parts.append("Battery \(s)% → \(e)%.")
        case let (s?, nil): parts.append("Battery \(s)% at start.")
        default: break
        }
        if lidCloses > 0 { parts.append("Lid closed \(Self.times(lidCloses)).") }
        if lowPowerEvents > 0 {
            let heat = thermalEvents > 0 ? " (\(thermalEvents) for heat)" : ""
            parts.append("Low Power Mode on \(Self.times(lowPowerEvents))\(heat).")
        }
        if chargerWeakEvents > 0 { parts.append("Charger too weak \(Self.times(chargerWeakEvents)).") }
        if outages > 0 {
            parts.append("\(outages) outage\(outages == 1 ? "" : "s"), \(FailoverMachine.humanGap(outageSeconds)) in all.")
        }
        if let granted = leasesGranted, granted > 0 {
            let most = maxLeasesHeld.map { $0 > 1 ? ", \($0) at once" : "" } ?? ""
            parts.append("\(granted) lease\(granted == 1 ? "" : "s") granted\(most).")
        }
        switch restored {
        case true?: parts.append("Everything restored.")
        case false?: parts.append("Some changes were NOT restored; see the Mac.")
        case nil: break
        }
        parts.append(contentsOf: agentParts())
        return parts.joined(separator: " ")
    }

    static func times(_ n: Int) -> String {
        switch n {
        case 1: "once"
        case 2: "twice"
        default: "\(n) times"
        }
    }
}

/// What the summary keeps about one agent.
struct AgentReportEntry: Codable, Equatable, Sendable {
    var name: String
    var repo: String?
    var lastState: AgentState
    /// It stalled, or waited for input, at some point.
    var stalled = false
    var waited = false

    init(name: String, repo: String?, lastState: AgentState, stalled: Bool = false, waited: Bool = false) {
        self.name = name
        self.repo = repo
        self.lastState = lastState
        self.stalled = stalled
        self.waited = waited
    }
}

extension SessionReport {
    /// "Agents: 3 ran, 2 finished, 1 stalled, 1 waiting for input at the
    /// end. Unpushed commits: api (3). wip pushed: 2 repos, failed: 1."
    func agentParts() -> [String] {
        var parts: [String] = []
        if let agents, !agents.isEmpty {
            let all = Array(agents.values)
            var counts = ["\(all.count) ran"]
            let finished = all.filter { $0.lastState.isSettled }.count
            if finished > 0 { counts.append("\(finished) finished") }
            let stalled = all.filter(\.stalled).count
            if stalled > 0 { counts.append("\(stalled) stalled") }
            let waiting = all.filter { $0.lastState == .waitingForInput }.count
            if waiting > 0 { counts.append("\(waiting) waiting for input at the end") }
            parts.append("Agents: \(counts.joined(separator: ", ")).")
        }
        let behind = (unpushed ?? [:]).filter { $0.value > 0 }.sorted { $0.key < $1.key }
        if !behind.isEmpty {
            let list = behind.map { "\(GitRepoLocator.name(of: $0.key)) (\($0.value))" }.joined(separator: ", ")
            parts.append("Unpushed commits: \(list).")
        }
        let pushed = wipPushed?.count ?? 0, failed = wipFailed?.count ?? 0
        if pushed > 0 || failed > 0 {
            var line = "wip pushed: \(pushed) repo\(pushed == 1 ? "" : "s")"
            if failed > 0 { line += ", failed: \(failed)" }
            parts.append(line + ".")
        }
        return parts
    }
}
