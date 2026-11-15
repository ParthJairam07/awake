import XCTest
@testable import Awake

final class AgentHookParserTests: XCTestCase {
    private func parse(_ kind: String, _ json: String, query: [String: String] = [:]) -> AgentHookEvent? {
        AgentHookParser.parse(kind: kind, query: query, body: Data(json.utf8))
    }

    func testClaudeNotificationIsWaitingWithItsMessage() {
        let event = parse("claude", #"{"session_id":"abc","transcript_path":"/Users/x/.claude/projects/p/abc.jsonl","cwd":"/Users/x/api","hook_event_name":"Notification","message":"Claude needs your permission to use Bash"}"#, query: ["pid": "4242"])
        XCTAssertEqual(event, AgentHookEvent(kind: "claude", action: .waiting("Claude needs your permission to use Bash"), pid: 4242, sessionId: "abc", cwd: "/Users/x/api", transcriptPath: "/Users/x/.claude/projects/p/abc.jsonl"))
    }

    func testClaudeIdleNotificationIsRestNotAQuestion() {
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"Notification","message":"Claude is waiting for your input"}"#)?.action, .finished)
    }

    func testClaudeStopAndSubagentStopAreFinishedAndToolUseIsAHeartbeat() {
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"Stop"}"#)?.action, .finished)
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"SubagentStop"}"#)?.action, .finished)
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#)?.action, .heartbeat)
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"UserPromptSubmit"}"#)?.action, .heartbeat)
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"SessionEnd","reason":"logout"}"#)?.action, .ended("logout"))
    }

    func testCodexNotifyTurnCompleteIsFinished() {
        let event = parse("codex", #"{"type":"agent-turn-complete","thread-id":"t-1","turn-id":"9","cwd":"/Users/x/web","input-messages":["fix it"],"last-assistant-message":"Done."}"#)
        XCTAssertEqual(event?.action, .finished)
        XCTAssertEqual(event?.sessionId, "t-1")
        XCTAssertEqual(event?.cwd, "/Users/x/web")
        XCTAssertNil(event?.pid)
    }

    func testTheQueryEventWinsAndAnEmptyBodyIsFine() {
        XCTAssertEqual(parse("claude", #"{"hook_event_name":"Stop"}"#, query: ["event": "waiting"])?.action, .waiting(nil))
        XCTAssertEqual(parse("mybot", "", query: ["event": "heartbeat"])?.action, .heartbeat)
        XCTAssertEqual(parse("mybot", "not json", query: ["event": "finished", "pid": "1"])?.pid, nil, "pid 1 is launchd, never an agent")
    }

    func testUnknownEventsAndBadKindsAreRefused() {
        XCTAssertNil(parse("claude", #"{"hook_event_name":"PreCompact"}"#))
        XCTAssertNil(parse("claude", "{}"))
        XCTAssertNil(parse("Claude", #"{"hook_event_name":"Stop"}"#))
        XCTAssertNil(parse("a/b", #"{"hook_event_name":"Stop"}"#))
        XCTAssertNil(parse("", #"{"hook_event_name":"Stop"}"#))
        XCTAssertNil(parse(String(repeating: "a", count: 33), #"{"hook_event_name":"Stop"}"#))
    }

    func testLongFieldsAreCapped() {
        let long = String(repeating: "m", count: 5000)
        guard case let .waiting(message)? = parse("claude", #"{"hook_event_name":"Notification","message":"\#(long)"}"#)?.action else { return XCTFail("not waiting") }
        XCTAssertEqual(message?.count, 1024)
    }
}

final class HookHTTPTests: XCTestCase {
    private func request(_ text: String) -> HookHTTP.Parse { HookHTTP.parse(Data(text.utf8)) }

    func testParsesAPostWithQueryHeadersAndBody() {
        let body = #"{"hook_event_name":"Stop"}"#
        guard case let .request(r) = request("POST /hooks/claude?pid=77&event=finished HTTP/1.1\r\nHost: awake\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)") else { return XCTFail("not parsed") }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/hooks/claude")
        XCTAssertEqual(r.query, ["pid": "77", "event": "finished"])
        XCTAssertEqual(r.headers["content-type"], "application/json")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), body)
    }

    func testWaitsForTheWholeBodyAndTheWholeHead() {
        XCTAssertEqual(request("POST /hooks/claude HTTP/1.1\r\nContent-Le"), .needMore)
        XCTAssertEqual(request("POST /hooks/claude HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345"), .needMore)
        guard case .request = request("POST /hooks/claude HTTP/1.1\r\nContent-Length: 5\r\n\r\n12345") else { return XCTFail("complete") }
        guard case let .request(get) = request("GET /status.json HTTP/1.1\r\n\r\n") else { return XCTFail("a GET has no body") }
        XCTAssertTrue(get.body.isEmpty)
    }

    func testOversizedAndMalformedRequestsAreInvalid() {
        XCTAssertEqual(request("POST /hooks/x HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n"), .invalid)
        XCTAssertEqual(request("POST /hooks/x HTTP/1.1\r\nContent-Length: -4\r\n\r\n"), .invalid)
        XCTAssertEqual(request("nonsense\r\n\r\n"), .invalid)
        XCTAssertEqual(HookHTTP.parse(Data(repeating: 0x41, count: 17 * 1024)), .invalid, "a head that never ends")
        XCTAssertEqual(HookHTTP.parse(Data(repeating: 0x41, count: HookHTTP.maxBytes + 1)), .invalid)
    }

    private func post(_ path: String, headers: [String: String] = [:], body: String = #"{"hook_event_name":"Stop"}"#, method: String = "POST") -> HookHTTPRequest {
        HookHTTPRequest(method: method, path: path, query: [:], headers: headers, body: Data(body.utf8))
    }

    private func status(_ reply: Data) -> String { String(String(decoding: reply, as: UTF8.self).prefix(12)) }

    func testHookOverTheSocketNeedsNoHeader() {
        let handled = HookHTTP.handleHook(post("/hooks/claude"), overTCP: false)
        XCTAssertEqual(status(handled.reply), "HTTP/1.1 200")
        XCTAssertEqual(handled.event?.action, .finished)
        XCTAssertEqual(handled.event?.kind, "claude")
    }

    func testHookOverTCPNeedsTheHeaderAndRefusesABrowser() {
        XCTAssertEqual(status(HookHTTP.handleHook(post("/hooks/claude"), overTCP: true).reply), "HTTP/1.1 403")
        XCTAssertNil(HookHTTP.handleHook(post("/hooks/claude"), overTCP: true).event)
        let good = HookHTTP.handleHook(post("/hooks/claude", headers: ["x-awake-hook": "1"]), overTCP: true)
        XCTAssertEqual(status(good.reply), "HTTP/1.1 200")
        XCTAssertNotNil(good.event)
        let browser = HookHTTP.handleHook(post("/hooks/claude", headers: ["x-awake-hook": "1", "origin": "https://evil.example"]), overTCP: true)
        XCTAssertEqual(status(browser.reply), "HTTP/1.1 403")
        XCTAssertNil(browser.event)
    }

    func testBadMethodPathAndEvent() {
        XCTAssertEqual(status(HookHTTP.handleHook(post("/hooks/claude", method: "GET"), overTCP: false).reply), "HTTP/1.1 405")
        XCTAssertEqual(status(HookHTTP.handleHook(post("/hooks/"), overTCP: false).reply), "HTTP/1.1 404")
        XCTAssertEqual(status(HookHTTP.handleHook(post("/hooks/a/b"), overTCP: false).reply), "HTTP/1.1 404")
        XCTAssertEqual(status(HookHTTP.handleHook(post("/hooks/claude", body: "{}"), overTCP: false).reply), "HTTP/1.1 422")
        XCTAssertEqual(HookHTTP.hookKind(path: "/hooks/codex"), "codex")
        XCTAssertNil(HookHTTP.hookKind(path: "/status.json"))
    }
}

/// The socket server over a real Unix socket in a temp directory, driven
/// by the shipped script and by a raw client.
final class HookSocketServerTests: XCTestCase {
    private var dir: URL!
    private let server = HookSocketServer()
    private let received = Received()

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [AgentHookEvent] = []
        var events: [AgentHookEvent] { lock.withLock { _events } }
        func add(_ e: AgentHookEvent) { lock.withLock { _events.append(e) } }
    }

    override func setUp() {
        // Short: sockaddr_un holds 103 bytes.
        dir = URL(fileURLWithPath: "/tmp/awk-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    override func tearDown() {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private var socketPath: String { dir.appendingPathComponent("hooks.sock").path }

    private func start() {
        let received = self.received
        XCTAssertTrue(server.start(path: socketPath) { received.add($0) })
    }

    private func waitForEvents(_ count: Int) async {
        for _ in 0..<200 where received.events.count < count { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testSocketIsOwnerOnlyAndRemovedOnStop() throws {
        start()
        XCTAssertTrue(server.isListening)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o600)
        server.stop()
        XCTAssertFalse(server.isListening)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testAStaleSocketFileIsReplaced() {
        FileManager.default.createFile(atPath: socketPath, contents: Data("stale".utf8))
        start()
        XCTAssertTrue(server.isListening)
    }

    func testAPathTooLongForASocketIsRefused() {
        let long = dir.appendingPathComponent(String(repeating: "x", count: 120)).path
        XCTAssertFalse(server.start(path: long) { _ in })
        XCTAssertFalse(server.isListening)
    }

    func testCurlPostsOverTheSocket() async throws {
        start()
        let body = #"{"hook_event_name":"Notification","message":"Allow Bash?","session_id":"s1","cwd":"/Users/x/api"}"#
        let r = try await Shell.run("/usr/bin/curl", ["--silent", "--max-time", "5", "--unix-socket", socketPath, "--data-binary", body, "http://awake/hooks/claude?pid=4242"], timeout: 10)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertEqual(r.stdout, #"{"ok":"received"}"#)
        await waitForEvents(1)
        XCTAssertEqual(received.events, [AgentHookEvent(kind: "claude", action: .waiting("Allow Bash?"), pid: 4242, sessionId: "s1", cwd: "/Users/x/api")])
    }

    func testABodyLargerThanOneReadArrivesWhole() async throws {
        start()
        let message = String(repeating: "m", count: 60_000)
        let file = dir.appendingPathComponent("body.json")
        try Data(#"{"hook_event_name":"Notification","message":"\#(message)"}"#.utf8).write(to: file)
        let r = try await Shell.run("/usr/bin/curl", ["--silent", "--max-time", "5", "--unix-socket", socketPath, "--data-binary", "@\(file.path)", "http://awake/hooks/claude"], timeout: 10)
        XCTAssertEqual(r.stdout, #"{"ok":"received"}"#)
        await waitForEvents(1)
        XCTAssertEqual(received.events.count, 1)
    }

    func testBadRequestsGetAnErrorAndDeliverNothing() async throws {
        start()
        let unknown = try await Shell.run("/usr/bin/curl", ["--silent", "--max-time", "5", "-o", "/dev/null", "-w", "%{http_code}", "--unix-socket", socketPath, "--data-binary", "{}", "http://awake/hooks/claude"], timeout: 10)
        XCTAssertEqual(unknown.stdout, "422")
        let get = try await Shell.run("/usr/bin/curl", ["--silent", "--max-time", "5", "-o", "/dev/null", "-w", "%{http_code}", "--unix-socket", socketPath, "http://awake/hooks/claude"], timeout: 10)
        XCTAssertEqual(get.stdout, "405")
        let other = try await Shell.run("/usr/bin/curl", ["--silent", "--max-time", "5", "-o", "/dev/null", "-w", "%{http_code}", "--unix-socket", socketPath, "--data-binary", "{}", "http://awake/status.json"], timeout: 10)
        XCTAssertEqual(other.stdout, "404")
        XCTAssertTrue(received.events.isEmpty)
    }

    // MARK: The shipped script

    private static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var script: String { Self.repoRoot.appendingPathComponent("scripts/awake-hook.sh").path }

    /// Runs the script with AWAKE_HOME at the temp directory and `stdin`
    /// on its standard input.
    private func runScript(_ args: [String], stdin: String?) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + args
        var env = ProcessInfo.processInfo.environment
        env["AWAKE_HOME"] = dir.path
        process.environment = env
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exit = ProcessExit(process)
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(Data(stdin.utf8))
            try input.fileHandleForWriting.close()
        }
        await exit.exited()
        return process.terminationStatus
    }

    func testScriptPostsClaudeHookInputFromStdinWithItsParentPid() async throws {
        start()
        let status = try await runScript(["claude"], stdin: #"{"hook_event_name":"Stop","session_id":"s2","cwd":"/Users/x/api"}"#)
        XCTAssertEqual(status, 0)
        await waitForEvents(1)
        XCTAssertEqual(received.events.first?.action, .finished)
        XCTAssertEqual(received.events.first?.sessionId, "s2")
        XCTAssertEqual(received.events.first?.pid, getpid(), "the script's parent is the process that ran it")
    }

    func testScriptPostsCodexNotifyPayloadFromItsArgument() async throws {
        start()
        let status = try await runScript(["codex", "", #"{"type":"agent-turn-complete","thread-id":"t7"}"#], stdin: nil)
        XCTAssertEqual(status, 0)
        await waitForEvents(1)
        XCTAssertEqual(received.events.first, AgentHookEvent(kind: "codex", action: .finished, pid: getpid(), sessionId: "t7"))
    }

    func testScriptEventArgumentNamesTheEventForAnAgentWithNoPayload() async throws {
        start()
        let status = try await runScript(["mybot", "heartbeat"], stdin: nil)
        XCTAssertEqual(status, 0)
        await waitForEvents(1)
        XCTAssertEqual(received.events.first?.kind, "mybot")
        XCTAssertEqual(received.events.first?.action, .heartbeat)
    }

    func testScriptIsSilentAndSucceedsWithoutASocketOrWithABadKind() async throws {
        let noSocket = try await runScript(["claude"], stdin: #"{"hook_event_name":"Stop"}"#)
        XCTAssertEqual(noSocket, 0)
        start()
        let badKind = try await runScript(["Bad Kind!"], stdin: #"{"hook_event_name":"Stop"}"#)
        XCTAssertEqual(badKind, 0)
        let badEvent = try await runScript(["claude", "a b;c"], stdin: #"{"hook_event_name":"Stop"}"#)
        XCTAssertEqual(badEvent, 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(received.events.isEmpty)
    }
}

final class HookScriptTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testEmbeddedScriptIsTheShippedScript() throws {
        let shipped = try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/awake-hook.sh"), encoding: .utf8)
        XCTAssertEqual(HookScript.text, shipped, "regenerate HookScript.text from scripts/awake-hook.sh")
    }

    func testInstallWritesAnOwnerOnlyExecutableOnceAndRepairsAnEditedCopy() throws {
        let home = TempHome()
        defer { home.destroy() }
        let url = try XCTUnwrap(HookScript.install(paths: home.paths))
        XCTAssertEqual(url, home.paths.hookScript)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), HookScript.text)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode & 0o777, 0o700)
        try Data("#!/bin/bash\necho tampered\n".utf8).write(to: url)
        XCTAssertNotNil(HookScript.install(paths: home.paths))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), HookScript.text)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: home.paths.appSupport.path).contains { $0.contains(".tmp-") })
    }

    func testCommandQuotesThePath() {
        let paths = Paths(root: URL(fileURLWithPath: "/Users/o'x/Library/Application Support/Awake"))
        XCTAssertEqual(HookScript.command(kind: "claude", paths: paths), #"'/Users/o'\''x/Library/Application Support/Awake/awake-hook.sh' claude"#)
        XCTAssertEqual(HookScript.command(kind: "x", event: "finished", paths: Paths(root: URL(fileURLWithPath: "/a"))), "'/a/awake-hook.sh' x finished")
    }
}

@MainActor
final class StatusServerHookTests: XCTestCase {
    func testPostToHooksOnTheLoopbackPortDeliversTheEventAndStatusStillWorks() async throws {
        let server = StatusServer()
        let port = 29000 + Int.random(in: 0..<900)
        server.start(port: port)
        defer { server.stop() }
        server.update(Data("{\"active\":true}".utf8))
        var events: [AgentHookEvent] = []
        server.onHook = { events.append($0) }
        try await Task.sleep(for: .milliseconds(200))

        let body = #"{"hook_event_name":"Notification","message":"Allow?","session_id":"s1"}"#
        let ok = try await Shell.run("/usr/bin/curl", ["--silent", "--max-time", "5", "-H", "X-Awake-Hook: 1", "--data-binary", body, "http://127.0.0.1:\(port)/hooks/claude"], timeout: 10)
        XCTAssertEqual(ok.stdout, #"{"ok":"received"}"#, ok.stderr)
        XCTAssertEqual(events, [AgentHookEvent(kind: "claude", action: .waiting("Allow?"), sessionId: "s1")])

        let refused = try await Shell.run("/usr/bin/curl", ["--silent", "--max-time", "5", "-o", "/dev/null", "-w", "%{http_code}", "--data-binary", body, "http://127.0.0.1:\(port)/hooks/claude"], timeout: 10)
        XCTAssertEqual(refused.stdout, "403", "no header, no event")
        XCTAssertEqual(events.count, 1)

        let status = try await Shell.run("/usr/bin/curl", ["--silent", "--max-time", "5", "http://127.0.0.1:\(port)/status.json"], timeout: 10)
        XCTAssertEqual(status.stdout, "{\"active\":true}")
    }
}
