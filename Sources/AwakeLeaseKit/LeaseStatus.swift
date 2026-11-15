import Foundation

/// One lease as it is reported: in status.json (`StatusSnapshot.leases`),
/// by `awake leases --json` and by the MCP tools.
public struct LeaseStatus: Codable, Equatable, Sendable {
    public var id: String
    public var owner: String
    public var reason: String
    public var source: String
    public var createdAt: Date
    /// When the lease stops counting, the owner's cap applied.
    public var expiresAt: Date
    public var remainingSeconds: Int
    /// "pid 4242", "tmux work:1.0", "command make"; nil without a condition.
    public var until: String?
    public var graceSeconds: Int

    public init(lease: Lease, now: Date, capSeconds: TimeInterval? = nil) {
        let expiry = LeaseRules.effectiveExpiry(of: lease, capSeconds: capSeconds)
        id = Lease.idText(lease.id)
        owner = LeaseRules.cleanOwner(lease.owner)
        reason = LeaseRules.cleanReason(lease.reason)
        source = lease.source.rawValue
        createdAt = lease.createdAt
        expiresAt = expiry
        remainingSeconds = max(0, Int(expiry.timeIntervalSince(now)))
        until = lease.until?.summary
        graceSeconds = lease.graceSeconds
    }

    /// "claude 'refactor billing' 1h 12m left", the reason left out when
    /// there is none.
    public var line: String {
        let left = "\(LeaseDuration.format(TimeInterval(remainingSeconds))) left"
        return reason.isEmpty ? "\(owner) \(left)" : "\(owner) '\(reason)' \(left)"
    }

    /// The menu's lines: "Leases: 2 — claude 'refactor billing' 1h 12m
    /// left" and one more line per further lease, the longest-lived first.
    /// `waiting` marks leases that hold nothing because no session runs.
    public static func menuLines(_ leases: [LeaseStatus], waiting: Bool = false, limit: Int = 6) -> [String] {
        guard !leases.isEmpty else { return [] }
        let sorted = leases.sorted { ($0.expiresAt, $0.id) > ($1.expiresAt, $1.id) }
        let head = "Leases: \(sorted.count)\(waiting ? " (waiting for a session)" : "")"
        var lines = ["\(head) \u{2014} \(sorted[0].line)"]
        for lease in sorted.dropFirst().prefix(max(limit - 1, 0)) {
            lines.append("    \(lease.line)")
        }
        if sorted.count > limit { lines.append("    and \(sorted.count - limit) more") }
        return lines
    }
}
