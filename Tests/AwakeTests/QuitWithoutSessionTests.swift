import XCTest
@testable import Awake

/// An end that undoes nothing says nothing: quitting an idle Awake used to
/// post "Session restored — Awake quit. Sleep is back to normal."
@MainActor
final class QuitWithoutSessionTests: XCTestCase {
    var h: Harness!

    override func setUp() async throws { h = Harness() }
    override func tearDown() async throws { h.home.destroy() }

    private func log() -> String {
        (try? String(contentsOf: h.home.paths.logFile, encoding: .utf8)) ?? ""
    }

    func testQuitWithNoSessionPostsAndLogsNoRestore() async throws {
        let m = h.makeManager()
        await m.reconcile()
        let before = h.notifier.posts.count

        let outcome = await m.end(reason: .quit)

        XCTAssertEqual(outcome, .restored, "an idle quit must still be let through")
        XCTAssertTrue(outcome.letsQuitGo)
        XCTAssertEqual(h.notifier.posts.count, before, "posted \(h.notifier.posts.last?.title ?? "") for a quit that undid nothing")
        XCTAssertEqual(h.guardFake.calls.filter { $0 != "pmset -g" }, [], "a pmset write ran with nothing to undo")
        XCTAssertFalse(log().contains("session end (quit)"), "an idle quit was logged as a session end")
        XCTAssertFalse(log().lowercased().contains("restored"), "an idle quit was logged as a restore")
        XCTAssertTrue(log().contains("quit: no session and nothing to undo"))
    }

    func testEndingByHandWithNoSessionSaysNothingEither() async throws {
        let m = h.makeManager()
        await m.reconcile()
        let before = h.notifier.posts.count
        let outcome = await m.end(reason: .user)
        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(h.notifier.posts.count, before)
    }

    func testQuitDuringASessionStillSaysSessionEnded() async throws {
        let m = h.makeManager()
        await m.start(duration: 3600)
        XCTAssertNotNil(m.session)

        let outcome = await m.end(reason: .quit)

        XCTAssertEqual(outcome, .restored)
        let post = try XCTUnwrap(h.notifier.posts.last { $0.title != SessionReport.title })
        XCTAssertEqual(post.title, "Session ended")
        XCTAssertEqual(post.body, "Awake quit. Sleep is back to normal.")
        XCTAssertEqual(h.guardFake.calls.last, "disablesleep 0")
        XCTAssertTrue(log().contains("session end (quit)"))
    }

    /// No session in this process, but the journal still holds an entry:
    /// the quit undoes it and must say so.
    func testQuitThatUndoesAJournalEntryStillSaysSessionRestored() async throws {
        let m = h.makeManager()
        try m.journal { $0.sleepDisabledByUs = true }
        XCTAssertNil(m.session)

        let outcome = await m.end(reason: .quit)

        XCTAssertEqual(outcome, .restored)
        XCTAssertEqual(h.guardFake.calls, ["disablesleep 0"])
        let post = try XCTUnwrap(h.notifier.posts.last)
        XCTAssertEqual(post.title, "Session restored")
        XCTAssertEqual(post.body, "Awake quit. Sleep is back to normal.")
        XCTAssertEqual(try h.store.loadState(), RuntimeState.clean)
        XCTAssertTrue(log().contains("session end (quit)"))
    }
}
