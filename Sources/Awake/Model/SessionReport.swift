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
        switch restored {
        case true?: parts.append("Everything restored.")
        case false?: parts.append("Some changes were NOT restored; see the Mac.")
        case nil: break
        }
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
