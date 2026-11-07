import Foundation
import IOKit

/// Phase 0: heat signals finer than `ProcessInfo.thermalState`. The CPU
/// speed limit from `pmset -g therm` says how hard macOS is already
/// throttling (100 = not at all); the battery temperature, where the
/// battery driver reports one, says whether the Mac is cooking in a bag
/// before the thermal state admits it.
struct ThermalReading: Equatable, Sendable {
    /// `CPU_Speed_Limit` in percent; nil when pmset reports no limit line
    /// (nothing recorded) or could not be read.
    var speedLimit: Int?
    /// Battery temperature in degrees Celsius; nil when the driver has no
    /// `Temperature` key (many Apple Silicon models) or it could not be read.
    var batteryTemperatureC: Double?

    static let unknown = ThermalReading()
}

enum ThermalProbe {
    /// `pmset -g therm` prints `CPU_Speed_Limit 	= 100` while a limit is in
    /// force and only "Note: ... has been recorded" lines otherwise, which
    /// is nil here: no line means no throttling.
    static func speedLimit(from output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: "CPU_Speed_Limit") else { continue }
            let rest = line[range.upperBound...].drop { !$0.isNumber }
            let digits = rest.prefix { $0.isNumber }
            if let value = Int(digits) { return min(max(value, 0), 100) }
        }
        return nil
    }

    /// The driver's `Temperature` is in hundredths of a degree Celsius
    /// (3015 is 30.15 °C). Values outside -40...150 °C are noise.
    static func batteryTemperatureC(fromDriverValue raw: Int64) -> Double? {
        let c = Double(raw) / 100
        guard c > -40, c < 150 else { return nil }
        return c
    }

    static func readSpeedLimit() async -> Int? {
        guard let result = try? await Shell.run("/usr/bin/pmset", ["-g", "therm"]), result.succeeded else { return nil }
        return speedLimit(from: result.stdout)
    }

    static func readBatteryTemperatureC() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let v = IORegistryEntryCreateCFProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let raw = (v as? NSNumber)?.int64Value else { return nil }
        return batteryTemperatureC(fromDriverValue: raw)
    }

    static func read() async -> ThermalReading {
        ThermalReading(speedLimit: await readSpeedLimit(), batteryTemperatureC: readBatteryTemperatureC())
    }
}
