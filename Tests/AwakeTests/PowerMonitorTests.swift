import IOKit.ps
import XCTest
@testable import Awake

/// `PowerMonitor` with power source descriptions built by hand and an
/// injected reader. Nothing here changes power state.
@MainActor
final class PowerMonitorTests: XCTestCase {
    private func battery(current: Int? = 50, max: Int? = 100, state: String = kIOPSBatteryPowerValue, charging: Bool = false) -> [String: Any] {
        var d: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSPowerSourceStateKey: state,
            kIOPSIsChargingKey: charging,
        ]
        if let current { d[kIOPSCurrentCapacityKey] = current }
        if let max { d[kIOPSMaxCapacityKey] = max }
        return d
    }

    /// `classify` with the registry probes fixed. `external` is what the
    /// AppleSmartBattery driver says about the charger, nil when unreadable.
    private func classify(_ sources: [[String: Any]]?, service: Bool, external: Bool? = nil) -> (battery: BatteryStatus, charging: Bool) {
        PowerMonitor.classify(sources: sources, hasBatteryService: { service }, externalPowerConnected: { external })
    }

    // MARK: classify: no battery vs. battery present but unreadable

    func testReadableBatteryIsAPercent() {
        let r = PowerMonitor.classify(
            sources: [battery(current: 42, max: 100)],
            hasBatteryService: { XCTFail("service checked with an entry present"); return true },
            externalPowerConnected: { XCTFail("charger probed with an entry present"); return true }
        )
        XCTAssertEqual(r.battery, .percent(42))
        XCTAssertFalse(r.charging)
        XCTAssertTrue(classify([battery(state: kIOPSACPowerValue)], service: true).charging)
        XCTAssertTrue(classify([battery(charging: true)], service: true).charging)
    }

    func testEmptyListIsNoBatteryOnADesktop() {
        let r = PowerMonitor.classify(
            sources: [],
            hasBatteryService: { false },
            externalPowerConnected: { XCTFail("charger probed on a desktop"); return true }
        )
        XCTAssertEqual(r.battery, .none)
        XCTAssertFalse(r.charging)
    }

    func testEmptyListWithABatteryServiceIsUnreadable() {
        XCTAssertEqual(classify([], service: true).battery, .unreadable(misses: 1))
    }

    func testUnavailableListFollowsTheBatteryService() {
        XCTAssertEqual(classify(nil, service: true).battery, .unreadable(misses: 1))
        XCTAssertEqual(classify(nil, service: false).battery, .none)
    }

    /// Greptile caught this: a laptop on a charger whose list is unreadable
    /// or has no battery entry was reported as on battery, so the two-miss
    /// rule ended its session. The charger state comes from the driver's
    /// `ExternalConnected` instead. When that is unreadable too the laptop
    /// is taken to be on battery, so the session ends rather than running
    /// with no floor on a battery that may be draining.
    func testUnreadableListTakesTheChargerFromTheDriver() {
        XCTAssertEqual(classify(nil, service: true, external: true).battery, .unreadable(misses: 1))
        XCTAssertTrue(classify(nil, service: true, external: true).charging)
        XCTAssertTrue(classify([], service: true, external: true).charging)
        XCTAssertFalse(classify(nil, service: true, external: false).charging)
        XCTAssertFalse(classify([], service: true, external: false).charging)
        XCTAssertFalse(classify(nil, service: true, external: nil).charging, "unknown charger state must fail closed")
    }

    /// An entry without a usable capacity is unreadable even though the
    /// power source state is known; charging still comes from the entry.
    func testEntryWithoutCapacityIsUnreadableButKeepsCharging() {
        let noCurrent = classify([battery(current: nil, state: kIOPSACPowerValue)], service: false)
        XCTAssertEqual(noCurrent.battery, .unreadable(misses: 1))
        XCTAssertTrue(noCurrent.charging)
        XCTAssertEqual(classify([battery(max: 0)], service: false).battery, .unreadable(misses: 1))
    }

    func testOtherPowerSourcesAreIgnored() {
        let ups: [String: Any] = [kIOPSTypeKey: kIOPSUPSType, kIOPSCurrentCapacityKey: 90, kIOPSMaxCapacityKey: 100]
        XCTAssertEqual(classify([ups], service: false).battery, .none)
        XCTAssertEqual(classify([ups, battery(current: 70)], service: false).battery, .percent(70))
    }

    // MARK: consecutive misses and the recheck

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var _next: (battery: BatteryStatus, charging: Bool) = (.unreadable(misses: 1), false)
        private var _count = 0
        var next: (battery: BatteryStatus, charging: Bool) {
            get { lock.withLock { _next } }
            set { lock.withLock { _next = newValue } }
        }
        var count: Int { lock.withLock { _count } }
        func read() -> (battery: BatteryStatus, charging: Bool) {
            lock.withLock { _count += 1; return _next }
        }
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), what)
    }

    /// Phase 0: on AC, each read also samples the watts and feeds the
    /// charger trend; two discharging reads mark the charger too weak, and
    /// unplugging clears it. Off AC the watts are not read at all.
    func testChargerDrainingFollowsTheWattsWhileOnAC() {
        let reads = Reads()
        reads.next = (.percent(60), true)
        let watts = Watts()
        watts.next = -4
        let monitor = PowerMonitor(reader: { reads.read() }, wattsReader: { watts.read() }, recheckDelay: .seconds(3600))
        monitor.refreshBattery()
        XCTAssertFalse(monitor.chargerDraining)
        monitor.refreshBattery()
        XCTAssertTrue(monitor.chargerDraining)
        XCTAssertTrue(monitor.isCharging, "still on AC as far as IOKit knows")
        XCTAssertEqual(watts.count, 2)

        reads.next = (.percent(58), false)
        monitor.refreshBattery()
        XCTAssertFalse(monitor.chargerDraining)
        XCTAssertEqual(watts.count, 2, "watts are not read off the charger")
    }

    func testChargerDrainingFollowsAFallingPercentWithoutWatts() {
        let reads = Reads()
        reads.next = (.percent(60), true)
        let monitor = PowerMonitor(reader: { reads.read() }, wattsReader: { nil }, recheckDelay: .seconds(3600))
        monitor.refreshBattery()
        reads.next = (.percent(58), true)
        monitor.refreshBattery()
        XCTAssertTrue(monitor.chargerDraining)
    }

    /// Phase 0: the thermal poll reports a change like a battery event and
    /// stops reporting once stopped.
    func testThermalPollReportsChanges() async {
        let reads = Reads()
        reads.next = (.percent(60), true)
        let reading = Locked<ThermalReading>(.unknown)
        let monitor = PowerMonitor(reader: { reads.read() }, wattsReader: { nil }, thermalReader: { reading.value }, thermalPollInterval: .seconds(3600), recheckDelay: .seconds(3600))
        let changes = Locked<Int>(0)
        monitor.onChange = { changes.value += 1 }
        monitor.start()
        defer { monitor.stop() }
        await monitor.pollThermal()
        XCTAssertEqual(monitor.thermalReading, .unknown)
        XCTAssertEqual(changes.value, 0, "unknown to unknown is not a change")
        reading.value = ThermalReading(speedLimit: 50)
        await monitor.pollThermal()
        XCTAssertEqual(monitor.thermalReading.speedLimit, 50)
        XCTAssertEqual(changes.value, 1)
        await monitor.pollThermal()
        XCTAssertEqual(changes.value, 1, "same reading: no event")
        monitor.stop()
        XCTAssertEqual(monitor.thermalReading, .unknown)
        reading.value = ThermalReading(speedLimit: 10)
        await monitor.pollThermal()
        XCTAssertEqual(changes.value, 1, "stopped: nothing reported")
    }

    final class Watts: @unchecked Sendable {
        private let lock = NSLock()
        private var _next: Double?
        private var _count = 0
        var next: Double? {
            get { lock.withLock { _next } }
            set { lock.withLock { _next = newValue } }
        }
        var count: Int { lock.withLock { _count } }
        func read() -> Double? {
            lock.withLock { _count += 1; return _next }
        }
    }

    /// The menu's refresh never counts a miss: the count only moves on the
    /// event path, where the floor rules see it. A readable read still
    /// replaces the state, and a miss after it starts the count over.
    func testMenuRefreshKeepsTheMissCountWhereItIs() {
        let reads = Reads()
        let monitor = PowerMonitor(reader: { reads.read() }, recheckDelay: .seconds(3600))
        XCTAssertEqual(monitor.battery, .none)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1))
        XCTAssertNil(monitor.percent)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1), "the menu counted a miss")
        reads.next = (.percent(55), true)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .percent(55))
        XCTAssertEqual(monitor.percent, 55)
        XCTAssertTrue(monitor.isCharging)
        reads.next = (.unreadable(misses: 1), false)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1), "misses carried over a readable read")
        XCTAssertFalse(monitor.isCharging)
    }

    /// Greptile caught this: the menu's refresh moved the count to two on
    /// its own, and the recheck then saw two become two, so the floor rules
    /// never ran. A menu opened during the first miss leaves the count at
    /// one; the recheck makes it two and reports the change.
    func testMenuRefreshDuringAMissDoesNotHideTheSecondMissFromTheFloorRules() async {
        let reads = Reads()
        let monitor = PowerMonitor(reader: { reads.read() }, recheckDelay: .milliseconds(50))
        var changes = 0
        monitor.onChange = { changes += 1 }

        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1))
        monitor.refreshBattery()
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1), "the menu counted a miss")
        XCTAssertEqual(changes, 0)

        await waitUntil("second miss never reported") { monitor.battery == .unreadable(misses: 2) }
        XCTAssertEqual(changes, 1, "the move to two misses was not reported")
    }

    /// A battery that turns unreadable between IOKit events, seen first by
    /// the menu, still gets its recheck, so the second miss is reached.
    func testMenuRefreshStartsTheRecheckWhenTheBatteryTurnsUnreadable() async {
        let reads = Reads()
        reads.next = (.percent(80), false)
        let monitor = PowerMonitor(reader: { reads.read() }, recheckDelay: .milliseconds(50))
        var changes = 0
        monitor.onChange = { changes += 1 }

        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.battery, .percent(80))
        reads.next = (.unreadable(misses: 1), false)
        monitor.refreshBattery()
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1))

        await waitUntil("second miss never reported") { monitor.battery == .unreadable(misses: 2) }
        XCTAssertEqual(changes, 1)
    }

    /// IOKit sends no event for a read that keeps failing. While started
    /// and unreadable, the monitor re-reads on its own and reports the
    /// second miss as a change; the count is capped there, so a battery
    /// that stays unreadable is not a change on every re-read; once
    /// readable again it stops re-reading.
    func testUnreadableBatteryIsRecheckedWhileStarted() async {
        let reads = Reads()
        let monitor = PowerMonitor(reader: { reads.read() }, recheckDelay: .milliseconds(50))
        var changes = 0
        monitor.onChange = { changes += 1 }

        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1))
        XCTAssertEqual(reads.count, 1)

        await waitUntil("second miss never reported") { monitor.battery == .unreadable(misses: 2) }
        XCTAssertEqual(changes, 1)
        let atTwo = reads.count
        await waitUntil("no re-read at two misses") { reads.count >= atTwo + 2 }
        XCTAssertEqual(monitor.battery, .unreadable(misses: 2))
        XCTAssertEqual(changes, 1, "a capped count was reported as a change")

        reads.next = (.percent(80), false)
        await waitUntil("recovery never seen") { monitor.battery == .percent(80) }
        XCTAssertEqual(changes, 2)
        let after = reads.count
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reads.count, after, "still re-reading a readable battery")
    }

    /// Misses before a stop are not consecutive with the next start.
    func testStartBeginsAFreshCount() async {
        let reads = Reads()
        let monitor = PowerMonitor(reader: { reads.read() }, recheckDelay: .milliseconds(50))
        monitor.start()
        await waitUntil("second miss never reported") { monitor.battery == .unreadable(misses: 2) }
        monitor.stop()
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.battery, .unreadable(misses: 1))
    }

    func testStopCancelsTheRecheck() async {
        let reads = Reads()
        let monitor = PowerMonitor(reader: { reads.read() }, recheckDelay: .milliseconds(50))
        monitor.start()
        monitor.stop()
        let after = reads.count
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reads.count, after, "re-read after stop")
        // Not started: a refresh schedules nothing.
        monitor.refreshBattery()
        let again = reads.count
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(reads.count, again)
    }
}
