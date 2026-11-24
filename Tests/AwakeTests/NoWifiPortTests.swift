import XCTest
@testable import Awake

/// A Mac with no Wi-Fi port (a desktop on Ethernet, a virtual machine)
/// used to get "Internet down — Wi-Fi has had no connection for 1m 30s" in
/// every session: the Wi-Fi-only path was never satisfied. The Wi-Fi
/// failover now stays out of it, and the internet check still decides.
@MainActor
final class NoWifiPortTests: XCTestCase {
    private var home: TempHome!
    private var clock: FakeClock!
    private var notifier: RecordingNotifier!
    private var joiner: RecordingHotspotJoiner!

    private static let ethernetOnly = """

    Hardware Port: Ethernet
    Device: en0
    Ethernet Address: 00:11:22:33:44:55

    Hardware Port: Thunderbolt Bridge
    Device: bridge0
    Ethernet Address: 00:11:22:33:44:56
    """

    override func setUp() async throws {
        home = TempHome()
        clock = FakeClock(Date(timeIntervalSince1970: 1_800_000_000))
        notifier = RecordingNotifier()
        joiner = RecordingHotspotJoiner()
    }

    override func tearDown() async throws { home.destroy() }

    private func make(ports: String?, probe: FakeProbe? = nil, hotspot: String = "Phone") throws -> NetworkFailover {
        let keychain = FakeKeychainStore()
        try keychain.set(service: KeychainStore.service, account: "Phone", value: "secret")
        var config = Config()
        config.hotspotSSID = hotspot
        config.nudgeThreshold = 3600
        let clock = self.clock!
        struct NoAnswer: Error {}
        return NetworkFailover(
            paths: home.paths, keychain: keychain, nudge: TmuxNudge { _, _ in true }, hotspotJoiner: joiner,
            notifier: notifier, clock: { clock.now }, probe: probe, probeInterval: 3600,
            hardwarePorts: { if let ports { return ports } else { throw NoAnswer() } }
        ) { config }
    }

    func testAMacWithoutAWifiPortIsRecognised() async throws {
        let n = try make(ports: Self.ethernetOnly)
        XCTAssertFalse(n.noWifiPort, "decided before networksetup was asked")
        await n.resolveInterface()
        XCTAssertTrue(n.noWifiPort)
        XCTAssertNil(n.wifiInterface)
    }

    func testAWifiPortOrNoAnswerIsNotAMacWithoutWifi() async throws {
        let wifi = try make(ports: "Hardware Port: Wi-Fi\nDevice: en1\n")
        await wifi.resolveInterface()
        XCTAssertFalse(wifi.noWifiPort)
        XCTAssertEqual(wifi.wifiInterface, "en1")

        let failed = try make(ports: nil)
        await failed.resolveInterface()
        XCTAssertFalse(failed.noWifiPort, "a networksetup that failed was read as a Mac with no Wi-Fi")
    }

    /// The internet stops answering on a Mac with no Wi-Fi: "Internet down"
    /// without the word Wi-Fi, no hotspot join, no retry timer.
    func testProbeOutageIsAnnouncedWithoutWifiOrHotspot() async throws {
        let probe = FakeProbe([false])
        let n = try make(ports: Self.ethernetOnly, probe: probe)
        await n.resolveInterface()
        await n.probeNow()
        await n.probeNow()
        XCTAssertTrue(n.machine.inOutage, "the internet check no longer opens an outage")
        XCTAssertNil(n.retryTimer, "a hotspot retry was scheduled on a Mac with no Wi-Fi")

        clock.advance(FailoverMachine.initialDelay)
        await n.fireTimer().value
        XCTAssertEqual(joiner.calls, [], "a hotspot join was tried on a Mac with no Wi-Fi")
        XCTAssertNil(n.retryTimer)
        XCTAssertNil(n.passwordReport)

        clock.advance(85)
        n.fireOutageNotice(source: NetworkFailover.probeSource)
        let post = try XCTUnwrap(notifier.posts.last)
        XCTAssertEqual(post.title, "Internet down")
        XCTAssertEqual(post.body, "The network is connected but the internet does not answer for 1m 30s. Awake keeps watching.")
        XCTAssertFalse(notifier.posts.contains { $0.title.contains("Wi-Fi") || $0.body.contains("Wi-Fi") || $0.body.lowercased().contains("hotspot") })

        probe.set([true])
        clock.advance(30)
        await n.probeNow()
        XCTAssertFalse(n.machine.inOutage)
        XCTAssertEqual(notifier.posts.last?.title, "Internet back")
        XCTAssertEqual(notifier.posts.last?.body, "Back after 2m.")
        n.stop()
    }

    /// The network path itself is lost (cable out): worded without Wi-Fi.
    func testLostNetworkPathIsWordedWithoutWifi() async throws {
        let n = try make(ports: Self.ethernetOnly)
        await n.resolveInterface()
        await n.simulate(satisfied: false)
        clock.advance(90)
        n.fireOutageNotice()
        XCTAssertEqual(notifier.posts.map(\.title), ["Internet down"])
        XCTAssertEqual(notifier.posts.last?.body, "This Mac has had no network connection for 1m 30s. Awake keeps watching.")
        XCTAssertNil(n.retryTimer)
        n.stop()
    }

    /// With a Wi-Fi port nothing changes: the join runs and the wording
    /// names Wi-Fi.
    func testAMacWithWifiStillJoinsAndNamesWifi() async throws {
        let n = try make(ports: "Hardware Port: Wi-Fi\nDevice: en1\n")
        await n.resolveInterface()
        await n.simulate(satisfied: false)
        XCTAssertNotNil(n.retryTimer)
        clock.advance(FailoverMachine.initialDelay)
        await n.fireTimer().value
        XCTAssertEqual(joiner.calls, [RecordingHotspotJoiner.Call(ssid: "Phone", password: "secret", interfaceName: "en1")])
        clock.advance(85)
        n.fireOutageNotice()
        XCTAssertEqual(notifier.posts.last?.body, "Wi-Fi has had no connection for 1m 30s. Awake keeps trying to join Phone (1 attempt so far).")
        n.stop()
    }
}
