import Foundation

/// Phase 0: many agents plus Docker fill memory and disk overnight, and
/// the Mac keeps running slower and slower with nobody at it. The rules
/// are pure; `ResourceMonitor` feeds them from the memory-pressure source
/// and the home volume, and notifies once per crossing.
enum ResourceRules {
    enum MemoryPressure: Equatable, Sendable {
        case normal
        case warning
        case critical
    }

    /// Low when under the floor; the alert re-arms only once the free space
    /// is back above the floor plus `diskHysteresisGB`, so a disk hovering
    /// at the floor is announced once, not every poll.
    static let diskHysteresisGB = 2

    static func diskLow(freeBytes: Int64, floorGB: Int) -> Bool {
        floorGB > 0 && freeBytes < Int64(floorGB) * 1_000_000_000
    }

    static func diskRecovered(freeBytes: Int64, floorGB: Int) -> Bool {
        freeBytes >= Int64(floorGB + diskHysteresisGB) * 1_000_000_000
    }

    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}

/// Tracks the alerted state so each crossing is announced once.
struct ResourceAlertState: Equatable, Sendable {
    private(set) var diskAlerted = false
    private(set) var memoryAlerted = false

    /// Returns the notification body to post, or nil.
    mutating func disk(freeBytes: Int64, floorGB: Int) -> String? {
        if !diskAlerted, ResourceRules.diskLow(freeBytes: freeBytes, floorGB: floorGB) {
            diskAlerted = true
            return "\(ResourceRules.gigabytes(freeBytes)) free, below the \(floorGB) GB floor. Agents and Docker fill disks overnight; builds and commits fail when it is full."
        }
        if diskAlerted, ResourceRules.diskRecovered(freeBytes: freeBytes, floorGB: floorGB) {
            diskAlerted = false
        }
        return nil
    }

    /// Critical is announced on entry; warning is logged by the caller.
    mutating func memory(_ pressure: ResourceRules.MemoryPressure) -> String? {
        switch pressure {
        case .critical where !memoryAlerted:
            memoryAlerted = true
            return "macOS reports critical memory pressure. Agents are being swapped; the Mac may become unresponsive."
        case .normal:
            memoryAlerted = false
            return nil
        default:
            return nil
        }
    }
}

/// Memory pressure from the kernel's dispatch source, free disk from the
/// home volume on a timer. Only while started (a session is running).
@MainActor
final class ResourceMonitor {
    typealias DiskReader = @Sendable () -> Int64?

    private let notifier: any Notifying
    private let configProvider: @MainActor () -> Config
    private let diskReader: DiskReader
    private let diskInterval: TimeInterval
    private var state = ResourceAlertState()
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private var diskTimer: (any DispatchSourceTimer)?
    private(set) var running = false

    init(
        notifier: any Notifying,
        diskReader: @escaping DiskReader = { ResourceMonitor.readFreeDisk() },
        diskInterval: TimeInterval = 300,
        config: @escaping @MainActor () -> Config
    ) {
        self.notifier = notifier
        self.diskReader = diskReader
        self.diskInterval = diskInterval
        self.configProvider = config
    }

    func start() {
        guard !running else { return }
        running = true
        state = ResourceAlertState()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let mask = source.data
            let level: ResourceRules.MemoryPressure = mask.contains(.critical) ? .critical : mask.contains(.warning) ? .warning : .normal
            MainActor.assumeIsolated { self.memoryPressure(level) }
        }
        source.resume()
        pressureSource = source

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: diskInterval, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.checkDisk() }
        }
        timer.resume()
        diskTimer = timer
    }

    func stop() {
        guard running else { return }
        running = false
        pressureSource?.cancel()
        pressureSource = nil
        diskTimer?.cancel()
        diskTimer = nil
    }

    /// One disk check; the timer calls this, and tests call it directly.
    func checkDisk() {
        guard running else { return }
        let config = configProvider()
        guard config.resourceAlerts, let free = diskReader() else { return }
        if let body = state.disk(freeBytes: free, floorGB: config.freeDiskFloorGB) {
            Log.info("free disk \(ResourceRules.gigabytes(free)) below the \(config.freeDiskFloorGB) GB floor")
            notifier.post(title: "Disk almost full", body: body)
        }
    }

    /// One pressure event; the source calls this, and tests call it directly.
    func memoryPressure(_ level: ResourceRules.MemoryPressure) {
        guard running, configProvider().resourceAlerts else { return }
        if level != .normal { Log.info("memory pressure \(level)") }
        if let body = state.memory(level) {
            notifier.post(title: "Memory pressure critical", body: body)
        }
    }

    /// Free space for important usage on the volume holding the home
    /// directory, which is where agents write.
    nonisolated static func readFreeDisk() -> Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return free
    }
}
