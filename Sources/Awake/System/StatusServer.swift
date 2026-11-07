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
    var batteryPercent: Int?
    var isCharging: Bool
    var chargerDraining: Bool
    var thermalState: String
    var lowPowerSetByUs: Bool
    var wifiSSID: String?
    var lastOutageSeconds: Int?
    var frozenCount: Int
    var dockerPaused: Bool

    static func encode(_ s: StatusSnapshot) throws -> Data {
        let encoder = Store.makeEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return try encoder.encode(s)
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

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                if error != nil { connection.cancel(); return }
                let head = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let reply = StatusHTTP.respond(to: head, json: self.json)
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
