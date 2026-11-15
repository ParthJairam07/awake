import Network
import XCTest
@testable import Awake

/// The server over real loopback sockets, like StatusServerTests: binds
/// 127.0.0.1 on a random high port and nothing else.
@MainActor
final class PhoneServerTests: XCTestCase {
    private var server: PhoneServer!
    private var port = 0

    override func setUp() async throws {
        server = PhoneServer()
        port = 29000 + Int.random(in: 0..<2000)
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
    }

    private func listen() async throws {
        server.listen(port: port, addresses: [PhoneServer.loopback])
        for _ in 0..<100 where !server.ready.contains(PhoneServer.loopback) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(server.ready, [PhoneServer.loopback], "\(server.failures)")
    }

    private func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    private func fetch(_ method: String, _ path: String, headers: [String: String] = [:], body: Data? = nil) async throws -> (Int, Data, HTTPURLResponse) {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, data, http)
    }

    func testServesWhatTheHandlerAnswersWithSecurityHeaders() async throws {
        var seen: [PhoneRequest] = []
        var peers: [String] = []
        server.setHandler { request, peer in
            seen.append(request)
            peers.append(peer)
            return .response(.object(["ok": true, "path": request.path]))
        }
        try await listen()
        let (status, data, http) = try await fetch("POST", "/api/session/extend?x=1", headers: ["Content-Type": "application/json", "Authorization": "Bearer abc.def"], body: Data("{\"minutes\":30}".utf8))
        XCTAssertEqual(status, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"ok\":true,\"path\":\"/api/session/extend\"}")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Content-Type-Options"), "nosniff")
        XCTAssertNil(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin"))
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.method, "POST")
        XCTAssertEqual(seen.first?.query, ["x": "1"])
        XCTAssertEqual(seen.first?.bearerToken, "abc.def")
        XCTAssertEqual(seen.first?.body, Data("{\"minutes\":30}".utf8))
        XCTAssertEqual(peers, ["127.0.0.1"])
    }

    func testABadRequestIsAnsweredWithoutReachingTheHandler() async throws {
        var calls = 0
        server.setHandler { _, _ in
            calls += 1
            return .response(.ok())
        }
        try await listen()
        let (status, _, _) = try await fetch("DELETE", "/api/status")
        XCTAssertEqual(status, 405)
        XCTAssertEqual(calls, 0)
    }

    func testListensOnlyOnTheAddressesAsked() async throws {
        server.setHandler { _, _ in .response(.ok()) }
        try await listen()
        XCTAssertEqual(server.addresses, ["127.0.0.1"])
        XCTAssertEqual(server.port, port)
        // Never the wildcard, and never a name.
        XCTAssertNil(PhoneServer.host("0.0.0.0"))
        XCTAssertNil(PhoneServer.host("::"))
        XCTAssertNil(PhoneServer.host("localhost"))
        XCTAssertNil(PhoneServer.host(""))
        XCTAssertNotNil(PhoneServer.host("127.0.0.1"))
        XCTAssertNotNil(PhoneServer.host("100.101.102.103"))
        XCTAssertNotNil(PhoneServer.host("fd7a:115c:a1e0::abcd"))
        server.listen(port: port, addresses: ["0.0.0.0", "127.0.0.1"])
        XCTAssertEqual(server.addresses, ["127.0.0.1"], "the wildcard is refused, not bound")
        XCTAssertNotNil(server.failures["0.0.0.0"])
    }

    func testStopClosesTheListener() async throws {
        server.setHandler { _, _ in .response(.ok()) }
        try await listen()
        server.stop()
        XCTAssertNil(server.port)
        XCTAssertTrue(server.addresses.isEmpty)
        try await Task.sleep(for: .milliseconds(100))
        do {
            _ = try await fetch("GET", "/")
            XCTFail("the port should be closed")
        } catch {}
    }

    func testAnInvalidPortListensOnNothing() {
        server.listen(port: 0, addresses: [PhoneServer.loopback])
        XCTAssertNil(server.port)
        XCTAssertTrue(server.addresses.isEmpty)
        server.listen(port: 70000, addresses: [PhoneServer.loopback])
        XCTAssertTrue(server.addresses.isEmpty)
    }

    func testEventStreamSendsTheFirstStatusThenBroadcasts() async throws {
        server.setHandler { _, _ in .events(deviceID: "dev1") }
        server.initialEvent = { id in Data("{\"first\":\"\(id)\"}".utf8) }
        var counts: [Int] = []
        server.onEventClientsChanged = { counts.append($0) }
        try await listen()

        let (bytes, response) = try await URLSession.shared.bytes(from: url("/api/events"))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/event-stream") == true)

        var lines = bytes.lines.makeAsyncIterator()
        let event = try await lines.next()
        let data = try await lines.next()
        XCTAssertEqual(event, "event: status")
        XCTAssertEqual(data, "data: {\"first\":\"dev1\"}")
        XCTAssertEqual(server.eventClientCount, 1)

        server.broadcast(event: "status") { id in id == "dev1" ? Data("{\"n\":2}".utf8) : nil }
        let event2 = try await lines.next()
        let data2 = try await lines.next()
        XCTAssertEqual(event2, "event: status")
        XCTAssertEqual(data2, "data: {\"n\":2}")

        // Forgetting the device hangs its stream up.
        server.closeEventStreams(of: ["dev1"])
        XCTAssertEqual(server.eventClientCount, 0)
        XCTAssertEqual(counts, [1, 0])
        let end = try await lines.next()
        XCTAssertNil(end, "the stream ends")
    }

    func testAPhoneThatHangsUpIsDropped() async throws {
        server.setHandler { _, _ in .events(deviceID: "dev1") }
        try await listen()
        let task = Task {
            let (bytes, _) = try await URLSession.shared.bytes(from: self.url("/api/events"))
            for try await _ in bytes.lines {}
        }
        for _ in 0..<100 where server.eventClientCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(server.eventClientCount, 1)
        task.cancel()
        for _ in 0..<150 where server.eventClientCount != 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(server.eventClientCount, 0)
    }

    func testClientAddressBelievesForwardedForOnlyFromLoopback() {
        XCTAssertEqual(PhoneServer.clientAddress(peer: "127.0.0.1", forwardedFor: "100.64.0.9"), "100.64.0.9")
        XCTAssertEqual(PhoneServer.clientAddress(peer: "127.0.0.1", forwardedFor: "100.64.0.9, 10.0.0.1"), "100.64.0.9")
        XCTAssertEqual(PhoneServer.clientAddress(peer: "127.0.0.1", forwardedFor: nil), "127.0.0.1")
        XCTAssertEqual(PhoneServer.clientAddress(peer: "127.0.0.1", forwardedFor: "not an address"), "127.0.0.1")
        XCTAssertEqual(PhoneServer.clientAddress(peer: "100.64.0.5", forwardedFor: "1.2.3.4"), "100.64.0.5", "a tailnet peer cannot pick its own address")
    }

    func testURLs() {
        XCTAssertEqual(PhoneServer.url(address: "100.101.102.103", port: 7788), "http://100.101.102.103:7788")
        XCTAssertEqual(PhoneServer.url(address: "fd7a:115c:a1e0::1", port: 7788), "http://[fd7a:115c:a1e0::1]:7788")
    }
}

/// The API behind the real server: a paired token over a real socket.
@MainActor
final class PhoneEndToEndTests: XCTestCase {
    func testPairThenCallOverLoopback() async throws {
        let h = PhoneAPIHarness()
        defer { h.destroy() }
        let server = PhoneServer()
        defer { server.stop() }
        server.setHandler { request, peer in await h.api.handle(request, peer: peer) }
        let port = 31000 + Int.random(in: 0..<2000)
        server.listen(port: port, addresses: [PhoneServer.loopback])
        for _ in 0..<100 where server.ready.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        await h.auth.load()
        let window = h.auth.beginPairing()

        func call(_ method: String, _ path: String, token: String?, body: [String: Any]? = nil) async throws -> (Int, [String: Any], Data) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            request.httpMethod = method
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if method == "POST" {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, json, data)
        }

        let (index, _, html) = try await call("GET", "/", token: nil)
        XCTAssertEqual(index, 200)
        XCTAssertTrue(String(decoding: html, as: UTF8.self).contains("<title>Awake</title>"))

        let (unauthorized, _, _) = try await call("GET", "/api/status", token: nil)
        XCTAssertEqual(unauthorized, 401)

        let (paired, pairBody, _) = try await call("POST", "/api/pair", token: nil, body: ["code": window.code, "name": "iPhone"])
        XCTAssertEqual(paired, 200)
        let token = try XCTUnwrap(pairBody["token"] as? String)

        let (status, statusBody, _) = try await call("GET", "/api/status", token: token)
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(statusBody["status"])

        let (locked, _, _) = try await call("POST", "/api/lock", token: token)
        XCTAssertEqual(locked, 200)
        XCTAssertEqual(h.locker.calls, 1)

        let (shot, _, jpeg) = try await call("GET", "/api/screenshot?width=640", token: token)
        XCTAssertEqual(shot, 200)
        XCTAssertEqual(jpeg, Data([0xFF, 0xD8, 0xFF, 0xD9]))

        let (missing, _, _) = try await call("GET", "/api/anything-else", token: token)
        XCTAssertEqual(missing, 404)
        XCTAssertEqual(h.audit.last?["action"] as? String, "screenshot")
    }
}
