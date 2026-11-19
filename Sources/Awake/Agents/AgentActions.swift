import AwakeLeaseKit
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

/// The process group a process is in and the one that holds its terminal.
struct ProcessGroups: Sendable, Equatable {
    let group: Int32
    let foreground: Int32
}

/// Which of some processes is in front of its terminal. Read-only.
protocol PaneFrontReading: Sendable {
    /// The groups of each of `pids` that is alive; nil when they could not
    /// be read.
    func groups(of pids: [Int32]) async -> [Int32: ProcessGroups]?
}

/// `ps -o pid=,pgid=,tpgid= -p <pids>`.
struct LivePaneFront: PaneFrontReading {
    static let ps = "/bin/ps"

    func groups(of pids: [Int32]) async -> [Int32: ProcessGroups]? {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        // ps exits 1 when none of the pids is alive: that is an answer.
        guard let r = try? await Shell.run(Self.ps, ["-o", "pid=,pgid=,tpgid=", "-p", list]) else { return nil }
        guard r.status == 0 || (r.status == 1 && r.stdout.allSatisfy(\.isWhitespace)) else { return nil }
        return PaneFront.parse(r.stdout)
    }
}

/// Who a marked pane's keys would reach, and which process a Stop is for.
enum PaneFront {
    static func parse(_ ps: String) -> [Int32: ProcessGroups] {
        var out: [Int32: ProcessGroups] = [:]
        for line in ps.split(whereSeparator: \.isNewline) {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Int32($0) }
            guard f.count == 3 else { continue }
            out[f[0]] = ProcessGroups(group: f[1], foreground: f[2])
        }
        return out
    }

    private static func isShell(_ command: String) -> Bool {
        LeaseTmux.shells.contains(command.hasPrefix("-") ? String(command.dropFirst()) : command)
    }

    /// True when the pane's own shell holds the terminal while the agent's
    /// processes are a job of that shell that is stopped or in the
    /// background. A SIGSTOP does that to a program started from an
    /// interactive shell: the shell reports it suspended and takes the
    /// terminal back, and after SIGCONT the program is a background job. Keys
    /// sent to the pane are then read by the shell, which runs them as a
    /// command.
    static func shellInFront(pane: TmuxPane, agentPids: [Int32], groups: [Int32: ProcessGroups]) -> Bool {
        guard let root = groups[pane.pid], root.foreground == root.group, isShell(pane.currentCommand) else { return false }
        return agentPids.contains { pid in
            guard pid != pane.pid, let g = groups[pid] else { return false }
            return g.group != root.group
        }
    }

    /// The process a Stop of a pane-rooted agent is for. The pane's first
    /// process is usually an interactive shell, which ignores SIGTERM: the
    /// agent is the job running in it. That is the leader of the group in
    /// front of the pane when the agent tracks it, or the shell's only job
    /// when the shell itself is in front; nil means the pane's first
    /// process, as for any other agent.
    static func jobToStop(pane: TmuxPane, agentPids: [Int32], groups: [Int32: ProcessGroups]) -> Int32? {
        guard let root = groups[pane.pid] else { return nil }
        if root.foreground != root.group {
            return agentPids.contains(root.foreground) && root.foreground != pane.pid ? root.foreground : nil
        }
        guard isShell(pane.currentCommand) else { return nil }
        let leaders = agentPids.filter { pid in
            guard pid != pane.pid, let g = groups[pid] else { return false }
            return g.group == pid && g.group != root.group
        }
        return leaders.count == 1 ? leaders[0] : nil
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
    static let frontUnreadable = "could not check which program is in front of the pane; nothing was typed"
    static func notInFront(_ label: String) -> String {
        "\(label) is not in front of its pane: the pane's shell is, and it would run what is typed. Bring the agent back with fg in that pane; nothing was typed"
    }
    static let maxAnswerLength = 500

    private weak var manager: SessionManager?
    private weak var pauser: AgentPauser?
    private let tmux: any TmuxReading
    private let typer: any TmuxTyping
    private let control: any ProcessSignaling
    private let front: any PaneFrontReading
    /// The tracker's records; nil once the tracker is gone.
    private let records: @MainActor () -> [AgentRecord]?

    init(
        manager: SessionManager,
        pauser: AgentPauser,
        tmux: any TmuxReading,
        typer: any TmuxTyping,
        control: any ProcessSignaling,
        front: any PaneFrontReading = LivePaneFront(),
        records: @escaping @MainActor () -> [AgentRecord]?
    ) {
        self.front = front
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
    private func markedPane(of agent: AgentRecord) async -> TmuxPane? {
        guard let paneId = agent.tmuxPaneId else { return nil }
        let panes = await tmux.panes()
        return panes.first { $0.id == paneId && $0.marked && !$0.dead }
    }

    /// Why keys must not go to the agent's pane right now, or nil.
    private func refusalToType(to agent: AgentRecord, in pane: TmuxPane) async -> String? {
        guard let groups = await front.groups(of: [pane.pid] + agent.pids.filter { $0 != pane.pid }) else {
            return Self.frontUnreadable
        }
        return PaneFront.shellInFront(pane: pane, agentPids: agent.pids, groups: groups) ? Self.notInFront(agent.label) : nil
    }

    func nudge(id: String) async -> PhoneActionResult {
        let agent: AgentRecord
        switch self.agent(id) {
        case let .failure(why): return .failed(why.message)
        case let .success(found): agent = found
        }
        guard let pane = await markedPane(of: agent) else { return .failed(Self.notInMarkedPane) }
        let paneId = pane.id
        if let why = await refusalToType(to: agent, in: pane) {
            Log.error("phone: nudge of \(agent.label) not sent: \(why)")
            return .failed(why)
        }
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
        guard let pane = await markedPane(of: agent) else { return .failed(Self.notInMarkedPane) }
        let paneId = pane.id
        if let why = await refusalToType(to: agent, in: pane) {
            Log.error("phone: answer to \(agent.label) not sent: \(why)")
            return .failed(why)
        }
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
        guard let first = agent.rootPid, let firstIdentity = agent.identities[first] ?? agent.identity else {
            return .failed("\(agent.label) is known only from hooks; there is no process to stop")
        }
        if agent.state == .exited { return .failed("\(agent.label) has exited") }
        // A stopped process acts on SIGTERM only once it runs again.
        if let pauser, pauser.isPaused(id), let why = await pauser.release(id: id) {
            return .failed("\(agent.label) is paused and could not be resumed to stop it: \(why)")
        }
        // A marked pane's first process is usually its shell; the agent is
        // the job running in it.
        var root = first
        var identity = firstIdentity
        if let paneId = agent.tmuxPaneId,
           let pane = await tmux.panes().first(where: { $0.id == paneId && !$0.dead }), pane.pid == first,
           let groups = await front.groups(of: agent.pids),
           let job = PaneFront.jobToStop(pane: pane, agentPids: agent.pids, groups: groups),
           let jobIdentity = agent.identities[job] {
            root = job
            identity = jobIdentity
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
