import Foundation

/// Spec section 6 decision table (plus the section 4 lid row), as a pure
/// function plus a small driver.
enum FloorRules {
    /// Why Low Power Mode is being switched on. The strongest cause is
    /// named when several hold: thermal, then battery, then lid.
    enum LowPowerCause: Equatable, Sendable {
        case battery
        case thermal
        case lid
    }

    enum Action: Equatable, Sendable {
        case enableLowPower(LowPowerCause)
        case disableLowPower
        case endSession(EndReason)
    }

    /// Ordered actions for the current inputs.
    ///
    /// "Not charging" means off the charger, or on one too weak for the
    /// load (`chargerDraining`, from `ChargerTrend`): a Mac draining on a
    /// 20 W phone charger is on battery as far as the floors are concerned.
    ///
    /// - battery below `endFloor` while not charging: end session. 0 never
    ///   matches, so 0 turns the battery end off; Config keeps a non-zero
    ///   `endFloor` below `lowPowerFloor`.
    /// - thermal `critical` (if `thermalRules`): end session
    /// - battery temperature at or above `batteryTempEndC` (if
    ///   `thermalRules` and the driver reports one): end session
    /// - battery present but unreadable on two consecutive reads while not
    ///   charging, with an end floor set: end session. The floor cannot be
    ///   applied to a level nobody can read, and the Mac is on a battery
    ///   that may be about to die. A desktop has no battery and no floor.
    /// - battery below `lowPowerFloor` while not charging, thermal
    ///   `serious`, CPU speed limit at or below `throttleLowPowerPercent`
    ///   or battery temperature at or above `batteryTempLowPowerC` (the
    ///   three if `thermalRules`), or lid closed (if `lowPowerOnLidClose`,
    ///   charging or not): Low Power Mode on
    /// - none of the above while we set Low Power Mode: Low Power Mode off
    ///   ("charger connected", "thermal back to nominal/fair", "lid opened")
    static func evaluate(
        battery: BatteryStatus,
        isCharging: Bool,
        thermal: ProcessInfo.ThermalState,
        lidClosed: Bool,
        lowPowerSetByUs: Bool,
        config: Config,
        chargerDraining: Bool = false,
        thermalReading: ThermalReading = .unknown
    ) -> [Action] {
        let onBattery = !isCharging || chargerDraining
        let percent = battery.percent
        if let p = percent, onBattery, p < config.endFloor {
            return [.endSession(.batteryFloor)]
        }
        if config.thermalRules, thermal == .critical {
            return [.endSession(.thermalCritical)]
        }
        if config.thermalRules, batteryTooHot(thermalReading, config: config) {
            return [.endSession(.batteryHot)]
        }
        if case let .unreadable(misses) = battery, onBattery, misses >= 2, config.endFloor > 0 {
            return [.endSession(.batteryUnreadable)]
        }
        let cause = lowPowerCause(percent: percent, isCharging: isCharging, thermal: thermal, lidClosed: lidClosed, config: config, chargerDraining: chargerDraining, thermalReading: thermalReading)
        if let cause, !lowPowerSetByUs { return [.enableLowPower(cause)] }
        if cause == nil, lowPowerSetByUs { return [.disableLowPower] }
        return []
    }

    /// The strongest cause that wants Low Power Mode right now (thermal,
    /// then battery, then lid), or nil when none holds. Independent of
    /// whether the mode is already on, so the driver can track which cause
    /// is keeping it on as the inputs change.
    static func lowPowerCause(
        percent: Int?,
        isCharging: Bool,
        thermal: ProcessInfo.ThermalState,
        lidClosed: Bool,
        config: Config,
        chargerDraining: Bool = false,
        thermalReading: ThermalReading = .unknown
    ) -> LowPowerCause? {
        if config.thermalRules, thermal == .serious || throttled(thermalReading, config: config) || batteryHot(thermalReading, config: config) { return .thermal }
        if let p = percent, !isCharging || chargerDraining, p < config.lowPowerFloor { return .battery }
        if lidClosed, config.lowPowerOnLidClose { return .lid }
        return nil
    }

    /// macOS is limiting the CPU to `throttleLowPowerPercent` or less.
    static func throttled(_ r: ThermalReading, config: Config) -> Bool {
        guard config.throttleLowPowerPercent > 0, let limit = r.speedLimit else { return false }
        return limit <= config.throttleLowPowerPercent
    }

    static func batteryHot(_ r: ThermalReading, config: Config) -> Bool {
        guard config.batteryTempLowPowerC > 0, let t = r.batteryTemperatureC else { return false }
        return t >= Double(config.batteryTempLowPowerC)
    }

    static func batteryTooHot(_ r: ThermalReading, config: Config) -> Bool {
        guard config.batteryTempEndC > 0, let t = r.batteryTemperatureC else { return false }
        return t >= Double(config.batteryTempEndC)
    }

    /// Why Low Power Mode went on for heat, naming the signal that fired.
    static func thermalBody(thermal: ProcessInfo.ThermalState, reading: ThermalReading, config: Config) -> String {
        if thermal == .serious { return "Thermal state is serious. Low Power Mode is on until it cools down." }
        if throttled(reading, config: config), let limit = reading.speedLimit {
            return "macOS has limited the CPU to \(limit)% of full speed. Low Power Mode is on until it cools down."
        }
        if let t = reading.batteryTemperatureC {
            return String(format: "Battery at %.0f °C, at or above the %d °C floor. Low Power Mode is on until it cools down.", t, config.batteryTempLowPowerC)
        }
        return "The Mac is hot. Low Power Mode is on until it cools down."
    }
}

/// Applies `FloorRules` through the session manager (journal first) and
/// posts the spec section 9 notifications. A lid-caused change is logged
/// but not announced: the user just closed or opened the lid.
///
/// Announce rule for switching the mode off: the disable is announced iff
/// the cause that last held while Awake had the mode on was battery or
/// thermal, and silent iff it was the lid. The cause is refreshed on every
/// run while the mode is ours, so a takeover (lid-caused mode kept on by
/// the battery floor, or the reverse) changes which one the disable is
/// attributed to.
@MainActor
struct FloorRuleDriver {
    weak var manager: SessionManager?
    let notifier: any Notifying
    /// The cause that most recently held while Awake had the mode on,
    /// so the matching disable knows whether it is announced. Not
    /// journaled: after a relaunch the disable is announced as before.
    private let lastCause = LastCause()
    /// Whether the weak-charger notice has been posted for the current
    /// draining spell; cleared when the charger keeps up again.
    private let drainingNotice = Flag()

    @MainActor
    private final class LastCause {
        var value: FloorRules.LowPowerCause?
    }

    @MainActor
    private final class Flag {
        var value = false
    }

    static func chargerTooWeakBody(percent: Int?) -> String {
        let level = percent.map { "Battery at \($0)% and falling" } ?? "The battery is falling"
        return "\(level) while plugged in: the charger cannot keep up with the load. Battery floors apply as if on battery."
    }

    init(manager: SessionManager, notifier: any Notifying) {
        self.manager = manager
        self.notifier = notifier
    }

    func run(battery: BatteryStatus, isCharging: Bool, thermal: ProcessInfo.ThermalState, lidClosed: Bool, chargerDraining: Bool = false, thermalReading: ThermalReading = .unknown) async {
        guard let manager, manager.isActive, !Task.isCancelled else { return }
        let config = manager.config
        let percent = battery.percent
        let draining = isCharging && chargerDraining
        if draining, !drainingNotice.value {
            drainingNotice.value = true
            manager.noteReport { $0.chargerWeakEvents += 1 }
            Log.info("charger too weak: battery \(PowerMonitor.describe(battery)) and falling on AC")
            notifier.post(title: "Charger too weak", body: Self.chargerTooWeakBody(percent: percent))
        } else if !draining, drainingNotice.value {
            drainingNotice.value = false
            Log.info("charger keeping up again")
        }
        let actions = FloorRules.evaluate(
            battery: battery,
            isCharging: isCharging,
            thermal: thermal,
            lidClosed: lidClosed,
            lowPowerSetByUs: manager.state.lowPowerSetByUs,
            config: config,
            chargerDraining: chargerDraining,
            thermalReading: thermalReading
        )
        // Track the effective cause while the mode is ours, not only at the
        // enable: another cause may have taken over since.
        if manager.state.lowPowerSetByUs,
           let cause = FloorRules.lowPowerCause(percent: percent, isCharging: isCharging, thermal: thermal, lidClosed: lidClosed, config: config, chargerDraining: chargerDraining, thermalReading: thermalReading) {
            lastCause.value = cause
        }
        for action in actions {
            guard manager.isActive, !Task.isCancelled else { return }
            switch action {
            case let .enableLowPower(cause):
                guard await manager.setLowPower(true) else { continue }
                lastCause.value = cause
                manager.noteReport { $0.lowPowerEvents += 1; if cause == .thermal { $0.thermalEvents += 1 } }
                guard manager.isActive, !Task.isCancelled else { return }
                switch cause {
                case .thermal:
                    notifier.post(title: "Low Power Mode on", body: FloorRules.thermalBody(thermal: thermal, reading: thermalReading, config: config))
                case .battery:
                    notifier.post(title: "Low Power Mode on", body: "Battery at \(percent ?? 0)%, below the \(config.lowPowerFloor)% floor.")
                case .lid:
                    Log.info("low power mode on (lid closed)")
                }
            case .disableLowPower:
                if await manager.setLowPower(false) {
                    let cause = lastCause.value
                    lastCause.value = nil
                    guard manager.isActive, !Task.isCancelled else { return }
                    if cause == .lid {
                        Log.info("low power mode off (lid opened)")
                    } else {
                        notifier.post(title: "Low Power Mode off", body: isCharging && !chargerDraining ? "Charger connected." : "Back above the floor.")
                    }
                }
            case let .endSession(reason):
                await manager.end(reason: reason)
                guard manager.isActive, !Task.isCancelled else { return }
            }
        }
    }
}
