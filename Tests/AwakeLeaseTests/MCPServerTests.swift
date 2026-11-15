import AwakeLeaseKit
import XCTest
@testable import awake_cli

final class MCPServerTests: CLICase {
    private var session = MCPServer.Session()

    private func send(_ line: String) throws -> [String: Any]? {
        guard let reply = MCPServer(env: env).handle(line: line, session: &session) else { return nil }
        XCTAssertFalse(reply.contains("\n"), "one message per line")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    }

    private func request(_ method: String, id: Any = 1, params: [String: Any]? = nil) throws -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        let line = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
        let reply = try XCTUnwrap(try send(line), "a request is always answered")
        XCTAssertEqual(reply["jsonrpc"] as? String, "2.0")
        return reply
    }

    /// The `result` of a tools/call: (structuredContent, isError, text).
    private func call(_ tool: String, _ arguments: [String: Any]? = nil) throws -> (body: [String: Any], isError: Bool, text: String) {
        var params: [String: Any] = ["name": tool]
        if let arguments { params["arguments"] = arguments }
        let reply = try request("tools/call", params: params)
        let result = try XCTUnwrap(reply["result"] as? [String: Any], "\(reply)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "text")
        return (result["structuredContent"] as? [String: Any] ?? [:], result["isError"] as? Bool ?? false, content.first?["text"] as? String ?? "")
    }

    private func errorCode(_ reply: [String: Any]?) -> Int? {
        (reply?["error"] as? [String: Any])?["code"] as? Int
    }

    // MARK: Framing

    func testInitializeAnswersWithTheProtocolVersionAndTheToolsCapability() throws {
        let reply = try request("initialize", id: 0, params: ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "2.0"]])

        XCTAssertEqual(reply["id"] as? Int, 0)
        let result = try XCTUnwrap(reply["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((result["capabilities"] as? [String: Any])?.keys.sorted(), ["tools"])
        let info = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(info["name"] as? String, "awake")
        XCTAssertEqual(info["version"] as? String, "9.9")
        XCTAssertNotNil(result["instructions"] as? String)
        XCTAssertEqual(session.clientName, "claude-code")
    }

    func testAnOlderRevisionIsEchoedAndAnUnknownOneGetsTheLatest() throws {
        func version(_ asked: Any?) throws -> String? {
            var params: [String: Any] = ["capabilities": [:]]
            if let asked { params["protocolVersion"] = asked }
            return (try request("initialize", params: params)["result"] as? [String: Any])?["protocolVersion"] as? String
        }
        XCTAssertEqual(try version("2024-11-05"), "2024-11-05")
        XCTAssertEqual(try version("2025-03-26"), "2025-03-26")
        XCTAssertEqual(try version("2099-01-01"), "2025-06-18")
        XCTAssertEqual(try version(nil), "2025-06-18")
    }

    func testPing() throws {
        let reply = try request("ping", id: "abc")
        XCTAssertEqual(reply["id"] as? String, "abc", "the id comes back as it was sent")
        XCTAssertEqual((reply["result"] as? [String: Any])?.count, 0)
    }

    func testNotificationsAreNeverAnswered() throws {
        XCTAssertNil(try send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertNil(try send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#))
        XCTAssertNil(try send(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"awake_lease","arguments":{"duration":"1h","reason":"x"}}}"#), "a request without an id is a notification")
        XCTAssertEqual(onDisk, [], "and is not carried out")
        XCTAssertNil(try send(#"{"jsonrpc":"2.0","id":7,"result":{}}"#), "a response sent to the server")
        XCTAssertNil(try send(""))
        XCTAssertNil(try send("   "))
    }

    func testMalformedInput() throws {
        XCTAssertEqual(errorCode(try send("not json")), -32700)
        XCTAssertTrue(try send("not json")?["id"] is NSNull)
        XCTAssertEqual(errorCode(try send("[]")), -32600)
        XCTAssertEqual(errorCode(try send(#"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#)), -32600, "batches were removed in 2025-06-18")
        XCTAssertEqual(errorCode(try send("42")), -32600)
        XCTAssertEqual(errorCode(try send(#"{"jsonrpc":"2.0","id":3}"#)), -32600)
        XCTAssertEqual(errorCode(try send(#"{"jsonrpc":"2.0","id":{"a":1},"method":"ping"}"#)), -32600)
        XCTAssertEqual(errorCode(try request("resources/list")), -32601)
        XCTAssertEqual(errorCode(try request("tools/call", params: ["name": "rm_rf"])), -32602, "an unknown tool is a protocol error")
        XCTAssertEqual(errorCode(try request("tools/call", params: [:])), -32602)
        XCTAssertEqual(errorCode(try request("tools/call", params: ["name": "awake_leases", "arguments": "x"])), -32602)
    }

    func testToolsListDescribesEachToolWithASchema() throws {
        let result = try XCTUnwrap(try request("tools/list")["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["awake_lease", "awake_release", "awake_leases", "awake_status", "awake_extend"])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), MCPServer.toolNames)
        for tool in tools {
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertNotNil(schema["properties"] as? [String: Any])
        }
        let lease = try XCTUnwrap(tools.first?["inputSchema"] as? [String: Any])
        XCTAssertEqual(lease["required"] as? [String], ["duration", "reason"])
        XCTAssertEqual((lease["properties"] as? [String: Any])?.keys.sorted(), ["duration", "grace", "owner", "reason"])
    }

    func testASessionOfLinesIsAnsweredInOrderAndRemembersTheClient() throws {
        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"cursor","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"awake_lease","arguments":{"duration":"1h","reason":"loop"}}}"#,
        ]
        var session = MCPServer.Session()
        let server = MCPServer(env: env)
        let replies = input.compactMap { server.handle(line: $0, session: &session) }
        XCTAssertEqual(replies.count, 2)
        XCTAssertEqual(onDisk.first?.owner, "cursor")
    }

    // MARK: Tools

    func testAwakeLeaseWritesAnMCPLeaseOwnedByTheClient() throws {
        _ = try request("initialize", params: ["protocolVersion": "2025-06-18", "clientInfo": ["name": "claude-code"]])

        let r = try call("awake_lease", ["duration": "2h", "reason": "refactor billing"])

        XCTAssertFalse(r.isError)
        let lease = try XCTUnwrap(onDisk.first)
        XCTAssertEqual(lease.source, .mcp)
        XCTAssertEqual(lease.owner, "claude-code")
        XCTAssertEqual(lease.reason, "refactor billing")
        XCTAssertEqual(lease.expiresAt, t0.addingTimeInterval(7200))
        XCTAssertEqual(r.body["id"] as? String, Lease.idText(lease.id))
        XCTAssertEqual(r.body["remainingSeconds"] as? Int, 7200)
        XCTAssertNil(r.body["warnings"])
        let text = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(r.text.utf8)) as? [String: Any])
        XCTAssertEqual(text["id"] as? String, r.body["id"] as? String, "the text is the same JSON, for clients that read only text")
    }

    func testAwakeLeaseOwnerGraceCapAndWarnings() throws {
        try FileManager.default.createDirectory(at: home.appSupport, withIntermediateDirectories: true)
        try Data(#"{"leaseCapHours":2}"#.utf8).write(to: home.configFile)
        appRunning.value = false

        let r = try call("awake_lease", ["duration": "6h", "reason": "x", "owner": "codex", "grace": "10m"])

        XCTAssertFalse(r.isError)
        XCTAssertEqual(onDisk.first?.owner, "codex")
        XCTAssertEqual(onDisk.first?.graceSeconds, 600)
        XCTAssertEqual(r.body["remainingSeconds"] as? Int, 7200, "reported with the owner's cap applied")
        XCTAssertEqual(r.body["note"] as? String, "The owner's cap is 2h, so this lease counts for 2h.")
        XCTAssertEqual(r.body["warnings"] as? [String], ["Awake.app is not running; lease will take effect when it starts"])
    }

    func testWithoutAClientNameTheOwnerIsAgent() throws {
        _ = try call("awake_lease", ["duration": "1h", "reason": "x"])
        XCTAssertEqual(onDisk.first?.owner, "agent")
    }

    func testAToolFailureIsAResultTheModelCanRead() throws {
        for (arguments, message) in [
            (["reason": "x"], "duration is required and must be a string"),
            (["duration": "2h"], "reason is required and must be a string"),
            (["duration": 120, "reason": "x"], "duration is required and must be a string"),
            (["duration": "120", "reason": "x"], "\"120\" is not a duration; use a number and a unit, such as 90m, 2h or 1h30m"),
            (["duration": "10s", "reason": "x"], "a lease lasts at least 1m"),
            (["duration": "1h", "reason": "x", "grace": "never"], "\"never\" is not a grace period; use a number and a unit, such as 30s or 10m (at most 24h)"),
        ] as [([String: Any], String)] {
            let r = try call("awake_lease", arguments)
            XCTAssertTrue(r.isError, "\(arguments)")
            XCTAssertEqual(r.text, message)
        }
        XCTAssertEqual(onDisk, [])
    }

    func testAwakeReleaseLeasesAndExtend() throws {
        let made = try call("awake_lease", ["duration": "1h", "reason": "a"])
        let id = try XCTUnwrap(made.body["id"] as? String)
        _ = try call("awake_lease", ["duration": "30m", "reason": "b", "owner": "codex"])

        let listed = try call("awake_leases")
        XCTAssertEqual((listed.body["leases"] as? [[String: Any]])?.compactMap { $0["reason"] as? String }.sorted(), ["a", "b"])

        clock.value = t0.addingTimeInterval(600)
        let extended = try call("awake_extend", ["id": id, "by": "1h"])
        XCTAssertFalse(extended.isError)
        XCTAssertEqual(extended.body["remainingSeconds"] as? Int, 6600)
        XCTAssertEqual(store.load(id: try XCTUnwrap(UUID(uuidString: id)))?.expiresAt, t0.addingTimeInterval(7200))
        XCTAssertTrue(try call("awake_extend", ["id": id, "by": "later"]).isError)
        XCTAssertTrue(try call("awake_extend", ["id": id]).isError)

        let released = try call("awake_release", ["id": id])
        XCTAssertEqual(released.body["released"] as? String, id)
        XCTAssertEqual(onDisk.map(\.reason), ["b"])
        let again = try call("awake_release", ["id": id])
        XCTAssertTrue(again.isError)
        XCTAssertEqual(again.text, "no lease \(id)")
        XCTAssertTrue(try call("awake_release").isError)
    }

    func testAwakeStatus() throws {
        var r = try call("awake_status")
        XCTAssertFalse(r.isError)
        XCTAssertEqual(r.body["appRunning"] as? Bool, true)
        XCTAssertTrue(r.body["status"] is NSNull, "no status.json yet")
        XCTAssertEqual((r.body["leases"] as? [Any])?.count, 0)

        try FileManager.default.createDirectory(at: home.appSupport, withIntermediateDirectories: true)
        try Data(#"{"active":true,"batteryPercent":64,"leases":[{"id":"stale"}],"endsAt":"2027-01-15T09:12:00Z"}"#.utf8).write(to: home.statusFile)
        _ = try call("awake_lease", ["duration": "1h", "reason": "a"])
        appRunning.value = false

        r = try call("awake_status")
        XCTAssertEqual(r.body["appRunning"] as? Bool, false)
        let status = try XCTUnwrap(r.body["status"] as? [String: Any])
        XCTAssertEqual(status["batteryPercent"] as? Int, 64)
        XCTAssertNil(status["leases"], "the leases are read from the directory now, not from the file")
        XCTAssertEqual((r.body["leases"] as? [[String: Any]])?.first?["reason"] as? String, "a")
    }

    func testTextFromTheAgentCannotBreakTheFraming() throws {
        let r = try call("awake_lease", ["duration": "1h", "reason": "line one\nline two\u{1B}[2J \"quoted\"", "owner": "a\nb"])
        XCTAssertFalse(r.isError)
        XCTAssertEqual(onDisk.first?.reason, "line one line two [2J \"quoted\"")
        XCTAssertEqual(onDisk.first?.owner, "a b")
    }
}
