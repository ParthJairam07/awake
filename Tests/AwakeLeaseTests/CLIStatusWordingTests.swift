import XCTest
@testable import awake_cli

/// `awake status` on machines whose status.json says less than a laptop's.
final class CLIStatusWordingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func lines(_ status: [String: Any]) -> [String] {
        CLI.statusLines(status, leases: [], appRunning: true, now: now)
    }

    /// A Mac with no battery is on mains power: no battery line at all.
    func testNoBatteryIsMainsPower() {
        let out = lines(["active": false, "hasBattery": false, "isCharging": false, "chargerDraining": false])
        XCTAssertTrue(out.contains("Power: mains (no battery)"), "\(out)")
        XCTAssertFalse(out.contains { $0.hasPrefix("Battery") }, "\(out)")
    }

    func testABatteryReadsAsBefore() {
        XCTAssertTrue(lines(["hasBattery": true, "batteryPercent": 64, "isCharging": true]).contains("Battery: 64%, charging"))
        XCTAssertTrue(lines(["batteryPercent": 41, "isCharging": false]).contains("Battery: 41%"), "a status.json from before hasBattery")
        XCTAssertFalse(lines(["hasBattery": true]).contains { $0.hasPrefix("Power") || $0.hasPrefix("Battery") }, "an unreadable battery is not mains power")
    }
}
