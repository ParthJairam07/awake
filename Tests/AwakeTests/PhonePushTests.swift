import XCTest
@testable import Awake

final class PhonePushTests: XCTestCase {
    func testNtfyRequestShape() throws {
        let r = try XCTUnwrap(PhonePush.ntfyRequest(server: "https://ntfy.sh/", topic: "parth-awake", token: "tk_abc", title: "Session ended", body: "Time is up. 100% → 64%", priority: .high))
        XCTAssertEqual(r.url?.absoluteString, "https://ntfy.sh/parth-awake")
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Title"), "Session ended")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Priority"), "high")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer tk_abc")
        XCTAssertEqual(String(data: r.httpBody ?? Data(), encoding: .utf8), "Time is up. 100% → 64%")
    }

    func testNtfyDefaultsAndRefusals() {
        XCTAssertEqual(PhonePush.ntfyRequest(server: "", topic: "t", token: nil, title: "x", body: "y", priority: .normal)?.url?.absoluteString, "https://ntfy.sh/t")
        XCTAssertNil(PhonePush.ntfyRequest(server: "https://ntfy.sh", topic: "", token: nil, title: "x", body: "y", priority: .normal))
        XCTAssertNil(PhonePush.ntfyRequest(server: "https://ntfy.sh", topic: "a/b", token: nil, title: "x", body: "y", priority: .normal))
        XCTAssertNil(PhonePush.ntfyRequest(server: "ftp://x", topic: "t", token: nil, title: "x", body: "y", priority: .normal))
        XCTAssertNil(PhonePush.ntfyRequest(server: "https://ntfy.sh", topic: "t", token: "", title: "x", body: "y", priority: .normal)?.value(forHTTPHeaderField: "Authorization"))
    }

    func testNtfyTitleHeaderIsASCII() {
        let r = PhonePush.ntfyRequest(server: "", topic: "t", token: nil, title: "Battery 45 °C", body: "", priority: .normal)
        XCTAssertEqual(r?.value(forHTTPHeaderField: "Title"), "Battery 45 ?C")
    }

    func testPushoverRequestShape() throws {
        let r = try XCTUnwrap(PhonePush.pushoverRequest(appToken: "app", userKey: "user", title: "Low Power Mode on", body: "a b&c", priority: .normal))
        XCTAssertEqual(r.url?.absoluteString, "https://api.pushover.net/1/messages.json")
        XCTAssertEqual(String(data: r.httpBody ?? Data(), encoding: .utf8), "token=app&user=user&title=Low%20Power%20Mode%20on&message=a%20b%26c&priority=0")
        XCTAssertNil(PhonePush.pushoverRequest(appToken: "", userKey: "user", title: "x", body: "y", priority: .normal))
    }

    func testUrgentTitlesGetHighPriority() {
        XCTAssertEqual(PhonePush.priority(forTitle: "Session ended"), .high)
        XCTAssertEqual(PhonePush.priority(forTitle: "Charger too weak"), .high)
        XCTAssertEqual(PhonePush.priority(forTitle: "Low Power Mode on"), .normal)
    }
}

/// Records requests and answers with scripted statuses.
final class FakePushTransport: PushTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var _statuses: [Int]
    var failWith: String?
    init(statuses: [Int] = [200]) { _statuses = statuses }
    var requests: [URLRequest] { lock.withLock { _requests } }
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let status: Int = lock.withLock {
            _requests.append(request)
            return _statuses.count > 1 ? _statuses.removeFirst() : (_statuses.first ?? 200)
        }
        if let failWith { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: failWith]) }
        return (status, Data("{\"status\":1}".utf8))
    }
}

@MainActor
final class PhoneAlertsTests: XCTestCase {
    private func make(config: Config, statuses: [Int] = [200], secrets: PhoneSecrets = PhoneSecrets(ntfyToken: nil, pushoverAppToken: "app", pushoverUserKey: "user")) -> (PhoneAlerts, RecordingNotifier, FakePushTransport) {
        let local = RecordingNotifier()
        let transport = FakePushTransport(statuses: statuses)
        let alerts = PhoneAlerts(local: local, transport: transport, secrets: { secrets })
        alerts.configProvider = { config }
        return (alerts, local, transport)
    }

    func testUnconfiguredPostsLocallyOnly() async {
        let (alerts, local, transport) = make(config: Config())
        alerts.post(title: "Session ended", body: "Time is up.")
        await alerts.flush()
        XCTAssertEqual(local.posts.map(\.title), ["Session ended"])
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testConfiguredForwardsToEachService() async {
        var config = Config()
        config.ntfyTopic = "parth"
        config.pushoverEnabled = true
        let (alerts, local, transport) = make(config: config)
        alerts.post(title: "Session ended", body: "Time is up.")
        await alerts.flush()
        XCTAssertEqual(local.posts.count, 1, "the local notification is posted exactly once")
        XCTAssertEqual(transport.requests.map { $0.url?.host }, ["ntfy.sh", "api.pushover.net"])
        XCTAssertEqual(alerts.deliveryLog, ["ntfy: ok", "Pushover: ok"])
    }

    func testFailureIsLoggedAndAnnouncedOncePerLaunch() async {
        var config = Config()
        config.ntfyTopic = "parth"
        let (alerts, local, transport) = make(config: config, statuses: [500, 500, 500, 500])
        alerts.post(title: "Low Power Mode on", body: "x")
        await alerts.flush()
        XCTAssertEqual(transport.requests.count, 2, "one retry on a server error")
        XCTAssertEqual(local.posts.map(\.title), ["Low Power Mode on", PhoneAlerts.failureTitle])
        XCTAssertTrue(local.posts.last?.body.contains("ntfy answered 500") ?? false, local.posts.last?.body ?? "")

        alerts.post(title: "Low Power Mode off", body: "y")
        await alerts.flush()
        XCTAssertEqual(local.posts.filter { $0.title == PhoneAlerts.failureTitle }.count, 1, "announced once")
        XCTAssertEqual(transport.requests.count, 4, "still attempted")
    }

    func testClientErrorIsNotRetried() async {
        var config = Config()
        config.ntfyTopic = "parth"
        let (alerts, _, transport) = make(config: config, statuses: [403])
        alerts.post(title: "x", body: "y")
        await alerts.flush()
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testMissingPushoverSecretsAreReportedWithoutARequest() async {
        var config = Config()
        config.pushoverEnabled = true
        let (alerts, local, transport) = make(config: config, secrets: .none)
        alerts.post(title: "x", body: "y")
        await alerts.flush()
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertTrue(local.posts.last?.body.contains("Pushover: the app token or user key is missing") ?? false)
    }

    func testTestAlertReturnsNilOnSuccessAndTheProblemOtherwise() async {
        var config = Config()
        config.ntfyTopic = "parth"
        let ok = make(config: config)
        let nilProblem = await ok.0.sendTest()
        XCTAssertNil(nilProblem)
        XCTAssertEqual(ok.2.requests.first?.value(forHTTPHeaderField: "Title"), "Awake test")
        XCTAssertTrue(ok.1.posts.isEmpty, "a test alert is not posted on the Mac")

        let bad = make(config: config, statuses: [404])
        let problem = await bad.0.sendTest()
        XCTAssertTrue(problem?.contains("ntfy answered 404") ?? false, problem ?? "")
        XCTAssertTrue(bad.1.posts.isEmpty, "the test button shows the problem itself; no failure notice")
    }

    func testWithoutAConfigProviderNothingIsForwarded() async {
        let local = RecordingNotifier()
        let transport = FakePushTransport()
        let alerts = PhoneAlerts(local: local, transport: transport, secrets: { .none })
        alerts.post(title: "x", body: "y")
        await alerts.flush()
        XCTAssertEqual(local.posts.count, 1)
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
