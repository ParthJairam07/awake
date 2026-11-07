import XCTest
@testable import Awake

final class ChargerTrendTests: XCTestCase {
    func testOffTheChargerNeverDrains() {
        var t = ChargerTrend()
        t.update(percent: 50, onAC: false, watts: -12)
        t.update(percent: 40, onAC: false, watts: -12)
        XCTAssertFalse(t.draining)
    }

    func testPercentFallingTwoPointsOnACDrains() {
        var t = ChargerTrend()
        t.update(percent: 60, onAC: true, watts: nil)
        t.update(percent: 59, onAC: true, watts: nil)
        XCTAssertFalse(t.draining, "a one-point dip is Optimized Battery Charging drift")
        t.update(percent: 58, onAC: true, watts: nil)
        XCTAssertTrue(t.draining)
    }

    func testTwoNegativeWattReadsOnACDrain() {
        var t = ChargerTrend()
        t.update(percent: 80, onAC: true, watts: -3.2)
        XCTAssertFalse(t.draining, "one read could be a burst")
        t.update(percent: 80, onAC: true, watts: -2.8)
        XCTAssertTrue(t.draining)
    }

    func testNoiseAroundZeroWattsIsNotDraining() {
        var t = ChargerTrend()
        for _ in 0..<5 { t.update(percent: 100, onAC: true, watts: -0.3) }
        XCTAssertFalse(t.draining)
    }

    func testAPositiveWattReadInterruptsTheCount() {
        var t = ChargerTrend()
        t.update(percent: 80, onAC: true, watts: -3)
        t.update(percent: 80, onAC: true, watts: 5)
        t.update(percent: 80, onAC: true, watts: -3)
        XCTAssertFalse(t.draining)
    }

    func testTakingChargeClearsDrainingAndRebasesTheHigh() {
        var t = ChargerTrend()
        t.update(percent: 60, onAC: true, watts: -4)
        t.update(percent: 58, onAC: true, watts: -4)
        XCTAssertTrue(t.draining)
        // Load dropped; the charger is winning again at 58%.
        t.update(percent: 58, onAC: true, watts: 6)
        XCTAssertFalse(t.draining)
        // 58 is the new baseline: staying there is not a fall from 60.
        t.update(percent: 58, onAC: true, watts: nil)
        XCTAssertFalse(t.draining)
        t.update(percent: 56, onAC: true, watts: nil)
        XCTAssertTrue(t.draining)
    }

    func testBackAtTheHighClearsDraining() {
        var t = ChargerTrend()
        t.update(percent: 60, onAC: true, watts: nil)
        t.update(percent: 58, onAC: true, watts: nil)
        XCTAssertTrue(t.draining)
        t.update(percent: 59, onAC: true, watts: nil)
        XCTAssertTrue(t.draining, "still below the high")
        t.update(percent: 60, onAC: true, watts: nil)
        XCTAssertFalse(t.draining)
    }

    func testUnpluggingStartsOver() {
        var t = ChargerTrend()
        t.update(percent: 60, onAC: true, watts: -4)
        t.update(percent: 58, onAC: true, watts: -4)
        XCTAssertTrue(t.draining)
        t.update(percent: 57, onAC: false, watts: -4)
        XCTAssertEqual(t, ChargerTrend())
        // A new charger at 57% is judged from 57, not from 60.
        t.update(percent: 57, onAC: true, watts: nil)
        XCTAssertFalse(t.draining)
    }

    func testUnreadablePercentCountsWattsOnly() {
        var t = ChargerTrend()
        t.update(percent: nil, onAC: true, watts: -2)
        t.update(percent: nil, onAC: true, watts: -2)
        XCTAssertTrue(t.draining)
        t.update(percent: nil, onAC: true, watts: nil)
        XCTAssertTrue(t.draining, "a missing read changes nothing")
    }
}
