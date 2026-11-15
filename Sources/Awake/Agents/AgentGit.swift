import Foundation

/// How a child process ended, for callers that must never throw.
enum ShellOutcome: Sendable {
    case finished(ShellResult)
    case timedOut
    case failed(String)

    var succeeded: Bool {
        if case let .finished(r) = self { return r.succeeded }
        return false
    }

    var stdout: String {
        if case let .finished(r) = self { return r.stdout }
        return ""
    }

    /// One line for a log or a summary.
    var failure: String? {
        switch self {
        case let .finished(r):
            guard !r.succeeded else { return nil }
            let text = (r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let line = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            return line.isEmpty ? "exit \(r.status)" : "exit \(r.status): \(line.prefix(200))"
        case .timedOut: return "timed out"
        case let .failed(message): return message
        }
    }
}

/// The shell runner agent git work goes through. Never a shell: an
/// absolute executable and literal arguments. Tests hand in a fake.
protocol ShellRunning: Sendable {
    func run(_ exe: String, _ args: [String], timeout: TimeInterval) async -> ShellOutcome
}

struct LiveShellRunner: ShellRunning {
    func run(_ exe: String, _ args: [String], timeout: TimeInterval) async -> ShellOutcome {
        do {
            return .finished(try await Shell.run(exe, args, timeout: timeout))
        } catch is ShellTimeoutError {
            return .timedOut
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Git for agent repos: unpushed commits for the summary and the opt-in
/// wip save before a session ends. Never `sudo`, never `--force`.
struct AgentGit: Sendable {
    /// A real git binary. `/usr/bin/git` is left out on purpose: without
    /// the developer tools it opens an install dialog nobody is there to
    /// answer.
    static let candidates = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
    ]
    static let wipMessage = "wip: awake auto-save before session end"
    static let wipTimeout: TimeInterval = 60
    static let queryTimeout: TimeInterval = 10

    let runner: any ShellRunning
    let git: String?

    init(runner: any ShellRunning = LiveShellRunner(), git: String? = Shell.locate(AgentGit.candidates)) {
        self.runner = runner
        self.git = git
    }

    /// Runs git with prompts off: a push that wants a password fails
    /// instead of waiting for one.
    private func run(_ git: String, _ args: [String], timeout: TimeInterval) async -> ShellOutcome {
        await runner.run("/usr/bin/env", ["GIT_TERMINAL_PROMPT=0", git] + args, timeout: timeout)
    }

    /// Commits on the checked-out branch that its upstream does not have;
    /// nil when there is no upstream or git cannot say.
    func unpushedCount(repo: String) async -> Int? {
        guard let git else { return nil }
        let outcome = await run(git, ["-C", repo, "log", "@{u}..", "--oneline"], timeout: Self.queryTimeout)
        guard outcome.succeeded else { return nil }
        return outcome.stdout.split(whereSeparator: \.isNewline).count
    }

    enum WipResult: Codable, Equatable, Sendable {
        /// Nothing to commit; nothing was run after the status check.
        case clean
        case pushed
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// `git add -A`, commit, push, in one repo, inside one 60 s budget.
    /// The commit skips the repo's commit hooks (`--no-verify`): a linter
    /// must not veto a save made because the battery is at its floor.
    func wipCommit(repo: String, now: @Sendable () -> Date = { Date() }) async -> WipResult {
        guard let git else { return .failed("git not found") }
        let deadline = now().addingTimeInterval(Self.wipTimeout)
        func step(_ args: [String]) async -> ShellOutcome {
            let left = deadline.timeIntervalSince(now())
            guard left > 0 else { return .timedOut }
            return await run(git, ["-C", repo] + args, timeout: left)
        }
        let status = await step(["status", "--porcelain"])
        guard status.succeeded else { return .failed("status: \(status.failure ?? "failed")") }
        if status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .clean }
        let add = await step(["add", "-A"])
        guard add.succeeded else { return .failed("add: \(add.failure ?? "failed")") }
        let commit = await step(["commit", "--no-verify", "-m", Self.wipMessage])
        guard commit.succeeded else { return .failed("commit: \(commit.failure ?? "failed")") }
        let push = await step(["push"])
        guard push.succeeded else { return .failed("push: \(push.failure ?? "failed")") }
        return .pushed
    }
}
