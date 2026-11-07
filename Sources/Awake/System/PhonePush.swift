import Foundation

/// Phase 1: every notification Awake posts on the Mac also goes to the
/// phone, through ntfy and/or Pushover. No app to build, no relay of our
/// own: an HTTPS POST per alert. The local notification is posted first
/// and never waits on the network; delivery runs in the background, with
/// one retry, and a failure is logged and announced locally once per
/// launch, so a dead topic does not go unnoticed for a week.

/// Something that performs one HTTP request. Tests record requests and
/// script the status; the app uses URLSession.
protocol PushTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (status: Int, body: Data)
}

struct URLSessionPushTransport: PushTransport {
    static let timeout: TimeInterval = 10

    func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Self.timeout
        config.timeoutIntervalForResource = Self.timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// The phone secrets, read from the login keychain (service `awake-phone`).
/// All optional: a service whose secret is missing is skipped and reported.
struct PhoneSecrets: Equatable, Sendable {
    var ntfyToken: String?
    var pushoverAppToken: String?
    var pushoverUserKey: String?

    static let service = "awake-phone"
    static let ntfyTokenAccount = "ntfy-token"
    static let pushoverAppTokenAccount = "pushover-app-token"
    static let pushoverUserKeyAccount = "pushover-user-key"

    static let none = PhoneSecrets()
}

/// Pure request builders and answer checks, so the wire format is tested
/// without a network.
enum PhonePush {
    enum Priority: String, Sendable {
        case normal
        case high
    }

    /// Alerts that should break through a silenced phone.
    static func priority(forTitle title: String) -> Priority {
        let urgent = ["Session ended", "Sleep restored", "Session not started", "Session not ended", "Not restored", "Restore incomplete",
                      "Charger too weak", "Internet down", "Screen not locked", "Memory pressure critical", "Disk almost full"]
        return urgent.contains(where: { title.hasPrefix($0) }) ? .high : .normal
    }

    /// ntfy: `POST {server}/{topic}` with the message as the body and the
    /// title, priority and tags as headers. nil when the server URL or
    /// topic is unusable.
    static func ntfyRequest(server: String, topic: String, token: String?, title: String, body: String, priority: Priority) -> URLRequest? {
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty, !topic.contains("/"), !topic.contains(" ") else { return nil }
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = Self.defaultNtfyServer }
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: "\(base)/\(topic)"), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(asciiHeader(title), forHTTPHeaderField: "Title")
        request.setValue(priority == .high ? "high" : "default", forHTTPHeaderField: "Priority")
        request.setValue("awake", forHTTPHeaderField: "Tags")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = Data(body.utf8)
        return request
    }

    static let defaultNtfyServer = "https://ntfy.sh"

    /// HTTP headers are Latin-1 on the wire; ntfy reads a header with
    /// non-ASCII as garbage. The title is kept ASCII, the body (UTF-8) is
    /// where the degree signs and arrows go.
    static func asciiHeader(_ s: String) -> String {
        String(s.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 ? Character($0) : "?" })
    }

    /// Pushover: `POST https://api.pushover.net/1/messages.json`, form body.
    static func pushoverRequest(appToken: String, userKey: String, title: String, body: String, priority: Priority) -> URLRequest? {
        guard !appToken.isEmpty, !userKey.isEmpty else { return nil }
        var request = URLRequest(url: URL(string: "https://api.pushover.net/1/messages.json")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let fields: [(String, String)] = [
            ("token", appToken),
            ("user", userKey),
            ("title", title),
            ("message", body),
            ("priority", priority == .high ? "1" : "0"),
        ]
        request.httpBody = Data(formEncode(fields).utf8)
        return request
    }

    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    static func accepted(status: Int) -> Bool {
        (200..<300).contains(status)
    }

    /// Which services the config turns on, before secrets are consulted.
    static func servicesEnabled(config: Config) -> (ntfy: Bool, pushover: Bool) {
        (!config.ntfyTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, config.pushoverEnabled)
    }
}

/// The `Notifying` the app uses: posts locally, then forwards to the phone.
final class PhoneAlerts: Notifying, @unchecked Sendable {
    typealias SecretsReader = @Sendable () async -> PhoneSecrets

    /// The Mac-side notifier the forwards wrap; AppServices asks it for
    /// notification authorization.
    let local: any Notifying
    private let transport: any PushTransport
    private let secrets: SecretsReader
    private let lock = NSLock()
    /// Set once the manager exists; nil (tests without one) sends nothing.
    private var _configProvider: (@MainActor () -> Config)?
    private var _failureAnnounced = false
    private var _inflight: [UUID: Task<Void, Never>] = [:]
    /// Push outcomes, newest last, for tests and the Settings test button.
    private var _log: [String] = []

    init(local: any Notifying, transport: any PushTransport = URLSessionPushTransport(), secrets: @escaping SecretsReader) {
        self.local = local
        self.transport = transport
        self.secrets = secrets
    }

    var configProvider: (@MainActor () -> Config)? {
        get { lock.withLock { _configProvider } }
        set { lock.withLock { _configProvider = newValue } }
    }

    var deliveryLog: [String] { lock.withLock { _log } }

    func post(title: String, body: String) {
        local.post(title: title, body: body)
        guard title != Self.failureTitle else { return }
        let id = UUID()
        let task = Task { [weak self] in
            await self?.forward(title: title, body: body)
            self?.lock.withLock { _ = self?._inflight.removeValue(forKey: id) }
        }
        lock.withLock { _inflight[id] = task }
    }

    /// Waits for every forward started so far. Tests; the app never waits.
    func flush() async {
        let tasks = lock.withLock { Array(_inflight.values) }
        for t in tasks { await t.value }
    }

    static let failureTitle = "Phone alert failed"

    /// Sends a test alert now and returns nil on success or the problem.
    func sendTest() async -> String? {
        let problems = await deliver(title: "Awake test", body: "Phone alerts are working.", announceFailure: false)
        return problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    private func forward(title: String, body: String) async {
        _ = await deliver(title: title, body: body, announceFailure: true)
    }

    /// Returns one line per service that failed; empty when nothing was
    /// configured or everything was accepted.
    private func deliver(title: String, body: String, announceFailure: Bool) async -> [String] {
        guard let provider = configProvider else { return [] }
        let config = await MainActor.run { provider() }
        let enabled = PhonePush.servicesEnabled(config: config)
        guard enabled.ntfy || enabled.pushover else { return [] }
        let secrets = await secrets()
        let priority = PhonePush.priority(forTitle: title)
        var problems: [String] = []
        if enabled.ntfy {
            if let request = PhonePush.ntfyRequest(server: config.ntfyServer, topic: config.ntfyTopic, token: secrets.ntfyToken, title: title, body: body, priority: priority) {
                if let problem = await send(request, service: "ntfy") { problems.append(problem) }
            } else {
                problems.append("ntfy: the server or topic in Settings is not usable.")
            }
        }
        if enabled.pushover {
            if let request = PhonePush.pushoverRequest(appToken: secrets.pushoverAppToken ?? "", userKey: secrets.pushoverUserKey ?? "", title: title, body: body, priority: priority) {
                if let problem = await send(request, service: "Pushover") { problems.append(problem) }
            } else {
                problems.append("Pushover: the app token or user key is missing from the keychain.")
            }
        }
        for p in problems { Log.error("phone alert: \(p)") }
        if announceFailure, !problems.isEmpty {
            let first = lock.withLock { () -> Bool in
                if _failureAnnounced { return false }
                _failureAnnounced = true
                return true
            }
            if first {
                local.post(title: Self.failureTitle, body: "\(problems.joined(separator: " ")) Awake keeps posting on the Mac; check the Phone section of Settings.")
            }
        }
        return problems
    }

    /// One attempt and one retry; nil on success, the problem otherwise.
    private func send(_ request: URLRequest, service: String) async -> String? {
        var last = ""
        for attempt in 0..<2 {
            do {
                let (status, body) = try await transport.send(request)
                if PhonePush.accepted(status: status) {
                    lock.withLock { _log.append("\(service): ok") }
                    return nil
                }
                let text = String(data: body.prefix(200), encoding: .utf8) ?? ""
                last = "\(service) answered \(status)\(text.isEmpty ? "" : ": \(text)")"
                // A client error will not improve on retry.
                if (400..<500).contains(status) { break }
            } catch {
                last = "\(service) could not be reached: \(error.localizedDescription)"
            }
            if attempt == 0 { try? await Task.sleep(for: .seconds(2)) }
        }
        lock.withLock { _log.append("\(service): \(last)") }
        return "\(last)."
    }
}

/// Reads the phone secrets from the login keychain on the keychain queue.
enum KeychainPhoneSecrets {
    static func read(keychain: any KeychainStoring = KeychainStore(), queue: KeychainQueue = .shared) async -> PhoneSecrets {
        do {
            return try await queue.run {
                PhoneSecrets(
                    ntfyToken: try keychain.get(service: PhoneSecrets.service, account: PhoneSecrets.ntfyTokenAccount),
                    pushoverAppToken: try keychain.get(service: PhoneSecrets.service, account: PhoneSecrets.pushoverAppTokenAccount),
                    pushoverUserKey: try keychain.get(service: PhoneSecrets.service, account: PhoneSecrets.pushoverUserKeyAccount)
                )
            }
        } catch {
            Log.error("phone secrets could not be read: \(error.localizedDescription)")
            return .none
        }
    }
}
