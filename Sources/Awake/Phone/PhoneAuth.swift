import Foundation
import Observation

/// The paired phones, the pairing window and the rate limits, in one
/// place on the main actor. The keychain is read once, when the phone app
/// starts, and written whenever the list changes; a token is checked
/// against the copy in memory, so no request waits on the keychain.
@MainActor
@Observable
final class PhoneAuth {
    private(set) var devices: [PhoneDevice] = []
    /// The open pairing window, for Settings and the menu.
    private(set) var pairingWindow: PhonePairing.Window?
    /// Why the paired phones could not be read or saved, for Settings.
    private(set) var storeProblem: String?
    private(set) var loaded = false

    @ObservationIgnored private var pairing = PhonePairing()
    @ObservationIgnored private var limiter = PhoneRateLimiter()
    @ObservationIgnored private let store: any PhoneDeviceStoring
    @ObservationIgnored private let queue: KeychainQueue
    @ObservationIgnored private let random: PhoneRandom
    @ObservationIgnored private let clock: @Sendable () -> Date
    /// `lastSeenAt` is written back to the keychain at most this often.
    @ObservationIgnored private var lastSeenSavedAt: [String: Date] = [:]
    static let lastSeenSaveInterval: TimeInterval = 3600
    /// The most phones kept; pairing another forgets the one seen longest ago.
    static let maxDevices = 8
    /// Called with the id of each device that was forgotten, so its open
    /// event streams are closed.
    @ObservationIgnored var onRevoked: (@MainActor (Set<String>) -> Void)?

    init(
        store: any PhoneDeviceStoring,
        queue: KeychainQueue = .shared,
        random: @escaping PhoneRandom = PhoneSecureRandom.system,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.queue = queue
        self.random = random
        self.clock = clock
    }

    /// Reads the paired phones. An unreadable item (another build's, a
    /// locked keychain) leaves the list empty and says why: nobody is let
    /// in on the strength of a record that could not be read.
    func load() async {
        let store = self.store
        do {
            devices = try await queue.run { try store.load() }
            storeProblem = nil
        } catch {
            devices = []
            storeProblem = "The paired phones could not be read from the keychain (\(error.localizedDescription)). Pair the phone again."
            Log.error("phone app: paired devices unreadable: \(error.localizedDescription)")
        }
        loaded = true
    }

    // MARK: Pairing

    @discardableResult
    func beginPairing() -> PhonePairing.Window {
        let w = pairing.begin(now: clock(), random: random)
        pairingWindow = w
        return w
    }

    func cancelPairing() {
        pairing.cancel()
        pairingWindow = nil
    }

    /// Drops a window that has run out; Settings calls this on its timer.
    func refreshPairing() {
        pairingWindow = pairing.current(now: clock())
    }

    enum PairResult: Equatable, Sendable {
        case paired(token: String, device: PhoneDevice)
        case refused(PhonePairing.Outcome)
        /// The code was right but the keychain refused the record; the
        /// window stays closed and no token is handed out.
        case notSaved(String)
    }

    func pair(code: String, name: String) async -> PairResult {
        let outcome = pairing.redeem(code, now: clock(), random: random)
        pairingWindow = pairing.current(now: clock())
        guard outcome == .accepted else { return .refused(outcome) }
        let issued = PhoneToken.issue(name: name, now: clock(), random: random)
        var next = devices
        next.append(issued.device)
        var dropped: Set<String> = []
        while next.count > Self.maxDevices, let oldest = next.dropLast().min(by: { ($0.lastSeenAt ?? $0.createdAt) < ($1.lastSeenAt ?? $1.createdAt) }) {
            next.removeAll { $0.id == oldest.id }
            dropped.insert(oldest.id)
        }
        if let problem = await save(next) {
            return .notSaved(problem)
        }
        if !dropped.isEmpty { revoked(dropped) }
        return .paired(token: issued.token, device: issued.device)
    }

    // MARK: Tokens

    /// The device a token belongs to, or nil. Marks it as seen.
    func authenticate(_ token: String) -> PhoneDevice? {
        guard let (id, _) = PhoneToken.split(token),
              let index = devices.firstIndex(where: { $0.id == id }),
              PhoneToken.matches(token, device: devices[index]) else { return nil }
        let now = clock()
        devices[index].lastSeenAt = now
        if now.timeIntervalSince(lastSeenSavedAt[id] ?? .distantPast) >= Self.lastSeenSaveInterval {
            lastSeenSavedAt[id] = now
            let snapshot = devices
            Task { _ = await self.save(snapshot) }
        }
        return devices[index]
    }

    /// Forgets one phone. Returns the problem if the keychain refused.
    @discardableResult
    func forget(id: String) async -> String? {
        guard devices.contains(where: { $0.id == id }) else { return nil }
        let problem = await save(devices.filter { $0.id != id })
        if problem == nil { revoked([id]) }
        return problem
    }

    @discardableResult
    func forgetAll() async -> String? {
        let ids = Set(devices.map(\.id))
        cancelPairing()
        let problem = await save([])
        if problem == nil { revoked(ids) }
        return problem
    }

    private func revoked(_ ids: Set<String>) {
        for id in ids {
            limiter.forget(token: id)
            lastSeenSavedAt[id] = nil
        }
        onRevoked?(ids)
    }

    private func save(_ next: [PhoneDevice]) async -> String? {
        let store = self.store
        do {
            try await queue.run { try store.save(next) }
            // Keep what was seen while the save ran.
            let seen = Dictionary(devices.map { ($0.id, $0.lastSeenAt) }, uniquingKeysWith: { a, _ in a })
            devices = next.map { device in
                var d = device
                if let s = seen[device.id] ?? nil, s > (d.lastSeenAt ?? .distantPast) { d.lastSeenAt = s }
                return d
            }
            storeProblem = nil
            return nil
        } catch {
            let problem = "The keychain did not take the change: \(error.localizedDescription)"
            storeProblem = problem
            Log.error("phone app: paired devices not saved: \(error.localizedDescription)")
            return problem
        }
    }

    // MARK: Limits

    func allowRequest(device: PhoneDevice) -> Bool {
        limiter.allowRequest(token: device.id, now: clock())
    }

    func blockRemaining(address: String) -> TimeInterval? {
        limiter.blockRemaining(address: address, now: clock())
    }

    @discardableResult
    func recordFailure(address: String) -> Bool {
        let blocked = limiter.recordFailure(address: address, now: clock())
        if blocked {
            Log.info("phone app: \(address) refused for \(Int(PhoneRateLimiter.blockDuration)) s after \(PhoneRateLimiter.failureLimit) failed sign-ins")
        }
        return blocked
    }
}
