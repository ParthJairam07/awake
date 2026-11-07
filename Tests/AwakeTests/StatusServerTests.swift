import XCTest
@testable import Awake

final class StatusHTTPTests: XCTestCase {
    func testOnlyGetOfTheStatusPathIsServed() {
        XCTAssertEqual(StatusHTTP.isStatusRequest(head: "GET /status.json HTTP/1.1\r\nHost: x\r\n\r\n"), true)
        XCTAssertEqual(StatusHTTP.isStatusRequest(head: "HEAD / HTTP/1.1\r\n\r\n"), true)
        XCTAssertEqual(StatusHTTP.isStatusRequest(head: "GET /other HTTP/1.1\r\n\r\n"), false)
        XCTAssertNil(StatusHTTP.isStatusRequest(head: "POST /status.json HTTP/1.1\r\n\r\n"))
        XCTAssertNil(StatusHTTP.isStatusRequest(head: ""))
    }

    func testResponses() {
        let ok = String(decoding: StatusHTTP.respond(to: "GET /status.json HTTP/1.1\r\n\r\n", json: Data("{\"active\":true}".utf8)), as: UTF8.self)
        XCTAssertTrue(ok.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(ok.contains("Content-Length: 15\r\n"))
        XCTAssertTrue(ok.hasSuffix("\r\n\r\n{\"active\":true}"))
        XCTAssertTrue(String(decoding: StatusHTTP.respond(to: "GET /status.json HTTP/1.1\r\n\r\n", json: nil), as: UTF8.self).hasPrefix("HTTP/1.1 503"))
        XCTAssertTrue(String(decoding: StatusHTTP.respond(to: "GET /x HTTP/1.1\r\n\r\n", json: nil), as: UTF8.self).hasPrefix("HTTP/1.1 404"))
        XCTAssertTrue(String(decoding: StatusHTTP.respond(to: "DELETE / HTTP/1.1\r\n\r\n", json: nil), as: UTF8.self).hasPrefix("HTTP/1.1 405"))
    }

    func testSnapshotEncodesWithSortedKeys() throws {
        let s = StatusSnapshot(updatedAt: Date(timeIntervalSince1970: 1_800_000_000), active: true, startedAt: nil, endsAt: nil, remainingSeconds: 120, lidClosed: true, lidOnDesk: false, batteryPercent: 64, isCharging: true, chargerDraining: true, thermalState: "nominal", lowPowerSetByUs: false, wifiSSID: "iPhone", lastOutageSeconds: nil, frozenCount: 3, dockerPaused: false)
        let text = String(decoding: try StatusSnapshot.encode(s), as: UTF8.self)
        XCTAssertTrue(text.contains("\"active\":true") || text.contains("\"active\" : true"), text)
        XCTAssertTrue(text.contains("\"chargerDraining\""), text)
        XCTAssertLessThan(text.range(of: "\"active\"")!.lowerBound, text.range(of: "\"wifiSSID\"")!.lowerBound, "sorted keys")
    }
}

@MainActor
final class StatusServerTests: XCTestCase {
    func testServesTheLatestSnapshotOnLoopback() async throws {
        let server = StatusServer()
        let port = 28000 + Int.random(in: 0..<1000)
        server.start(port: port)
        defer { server.stop() }
        XCTAssertEqual(server.port, UInt16(port))
        server.update(Data("{\"active\":false}".utf8))
        try await Task.sleep(for: .milliseconds(200))
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/status.json")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "{\"active\":false}")
        server.update(Data("{\"active\":true}".utf8))
        let (again, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertEqual(String(decoding: again, as: UTF8.self), "{\"active\":true}")
    }

    func testPortZeroDoesNotListen() {
        let server = StatusServer()
        server.start(port: 0)
        XCTAssertNil(server.port)
    }
}

@MainActor
final class StatusFileTests: XCTestCase {
    func testWriteStatusProducesTheFile() throws {
        let home = TempHome()
        defer { home.destroy() }
        let services = AppServices(paths: home.paths, notifier: RecordingNotifier(), audio: FakeAudioControl(), processControl: FakeProcessControl(), locationPermission: LocationPermission(authorizationStatus: .notDetermined), lidSimulation: nil, lidSimulationEnabled: false)
        services.status.lidClosed = true
        services.writeStatus()
        let data = try Data(contentsOf: home.paths.statusFile)
        let decoded = try Store.makeDecoder().decode(StatusSnapshot.self, from: data)
        XCTAssertFalse(decoded.active)
        XCTAssertTrue(decoded.lidClosed)
        XCTAssertEqual(decoded.thermalState, "nominal")
    }
}
