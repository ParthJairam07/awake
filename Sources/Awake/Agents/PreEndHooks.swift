import Foundation

/// What a pre-end save set out to do and what came of it. Written to
/// pre-end.json before anything runs and after each repo, so a crash in
/// the middle leaves a record of what was started.
struct PreEndJournal: Codable, Equatable, Sendable {
    var reason: String
    var startedAt: Date
    var wipCommit: Bool
    /// Repos the save will visit, in order.
    var repos: [String]
    /// The repo being worked on right now.
    var running: String?
    var results: [String: AgentGit.WipResult] = [:]
    var finishedAt: Date?

    init(reason: String, startedAt: Date, wipCommit: Bool, repos: [String]) {
        self.reason = reason
        self.startedAt = startedAt
        self.wipCommit = wipCommit
        self.repos = repos
    }

    var pushed: [String] { repos.filter { results[$0] == .pushed } }
    var failed: [String] { repos.filter { results[$0]?.isFailure == true } }
}

/// Phase 2, opt-in: what runs before a battery, heat or planned end.
/// Journal the intent, post "Session ending", then (with
/// `Config.wipCommitOnEnd`) commit and push each agent repo. Never sudo,
/// never force.
@MainActor
final class PreEndRunner {
    static let title = "Session ending"
    static let interruptedTitle = "Pre-end save interrupted"

    private let store: Store
    private let paths: Paths
    private let notifier: any Notifying
    private let git: AgentGit
    private let clock: @Sendable () -> Date
    private let config: @MainActor () -> Config
    private let repos: @MainActor () -> [String]
    private var inFlight: Task<Void, Never>?

    /// Results for the session report.
    var onReport: (@MainActor ((inout SessionReport) -> Void) -> Void)?

    init(
        paths: Paths,
        notifier: any Notifying,
        git: AgentGit = AgentGit(),
        clock: @escaping @Sendable () -> Date = { Date() },
        config: @escaping @MainActor () -> Config,
        repos: @escaping @MainActor () -> [String]
    ) {
        self.paths = paths
        self.store = Store(paths: paths)
        self.notifier = notifier
        self.git = git
        self.clock = clock
        self.config = config
        self.repos = repos
    }

    static func body(reason: EndReason, repos: Int, wipCommit: Bool) -> String {
        let why = SessionManager.reasonText(reason.rawValue)
        guard wipCommit, repos > 0 else { return "Ending now: \(why)." }
        return "Ending now: \(why). Saving work in \(repos) repo\(repos == 1 ? "" : "s") first (commit and push, up to \(Int(AgentGit.wipTimeout)) s each)."
    }

    /// Runs the pre-end work for `reason`. A second call while one runs
    /// waits for that one instead of saving twice.
    func run(reason: EndReason) async {
        guard config().preEndHooks else { return }
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { @MainActor in await self.perform(reason: reason) }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func perform(reason: EndReason) async {
        let wip = config().wipCommitOnEnd
        let targets = wip ? repos() : []
        var journal = PreEndJournal(reason: reason.rawValue, startedAt: clock(), wipCommit: wip, repos: targets)
        // Journal first: with no record on disk, nothing is run.
        var journaled = true
        do {
            try store.write(journal, to: paths.preEndFile)
        } catch {
            journaled = false
            Log.error("pre-end.json could not be written: \(error.localizedDescription); nothing is committed or pushed")
        }
        Log.info("pre-end (\(reason.rawValue)): \(targets.count) repo(s), wip commit \(wip ? "on" : "off")")
        notifier.post(title: Self.title, body: Self.body(reason: reason, repos: journaled ? targets.count : 0, wipCommit: wip && journaled))
        guard journaled else { return }

        for repo in targets {
            journal.running = repo
            do {
                try store.write(journal, to: paths.preEndFile)
            } catch {
                Log.error("pre-end.json could not record the save of \(repo): \(error.localizedDescription); that repo is skipped")
                journal.running = nil
                journal.results[repo] = .failed("not journaled")
                continue
            }
            let result = await git.wipCommit(repo: repo)
            Log.info("pre-end wip save in \(repo): \(result)")
            journal.results[repo] = result
            journal.running = nil
            try? store.write(journal, to: paths.preEndFile)
        }
        journal.finishedAt = clock()
        do {
            try store.write(journal, to: paths.preEndFile)
        } catch {
            Log.error("pre-end.json could not record the end of the save: \(error.localizedDescription)")
        }
        let pushed = journal.pushed, failed = journal.failed
        if !pushed.isEmpty || !failed.isEmpty {
            onReport? { report in
                report.wipPushed = pushed
                report.wipFailed = failed
            }
        }
    }

    /// At session start: a journal without `finishedAt` is a save a crash
    /// or a forced restart cut short. Say so once, then mark it settled.
    func settleLeftover() {
        guard var left = (try? store.read(PreEndJournal.self, from: paths.preEndFile)) ?? nil, left.finishedAt == nil else { return }
        let where_ = left.running.map { " while saving \(GitRepoLocator.name(of: $0))" } ?? ""
        let pending = left.repos.filter { left.results[$0] == nil }.map(GitRepoLocator.name)
        let rest = pending.isEmpty ? "" : " Not saved: \(pending.joined(separator: ", "))."
        notifier.post(title: Self.interruptedTitle, body: "The save before the last session end was cut short\(where_).\(rest) Check those repos by hand.")
        left.finishedAt = clock()
        left.running = nil
        try? store.write(left, to: paths.preEndFile)
    }
}
