import XCTest
@testable import Awake

@MainActor
final class RecordingAgentActions: AgentActing {
    var available = true
    var result = PhoneActionResult.done("done")
    private(set) var calls: [String] = []

    func nudge(id: String) async -> PhoneActionResult { calls.append("nudge \(id)"); return result }
    func answer(id: String, text: String) async -> PhoneActionResult { calls.append("answer \(id) \(text)"); return result }
    func pause(id: String) async -> PhoneActionResult { calls.append("pause \(id)"); return result }
    func resume(id: String) async -> PhoneActionResult { calls.append("resume \(id)"); return result }
    func stop(id: String) async -> PhoneActionResult { calls.append("stop \(id)"); return result }
}

/// The phone API over fakes: no sockets, no keychain, no ScreenCaptureKit.
@MainActor
final class PhoneAPIHarness {
    let home = TempHome()
    let clock = TestClock()
    let store = MemoryPhoneDeviceStore()
    let session = FakePhoneSession()
    let locker = RecordingScreenLock()
    let screen = FakeScreenCapture()
    let machine = FakePhoneMachine()
    let agents = RecordingAgentActions()
    let auth: PhoneAuth
    let api: PhoneAPI
    var logLines = ["one", "two", "three"]
    var token = ""
    var device: PhoneDevice?
    private(set) var changes = 0

    init(agentsWired: Bool = true) {
        let clock = self.clock
        auth = PhoneAuth(store: store, queue: KeychainQueue(), clock: { clock.now })
        let lines = LinesBox()
        api = PhoneAPI(
            auth: auth,
            session: session,
            locker: locker,
            screen: screen,
            machine: machine,
            audit: PhoneAuditLog(url: home.paths.auditLog),
            logTail: { count in Array(lines.value.suffix(count)) },
            serverInfo: { ["name": "Test Mac", "port": 7788] },
            clock: { clock.now }
        )
        if agentsWired { api.agents = agents }
        lines.value = logLines
        api.onChange = { [weak self] in self?.changes += 1 }
    }

    final class LinesBox: @unchecked Sendable {
        var value: [String] = []
    }

    func destroy() { home.destroy() }

    /// Pairs a phone through the API itself.
    func pair(name: String = "iPhone") async {
        await auth.load()
        let window = auth.beginPairing()
        let (status, body) = await call("POST", "/api/pair", json: ["code": window.code, "name": name], token: nil)
        XCTAssertEqual(status, 200)
        token = body["token"] as? String ?? ""
        device = auth.devices.last
    }

    func request(_ method: String, _ target: String, json: [String: Any]? = nil, token: String?, contentType: String? = "application/json") -> PhoneRequest {
        let (path, query) = PhoneHTTP.split(target: target)
        var r = PhoneRequest(method: method, path: path, query: query)
        if let token { r.headers["authorization"] = "Bearer \(token)" }
        if method == "POST" {
            if let contentType { r.headers["content-type"] = contentType }
            r.body = json.map { try! JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)
        }
        return r
    }

    func respond(_ request: PhoneRequest, peer: String = "100.64.0.2") async -> PhoneResponse {
        switch await api.handle(request, peer: peer) {
        case let .response(r): return r
        case .events: return PhoneResponse(status: -1, contentType: "events", body: Data())
        }
    }

    @discardableResult
    func call(_ method: String, _ target: String, json: [String: Any]? = nil, token: String?? = .none, peer: String = "100.64.0.2") async -> (Int, [String: Any]) {
        let t: String? = token == .none ? self.token : token!
        let r = await respond(request(method, target, json: json, token: t), peer: peer)
        let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        return (r.status, body)
    }

    var audit: [[String: Any]] {
        guard let text = try? String(contentsOf: home.paths.auditLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    var auditText: String { (try? String(contentsOf: home.paths.auditLog, encoding: .utf8)) ?? "" }
}

@MainActor
final class PhoneAPITests: XCTestCase {
    private var h: PhoneAPIHarness!

    override func setUp() async throws {
        h = PhoneAPIHarness()
    }

    override func tearDown() async throws {
        h.destroy()
        h = nil
    }

    // MARK: Allow-list and auth

    func testUnknownPathsAre404WithOrWithoutAToken() async {
        await h.pair()
        for (method, path) in [("GET", "/api/nope"), ("POST", "/api/unlock"), ("GET", "/config.json"), ("GET", "/api/lock"), ("POST", "/api/status"), ("GET", "/api/agents/x/nudge")] {
            let (withToken, _) = await h.call(method, path)
            XCTAssertEqual(withToken, 404, "\(method) \(path)")
            let (without, _) = await h.call(method, path, token: .some(nil))
            XCTAssertEqual(without, 404, "\(method) \(path)")
        }
    }

    func testEveryAPIRouteNeedsABearerToken() async {
        await h.pair()
        let routes: [(String, String)] = [
            ("GET", "/api/status"), ("GET", "/api/events"), ("GET", "/api/machine"), ("GET", "/api/log"), ("GET", "/api/screenshot"),
            ("GET", "/api/devices"), ("POST", "/api/unpair"), ("POST", "/api/session/start"), ("POST", "/api/session/extend"),
            ("POST", "/api/session/end"), ("POST", "/api/lock"), ("POST", "/api/panic"), ("POST", "/api/agents/a/stop"),
            ("GET", "/api/push/key"), ("POST", "/api/push/subscribe"), ("POST", "/api/push/unsubscribe"), ("POST", "/api/push/test"),
        ]
        for (method, path) in routes {
            let (status, body) = await h.call(method, path, json: ["minutes": 30], token: .some(nil))
            XCTAssertEqual(status, 401, "\(method) \(path)")
            XCTAssertEqual(body["ok"] as? Bool, false)
        }
        XCTAssertTrue(h.session.calls.isEmpty)
        XCTAssertEqual(h.locker.calls, 0)
        XCTAssertTrue(h.screen.calls.isEmpty)
        XCTAssertTrue(h.agents.calls.isEmpty)
    }

    func testAWrongTokenIs401AndAudited() async {
        await h.pair()
        let (status, _) = await h.call("POST", "/api/lock", token: h.token + "x")
        XCTAssertEqual(status, 401)
        XCTAssertEqual(h.locker.calls, 0)
        XCTAssertEqual(h.audit.last?["action"] as? String, "auth")
        XCTAssertEqual(h.audit.last?["result"] as? String, "refused: unknown token")
        XCTAssertFalse(h.auditText.contains(h.token), "tokens are never written to the audit log")
    }

    func testFiveWrongTokensBlockTheAddressEvenForAValidToken() async {
        await h.pair()
        for _ in 0..<5 {
            let (status, _) = await h.call("GET", "/api/status", token: "deadbeef.nope", peer: "100.64.0.66")
            XCTAssertEqual(status, 401)
        }
        let r = await h.respond(h.request("GET", "/api/status", token: h.token), peer: "100.64.0.66")
        XCTAssertEqual(r.status, 429)
        XCTAssertNotNil(r.extraHeaders["Retry-After"])
        let (other, _) = await h.call("GET", "/api/status", peer: "100.64.0.2")
        XCTAssertEqual(other, 200, "another address is unaffected")
        h.clock.advance(301)
        let (after, _) = await h.call("GET", "/api/status", peer: "100.64.0.66")
        XCTAssertEqual(after, 200, "the block lifts after five minutes")
    }

    func testThirtyRequestsInTenSecondsThen429() async {
        await h.pair()
        for i in 0..<30 {
            let (status, _) = await h.call("GET", "/api/status")
            XCTAssertEqual(status, 200, "\(i)")
        }
        let r = await h.respond(h.request("GET", "/api/status", token: h.token))
        XCTAssertEqual(r.status, 429)
        XCTAssertEqual(r.extraHeaders["Retry-After"], "10")
        let (lock, _) = await h.call("POST", "/api/lock")
        XCTAssertEqual(lock, 429, "actions are limited too")
        XCTAssertEqual(h.locker.calls, 0)
        h.clock.advance(10.5)
        let (again, _) = await h.call("GET", "/api/status")
        XCTAssertEqual(again, 200)
    }

    func testPostsMustBeJSON() async {
        await h.pair()
        for type in ["text/plain", "application/x-www-form-urlencoded", nil] as [String?] {
            let r = await h.respond(h.request("POST", "/api/lock", token: h.token, contentType: type))
            XCTAssertEqual(r.status, 415, type ?? "none")
        }
        let pair = await h.respond(h.request("POST", "/api/pair", json: ["code": "000000"], token: nil, contentType: "text/plain"))
        XCTAssertEqual(pair.status, 415, "a cross-site form post cannot even try a code")
        XCTAssertEqual(h.locker.calls, 0)
    }

    func testStaticFilesNeedNoToken() async {
        for path in ["/", "/index.html", "/app.js", "/app.css", "/manifest.webmanifest", "/sw.js", "/icon-180.png", "/icon-192.png", "/icon-512.png", "/apple-touch-icon.png"] {
            let r = await h.respond(h.request("GET", path, token: nil))
            XCTAssertEqual(r.status, 200, path)
            XCTAssertFalse(r.body.isEmpty, path)
        }
    }

    // MARK: Pairing

    func testPairingOverTheAPI() async {
        await h.auth.load()
        let closed = await h.call("POST", "/api/pair", json: ["code": "123456", "name": "iPhone"], token: .some(nil))
        XCTAssertEqual(closed.0, 409)
        XCTAssertTrue((closed.1["error"] as? String)?.contains("Pair phone") == true)

        let window = h.auth.beginPairing()
        let wrongCode = window.code == "000000" ? "111111" : "000000"
        let wrong = await h.call("POST", "/api/pair", json: ["code": wrongCode, "name": "iPhone"], token: .some(nil))
        XCTAssertEqual(wrong.0, 401)
        XCTAssertEqual(wrong.1["attemptsLeft"] as? Int, 4)

        let bad = await h.call("POST", "/api/pair", json: ["name": "iPhone"], token: .some(nil))
        XCTAssertEqual(bad.0, 400)

        let ok = await h.call("POST", "/api/pair", json: ["code": window.code, "name": " Parth's iPhone\n"], token: .some(nil))
        XCTAssertEqual(ok.0, 200)
        let token = ok.1["token"] as? String ?? ""
        XCTAssertEqual((ok.1["device"] as? [String: Any])?["name"] as? String, "Parth's iPhone")
        XCTAssertNotNil(h.auth.authenticate(token))

        let again = await h.call("POST", "/api/pair", json: ["code": window.code, "name": "second"], token: .some(nil))
        XCTAssertEqual(again.0, 409, "one phone per code")

        let results = h.audit.filter { $0["action"] as? String == "pair" }.compactMap { $0["result"] as? String }
        XCTAssertEqual(results, ["refused: pairing not open", "refused: wrong code", "paired", "refused: pairing not open"])
        XCTAssertFalse(h.auditText.contains(window.code), "pairing codes are never written to the audit log")
        XCTAssertFalse(h.auditText.contains(token))
    }

    func testFiveWrongCodesRegenerateAndBlockTheAddress() async {
        await h.auth.load()
        let window = h.auth.beginPairing()
        let wrongCode = window.code == "000000" ? "111111" : "000000"
        var last: (Int, [String: Any]) = (0, [:])
        for _ in 0..<5 {
            last = await h.call("POST", "/api/pair", json: ["code": wrongCode], token: .some(nil), peer: "100.64.0.77")
        }
        XCTAssertEqual(last.0, 401)
        XCTAssertTrue((last.1["error"] as? String)?.contains("new one") == true)
        XCTAssertNotEqual(h.auth.pairingWindow?.code, window.code)
        // The right (new) code from the blocked address is refused unseen.
        let newCode = h.auth.pairingWindow!.code
        let blocked = await h.call("POST", "/api/pair", json: ["code": newCode], token: .some(nil), peer: "100.64.0.77")
        XCTAssertEqual(blocked.0, 429)
        XCTAssertNotNil(h.auth.pairingWindow, "the refused request did not use up the window")
        let fine = await h.call("POST", "/api/pair", json: ["code": newCode], token: .some(nil), peer: "100.64.0.2")
        XCTAssertEqual(fine.0, 200)
    }

    // MARK: Status

    func testStatusCarriesTheSnapshotAndServerInfo() async throws {
        await h.pair()
        h.session.json = Data("{\n  \"active\" : true,\n  \"remainingSeconds\" : 120\n}".utf8)
        let (status, body) = await h.call("GET", "/api/status")
        XCTAssertEqual(status, 200)
        let snapshot = try XCTUnwrap(body["status"] as? [String: Any])
        XCTAssertEqual(snapshot["active"] as? Bool, true)
        XCTAssertEqual(snapshot["remainingSeconds"] as? Int, 120)
        let server = try XCTUnwrap(body["server"] as? [String: Any])
        XCTAssertEqual(server["name"] as? String, "Test Mac")
        XCTAssertEqual(server["presetMinutes"] as? [Int], [30, 60, 120])
        XCTAssertEqual(server["agentActions"] as? Bool, true)
        XCTAssertEqual(server["webPush"] as? Bool, false, "no web push transport yet: the phone hides the card")
        XCTAssertEqual((server["device"] as? [String: Any])?["name"] as? String, "iPhone")
    }

    func testAgentsAndLeasesFromLaterPhasesPassThroughUntouched() async throws {
        await h.pair()
        h.session.json = Data("""
        {"active":true,"agents":[{"id":"a1","kind":"claude","name":"Claude Code","state":"waitingForInput","lastOutputAgeSeconds":42,"repo":"awake","tmuxTarget":"main:0.1","waitingPrompt":"Proceed? (y/n)"}],
         "leases":[{"id":"l1","owner":"codex","reason":"refactor billing","expiresAt":"2026-11-15T10:00:00Z"}]}
        """.utf8)
        let (_, body) = await h.call("GET", "/api/status")
        let snapshot = try XCTUnwrap(body["status"] as? [String: Any])
        let agents = try XCTUnwrap(snapshot["agents"] as? [[String: Any]])
        XCTAssertEqual(agents.first?["waitingPrompt"] as? String, "Proceed? (y/n)")
        XCTAssertEqual(agents.first?["state"] as? String, "waitingForInput")
        let leases = try XCTUnwrap(snapshot["leases"] as? [[String: Any]])
        XCTAssertEqual(leases.first?["reason"] as? String, "refactor billing")
    }

    func testTheStatusBodyIsOneLineForTheEventStream() async {
        await h.pair()
        h.session.json = Data("{\n  \"active\" : false\n}".utf8)
        let body = h.api.statusBody(device: h.device)
        XCTAssertFalse(body.contains(UInt8(ascii: "\n")))
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: body))
    }

    func testEventsReplyNamesTheDevice() async {
        await h.pair()
        guard case let .events(deviceID) = await h.api.handle(h.request("GET", "/api/events", token: h.token), peer: "100.64.0.2") else {
            return XCTFail("expected an event stream")
        }
        XCTAssertEqual(deviceID, h.device?.id)
        XCTAssertEqual(h.audit.last?["action"] as? String, "events")
    }

    // MARK: Session

    func testSessionStartExtendEnd() async {
        await h.pair()
        let start = await h.call("POST", "/api/session/start", json: ["minutes": 90])
        XCTAssertEqual(start.0, 200)
        XCTAssertEqual(start.1["ok"] as? Bool, true)
        let extend = await h.call("POST", "/api/session/extend", json: ["minutes": 30])
        XCTAssertEqual(extend.0, 200)
        let end = await h.call("POST", "/api/session/end")
        XCTAssertEqual(end.0, 200)
        XCTAssertEqual(h.session.calls, ["start 90", "extend 30", "end"])
        XCTAssertEqual(h.changes, 4, "pair, start, extend and end each push the status")
        let actions = h.audit.compactMap { $0["action"] as? String }
        XCTAssertEqual(Array(actions.suffix(3)), ["session.start", "session.extend", "session.end"])
        let startEntry = h.audit.first { $0["action"] as? String == "session.start" }
        XCTAssertEqual((startEntry?["args"] as? [String: String])?["minutes"], "90")
        XCTAssertEqual(startEntry?["device"] as? String, "iPhone")
        XCTAssertEqual(startEntry?["address"] as? String, "100.64.0.2")
        XCTAssertEqual(startEntry?["result"] as? String, "ok: Session started for 30 min.")
    }

    func testMinutesMustBeAWholeNumberInRange() async {
        await h.pair()
        h.session.maxMinutes = 600
        for bad in [["minutes": 0], ["minutes": -5], ["minutes": 601], ["minutes": 30.5], ["minutes": "30"], ["minutes": true], [:], ["minutes": NSNull()]] as [[String: Any]] {
            let (status, _) = await h.call("POST", "/api/session/start", json: bad)
            XCTAssertEqual(status, 400, "\(bad)")
            let (extend, _) = await h.call("POST", "/api/session/extend", json: bad)
            XCTAssertEqual(extend, 400, "\(bad)")
            h.clock.advance(11)
        }
        XCTAssertTrue(h.session.calls.isEmpty)
        let (ok, _) = await h.call("POST", "/api/session/start", json: ["minutes": 600])
        XCTAssertEqual(ok, 200)
    }

    func testASessionThatDoesNotStartIsA409WithTheReason() async {
        await h.pair()
        h.session.startResult = .failed("could not arm the recovery agent")
        let (status, body) = await h.call("POST", "/api/session/start", json: ["minutes": 30])
        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "could not arm the recovery agent")
        XCTAssertEqual(h.audit.last?["result"] as? String, "failed: could not arm the recovery agent")
    }

    // MARK: Lock and panic

    func testLockUsesTheScreenLock() async {
        await h.pair()
        let (status, _) = await h.call("POST", "/api/lock")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(h.locker.calls, 1)
        h.locker.failWith = "SACLockScreenImmediate returned 1"
        let (failed, body) = await h.call("POST", "/api/lock")
        XCTAssertEqual(failed, 500)
        XCTAssertTrue((body["error"] as? String)?.contains("SACLockScreenImmediate returned 1") == true)
        XCTAssertEqual(h.audit.suffix(2).compactMap { ($0["result"] as? String)?.prefix(6) }.map(String.init), ["ok: Th", "failed"])
    }

    func testPanicLocksAndEndsTheSession() async {
        await h.pair()
        let (status, body) = await h.call("POST", "/api/panic")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["ok"] as? Bool, true)
        XCTAssertEqual(h.locker.calls, 1)
        XCTAssertEqual(h.session.calls, ["end"])
        XCTAssertEqual(h.audit.last?["action"] as? String, "panic")
    }

    func testPanicStillEndsTheSessionWhenTheLockFails() async {
        await h.pair()
        h.locker.failWith = "no login framework"
        let (status, body) = await h.call("POST", "/api/panic")
        XCTAssertEqual(status, 500)
        XCTAssertEqual(h.session.calls, ["end"], "a failed lock does not stop the end")
        XCTAssertEqual((body["lock"] as? [String: Any])?["ok"] as? Bool, false)
        XCTAssertEqual((body["session"] as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertTrue((body["error"] as? String)?.contains("no login framework") == true)
    }

    func testPanicStillLocksWhenTheEndFails() async {
        await h.pair()
        h.session.endResult = .failed("the recovery lock is held")
        let (status, body) = await h.call("POST", "/api/panic")
        XCTAssertEqual(status, 500)
        XCTAssertEqual(h.locker.calls, 1)
        XCTAssertEqual((body["lock"] as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertEqual(body["error"] as? String, "the recovery lock is held")
    }

    // MARK: Screenshot

    func testScreenshotReturnsTheJPEG() async {
        await h.pair()
        let r = await h.respond(h.request("GET", "/api/screenshot?display=main&width=640", token: h.token))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.contentType, "image/jpeg")
        XCTAssertEqual(r.body, Data([0xFF, 0xD8, 0xFF, 0xD9]))
        XCTAssertEqual(h.screen.calls.first?.display, "main")
        XCTAssertEqual(h.screen.calls.first?.maxWidth, 640)
        XCTAssertEqual(h.audit.last?["result"] as? String, "ok: 4 bytes")
    }

    func testScreenshotDefaults() async {
        await h.pair()
        _ = await h.respond(h.request("GET", "/api/screenshot", token: h.token))
        XCTAssertEqual(h.screen.calls.first?.display, "main")
        XCTAssertEqual(h.screen.calls.first?.maxWidth, 1280)
    }

    func testScreenshotWithoutPermissionIsA403ThatSaysWhatToDo() async {
        await h.pair()
        h.screen.granted = false
        let (status, body) = await h.call("GET", "/api/screenshot")
        XCTAssertEqual(status, 403)
        XCTAssertEqual(body["permission"] as? String, "screenRecording")
        XCTAssertTrue((body["error"] as? String)?.contains("Screen & System Audio Recording") == true)
        XCTAssertTrue(h.screen.calls.isEmpty, "ScreenCaptureKit is not asked, so no prompt appears on the Mac")
        h.screen.granted = true
        h.screen.result = .failure(.permissionDenied)
        let (late, _) = await h.call("GET", "/api/screenshot")
        XCTAssertEqual(late, 403, "a grant withdrawn between the check and the capture")
    }

    func testScreenshotArgumentsAreChecked() async {
        await h.pair()
        for bad in ["width=100", "width=5000", "width=abc", "display=../etc", "display=99", "display=-1"] {
            let (status, _) = await h.call("GET", "/api/screenshot?\(bad)")
            XCTAssertEqual(status, 400, bad)
        }
        XCTAssertTrue(h.screen.calls.isEmpty)
        let (second, _) = await h.call("GET", "/api/screenshot?display=1&width=320")
        XCTAssertEqual(second, 200)
        h.screen.result = .failure(.noSuchDisplay)
        let (missing, _) = await h.call("GET", "/api/screenshot?display=3")
        XCTAssertEqual(missing, 404)
        h.screen.result = .failure(.failed("stream stopped"))
        let (failed, body) = await h.call("GET", "/api/screenshot")
        XCTAssertEqual(failed, 500)
        XCTAssertTrue((body["error"] as? String)?.contains("stream stopped") == true)
    }

    // MARK: Log, machine, devices

    func testLogTail() async {
        await h.pair()
        let (status, body) = await h.call("GET", "/api/log?lines=2")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["lines"] as? [String], ["two", "three"])
        let (all, allBody) = await h.call("GET", "/api/log")
        XCTAssertEqual(all, 200)
        XCTAssertEqual((allBody["lines"] as? [String])?.count, 3)
        for bad in ["0", "1001", "x", "-1"] {
            let (s, _) = await h.call("GET", "/api/log?lines=\(bad)")
            XCTAssertEqual(s, 400, bad)
        }
    }

    func testMachineReportsReadingsAndLeavesUnknownsOut() async throws {
        await h.pair()
        h.machine.info = PhoneMachineInfo(hostName: "Test Mac", batteryPercent: 64, isCharging: true, chargerDraining: true, batteryWatts: -3.5, adapterWatts: 30, thermalState: "fair", cpuSpeedLimit: 80, batteryTemperatureC: nil, memoryPressure: "warning", freeDiskBytes: 42_000_000_000, networkType: "wifi", wifiSSID: nil, tailscaleIPv4: "100.101.102.103", lidClosed: true, lowPowerMode: false, uptimeSeconds: 3600)
        let (status, body) = await h.call("GET", "/api/machine")
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body["batteryPercent"] as? Int, 64)
        XCTAssertEqual(body["chargerDraining"] as? Bool, true)
        XCTAssertEqual(body["batteryWatts"] as? Double, -3.5)
        XCTAssertEqual(body["cpuSpeedLimit"] as? Int, 80)
        XCTAssertEqual(body["memoryPressure"] as? String, "warning")
        XCTAssertEqual(body["tailscaleIPv4"] as? String, "100.101.102.103")
        XCTAssertNil(body["batteryTemperatureC"], "a reading that was not taken is absent, not zero")
        XCTAssertNil(body["wifiSSID"])
        XCTAssertEqual(h.machine.reads, 1)
    }

    func testDevicesListsWhoIsPairedWithoutSecrets() async throws {
        await h.pair(name: "iPhone")
        let first = h.token
        await h.pair(name: "iPad")
        let (status, body) = await h.call("GET", "/api/devices", token: first)
        XCTAssertEqual(status, 200)
        let devices = try XCTUnwrap(body["devices"] as? [[String: Any]])
        XCTAssertEqual(devices.map { $0["name"] as? String }, ["iPhone", "iPad"])
        XCTAssertEqual(devices.map { $0["current"] as? Bool }, [true, false])
        for d in devices {
            XCTAssertNil(d["hash"])
            XCTAssertNil(d["salt"])
        }
    }

    func testUnpairRevokesOnlyTheCallingPhone() async {
        await h.pair(name: "iPhone")
        let first = h.token
        await h.pair(name: "iPad")
        let second = h.token
        let (status, _) = await h.call("POST", "/api/unpair", token: first)
        XCTAssertEqual(status, 200)
        let (gone, _) = await h.call("GET", "/api/status", token: first)
        XCTAssertEqual(gone, 401)
        let (still, _) = await h.call("GET", "/api/status", token: second)
        XCTAssertEqual(still, 200)
    }

    // MARK: Agents

    func testAgentActionsGoToAgentActing() async {
        await h.pair()
        for action in ["nudge", "pause", "resume", "stop"] {
            let (status, body) = await h.call("POST", "/api/agents/claude-1/\(action)")
            XCTAssertEqual(status, 200, action)
            XCTAssertEqual(body["ok"] as? Bool, true)
        }
        let (answer, _) = await h.call("POST", "/api/agents/claude-1/answer", json: ["text": "y"])
        XCTAssertEqual(answer, 200)
        XCTAssertEqual(h.agents.calls, ["nudge claude-1", "pause claude-1", "resume claude-1", "stop claude-1", "answer claude-1 y"])
    }

    func testAnswerTextIsNeverWrittenToTheAuditLog() async {
        await h.pair()
        let (status, _) = await h.call("POST", "/api/agents/a/answer", json: ["text": "hunter2-secret"])
        XCTAssertEqual(status, 200)
        XCTAssertFalse(h.auditText.contains("hunter2"))
        XCTAssertEqual((h.audit.last?["args"] as? [String: String])?["text"], "14 characters")
        XCTAssertEqual(h.audit.last?["action"] as? String, "agent.answer")
    }

    func testAnswerNeedsText() async {
        await h.pair()
        for bad in [[:], ["text": ""], ["text": 5], ["text": String(repeating: "a", count: 4001)]] as [[String: Any]] {
            let (status, _) = await h.call("POST", "/api/agents/a/answer", json: bad)
            XCTAssertEqual(status, 400)
        }
        XCTAssertTrue(h.agents.calls.isEmpty)
    }

    func testUnknownAgentActionsAre404() async {
        await h.pair()
        for action in ["kill", "exec", "NUDGE", "answer%2F.."] {
            let (status, _) = await h.call("POST", "/api/agents/a/\(action)")
            XCTAssertEqual(status, 404, action)
        }
        XCTAssertTrue(h.agents.calls.isEmpty)
    }

    func testAnAgentActionThatFailsIsA409() async {
        await h.pair()
        h.agents.result = .failed("that agent has exited")
        let (status, body) = await h.call("POST", "/api/agents/a/nudge")
        XCTAssertEqual(status, 409)
        XCTAssertEqual(body["error"] as? String, "that agent has exited")
    }

    func testWithoutPhaseTwoEveryAgentActionSaysNotAvailableYet() async {
        let bare = PhoneAPIHarness(agentsWired: false)
        defer { bare.destroy() }
        await bare.pair()
        let (statusCode, statusBody) = await bare.call("GET", "/api/status")
        XCTAssertEqual(statusCode, 200)
        XCTAssertEqual((statusBody["server"] as? [String: Any])?["agentActions"] as? Bool, false)
        for action in AgentAction.allCases {
            let (status, body) = await bare.call("POST", "/api/agents/a/\(action.rawValue)", json: ["text": "y"])
            XCTAssertEqual(status, 501, action.rawValue)
            XCTAssertEqual(body["error"] as? String, "not available yet")
        }
    }

    // MARK: Push placeholders

    func testPushIsUnavailableUntilWired() async {
        await h.pair()
        let (key, _) = await h.call("GET", "/api/push/key")
        XCTAssertEqual(key, 503)
        let (subscribe, _) = await h.call("POST", "/api/push/subscribe", json: ["endpoint": "https://push.example/x"])
        XCTAssertEqual(subscribe, 400)
    }

    func testWholeNumber() {
        XCTAssertEqual(PhoneAPI.wholeNumber(30), 30)
        XCTAssertEqual(PhoneAPI.wholeNumber(NSNumber(value: 30.0)), 30)
        XCTAssertNil(PhoneAPI.wholeNumber(30.5))
        XCTAssertNil(PhoneAPI.wholeNumber("30"))
        XCTAssertNil(PhoneAPI.wholeNumber(true))
        XCTAssertNil(PhoneAPI.wholeNumber(nil))
        XCTAssertNil(PhoneAPI.wholeNumber(1e12))
    }
}

final class PhoneAuditLogTests: XCTestCase {
    func testEachEntryIsOneJSONLineInAnOwnerOnlyFile() throws {
        let home = TempHome()
        defer { home.destroy() }
        let log = PhoneAuditLog(url: home.paths.auditLog)
        XCTAssertEqual(home.paths.auditLog.lastPathComponent, "audit.log")
        XCTAssertEqual(home.paths.auditLog.deletingLastPathComponent().path, home.paths.appSupport.path)
        log.record(.init(time: Date(timeIntervalSince1970: 1_800_000_000), device: "iPhone", deviceID: "abcd", address: "100.64.0.2", action: "lock", args: [:], result: "ok"))
        log.record(.init(time: Date(timeIntervalSince1970: 1_800_000_060), device: "-", deviceID: nil, address: "100.64.0.9", action: "pair", args: ["name": "x\ny"], result: "refused: wrong code"))
        let text = try String(contentsOf: home.paths.auditLog, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count, 3, "two entries and the final newline: \(text)")
        XCTAssertEqual(String(lines[0]), "{\"action\":\"lock\",\"address\":\"100.64.0.2\",\"args\":{},\"device\":\"iPhone\",\"deviceID\":\"abcd\",\"result\":\"ok\",\"time\":\"2027-01-15T08:00:00Z\"}")
        XCTAssertTrue(lines[1].contains("\"name\":\"x\\ny\""), "a newline in an argument cannot forge a second entry")
        var info = stat()
        XCTAssertEqual(stat(home.paths.auditLog.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }

    func testRotatesPastTheCap() throws {
        let home = TempHome()
        defer { home.destroy() }
        XCTAssertEqual(PhoneAuditLog.maxBytes, 5 * 1024 * 1024)
        let log = PhoneAuditLog(url: home.paths.auditLog, maxBytes: 300)
        let entry = PhoneAuditLog.Entry(time: Date(timeIntervalSince1970: 1_800_000_000), device: "iPhone", deviceID: "abcd", address: "100.64.0.2", action: "screenshot", args: ["width": "1280"], result: "ok: 1000 bytes")
        for _ in 0..<4 { log.record(entry) }
        let rotated = OwnerOnly.rotated(home.paths.auditLog)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path), "audit.log.1 exists")
        let current = try String(contentsOf: home.paths.auditLog, encoding: .utf8).split(separator: "\n").count
        let previous = try String(contentsOf: rotated, encoding: .utf8).split(separator: "\n").count
        XCTAssertEqual(current + previous, 4, "no entry is lost in the rotation")
        XCTAssertGreaterThanOrEqual(current, 1, "the entry that found the log oversized starts the new file")
        XCTAssertLessThan(current, 4)
        var info = stat()
        XCTAssertEqual(stat(rotated.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
    }
}
