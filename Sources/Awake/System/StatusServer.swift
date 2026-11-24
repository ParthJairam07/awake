import AwakeLeaseKit
import Foundation
import Network

/// Phase 1: the menu's status as JSON, for dashboards (Raycast,
/// SketchyBar) and, in phase 3, the phone. Written to status.json on every
/// change and served, when `Config.statusPort` is set, on
/// `http://127.0.0.1:<port>/status.json`. Loopback only: nothing listens
/// on a network interface until the phone pairing of phase 3.
struct StatusSnapshot: Codable, Equatable, Sendable {
    var updatedAt: Date
    var active: Bool
    var startedAt: Date?
    var endsAt: Date?
    var remainingSeconds: Int?
    var lidClosed: Bool
    var lidOnDesk: Bool
    /// False when the lid state cannot be read (a desktop, a virtual
    /// machine): `lidClosed` is then no reading, and the lid is unknown,
    /// not open. Declared with a default so a status.json from before
    /// this key reads as before.
    var lidKnown: Bool = true
    var batteryPercent: Int?
    var isCharging: Bool
    var chargerDraining: Bool
    /// False on a Mac with no battery (a desktop, a virtual machine): it
    /// is on mains power, and `isCharging` says nothing. Declared with a
    /// default so a status.json from before this key reads as before.
    var hasBattery: Bool = true
    var thermalState: String
    var lowPowerSetByUs: Bool
    var wifiSSID: String?
    var lastOutageSeconds: Int?
    var frozenCount: Int
    var dockerPaused: Bool
    /// Phase 2: the agents Awake tracks, oldest first. Empty when agent
    /// tracking is off or no session runs.
    var agents: [AgentStatus] = []
    /// Phase 4: the leases the app honours right now.
    var leases: [LeaseStatus] = []

    static func encode(_ s: StatusSnapshot) throws -> Data {
        let encoder = Store.makeEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return try encoder.encode(s)
    }
}

extension StatusSnapshot {
    /// A status.json written before phase 2 has no `agents`; it decodes
    /// with none.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        active = try c.decode(Bool.self, forKey: .active)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        endsAt = try c.decodeIfPresent(Date.self, forKey: .endsAt)
        remainingSeconds = try c.decodeIfPresent(Int.self, forKey: .remainingSeconds)
        lidClosed = try c.decode(Bool.self, forKey: .lidClosed)
        lidOnDesk = try c.decode(Bool.self, forKey: .lidOnDesk)
        lidKnown = try c.decodeIfPresent(Bool.self, forKey: .lidKnown) ?? true
        batteryPercent = try c.decodeIfPresent(Int.self, forKey: .batteryPercent)
        isCharging = try c.decode(Bool.self, forKey: .isCharging)
        chargerDraining = try c.decode(Bool.self, forKey: .chargerDraining)
        hasBattery = try c.decodeIfPresent(Bool.self, forKey: .hasBattery) ?? true
        thermalState = try c.decode(String.self, forKey: .thermalState)
        lowPowerSetByUs = try c.decode(Bool.self, forKey: .lowPowerSetByUs)
        wifiSSID = try c.decodeIfPresent(String.self, forKey: .wifiSSID)
        lastOutageSeconds = try c.decodeIfPresent(Int.self, forKey: .lastOutageSeconds)
        frozenCount = try c.decode(Int.self, forKey: .frozenCount)
        dockerPaused = try c.decode(Bool.self, forKey: .dockerPaused)
        agents = try c.decodeIfPresent([AgentStatus].self, forKey: .agents) ?? []
        leases = try c.decodeIfPresent([LeaseStatus].self, forKey: .leases) ?? []
    }
}

/// Pure HTTP pieces, tested without sockets.
enum StatusHTTP {
    /// GET or HEAD for `/status.json` or `/`; anything else is a 404.
    static func isStatusRequest(head: String) -> Bool? {
        guard let line = head.split(whereSeparator: \.isNewline).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = parts[0], path = parts[1]
        guard method == "GET" || method == "HEAD" else { return nil }
        return path == "/status.json" || path == "/"
    }

    static func response(status: Int, reason: String, body: Data, contentType: String = "application/json; charset=utf-8") -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func respond(to head: String, json: Data?) -> Data {
        switch isStatusRequest(head: head) {
        case true?:
            if let json { return response(status: 200, reason: "OK", body: json) }
            return response(status: 503, reason: "Service Unavailable", body: Data("{\"error\":\"no status yet\"}".utf8))
        case false?:
            return response(status: 404, reason: "Not Found", body: Data("{\"error\":\"not found\"}".utf8))
        case nil:
            return response(status: 405, reason: "Method Not Allowed", body: Data("{\"error\":\"GET /status.json\"}".utf8))
        }
    }
}

/// Serves the latest snapshot on loopback. `update` replaces what is
/// served; `start`/`stop` follow the setting.
@MainActor
final class StatusServer {
    private var listener: NWListener?
    private var json: Data?
    private(set) var port: UInt16?

    func update(_ data: Data) { json = data }

    func start(port requested: Int) {
        guard requested > 0, requested <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(requested)) else { return }
        if listener != nil, port == UInt16(requested) { return }
        stop()
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = true
        do {
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: Log.info("status endpoint listening on http://127.0.0.1:\(requested)/status.json")
                case let .failed(error): Log.error("status endpoint failed: \(error.localizedDescription)")
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.serve(connection) }
            }
            l.start(queue: .main)
            listener = l
            port = UInt16(requested)
        } catch {
            Log.error("status endpoint could not start on port \(requested): \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    /// Phase 2: `POST /hooks/<kind>` on the same port hands the parsed
    /// event here (`HookHTTP`). nil: hook posts are answered and dropped.
    var onHook: (@MainActor (AgentHookEvent) -> Void)?

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffered: Data())
    }

    /// Reads until the request is whole: a hook post carries a body that
    /// may arrive after its head.
    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                if error != nil { connection.cancel(); return }
                var all = buffered
                all.append(data ?? Data())
                let reply: Data
                switch HookHTTP.parse(all) {
                case .needMore where !isComplete && !(data ?? Data()).isEmpty:
                    self.receive(on: connection, buffered: all)
                    return
                case let .request(request) where HookHTTP.isHookPath(request.path):
                    let handled = HookHTTP.handleHook(request, overTCP: true)
                    if let event = handled.event { self.onHook?(event) }
                    reply = handled.reply
                default:
                    reply = StatusHTTP.respond(to: String(data: all, encoding: .utf8) ?? "", json: self.json)
                }
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
