import Foundation

/// Where the leases live, resolved the way the app resolves its own files:
/// `~/Library/Application Support/Awake`, or the directory in `AWAKE_HOME`
/// when that is set (tests, and the recovery scripts honour the same
/// variable).
public struct LeaseHome: Sendable, Equatable {
    public static let environmentKey = "AWAKE_HOME"

    public let appSupport: URL

    public init(appSupport: URL) {
        self.appSupport = appSupport
    }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> LeaseHome {
        if let root = env[environmentKey], !root.isEmpty {
            return LeaseHome(appSupport: URL(fileURLWithPath: root, isDirectory: true))
        }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return LeaseHome(appSupport: library.appendingPathComponent("Application Support/Awake", isDirectory: true))
    }

    public static let leasesDirectoryName = "leases"

    public var leasesDirectory: URL { appSupport.appendingPathComponent(Self.leasesDirectoryName, isDirectory: true) }
    public var statusFile: URL { appSupport.appendingPathComponent("status.json") }
    public var configFile: URL { appSupport.appendingPathComponent("config.json") }

    /// The lease settings the command needs to know, read straight from the
    /// app's config.json; a missing file or key is the app's default.
    public struct Settings: Equatable, Sendable {
        public var enabled = true
        public var capHours = LeaseRules.defaultCapHours
        public var mayStartSession = true

        public init() {}

        public var capSeconds: TimeInterval { TimeInterval(max(capHours, 1)) * 3600 }
    }

    public func settings() -> Settings {
        var s = Settings()
        guard let data = try? Data(contentsOf: configFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return s }
        if let v = object["leasesEnabled"] as? Bool { s.enabled = v }
        if let v = object["leaseCapHours"] as? Int, v >= 1 { s.capHours = v }
        if let v = object["leasesMayStartSession"] as? Bool { s.mayStartSession = v }
        return s
    }
}
