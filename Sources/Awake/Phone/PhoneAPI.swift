import Foundation

/// What the server does with a request once the API has looked at it.
enum PhoneReply: Sendable {
    case response(PhoneResponse)
    /// Keep the connection and stream status events to this device.
    case events(deviceID: String)
}

/// Phase 3: the phone's API. An allow-list: the routes added in `init`
/// and nothing else. Every route under `/api/` except the pairing call
/// needs a paired phone's bearer token; every action is written to the
/// audit log. No sockets here: the server hands in a parsed request and
/// the address it came from.
@MainActor
final class PhoneAPI {
    enum Route: Sendable, Equatable {
        case asset(PhoneWebAsset)
        case pair
        case status
        case events
        case machine
        case log
        case screenshot
        case devices
        case unpair
        case sessionStart
        case sessionExtend
        case sessionEnd
        case lock
        case panic
        case agentAction
        case pushKey
        case pushSubscribe
        case pushUnsubscribe
        case pushTest
    }

    static let screenshotWidths = 320...2560
    static let defaultScreenshotWidth = 1280
    static let logLines = 1...1000
    static let defaultLogLines = 200
    /// The longest answer typed for an agent prompt.
    static let maxAnswerLength = 4000

    let auth: PhoneAuth
    private let session: any PhoneSessionControlling
    private let locker: any ScreenLocking
    private let screen: any ScreenCapturing
    private let machine: any PhoneMachineProbing
    var agents: any AgentActing
    var push: any PhonePushSubscribing
    private let audit: PhoneAuditLog
    private let logTail: @Sendable (Int) -> [String]
    /// Name, version, port and Tailscale state, for `/api/status`.
    var serverInfoProvider: @MainActor () -> [String: Any]
    private let clock: @Sendable () -> Date
    private let router: PhoneRouter<Route>
    /// Called after an action that changes what the status shows, so the
    /// event stream pushes the new snapshot at once.
    var onChange: (@MainActor () -> Void)?

    init(
        auth: PhoneAuth,
        session: any PhoneSessionControlling,
        locker: any ScreenLocking,
        screen: any ScreenCapturing,
        machine: any PhoneMachineProbing,
        agents: any AgentActing = UnavailableAgentActions(),
        push: any PhonePushSubscribing = UnavailablePhonePush(),
        audit: PhoneAuditLog,
        logTail: @escaping @Sendable (Int) -> [String],
        serverInfo: @escaping @MainActor () -> [String: Any] = { [:] },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.auth = auth
        self.session = session
        self.locker = locker
        self.screen = screen
        self.machine = machine
        self.agents = agents
        self.push = push
        self.audit = audit
        self.logTail = logTail
        self.serverInfoProvider = serverInfo
        self.clock = clock
        self.router = Self.makeRouter()
    }

    /// The whole surface of the server.
    nonisolated static func makeRouter() -> PhoneRouter<Route> {
        var r = PhoneRouter<Route>()
        for asset in PhoneWebAsset.allCases {
            for path in asset.paths { r.add("GET", path, .asset(asset)) }
        }
        r.add("POST", "/api/pair", .pair)
        r.add("GET", "/api/status", .status)
        r.add("GET", "/api/events", .events)
        r.add("GET", "/api/machine", .machine)
        r.add("GET", "/api/log", .log)
        r.add("GET", "/api/screenshot", .screenshot)
        r.add("GET", "/api/devices", .devices)
        r.add("POST", "/api/unpair", .unpair)
        r.add("POST", "/api/session/start", .sessionStart)
        r.add("POST", "/api/session/extend", .sessionExtend)
        r.add("POST", "/api/session/end", .sessionEnd)
        r.add("POST", "/api/lock", .lock)
        r.add("POST", "/api/panic", .panic)
        r.add("POST", "/api/agents/{id}/{action}", .agentAction)
        r.add("GET", "/api/push/key", .pushKey)
        r.add("POST", "/api/push/subscribe", .pushSubscribe)
        r.add("POST", "/api/push/unsubscribe", .pushUnsubscribe)
        r.add("POST", "/api/push/test", .pushTest)
        return r
    }

    /// The status the phone shows: the snapshot plus what it needs to know
    /// about the server, as compact JSON. `/api/status` and every event
    /// carry exactly this.
    func statusBody(device: PhoneDevice? = nil) -> Data {
        var info = serverInfoProvider()
        info["presetMinutes"] = session.presetMinutes
        info["maxMinutes"] = session.maxMinutes
        info["agentActions"] = agents.available
        info["time"] = Self.iso(clock())
        if let device { info["device"] = ["id": device.id, "name": device.name] }
        let server = (try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let status = PhoneHTTP.compactJSON(session.statusJSON()) ?? Data("null".utf8)
        return Data("{\"server\":".utf8) + server + Data(",\"status\":".utf8) + status + Data("}".utf8)
    }

    func handle(_ request: PhoneRequest, peer: String) async -> PhoneReply {
        guard let match = router.match(method: request.method, path: request.path) else {
            return .response(.notFound)
        }
        if case let .asset(asset) = match.route {
            return .response(asset.response)
        }
        // Everything below is the API. An address that keeps failing to
        // sign in is refused before anything is compared.
        if let wait = auth.blockRemaining(address: peer) {
            return .response(Self.tooMany("too many failed sign-ins from this address; try again later", retryAfter: wait))
        }
        if request.method == "POST", !request.hasJSONContentType {
            return .response(.error(415, "POST bodies must be application/json"))
        }
        if match.route == .pair {
            return .response(await pair(request, peer: peer))
        }
        guard let token = request.bearerToken else {
            return .response(.error(401, "this phone is not paired"))
        }
        guard let device = auth.authenticate(token) else {
            let blocked = auth.recordFailure(address: peer)
            record(nil, peer, "auth", [:], blocked ? "refused: unknown token; address blocked" : "refused: unknown token")
            return .response(.error(401, "this phone is not paired"))
        }
        guard auth.allowRequest(device: device) else {
            return .response(Self.tooMany("too many requests; slow down", retryAfter: PhoneRateLimiter.requestWindow))
        }
        switch match.route {
        case .asset, .pair:
            return .response(.notFound)
        case .status:
            return .response(.json(statusBody(device: device)))
        case .events:
            record(device, peer, "events", [:], "stream opened")
            return .events(deviceID: device.id)
        case .machine:
            return .response(await machineInfo())
        case .log:
            return .response(log(request, device, peer))
        case .screenshot:
            return .response(await screenshot(request, device, peer))
        case .devices:
            return .response(devices(current: device))
        case .unpair:
            let problem = await auth.forget(id: device.id)
            record(device, peer, "unpair", [:], problem ?? "ok")
            return .response(problem.map { .error(500, $0) } ?? .ok("This phone is no longer paired."))
        case .sessionStart:
            return .response(await sessionAction(request, device, peer, "session.start") { await self.session.start(minutes: $0) })
        case .sessionExtend:
            return .response(await sessionAction(request, device, peer, "session.extend") { await self.session.extend(minutes: $0) })
        case .sessionEnd:
            let result = await session.end()
            record(device, peer, "session.end", [:], Self.describe(result))
            onChange?()
            return .response(Self.response(result, failure: 409))
        case .lock:
            let result = lock()
            record(device, peer, "lock", [:], Self.describe(result))
            return .response(Self.response(result, failure: 500))
        case .panic:
            return .response(await panic(device, peer))
        case .agentAction:
            return .response(await agentAction(request, match.parameters, device, peer))
        case .pushKey:
            guard let key = await push.publicKey() else { return .response(.error(503, "web push is not available")) }
            return .response(.object(["ok": true, "publicKey": key]))
        case .pushSubscribe:
            guard let body = Self.jsonObject(request.body) else { return .response(.error(400, "the body is not a JSON object")) }
            let result = await push.subscribe(deviceID: device.id, subscription: body)
            record(device, peer, "push.subscribe", [:], Self.describe(result))
            return .response(Self.response(result, failure: 400))
        case .pushUnsubscribe:
            let result = await push.unsubscribe(deviceID: device.id)
            record(device, peer, "push.unsubscribe", [:], Self.describe(result))
            return .response(Self.response(result, failure: 400))
        case .pushTest:
            let result = await push.sendTest(deviceID: device.id)
            record(device, peer, "push.test", [:], Self.describe(result))
            return .response(Self.response(result, failure: 502))
        }
    }

    // MARK: Pairing

    private func pair(_ request: PhoneRequest, peer: String) async -> PhoneResponse {
        guard let body = Self.jsonObject(request.body), let code = body["code"] as? String else {
            return .error(400, "send {\"code\": \"123456\", \"name\": \"iPhone\"}")
        }
        let name = PhoneToken.cleanName(body["name"] as? String ?? "")
        switch await auth.pair(code: code, name: name) {
        case let .paired(token, device):
            record(device, peer, "pair", ["name": device.name], "paired")
            Log.info("phone app: paired \(device.name) (\(device.id))")
            onChange?()
            return .object(["ok": true, "token": token, "device": ["id": device.id, "name": device.name]])
        case let .notSaved(problem):
            record(nil, peer, "pair", ["name": name], "refused: \(problem)")
            return .error(500, problem)
        case let .refused(outcome):
            switch outcome {
            case .accepted:
                return .error(500, "pairing failed")
            case let .wrong(attemptsLeft):
                let blocked = auth.recordFailure(address: peer)
                record(nil, peer, "pair", ["name": name], blocked ? "refused: wrong code; address blocked" : "refused: wrong code")
                return .error(401, "That code is not the one on the Mac.", extra: ["attemptsLeft": attemptsLeft])
            case .regenerated:
                let blocked = auth.recordFailure(address: peer)
                record(nil, peer, "pair", ["name": name], blocked ? "refused: wrong code; new code issued; address blocked" : "refused: wrong code; new code issued")
                return .error(401, "Too many wrong codes. The Mac now shows a new one.", extra: ["attemptsLeft": PhonePairing.maxAttempts])
            case .expired:
                record(nil, peer, "pair", ["name": name], "refused: code expired")
                return .error(409, "That code has expired. On the Mac, choose Pair phone\u{2026} again.")
            case .notOpen:
                record(nil, peer, "pair", ["name": name], "refused: pairing not open")
                return .error(409, "Pairing is not open. On the Mac, open Awake's Settings and choose Pair phone\u{2026}.")
            }
        }
    }

    // MARK: Reads

    private func machineInfo() async -> PhoneResponse {
        let info = await machine.read()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(info) else { return .error(500, "the machine readings could not be encoded") }
        return .json(data)
    }

    private func log(_ request: PhoneRequest, _ device: PhoneDevice, _ peer: String) -> PhoneResponse {
        var count = Self.defaultLogLines
        if let raw = request.query["lines"] {
            guard let n = Int(raw), Self.logLines.contains(n) else {
                return .error(400, "lines must be \(Self.logLines.lowerBound) to \(Self.logLines.upperBound)")
            }
            count = n
        }
        let lines = logTail(count)
        record(device, peer, "log", ["lines": "\(count)"], "ok: \(lines.count) lines")
        return .object(["ok": true, "lines": lines])
    }

    private func screenshot(_ request: PhoneRequest, _ device: PhoneDevice, _ peer: String) async -> PhoneResponse {
        let display = request.query["display"] ?? "main"
        guard display == "main" || (Int(display).map { (0..<16).contains($0) } ?? false) else {
            return .error(400, "display must be main or a display number")
        }
        var width = Self.defaultScreenshotWidth
        if let raw = request.query["width"] {
            guard let n = Int(raw), Self.screenshotWidths.contains(n) else {
                return .error(400, "width must be \(Self.screenshotWidths.lowerBound) to \(Self.screenshotWidths.upperBound)")
            }
            width = n
        }
        let args = ["display": display, "width": "\(width)"]
        guard screen.permissionGranted() else {
            record(device, peer, "screenshot", args, "refused: Screen Recording not granted")
            return Self.screenRecordingDenied
        }
        do {
            let jpeg = try await screen.captureJPEG(display: display, maxWidth: width)
            record(device, peer, "screenshot", args, "ok: \(jpeg.count) bytes")
            return PhoneResponse(status: 200, contentType: "image/jpeg", body: jpeg)
        } catch ScreenCaptureError.permissionDenied {
            record(device, peer, "screenshot", args, "refused: Screen Recording not granted")
            return Self.screenRecordingDenied
        } catch ScreenCaptureError.noSuchDisplay {
            record(device, peer, "screenshot", args, "failed: no such display")
            return .error(404, "There is no such display.")
        } catch {
            let why = (error as? ScreenCaptureError).map { if case let .failed(text) = $0 { return text } else { return "\($0)" } } ?? error.localizedDescription
            record(device, peer, "screenshot", args, "failed: \(why)")
            return .error(500, "The screen could not be captured: \(why)")
        }
    }

    static let screenRecordingDenied = PhoneResponse.error(
        403,
        "Awake is not allowed to record the screen. On the Mac: System Settings > Privacy & Security > Screen & System Audio Recording, turn on Awake, then quit and reopen it.",
        extra: ["permission": "screenRecording"]
    )

    private func devices(current: PhoneDevice) -> PhoneResponse {
        let list: [[String: Any]] = auth.devices.map { d in
            var o: [String: Any] = ["id": d.id, "name": d.name, "createdAt": Self.iso(d.createdAt), "current": d.id == current.id]
            if let seen = d.lastSeenAt { o["lastSeenAt"] = Self.iso(seen) }
            return o
        }
        return .object(["ok": true, "devices": list])
    }

    // MARK: Actions

    private func sessionAction(_ request: PhoneRequest, _ device: PhoneDevice, _ peer: String, _ action: String, _ run: (Int) async -> PhoneActionResult) async -> PhoneResponse {
        guard let body = Self.jsonObject(request.body), let minutes = Self.wholeNumber(body["minutes"]) else {
            return .error(400, "send {\"minutes\": 30}")
        }
        guard minutes >= 1, minutes <= session.maxMinutes else {
            record(device, peer, action, ["minutes": "\(minutes)"], "refused: out of range")
            return .error(400, "minutes must be 1 to \(session.maxMinutes)")
        }
        let result = await run(minutes)
        record(device, peer, action, ["minutes": "\(minutes)"], Self.describe(result))
        onChange?()
        return Self.response(result, failure: 409)
    }

    private func lock() -> PhoneActionResult {
        do {
            try locker.lock()
            return .done("The Mac's screen is locked.")
        } catch {
            return .failed("The screen could not be locked: \(error)")
        }
    }

    /// Lock first, since it is instant and the reason for a panic is
    /// usually someone at the Mac; then end the session, which resumes
    /// every app Awake froze and undoes the rest. Both are attempted
    /// whatever the other did, and both results are reported.
    private func panic(_ device: PhoneDevice, _ peer: String) async -> PhoneResponse {
        let locked = lock()
        let ended = await session.end()
        let ok = locked.ok && ended.ok
        record(device, peer, "panic", [:], "lock: \(Self.describe(locked)); session: \(Self.describe(ended))")
        onChange?()
        var body: [String: Any] = [
            "ok": ok,
            "lock": ["ok": locked.ok, "message": locked.message],
            "session": ["ok": ended.ok, "message": ended.message],
        ]
        if ok {
            body["message"] = "Locked. \(ended.message)"
        } else {
            body["error"] = [locked, ended].filter { !$0.ok }.map(\.message).joined(separator: " ")
        }
        return .object(body, status: ok ? 200 : 500)
    }

    private func agentAction(_ request: PhoneRequest, _ parameters: [String: String], _ device: PhoneDevice, _ peer: String) async -> PhoneResponse {
        guard let id = parameters["id"], let raw = parameters["action"], let action = AgentAction(rawValue: raw) else {
            return .notFound
        }
        var args = ["id": id]
        let result: PhoneActionResult
        switch action {
        case .nudge: result = await agents.nudge(id: id)
        case .pause: result = await agents.pause(id: id)
        case .resume: result = await agents.resume(id: id)
        case .stop: result = await agents.stop(id: id)
        case .answer:
            guard let body = Self.jsonObject(request.body), let text = body["text"] as? String, !text.isEmpty else {
                return .error(400, "send {\"text\": \"\u{2026}\"}")
            }
            guard text.count <= Self.maxAnswerLength else {
                return .error(400, "the answer is longer than \(Self.maxAnswerLength) characters")
            }
            // The answer may be a password or a 2FA code: its length is
            // logged, its text is not.
            args["text"] = "\(text.count) characters"
            result = await agents.answer(id: id, text: text)
        }
        record(device, peer, "agent.\(action.rawValue)", args, Self.describe(result))
        onChange?()
        if !agents.available {
            return .error(501, result.message)
        }
        return Self.response(result, failure: 409)
    }

    // MARK: Helpers

    private func record(_ device: PhoneDevice?, _ peer: String, _ action: String, _ args: [String: String], _ result: String) {
        audit.record(PhoneAuditLog.Entry(time: clock(), device: device?.name ?? "-", deviceID: device?.id, address: peer, action: action, args: args, result: result))
    }

    nonisolated static func describe(_ result: PhoneActionResult) -> String {
        (result.ok ? "ok: " : "failed: ") + result.message
    }

    nonisolated static func response(_ result: PhoneActionResult, failure: Int) -> PhoneResponse {
        result.ok ? .ok(result.message) : .error(failure, result.message)
    }

    nonisolated static func tooMany(_ message: String, retryAfter: TimeInterval) -> PhoneResponse {
        var r = PhoneResponse.error(429, message)
        r.extraHeaders["Retry-After"] = "\(max(1, Int(retryAfter.rounded(.up))))"
        return r
    }

    nonisolated static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A JSON number that is a whole number (30, not 30.5, not "30", not true).
    nonisolated static func wholeNumber(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let d = number.doubleValue
        guard d.isFinite, d == d.rounded(), abs(d) < 1e9 else { return nil }
        return Int(d)
    }

    nonisolated static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
