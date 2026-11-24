import Foundation
import IOKit.ps
import Network

/// The Machine tab's readings, taken when the phone asks. Each is read
/// straight from the system; one that cannot be read stays nil.
@MainActor
final class LivePhoneMachine: PhoneMachineProbing {
    private weak var services: AppServices?
    private let interfaces: NetworkInterfaces.Reader

    init(services: AppServices?, interfaces: @escaping NetworkInterfaces.Reader = { NetworkInterfaces.current() }) {
        self.services = services
        self.interfaces = interfaces
    }

    /// The battery part of the Machine tab. A Mac with no battery says so
    /// (`hasBattery` false) and reports no charging state and no flow:
    /// it is on mains, not "not charging".
    static func fill(_ info: inout PhoneMachineInfo, battery: BatteryStatus, charging: Bool, watts: () -> Double?) {
        info.hasBattery = battery != .none
        info.batteryPercent = battery.percent
        guard battery != .none else { return }
        info.isCharging = charging
        info.batteryWatts = watts()
    }

    func read() async -> PhoneMachineInfo {
        var info = PhoneMachineInfo()
        info.hostName = Self.computerName()
        let (battery, charging) = PowerMonitor.readBattery()
        Self.fill(&info, battery: battery, charging: charging, watts: { PowerMonitor.readInstantWatts() })
        info.adapterWatts = Self.adapterWatts()
        // The trend is only followed while a session runs, and only a
        // battery can be drained.
        if let services, services.running, battery != .none { info.chargerDraining = services.status.chargerDraining }
        info.thermalState = PowerMonitor.name(ProcessInfo.processInfo.thermalState)
        let thermal = await ThermalProbe.read()
        info.cpuSpeedLimit = thermal.speedLimit
        info.batteryTemperatureC = thermal.batteryTemperatureC
        info.memoryPressure = Self.memoryPressure(level: Self.readMemoryPressureLevel())
        info.freeDiskBytes = ResourceMonitor.readFreeDisk()
        info.networkType = await Self.networkType()
        if let services {
            await services.refreshSSIDForPhone()
            info.wifiSSID = services.status.wifiSSID
        }
        info.tailscaleIPv4 = Tailscale.addresses(in: interfaces()).ipv4
        info.lidClosed = LidObserver.readClamshellState()
        info.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        info.uptimeSeconds = Int(ProcessInfo.processInfo.systemUptime)
        return info
    }

    static func computerName() -> String? {
        let name = Host.current().localizedName
        return name?.isEmpty == false ? name : nil
    }

    /// The connected power adapter's rating in watts, when it reports one.
    nonisolated static func adapterWatts() -> Int? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else { return nil }
        return (details[kIOPSPowerAdapterWattsKey] as? NSNumber)?.intValue
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    nonisolated static func readMemoryPressureLevel() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return Int(level)
    }

    nonisolated static func memoryPressure(level: Int?) -> String? {
        switch level {
        case 1: "normal"
        case 2: "warning"
        case 4: "critical"
        default: nil
        }
    }

    /// The kind of the interface the default route uses right now.
    nonisolated static func networkType() async -> String? {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func first() -> Bool {
                lock.withLock {
                    if done { return false }
                    done = true
                    return true
                }
            }
        }
        let monitor = NWPathMonitor()
        let once = Once()
        let path: NWPath? = await withCheckedContinuation { continuation in
            monitor.pathUpdateHandler = { path in
                if once.first() { continuation.resume(returning: path) }
            }
            monitor.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if once.first() { continuation.resume(returning: nil) }
            }
        }
        monitor.cancel()
        guard let path else { return nil }
        return networkType(satisfied: path.status == .satisfied, wifi: path.usesInterfaceType(.wifi), wired: path.usesInterfaceType(.wiredEthernet), cellular: path.usesInterfaceType(.cellular))
    }

    nonisolated static func networkType(satisfied: Bool, wifi: Bool, wired: Bool, cellular: Bool) -> String {
        guard satisfied else { return "none" }
        if wired { return "wired" }
        if wifi { return "wifi" }
        if cellular { return "cellular" }
        return "other"
    }
}

/// Scripted readings; for tests.
@MainActor
final class FakePhoneMachine: PhoneMachineProbing {
    var info = PhoneMachineInfo()
    private(set) var reads = 0

    func read() async -> PhoneMachineInfo {
        reads += 1
        return info
    }
}
