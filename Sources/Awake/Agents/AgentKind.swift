import Foundation

/// The AI coding agents Awake recognises (PLAN.md 3.3).
enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case cursor
    case aider
    case devin
    case gemini
    case ollama
    case lmStudio = "lmstudio"
    /// A tmux pane the user marked (`@awake`, or an `awake:` title) that
    /// runs nothing Awake recognises by itself.
    case tmuxPane = "tmux"
    /// Known only from hook events: no process could be matched to them.
    case hookOnly = "hook"

    var displayName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "cursor"
        case .aider: "aider"
        case .devin: "devin"
        case .gemini: "gemini"
        case .ollama: "ollama"
        case .lmStudio: "lm-studio"
        case .tmuxPane: "tmux pane"
        case .hookOnly: "agent"
        }
    }

    /// A command-line agent a person talks to: it can wait for input and
    /// it can stall. A model server or an editor only runs or does not.
    var isConversational: Bool {
        switch self {
        case .claude, .codex, .aider, .devin, .gemini, .tmuxPane, .hookOnly: true
        case .cursor, .ollama, .lmStudio: false
        }
    }
}

/// Pure matching of a process or an app to an agent kind.
enum AgentCatalog {
    /// Executable (or script) base names, lower case.
    static let commands: [String: AgentKind] = [
        "claude": .claude,
        "codex": .codex,
        "cursor-agent": .cursor,
        "aider": .aider,
        "devin": .devin,
        "gemini": .gemini,
        "ollama": .ollama,
        "lms": .lmStudio,
    ]

    /// GUI apps by bundle id. The ids are the ones `Config.defaultAgentList`
    /// already carries for the same apps.
    static let bundleIds: [String: AgentKind] = [
        "com.todesktop.230313mzl4w4u92": .cursor,
        "ai.elementlabs.lmstudio": .lmStudio,
        "com.electron.ollama": .ollama,
    ]

    /// Interpreters and launchers whose first script argument names the
    /// program actually running (`node /opt/homebrew/bin/claude`,
    /// `python3 -m aider`).
    static let launchers: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "uv", "npx", "bunx", "env", "sh", "bash", "zsh",
    ]

    static func kind(bundleId: String?) -> AgentKind? {
        bundleId.flatMap { bundleIds[$0] }
    }

    /// `executable` is the path the kernel reports; `arguments` is argv
    /// (argv[0] first), empty when it could not be read.
    static func kind(executable: String, arguments: [String]) -> AgentKind? {
        let exe = baseName(executable)
        let argv0 = arguments.first.map(baseName) ?? ""
        let rest = Array(arguments.dropFirst())
        if let kind = commands[exe] ?? commands[argv0] { return kind }
        guard isLauncher(exe) || isLauncher(argv0) else { return nil }
        // The first argument that is not an option: the script, or the
        // module after `-m`.
        var index = 0
        while index < rest.count {
            let arg = rest[index]
            if arg == "-m", index + 1 < rest.count { return commands[rest[index + 1].lowercased()] }
            if arg.hasPrefix("-") { index += 1; continue }
            if arg.contains("="), exe == "env" || argv0 == "env" { index += 1; continue }
            return commands[scriptName(arg)]
        }
        return nil
    }

    static func baseName(_ path: String) -> String {
        (path as NSString).lastPathComponent.lowercased()
    }

    private static func isLauncher(_ name: String) -> Bool {
        if launchers.contains(name) { return true }
        // python3.12, node22
        return ["python", "node"].contains { name.hasPrefix($0) && name.dropFirst($0.count).allSatisfy { $0.isNumber || $0 == "." } }
    }

    /// `/x/bin/claude` → claude, `/x/cli.js` inside `.../claude-code/` →
    /// claude, `/x/codex.js` → codex.
    private static func scriptName(_ path: String) -> String {
        let base = baseName(path)
        let stem = (base as NSString).deletingPathExtension
        if commands[base] != nil { return base }
        if commands[stem] != nil { return stem }
        let lower = path.lowercased()
        if lower.contains("/claude-code/") || lower.contains("/@anthropic-ai/claude") { return "claude" }
        if lower.contains("/@openai/codex/") { return "codex" }
        if lower.contains("/@google/gemini-cli/") { return "gemini" }
        return base
    }
}
