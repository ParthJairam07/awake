import Foundation

/// Phase 3: the HTTP pieces of the phone server, pure and tested without
/// sockets, in the manner of `StatusHTTP`. One request per connection
/// (`Connection: close`), a bounded head and body, and nothing parsed that
/// the phone app does not send.
struct PhoneRequest: Equatable, Sendable {
    var method: String
    /// The path with its percent-encoding still in place and no query.
    var path: String
    var query: [String: String] = [:]
    /// Header names lowercased.
    var headers: [String: String] = [:]
    var body = Data()

    /// The bearer token of `Authorization: Bearer <token>`, if any.
    var bearerToken: String? {
        guard let value = headers["authorization"] else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    /// Whether the body is declared as JSON. Every POST must be: a page on
    /// another origin cannot send that type without a preflight, which
    /// this server never answers.
    var hasJSONContentType: Bool {
        guard let type = headers["content-type"]?.lowercased() else { return false }
        return type.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/json"
    }
}

enum PhoneHTTPParse: Equatable, Sendable {
    /// More bytes are needed.
    case incomplete
    case request(PhoneRequest)
    /// Not a request this server reads; answered with `status` and closed.
    case invalid(status: Int, message: String)
}

struct PhoneResponse: Equatable, Sendable {
    var status: Int
    var contentType: String
    var body: Data
    var extraHeaders: [String: String] = [:]

    static let jsonType = "application/json; charset=utf-8"

    static func json(_ data: Data, status: Int = 200) -> PhoneResponse {
        PhoneResponse(status: status, contentType: jsonType, body: data)
    }

    /// `{"ok":…, …}` from a dictionary of JSON values.
    static func object(_ object: [String: Any], status: Int = 200) -> PhoneResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return json(data, status: status)
    }

    static func ok(_ message: String? = nil) -> PhoneResponse {
        var o: [String: Any] = ["ok": true]
        if let message { o["message"] = message }
        return object(o)
    }

    static func error(_ status: Int, _ message: String, extra: [String: Any] = [:]) -> PhoneResponse {
        var o = extra
        o["ok"] = false
        o["error"] = message
        return object(o, status: status)
    }

    static let notFound = PhoneResponse.error(404, "not found")
}

enum PhoneHTTP {
    /// The request line and headers. A phone browser sends well under 4 KB.
    static let maxHeadBytes = 16 * 1024
    /// The largest body any route reads: a web push subscription or an
    /// answer typed for an agent.
    static let maxBodyBytes = 64 * 1024
    static let methods: Set<String> = ["GET", "HEAD", "POST"]

    private static let headEnd = Data("\r\n\r\n".utf8)

    /// Reads one request from the bytes received so far.
    static func parse(_ buffer: Data) -> PhoneHTTPParse {
        guard let range = buffer.range(of: headEnd) else {
            return buffer.count > maxHeadBytes ? .invalid(status: 431, message: "request head too large") : .incomplete
        }
        guard range.lowerBound - buffer.startIndex <= maxHeadBytes else {
            return .invalid(status: 431, message: "request head too large")
        }
        guard let head = String(data: buffer[buffer.startIndex..<range.lowerBound], encoding: .utf8) else {
            return .invalid(status: 400, message: "request head is not UTF-8")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid(status: 400, message: "bad request line")
        }
        let method = String(requestLine[0])
        guard methods.contains(method) else {
            return .invalid(status: 405, message: "method not allowed")
        }
        let target = String(requestLine[1])
        guard target.hasPrefix("/") else {
            return .invalid(status: 400, message: "bad request target")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                return .invalid(status: 400, message: "bad header")
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // A repeated Content-Length or Authorization is how one request
            // is made to look like two; refuse it instead of picking one.
            if headers[name] != nil, name == "content-length" || name == "authorization" || name == "host" {
                return .invalid(status: 400, message: "repeated \(name) header")
            }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil {
            return .invalid(status: 501, message: "transfer-encoding is not supported")
        }
        var length = 0
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0, raw.allSatisfy(\.isNumber) else {
                return .invalid(status: 400, message: "bad content-length")
            }
            guard n <= maxBodyBytes else {
                return .invalid(status: 413, message: "request body too large")
            }
            length = n
        }
        let bodyStart = range.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }
        let (path, query) = split(target: target)
        return .request(PhoneRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: Data(buffer[bodyStart..<(bodyStart + length)])
        ))
    }

    /// `/a/b?x=1&y=2` → (`/a/b`, [x: 1, y: 2]). Query values are
    /// percent-decoded; a repeated key keeps its first value.
    static func split(target: String) -> (path: String, query: [String: String]) {
        var target = target
        if let hash = target.firstIndex(of: "#") { target = String(target[..<hash]) }
        guard let mark = target.firstIndex(of: "?") else { return (target, [:]) }
        var query: [String: String] = [:]
        for pair in target[target.index(after: mark)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = kv.first, let key = String(rawKey).removingPercentEncoding, !key.isEmpty else { continue }
            let rawValue = kv.count > 1 ? String(kv[1]).replacingOccurrences(of: "+", with: " ") : ""
            if query[key] == nil { query[key] = rawValue.removingPercentEncoding ?? "" }
        }
        return (String(target[..<mark]), query)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 201: "Created"
        case 204: "No Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }

    /// Sent with every response. The page may only load and call its own
    /// origin, is never framed, and nothing is cached by a proxy or the
    /// browser's HTTP cache (the service worker keeps the shell).
    static let securityHeaders: [(String, String)] = [
        ("Cache-Control", "no-store"),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "no-referrer"),
        ("X-Frame-Options", "DENY"),
        ("Content-Security-Policy", "default-src 'self'; img-src 'self' blob: data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"),
    ]

    static func head(status: Int, contentType: String, contentLength: Int?, extra: [String: String] = [:]) -> Data {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        text += "Content-Type: \(contentType)\r\n"
        if let contentLength { text += "Content-Length: \(contentLength)\r\n" }
        for (name, value) in securityHeaders { text += "\(name): \(value)\r\n" }
        for (name, value) in extra.sorted(by: { $0.key < $1.key }) { text += "\(name): \(value)\r\n" }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }

    /// The bytes of a whole response. A HEAD gets the headers of the GET
    /// and no body.
    static func serialize(_ response: PhoneResponse, headOnly: Bool = false) -> Data {
        let head = head(status: response.status, contentType: response.contentType, contentLength: response.body.count, extra: response.extraHeaders)
        return headOnly ? head : head + response.body
    }

    /// The head of the event stream; the events follow for as long as the
    /// connection lives.
    static func eventStreamHead() -> Data {
        head(status: 200, contentType: "text/event-stream; charset=utf-8", contentLength: nil, extra: ["X-Accel-Buffering": "no"])
    }

    /// One server-sent event. `data` is a single line (compact JSON).
    static func event(name: String, data: Data) -> Data {
        Data("event: \(name)\ndata: ".utf8) + data + Data("\n\n".utf8)
    }

    /// A comment line: keeps proxies and the phone from timing the stream
    /// out, and tells the phone the Mac is still there.
    static let keepalive = Data(": keepalive\n\n".utf8)

    /// JSON on one line, for an event's `data:` field. nil when `data` is
    /// not JSON.
    static func compactJSON(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
}

/// Method + path patterns with `{name}` parameters. Only what is added is
/// served: no match is a 404, whatever the method.
struct PhoneRouter<Route: Sendable>: Sendable {
    private enum Segment: Sendable, Equatable {
        case literal(String)
        case parameter(String)
    }

    private struct Entry: Sendable {
        let method: String
        let segments: [Segment]
        let route: Route
    }

    struct Match {
        let route: Route
        let parameters: [String: String]
    }

    private var entries: [Entry] = []

    init() {}

    mutating func add(_ method: String, _ pattern: String, _ route: Route) {
        let segments = pattern.split(separator: "/", omittingEmptySubsequences: true).map { part -> Segment in
            if part.hasPrefix("{"), part.hasSuffix("}") {
                return .parameter(String(part.dropFirst().dropLast()))
            }
            return .literal(String(part))
        }
        entries.append(Entry(method: method, segments: segments, route: route))
    }

    /// A HEAD matches the GET of the same path. Parameters are
    /// percent-decoded; one that decodes to nothing, to a `/`, to a dot
    /// segment or to a control character matches nothing.
    func match(method: String, path: String) -> Match? {
        guard path.hasPrefix("/"), !path.contains("//") else { return nil }
        let parts = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let wanted = parts == [""] ? [] : parts
        let method = method == "HEAD" ? "GET" : method
        for entry in entries where entry.method == method && entry.segments.count == wanted.count {
            var parameters: [String: String] = [:]
            var matched = true
            for (segment, part) in zip(entry.segments, wanted) {
                switch segment {
                case let .literal(text):
                    if text != part { matched = false }
                case let .parameter(name):
                    guard let value = part.removingPercentEncoding, Self.isSafeParameter(value) else {
                        matched = false
                        break
                    }
                    parameters[name] = value
                }
                if !matched { break }
            }
            if matched { return Match(route: entry.route, parameters: parameters) }
        }
        return nil
    }

    static func isSafeParameter(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200, value != ".", value != ".." else { return false }
        return !value.contains("/") && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
