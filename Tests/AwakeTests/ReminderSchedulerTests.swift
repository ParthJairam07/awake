import XCTest
@testable import Awake

@MainActor
final class ReminderSchedulerTests: XCTestCase {
    func testReminderIsTenMinutesAndGoesThroughTheNotifier() {
        let notifier = RecordingNotifier()
        let r = ReminderScheduler(notifier: notifier)
        let endsAt = Date().addingTimeInterval(3600)
        r.sync(endsAt: endsAt)
        XCTAssertEqual(r.scheduledFor, endsAt.addingTimeInterval(-600))
        r.fire(endsAt: endsAt)
        XCTAssertEqual(notifier.posts.map(\.title), ["10 minutes left"])
        XCTAssertTrue(notifier.posts.first?.body.contains("Extend from the menu bar") ?? false)
        XCTAssertNil(r.scheduledFor)
    }

    func testUnderTenMinutesOrNoSessionSchedulesNothing() {
        let r = ReminderScheduler(notifier: RecordingNotifier())
        r.sync(endsAt: Date().addingTimeInterval(300))
        XCTAssertNil(r.scheduledFor)
        r.sync(endsAt: Date().addingTimeInterval(3600))
        XCTAssertNotNil(r.scheduledFor)
        r.sync(endsAt: nil)
        XCTAssertNil(r.scheduledFor)
    }
}
