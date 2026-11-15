import AwakeLeaseKit
import XCTest
@testable import Awake

/// Phase 4: the lease manager over the fake session harness. The leases
/// directory is the real one under the test's temp AWAKE_HOME; processes
/// and tmux are fakes.
@MainActor
final class LeaseManagerTests: XCTestCase {
    var h: Harness!
    var table: FakeLeaseProcesses!
    var tmux: FakeLeaseTmux!
    var store: LeaseStore!

    override func setUp() async throws {
        h = Harness()
        table = FakeLeaseProcesses()
        tmux = FakeLeaseTmux()
        store = LeaseStore(directory: h.home.paths.leasesDirectory)
    }

    override func tearDown() async throws { h.home.destroy() }

    private var now: Date { h.clock.now }

    private func makeLeases(for m: SessionManager) -> LeaseManager {
        let c = h.clock
        let t = table!
        let leases = LeaseManager(
            manager: m,
            notifier: h.notifier,
            clock: { c.now },
            processLookup: { t.lookup($0) },
            tmux: tmux.runner
        )
        m.leases = leases
        return leases
    }

    @discardableResult
    private func grant(
        _ duration: TimeInterval,
        owner: String = "claude",
        reason: String = "refactor billing",
        until: LeaseUntil? = nil,
        grace: Int = 0,
        createdAt: Date? = nil
    ) throws -> Lease {
        let lease = Lease(owner: owner, reason: reason, createdAt: createdAt ?? now, expiresAt: now.addingTimeInterval(duration), until: until, graceSeconds: grace, source: .cli)
        try store.write(lease)
        return lease
    }

    private func exists(_ lease: Lease) -> Bool {
        FileManager.default.fileExists(atPath: store.url(for: lease.id).path)
    }

    private func posts(_ title: String) -> [String] {
        h.notifier.posts.filter { $0.title == title }.map(\.body)
    }

    // MARK: A lease starts a session

    func testALeaseStartsASessionWithTheDefaultDurationAsItsFirstHorizon() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        let lease = try grant(3600)

        await leases.sync()

        let session = try XCTUnwrap(m.session, "a valid lease starts a session")
        XCTAssertEqual(session.endsAt, now.addingTimeInterval(m.config.defaultPreset), "the first horizon is the default duration: a 1 h lease does not shorten it")
        XCTAssertTrue(h.guardFake.sleepDisabled)
        XCTAssertEqual(leases.held, [lease])
        XCTAssertTrue(leases.state.startedByLeases)
        XCTAssertEqual(posts(LeaseManager.grantedTitle).count, 1)
        XCTAssertEqual(posts(LeaseManager.grantedTitle).first, LeaseManager.grantedBody(lease, now: now, capSeconds: m.config.leaseCapSeconds))
        XCTAssertEqual(h.store.loadReport()?.leasesGranted, 1)
        XCTAssertEqual(h.store.loadReport()?.maxLeasesHeld, 1)
    }

    func testTheEndIsTheLatestLeaseExpiryPlusTheGraceWhenThatIsLater() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        try grant(2 * 3600, owner: "codex")
        try grant(6 * 3600)

        await leases.sync()

        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(6 * 3600 + 5 * 60), "max(planned end, latest expiry + grace)")
        XCTAssertEqual(try h.store.loadSession()?.endsAt, m.session?.endsAt, "the end is in session.json, where the recovery agent reads it")
        XCTAssertEqual(h.store.loadReport()?.leasesGranted, 2)
        XCTAssertEqual(h.store.loadReport()?.maxLeasesHeld, 2)
    }

    func testLeasesAreCappedByLeaseCapHours() async throws {
        let m = h.makeManager()
        m.config.leaseCapHours = 5
        let leases = makeLeases(for: m)
        try grant(20 * 3600)

        await leases.sync()

        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(5 * 3600), "a 20 h lease holds the Mac for the 5 h cap")
        XCTAssertEqual(leases.statuses(now: now).first?.remainingSeconds, 5 * 3600, "and is reported with the capped expiry")
    }

    func testTheCapCountsFromTheFirstLeaseOfTheSessionForAllOfThemTogether() async throws {
        let m = h.makeManager()
        m.config.leaseCapHours = 6
        let leases = makeLeases(for: m)
        let start = now
        try grant(5 * 3600)
        await leases.sync()
        h.clock.advance(4 * 3600)
        try grant(5 * 3600, owner: "codex")

        await leases.sync()

        XCTAssertEqual(m.session?.endsAt, start.addingTimeInterval(6 * 3600), "a second lease cannot carry the session past 6 h from the first")
    }

    func testLeasesAreCappedByMaxDuration() async throws {
        let m = h.makeManager()
        m.config.maxDuration = 3 * 3600
        m.config.leaseCapHours = 72
        let leases = makeLeases(for: m)
        try grant(10 * 3600)

        await leases.sync()

        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(3 * 3600))
    }

    func testAShortCapAlsoCutsTheFirstHorizon() async throws {
        let m = h.makeManager()
        m.config.leaseCapHours = 1
        let leases = makeLeases(for: m)
        try grant(30 * 60)

        await leases.sync()

        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(3600), "min(default 4 h, cap 1 h)")
    }

    func testLeaseGrantedIsPostedOncePerLeaseEvenAcrossARelaunch() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        try grant(3600)
        await leases.sync()
        await leases.sync()
        XCTAssertEqual(posts(LeaseManager.grantedTitle).count, 1)

        let relaunched = makeLeases(for: m)
        await relaunched.sync()
        XCTAssertEqual(posts(LeaseManager.grantedTitle).count, 1, "lease-state.json remembers what was announced")

        try grant(3600, owner: "codex")
        await relaunched.sync()
        XCTAssertEqual(posts(LeaseManager.grantedTitle).count, 2)
    }

    func testNoNotificationsWhenTheyAreTurnedOff() async throws {
        let m = h.makeManager()
        m.config.leaseNotifications = false
        let leases = makeLeases(for: m)
        let lease = try grant(3600)
        await leases.sync()
        try store.remove(id: lease.id)
        await leases.sync()

        XCTAssertEqual(posts(LeaseManager.grantedTitle), [])
        XCTAssertEqual(posts(LeaseManager.lastReleasedTitle), [])
        XCTAssertNotNil(m.session)
    }

    // MARK: The last lease goes

    func testReleasingTheLastLeaseEndsALeaseStartedSessionAfterTheGrace() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        let lease = try grant(3600)
        await leases.sync()
        h.clock.advance(600)
        try store.remove(id: lease.id)

        await leases.sync()

        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(300), "ends 5 minutes after the release")
        XCTAssertEqual(posts(LeaseManager.lastReleasedTitle), ["Ending in 5 min unless a new lease arrives."])
        XCTAssertEqual(leases.timerEndReason, .leasesReleased)

        await leases.sync()
        XCTAssertEqual(posts(LeaseManager.lastReleasedTitle).count, 1, "said once")

        h.clock.advance(300)
        await m.end(reason: leases.timerEndReason)
        XCTAssertNil(m.session)
        XCTAssertFalse(h.guardFake.sleepDisabled)
        let ended = h.notifier.posts.last { $0.title == "Session ended" }
        XCTAssertEqual(ended?.body, "The last lease was released or expired. Sleep is back to normal.")
        let summary = h.notifier.posts.last { $0.title == SessionReport.title }
        XCTAssertTrue(summary?.body.contains("(leases released)") ?? false, summary?.body ?? "")
        XCTAssertTrue(summary?.body.contains("1 lease granted.") ?? false, summary?.body ?? "")
    }

    func testAnExpiredLeaseIsDeletedAndCountsAsReleased() async throws {
        let m = h.makeManager()
        m.config.defaultPreset = 1800
        let leases = makeLeases(for: m)
        let lease = try grant(3600)
        await leases.sync()
        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(3600 + 300))
        h.clock.advance(3600)

        XCTAssertEqual(leases.timerEndReason, .leasesReleased, "read live: the lease expired this second and no pass has run")
        await leases.sync()

        XCTAssertFalse(exists(lease), "expired files are deleted")
        XCTAssertEqual(leases.held, [])
        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(300))
        XCTAssertEqual(leases.timerEndReason, .leasesReleased)
    }

    func testANewLeaseDuringTheGraceKeepsTheSession() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        let first = try grant(3600)
        await leases.sync()
        let start = now
        h.clock.advance(600)
        try store.remove(id: first.id)
        await leases.sync()
        h.clock.advance(120)
        try grant(5 * 3600, owner: "codex")

        await leases.sync()

        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(5 * 3600 + 300))
        XCTAssertEqual(m.session?.startedAt, start, "the same session")
        XCTAssertEqual(leases.timerEndReason, .timer)
    }

    func testAZeroGraceEndsAtTheRelease() async throws {
        let m = h.makeManager()
        m.config.leaseGraceMinutes = 0
        let leases = makeLeases(for: m)
        let lease = try grant(3600)
        await leases.sync()
        h.clock.advance(60)
        try store.remove(id: lease.id)

        await leases.sync()

        XCTAssertEqual(m.session?.endsAt, now)
        XCTAssertEqual(posts(LeaseManager.lastReleasedTitle), ["The session only leases were holding ends now."])
    }

    // MARK: A session the user started

    func testAUserStartedSessionIsNeverShortenedByLeases() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        await m.start(duration: 4 * 3600)
        let planned = try XCTUnwrap(m.session?.endsAt)
        let lease = try grant(1800)

        await leases.sync()
        XCTAssertEqual(m.session?.endsAt, planned, "a shorter lease changes nothing")
        XCTAssertFalse(leases.state.startedByLeases)

        try store.remove(id: lease.id)
        await leases.sync()
        XCTAssertEqual(m.session?.endsAt, planned, "nor does its release")
        XCTAssertEqual(posts(LeaseManager.lastReleasedTitle), [], "the session was never the leases' to end")
        XCTAssertEqual(leases.timerEndReason, .timer)
    }

    func testALongerLeaseStretchesAUserSessionAndItsReleaseGivesTheUsersEndBack() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        await m.start(duration: 3600)
        let planned = try XCTUnwrap(m.session?.endsAt)
        let lease = try grant(3 * 3600)

        await leases.sync()
        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(3 * 3600 + 300))

        h.clock.advance(600)
        try store.remove(id: lease.id)
        await leases.sync()
        XCTAssertEqual(m.session?.endsAt, planned, "back to the end the user chose, not earlier")
        XCTAssertEqual(posts(LeaseManager.lastReleasedTitle), [])
        XCTAssertEqual(leases.timerEndReason, .timer)
    }

    func testAUserSessionHeldPastItsEndByLeasesEndsAfterTheGraceOnceTheyGo() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        await m.start(duration: 3600)
        let lease = try grant(3 * 3600)
        await leases.sync()
        h.clock.advance(2 * 3600)
        try store.remove(id: lease.id)

        await leases.sync()

        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(300))
        XCTAssertEqual(posts(LeaseManager.lastReleasedTitle).count, 1)
        XCTAssertEqual(leases.timerEndReason, .leasesReleased)
    }

    func testTimeAddedByHandToALeaseStartedSessionMakesItTheUsers() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        let lease = try grant(3600)
        await leases.sync()
        await m.extend(by: 3600)
        let chosen = try XCTUnwrap(m.session?.endsAt)
        XCTAssertEqual(chosen, now.addingTimeInterval(5 * 3600))

        await leases.sync()
        XCTAssertFalse(leases.state.startedByLeases)
        try store.remove(id: lease.id)
        await leases.sync()

        XCTAssertEqual(m.session?.endsAt, chosen, "the release no longer ends it")
        XCTAssertEqual(posts(LeaseManager.lastReleasedTitle), [])
        XCTAssertEqual(leases.timerEndReason, .timer)
    }

    func testAMoveDecidedBeforeTheUserExtendedIsDropped() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        let before = try XCTUnwrap(m.session?.endsAt)
        await m.extend(by: 3600)
        let extended = try XCTUnwrap(m.session?.endsAt)

        let moved = await m.moveEnd(to: before.addingTimeInterval(-600), from: before)

        XCTAssertNil(moved)
        XCTAssertEqual(m.session?.endsAt, extended)
    }

    func testMoveEndNeverGoesBeforeNowOrPastMaxDuration() async throws {
        let m = h.makeManager()
        m.config.maxDuration = 2 * 3600
        await m.start(duration: 3600)
        var end = try XCTUnwrap(m.session?.endsAt)

        let late = await m.moveEnd(to: now.addingTimeInterval(9 * 3600), from: end)
        XCTAssertEqual(late, now.addingTimeInterval(2 * 3600))
        end = try XCTUnwrap(m.session?.endsAt)
        let early = await m.moveEnd(to: now.addingTimeInterval(-60), from: end)
        XCTAssertEqual(early, now)
        XCTAssertEqual(try h.store.loadSession()?.endsAt, now)
        XCTAssertGreaterThanOrEqual(h.backstop.arms, 3, "the recovery agent is confirmed before each move")
    }

    // MARK: Settings

    func testLeasesTurnedOffHoldNothingAndAreLeftOnDisk() async throws {
        let m = h.makeManager()
        m.config.leasesEnabled = false
        let leases = makeLeases(for: m)
        let lease = try grant(3600)

        await leases.sync()

        XCTAssertNil(m.session)
        XCTAssertEqual(leases.held, [])
        XCTAssertTrue(exists(lease))
        XCTAssertEqual(h.notifier.posts.count, 0)
    }

    func testLeasesThatMayNotStartASessionStillStretchOne() async throws {
        let m = h.makeManager()
        m.config.leasesMayStartSession = false
        let leases = makeLeases(for: m)
        let lease = try grant(6 * 3600)

        await leases.sync()
        XCTAssertNil(m.session)
        XCTAssertEqual(leases.held, [lease], "listed, but holding nothing")
        XCTAssertTrue(posts(LeaseManager.grantedTitle).first?.hasSuffix("It holds nothing until you start a session.") ?? false)
        XCTAssertEqual(leases.menuLines(now: now).first, "Leases: 1 (waiting for a session) \u{2014} claude 'refactor billing' 6h left")

        await m.start(duration: 3600)
        await leases.sync()
        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(6 * 3600 + 300))
    }

    func testAStartThatFailsIsNotTriedAgainUntilANewLeaseArrives() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        h.backstop.failArm = true
        try grant(3600)

        await leases.sync()
        await leases.sync()
        await leases.sync()
        XCTAssertNil(m.session)
        let starts = h.guardFake.calls.count
        XCTAssertEqual(leases.state.startIntentAt, nil)

        h.backstop.failArm = false
        await leases.sync()
        XCTAssertNil(m.session, "the same lease does not try again")
        XCTAssertEqual(h.guardFake.calls.count, starts)

        try grant(3600, owner: "codex")
        await leases.sync()
        XCTAssertNotNil(m.session, "a new lease does")
    }

    // MARK: Files that are not leases

    func testInvalidFilesAreDeletedOnceTheyAreOldEnough() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        try store.ensureDirectory()
        let garbage = store.directory.appendingPathComponent("\(Lease.idText(UUID())).json")
        try Data("{ not json".utf8).write(to: garbage)
        let misnamed = store.directory.appendingPathComponent("notes.json")
        try Data("{}".utf8).write(to: misnamed)
        let other = store.directory.appendingPathComponent("README.txt")
        try Data("hello".utf8).write(to: other)
        let fm = FileManager.default
        // The files are stamped by the real clock; the fake one is later.
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-3)], ofItemAtPath: garbage.path)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-60)], ofItemAtPath: misnamed.path)

        await leases.sync()
        XCTAssertTrue(fm.fileExists(atPath: garbage.path), "a file written a moment ago may still be being written")
        XCTAssertFalse(fm.fileExists(atPath: misnamed.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path), "only *.json is the manager's to judge")

        h.clock.advance(30)
        await leases.sync()
        XCTAssertFalse(fm.fileExists(atPath: garbage.path))
        XCTAssertNil(m.session)
    }

    func testLeasesWithImpossibleDatesAreDeleted() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        let backwards = Lease(owner: "a", reason: "", createdAt: now, expiresAt: now.addingTimeInterval(-10), source: .cli)
        let future = Lease(owner: "b", reason: "", createdAt: now.addingTimeInterval(3600), expiresAt: now.addingTimeInterval(7200), source: .cli)
        let nameless = Lease(owner: " \n ", reason: "", createdAt: now, expiresAt: now.addingTimeInterval(600), source: .cli)
        for lease in [backwards, future, nameless] { try store.write(lease) }

        await leases.sync()

        for lease in [backwards, future, nameless] { XCTAssertFalse(exists(lease)) }
        XCTAssertNil(m.session)
    }

    func testALeaseRewrittenWhileItWasBeingJudgedIsNotDeleted() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        let shell = table.run(700)
        let pane = LeasePane(target: "work:1.0", paneId: "%3", socketPath: "/tmp/s", process: shell)
        tmux.answer = .init(status: 0, stdout: FakeLeaseTmux.line(id: "%3", pid: 700, command: "zsh"), stderr: "")
        var lease = try grant(600, until: .tmux(pane))
        // The pass has read the lease and is asking tmux about its pane
        // when an extend replaces the file.
        lease.expiresAt = now.addingTimeInterval(7200)
        let extended = lease
        let store = store!
        tmux.onCall = { try? store.write(extended) }

        await leases.sync()

        XCTAssertTrue(exists(lease), "the delete was decided from the file as it was; the new one stays")
        XCTAssertEqual(store.load(id: lease.id)?.expiresAt, extended.expiresAt)
    }

    // MARK: until

    func testUntilPidIsHeldWhileThatProcessLivesAndReleasedAfterItsGrace() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        let process = table.run(4242)
        let lease = try grant(6 * 3600, until: .pid(process), grace: 120)

        await leases.sync()
        XCTAssertEqual(leases.held, [lease])

        h.clock.advance(30)
        table.exit(4242)
        await leases.sync()
        XCTAssertTrue(exists(lease), "finished, but inside its idle grace")

        h.clock.advance(119)
        await leases.sync()
        XCTAssertTrue(exists(lease))

        h.clock.advance(1)
        await leases.sync()
        XCTAssertFalse(exists(lease))
        XCTAssertEqual(leases.held, [])
        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(300), "then the session's own grace")
    }

    func testAReusedPidNeverHoldsALease() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        let process = table.run(4242)
        let lease = try grant(6 * 3600, until: .pid(process))
        await leases.sync()
        // The process exits and another one is given its pid.
        table.run(4242, startedAt: process.startedAt + 50)

        h.clock.advance(30)
        await leases.sync()

        XCTAssertFalse(exists(lease), "the pid is alive, but it is not the process the lease named")
    }

    func testAProcessFromBeforeARestartNeverHoldsALease() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        var process = table.run(4242)
        process.bootSession = "an-earlier-boot"
        let lease = try grant(6 * 3600, until: .pid(process))

        await leases.sync()

        XCTAssertFalse(exists(lease))
        XCTAssertNil(m.session)
    }

    func testAProcessThatComesBackInsideTheGraceKeepsTheLease() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        table.unreadable.insert(4242)
        let process = LeaseProcess(pid: 4242, startedAt: 100, startedAtMicros: 5, bootSession: FakeLeaseProcesses.boot)
        let lease = try grant(3600, until: .command(process, name: "make"), grace: 0)

        await leases.sync()
        h.clock.advance(600)
        await leases.sync()

        XCTAssertTrue(exists(lease), "a process table that cannot be read is unknown, not finished")
        XCTAssertEqual(leases.held, [lease])
    }

    func testUntilTmuxFollowsThePane() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        let shell = table.run(700)
        let pane = LeasePane(target: "work:1.0", paneId: "%3", socketPath: "/tmp/tmux-501/default", process: shell)
        tmux.answer = .init(status: 0, stdout: FakeLeaseTmux.line(id: "%3", pid: 700, command: "node"), stderr: "")
        let lease = try grant(6 * 3600, until: .tmux(pane))

        await leases.sync()
        XCTAssertEqual(leases.held, [lease])
        XCTAssertEqual(tmux.calls.last, ["-S", "/tmp/tmux-501/default", "display-message", "-p", "-t", "%3", "-F", LeaseTmux.format], "asked by pane id on the recorded socket; nothing is ever typed")

        tmux.answer = nil
        h.clock.advance(30)
        await leases.sync()
        XCTAssertTrue(exists(lease), "tmux missing is unknown")

        tmux.answer = .init(status: 0, stdout: FakeLeaseTmux.line(id: "%3", pid: 700, command: "zsh"), stderr: "")
        h.clock.advance(30)
        await leases.sync()
        XCTAssertFalse(exists(lease), "back at the shell prompt: the work is done")
    }

    // MARK: Floors and other ends win

    func testABatteryFloorEndRevokesTheLeasesSoTheyDoNotRestartTheSession() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        let lease = try grant(6 * 3600)
        let other = try grant(3600, owner: "codex")
        await leases.sync()

        await m.end(reason: .batteryFloor)

        XCTAssertNil(m.session, "the floor ends the session whatever the leases say")
        XCTAssertFalse(exists(lease))
        XCTAssertFalse(exists(other))
        XCTAssertEqual(posts(LeaseManager.revokedTitle), ["The session ended (battery floor), so its 2 leases were revoked: claude, codex. A new lease starts a new session."])
        await leases.sync()
        XCTAssertNil(m.session)
        XCTAssertFalse(h.guardFake.sleepDisabled)

        try grant(3600, owner: "aider")
        await leases.sync()
        XCTAssertNotNil(m.session, "a lease asked for afterwards starts a new session; the floors judge that one too")
    }

    func testEveryEndButQuitAndLeasesReleasedRevokes() async throws {
        for reason in [EndReason.user, .timer, .thermalCritical, .batteryHot, .batteryUnreadable] {
            let m = h.makeManager()
            let leases = makeLeases(for: m)
            let lease = try grant(3600)
            await leases.sync()
            XCTAssertNotNil(m.session, reason.rawValue)

            await m.end(reason: reason)

            XCTAssertFalse(exists(lease), reason.rawValue)
            await leases.sync()
            XCTAssertNil(m.session, reason.rawValue)
        }
    }

    func testQuitKeepsTheLeasesForTheNextLaunch() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        let lease = try grant(3600)
        await leases.sync()

        await m.end(reason: .quit)
        await leases.sync()

        XCTAssertTrue(exists(lease))
        XCTAssertNil(m.session, "nothing starts while the app is quitting")
        XCTAssertEqual(posts(LeaseManager.revokedTitle), [])

        let next = h.makeManager()
        let relaunched = makeLeases(for: next)
        await next.reconcile()
        await relaunched.sync()
        XCTAssertNotNil(next.session, "the next launch picks the lease up")
        XCTAssertEqual(posts(LeaseManager.grantedTitle).count, 1)
    }

    func testALeaseMadeWhileTheAppWasNotRunningSurvivesTheReconcileOfAnExpiredSession() async throws {
        let first = h.makeManager()
        let old = makeLeases(for: first)
        try grant(600)
        await old.sync()
        XCTAssertNotNil(first.session)
        // The app dies; the session and its lease expire; a new lease is
        // written by the command while nothing is running.
        h.clock.advance(5 * 3600)
        let fresh = try grant(3600, owner: "codex")

        let m = h.makeManager()
        let leases = makeLeases(for: m)
        await m.reconcile()
        XCTAssertNil(m.session)
        await leases.sync()

        XCTAssertTrue(exists(fresh), "the end of the old session revokes only what that session honoured")
        XCTAssertNotNil(m.session)
        XCTAssertEqual(leases.held, [fresh])
    }

    func testARelaunchInTheMiddleOfALeaseStartedSessionStillEndsItWhenTheLeasesGo() async throws {
        let first = h.makeManager()
        let old = makeLeases(for: first)
        let lease = try grant(3600)
        await old.sync()
        h.clock.advance(600)

        let m = h.makeManager()
        let leases = makeLeases(for: m)
        await m.reconcile()
        XCTAssertNotNil(m.session, "the session on disk is resumed")
        await leases.sync()
        XCTAssertTrue(leases.state.startedByLeases)
        try store.remove(id: lease.id)
        await leases.sync()

        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(300))
        XCTAssertEqual(leases.timerEndReason, .leasesReleased)
    }

    // MARK: Reporting

    func testLeasesAreListedInTheMenuAndTheStatusSnapshot() async throws {
        let m = h.makeManager()
        let leases = makeLeases(for: m)
        // Made a second apart: leases are held oldest first, and two made
        // in the same instant would be ordered by their random ids.
        try grant(72 * 60, reason: "refactor billing", createdAt: now.addingTimeInterval(-1))
        try grant(30 * 60, owner: "codex", reason: "")
        await leases.sync()

        XCTAssertEqual(leases.menuLines(now: now), [
            "Leases: 2 \u{2014} claude 'refactor billing' 1h 12m left",
            "    codex 30m left",
        ])
        let items = StatusMenu.items(sessionActive: true, sleepHeld: true, machine: "Lid: open", actions: nil, throttledBrowsers: [], error: nil, leases: leases.menuLines(now: now))
        XCTAssertEqual(items.map(\.title), [
            "Sleep held per journal \u{2014} not verified live",
            "Lid: open",
            "Leases: 2 \u{2014} claude 'refactor billing' 1h 12m left",
            "    codex 30m left",
            "",
            StatusMenu.settingsTitle,
            StatusMenu.quitTitle,
        ])

        let statuses = leases.statuses(now: now)
        XCTAssertEqual(statuses.map(\.owner), ["claude", "codex"])
        let snapshot = StatusSnapshot(updatedAt: now, active: true, startedAt: nil, endsAt: nil, remainingSeconds: nil, lidClosed: false, lidOnDesk: false, batteryPercent: nil, isCharging: false, chargerDraining: false, thermalState: "nominal", lowPowerSetByUs: false, wifiSSID: nil, lastOutageSeconds: nil, frozenCount: 0, dockerPaused: false, leases: statuses)
        let data = try StatusSnapshot.encode(snapshot)
        let decoded = try Store.makeDecoder().decode(StatusSnapshot.self, from: data)
        XCTAssertEqual(decoded.leases, statuses)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((json["leases"] as? [[String: Any]])?.first?["reason"] as? String, "refactor billing")
    }

    func testNoLeasesNoMenuLine() {
        let items = StatusMenu.items(sessionActive: false, sleepHeld: false, machine: nil, actions: nil, throttledBrowsers: [], error: nil, leases: [])
        XCTAssertEqual(items.map(\.kind), [.settings, .quit])
    }

    func testTheSummaryCountsLeases() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var r = SessionReport(startedAt: start, plannedEnd: start.addingTimeInterval(3600), batteryStart: nil)
        r.endedAt = start.addingTimeInterval(1800)
        r.endReason = EndReason.leasesReleased.rawValue
        r.leasesGranted = 3
        r.maxLeasesHeld = 2
        r.restored = true
        XCTAssertEqual(r.summary(now: r.endedAt!, endReasonText: SessionManager.reasonText), "Ran 30m (leases released). 3 leases granted, 2 at once. Everything restored.")
    }

    func testAReportWrittenBeforeLeasesExistedStillDecodes() throws {
        let old = #"{"startedAt":"2027-01-15T08:00:00Z","plannedEnd":"2027-01-15T09:00:00Z","lidCloses":1,"lowPowerEvents":0,"thermalEvents":0,"chargerWeakEvents":0,"outages":0,"outageSeconds":0,"summaryPosted":false}"#
        let r = try Store.makeDecoder().decode(SessionReport.self, from: Data(old.utf8))
        XCTAssertNil(r.leasesGranted)
        XCTAssertEqual(r.lidCloses, 1)
    }

    func testConfigDefaultsAndAConfigWithoutTheKeys() throws {
        let c = Config()
        XCTAssertTrue(c.leasesEnabled)
        XCTAssertEqual(c.leaseCapHours, 8)
        XCTAssertEqual(c.leaseGraceMinutes, 5)
        XCTAssertTrue(c.leasesMayStartSession)
        XCTAssertTrue(c.leaseNotifications)
        let old = try Store.makeDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(old.leaseCapHours, 8)
        XCTAssertTrue(old.leasesEnabled)
        var edited = Config()
        edited.leaseCapHours = 0
        edited.leaseGraceMinutes = -3
        XCTAssertEqual(edited.leaseCapSeconds, 3600, "a hand-edited 0 does not turn the cap off")
        XCTAssertEqual(edited.leaseGraceSeconds, 0)
    }

    func testThePathsMatchTheKit() {
        let home = LeaseHome.fromEnvironment([LeaseHome.environmentKey: h.home.root.path])
        XCTAssertEqual(home.leasesDirectory.path, h.home.paths.leasesDirectory.path)
        XCTAssertEqual(home.statusFile.path, h.home.paths.statusFile.path)
        XCTAssertEqual(home.configFile.path, h.home.paths.configFile.path)
        XCTAssertEqual(LeaseHome.environmentKey, Paths.environmentKey)
        XCTAssertEqual(LeaseProcessProbe.bootSession, SignalProcessControl.bootSession)
    }

    func testTheKitReadsAProcessAsTheAppDoes() throws {
        let pid = getpid()
        guard case let .present(mine) = LeaseProcessProbe.lookup(pid: pid), case let .present(app) = SignalProcessControl.processTableState(pid: pid) else {
            return XCTFail("this process is in the process table")
        }
        XCTAssertEqual(mine.startedAt, app.identity.startedAt)
        XCTAssertEqual(mine.startedAtMicros, app.identity.startedAtMicros)
        XCTAssertEqual(mine.bootSession, app.identity.bootSession)
    }

    // MARK: The watcher

    func testTheWatcherReportsALeaseWrittenIntoTheDirectory() async throws {
        try store.ensureDirectory()
        let watcher = LeaseDirectoryWatcher()
        let changed = expectation(description: "the directory change is reported")
        changed.assertForOverFulfill = false
        watcher.onChange = { changed.fulfill() }
        watcher.watch(store.directory)

        try grant(600)

        await fulfillment(of: [changed], timeout: 5)
        watcher.stop()
    }

    func testTheWatcherFollowsADirectoryThatWasDeletedAndMadeAgain() async throws {
        try store.ensureDirectory()
        let watcher = LeaseDirectoryWatcher()
        watcher.watch(store.directory)
        try FileManager.default.removeItem(at: store.directory)
        try store.ensureDirectory()
        let changed = expectation(description: "the new directory is watched")
        changed.assertForOverFulfill = false
        watcher.watch(store.directory)
        watcher.onChange = { changed.fulfill() }

        try grant(600)

        await fulfillment(of: [changed], timeout: 5)
        watcher.stop()
    }

    func testStartWatchesAndTheFirstPassRuns() async throws {
        let m = h.makeManager()
        let c = h.clock
        let watcher = FakeLeaseWatcher()
        let leases = LeaseManager(manager: m, notifier: h.notifier, clock: { c.now }, watcher: watcher)
        m.leases = leases
        try grant(3600)

        leases.start()
        await leases.sync()
        XCTAssertEqual(watcher.watched.first?.path, store.directory.path)
        XCTAssertNotNil(m.session)
        let perms = try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)

        try grant(7 * 3600, owner: "codex")
        watcher.onChange?()
        await leases.sync()
        XCTAssertEqual(m.session?.endsAt, now.addingTimeInterval(7 * 3600 + 300))

        leases.stop()
        XCTAssertTrue(watcher.stopped)
        await m.end(reason: .user)
    }
}

/// The process table for lease conditions.
final class FakeLeaseProcesses: @unchecked Sendable {
    static let boot = "boot-1"
    private let lock = NSLock()
    private var entries: [Int32: LeaseProcess] = [:]
    private var _unreadable: Set<Int32> = []
    var unreadable: Set<Int32> {
        get { lock.withLock { _unreadable } }
        set { lock.withLock { _unreadable = newValue } }
    }

    @discardableResult
    func run(_ pid: Int32, startedAt: Int64 = 1_799_999_000) -> LeaseProcess {
        let p = LeaseProcess(pid: pid, startedAt: startedAt, startedAtMicros: 123_456, bootSession: Self.boot)
        lock.withLock { entries[pid] = p }
        return p
    }

    func exit(_ pid: Int32) { lock.withLock { entries[pid] = nil } }

    func lookup(_ pid: Int32) -> LeaseProcessLookup {
        lock.withLock {
            if _unreadable.contains(pid) { return .unreadable(EPERM) }
            return entries[pid].map { .present($0) } ?? .absent
        }
    }
}

final class FakeLeaseTmux: @unchecked Sendable {
    private let lock = NSLock()
    private var _answer: LeaseTmux.Output?
    private var _calls: [[String]] = []
    /// nil: tmux is not installed.
    var answer: LeaseTmux.Output? {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }
    var calls: [[String]] { lock.withLock { _calls } }
    /// Runs once, during the next call.
    var onCall: (@Sendable () -> Void)? {
        get { lock.withLock { _onCall } }
        set { lock.withLock { _onCall = newValue } }
    }
    private var _onCall: (@Sendable () -> Void)?

    var runner: LeaseTmux.Runner {
        { [self] args in
            let hook = lock.withLock { () -> (@Sendable () -> Void)? in
                defer { _onCall = nil }
                return _onCall
            }
            hook?()
            return lock.withLock {
                _calls.append(args)
                return _answer
            }
        }
    }

    static func line(id: String, dead: Bool = false, pid: Int32, socket: String = "/tmp/tmux-501/default", command: String) -> String {
        [id, dead ? "1" : "0", "\(pid)", socket, command].joined(separator: LeaseTmux.separator) + "\n"
    }
}

@MainActor
final class FakeLeaseWatcher: LeaseDirectoryWatching {
    var onChange: (@MainActor () -> Void)?
    var watched: [URL] = []
    var stopped = false
    func watch(_ directory: URL) { watched.append(directory) }
    func stop() { stopped = true }
}
