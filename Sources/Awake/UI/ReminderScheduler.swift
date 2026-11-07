import Foundation

/// One `Timer` at endsAt − 10 min that posts the "10 minutes left"
/// reminder through the app's notifier, so it reaches the Mac and, with
/// phone alerts configured, the phone. Rescheduled on extend, cancelled on
/// end.
@MainActor
final class ReminderScheduler {
    static let lead: TimeInterval = 10 * 60
    static let title = "10 minutes left"

    private let notifier: any Notifying
    private var timer: Timer?
    private(set) var scheduledFor: Date?

    init(notifier: any Notifying) {
        self.notifier = notifier
    }

    /// Keep the timer in step with the session deadline.
    func sync(endsAt: Date?) {
        guard let endsAt else {
            cancel()
            return
        }
        let fireAt = endsAt.addingTimeInterval(-Self.lead)
        if scheduledFor == fireAt { return }
        timer?.invalidate()
        guard fireAt > Date() else {
            // Less than ten minutes to go: nothing to remind about.
            scheduledFor = nil
            timer = nil
            return
        }
        let t = Timer(fire: fireAt, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fire(endsAt: endsAt) }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        scheduledFor = fireAt
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        scheduledFor = nil
    }

    static func body(endsAt: Date) -> String {
        "Sleep is restored at \(endsAt.formatted(date: .omitted, time: .shortened)). Extend from the menu bar."
    }

    /// What the timer calls; internal so a test can fire it.
    func fire(endsAt: Date) {
        scheduledFor = nil
        timer = nil
        Log.info("reminder: 10 minutes left")
        notifier.post(title: Self.title, body: Self.body(endsAt: endsAt))
    }
}
