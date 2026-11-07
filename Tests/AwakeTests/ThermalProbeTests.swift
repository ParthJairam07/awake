import XCTest
@testable import Awake

final class ThermalProbeTests: XCTestCase {
    func testSpeedLimitLineIsParsed() {
        let output = """
        Note: No thermal warning level has been recorded
        CPU_Speed_Limit \t= 50
        CPU_Available_CPUs \t= 8
        CPU_Scheduler_Limit \t= 100
        """
        XCTAssertEqual(ThermalProbe.speedLimit(from: output), 50)
    }

    func testNoLimitLineIsNil() {
        let output = """
        Note: No thermal warning level has been recorded
        Note: No performance warning level has been recorded
        Note: No CPU power status has been recorded
        """
        XCTAssertNil(ThermalProbe.speedLimit(from: output))
        XCTAssertNil(ThermalProbe.speedLimit(from: ""))
    }

    func testOutOfRangeLimitIsClamped() {
        XCTAssertEqual(ThermalProbe.speedLimit(from: "CPU_Speed_Limit = 250"), 100)
    }

    func testDriverTemperatureIsHundredthsOfADegree() {
        XCTAssertEqual(ThermalProbe.batteryTemperatureC(fromDriverValue: 3015), 30.15)
        XCTAssertNil(ThermalProbe.batteryTemperatureC(fromDriverValue: 0x7FFF_FFFF), "garbage is not a temperature")
        XCTAssertNil(ThermalProbe.batteryTemperatureC(fromDriverValue: -10_000))
    }

    func testUnknownReadingHasNothing() {
        XCTAssertNil(ThermalReading.unknown.speedLimit)
        XCTAssertNil(ThermalReading.unknown.batteryTemperatureC)
    }
}
