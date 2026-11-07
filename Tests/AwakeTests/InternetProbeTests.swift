import XCTest
@testable import Awake

final class InternetProbeTests: XCTestCase {
    func testApplesPageIsReachable() {
        XCTAssertTrue(InternetProbe.verdict(status: 200, body: "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"))
    }

    func testAPortalPageOrRedirectIsNot() {
        XCTAssertFalse(InternetProbe.verdict(status: 200, body: "<html>Welcome to Hotel Wi-Fi, please log in</html>"))
        XCTAssertFalse(InternetProbe.verdict(status: 302, body: ""))
        XCTAssertFalse(InternetProbe.verdict(status: 511, body: "Success"))
        XCTAssertFalse(InternetProbe.verdict(status: nil, body: nil))
    }

    func testTrackerNeedsTwoFailuresAndOneSuccess() {
        var t = ReachabilityTracker()
        XCTAssertFalse(t.record(false))
        XCTAssertFalse(t.down, "one lost probe is not an outage")
        XCTAssertTrue(t.record(false))
        XCTAssertTrue(t.down)
        XCTAssertFalse(t.record(false), "still down: no change")
        XCTAssertTrue(t.record(true))
        XCTAssertFalse(t.down)
    }

    func testUnknownResultsChangeNothing() {
        var t = ReachabilityTracker()
        t.record(false)
        XCTAssertFalse(t.record(nil))
        t.record(nil)
        XCTAssertFalse(t.down)
        t.record(false)
        XCTAssertTrue(t.down)
    }
}

/// A probe whose answers the test scripts.
final class FakeProbe: InternetProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _answers: [Bool?]
    private var _calls = 0
    init(_ answers: [Bool?]) { _answers = answers }
    var calls: Int { lock.withLock { _calls } }
    func set(_ answers: [Bool?]) { lock.withLock { _answers = answers } }
    func reachable() async -> Bool? {
        lock.withLock {
            _calls += 1
            guard !_answers.isEmpty else { return nil }
            return _answers.count == 1 ? _answers[0] : _answers.removeFirst()
        }
    }
}

@MainActor
final class NetworkFailoverProbeTests: XCTestCase {
    private var home: TempHome!

    override func setUp() async throws { home = TempHome() }
    override func tearDown() async throws { home.destroy() }

    private func make(probe: FakeProbe, config: Config = Config(), clock: FakeClock) -> NetworkFailover {
        let nudge = TmuxNudge { _, _ in true }
        return NetworkFailover(paths: home.paths, keychain: FakeKeychainStore(), nudge: nudge, notifier: RecordingNotifier(), clock: { clock.now }, probe: probe, probeInterval: 3600) { config }
    }

    /// Wi-Fi says connected, the internet does not answer twice: an outage
    /// opens as if the path had dropped, with the first retry scheduled.
    func testTwoFailedProbesOnASatisfiedPathOpenAnOutage() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let probe = FakeProbe([false])
        let n = make(probe: probe, clock: clock)
        await n.simulate(satisfied: true)
        await n.probeNow()
        XCTAssertFalse(n.machine.inOutage, "one failure is not an outage")
        await n.probeNow()
        XCTAssertTrue(n.machine.inOutage)
        XCTAssertNotNil(n.retryTimer, "the hotspot retry is scheduled like a path outage")

        probe.set([true])
        await n.probeNow()
        XCTAssertFalse(n.machine.inOutage, "a reachable probe closes the outage it opened")
        XCTAssertNotNil(n.lastGap)
    }

    func testTheProbeDoesNotRunWhileThePathIsDown() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let probe = FakeProbe([false])
        let n = make(probe: probe, clock: clock)
        await n.simulate(satisfied: false)
        await n.probeNow()
        XCTAssertEqual(probe.calls, 0)
    }

    func testTheSettingTurnsTheProbeOff() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        var config = Config()
        config.internetProbe = false
        let probe = FakeProbe([false])
        let n = make(probe: probe, config: config, clock: clock)
        await n.simulate(satisfied: true)
        await n.probeNow()
        await n.probeNow()
        XCTAssertEqual(probe.calls, 0)
        XCTAssertFalse(n.machine.inOutage)
    }

    /// The path comes back behind a captive portal: not a recovery until
    /// the page loads, so no nudge and no handoff line yet.
    func testAPathRecoveryBehindAPortalIsNotARecovery() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let probe = FakeProbe([false])
        let n = make(probe: probe, clock: clock)
        await n.simulate(satisfied: false)
        XCTAssertTrue(n.machine.inOutage)
        clock.advance(30)
        await n.simulate(satisfied: true)
        XCTAssertTrue(n.machine.inOutage, "portal answered: still an outage")
        XCTAssertEqual(probe.calls, 1)
        XCTAssertNil(n.lastGap)

        probe.set([true])
        clock.advance(30)
        await n.probeNow()
        XCTAssertFalse(n.machine.inOutage)
        XCTAssertEqual(n.lastGap, 60)
    }

    func testAnUnknownProbeTrustsThePath() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let probe = FakeProbe([nil])
        let n = make(probe: probe, clock: clock)
        await n.simulate(satisfied: false)
        clock.advance(10)
        await n.simulate(satisfied: true)
        XCTAssertFalse(n.machine.inOutage)
        XCTAssertEqual(n.lastGap, 10)
    }
}

@MainActor
final class OutageNoticeTests: XCTestCase {
    private var home: TempHome!
    override func setUp() async throws { home = TempHome() }
    override func tearDown() async throws { home.destroy() }

    private func make(notifier: RecordingNotifier, config: Config, clock: FakeClock) -> NetworkFailover {
        NetworkFailover(paths: home.paths, keychain: FakeKeychainStore(), nudge: TmuxNudge { _, _ in true }, notifier: notifier, clock: { clock.now }, probe: nil) { config }
    }

    /// "Internet down" is posted when the notice timer fires during an
    /// outage, once, and a short recovery after it is closed on the phone.
    func testOutageIsAnnouncedOnceAndClosedOnRecovery() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let notifier = RecordingNotifier()
        var config = Config()
        config.hotspotSSID = "iPhone"
        let n = make(notifier: notifier, config: config, clock: clock)
        await n.simulate(satisfied: false)
        clock.advance(90)
        n.fireOutageNotice()
        n.fireOutageNotice()
        XCTAssertEqual(notifier.posts.map(\.title), ["Internet down"])
        XCTAssertTrue(notifier.posts[0].body.contains("1m 30s"), notifier.posts[0].body)
        XCTAssertTrue(notifier.posts[0].body.contains("iPhone"), notifier.posts[0].body)
        XCTAssertTrue(n.outageAnnounced)

        // Recovery below the nudge threshold would otherwise be silent.
        config.nudgeThreshold = 3600
        await n.simulate(satisfied: true)
        XCTAssertEqual(notifier.posts.map(\.title), ["Internet down", "Internet back"])
        XCTAssertFalse(n.outageAnnounced)
    }

    func testNoticeOutsideAnOutageOrAfterRecoveryPostsNothing() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let notifier = RecordingNotifier()
        let n = make(notifier: notifier, config: Config(), clock: clock)
        n.fireOutageNotice()
        await n.simulate(satisfied: false)
        clock.advance(10)
        await n.simulate(satisfied: true)
        n.fireOutageNotice()
        XCTAssertEqual(notifier.posts.count, 0)
    }

    func testStopForgetsTheNotice() async {
        let clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        let notifier = RecordingNotifier()
        let n = make(notifier: notifier, config: Config(), clock: clock)
        await n.simulate(satisfied: false)
        n.fireOutageNotice()
        XCTAssertTrue(n.outageAnnounced)
        n.stop()
        XCTAssertFalse(n.outageAnnounced)
    }
}
