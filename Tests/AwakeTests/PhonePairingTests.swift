import XCTest
@testable import Awake

/// Deterministic bytes: 0, 1, 2, ... so every draw differs.
final class CountingRandom: @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt8 = 0
    var random: PhoneRandom {
        { count in
            self.lock.withLock {
                (0..<count).map { _ in
                    defer { self.next = self.next &+ 1 }
                    return self.next
                }
            }
        }
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date = Date(timeIntervalSince1970: 1_800_000_000)) { _now = now }
    var now: Date { lock.withLock { _now } }
    func advance(_ seconds: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(seconds) } }
}

final class PhonePairingTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testCodesAreSixDigitsAndKeepLeadingZeros() {
        XCTAssertEqual(PhoneSecureRandom.pairingCode { _ in [0, 0, 0, 7] }, "000007")
        XCTAssertEqual(PhoneSecureRandom.pairingCode { _ in [0x00, 0x0F, 0x42, 0x3F] }, "999999")
        XCTAssertEqual(PhoneSecureRandom.pairingCode { _ in [0x00, 0x0F, 0x42, 0x40] }, "000000")
        for _ in 0..<200 {
            let code = PhoneSecureRandom.pairingCode(PhoneSecureRandom.system)
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy(\.isNumber))
        }
    }

    func testBiasedDrawsAreRejected() {
        // 0xFFFFFFFF is above the last multiple of a million: drawn again.
        nonisolated(unsafe) var draws = 0
        let code = PhoneSecureRandom.pairingCode { _ in
            draws += 1
            return draws == 1 ? [0xFF, 0xFF, 0xFF, 0xFF] : [0, 0, 0, 42]
        }
        XCTAssertEqual(code, "000042")
        XCTAssertEqual(draws, 2)
    }

    func testTheRightCodeIsAcceptedOnceAndClosesTheWindow() {
        var p = PhonePairing()
        let w = p.begin(now: t0)
        XCTAssertEqual(w.expiresAt, t0.addingTimeInterval(300))
        XCTAssertEqual(w.attemptsLeft, 5)
        XCTAssertEqual(p.redeem(w.code, now: t0.addingTimeInterval(10)), .accepted)
        XCTAssertNil(p.current(now: t0.addingTimeInterval(11)))
        XCTAssertEqual(p.redeem(w.code, now: t0.addingTimeInterval(12)), .notOpen, "a code pairs one phone")
    }

    func testACodeTypedWithSpacesStillMatches() {
        var p = PhonePairing()
        let w = p.begin(now: t0) { _ in [0, 1, 226, 64] } // 123456
        XCTAssertEqual(w.code, "123456")
        XCTAssertEqual(p.redeem("123 456", now: t0), .accepted)
    }

    func testNoWindowNoPairing() {
        var p = PhonePairing()
        XCTAssertEqual(p.redeem("123456", now: t0), .notOpen)
    }

    func testTheWindowExpiresAfterFiveMinutes() {
        var p = PhonePairing()
        let w = p.begin(now: t0)
        XCTAssertNotNil(p.current(now: t0.addingTimeInterval(299)))
        XCTAssertEqual(p.redeem(w.code, now: t0.addingTimeInterval(300)), .expired)
        XCTAssertEqual(p.redeem(w.code, now: t0.addingTimeInterval(301)), .notOpen)
        var q = PhonePairing()
        q.begin(now: t0)
        XCTAssertNil(q.current(now: t0.addingTimeInterval(300)))
    }

    func testFiveWrongCodesReplaceTheCode() {
        let dice = CountingRandom()
        var p = PhonePairing()
        let first = p.begin(now: t0, random: dice.random)
        let wrong = first.code == "111111" ? "222222" : "111111"
        for left in [4, 3, 2, 1] {
            XCTAssertEqual(p.redeem(wrong, now: t0, random: dice.random), .wrong(attemptsLeft: left))
        }
        XCTAssertEqual(p.redeem(wrong, now: t0.addingTimeInterval(60), random: dice.random), .regenerated)
        let second = p.current(now: t0.addingTimeInterval(60))
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second?.code, first.code)
        XCTAssertEqual(second?.attemptsLeft, 5)
        XCTAssertEqual(second?.expiresAt, t0.addingTimeInterval(360), "the new code gets its own five minutes")
        XCTAssertNotEqual(p.redeem(first.code, now: t0.addingTimeInterval(61), random: dice.random), .accepted, "the old code is dead")
    }

    func testMalformedCodesCountAsWrong() {
        var p = PhonePairing()
        p.begin(now: t0)
        XCTAssertEqual(p.redeem("", now: t0), .wrong(attemptsLeft: 4))
        XCTAssertEqual(p.redeem("12345", now: t0), .wrong(attemptsLeft: 3))
        XCTAssertEqual(p.redeem("1234567", now: t0), .wrong(attemptsLeft: 2))
    }

    func testCancelClosesTheWindow() {
        var p = PhonePairing()
        let w = p.begin(now: t0)
        p.cancel()
        XCTAssertEqual(p.redeem(w.code, now: t0), .notOpen)
    }
}

final class PhoneTokenTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnIssuedTokenMatchesItsDeviceAndNoOther() {
        let a = PhoneToken.issue(name: "iPhone", now: t0)
        let b = PhoneToken.issue(name: "iPad", now: t0)
        XCTAssertTrue(PhoneToken.matches(a.token, device: a.device))
        XCTAssertFalse(PhoneToken.matches(a.token, device: b.device))
        XCTAssertFalse(PhoneToken.matches(b.token, device: a.device))
        XCTAssertNotEqual(a.token, b.token)
    }

    func testTheTokenIs32RandomBytesAndTheRecordHoldsOnlyAHash() throws {
        let issued = PhoneToken.issue(name: "iPhone", now: t0)
        let (id, secret) = try XCTUnwrap(PhoneToken.split(issued.token))
        XCTAssertEqual(id, issued.device.id)
        XCTAssertEqual(id.count, 16)
        XCTAssertEqual(PhoneSecureRandom.decodeBase64URL(secret)?.count, 32)
        XCTAssertEqual(issued.device.hash.count, 64, "SHA-256, hex")
        let stored = String(decoding: try Store.makeEncoder().encode(issued.device), as: UTF8.self)
        XCTAssertFalse(stored.contains(secret), "the secret is never stored")
        XCTAssertEqual(issued.device.hash, PhoneToken.hash(secret: secret, salt: issued.device.salt))
    }

    func testTamperedAndMalformedTokensDoNotMatch() {
        let issued = PhoneToken.issue(name: "iPhone", now: t0)
        var flipped = issued.token
        let last = flipped.removeLast()
        flipped.append(last == "A" ? "B" : "A")
        XCTAssertFalse(PhoneToken.matches(flipped, device: issued.device))
        for bad in ["", ".", "abc", "\(issued.device.id).", ".secret", "\(issued.device.id).x.y", issued.device.id, String(repeating: "a", count: 200) + ".b"] {
            XCTAssertFalse(PhoneToken.matches(bad, device: issued.device), bad)
        }
    }

    func testTheSameSecretUnderAnotherSaltHashesDifferently() {
        XCTAssertNotEqual(PhoneToken.hash(secret: "s", salt: "a"), PhoneToken.hash(secret: "s", salt: "b"))
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(PhoneToken.constantTimeEqual([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(PhoneToken.constantTimeEqual([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(PhoneToken.constantTimeEqual([1, 2, 3], [1, 2]))
        XCTAssertTrue(PhoneToken.constantTimeEqual([], []))
    }

    func testDeviceNamesAreOneBoundedPrintableLine() {
        XCTAssertEqual(PhoneToken.cleanName("  Parth's iPhone \n"), "Parth's iPhone")
        XCTAssertEqual(PhoneToken.cleanName("a\nb\tc\u{0}"), "abc")
        XCTAssertEqual(PhoneToken.cleanName(""), "Phone")
        XCTAssertEqual(PhoneToken.cleanName("   "), "Phone")
        XCTAssertEqual(PhoneToken.cleanName(String(repeating: "x", count: 100)).count, 40)
    }

    func testBase64URLRoundTrip() {
        let bytes: [UInt8] = [0xFB, 0xFF, 0xFE, 0x00, 0x01]
        let text = PhoneSecureRandom.base64URL(bytes)
        XCTAssertFalse(text.contains("+") || text.contains("/") || text.contains("="))
        XCTAssertEqual(PhoneSecureRandom.decodeBase64URL(text), Data(bytes))
        XCTAssertEqual(PhoneSecureRandom.hex([0, 15, 255]), "000fff")
    }
}

final class PhoneRateLimiterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testThirtyRequestsPerTenSecondsPerToken() {
        var l = PhoneRateLimiter()
        for i in 0..<30 {
            XCTAssertTrue(l.allowRequest(token: "a", now: t0.addingTimeInterval(Double(i) * 0.1)), "\(i)")
        }
        XCTAssertFalse(l.allowRequest(token: "a", now: t0.addingTimeInterval(3)))
        XCTAssertTrue(l.allowRequest(token: "b", now: t0.addingTimeInterval(3)), "another phone has its own budget")
        XCTAssertFalse(l.allowRequest(token: "a", now: t0.addingTimeInterval(9.9)))
        XCTAssertTrue(l.allowRequest(token: "a", now: t0.addingTimeInterval(10.01)), "the window slides")
    }

    func testRefusedRequestsDoNotExtendTheWait() {
        var l = PhoneRateLimiter()
        for _ in 0..<30 { XCTAssertTrue(l.allowRequest(token: "a", now: t0)) }
        for i in 1...50 { XCTAssertFalse(l.allowRequest(token: "a", now: t0.addingTimeInterval(Double(i) * 0.1))) }
        XCTAssertTrue(l.allowRequest(token: "a", now: t0.addingTimeInterval(10.01)))
    }

    func testFiveFailuresInAMinuteBlockTheAddressForFiveMinutes() {
        var l = PhoneRateLimiter()
        for i in 0..<4 {
            XCTAssertFalse(l.recordFailure(address: "100.64.0.9", now: t0.addingTimeInterval(Double(i))))
            XCTAssertNil(l.blockRemaining(address: "100.64.0.9", now: t0.addingTimeInterval(Double(i))))
        }
        XCTAssertTrue(l.recordFailure(address: "100.64.0.9", now: t0.addingTimeInterval(4)))
        XCTAssertEqual(l.blockRemaining(address: "100.64.0.9", now: t0.addingTimeInterval(4)), 300)
        XCTAssertEqual(l.blockRemaining(address: "100.64.0.9", now: t0.addingTimeInterval(204)), 100)
        XCTAssertNil(l.blockRemaining(address: "100.64.0.8", now: t0.addingTimeInterval(5)), "another address is not blocked")
        XCTAssertNil(l.blockRemaining(address: "100.64.0.9", now: t0.addingTimeInterval(304)))
    }

    func testSlowFailuresNeverBlock() {
        var l = PhoneRateLimiter()
        for i in 0..<20 {
            XCTAssertFalse(l.recordFailure(address: "a", now: t0.addingTimeInterval(Double(i) * 16)), "four a minute at most")
        }
        XCTAssertNil(l.blockRemaining(address: "a", now: t0.addingTimeInterval(400)))
    }

    func testAfterABlockTheCountStartsAgain() {
        var l = PhoneRateLimiter()
        for _ in 0..<5 { l.recordFailure(address: "a", now: t0) }
        let later = t0.addingTimeInterval(301)
        XCTAssertNil(l.blockRemaining(address: "a", now: later))
        XCTAssertFalse(l.recordFailure(address: "a", now: later))
    }

    func testTheTablesStayBounded() {
        var l = PhoneRateLimiter()
        for i in 0..<5000 {
            _ = l.allowRequest(token: "t\(i)", now: t0.addingTimeInterval(Double(i) * 0.001))
            l.recordFailure(address: "a\(i)", now: t0.addingTimeInterval(Double(i) * 0.001))
        }
        // Still answers, and the newest entries are the ones kept.
        XCTAssertTrue(l.allowRequest(token: "t4999", now: t0.addingTimeInterval(6)))
        XCTAssertFalse(l.recordFailure(address: "fresh", now: t0.addingTimeInterval(6)))
    }
}

@MainActor
final class PhoneAuthTests: XCTestCase {
    private func make(_ store: MemoryPhoneDeviceStore = MemoryPhoneDeviceStore(), clock: TestClock = TestClock()) -> PhoneAuth {
        PhoneAuth(store: store, queue: KeychainQueue(), clock: { clock.now })
    }

    func testPairingIssuesATokenThatAuthenticatesAndIsStoredHashed() async throws {
        let store = MemoryPhoneDeviceStore()
        let auth = make(store)
        await auth.load()
        let window = auth.beginPairing()
        XCTAssertEqual(auth.pairingWindow, window)
        guard case let .paired(token, device) = await auth.pair(code: window.code, name: "iPhone") else { return XCTFail("not paired") }
        XCTAssertNil(auth.pairingWindow, "the window closes on success")
        XCTAssertEqual(auth.devices.map(\.name), ["iPhone"])
        XCTAssertEqual(auth.authenticate(token)?.id, device.id)
        XCTAssertNil(auth.authenticate(token + "x"))
        XCTAssertEqual(store.stored.count, 1)
        let secret = try XCTUnwrap(PhoneToken.split(token)).secret
        XCTAssertFalse(String(describing: store.stored).contains(secret))
    }

    func testAWrongCodeDoesNotPair() async {
        let auth = make()
        await auth.load()
        let window = auth.beginPairing()
        let wrong = window.code == "000000" ? "111111" : "000000"
        let result = await auth.pair(code: wrong, name: "x")
        XCTAssertEqual(result, .refused(.wrong(attemptsLeft: 4)))
        XCTAssertTrue(auth.devices.isEmpty)
        XCTAssertEqual(auth.pairingWindow?.attemptsLeft, 4)
    }

    func testPairingWithoutAWindowIsRefused() async {
        let auth = make()
        await auth.load()
        let result = await auth.pair(code: "123456", name: "x")
        XCTAssertEqual(result, .refused(.notOpen))
    }

    func testAKeychainThatRefusesTheSaveHandsOutNoToken() async {
        let store = MemoryPhoneDeviceStore()
        store.failSave = "keychain locked"
        let auth = make(store)
        await auth.load()
        let window = auth.beginPairing()
        guard case let .notSaved(problem) = await auth.pair(code: window.code, name: "iPhone") else { return XCTFail("expected notSaved") }
        XCTAssertTrue(problem.contains("keychain locked"), problem)
        XCTAssertTrue(auth.devices.isEmpty, "nothing in memory that is not on file")
        XCTAssertNotNil(auth.storeProblem)
    }

    func testAnUnreadableKeychainLetsNobodyInAndSaysSo() async {
        let issued = PhoneToken.issue(name: "iPhone", now: Date())
        let store = MemoryPhoneDeviceStore([issued.device])
        store.failLoad = "another build's item"
        let auth = make(store)
        await auth.load()
        XCTAssertTrue(auth.loaded)
        XCTAssertTrue(auth.devices.isEmpty)
        XCTAssertNil(auth.authenticate(issued.token))
        XCTAssertTrue(auth.storeProblem?.contains("another build's item") == true)
    }

    func testAnotherBuildsKeychainItemIsNamedAndAFreshPairingReplacesIt() async {
        let issued = PhoneToken.issue(name: "iPhone", now: Date())
        let store = MemoryPhoneDeviceStore([issued.device])
        store.failLoadStatus = errSecAuthFailed
        let auth = make(store)
        await auth.load()
        XCTAssertNil(auth.authenticate(issued.token))
        XCTAssertEqual(auth.storeProblem, "The paired phones were saved by another build of Awake, which this one cannot read. Pair the phone again.")
        let window = auth.beginPairing()
        guard case let .paired(token, _) = await auth.pair(code: window.code, name: "iPhone") else { return XCTFail("not paired") }
        XCTAssertNotNil(auth.authenticate(token))
        XCTAssertNil(auth.storeProblem)
        XCTAssertEqual(store.stored.count, 1, "the unreadable record is replaced, not merged")
    }

    func testDevicesSurviveAReload() async {
        let store = MemoryPhoneDeviceStore()
        let first = make(store)
        await first.load()
        let window = first.beginPairing()
        guard case let .paired(token, _) = await first.pair(code: window.code, name: "iPhone") else { return XCTFail("not paired") }
        let second = make(store)
        await second.load()
        XCTAssertNotNil(second.authenticate(token))
    }

    func testForgetRevokesOneAndForgetAllRevokesEvery() async {
        let auth = make()
        await auth.load()
        var tokens: [String] = []
        for name in ["a", "b", "c"] {
            let w = auth.beginPairing()
            guard case let .paired(token, _) = await auth.pair(code: w.code, name: name) else { return XCTFail("not paired") }
            tokens.append(token)
        }
        var revoked: [Set<String>] = []
        auth.onRevoked = { revoked.append($0) }
        let b = auth.devices[1].id
        let problem = await auth.forget(id: b)
        XCTAssertNil(problem)
        XCTAssertNil(auth.authenticate(tokens[1]))
        XCTAssertNotNil(auth.authenticate(tokens[0]))
        XCTAssertEqual(revoked, [[b]])
        auth.beginPairing()
        await auth.forgetAll()
        XCTAssertTrue(auth.devices.isEmpty)
        XCTAssertNil(auth.pairingWindow, "forget all also closes an open pairing window")
        XCTAssertNil(auth.authenticate(tokens[0]))
        XCTAssertNil(auth.authenticate(tokens[2]))
        XCTAssertEqual(revoked.count, 2)
    }

    func testAFailedForgetKeepsTheDevice() async {
        let store = MemoryPhoneDeviceStore()
        let auth = make(store)
        await auth.load()
        let w = auth.beginPairing()
        guard case let .paired(token, device) = await auth.pair(code: w.code, name: "a") else { return XCTFail("not paired") }
        store.failSave = "keychain locked"
        let problem = await auth.forget(id: device.id)
        XCTAssertNotNil(problem)
        XCTAssertNotNil(auth.authenticate(token), "what the keychain still holds is still valid; Settings shows the problem")
    }

    func testTheOldestPhoneIsDroppedPastTheLimit() async {
        let clock = TestClock()
        let auth = make(clock: clock)
        await auth.load()
        var tokens: [String] = []
        for i in 0..<(PhoneAuth.maxDevices + 1) {
            clock.advance(10)
            let w = auth.beginPairing()
            guard case let .paired(token, _) = await auth.pair(code: w.code, name: "p\(i)") else { return XCTFail("not paired") }
            tokens.append(token)
        }
        XCTAssertEqual(auth.devices.count, PhoneAuth.maxDevices)
        XCTAssertNil(auth.authenticate(tokens[0]), "the phone seen longest ago went")
        XCTAssertNotNil(auth.authenticate(tokens.last!))
    }

    func testAuthenticateMarksTheDeviceSeen() async {
        let clock = TestClock()
        let auth = make(clock: clock)
        await auth.load()
        let w = auth.beginPairing()
        guard case let .paired(token, _) = await auth.pair(code: w.code, name: "a") else { return XCTFail("not paired") }
        clock.advance(120)
        XCTAssertEqual(auth.authenticate(token)?.lastSeenAt, clock.now)
    }

    func testAnExpiredWindowDisappearsOnRefresh() async {
        let clock = TestClock()
        let auth = make(clock: clock)
        auth.beginPairing()
        clock.advance(299)
        auth.refreshPairing()
        XCTAssertNotNil(auth.pairingWindow)
        clock.advance(2)
        auth.refreshPairing()
        XCTAssertNil(auth.pairingWindow)
    }
}

final class KeychainPhoneDeviceStoreTests: XCTestCase {
    func testRoundTripsThroughOneKeychainItem() throws {
        let keychain = FakeKeychainStore()
        let store = KeychainPhoneDeviceStore(keychain: keychain)
        XCTAssertEqual(try store.load(), [])
        let device = PhoneToken.issue(name: "iPhone", now: Date(timeIntervalSince1970: 1_800_000_000)).device
        try store.save([device])
        XCTAssertEqual(try store.load(), [device])
        XCTAssertNotNil(try keychain.get(service: "awake-phone-app", account: "paired-devices"))
        try store.save([])
        XCTAssertNil(try keychain.get(service: "awake-phone-app", account: "paired-devices"), "no phones, no item")
    }
}
