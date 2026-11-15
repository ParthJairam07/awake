import AwakeLeaseKit
import Foundation

/// What the command and the MCP server both do to the leases directory.
/// Each call is one read or one atomic write; nothing is kept in memory
/// between them.
struct LeaseService: Sendable {
    let env: CLIEnvironment

    enum Failure: Error, LocalizedError, Equatable {
        case badDuration(String)
        case tooShort
        case badGrace(String)
        case noSuchLease(String)
        case ambiguous(String, Int)
        case expired(String)
        case noSuchProcess(Int32)
        case unreadableProcess(Int32)
        case noSuchPane(String)
        case tmux(String)
        case emptyOwner
        case write(String)

        var errorDescription: String? {
            switch self {
            case let .badDuration(text): "\"\(text)\" is not a duration; use a number and a unit, such as 90m, 2h or 1h30m"
            case .tooShort: "a lease lasts at least 1m"
            case let .badGrace(text): "\"\(text)\" is not a grace period; use a number and a unit, such as 30s or 10m (at most 24h)"
            case let .noSuchLease(id): "no lease \(id)"
            case let .ambiguous(prefix, count): "\(count) leases start with \(prefix); give more of the id"
            case let .expired(id): "lease \(id) has expired; ask for a new one"
            case let .noSuchProcess(pid): "no process with pid \(pid)"
            case let .unreadableProcess(pid): "process \(pid) could not be read, so it could not be told from a later process with the same pid"
            case let .noSuchPane(target): "tmux has no pane \(target)"
            case let .tmux(why): "tmux: \(why)"
            case .emptyOwner: "the owner is empty"
            case let .write(why): why
            }
        }
    }

    /// The valid leases on disk now, oldest first. Reading never deletes:
    /// tidying the directory is the app's job.
    func current() -> [Lease] {
        let now = env.now()
        return env.store.scan().leases.filter { LeaseRules.problem(with: $0, now: now) == nil }
    }

    func statuses() -> [LeaseStatus] {
        let now = env.now()
        let cap = env.home.settings().capSeconds
        return current()
            .map { LeaseStatus(lease: $0, now: now, capSeconds: cap) }
            .filter { $0.remainingSeconds > 0 }
    }

    static func duration(_ text: String) throws -> TimeInterval {
        guard let seconds = LeaseDuration.seconds(from: text) else { throw Failure.badDuration(text) }
        guard seconds >= LeaseRules.minimumDuration else { throw Failure.tooShort }
        return min(seconds, LeaseRules.maximumDuration)
    }

    static func grace(_ text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "0" { return 0 }
        guard let seconds = LeaseDuration.seconds(from: trimmed), seconds <= LeaseRules.maximumGrace else { throw Failure.badGrace(text) }
        return Int(seconds)
    }

    /// Writes a new lease. `duration` nil means the owner's cap.
    func grant(duration: TimeInterval?, reason: String, owner: String, until: LeaseUntil? = nil, graceSeconds: Int = 0, source: LeaseSource) throws -> Lease {
        let cleanOwner = LeaseRules.cleanOwner(owner)
        guard !cleanOwner.isEmpty else { throw Failure.emptyOwner }
        let now = LeaseJSON.wholeSeconds(env.now())
        let length = duration ?? env.home.settings().capSeconds
        let lease = Lease(
            owner: cleanOwner,
            reason: LeaseRules.cleanReason(reason),
            createdAt: now,
            expiresAt: now.addingTimeInterval(length.rounded(.up)),
            until: until,
            graceSeconds: max(graceSeconds, 0),
            source: source
        )
        try write(lease)
        return lease
    }

    private func write(_ lease: Lease) throws {
        do {
            try env.store.write(lease)
        } catch {
            throw Failure.write(error.localizedDescription)
        }
    }

    /// The lease `text` names: a whole id, or the start of exactly one.
    func find(_ text: String) throws -> Lease {
        let wanted = text.lowercased()
        let leases = current()
        if let exact = leases.first(where: { Lease.idText($0.id) == wanted }) { return exact }
        guard wanted.count >= 4 else { throw Failure.noSuchLease(text) }
        let matches = leases.filter { Lease.idText($0.id).hasPrefix(wanted) }
        switch matches.count {
        case 0: throw Failure.noSuchLease(text)
        case 1: return matches[0]
        default: throw Failure.ambiguous(text, matches.count)
        }
    }

    @discardableResult
    func release(_ lease: Lease) throws -> Bool {
        do {
            return try env.store.remove(id: lease.id)
        } catch {
            throw Failure.write(error.localizedDescription)
        }
    }

    func releaseAll(owner: String? = nil) throws -> [Lease] {
        let wanted = owner.map(LeaseRules.cleanOwner)
        var released: [Lease] = []
        for lease in current() where wanted == nil || LeaseRules.cleanOwner(lease.owner) == wanted {
            if try release(lease) { released.append(lease) }
        }
        return released
    }

    /// Moves the lease's expiry `seconds` later, never past 30 days from
    /// when it was made.
    func extend(_ lease: Lease, by seconds: TimeInterval) throws -> Lease {
        guard lease.expiresAt > env.now() else { throw Failure.expired(Lease.idText(lease.id)) }
        var extended = lease
        let ceiling = lease.createdAt.addingTimeInterval(LeaseRules.maximumDuration)
        extended.expiresAt = min(lease.expiresAt.addingTimeInterval(seconds.rounded(.up)), ceiling)
        try write(extended)
        return extended
    }

    // MARK: until

    func untilPid(_ pid: Int32) throws -> LeaseUntil {
        switch env.processLookup(pid) {
        case let .present(process):
            guard !process.bootSession.isEmpty else { throw Failure.unreadableProcess(pid) }
            return .pid(process)
        case .absent: throw Failure.noSuchProcess(pid)
        case .unreadable: throw Failure.unreadableProcess(pid)
        }
    }

    /// The pane `target` names now, and whether something other than a
    /// shell is running in it.
    func untilTmux(_ target: String) throws -> (until: LeaseUntil, reading: LeaseTmux.Reading) {
        switch LeaseTmux.read(target: target, runner: env.tmux) {
        case .gone: throw Failure.noSuchPane(target)
        case let .unknown(why): throw Failure.tmux(why)
        case let .pane(reading):
            guard case let .present(process) = env.processLookup(reading.pid), !process.bootSession.isEmpty else {
                throw Failure.unreadableProcess(reading.pid)
            }
            let pane = LeasePane(target: target, paneId: reading.paneId, socketPath: reading.socketPath, process: process)
            return (.tmux(pane), reading)
        }
    }

    // MARK: status.json

    /// The app's status.json as it is on disk, or nil when there is none
    /// or it is not JSON.
    func statusData() -> Data? {
        guard let data = try? Data(contentsOf: env.home.statusFile),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
        else { return nil }
        return data
    }

    /// What stands between a lease and the Mac staying awake, for the
    /// caller to pass on: the app is not running, leases are turned off,
    /// or they may not start a session and none is running.
    func cautions(plural: Bool = false) -> [String] {
        var notes: [String] = []
        let settings = env.home.settings()
        if !env.appRunning() {
            notes.append("Awake.app is not running; \(plural ? "leases" : "lease") will take effect when it starts")
        }
        if !settings.enabled {
            notes.append("leases are turned off in Awake's Settings; \(plural ? "these leases hold" : "this lease holds") nothing until they are turned on")
        } else if !settings.mayStartSession, !sessionActive() {
            notes.append("leases may not start a session (Awake's Settings) and none is running; \(plural ? "these leases hold" : "this lease holds") nothing until you start one")
        }
        return notes
    }

    /// Whether status.json, as last written, shows a session that has not
    /// run out.
    func sessionActive() -> Bool {
        guard let data = statusData(), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["active"] as? Bool == true,
              let ends = (object["endsAt"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) })
        else { return false }
        return ends > env.now()
    }
}
