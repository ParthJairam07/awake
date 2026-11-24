/// What a pause does to an agent that was started from an interactive
/// shell, in one sentence. A pause is a SIGSTOP; the shell that started the
/// program sees it stop, prints "suspended" and takes the terminal back,
/// and a SIGCONT resumes it as a background job. Awake does not change
/// that (see docs/agents.md), so everywhere a pause is offered says so:
/// Settings > Agents under the priority pause, and the phone's Pause
/// confirmation (app.js holds the same sentence; a test keeps the two and
/// the docs in step).
enum AgentPauseCopy {
    static let shellJob = "An agent started from a shell prompt becomes a background job of that shell when it is paused: the shell takes the terminal back, and after the resume an agent that reads the terminal stays stopped until you type fg in that terminal."
}
