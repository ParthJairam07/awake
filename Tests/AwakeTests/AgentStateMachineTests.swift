import XCTest
@testable import Awake

final class PromptDetectorTests: XCTestCase {
    private func lines(_ text: String) -> [String] { PromptDetector.tail(of: text) }

    func testQuestionPhrasesAreFound() {
        for text in [
            "Overwrite config.toml? (y/n)",
            "Proceed with install [Y/n]",
            "Allow? ",
            "Do you want to make this edit to main.swift?",
            "Press Enter to continue",
            "Are you sure you want to continue connecting (yes/no/[fingerprint])?",
            "Allow command? rm -rf build",
            "Claude needs your permission to use Bash",
        ] {
            XCTAssertNotNil(PromptDetector.question(in: lines("building...\n\(text)\n")), text)
        }
    }

    func testClaudeNumberedMenuReportsTheQuestionLine() {
        let pane = """
        ╭──────────────────────────────────────────╮
        │ Bash command                             │
        │   rm -rf build                           │
        │ Do you want to proceed?                  │
        │ ❯ 1. Yes                                 │
        │   2. Yes, and don't ask again            │
        │   3. No, and tell Claude what to do      │
        ╰──────────────────────────────────────────╯
        """
        let match = PromptDetector.question(in: lines(pane))
        XCTAssertEqual(match?.excerpt, "Do you want to proceed?")
        XCTAssertEqual(match?.isSudo, false)
    }

    func testANumberedMenuWithoutAQuestionPhraseReportsTheSelectedChoice() {
        let match = PromptDetector.question(in: lines("Pick a model\n❯ 1. Opus\n  2. Sonnet\n"))
        XCTAssertEqual(match?.excerpt, "❯ 1. Opus")
    }

    func testAQuestionAboveTheInputLineIsAlreadyAnswered() {
        let pane = "Do you want to proceed?\n❯ 1. Yes\nRan rm -rf build\nDone.\n❯ \n"
        XCTAssertNil(PromptDetector.question(in: lines(pane)))
        XCTAssertTrue(PromptDetector.isIdleAtPrompt(lines(pane)))
    }

    func testSudoPasswordPromptIsMarked() {
        XCTAssertEqual(PromptDetector.question(in: lines("$ sudo make install\nPassword:"))?.isSudo, true)
        XCTAssertEqual(PromptDetector.question(in: lines("[sudo] password for dev: "))?.isSudo, true)
        XCTAssertEqual(PromptDetector.question(in: lines("Enter passphrase for key '/x/id_ed25519':"))?.isSudo, false)
    }

    func testOnlyTheLastLinesAreRead() {
        let old = "Do you want to proceed?\n" + (1...30).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertNil(PromptDetector.question(in: lines(old)))
    }

    func testIdlePromptAndWorkingIndicator() {
        XCTAssertTrue(PromptDetector.isIdleAtPrompt(lines("All done.\n╭────╮\n│ > Try \"fix lint\" │\n╰────╯\n  ? for shortcuts")))
        XCTAssertTrue(PromptDetector.isIdleAtPrompt(lines("make: done\ndev@mac repo %")))
        XCTAssertFalse(PromptDetector.isIdleAtPrompt(lines("✻ Thinking… (12s · esc to interrupt)\n│ > │")))
        XCTAssertFalse(PromptDetector.isIdleAtPrompt(lines("Compiling 12/80")))
        XCTAssertFalse(PromptDetector.isIdleAtPrompt([]))
    }

    func testMenuAndPromptShapes() {
        XCTAssertTrue(PromptDetector.isMenuChoice("❯ 1. Yes"))
        XCTAssertTrue(PromptDetector.isMenuChoice("2. No"))
        XCTAssertTrue(PromptDetector.isMenuChoice("> 3) Cancel"))
        XCTAssertFalse(PromptDetector.isMenuChoice("2024. was a year"))
        XCTAssertFalse(PromptDetector.isMenuChoice("1."))
        XCTAssertTrue(PromptDetector.isInputPrompt("❯"))
        XCTAssertTrue(PromptDetector.isInputPrompt("› Ask Codex to do anything"))
        XCTAssertFalse(PromptDetector.isInputPrompt("❯ 1. Yes"))
        XCTAssertFalse(PromptDetector.isInputPrompt(">>> python"))
    }

    func testExcerptIsCollapsedAndCapped() {
        XCTAssertEqual(PromptDetector.excerpt("Allow   this\tedit?"), "Allow this edit?")
        let long = String(repeating: "x", count: 400)
        XCTAssertEqual(PromptDetector.excerpt(long).count, PromptDetector.excerptLimit)
        XCTAssertTrue(PromptDetector.excerpt(long).hasSuffix("…"))
    }

    func testHashIsStableAndTextSensitive() {
        XCTAssertEqual(PromptDetector.hash("abc"), PromptDetector.hash("abc"))
        XCTAssertNotEqual(PromptDetector.hash("abc"), PromptDetector.hash("abd"))
        XCTAssertEqual(PromptDetector.hash(""), 0xcbf2_9ce4_8422_2325)
    }
}

final class AgentStateMachineTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private let quick = AgentStateMachine.Thresholds(stallAfter: 600)

    func testStartsAliveAndNeedsTwoSamplesToCallItIdle() {
        var m = AgentStateMachine(firstSeen: t0)
        XCTAssertEqual(m.state, .alive)
        XCTAssertNil(m.ingest(AgentSample(at: at(0)), thresholds: quick))
        XCTAssertEqual(m.state, .alive)
        XCTAssertEqual(m.ingest(AgentSample(at: at(20), cpuPercent: 0.2), thresholds: quick), AgentTransition(from: .alive, to: .idle))
        XCTAssertEqual(m.since, at(20))
    }

    func testCPUAboveTheThresholdIsBusyAndBelowIsIdle() {
        var m = AgentStateMachine(firstSeen: t0)
        m.ingest(AgentSample(at: at(0)), thresholds: quick)
        XCTAssertEqual(m.ingest(AgentSample(at: at(20), cpuPercent: 40), thresholds: quick)?.to, .busy)
        XCTAssertNil(m.ingest(AgentSample(at: at(40), cpuPercent: 3), thresholds: quick), "exactly at the threshold is still busy")
        XCTAssertEqual(m.ingest(AgentSample(at: at(60), cpuPercent: 2.9), thresholds: quick)?.to, .idle)
    }

    func testChangingPaneTextIsBusyEvenWithNoCPU() {
        var m = AgentStateMachine(firstSeen: t0)
        m.ingest(AgentSample(at: at(0), paneText: "a"), thresholds: quick)
        XCTAssertEqual(m.ingest(AgentSample(at: at(20), cpuPercent: 0, paneText: "ab"), thresholds: quick)?.to, .busy)
        XCTAssertEqual(m.lastOutputChange, at(20))
        XCTAssertEqual(m.lastOutputAge(now: at(50)), 30)
    }

    func testAQuestionMustSitUnchangedForOnePollBeforeItCountsAsWaiting() {
        var m = AgentStateMachine(firstSeen: t0)
        let pane = "Do you want to proceed?\n❯ 1. Yes\n  2. No"
        XCTAssertNil(m.ingest(AgentSample(at: at(0), paneText: pane), thresholds: quick))
        let t = m.ingest(AgentSample(at: at(20), cpuPercent: 30, paneText: pane), thresholds: quick)
        XCTAssertEqual(t, AgentTransition(from: .alive, to: .waitingForInput), "waiting wins over a spinner's CPU")
        XCTAssertEqual(m.waitingPrompt, "Do you want to proceed?")
        XCTAssertNil(m.ingest(AgentSample(at: at(40), paneText: pane), thresholds: quick), "one transition, not one per poll")
        XCTAssertEqual(m.ingest(AgentSample(at: at(60), paneText: "Running rm -rf build"), thresholds: quick)?.to, .busy)
        XCTAssertNil(m.waitingPrompt)
    }

    func testSudoPromptIsFlagged() {
        var m = AgentStateMachine(firstSeen: t0)
        m.ingest(AgentSample(at: at(0), paneText: "Password:"), thresholds: quick)
        m.ingest(AgentSample(at: at(20), paneText: "Password:"), thresholds: quick)
        XCTAssertEqual(m.state, .waitingForInput)
        XCTAssertTrue(m.waitingOnSudo)
    }

    func testStallsAfterTheThresholdWithoutOutputAndRecoversOnOutput() {
        var m = AgentStateMachine(firstSeen: t0)
        let pane = "✻ Compacting… (esc to interrupt)"
        m.ingest(AgentSample(at: at(0), paneText: pane), thresholds: quick)
        XCTAssertEqual(m.ingest(AgentSample(at: at(20), cpuPercent: 0, paneText: pane), thresholds: quick)?.to, .idle)
        XCTAssertNil(m.ingest(AgentSample(at: at(580), cpuPercent: 0, paneText: pane), thresholds: quick))
        XCTAssertEqual(m.ingest(AgentSample(at: at(600), cpuPercent: 0, paneText: pane), thresholds: quick), AgentTransition(from: .idle, to: .stalled))
        XCTAssertNil(m.ingest(AgentSample(at: at(620), cpuPercent: 0, paneText: pane), thresholds: quick), "stays stalled, announced once")
        XCTAssertEqual(m.ingest(AgentSample(at: at(640), cpuPercent: 0, paneText: pane + "\nok"), thresholds: quick)?.to, .busy)
    }

    func testAnAgentAtItsIdlePromptNeverStalls() {
        var m = AgentStateMachine(firstSeen: t0)
        let pane = "Done.\n❯ "
        m.ingest(AgentSample(at: at(0), paneText: pane), thresholds: quick)
        m.ingest(AgentSample(at: at(20), cpuPercent: 0, paneText: pane), thresholds: quick)
        XCTAssertNil(m.ingest(AgentSample(at: at(5000), cpuPercent: 0, paneText: pane), thresholds: quick))
        XCTAssertEqual(m.state, .idle)
    }

    func testWithoutAPaneOrHeartbeatsSilenceIsIdleNotStalled() {
        var m = AgentStateMachine(firstSeen: t0)
        m.ingest(AgentSample(at: at(0)), thresholds: quick)
        m.ingest(AgentSample(at: at(20), cpuPercent: 0), thresholds: quick)
        XCTAssertNil(m.ingest(AgentSample(at: at(5000), cpuPercent: 0), thresholds: quick))
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.lastOutputAge(now: at(5000)), "no output source, no age")
    }

    func testServersNeverWaitOrStall() {
        let server = AgentStateMachine.Thresholds(stallAfter: 600, conversational: false)
        var m = AgentStateMachine(firstSeen: t0)
        let pane = "Continue? (y/n)"
        m.ingest(AgentSample(at: at(0), paneText: pane), thresholds: server)
        XCTAssertEqual(m.ingest(AgentSample(at: at(20), paneText: pane), thresholds: server)?.to, .idle)
        XCTAssertNil(m.ingest(AgentSample(at: at(5000), paneText: pane), thresholds: server))
    }

    func testExitIsTerminal() {
        var m = AgentStateMachine(firstSeen: t0)
        m.ingest(AgentSample(at: at(0)), thresholds: quick)
        XCTAssertEqual(m.ingest(AgentSample(at: at(20), present: false), thresholds: quick), AgentTransition(from: .alive, to: .exited))
        XCTAssertNil(m.ingest(AgentSample(at: at(40), cpuPercent: 90), thresholds: quick))
        XCTAssertNil(m.ingest(hook: .heartbeat, at: at(60), hasProcess: true))
        XCTAssertEqual(m.state, .exited)
    }

    func testLogModificationCountsAsOutput() {
        var m = AgentStateMachine(firstSeen: t0)
        m.ingest(AgentSample(at: at(0), logModifiedAt: at(-100)), thresholds: quick)
        XCTAssertEqual(m.lastOutputAge(now: at(0)), 100)
        XCTAssertEqual(m.ingest(AgentSample(at: at(20), cpuPercent: 0, logModifiedAt: at(15)), thresholds: quick)?.to, .busy)
        XCTAssertEqual(m.lastOutputAge(now: at(20)), 5)
        XCTAssertEqual(m.ingest(AgentSample(at: at(40), cpuPercent: 0, logModifiedAt: at(15)), thresholds: quick)?.to, .idle)
    }

    // MARK: Hooks

    func testHookWaitingThenHeartbeatThenFinished() {
        var m = AgentStateMachine(firstSeen: t0)
        XCTAssertEqual(m.ingest(hook: .waiting("Claude needs your permission to use Bash"), at: at(5), hasProcess: true)?.to, .waitingForInput)
        XCTAssertEqual(m.waitingPrompt, "Claude needs your permission to use Bash")
        XCTAssertNil(m.ingest(AgentSample(at: at(20), cpuPercent: 50), thresholds: quick), "still waiting whatever the CPU says")
        XCTAssertEqual(m.ingest(hook: .heartbeat, at: at(30), hasProcess: true)?.to, .busy)
        XCTAssertNil(m.ingest(AgentSample(at: at(40), cpuPercent: 0), thresholds: quick), "a fresh heartbeat keeps it busy")
        XCTAssertEqual(m.ingest(hook: .finished, at: at(50), hasProcess: true)?.to, .idle)
        XCTAssertNil(m.ingest(AgentSample(at: at(5000), cpuPercent: 0), thresholds: quick), "finished: silence is rest, not a stall")
    }

    func testHookWaitingWithoutAMessageHasADefaultPrompt() {
        var m = AgentStateMachine(firstSeen: t0)
        m.ingest(hook: .waiting(nil), at: at(1), hasProcess: false)
        XCTAssertEqual(m.waitingPrompt, "needs your input")
    }

    func testHeartbeatsThenSilenceIsAStall() {
        var m = AgentStateMachine(firstSeen: t0)
        m.ingest(hook: .heartbeat, at: at(0), hasProcess: true)
        XCTAssertNil(m.ingest(AgentSample(at: at(20), cpuPercent: 0), thresholds: quick))
        XCTAssertEqual(m.ingest(AgentSample(at: at(80), cpuPercent: 0), thresholds: quick)?.to, .idle)
        XCTAssertEqual(m.ingest(AgentSample(at: at(600), cpuPercent: 0), thresholds: quick)?.to, .stalled)
        XCTAssertEqual(m.ingest(hook: .heartbeat, at: at(700), hasProcess: true)?.to, .busy)
    }

    func testNewOutputClearsAHooksWaiting() {
        var m = AgentStateMachine(firstSeen: t0)
        m.ingest(AgentSample(at: at(0), paneText: "a"), thresholds: quick)
        m.ingest(hook: .waiting("Allow?"), at: at(5), hasProcess: true)
        XCTAssertEqual(m.ingest(AgentSample(at: at(20), paneText: "a\nRunning tool"), thresholds: quick)?.to, .busy)
    }

    func testEndedHookExitsOnlyAnAgentWithoutAProcess() {
        var hookOnly = AgentStateMachine(firstSeen: t0)
        XCTAssertEqual(hookOnly.ingest(hook: .ended("logout"), at: at(1), hasProcess: false)?.to, .exited)
        XCTAssertEqual(hookOnly.exitNote, "logout")
        var backed = AgentStateMachine(firstSeen: t0)
        XCTAssertEqual(backed.ingest(hook: .ended("logout"), at: at(1), hasProcess: true)?.to, .idle)
        XCTAssertEqual(backed.ingest(AgentSample(at: at(20), present: false), thresholds: quick)?.to, .exited)
        XCTAssertEqual(backed.exitNote, "logout")
    }

    func testSettledStates() {
        XCTAssertEqual(AgentState.allCases.filter(\.isSettled), [.idle, .exited])
    }
}
