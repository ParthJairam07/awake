import AwakeLeaseKit
import Foundation

/// `awake mcp`: the lease commands as Model Context Protocol tools, over
/// stdio. JSON-RPC 2.0, one message per line, as the stdio transport of
/// MCP 2025-06-18 sets out: requests and notifications arrive on stdin,
/// responses leave on stdout, and nothing else is ever written to stdout.
///
/// Implemented: `initialize`, `ping`, `tools/list`, `tools/call`.
/// Notifications are read and ignored. Everything else is "method not
/// found". No dependency: the messages are small enough for
/// JSONSerialization.
///
/// A lease made here is a plain lease: it lasts until it is released or
/// expires, also if the agent's session ends first. An agent often asks
/// for time for work that outlives its own turn, and the expiry it chose,
/// under the owner's cap, is what bounds it.
struct MCPServer: Sendable {
    static let latestProtocol = "2025-06-18"
    /// Revisions whose `initialize`, `tools/list` and `tools/call` this
    /// server answers the same way. A client asking for one gets it back;
    /// for any other the answer is the latest, and the client decides.
    static let supportedProtocols: Set<String> = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let env: CLIEnvironment

    // MARK: Transport

    /// Reads stdin to its end. Returns the exit status.
    func serveStandardInput() -> Int32 {
        var session = Session()
        while let line = readLine(strippingNewline: true) {
            if let reply = handle(line: line, session: &session) {
                env.out(reply)
            }
        }
        return 0
    }

    /// What the client said in `initialize`.
    struct Session: Equatable {
        var clientName: String?
    }

    /// One line in, at most one line out. nil for a notification, a blank
    /// line, or a response sent to us (this server asks the client nothing).
    func handle(line: String, session: inout Session) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return Self.encode(Self.error(id: NSNull(), code: -32700, message: "Parse error"))
        }
        guard let message = json as? [String: Any] else {
            // An array is a JSON-RPC batch, which MCP 2025-06-18 removed.
            let text = json is [Any] ? "Invalid Request: batches are not supported" : "Invalid Request"
            return Self.encode(Self.error(id: NSNull(), code: -32600, message: text))
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // A response or an error addressed to this server: nothing to do.
            if message["result"] != nil || message["error"] != nil { return nil }
            return Self.encode(Self.error(id: id ?? NSNull(), code: -32600, message: "Invalid Request: no method"))
        }
        // No id: a notification. Never answered, whatever it is.
        guard let id, !(id is NSNull) else { return nil }
        guard id is String || id is NSNumber else {
            return Self.encode(Self.error(id: NSNull(), code: -32600, message: "Invalid Request: id must be a string or a number"))
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            if let client = params["clientInfo"] as? [String: Any], let name = client["name"] as? String {
                session.clientName = LeaseRules.cleanOwner(name)
            }
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.supportedProtocols.contains($0) ? $0 : nil } ?? Self.latestProtocol
            return Self.encode(Self.result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "awake", "title": "Awake", "version": env.version],
                "instructions": Self.instructions,
            ]))
        case "ping":
            return Self.encode(Self.result(id: id, [:]))
        case "tools/list":
            return Self.encode(Self.result(id: id, ["tools": Self.tools]))
        case "tools/call":
            guard let name = params["name"] as? String else {
                return Self.encode(Self.error(id: id, code: -32602, message: "Invalid params: no tool name"))
            }
            guard Self.toolNames.contains(name) else {
                return Self.encode(Self.error(id: id, code: -32602, message: "Unknown tool: \(name)"))
            }
            if let arguments = params["arguments"], !(arguments is [String: Any]), !(arguments is NSNull) {
                return Self.encode(Self.error(id: id, code: -32602, message: "Invalid params: arguments must be an object"))
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return Self.encode(Self.result(id: id, call(name, arguments, session: session)))
        default:
            return Self.encode(Self.error(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    // MARK: Tools

    static let instructions = "Awake keeps this Mac awake while work runs unattended. Before a long task, call awake_lease with how long you need and why; call awake_release with the id when the task is done, or awake_extend if it needs longer. The Mac's owner caps how long leases can hold it, and battery and heat limits end a session whatever leases say."

    static let toolNames: Set<String> = ["awake_lease", "awake_release", "awake_leases", "awake_status", "awake_extend"]

    static var tools: [[String: Any]] { [
        [
            "name": "awake_lease",
            "title": "Ask for awake time",
            "description": "Keep this Mac awake for up to `duration` while you work. Returns the lease id; release it with awake_release when the task is done. The owner's cap may shorten it, and battery or heat limits can still end the session.",
            "inputSchema": schema([
                "duration": ["type": "string", "description": "How long at most, as a number and a unit: 90m, 2h, 1h30m."],
                "reason": ["type": "string", "description": "What the time is for, in a few words. Shown to the Mac's owner."],
                "owner": ["type": "string", "description": "Who is asking. Defaults to the MCP client's name."],
                "grace": ["type": "string", "description": "Accepted for symmetry with the command line (for example 10m); it only matters for leases tied to a process, which this tool does not make."],
            ], required: ["duration", "reason"]),
        ],
        [
            "name": "awake_release",
            "title": "Release a lease",
            "description": "Give back a lease you no longer need, by its id.",
            "inputSchema": schema(["id": ["type": "string", "description": "The lease id awake_lease returned."]], required: ["id"]),
        ],
        [
            "name": "awake_leases",
            "title": "List leases",
            "description": "The leases held now, with owner, reason and time left.",
            "inputSchema": schema([:], required: []),
        ],
        [
            "name": "awake_status",
            "title": "Awake status",
            "description": "Whether a keep-awake session is running and for how much longer, battery, lid, and the leases held.",
            "inputSchema": schema([:], required: []),
        ],
        [
            "name": "awake_extend",
            "title": "Extend a lease",
            "description": "Move a lease's expiry later by `by`.",
            "inputSchema": schema([
                "id": ["type": "string", "description": "The lease id."],
                "by": ["type": "string", "description": "How much longer: 30m, 1h."],
            ], required: ["id", "by"]),
        ],
    ] }

    private static func schema(_ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }

    /// Runs one tool. A failure of the tool is a result with `isError`,
    /// which the model can read and act on, not a protocol error.
    func call(_ name: String, _ arguments: [String: Any], session: Session) -> [String: Any] {
        let service = LeaseService(env: env)
        func text(_ key: String) throws -> String {
            guard let value = arguments[key] as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ToolError.missing(key)
            }
            return value
        }
        do {
            switch name {
            case "awake_lease":
                let duration = try LeaseService.duration(try text("duration"))
                let reason = try text("reason")
                let owner = (arguments["owner"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? session.clientName ?? "agent"
                let grace = try (arguments["grace"] as? String).map(LeaseService.grace) ?? 0
                let lease = try service.grant(duration: duration, reason: reason, owner: owner, graceSeconds: grace, source: .mcp)
                let status = LeaseStatus(lease: lease, now: env.now(), capSeconds: env.home.settings().capSeconds)
                var body = Self.object(status)
                let notes = service.cautions()
                if status.expiresAt < lease.expiresAt {
                    body["note"] = "The owner's cap is \(env.home.settings().capHours)h, so this lease counts for \(LeaseDuration.format(TimeInterval(status.remainingSeconds)))."
                }
                if !notes.isEmpty { body["warnings"] = notes }
                return Self.toolResult(body)
            case "awake_release":
                let lease = try service.find(try text("id"))
                try service.release(lease)
                return Self.toolResult(["released": Lease.idText(lease.id)])
            case "awake_leases":
                return Self.toolResult(["leases": service.statuses().map(Self.object)])
            case "awake_status":
                var body: [String: Any] = ["appRunning": env.appRunning(), "leases": service.statuses().map(Self.object)]
                if let data = service.statusData(), let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // The leases above are read from the directory now;
                    // the file's own list is as old as its last write.
                    body["status"] = status.filter { $0.key != "leases" }
                } else {
                    body["status"] = NSNull()
                }
                return Self.toolResult(body)
            case "awake_extend":
                guard let seconds = LeaseDuration.seconds(from: try text("by")) else { throw LeaseService.Failure.badDuration(try text("by")) }
                let extended = try service.extend(try service.find(try text("id")), by: seconds)
                return Self.toolResult(Self.object(LeaseStatus(lease: extended, now: env.now(), capSeconds: env.home.settings().capSeconds)))
            default:
                return Self.toolFailure("Unknown tool: \(name)")
            }
        } catch {
            return Self.toolFailure(error.localizedDescription)
        }
    }

    enum ToolError: Error, LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case let .missing(key): "\(key) is required and must be a string"
            }
        }
    }

    // MARK: JSON

    private static func object(_ status: LeaseStatus) -> [String: Any] {
        guard let data = try? LeaseJSON.encoder().encode(status), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// The structured result and the same JSON as text, for clients that
    /// read only one of the two.
    static func toolResult(_ body: [String: Any]) -> [String: Any] {
        ["content": [["type": "text", "text": encode(body, pretty: true)]], "structuredContent": body, "isError": false]
    }

    static func toolFailure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    static func result(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// One line: JSONSerialization escapes every newline inside a string,
    /// and without `.prettyPrinted` adds none of its own.
    static func encode(_ object: [String: Any], pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
