import Foundation

/// What the lease manager remembers in lease-state.json, so a relaunch in
/// the middle of a session knows what the leases did to it. Written before
/// the session is touched where the order matters (`startIntentAt`).
struct LeaseState: Codable, Equatable, Sendable {
    /// The session the rest describes, by its start. Another start time
    /// means another session: one the user started since.
    var sessionStartedAt: Date?
    /// The session exists because a lease asked for it, and nobody has
    /// added time to it by hand since.
    var startedByLeases = false
    /// Where the session ends when no lease holds it longer: the end the
    /// user chose, or the first horizon of a session leases started.
    var plannedEnd: Date?
    /// When the first lease of this session was honoured. The cap counts
    /// from here.
    var leaseEpoch: Date?
    /// The end the manager last gave the session. A session whose end is
    /// somewhere else was changed by the user.
    var appliedEnd: Date?
    /// When the manager found the last lease gone, while leases were all
    /// that held the session.
    var lastReleaseAt: Date?
    /// Ids of the leases this session has honoured.
    var sessionLeaseIDs: [String] = []
    var maxHeld = 0
    /// Ids "Lease granted" was posted for, so a relaunch does not post it
    /// again.
    var announced: [String] = []
    /// Written just before a lease starts a session and cleared once the
    /// start has been recorded. A relaunch that finds it beside a session
    /// started at that moment knows leases started it.
    var startIntentAt: Date?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionStartedAt = try c.decodeIfPresent(Date.self, forKey: .sessionStartedAt)
        startedByLeases = try c.decodeIfPresent(Bool.self, forKey: .startedByLeases) ?? false
        plannedEnd = try c.decodeIfPresent(Date.self, forKey: .plannedEnd)
        leaseEpoch = try c.decodeIfPresent(Date.self, forKey: .leaseEpoch)
        appliedEnd = try c.decodeIfPresent(Date.self, forKey: .appliedEnd)
        lastReleaseAt = try c.decodeIfPresent(Date.self, forKey: .lastReleaseAt)
        sessionLeaseIDs = try c.decodeIfPresent([String].self, forKey: .sessionLeaseIDs) ?? []
        maxHeld = try c.decodeIfPresent(Int.self, forKey: .maxHeld) ?? 0
        announced = try c.decodeIfPresent([String].self, forKey: .announced) ?? []
        startIntentAt = try c.decodeIfPresent(Date.self, forKey: .startIntentAt)
    }

    /// Forget the session; what was announced stays.
    mutating func clearSession() {
        sessionStartedAt = nil
        startedByLeases = false
        plannedEnd = nil
        leaseEpoch = nil
        appliedEnd = nil
        lastReleaseAt = nil
        sessionLeaseIDs = []
        maxHeld = 0
        startIntentAt = nil
    }

    /// The files hold whole seconds and the session in memory does not, so
    /// two readings of one moment can differ by a fraction.
    static func same(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a.timeIntervalSince(b)) < 1
        default: false
        }
    }
}
