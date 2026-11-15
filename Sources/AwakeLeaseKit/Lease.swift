import Foundation

/// Phase 4: one request to keep the Mac awake, made by a person or an agent.
///
/// A lease is one JSON file, `<id>.json`, in the leases directory
/// (`LeaseHome.leasesDirectory`). The directory is the whole interface: the
/// `awake` command and the MCP server write and delete files there, and the
/// app watches it. Nothing talks to the app over a socket, so a lease can
/// be asked for while the app is not running and is picked up at launch.
///
/// This type lives in AwakeLeaseKit, which the app and the command both
/// link, so the file one writes is the file the other reads.
public struct Lease: Codable, Equatable, Sendable, Identifiable {
    /// Bumped when the file's meaning changes. A file with a newer version
    /// than this build knows is not a lease to it.
    public static let currentVersion = 1

    public var version: Int
    public var id: UUID
    /// Who asked: a user name, or an agent's name ("claude").
    public var owner: String
    /// Why, in the owner's words ("refactor billing").
    public var reason: String
    public var createdAt: Date
    /// The lease is void from this moment whatever `until` says.
    public var expiresAt: Date
    /// Ends the lease early: once the process, pane or command it names
    /// has finished and stayed finished for `graceSeconds`.
    public var until: LeaseUntil?
    /// How long `until` has to stay finished before the lease goes. Also
    /// the time a `--until-exit` lease outlives its command.
    public var graceSeconds: Int
    public var source: LeaseSource

    public init(
        id: UUID = UUID(),
        owner: String,
        reason: String,
        createdAt: Date,
        expiresAt: Date,
        until: LeaseUntil? = nil,
        graceSeconds: Int = 0,
        source: LeaseSource
    ) {
        self.version = Lease.currentVersion
        self.id = id
        self.owner = owner
        self.reason = reason
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.until = until
        self.graceSeconds = graceSeconds
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case version, id, owner, reason, createdAt, expiresAt, until, graceSeconds, source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decode(UUID.self, forKey: .id)
        owner = try c.decode(String.self, forKey: .owner)
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        expiresAt = try c.decode(Date.self, forKey: .expiresAt)
        until = try c.decodeIfPresent(LeaseUntil.self, forKey: .until)
        graceSeconds = try c.decodeIfPresent(Int.self, forKey: .graceSeconds) ?? 0
        source = try c.decode(LeaseSource.self, forKey: .source)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        // Lower case, as in the file's name; UUID's own encoding is upper.
        try c.encode(Lease.idText(id), forKey: .id)
        try c.encode(owner, forKey: .owner)
        try c.encode(reason, forKey: .reason)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(expiresAt, forKey: .expiresAt)
        try c.encodeIfPresent(until, forKey: .until)
        try c.encode(graceSeconds, forKey: .graceSeconds)
        try c.encode(source, forKey: .source)
    }

    /// The file name is the id in lower case, so it reads the same in a
    /// shell, in `awake leases` and in the JSON.
    public var fileName: String { Lease.fileName(for: id) }

    public static func fileName(for id: UUID) -> String { "\(idText(id)).json" }
    public static func idText(_ id: UUID) -> String { id.uuidString.lowercased() }
}

/// What asked for the lease.
public enum LeaseSource: String, Codable, Sendable, CaseIterable {
    case cli
    case mcp
    case hook
}

/// A process named by pid together with the two facts that tell it from a
/// later process given the same pid: its start time to the microsecond and
/// the boot it started in. The same three the app's freeze journal keeps.
public struct LeaseProcess: Codable, Equatable, Hashable, Sendable {
    public var pid: Int32
    public var startedAt: Int64
    public var startedAtMicros: Int32
    public var bootSession: String

    public init(pid: Int32, startedAt: Int64, startedAtMicros: Int32, bootSession: String) {
        self.pid = pid
        self.startedAt = startedAt
        self.startedAtMicros = startedAtMicros
        self.bootSession = bootSession
    }
}

/// A tmux pane as it was when the lease was made. `target` is what the
/// owner typed (`session:window.pane`), kept for display. The pane is
/// looked up again by tmux's own id for it (`%N`) on the server at
/// `socketPath`, and counts as the same pane only while its first process
/// is still `process`: ids start again from %0 when a server restarts, so
/// the id alone could name a stranger's pane later.
public struct LeasePane: Equatable, Hashable, Sendable {
    public var target: String
    public var paneId: String
    public var socketPath: String
    public var process: LeaseProcess

    public init(target: String, paneId: String, socketPath: String, process: LeaseProcess) {
        self.target = target
        self.paneId = paneId
        self.socketPath = socketPath
        self.process = process
    }
}

/// The condition that ends a lease before its expiry.
public enum LeaseUntil: Equatable, Sendable {
    /// `--until-pid`: held while this exact process is alive.
    case pid(LeaseProcess)
    /// `--until-tmux`: held while this pane exists, is not dead, and runs
    /// something other than a bare shell.
    case tmux(LeasePane)
    /// `--until-exit -- cmd`: held while the command the `awake` process
    /// started is alive. `name` is the command's first word, for display;
    /// its arguments are never written down.
    case command(LeaseProcess, name: String)

    public var kind: String {
        switch self {
        case .pid: "pid"
        case .tmux: "tmux"
        case .command: "command"
        }
    }

    /// "pid 4242", "tmux work:1.0", "command make".
    public var summary: String {
        switch self {
        case let .pid(p): "pid \(p.pid)"
        case let .tmux(pane): "tmux \(pane.target)"
        case let .command(_, name): "command \(name)"
        }
    }
}

extension LeaseUntil: Codable {
    // Flat keys beside "kind", so the file reads plainly and a shell can
    // pick a field out with plutil.
    private enum CodingKeys: String, CodingKey {
        case kind, pid, startedAt, startedAtMicros, bootSession, target, paneId, socketPath, name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        func process() throws -> LeaseProcess {
            LeaseProcess(
                pid: try c.decode(Int32.self, forKey: .pid),
                startedAt: try c.decode(Int64.self, forKey: .startedAt),
                startedAtMicros: try c.decode(Int32.self, forKey: .startedAtMicros),
                bootSession: try c.decode(String.self, forKey: .bootSession)
            )
        }
        switch kind {
        case "pid":
            self = .pid(try process())
        case "tmux":
            self = .tmux(LeasePane(
                target: try c.decode(String.self, forKey: .target),
                paneId: try c.decode(String.self, forKey: .paneId),
                socketPath: try c.decode(String.self, forKey: .socketPath),
                process: try process()
            ))
        case "command":
            self = .command(try process(), name: try c.decodeIfPresent(String.self, forKey: .name) ?? "")
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown until kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        func process(_ p: LeaseProcess) throws {
            try c.encode(p.pid, forKey: .pid)
            try c.encode(p.startedAt, forKey: .startedAt)
            try c.encode(p.startedAtMicros, forKey: .startedAtMicros)
            try c.encode(p.bootSession, forKey: .bootSession)
        }
        switch self {
        case let .pid(p):
            try process(p)
        case let .tmux(pane):
            try c.encode(pane.target, forKey: .target)
            try c.encode(pane.paneId, forKey: .paneId)
            try c.encode(pane.socketPath, forKey: .socketPath)
            try process(pane.process)
        case let .command(p, name):
            try process(p)
            try c.encode(name, forKey: .name)
        }
    }
}

/// The JSON form shared by everything that reads or writes a lease: ISO
/// 8601 dates in whole seconds (`2027-01-15T08:00:00Z`), as the app's own
/// files use, sorted keys, one field per line.
public enum LeaseJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// A date as the files hold it; sub-second parts are dropped, so a date
    /// compares equal to itself after a round trip.
    public static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}
