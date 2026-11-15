import Foundation

/// Typing into a tmux pane, for the phone's Nudge and Answer. Apart from
/// `TmuxReading`, which stays read-only. Each call returns nil when the
/// keys were sent, else why they were not.
protocol TmuxTyping: Sendable {
    /// `send-keys -t <pane> Enter`.
    func enter(paneId: String) async -> String?
    /// `send-keys -t <pane> -l <text>`, then Enter.
    func type(paneId: String, text: String) async -> String?
}

/// Live typing over the tmux binary. Before every send the pane's own
/// state is read, as `TmuxNudge` does: a dead pane, one in copy mode or
/// one with input off gets nothing.
struct LiveTmuxTyper: TmuxTyping {
    let socketName: String?
    let command: CancellableCommand

    init(socketName: String? = nil, command: CancellableCommand = CancellableCommand()) {
        self.socketName = socketName
        self.command = command
    }

    func enter(paneId: String) async -> String? {
        await send(paneId: paneId, keys: [["Enter"]])
    }

    func type(paneId: String, text: String) async -> String? {
        // `--` so an answer that starts with a dash is text, not an option.
        await send(paneId: paneId, keys: [["-l", "--", text], ["Enter"]])
    }

    private func send(paneId: String, keys: [[String]]) async -> String? {
        guard let tmux = Shell.locate(TmuxNudge.candidates) else { return "tmux was not found" }
        let server = socketName.map { ["-L", $0] } ?? []
        guard let state = try? await command.run(tmux, server + ["display-message", "-p", "-t", paneId, "-F", TmuxNudge.paneStateFormat], timeout: 5), state.succeeded else {
            return "tmux could not read pane \(paneId)"
        }
        switch TmuxNudge.check(paneState: state.stdout) {
        case let .skip(reason):
            return reason
        case let .ready(id):
            guard id == paneId else { return "pane \(paneId) is gone" }
        }
        for arguments in keys {
            guard let r = try? await command.run(tmux, server + ["send-keys", "-t", paneId] + arguments, timeout: 5), r.succeeded else {
                return "tmux send-keys to \(paneId) failed"
            }
        }
        return nil
    }
}

/// What the phone may do to an agent (phase 3's `AgentActing`), built from
/// the phase-2 pieces: the tracker's records, tmux, and the priority
/// pause's journaled stops. Nothing here runs sudo, and nothing is sent to
/// a process whose identity no longer matches the record.
@MainActor
final class AgentActions: AgentActing {
    static let noSuchAgent = "no such agent"
    static let notInMarkedPane = "agent is not in a marked tmux pane"
    static let noSession = "no session is running"
    static let maxAnswerLength = 500

    private weak var manager: SessionManager?
    private weak var pauser: AgentPauser?
    private let tmux: any TmuxReading
    private let typer: any TmuxTyping
    private let control: any ProcessSignaling
    /// The tracker's records; nil once the tracker is gone.
    private let records: @MainActor () -> [AgentRecord]?

    init(
        manager: SessionManager,
        pauser: AgentPauser,
        tmux: any TmuxReading,
        typer: any TmuxTyping,
        control: any ProcessSignaling,
        records: @escaping @MainActor () -> [AgentRecord]?
    ) {
        self.manager = manager
        self.pauser = pauser
        self.tmux = tmux
        self.typer = typer
        self.control = control
        self.records = records
    }

    var available: Bool {
        manager?.isActive == true && pauser != nil && records() != nil
    }

    /// The record for `id`, or why there is none.
    private func agent(_ id: String) -> Result<AgentRecord, PhoneActionFailure> {
        guard available, let all = records() else { return .failure(.init(Self.noSession)) }
        guard let record = all.first(where: { $0.id == id }) else { return .failure(.init(Self.noSuchAgent)) }
        return .success(record)
    }

    /// The agent's pane, only when tmux says right now that it is marked.
    /// The record keeps the pane of any agent that runs in tmux; keys go
    /// only where the user asked for them with the mark.
    private func markedPane(of agent: AgentRecord) async -> String? {
        guard let paneId = agent.tmuxPaneId else { return nil }
        let panes = await tmux.panes()
        guard panes.contains(where: { $0.id == paneId && $0.marked && !$0.dead }) else { return nil }
        return paneId
    }

    func nudge(id: String) async -> PhoneActionResult {
        let agent: AgentRecord
        switch self.agent(id) {
        case let .failure(why): return .failed(why.message)
        case let .success(found): agent = found
        }
        guard let paneId = await markedPane(of: agent) else { return .failed(Self.notInMarkedPane) }
        if let why = await typer.enter(paneId: paneId) {
            Log.error("phone: nudge of \(agent.label) not sent: \(why)")
            return .failed(why)
        }
        Log.info("phone: nudged \(agent.label) (Enter to pane \(paneId))")
        return .done("Sent Enter to \(agent.label).")
    }

    /// Why `text` cannot be typed, or nil.
    static func refusal(ofAnswer text: String) -> String? {
        if text.isEmpty { return "the answer is empty" }
        if text.count > maxAnswerLength { return "the answer is longer than \(maxAnswerLength) characters" }
        // One line, and nothing a terminal would act on.
        if text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            return "the answer must be one line"
        }
        return nil
    }

    func answer(id: String, text: String) async -> PhoneActionResult {
        let agent: AgentRecord
        switch self.agent(id) {
        case let .failure(why): return .failed(why.message)
        case let .success(found): agent = found
        }
        if let why = Self.refusal(ofAnswer: text) { return .failed(why) }
        guard let paneId = await markedPane(of: agent) else { return .failed(Self.notInMarkedPane) }
        if let why = await typer.type(paneId: paneId, text: text) {
            Log.error("phone: answer to \(agent.label) not sent: \(why)")
            return .failed(why)
        }
        // The answer may be a password: its length is logged, not its text.
        Log.info("phone: answered \(agent.label) (\(text.count) characters and Enter to pane \(paneId))")
        return .done("Sent the answer to \(agent.label).")
    }

    func pause(id: String) async -> PhoneActionResult {
        let agent: AgentRecord
        switch self.agent(id) {
        case let .failure(why): return .failed(why.message)
        case let .success(found): agent = found
        }
        guard let pauser else { return .failed(Self.noSession) }
        if pauser.isPaused(id) { return .done("\(agent.label) is already paused.") }
        if let why = PausePlanner.protection(agent) { return .failed("\(agent.label) cannot be paused: \(why)") }
        if let why = await pauser.hold(agent) { return .failed(why) }
        return .done("Paused \(agent.label). It resumes when you resume it or the session ends.")
    }

    func resume(id: String) async -> PhoneActionResult {
        let agent: AgentRecord
        switch self.agent(id) {
        case let .failure(why): return .failed(why.message)
        case let .success(found): agent = found
        }
        guard let pauser else { return .failed(Self.noSession) }
        guard pauser.isPaused(id) else { return .failed("\(agent.label) is not paused by Awake") }
        if let why = await pauser.release(id: id) { return .failed(why) }
        return .done("Resumed \(agent.label).")
    }

    func stop(id: String) async -> PhoneActionResult {
        let agent: AgentRecord
        switch self.agent(id) {
        case let .failure(why): return .failed(why.message)
        case let .success(found): agent = found
        }
        guard let root = agent.rootPid, let identity = agent.identities[root] ?? agent.identity else {
            return .failed("\(agent.label) is known only from hooks; there is no process to stop")
        }
        if agent.state == .exited { return .failed("\(agent.label) has exited") }
        // A stopped process acts on SIGTERM only once it runs again.
        if let pauser, pauser.isPaused(id), let why = await pauser.release(id: id) {
            return .failed("\(agent.label) is paused and could not be resumed to stop it: \(why)")
        }
        switch control.terminate(FrozenProcess(pid: root, identity: identity)) {
        case .sent:
            Log.info("phone: SIGTERM sent to \(agent.label) (pid \(root))")
            return .done("Asked \(agent.label) to stop (SIGTERM to pid \(root)).")
        case .notTheSameProcess:
            Log.info("phone: stop of \(agent.label) refused: pid \(root) is gone or is another process now")
            return .failed("\(agent.label) is gone or pid \(root) is another process now; nothing was sent")
        case .failed:
            return .failed("pid \(root) could not be checked or signalled; nothing more was done")
        }
    }
}

/// Why an agent action stopped before doing anything.
struct PhoneActionFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
