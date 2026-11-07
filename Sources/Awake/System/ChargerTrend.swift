import Foundation

/// Whether a connected charger is losing to the load. IOKit reports a Mac
/// on a 20 W phone charger as "on AC", and the battery floors are skipped
/// while on AC, so a plugged-in Mac could drain to 0% mid-session. The
/// trend catches that: on AC, the battery is draining when its percentage
/// has fallen `percentDrop` or more below the highest level seen on this
/// charger, or when the instantaneous power has been negative (discharging)
/// on `wattReads` consecutive reads. A read that shows the battery taking
/// charge, or a percentage back at its high, clears it. Unplugging starts
/// over: the next charger is judged on its own.
///
/// A one-point dip is not a fall: Optimized Battery Charging holds the
/// battery around 80% and lets it drift a point.
struct ChargerTrend: Equatable, Sendable {
    static let percentDrop = 2
    /// Discharge power at or below which a read counts; a few tenths of a
    /// watt is noise around a full battery.
    static let drainWatts: Double = -0.5
    static let wattReads = 2

    private(set) var draining = false
    private var highPercent: Int?
    private var negativeReads = 0

    /// Feed one reading. `watts` is signed (negative while discharging) and
    /// nil when it could not be read, in which case only the percentage
    /// counts. `percent` is nil while the battery is unreadable.
    mutating func update(percent: Int?, onAC: Bool, watts: Double?) {
        guard onAC else {
            self = ChargerTrend()
            return
        }
        if let watts, watts > 0 {
            // Taking charge: whatever fell before, this is the new baseline.
            draining = false
            negativeReads = 0
            highPercent = percent ?? highPercent
            return
        }
        if let watts {
            negativeReads = watts <= Self.drainWatts ? negativeReads + 1 : 0
        }
        if let percent {
            let high = highPercent ?? percent
            if percent >= high {
                highPercent = percent
                draining = false
            } else if high - percent >= Self.percentDrop {
                draining = true
            }
        }
        if negativeReads >= Self.wattReads { draining = true }
    }
}
