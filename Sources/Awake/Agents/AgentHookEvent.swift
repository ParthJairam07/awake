import Foundation

/// One event an agent's hook posted to `/hooks/<kind>`.
struct AgentHookEvent: Sendable, Equatable {
    /// The path component: `claude`, `codex`, or whatever the hook's
    /// author chose. Lower case letters, digits, `-` and `_` only.
    let kind: String
    let action: AgentHookAction
    /// The hook's parent process, when the script sent it.
    var pid: Int32?
    /// The agent's own session or thread id.
    var sessionId: String?
    var cwd: String?
    var transcriptPath: String?

    init(kind: String, action: AgentHookAction, pid: Int32? = nil, sessionId: String? = nil, cwd: String? = nil, transcriptPath: String? = nil) {
        self.kind = kind
        self.action = action
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
    }
}
