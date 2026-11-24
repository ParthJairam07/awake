import XCTest
@testable import Awake

final class SessionReportTests: XCTestCase {
    func testSummaryNamesWhatHappened() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var r = SessionReport(startedAt: start, plannedEnd: start.addingTimeInterval(8 * 3600), batteryStart: 100)
        r.lidCloses = 1
        r.lowPowerEvents = 2
        r.thermalEvents = 1
        r.outages = 1
        r.outageSeconds = 130
        r.endedAt = start.addingTimeInterval(7 * 3600 + 42 * 60)
        r.endReason = "timer"
        r.batteryEnd = 64
        r.restored = true
        XCTAssertEqual(
            r.summary(now: r.endedAt!, endReasonText: SessionManager.reasonText),
            "Ran 7h 42m (time was up). Battery 100% → 64%. Lid closed once. Low Power Mode on twice (1 for heat). 1 outage, 2m 10s in all. Everything restored."
        )
    }

    func testSummaryOfASessionAwakeDidNotSeeEnd() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let r = SessionReport(startedAt: start, plannedEnd: start.addingTimeInterval(3600), batteryStart: nil)
        XCTAssertEqual(r.summary(now: start.addingTimeInterval(60), endReasonText: SessionManager.reasonText), "Ran 1m (Awake was not running when it ended).")
    }

    func testRoundTripsThroughTheStore() throws {
        let home = TempHome()
        defer { home.destroy() }
        let store = Store(paths: home.paths)
        let r = SessionReport(startedAt: Date(timeIntervalSince1970: 1_800_000_000), plannedEnd: Date(timeIntervalSince1970: 1_800_003_600), batteryStart: 80)
        try store.saveReport(r)
        XCTAssertEqual(store.loadReport(), r)
        try store.removeReport()
        XCTAssertNil(store.loadReport())
    }
}

@MainActor
final class SessionReportManagerTests: XCTestCase {
    var h: Harness!
    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    func testAReportIsJournaledDuringTheSessionAndSummarisedAtTheEnd() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertNotNil(h.store.loadReport(), "written at start")
        m.noteReport { $0.lidCloses += 1 }
        XCTAssertEqual(h.store.loadReport()?.lidCloses, 1, "written through on every note")
        h.clock.advance(600)
        await m.end(reason: .user)
        let summary = h.notifier.posts.last { $0.title == SessionReport.title }
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary?.body.contains("Ran 10m (ended by you)") ?? false, summary?.body ?? "")
        XCTAssertTrue(summary?.body.contains("Lid closed once") ?? false, summary?.body ?? "")
        XCTAssertTrue(summary?.body.contains("Everything restored") ?? false, summary?.body ?? "")
        XCTAssertNil(h.store.loadReport(), "removed once summarised")
    }

    func testTheSettingTurnsTheSummaryOff() async throws {
        let m = h.makeManager()
        m.config.sessionSummary = false
        await m.start(duration: 3600)
        await m.end(reason: .user)
        XCTAssertFalse(h.notifier.posts.contains { $0.title == SessionReport.title })
        XCTAssertNil(h.store.loadReport())
    }

    func testALeftoverReportIsSummarisedAtLaunch() async throws {
        let start = h.clock.now.addingTimeInterval(-7200)
        var left = SessionReport(startedAt: start, plannedEnd: start.addingTimeInterval(3600), batteryStart: 90)
        left.outages = 2
        left.outageSeconds = 400
        try h.store.saveReport(left)
        let m = h.makeManager()
        await m.reconcile()
        let summary = h.notifier.posts.last { $0.title == SessionReport.title }
        XCTAssertTrue(summary?.body.contains("Awake was not running when it ended") ?? false, summary?.body ?? "")
        XCTAssertTrue(summary?.body.contains("2 outages, 6m 40s in all") ?? false, summary?.body ?? "")
        XCTAssertNil(h.store.loadReport())
    }

    /// The recovery agent ended a 3-minute session; Awake is opened 39 s
    /// later. The summary used to say "Ran 3m 39s": it counted up to the
    /// launch. The session ran until its deadline.
    func testALeftoverReportRunsUntilTheDeadlineNotTheLaunch() async throws {
        let start = h.clock.now.addingTimeInterval(-219)
        try h.store.saveReport(SessionReport(startedAt: start, plannedEnd: start.addingTimeInterval(180), batteryStart: nil))
        let m = h.makeManager()
        await m.reconcile()
        let summary = h.notifier.posts.last { $0.title == SessionReport.title }
        XCTAssertEqual(summary?.body, "Ran 3m (Awake was not running when it ended).")
    }

    /// The same when the launch itself finds the expired session and ends
    /// it: nobody was holding the Mac awake after the deadline.
    func testAnExpiredSessionFoundAtLaunchRunsUntilItsDeadline() async throws {
        let first = h.makeManager()
        await first.start(duration: 180)
        XCTAssertNotNil(h.store.loadReport())
        h.clock.advance(219)
        let next = h.makeManager()
        await next.reconcile()
        XCTAssertFalse(next.isActive)
        let summary = h.notifier.posts.last { $0.title == SessionReport.title }
        XCTAssertTrue(summary?.body.hasPrefix("Ran 3m (Awake was not running when it ended).") ?? false, summary?.body ?? "")
    }

    /// An extension moves the deadline the summary counts to.
    func testAnExtendedSessionRunsUntilItsNewDeadline() async throws {
        let first = h.makeManager()
        await first.start(duration: 180)
        await first.extend(by: 120)
        XCTAssertEqual(h.store.loadReport()?.plannedEnd, first.session?.endsAt)
        h.clock.advance(3600)
        let next = h.makeManager()
        await next.reconcile()
        let summary = h.notifier.posts.last { $0.title == SessionReport.title }
        XCTAssertTrue(summary?.body.hasPrefix("Ran 5m (Awake was not running when it ended).") ?? false, summary?.body ?? "")
    }

    /// A leftover whose deadline is still ahead (a forced recovery run):
    /// never counted past the launch.
    func testALeftoverReportEndedEarlyIsNotCountedToItsDeadline() async throws {
        let start = h.clock.now.addingTimeInterval(-60)
        try h.store.saveReport(SessionReport(startedAt: start, plannedEnd: start.addingTimeInterval(3600), batteryStart: nil))
        let m = h.makeManager()
        await m.reconcile()
        let summary = h.notifier.posts.last { $0.title == SessionReport.title }
        XCTAssertEqual(summary?.body, "Ran 1m (Awake was not running when it ended).")
    }

    /// A session that ends in this process still counts to its real end.
    func testASessionEndedHereCountsToItsEnd() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        h.clock.advance(125)
        await m.end(reason: .user)
        let summary = h.notifier.posts.last { $0.title == SessionReport.title }
        XCTAssertTrue(summary?.body.hasPrefix("Ran 2m 5s (ended by you).") ?? false, summary?.body ?? "")
    }
}
