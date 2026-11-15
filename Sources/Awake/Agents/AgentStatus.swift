import Foundation

/// One agent in status.json and the menu (PLAN.md 3.3; phase 3 reads it).
struct AgentStatus: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var kind: String
    var name: String
    var state: AgentState
    /// Seconds since the agent last printed or sent a hook heartbeat; nil
    /// when Awake cannot see its output.
    var lastOutputAgeSeconds: Int?
    /// Name of the git work tree the agent runs in.
    var repo: String?
    var tmuxTarget: String?
    /// The question on screen while `state` is waitingForInput.
    var waitingPrompt: String?
    /// When `state` was entered.
    var stateSince: Date
    var cpuPercent: Double?
    var residentBytes: UInt64
    var pids: [Int32]
    var cwd: String?

    init(_ record: AgentRecord, now: Date) {
        id = record.id
        kind = record.kind.rawValue
        name = record.name
        state = record.state
        lastOutputAgeSeconds = record.machine.lastOutputAge(now: now).map { Int($0) }
        repo = record.repoName
        tmuxTarget = record.tmuxTarget
        waitingPrompt = record.state == .waitingForInput ? record.machine.waitingPrompt : nil
        stateSince = record.machine.since
        cpuPercent = record.cpuPercent.map { ($0 * 10).rounded() / 10 }
        residentBytes = record.residentBytes
        pids = record.pids
        cwd = record.cwd
    }
}

/// The compact menu line and the alert texts. Pure.
enum AgentLines {
    static func mark(_ state: AgentState) -> String {
        switch state {
        case .busy, .alive: "\u{25CF}"      // ●
        case .idle: "\u{25CB}"              // ○
        case .waitingForInput: "\u{25C6}"   // ◆
        case .stalled: "\u{25A0}"           // ■
        case .exited: "\u{00D7}"            // ×
        }
    }

    /// "3s", "3m", "2h 5m".
    static func age(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let m = (s % 3600) / 60
        return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(m)m"
    }

    /// "● claude  busy  3m  repo-name"
    static func menuLine(_ agent: AgentStatus, now: Date) -> String {
        var parts = ["\(mark(agent.state)) \(agent.name)", agent.state.label, age(now.timeIntervalSince(agent.stateSince))]
        if let place = agent.repo ?? agent.tmuxTarget { parts.append(place) }
        return parts.joined(separator: "  ")
    }

    static func menuLines(_ agents: [AgentStatus], now: Date, limit: Int = 8) -> [String] {
        var lines = agents.prefix(limit).map { menuLine($0, now: now) }
        if agents.count > limit { lines.append("\u{2026} and \(agents.count - limit) more agent\(agents.count - limit == 1 ? "" : "s")") }
        return lines
    }

    static func waiting(_ agent: AgentRecord) -> (title: String, body: String) {
        let prompt = agent.machine.waitingPrompt ?? "needs your input"
        return ("Agent waiting: \(agent.name)", agent.repoName.map { "\(prompt) (\($0))" } ?? prompt)
    }

    static func stalled(_ agent: AgentRecord, minutes: Int) -> (title: String, body: String) {
        let place = agent.repoName.map { ", \($0)" } ?? ""
        return ("Agent stalled: \(agent.name)", "No output for \(minutes) min\(place).")
    }

    static func exited(_ agent: AgentRecord) -> (title: String, body: String) {
        let why = agent.machine.exitNote.map { "Session ended: \($0)" } ?? "The process is gone; exit status unknown"
        return ("Agent exited: \(agent.name)", agent.repoName.map { "\(why) (\($0))." } ?? "\(why).")
    }

    static let allDoneTitle = "All agents finished"

    static func allDone(names: [String], minutes: Int) -> String {
        let list = names.isEmpty ? "" : ": \(names.joined(separator: ", "))"
        return "Every tracked agent has been idle or gone for \(minutes) min\(list)."
    }
}
