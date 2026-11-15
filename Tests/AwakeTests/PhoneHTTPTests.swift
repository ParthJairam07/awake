import XCTest
@testable import Awake

final class PhoneHTTPTests: XCTestCase {
    private func parse(_ text: String) -> PhoneHTTPParse {
        PhoneHTTP.parse(Data(text.utf8))
    }

    func testParsesAGetWithQueryAndHeaders() {
        guard case let .request(r) = parse("GET /api/screenshot?display=main&width=640&x=a%20b HTTP/1.1\r\nHost: mac:7788\r\nAuthorization: Bearer abc.def\r\n\r\n") else {
            return XCTFail("not parsed")
        }
        XCTAssertEqual(r.method, "GET")
        XCTAssertEqual(r.path, "/api/screenshot")
        XCTAssertEqual(r.query, ["display": "main", "width": "640", "x": "a b"])
        XCTAssertEqual(r.headers["host"], "mac:7788")
        XCTAssertEqual(r.bearerToken, "abc.def")
        XCTAssertTrue(r.body.isEmpty)
    }

    func testWaitsForTheWholeHeadAndBody() {
        XCTAssertEqual(parse("POST /api/pair HTTP/1.1\r\nContent-Le"), .incomplete)
        let head = "POST /api/pair HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n"
        XCTAssertEqual(parse(head + "{\"code\":\"12"), .incomplete)
        guard case let .request(r) = parse(head + "{\"code\":\"123456\"}") else { return XCTFail("not parsed") }
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "{\"code\":\"123456\"}")
        XCTAssertTrue(r.hasJSONContentType)
    }

    func testBodyBeyondContentLengthIsNotRead() {
        guard case let .request(r) = parse("POST /api/lock HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}GET /api/panic HTTP/1.1\r\n\r\n") else { return XCTFail("not parsed") }
        XCTAssertEqual(r.body, Data("{}".utf8))
    }

    func testRefusesWhatItDoesNotRead() {
        XCTAssertEqual(parse("DELETE /api/status HTTP/1.1\r\n\r\n"), .invalid(status: 405, message: "method not allowed"))
        XCTAssertEqual(parse("PUT / HTTP/1.1\r\n\r\n"), .invalid(status: 405, message: "method not allowed"))
        XCTAssertEqual(parse("GET http://evil/ HTTP/1.1\r\n\r\n"), .invalid(status: 400, message: "bad request target"))
        XCTAssertEqual(parse("GET /\r\n\r\n"), .invalid(status: 400, message: "bad request line"))
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nno colon here\r\n\r\n"), .invalid(status: 400, message: "bad header"))
        XCTAssertEqual(parse("POST /api/lock HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), .invalid(status: 501, message: "transfer-encoding is not supported"))
        XCTAssertEqual(parse("POST /api/lock HTTP/1.1\r\nContent-Length: -1\r\n\r\n"), .invalid(status: 400, message: "bad content-length"))
        XCTAssertEqual(parse("POST /api/lock HTTP/1.1\r\nContent-Length: 1e3\r\n\r\n"), .invalid(status: 400, message: "bad content-length"))
        XCTAssertEqual(parse("POST /api/lock HTTP/1.1\r\nContent-Length: \(PhoneHTTP.maxBodyBytes + 1)\r\n\r\n"), .invalid(status: 413, message: "request body too large"))
    }

    func testRepeatedSecurityRelevantHeadersAreRefused() {
        XCTAssertEqual(parse("POST /api/lock HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 0\r\n\r\n{}"), .invalid(status: 400, message: "repeated content-length header"))
        XCTAssertEqual(parse("GET /api/status HTTP/1.1\r\nAuthorization: Bearer a\r\nauthorization: Bearer b\r\n\r\n"), .invalid(status: 400, message: "repeated authorization header"))
    }

    func testAnOversizedHeadIsRefusedWithoutWaitingForItsEnd() {
        let big = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: PhoneHTTP.maxHeadBytes + 10)
        XCTAssertEqual(parse(big), .invalid(status: 431, message: "request head too large"))
        XCTAssertEqual(parse(big + "\r\n\r\n"), .invalid(status: 431, message: "request head too large"))
    }

    func testBearerTokenAndContentType() {
        var r = PhoneRequest(method: "GET", path: "/")
        XCTAssertNil(r.bearerToken)
        r.headers["authorization"] = "Basic abc"
        XCTAssertNil(r.bearerToken)
        r.headers["authorization"] = "bearer  tok "
        XCTAssertEqual(r.bearerToken, "tok")
        r.headers["authorization"] = "Bearer "
        XCTAssertNil(r.bearerToken)
        XCTAssertFalse(r.hasJSONContentType)
        r.headers["content-type"] = "Application/JSON; charset=utf-8"
        XCTAssertTrue(r.hasJSONContentType)
        r.headers["content-type"] = "text/plain"
        XCTAssertFalse(r.hasJSONContentType)
    }

    func testSerializedResponseCarriesLengthSecurityHeadersAndCloses() {
        let text = String(decoding: PhoneHTTP.serialize(.error(404, "not found")), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 404 Not Found\r\n"), text)
        XCTAssertTrue(text.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(text.contains("Cache-Control: no-store\r\n"))
        XCTAssertTrue(text.contains("X-Content-Type-Options: nosniff\r\n"))
        XCTAssertTrue(text.contains("X-Frame-Options: DENY\r\n"))
        XCTAssertTrue(text.contains("Content-Security-Policy: default-src 'self';"))
        XCTAssertTrue(text.contains("Connection: close\r\n\r\n"))
        XCTAssertFalse(text.contains("Access-Control-Allow-Origin"), "no other origin may read the API")
        let body = "{\"error\":\"not found\",\"ok\":false}"
        XCTAssertTrue(text.hasSuffix("\r\n\r\n" + body), text)
        XCTAssertTrue(text.contains("Content-Length: \(body.utf8.count)\r\n"))
    }

    func testHeadOnlyKeepsTheLengthAndDropsTheBody() {
        let text = String(decoding: PhoneHTTP.serialize(.ok(), headOnly: true), as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Length: 11\r\n"), text)
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    func testEventStreamFraming() {
        let head = String(decoding: PhoneHTTP.eventStreamHead(), as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(head.contains("Content-Type: text/event-stream; charset=utf-8\r\n"))
        XCTAssertFalse(head.contains("Content-Length"))
        XCTAssertEqual(String(decoding: PhoneHTTP.event(name: "status", data: Data("{\"a\":1}".utf8)), as: UTF8.self), "event: status\ndata: {\"a\":1}\n\n")
        XCTAssertEqual(String(decoding: PhoneHTTP.keepalive, as: UTF8.self), ": keepalive\n\n")
    }

    func testCompactJSONIsOneLine() throws {
        let pretty = Data("{\n  \"b\" : [1, 2],\n  \"a\" : \"x\\ny\"\n}".utf8)
        let compact = try XCTUnwrap(PhoneHTTP.compactJSON(pretty))
        XCTAssertEqual(String(decoding: compact, as: UTF8.self), "{\"a\":\"x\\ny\",\"b\":[1,2]}")
        XCTAssertFalse(compact.contains(UInt8(ascii: "\n")))
        XCTAssertNil(PhoneHTTP.compactJSON(Data("not json".utf8)))
    }

    func testTooManyCarriesRetryAfter() {
        let r = PhoneAPI.tooMany("slow down", retryAfter: 9.2)
        XCTAssertEqual(r.status, 429)
        XCTAssertEqual(r.extraHeaders["Retry-After"], "10")
        XCTAssertTrue(String(decoding: PhoneHTTP.serialize(r), as: UTF8.self).contains("Retry-After: 10\r\n"))
    }
}

final class PhoneRouterTests: XCTestCase {
    private func router() -> PhoneRouter<String> {
        var r = PhoneRouter<String>()
        r.add("GET", "/", "index")
        r.add("GET", "/api/status", "status")
        r.add("POST", "/api/agents/{id}/{action}", "agent")
        return r
    }

    func testLiteralAndParameterMatches() {
        let r = router()
        XCTAssertEqual(r.match(method: "GET", path: "/")?.route, "index")
        XCTAssertEqual(r.match(method: "GET", path: "/api/status")?.route, "status")
        let m = r.match(method: "POST", path: "/api/agents/claude%201/nudge")
        XCTAssertEqual(m?.route, "agent")
        XCTAssertEqual(m?.parameters, ["id": "claude 1", "action": "nudge"])
    }

    func testHeadMatchesGetAndNothingElseCrossesMethods() {
        let r = router()
        XCTAssertEqual(r.match(method: "HEAD", path: "/api/status")?.route, "status")
        XCTAssertNil(r.match(method: "POST", path: "/api/status"))
        XCTAssertNil(r.match(method: "GET", path: "/api/agents/a/nudge"))
        XCTAssertNil(r.match(method: "HEAD", path: "/api/agents/a/nudge"))
    }

    func testAnythingNotAddedIsNotMatched() {
        let r = router()
        for path in ["/api", "/api/", "/api/status/", "/api/status/x", "/API/status", "/api//status", "api/status", "/..", "/api/agents/a", "/api/agents/a/b/c", ""] {
            XCTAssertNil(r.match(method: "GET", path: path), path)
            XCTAssertNil(r.match(method: "POST", path: path), path)
        }
    }

    func testUnsafeParametersDoNotMatch() {
        let r = router()
        for id in ["..", ".", "a%2Fb", "%2e%2e", "a%00", "a%0Ab", "%ZZ", ""] {
            XCTAssertNil(r.match(method: "POST", path: "/api/agents/\(id)/nudge"), id)
        }
        XCTAssertNil(r.match(method: "POST", path: "/api/agents/" + String(repeating: "a", count: 201) + "/nudge"))
    }

    func testTheAPIsRouterIsTheWholeAllowList() {
        let r = PhoneAPI.makeRouter()
        let allowed: [(String, String)] = [
            ("GET", "/"), ("GET", "/index.html"), ("GET", "/app.js"), ("GET", "/app.css"), ("GET", "/manifest.webmanifest"), ("GET", "/sw.js"),
            ("GET", "/icon-180.png"), ("GET", "/icon-192.png"), ("GET", "/icon-512.png"), ("GET", "/apple-touch-icon.png"), ("GET", "/favicon.ico"),
            ("POST", "/api/pair"), ("GET", "/api/status"), ("GET", "/api/events"), ("GET", "/api/machine"), ("GET", "/api/log"),
            ("GET", "/api/screenshot"), ("GET", "/api/devices"), ("POST", "/api/unpair"),
            ("POST", "/api/session/start"), ("POST", "/api/session/extend"), ("POST", "/api/session/end"),
            ("POST", "/api/lock"), ("POST", "/api/panic"), ("POST", "/api/agents/x/nudge"),
            ("GET", "/api/push/key"), ("POST", "/api/push/subscribe"), ("POST", "/api/push/unsubscribe"), ("POST", "/api/push/test"),
        ]
        for (method, path) in allowed {
            XCTAssertNotNil(r.match(method: method, path: path), "\(method) \(path)")
        }
        let refused: [(String, String)] = [
            ("GET", "/api/pair"), ("GET", "/api/lock"), ("GET", "/api/panic"), ("GET", "/api/session/end"), ("POST", "/api/status"),
            ("GET", "/status.json"), ("GET", "/api/unlock"), ("POST", "/api/unlock"), ("GET", "/api/config"), ("POST", "/api/shell"),
            ("GET", "/config.json"), ("GET", "/audit.log"), ("GET", "/../config.json"), ("GET", "/app.js.map"), ("GET", "/Web/app.js"),
        ]
        for (method, path) in refused {
            XCTAssertNil(r.match(method: method, path: path), "\(method) \(path)")
        }
    }
}
