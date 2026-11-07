import XCTest
@testable import Awake

final class ResourceRulesTests: XCTestCase {
    func testDiskLowUnderTheFloorAndOffAtZero() {
        XCTAssertTrue(ResourceRules.diskLow(freeBytes: 9_999_999_999, floorGB: 10))
        XCTAssertFalse(ResourceRules.diskLow(freeBytes: 10_000_000_000, floorGB: 10))
        XCTAssertFalse(ResourceRules.diskLow(freeBytes: 0, floorGB: 0))
    }

    func testDiskAlertPostsOncePerCrossingWithHysteresis() {
        var s = ResourceAlertState()
        XCTAssertNil(s.disk(freeBytes: 30_000_000_000, floorGB: 10))
        XCTAssertNotNil(s.disk(freeBytes: 8_000_000_000, floorGB: 10))
        XCTAssertNil(s.disk(freeBytes: 7_000_000_000, floorGB: 10), "still low: not repeated")
        XCTAssertNil(s.disk(freeBytes: 10_500_000_000, floorGB: 10), "just above the floor does not re-arm")
        XCTAssertNil(s.disk(freeBytes: 9_000_000_000, floorGB: 10), "dipping back is not a new crossing")
        XCTAssertNil(s.disk(freeBytes: 12_000_000_000, floorGB: 10), "re-armed, nothing to post")
        XCTAssertNotNil(s.disk(freeBytes: 9_000_000_000, floorGB: 10), "a new crossing posts again")
    }

    func testDiskBodyNamesTheNumbers() {
        var s = ResourceAlertState()
        let body = s.disk(freeBytes: 8_400_000_000, floorGB: 10)
        XCTAssertTrue(body?.contains("8.4 GB free") ?? false, body ?? "")
        XCTAssertTrue(body?.contains("10 GB floor") ?? false, body ?? "")
    }

    func testMemoryCriticalPostsOnceUntilNormal() {
        var s = ResourceAlertState()
        XCTAssertNil(s.memory(.warning))
        XCTAssertNotNil(s.memory(.critical))
        XCTAssertNil(s.memory(.critical))
        XCTAssertNil(s.memory(.warning), "easing to warning does not re-arm")
        XCTAssertNil(s.memory(.normal))
        XCTAssertNotNil(s.memory(.critical))
    }
}

@MainActor
final class ResourceMonitorTests: XCTestCase {
    func testDiskCheckNotifiesThroughTheConfiguredFloor() {
        let notifier = RecordingNotifier()
        let free = Locked<Int64?>(5_000_000_000)
        var config = Config()
        config.freeDiskFloorGB = 20
        let monitor = ResourceMonitor(notifier: notifier, diskReader: { free.value }, diskInterval: 3600) { config }
        monitor.checkDisk()
        XCTAssertTrue(notifier.posts.isEmpty, "not started: nothing runs")
        monitor.start()
        monitor.checkDisk()
        XCTAssertEqual(notifier.posts.last?.title, "Disk almost full")
        XCTAssertTrue(notifier.posts.last?.body.contains("20 GB floor") ?? false)
        monitor.checkDisk()
        XCTAssertEqual(notifier.posts.count, 1)
        free.value = nil
        monitor.checkDisk()
        XCTAssertEqual(notifier.posts.count, 1, "an unreadable volume posts nothing")
        monitor.stop()
    }

    func testMemoryPressureCriticalNotifiesOnce() {
        let notifier = RecordingNotifier()
        let monitor = ResourceMonitor(notifier: notifier, diskReader: { nil }, diskInterval: 3600) { Config() }
        monitor.start()
        monitor.memoryPressure(.warning)
        XCTAssertTrue(notifier.posts.isEmpty)
        monitor.memoryPressure(.critical)
        monitor.memoryPressure(.critical)
        XCTAssertEqual(notifier.posts.filter { $0.title == "Memory pressure critical" }.count, 1)
        monitor.stop()
    }

    func testTheSettingTurnsAlertsOff() {
        let notifier = RecordingNotifier()
        var config = Config()
        config.resourceAlerts = false
        let monitor = ResourceMonitor(notifier: notifier, diskReader: { 1 }, diskInterval: 3600) { config }
        monitor.start()
        monitor.checkDisk()
        monitor.memoryPressure(.critical)
        XCTAssertTrue(notifier.posts.isEmpty)
        monitor.stop()
    }
}
