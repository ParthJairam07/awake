import Foundation

/// What an agent is doing, as far as Awake can tell from outside.
enum AgentState: String, Codable, Sendable, CaseIterable {
    /// Just found; not enough samples to say more.
    case alive
    /// Using CPU, printing, or sending hook heartbeats.
    case busy
    /// Running and quiet.
    case idle
    /// Asking a person something.
    case waitingForInput
    /// In the middle of something and silent for too long.
    case stalled
    /// The process is gone (or its hook said the session ended).
    case exited

    var label: String {
        switch self {
        case .alive: "alive"
        case .busy: "busy"
        case .idle: "idle"
        case .waitingForInput: "waiting"
        case .stalled: "stalled"
        case .exited: "exited"
        }
    }

    /// Finished as far as "all agents finished" goes.
    var isSettled: Bool { self == .idle || self == .exited }
}

/// One reading of an agent, taken at a poll.
struct AgentSample: Sendable, Equatable {
    var at: Date
    /// The process (by identity, not pid) is still there.
    var present: Bool = true
    /// CPU over the interval since the last poll, percent of one core; nil
    /// on the first poll and for an agent without a process.
    var cpuPercent: Double?
    /// The pane's visible text, when the agent runs in a tmux pane.
    var paneText: String?
    /// Modification time of the agent's log or transcript, when known.
    var logModifiedAt: Date?

    init(at: Date, present: Bool = true, cpuPercent: Double? = nil, paneText: String? = nil, logModifiedAt: Date? = nil) {
        self.at = at
        self.present = present
        self.cpuPercent = cpuPercent
        self.paneText = paneText
        self.logModifiedAt = logModifiedAt
    }
}

/// What a hook event means for the state, once parsed (`AgentHookEvent`).
enum AgentHookAction: Sendable, Equatable {
    /// The agent asks for input or permission.
    case waiting(String?)
    /// The agent finished its turn and is at rest.
    case finished
    /// The agent is doing something (a tool call, a new prompt).
    case heartbeat
    /// The agent's session ended.
    case ended(String?)
}

struct AgentTransition: Sendable, Equatable {
    let from: AgentState
    let to: AgentState
}

/// The per-agent state machine. Pure: fed samples and hook actions, it
/// answers with the transition they caused, if any. No clock, no I/O.
struct AgentStateMachine: Sendable, Equatable {
    struct Thresholds: Sendable, Equatable {
        /// CPU at or above this is work, not a blinking cursor.
        var busyCPUPercent: Double = 3
        /// Silence after which a working agent counts as stalled.
        var stallAfter: TimeInterval = 600
        /// How long one hook heartbeat keeps the agent busy.
        var heartbeatWindow: TimeInterval = 60
        /// False for servers and editors: they never wait or stall.
        var conversational = true

        init(busyCPUPercent: Double = 3, stallAfter: TimeInterval = 600, heartbeatWindow: TimeInterval = 60, conversational: Bool = true) {
            self.busyCPUPercent = busyCPUPercent
            self.stallAfter = stallAfter
            self.heartbeatWindow = heartbeatWindow
            self.conversational = conversational
        }
    }

    private(set) var state: AgentState = .alive
    /// When `state` was entered.
    private(set) var since: Date
    /// The last time the pane text or the log changed; nil until either
    /// has been read once.
    private(set) var lastOutputChange: Date?
    private(set) var lastHeartbeat: Date?
    /// The question on screen, or the hook's message, while waiting.
    private(set) var waitingPrompt: String?
    /// The prompt on screen is sudo's password prompt.
    private(set) var waitingOnSudo = false
    /// What a hook said when the session ended.
    private(set) var exitNote: String?

    /// A hook said the turn is over; cleared by the next sign of work.
    private var finished = false
    private var hookWaiting: String?
    private var lastHash: UInt64?
    private var lastLogModified: Date?
    private var samples = 0
    private var hasPane = false

    init(firstSeen: Date) {
        since = firstSeen
    }

    /// Seconds since the agent last printed or sent a heartbeat; nil when
    /// Awake has no way to see its output.
    func lastOutputAge(now: Date) -> TimeInterval? {
        guard let last = lastActivity else { return nil }
        return max(0, now.timeIntervalSince(last))
    }

    private var lastActivity: Date? {
        switch (lastOutputChange, lastHeartbeat) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        default: nil
        }
    }

    @discardableResult
    mutating func ingest(_ sample: AgentSample, thresholds: Thresholds = Thresholds()) -> AgentTransition? {
        guard state != .exited else { return nil }
        guard sample.present else { return move(to: .exited, at: sample.at) }
        samples += 1

        var changed = false
        var lines: [String] = []
        if let text = sample.paneText {
            hasPane = true
            let hash = PromptDetector.hash(text)
            if let lastHash, lastHash != hash { changed = true }
            if lastHash == nil || changed { lastOutputChange = sample.at }
            lastHash = hash
            lines = PromptDetector.tail(of: text)
        }
        if let modified = sample.logModifiedAt {
            if let lastLogModified, modified > lastLogModified { changed = true }
            if lastLogModified == nil || changed {
                lastOutputChange = max(lastOutputChange ?? modified, min(modified, sample.at))
            }
            lastLogModified = max(lastLogModified ?? modified, modified)
        }
        if changed {
            // New output: whatever a hook said before is about a moment
            // that has passed.
            finished = false
            hookWaiting = nil
        }

        // Waiting: a hook said so, or a question has sat unchanged on the
        // pane since the last poll.
        if thresholds.conversational {
            if let hookWaiting {
                waitingOnSudo = false
                waitingPrompt = hookWaiting
                return move(to: .waitingForInput, at: sample.at)
            }
            if sample.paneText != nil, !changed, samples > 1, let match = PromptDetector.question(in: lines) {
                waitingPrompt = match.excerpt
                waitingOnSudo = match.isSudo
                return move(to: .waitingForInput, at: sample.at)
            }
        }
        waitingPrompt = nil
        waitingOnSudo = false

        let heartbeatFresh = lastHeartbeat.map { sample.at.timeIntervalSince($0) < thresholds.heartbeatWindow } ?? false
        let cpuBusy = (sample.cpuPercent ?? 0) >= thresholds.busyCPUPercent
        if changed || cpuBusy || heartbeatFresh {
            return move(to: .busy, at: sample.at)
        }

        // Stalled needs something whose silence can be measured (a pane or
        // hook heartbeats), no sign that the turn is over, and the silence.
        let observable = hasPane || lastHeartbeat != nil
        let atRest = finished || (sample.paneText != nil && PromptDetector.isIdleAtPrompt(lines))
        if thresholds.conversational, observable, !atRest, let last = lastActivity,
           sample.at.timeIntervalSince(last) >= thresholds.stallAfter {
            return move(to: .stalled, at: sample.at)
        }
        // A stalled agent stays stalled until it shows work again.
        if state == .stalled, !atRest { return nil }
        // One sample cannot tell idle from busy: CPU needs an interval.
        if samples < 2, state == .alive { return nil }
        return move(to: .idle, at: sample.at)
    }

    /// `hasProcess`: the agent has a process the polls watch, so only the
    /// process going away makes it exited.
    @discardableResult
    mutating func ingest(hook action: AgentHookAction, at: Date, hasProcess: Bool) -> AgentTransition? {
        guard state != .exited else { return nil }
        switch action {
        case let .waiting(message):
            let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            hookWaiting = text.isEmpty ? "needs your input" : PromptDetector.excerpt(text)
            finished = false
            waitingPrompt = hookWaiting
            waitingOnSudo = false
            return move(to: .waitingForInput, at: at)
        case .finished:
            finished = true
            hookWaiting = nil
            waitingPrompt = nil
            waitingOnSudo = false
            return move(to: .idle, at: at)
        case .heartbeat:
            lastHeartbeat = at
            finished = false
            hookWaiting = nil
            waitingPrompt = nil
            waitingOnSudo = false
            return move(to: .busy, at: at)
        case let .ended(note):
            exitNote = note
            finished = true
            hookWaiting = nil
            waitingPrompt = nil
            waitingOnSudo = false
            return move(to: hasProcess ? .idle : .exited, at: at)
        }
    }

    private mutating func move(to new: AgentState, at: Date) -> AgentTransition? {
        guard new != state else { return nil }
        let old = state
        state = new
        since = at
        return AgentTransition(from: old, to: new)
    }
}
