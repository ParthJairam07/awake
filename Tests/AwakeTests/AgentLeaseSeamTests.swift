import AwakeLeaseKit
import XCTest
@testable import Awake

/// Where phase 2 (pre-end hooks) meets phase 4 (leases): the deadline
/// timer of a session only leases were holding. Real clock and the real
/// one-shot timer, as in DeadlineTimerTests.
@MainActor
final class LeasePreEndTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A session leases started, loaded the way a launch loads it, whose
    /// last lease is gone and whose end is `endsAt`.
    private func leaseHeldSession(_ h: Harness, endsAt: Date) async throws -> (SessionManager, LeaseManager) {
        let startedAt = endsAt.addingTimeInterval(-600)
        try h.store.saveSession(Session(startedAt: startedAt, endsAt: endsAt))
        var journal = RuntimeState()
        journal.sleepDisabledByUs = true
        try h.store.saveState(journal)
        h.guardFake.sleepDisabled = true
        var state = LeaseState()
        state.sessionStartedAt = startedAt
        state.startedByLeases = true
        state.plannedEnd = endsAt
        state.appliedEnd = endsAt
        state.leaseEpoch = startedAt
        state.lastReleaseAt = endsAt.addingTimeInterval(-300)
        try h.store.write(state, to: h.home.paths.leaseStateFile)

        let m = h.makeManager(clock: { Date() })
        let table = FakeLeaseProcesses()
        let tmux = FakeLeaseTmux()
        let leases = LeaseManager(manager: m, notifier: h.notifier, processLookup: { table.lookup($0) }, tmux: tmux.runner)
        m.leases = leases
        await m.reconcile()
        await leases.sync()
        return (m, leases)
    }

    func testThePreEndOfALeaseEndIsToldTheLeasesAreWhyAndTheSessionEndsOnce() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let endsAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 2.5).rounded(.down))
        let (m, leases) = try await leaseHeldSession(h, endsAt: endsAt)
        XCTAssertTrue(m.isActive, "live before its deadline")
        XCTAssertEqual(m.session?.endsAt, endsAt, "the leases left the end where it was")
        XCTAssertEqual(leases.timerEndReason, .leasesReleased)

        m.config.preEndHooks = true
        var calls: [String] = []
        m.preEnd = { reason in
            calls.append("\(reason.rawValue), active \(m.isActive)")
            // A save that takes long enough for the lease manager's poll
            // to run while the session is past its end.
            try? await Task.sleep(for: .milliseconds(1500))
            await leases.sync()
            try? await Task.sleep(for: .milliseconds(300))
        }

        let ended = await waitUntil(10) { h.notifier.posts.contains { $0.title == "Session ended" } }
        XCTAssertTrue(ended, "the timer ended the session")
        // Anything a second end would post.
        try? await Task.sleep(for: .milliseconds(1500))

        XCTAssertEqual(calls, ["leasesReleased, active true"], "pre-end runs once, before the end, with the reason the end will have")
        XCTAssertFalse(m.isActive)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        let ends = h.notifier.posts.filter { $0.title == "Session ended" || $0.title == "Session restored" }
        XCTAssertEqual(ends.map(\.title), ["Session ended"], "one end, one notice")
        XCTAssertEqual(ends.first?.body, "The last lease was released or expired. Sleep is back to normal.")
    }

    /// The real runner: its "Session ending" notice and pre-end.json name
    /// the leases, not a timer nobody set.
    func testSessionEndingSaysTheLeasesWereReleased() async throws {
        let h = Harness()
        defer { h.home.destroy() }
        let endsAt = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 2.5).rounded(.down))
        let (m, _) = try await leaseHeldSession(h, endsAt: endsAt)
        m.config.preEndHooks = true
        let runner = PreEndRunner(paths: h.home.paths, notifier: h.notifier, config: { m.config }, repos: { [] })
        m.preEnd = { reason in await runner.run(reason: reason) }

        let ended = await waitUntil(10) { h.notifier.posts.contains { $0.title == "Session ended" } }
        XCTAssertTrue(ended, "the timer ended the session")
        let ending = h.notifier.posts.filter { $0.title == PreEndRunner.title }
        XCTAssertEqual(ending.map(\.body), ["Ending now: leases released."])
        let journal = try h.store.read(PreEndJournal.self, from: h.home.paths.preEndFile)
        XCTAssertEqual(journal?.reason, EndReason.leasesReleased.rawValue)
        let order = h.notifier.posts.map(\.title).filter { $0 == PreEndRunner.title || $0 == "Session ended" }
        XCTAssertEqual(order, [PreEndRunner.title, "Session ended"])
    }
}
