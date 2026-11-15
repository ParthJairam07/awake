import Foundation

/// The rules a lease has to pass, and the text it is shown with. Pure, so
/// the app, the command and the MCP server all apply the same ones.
public enum LeaseRules {
    /// Longest owner and reason kept; longer text is cut, not refused.
    public static let maxOwnerLength = 64
    public static let maxReasonLength = 200
    /// Shortest and longest a lease can be asked for. The app applies the
    /// owner's own cap (`Config.leaseCapHours`) on top of the longest.
    public static let minimumDuration: TimeInterval = 60
    public static let maximumDuration: TimeInterval = 30 * 24 * 3600
    /// Longest idle grace.
    public static let maximumGrace: TimeInterval = 24 * 3600
    /// A lease dated further ahead than this was not made by this Mac's
    /// clock; it is not a lease.
    public static let clockSkewAllowance: TimeInterval = 300
    /// Leases held at once. More files than this are left on disk and
    /// ignored until others go, so a runaway loop cannot fill the menu.
    public static let maximumHeld = 64
    /// The cap used when config.json cannot be read.
    public static let defaultCapHours = 8

    public enum Problem: Equatable, Sendable {
        case expired
        case unknownVersion(Int)
        case datesOutOfOrder
        case createdInTheFuture
        case emptyOwner

        public var text: String {
            switch self {
            case .expired: "expired"
            case let .unknownVersion(v): "written by a newer Awake (version \(v))"
            case .datesOutOfOrder: "expiresAt is not after createdAt"
            case .createdInTheFuture: "createdAt is in the future"
            case .emptyOwner: "no owner"
            }
        }
    }

    /// Why `lease` does not count at `now`, or nil when it does.
    public static func problem(with lease: Lease, now: Date) -> Problem? {
        if lease.version > Lease.currentVersion || lease.version < 1 { return .unknownVersion(lease.version) }
        if clean(lease.owner, limit: maxOwnerLength).isEmpty { return .emptyOwner }
        if lease.expiresAt <= lease.createdAt { return .datesOutOfOrder }
        if lease.createdAt.timeIntervalSince(now) > clockSkewAllowance { return .createdInTheFuture }
        if effectiveExpiry(of: lease, capSeconds: nil) <= now { return .expired }
        return nil
    }

    /// When the lease stops counting: its own expiry, or `capSeconds` after
    /// it was made, whichever is first.
    public static func effectiveExpiry(of lease: Lease, capSeconds: TimeInterval?) -> Date {
        guard let capSeconds else { return lease.expiresAt }
        return min(lease.expiresAt, lease.createdAt.addingTimeInterval(max(capSeconds, 0)))
    }

    /// One line of printable text: control characters and line breaks
    /// become spaces, runs of spaces collapse, and the result is cut to
    /// `limit` characters. Lease text reaches notifications, the menu and a
    /// terminal table, none of which should be handed a newline or an
    /// escape sequence written by another program.
    public static func clean(_ text: String, limit: Int) -> String {
        var out = ""
        var lastWasSpace = true
        for scalar in text.unicodeScalars {
            let isSpace = scalar.properties.isWhitespace || scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator
            if isSpace {
                if !lastWasSpace { out.unicodeScalars.append(" ") }
                lastWasSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        if out.count > limit { out = String(out.prefix(max(limit - 1, 0))) + "\u{2026}" }
        return out
    }

    public static func cleanOwner(_ text: String) -> String { clean(text, limit: maxOwnerLength) }
    public static func cleanReason(_ text: String) -> String { clean(text, limit: maxReasonLength) }
}

/// Durations as people type them: "2h", "90m", "1h30m", "45s", "1d".
public enum LeaseDuration {
    /// Seconds, or nil when the text is not a duration. A unit is required:
    /// a bare "90" could mean seconds or minutes, and a lease that is sixty
    /// times longer than meant is the wrong way to find out.
    public static func seconds(from text: String) -> TimeInterval? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        var total = 0
        var number = ""
        var sawUnit = false
        for ch in trimmed {
            if ch.isASCII, ch.isNumber {
                number.append(ch)
            } else if ch == " " {
                continue
            } else {
                guard let n = Int(number) else { return nil }
                let multiplier: Int
                switch ch {
                case "d": multiplier = 86_400
                case "h": multiplier = 3_600
                case "m": multiplier = 60
                case "s": multiplier = 1
                default: return nil
                }
                let (seconds, mulOverflow) = n.multipliedReportingOverflow(by: multiplier)
                guard !mulOverflow else { return nil }
                let (sum, addOverflow) = total.addingReportingOverflow(seconds)
                guard !addOverflow else { return nil }
                total = sum
                number = ""
                sawUnit = true
            }
        }
        guard number.isEmpty, sawUnit, total > 0 else { return nil }
        return TimeInterval(total)
    }

    /// "1h 12m", "45m", "30s", "2d 3h". Seconds show only under a minute.
    public static func format(_ interval: TimeInterval) -> String {
        let total = Int(max(interval, 0))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }
}
