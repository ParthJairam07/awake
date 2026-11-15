import Foundation

/// Turns a hook's JSON into an event. Knows Claude Code's hook input
/// (`hook_event_name`, `session_id`, `cwd`, `message`) and Codex's notify
/// payload (`type`, `thread-id`, `cwd`); anything else can say what it
/// means with an `event` field or query item.
enum AgentHookParser {
    static let maxKindLength = 32

    static func isValidKind(_ kind: String) -> Bool {
        !kind.isEmpty && kind.count <= maxKindLength
            && kind.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// `query` carries what the script adds (`event`, `pid`); the body is
    /// the agent's own JSON and may be empty.
    static func parse(kind: String, query: [String: String] = [:], body: Data) -> AgentHookEvent? {
        guard isValidKind(kind) else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        func string(_ keys: String...) -> String? {
            for key in keys {
                if let value = json[key] as? String, !value.isEmpty { return String(value.prefix(1024)) }
            }
            return nil
        }
        let name = (query["event"] ?? string("event", "hook_event_name", "type") ?? "").lowercased()
        let message = string("message", "last-assistant-message", "last_assistant_message", "reason")
        guard let action = action(for: name, message: message) else { return nil }
        var pid = query["pid"].flatMap { Int32($0) }
        if pid == nil, let n = json["pid"] as? Int { pid = Int32(exactly: n) }
        return AgentHookEvent(
            kind: kind,
            action: action,
            pid: pid.flatMap { $0 > 1 ? $0 : nil },
            sessionId: string("session_id", "thread-id", "thread_id", "session"),
            cwd: string("cwd"),
            transcriptPath: string("transcript_path")
        )
    }

    static func action(for name: String, message: String?) -> AgentHookAction? {
        switch name {
        case "notification", "waiting", "permissionrequest", "permission_request", "approval-requested":
            // Claude Code also sends a Notification when the prompt has
            // sat idle for a minute after a finished turn. That is rest,
            // not a question.
            if let message, message.lowercased().contains("waiting for your input") { return .finished }
            return .waiting(message)
        case "stop", "subagentstop", "finished", "done", "agent-turn-complete", "turn-complete":
            return .finished
        case "pretooluse", "posttooluse", "userpromptsubmit", "heartbeat", "busy", "sessionstart", "start":
            return .heartbeat
        case "sessionend", "exit", "exited", "ended":
            return .ended(message)
        default:
            return nil
        }
    }
}

/// One parsed HTTP request, enough for the status and hook endpoints.
struct HookHTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
}

enum HookHTTP {
    /// Largest request accepted, head and body together.
    static let maxBytes = 256 * 1024
    /// The header a TCP hook post must carry. A web page cannot set it
    /// without a CORS preflight, which this server never answers, so a
    /// page open in a browser cannot forge agent events.
    static let requiredHeader = "x-awake-hook"

    enum Parse: Equatable, Sendable {
        case needMore
        case request(HookHTTPRequest)
        case invalid
    }

    /// Parses what has arrived so far.
    static func parse(_ data: Data) -> Parse {
        guard data.count <= maxBytes else { return .invalid }
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count >= 16 * 1024 ? .invalid : .needMore
        }
        guard let head = String(data: data[data.startIndex..<headEnd.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxBytes else { return .invalid }
        let bodyStart = headEnd.upperBound
        let available = data.endIndex - bodyStart
        guard available >= length else { return .needMore }
        let target = String(requestLine[1])
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var query: [String: String] = [:]
        if parts.count == 2 {
            for item in parts[1].split(separator: "&") {
                let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = pair.first.map(String.init)?.removingPercentEncoding else { continue }
                query[key] = pair.count == 2 ? (String(pair[1]).removingPercentEncoding ?? "") : ""
            }
        }
        return .request(HookHTTPRequest(
            method: String(requestLine[0]),
            path: String(parts[0]),
            query: query,
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + length))
        ))
    }

    /// The kind in `/hooks/<kind>`, nil for any other path.
    static func hookKind(path: String) -> String? {
        let prefix = "/hooks/"
        guard path.hasPrefix(prefix) else { return nil }
        let kind = String(path.dropFirst(prefix.count))
        return AgentHookParser.isValidKind(kind) ? kind : nil
    }

    static func isHookPath(_ path: String) -> Bool { path.hasPrefix("/hooks") }

    /// Handles a hook request: the reply, and the event to deliver when
    /// the request was a good one. `overTCP` applies the header rule; the
    /// Unix socket is owner-only and needs none.
    static func handleHook(_ request: HookHTTPRequest, overTCP: Bool) -> (reply: Data, event: AgentHookEvent?) {
        func reply(_ status: Int, _ reason: String, _ message: String) -> Data {
            StatusHTTP.response(status: status, reason: reason, body: Data("{\"\(status < 300 ? "ok" : "error")\":\"\(message)\"}".utf8))
        }
        guard request.method == "POST" else { return (reply(405, "Method Not Allowed", "POST /hooks/<kind>"), nil) }
        if overTCP {
            guard request.headers[requiredHeader] != nil, request.headers["origin"] == nil else {
                return (reply(403, "Forbidden", "missing X-Awake-Hook header"), nil)
            }
        }
        guard let kind = hookKind(path: request.path) else { return (reply(404, "Not Found", "not found"), nil) }
        guard let event = AgentHookParser.parse(kind: kind, query: request.query, body: request.body) else {
            return (reply(422, "Unprocessable Content", "unknown event"), nil)
        }
        return (reply(200, "OK", "received"), event)
    }
}
