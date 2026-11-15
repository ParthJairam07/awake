import CryptoKit
import Foundation

/// Random bytes for pairing codes and tokens. Tests pass a counter.
typealias PhoneRandom = @Sendable (_ count: Int) -> [UInt8]

enum PhoneSecureRandom {
    static let system: PhoneRandom = { count in
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        // SecRandomCopyBytes failing means the kernel's generator is not
        // available; a guessable token would be worse than no phone app.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed (\(status))")
        return bytes
    }

    /// Six decimal digits, each of the million codes equally likely.
    static func pairingCode(_ random: PhoneRandom) -> String {
        // 2^32 is not a multiple of 10^6: draw again above the last full
        // multiple instead of taking the remainder of a biased value.
        let limit = UInt32.max - (UInt32.max % 1_000_000)
        while true {
            let b = random(4)
            let value = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
            if value < limit {
                let code = String(value % 1_000_000)
                return String(repeating: "0", count: 6 - code.count) + code
            }
        }
    }

    static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { byte in
            let s = String(byte, radix: 16)
            return s.count == 1 ? "0" + s : s
        }.joined()
    }

    static func base64URL(_ bytes: some Sequence<UInt8>) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}

/// The pairing window: the Mac shows a 6-digit code for five minutes, a
/// phone that sends it gets a token. Five wrong codes replace the code,
/// so a phone on the tailnet cannot walk the million codes; the person at
/// the Mac sees the new one. Pure, with the clock and the dice passed in.
struct PhonePairing: Sendable {
    static let lifetime: TimeInterval = 5 * 60
    static let maxAttempts = 5

    struct Window: Equatable, Sendable {
        var code: String
        var expiresAt: Date
        var attemptsLeft: Int
    }

    enum Outcome: Equatable, Sendable {
        /// The code matched; the window is closed (one phone per code).
        case accepted
        /// Wrong; this many tries are left on the code shown.
        case wrong(attemptsLeft: Int)
        /// Wrong for the last time: a new code is on the Mac's screen.
        case regenerated
        /// The window ran out; "Pair phone…" opens another.
        case expired
        /// Nobody opened a window on the Mac.
        case notOpen
    }

    private(set) var window: Window?

    /// Opens a window (replacing one already open) and returns its code.
    @discardableResult
    mutating func begin(now: Date, random: PhoneRandom = PhoneSecureRandom.system) -> Window {
        let w = Window(code: PhoneSecureRandom.pairingCode(random), expiresAt: now.addingTimeInterval(Self.lifetime), attemptsLeft: Self.maxAttempts)
        window = w
        return w
    }

    mutating func cancel() { window = nil }

    /// The open window, or nil once it has run out.
    mutating func current(now: Date) -> Window? {
        if let w = window, now >= w.expiresAt { window = nil }
        return window
    }

    mutating func redeem(_ candidate: String, now: Date, random: PhoneRandom = PhoneSecureRandom.system) -> Outcome {
        guard let w = window else { return .notOpen }
        guard now < w.expiresAt else {
            window = nil
            return .expired
        }
        let digits = candidate.filter(\.isNumber)
        if digits.count == 6, PhoneToken.constantTimeEqual(Array(digits.utf8), Array(w.code.utf8)) {
            window = nil
            return .accepted
        }
        if w.attemptsLeft <= 1 {
            begin(now: now, random: random)
            return .regenerated
        }
        window?.attemptsLeft = w.attemptsLeft - 1
        return .wrong(attemptsLeft: w.attemptsLeft - 1)
    }
}

/// A paired phone as the Mac remembers it. The token itself is never
/// kept: only a salted SHA-256 of its secret half, as for a password.
/// The secret is 32 random bytes, so no slow hash is needed: there is
/// nothing to guess faster than 2^256.
struct PhoneDevice: Codable, Equatable, Sendable, Identifiable {
    /// 8 random bytes, hex. The first half of the token; not a secret.
    var id: String
    /// What the phone called itself ("iPhone"), trimmed and bounded.
    var name: String
    var salt: String
    var hash: String
    var createdAt: Date
    var lastSeenAt: Date?
}

/// A bearer token is `<device id>.<secret>`: the id finds the record, the
/// secret is checked against its hash in constant time.
enum PhoneToken {
    static let secretBytes = 32

    struct Issued: Equatable, Sendable {
        var token: String
        var device: PhoneDevice
    }

    static func issue(name: String, now: Date, random: PhoneRandom = PhoneSecureRandom.system) -> Issued {
        let id = PhoneSecureRandom.hex(random(8))
        let secret = PhoneSecureRandom.base64URL(random(secretBytes))
        let salt = PhoneSecureRandom.hex(random(16))
        let device = PhoneDevice(id: id, name: cleanName(name), salt: salt, hash: hash(secret: secret, salt: salt), createdAt: now, lastSeenAt: now)
        return Issued(token: "\(id).\(secret)", device: device)
    }

    static func hash(secret: String, salt: String) -> String {
        PhoneSecureRandom.hex(SHA256.hash(data: Data((salt + ":" + secret).utf8)))
    }

    static func split(_ token: String) -> (id: String, secret: String)? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, token.utf8.count <= 128 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    static func matches(_ token: String, device: PhoneDevice) -> Bool {
        guard let (id, secret) = split(token), id == device.id else { return false }
        return constantTimeEqual(Array(hash(secret: secret, salt: device.salt).utf8), Array(device.hash.utf8))
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    /// A device name is shown in Settings and written to the audit log:
    /// one line, printable, at most 40 characters.
    static func cleanName(_ raw: String) -> String {
        let printable = String(raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
        let trimmed = printable.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Phone" : String(trimmed.prefix(40))
    }
}

/// Where the paired phones are kept. The app uses the login keychain;
/// tests keep them in memory.
protocol PhoneDeviceStoring: Sendable {
    func load() throws -> [PhoneDevice]
    func save(_ devices: [PhoneDevice]) throws
}

/// One keychain item (service `awake-phone-app`, account `paired-devices`)
/// holding the device records as JSON. Like every Awake keychain item it
/// belongs to the build that wrote it: after a reinstall the item cannot
/// be read without a prompt, the phones are forgotten and pair again.
struct KeychainPhoneDeviceStore: PhoneDeviceStoring {
    static let service = "awake-phone-app"
    static let account = "paired-devices"

    let keychain: any KeychainStoring

    init(keychain: any KeychainStoring = KeychainStore()) {
        self.keychain = keychain
    }

    func load() throws -> [PhoneDevice] {
        guard let text = try keychain.get(service: Self.service, account: Self.account), !text.isEmpty else { return [] }
        return try Store.makeDecoder().decode([PhoneDevice].self, from: Data(text.utf8))
    }

    func save(_ devices: [PhoneDevice]) throws {
        if devices.isEmpty {
            try keychain.delete(service: Self.service, account: Self.account)
            return
        }
        let encoder = Store.makeEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(devices)
        try keychain.set(service: Self.service, account: Self.account, value: String(decoding: data, as: UTF8.self))
    }
}

final class MemoryPhoneDeviceStore: PhoneDeviceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [PhoneDevice]
    private var _saves = 0
    var failLoad: String?
    var failSave: String?
    var saves: Int { lock.withLock { _saves } }
    var stored: [PhoneDevice] { lock.withLock { devices } }

    struct Failure: Error, LocalizedError {
        let errorDescription: String?
    }

    init(_ devices: [PhoneDevice] = []) { self.devices = devices }

    func load() throws -> [PhoneDevice] {
        if let failLoad { throw Failure(errorDescription: failLoad) }
        return lock.withLock { devices }
    }

    func save(_ new: [PhoneDevice]) throws {
        if let failSave { throw Failure(errorDescription: failSave) }
        lock.withLock {
            devices = new
            _saves += 1
        }
    }
}

/// The limits of the phone API, pure: 30 requests per 10 s for each
/// token, and five failed sign-ins (a wrong token or pairing code) per
/// minute from one address, after which that address is refused for five
/// minutes.
struct PhoneRateLimiter: Sendable {
    static let requestLimit = 30
    static let requestWindow: TimeInterval = 10
    static let failureLimit = 5
    static let failureWindow: TimeInterval = 60
    static let blockDuration: TimeInterval = 5 * 60
    /// How many addresses and tokens are tracked at once; the oldest are
    /// dropped past it, so a flood of made-up addresses cannot grow the
    /// tables without bound.
    static let maxTracked = 512

    private var requests: [String: [Date]] = [:]
    private var failures: [String: [Date]] = [:]
    private var blockedUntil: [String: Date] = [:]

    /// Counts a request for `token` and says whether it is within the
    /// limit. A refused request is not counted, so a phone that backs off
    /// gets through again as the window slides.
    mutating func allowRequest(token: String, now: Date) -> Bool {
        var recent = (requests[token] ?? []).filter { now.timeIntervalSince($0) < Self.requestWindow }
        defer {
            requests[token] = recent
            prune(&requests, now: now, window: Self.requestWindow)
        }
        guard recent.count < Self.requestLimit else { return false }
        recent.append(now)
        return true
    }

    /// Seconds until `address` may try again, or nil when it is not blocked.
    mutating func blockRemaining(address: String, now: Date) -> TimeInterval? {
        guard let until = blockedUntil[address] else { return nil }
        if now >= until {
            blockedUntil[address] = nil
            return nil
        }
        return until.timeIntervalSince(now)
    }

    /// Records a failed sign-in; returns true when it starts a block.
    @discardableResult
    mutating func recordFailure(address: String, now: Date) -> Bool {
        var recent = (failures[address] ?? []).filter { now.timeIntervalSince($0) < Self.failureWindow }
        recent.append(now)
        defer { prune(&failures, now: now, window: Self.failureWindow) }
        if recent.count >= Self.failureLimit {
            failures[address] = nil
            blockedUntil[address] = now.addingTimeInterval(Self.blockDuration)
            if blockedUntil.count > Self.maxTracked {
                blockedUntil = blockedUntil.filter { $0.value > now }
            }
            return true
        }
        failures[address] = recent
        return false
    }

    /// Forgets what is tracked for a token (it was revoked).
    mutating func forget(token: String) { requests[token] = nil }

    private func prune(_ table: inout [String: [Date]], now: Date, window: TimeInterval) {
        guard table.count > Self.maxTracked else { return }
        table = table.filter { entry in entry.value.contains { now.timeIntervalSince($0) < window } }
        while table.count > Self.maxTracked, let oldest = table.min(by: { ($0.value.last ?? .distantPast) < ($1.value.last ?? .distantPast) }) {
            table[oldest.key] = nil
        }
    }
}
