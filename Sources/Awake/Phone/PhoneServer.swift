import Foundation
import Network

/// Phase 3: the HTTP server the phone talks to. One `NWListener` per
/// address, each bound to that address alone: loopback always (so
/// `tailscale serve` can proxy to it and the Mac's own browser can open
/// it), and the Mac's Tailscale addresses when it has them. Never the
/// wildcard address: nothing on the Wi-Fi or any other network can
/// connect. Plain HTTP, because the tailnet already encrypts and
/// authenticates the devices; `tailscale serve` adds HTTPS on top.
///
/// One request per connection. A request for the event stream keeps its
/// connection, and `broadcast` writes to all of those.
@MainActor
final class PhoneServer {
    typealias Handler = @MainActor (PhoneRequest, _ peer: String) async -> PhoneReply

    nonisolated static let loopback = "127.0.0.1"
    /// A connection that has not sent a whole request by then is closed.
    static let requestTimeout: Duration = .seconds(15)
    static let keepaliveInterval: TimeInterval = 20
    static let maxConnections = 64
    static let maxEventClients = 16

    private var listeners: [String: NWListener] = [:]
    private(set) var port: Int?
    /// Addresses with a listener that reached `ready`, and the error of
    /// each that failed. Settings shows both.
    private(set) var ready: Set<String> = []
    private(set) var failures: [String: String] = [:]
    var onStateChange: (@MainActor () -> Void)?

    private var handler: Handler?
    /// The first event for a stream that has just opened.
    var initialEvent: (@MainActor (_ deviceID: String) -> Data?)?

    private var open: Set<ObjectIdentifier> = []
    var openConnectionCount: Int { open.count }
    private struct EventClient {
        let connection: NWConnection
        let deviceID: String
    }
    private var eventClients: [ObjectIdentifier: EventClient] = [:]
    private var keepalive: (any DispatchSourceTimer)?
    var onEventClientsChanged: (@MainActor (Int) -> Void)?

    var eventClientCount: Int { eventClients.count }
    var addresses: Set<String> { Set(listeners.keys) }

    func setHandler(_ handler: @escaping Handler) { self.handler = handler }

    /// Listens on exactly `addresses` (numeric IPv4 or IPv6) at `port`:
    /// listeners for addresses no longer wanted are cancelled, new ones
    /// started, the rest left alone. A port change restarts them all.
    func listen(port requested: Int, addresses wanted: Set<String>) {
        guard requested > 0, requested <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(requested)) else {
            stop()
            return
        }
        if port != requested { stopListeners() }
        port = requested
        for address in listeners.keys where !wanted.contains(address) {
            listeners[address]?.cancel()
            listeners[address] = nil
            ready.remove(address)
            failures[address] = nil
        }
        // A listener that failed (the address went away and came back) is
        // tried again.
        for address in wanted where listeners[address] == nil || failures[address] != nil {
            listeners[address]?.cancel()
            listeners[address] = nil
            failures[address] = nil
            guard let host = Self.host(address) else {
                failures[address] = "not a numeric address"
                continue
            }
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: host, port: nwPort)
            params.allowLocalEndpointReuse = true
            do {
                let listener = try NWListener(using: params)
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    Task { @MainActor in
                        guard let self, let listener, self.listeners[address] === listener else { return }
                        switch state {
                        case .ready:
                            self.ready.insert(address)
                            self.failures[address] = nil
                            Log.info("phone app listening on \(Self.url(address: address, port: requested))")
                        case let .failed(error):
                            self.ready.remove(address)
                            self.failures[address] = error.localizedDescription
                            Log.error("phone app listener on \(address) failed: \(error.localizedDescription)")
                            listener.cancel()
                        case let .waiting(error):
                            self.ready.remove(address)
                            self.failures[address] = error.localizedDescription
                        default:
                            break
                        }
                        self.onStateChange?()
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in
                        guard let self else {
                            connection.cancel()
                            return
                        }
                        self.accept(connection)
                    }
                }
                listener.start(queue: .main)
                listeners[address] = listener
            } catch {
                failures[address] = error.localizedDescription
                Log.error("phone app could not listen on \(address) port \(requested): \(error.localizedDescription)")
            }
        }
        onStateChange?()
    }

    func stop() {
        stopListeners()
        port = nil
        for client in eventClients.values { client.connection.cancel() }
        eventClients.removeAll()
        stopKeepalive()
        onEventClientsChanged?(0)
        onStateChange?()
    }

    private func stopListeners() {
        for listener in listeners.values { listener.cancel() }
        listeners.removeAll()
        ready.removeAll()
        failures.removeAll()
    }

    /// Only a numeric address is accepted, so a name can never resolve to
    /// the wildcard or to an interface that was not asked for.
    nonisolated static func host(_ address: String) -> NWEndpoint.Host? {
        if let v4 = IPv4Address(address) {
            return v4 == .any ? nil : .ipv4(v4)
        }
        if let v6 = IPv6Address(address) {
            return v6 == .any ? nil : .ipv6(v6)
        }
        return nil
    }

    nonisolated static func url(address: String, port: Int) -> String {
        address.contains(":") ? "http://[\(address)]:\(port)" : "http://\(address):\(port)"
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard open.count < Self.maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        open.insert(id)
        let peer = Self.peerAddress(connection.endpoint)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .cancelled, .failed:
                Task { @MainActor in
                    guard let self else { return }
                    self.open.remove(id)
                    if let connection { self.dropEventClient(connection) }
                }
                if case .failed = state { connection?.cancel() }
            default:
                break
            }
        }
        connection.start(queue: .main)
        let deadline = Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: Self.requestTimeout)
            guard !Task.isCancelled, let self, let connection, self.eventClients[ObjectIdentifier(connection)] == nil else { return }
            connection.cancel()
        }
        receive(connection, buffer: Data(), peer: peer, deadline: deadline)
    }

    private func receive(_ connection: NWConnection, buffer: Data, peer: String, deadline: Task<Void, Never>) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, error == nil else {
                    deadline.cancel()
                    connection.cancel()
                    return
                }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch PhoneHTTP.parse(buffer) {
                case .incomplete:
                    if isComplete {
                        deadline.cancel()
                        connection.cancel()
                    } else {
                        self.receive(connection, buffer: buffer, peer: peer, deadline: deadline)
                    }
                case let .invalid(status, message):
                    deadline.cancel()
                    self.finish(connection, with: .error(status, message), headOnly: false)
                case let .request(request):
                    deadline.cancel()
                    await self.respond(connection, to: request, peer: peer)
                }
            }
        }
    }

    private func respond(_ connection: NWConnection, to request: PhoneRequest, peer: String) async {
        guard let handler else {
            finish(connection, with: .error(503, "the phone app is not ready"), headOnly: false)
            return
        }
        // Behind `tailscale serve` every request arrives from loopback;
        // the proxy names the phone in X-Forwarded-For. Only a loopback
        // peer is believed about that.
        let client = Self.clientAddress(peer: peer, forwardedFor: request.headers["x-forwarded-for"])
        switch await handler(request, client) {
        case let .response(response):
            finish(connection, with: response, headOnly: request.method == "HEAD")
        case let .events(deviceID):
            guard request.method == "GET", eventClients.count < Self.maxEventClients else {
                finish(connection, with: .error(503, "too many open event streams"), headOnly: request.method == "HEAD")
                return
            }
            var first = PhoneHTTP.eventStreamHead()
            if let data = initialEvent?(deviceID) { first += PhoneHTTP.event(name: "status", data: data) }
            eventClients[ObjectIdentifier(connection)] = EventClient(connection: connection, deviceID: deviceID)
            startKeepalive()
            onEventClientsChanged?(eventClients.count)
            connection.send(content: first, completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor in self?.dropEventClient(connection) }
            })
            watchForClose(connection)
        }
    }

    private func finish(_ connection: NWConnection, with response: PhoneResponse, headOnly: Bool) {
        connection.send(content: PhoneHTTP.serialize(response, headOnly: headOnly), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// An event stream's phone sends nothing more; a read that completes
    /// means it hung up.
    private func watchForClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if isComplete || error != nil {
                    self.dropEventClient(connection)
                } else if self.eventClients[ObjectIdentifier(connection)] != nil {
                    self.watchForClose(connection)
                }
            }
        }
    }

    private func dropEventClient(_ connection: NWConnection) {
        guard eventClients.removeValue(forKey: ObjectIdentifier(connection)) != nil else { return }
        connection.cancel()
        if eventClients.isEmpty { stopKeepalive() }
        onEventClientsChanged?(eventClients.count)
    }

    // MARK: Events

    /// Sends one event to every open stream; `body` gives the payload for
    /// a device (each phone's status names that phone).
    func broadcast(event: String, body: (_ deviceID: String) -> Data?) {
        for client in eventClients.values {
            guard let data = body(client.deviceID) else { continue }
            send(PhoneHTTP.event(name: event, data: data), to: client.connection)
        }
    }

    /// Closes the streams of devices that were forgotten.
    func closeEventStreams(of deviceIDs: Set<String>) {
        for client in eventClients.values where deviceIDs.contains(client.deviceID) {
            dropEventClient(client.connection)
        }
    }

    private func send(_ data: Data, to connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.dropEventClient(connection) }
        })
    }

    private func startKeepalive() {
        guard keepalive == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.keepaliveInterval, repeating: Self.keepaliveInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for client in self.eventClients.values { self.send(PhoneHTTP.keepalive, to: client.connection) }
            }
        }
        timer.resume()
        keepalive = timer
    }

    private func stopKeepalive() {
        keepalive?.cancel()
        keepalive = nil
    }

    // MARK: Addresses

    nonisolated static func peerAddress(_ endpoint: NWEndpoint) -> String {
        guard case let .hostPort(host, _) = endpoint else { return "unknown" }
        switch host {
        case let .ipv4(address): return "\(address)"
        case let .ipv6(address):
            let text = "\(address)"
            return text.split(separator: "%").first.map(String.init) ?? text
        case let .name(name, _): return name
        @unknown default: return "unknown"
        }
    }

    /// The address a request is attributed to in the rate limits and the
    /// audit log.
    nonisolated static func clientAddress(peer: String, forwardedFor: String?) -> String {
        guard peer == loopback || peer == "::1",
              let first = forwardedFor?.split(separator: ",").first?.trimmingCharacters(in: .whitespaces),
              IPv4Address(first) != nil || IPv6Address(first) != nil else { return peer }
        return first
    }
}
