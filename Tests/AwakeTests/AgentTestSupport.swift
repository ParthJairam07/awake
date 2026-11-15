import Foundation
import XCTest
@testable import Awake

/// A fixed process table for the agent registry and tracker.
final class FakeAgentProbe: AgentProcessProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _processes: [AgentProcess] = []
    private var _apps: [RunningApp] = []
    private var _usage: [Int32: AgentProcessUsage] = [:]

    var processList: [AgentProcess] {
        get { lock.withLock { _processes } }
        set { lock.withLock { _processes = newValue } }
    }
    var appList: [RunningApp] {
        get { lock.withLock { _apps } }
        set { lock.withLock { _apps = newValue } }
    }
    var usageTable: [Int32: AgentProcessUsage] {
        get { lock.withLock { _usage } }
        set { lock.withLock { _usage = newValue } }
    }

    func processes() -> [AgentProcess] { processList }
    func apps() -> [RunningApp] { appList }
    func usage(pid: Int32) -> AgentProcessUsage? { usageTable[pid] }
    func parent(of pid: Int32) -> Int32? { processList.first { $0.pid == pid }?.entry.ppid }

    /// Adds a process; `startedAt` defaults to the pid, so every fixture
    /// process has its own identity.
    @discardableResult
    func add(_ pid: Int32, parent: Int32 = 1, exe: String, args: [String] = [], cwd: String? = nil, startedAt: Int64? = nil) -> AgentProcess {
        let p = AgentProcess(entry: ProcessEntry(pid: pid, ppid: parent, startedAt: startedAt ?? Int64(pid)), executable: exe, arguments: args)
        lock.withLock {
            _processes.removeAll { $0.pid == pid }
            _processes.append(p)
            _usage[pid] = AgentProcessUsage(cpuNanos: _usage[pid]?.cpuNanos ?? 0, residentBytes: 1_000_000, cwd: cwd)
        }
        return p
    }

    func remove(_ pid: Int32) {
        lock.withLock {
            _processes.removeAll { $0.pid == pid }
            _usage[pid] = nil
        }
    }

    /// Adds CPU time to a pid, as if it had run for `seconds` of one core.
    func burn(_ pid: Int32, seconds: Double) {
        lock.withLock {
            guard var u = _usage[pid] else { return }
            u.cpuNanos += UInt64(seconds * 1_000_000_000)
            _usage[pid] = u
        }
    }
}

final class FakeTmux: TmuxReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _panes: [TmuxPane] = []
    private var _text: [String: String] = [:]

    var paneList: [TmuxPane] {
        get { lock.withLock { _panes } }
        set { lock.withLock { _panes = newValue } }
    }
    var text: [String: String] {
        get { lock.withLock { _text } }
        set { lock.withLock { _text = newValue } }
    }

    func panes() async -> [TmuxPane] { paneList }
    func capture(paneId: String) async -> String? { text[paneId] }
}

/// Answers git (and anything else) from a script of rules; records every
/// call.
final class FakeShellRunner: ShellRunning, @unchecked Sendable {
    struct Call: Equatable {
        let exe: String
        let args: [String]
        let timeout: TimeInterval
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    /// First rule whose predicate matches the arguments answers.
    var rules: [(matches: @Sendable ([String]) -> Bool, outcome: ShellOutcome)] = []
    var fallback: ShellOutcome = .finished(ShellResult(status: 0, stdout: "", stderr: ""))
    var calls: [Call] { lock.withLock { _calls } }

    func on(_ needle: [String], _ outcome: ShellOutcome) {
        rules.append(({ args in needle.allSatisfy(args.contains) }, outcome))
    }

    func run(_ exe: String, _ args: [String], timeout: TimeInterval) async -> ShellOutcome {
        lock.withLock { _calls.append(Call(exe: exe, args: args, timeout: timeout)) }
        return rules.first { $0.matches(args) }?.outcome ?? fallback
    }

    static func ok(_ stdout: String = "") -> ShellOutcome { .finished(ShellResult(status: 0, stdout: stdout, stderr: "")) }
    static func fail(_ status: Int32 = 1, _ stderr: String = "") -> ShellOutcome { .finished(ShellResult(status: status, stdout: "", stderr: stderr)) }
}

extension RecordingNotifier {
    var titles: [String] { posts.map(\.title) }
    func bodies(titled title: String) -> [String] { posts.filter { $0.title == title }.map(\.body) }
}
