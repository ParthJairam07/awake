import XCTest
@testable import Awake

/// A Mac with no battery (a desktop, a virtual machine) is on mains. The
/// session log used to say "on battery" there; the battery floors, the
/// weak-charger rule and the wording must not apply anywhere.
@MainActor
final class NoBatteryTests: XCTestCase {
    private var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    func testTheLogSaysMainsPowerNotOnBattery() {
        XCTAssertEqual(PowerMonitor.describeCharger(isCharging: false, draining: false, hasBattery: false), "on mains power")
        XCTAssertEqual(PowerMonitor.describeCharger(isCharging: true, draining: true, hasBattery: false), "on mains power")
        // A Mac with a battery is described as before.
        XCTAssertEqual(PowerMonitor.describeCharger(isCharging: false, draining: false), "on battery")
        XCTAssertEqual(PowerMonitor.describeCharger(isCharging: true, draining: true), "charger too weak, draining")
        XCTAssertEqual(PowerMonitor.describeCharger(isCharging: true, draining: false), "charging")
    }

    func testTheMonitorKnowsWhetherThereIsABattery() {
        let none = PowerMonitor(reader: { (.none, false) }, wattsReader: { XCTFail("watts read with no battery"); return -9 }, recheckDelay: .seconds(3600))
        none.refreshBattery()
        none.refreshBattery()
        XCTAssertFalse(none.hasBattery)
        XCTAssertFalse(none.chargerDraining)

        let unreadable = PowerMonitor(reader: { (.unreadable(misses: 1), false) }, recheckDelay: .seconds(3600))
        unreadable.refreshBattery()
        XCTAssertTrue(unreadable.hasBattery, "a battery that cannot be read is still a battery")
    }

    /// Whatever the charging flags of a battery that is not there say, no
    /// battery rule fires: not the end, not Low Power Mode.
    func testNoBatteryRuleAppliesWithoutABattery() {
        var config = Config()
        config.endFloor = 20
        config.lowPowerFloor = 40
        for (charging, draining) in [(false, false), (false, true), (true, true)] {
            XCTAssertEqual(
                FloorRules.evaluate(battery: .none, isCharging: charging, thermal: .nominal, lidClosed: false, lowPowerSetByUs: false, config: config, chargerDraining: draining),
                []
            )
        }
        // Heat and the lid still count.
        XCTAssertEqual(
            FloorRules.evaluate(battery: .none, isCharging: false, thermal: .critical, lidClosed: false, lowPowerSetByUs: false, config: config),
            [.endSession(.thermalCritical)]
        )
    }

    func testNoWeakChargerNoticeWithoutABattery() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let before = h.notifier.posts.count
        let driver = FloorRuleDriver(manager: m, notifier: h.notifier)
        await driver.run(battery: .none, isCharging: true, thermal: .nominal, lidClosed: false, chargerDraining: true)
        await driver.run(battery: .none, isCharging: false, thermal: .nominal, lidClosed: false, chargerDraining: true)
        XCTAssertEqual(h.notifier.posts.count, before, "\(h.notifier.posts.dropFirst(before))")
        XCTAssertTrue(m.isActive)
    }

    func testTheMenuSaysMainsPower() {
        XCTAssertEqual(
            StatusLines.machine(lidClosed: false, watts: nil, wifiSSID: nil, batteryPercent: nil, isCharging: false, hasBattery: false),
            "Lid: open \u{00B7} mains power"
        )
        // A battery that could not be read is not "mains power".
        XCTAssertEqual(StatusLines.machine(lidClosed: false, watts: nil, wifiSSID: nil, batteryPercent: nil, isCharging: false), "Lid: open")
    }

    func testStatusJSONCarriesHasBatteryAndOldFilesStillRead() throws {
        var s = StatusSnapshot(updatedAt: Date(timeIntervalSince1970: 1_800_000_000), active: false, startedAt: nil, endsAt: nil, remainingSeconds: nil, lidClosed: false, lidOnDesk: false, batteryPercent: nil, isCharging: false, chargerDraining: false, thermalState: "nominal", lowPowerSetByUs: false, wifiSSID: nil, lastOutageSeconds: nil, frozenCount: 0, dockerPaused: false)
        s.hasBattery = false
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: StatusSnapshot.encode(s)) as? [String: Any])
        XCTAssertEqual(object["hasBattery"] as? Bool, false)
        XCTAssertEqual(try Store.makeDecoder().decode(StatusSnapshot.self, from: StatusSnapshot.encode(s)), s)

        let old = #"{"active":false,"chargerDraining":false,"dockerPaused":false,"frozenCount":0,"isCharging":false,"lidClosed":false,"lidOnDesk":false,"lowPowerSetByUs":false,"thermalState":"nominal","updatedAt":"2027-01-15T07:59:30Z"}"#
        XCTAssertTrue(try Store.makeDecoder().decode(StatusSnapshot.self, from: Data(old.utf8)).hasBattery)
    }

    func testThePhoneMachineInfoSaysNoBattery() {
        var info = PhoneMachineInfo()
        LivePhoneMachine.fill(&info, battery: .none, charging: false, watts: { XCTFail("watts read with no battery"); return 1 })
        XCTAssertEqual(info.hasBattery, false)
        XCTAssertNil(info.isCharging)
        XCTAssertNil(info.batteryPercent)
        XCTAssertNil(info.batteryWatts)

        var laptop = PhoneMachineInfo()
        LivePhoneMachine.fill(&laptop, battery: .percent(64), charging: false, watts: { -3.5 })
        XCTAssertEqual(laptop.hasBattery, true)
        XCTAssertEqual(laptop.isCharging, false)
        XCTAssertEqual(laptop.batteryPercent, 64)
        XCTAssertEqual(laptop.batteryWatts, -3.5)
    }

    /// The phone page itself, run in JavaScriptCore.
    func testThePhonePageSaysMainsNotOnBattery() throws {
        let js = try PhoneScript()
        XCTAssertEqual(js.call("machinePowerFacts", #"{"hasBattery":false}"#), #"[["Battery","no battery",null],["Power","mains",null]]"#)
        XCTAssertEqual(js.call("sessionPowerFact", #"{"hasBattery":false,"isCharging":false}"#), #"["Power","mains (no battery)",null]"#)
        // With a battery, as before.
        XCTAssertEqual(js.call("sessionPowerFact", #"{"hasBattery":true,"batteryPercent":15,"isCharging":false}"#), #"["Battery","15%, on battery","bad"]"#)
        XCTAssertEqual(js.call("sessionPowerFact", #"{"batteryPercent":80,"isCharging":true}"#), #"["Battery","80%, on power",null]"#)
        XCTAssertEqual(js.call("sessionPowerFact", #"{"batteryPercent":null}"#), "null")
        XCTAssertEqual(
            js.call("machinePowerFacts", #"{"hasBattery":true,"batteryPercent":64,"isCharging":true,"chargerDraining":true,"batteryWatts":-3.5,"adapterWatts":30}"#),
            #"[["Battery","64%",null],["Trend","draining 3.5 W","warn"],["Charger","connected, 30 W, too weak for the load","warn"]]"#
        )
        XCTAssertEqual(
            js.call("machinePowerFacts", #"{"hasBattery":true,"batteryPercent":null,"isCharging":null}"#),
            #"[["Battery","unknown",null],["Trend","unknown",null],["Charger","unknown",null]]"#
        )
    }
}
