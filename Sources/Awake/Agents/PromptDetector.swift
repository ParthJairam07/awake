import Foundation

/// What the last lines of a pane say the program in it is doing. Pure text
/// rules; nothing here reads a pane.
enum PromptDetector {
    struct Match: Equatable, Sendable {
        /// The line that asks, trimmed, for the alert.
        let excerpt: String
        /// A password prompt from sudo: the agent must never be paused
        /// while it is up (the never-SIGKILL-sudo rule's sibling).
        let isSudo: Bool
    }

    /// How many non-empty lines from the bottom are read. A question
    /// further up has scrolled out of what the user would answer.
    static let window = 10
    static let excerptLimit = 140

    /// Phrases that mean a person has to answer, lower case.
    static let questionPhrases: [String] = [
        "(y/n)", "[y/n]", "(yes/no", "[yes/no", "(y/n/", "[y/n/",
        "allow?", "allow command", "allow this", "do you want to", "would you like to",
        "press enter", "press return", "press any key", "are you sure",
        "requires approval", "approve this", "waiting for approval", "needs your permission", "needs your approval",
        "enter passphrase", "continue? ", "proceed? ", "overwrite? ",
    ]

    static let workingPhrases: [String] = ["esc to interrupt", "ctrl+c to interrupt", "esc to cancel", "ctrl-c to interrupt"]

    /// The last `window` non-empty lines, box-drawing and padding removed,
    /// top to bottom.
    static func tail(of text: String) -> [String] {
        let lines = text.split(whereSeparator: \.isNewline).map { strip(String($0)) }.filter { !$0.isEmpty }
        return Array(lines.suffix(window))
    }

    /// A question the program is asking now, or nil. Reads bottom up and
    /// stops at an input prompt: a question above the program's own input
    /// line has been answered already.
    static func question(in lines: [String]) -> Match? {
        var menuLine: String?
        for line in lines.reversed() {
            let lower = line.lowercased()
            if isSudoPrompt(lower) { return Match(excerpt: excerpt(line), isSudo: true) }
            if questionPhrases.contains(where: lower.contains) { return Match(excerpt: excerpt(line), isSudo: false) }
            if isMenuChoice(line) {
                if isSelectedChoice(line) { menuLine = menuLine ?? line }
                continue
            }
            if isInputPrompt(line) { break }
        }
        // A numbered menu with the cursor on a choice and no question
        // phrase near it: the selected line stands in for the question.
        return menuLine.map { Match(excerpt: excerpt($0), isSudo: false) }
    }

    /// The program shows its own idle input line (or a shell prompt) and
    /// nothing says it is working.
    static func isIdleAtPrompt(_ lines: [String]) -> Bool {
        guard !isWorking(lines), let last = lines.last else { return false }
        if lines.suffix(4).contains(where: isInputPrompt) { return true }
        return isShellPrompt(last)
    }

    static func isWorking(_ lines: [String]) -> Bool {
        lines.contains { line in
            let lower = line.lowercased()
            return workingPhrases.contains(where: lower.contains)
        }
    }

    static func isSudoPrompt(_ lower: String) -> Bool {
        if lower.contains("[sudo] password") { return true }
        if lower.hasPrefix("password:") || lower.hasSuffix("password:") { return true }
        return lower.hasPrefix("password for ") && lower.hasSuffix(":")
    }

    private static let promptMarks: [Character] = ["\u{276F}", "\u{203A}", ">"]

    /// `❯ 1. Yes`, `> 2. No`, `  3. Cancel`: one line of a numbered menu.
    static func isMenuChoice(_ line: String) -> Bool {
        var rest = Substring(line)
        if let first = rest.first, promptMarks.contains(first) { rest = rest.dropFirst().drop(while: { $0 == " " }) }
        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 2 else { return false }
        let after = rest.dropFirst(digits.count)
        return (after.hasPrefix(". ") || after.hasPrefix(") ")) && after.count > 2
    }

    static func isSelectedChoice(_ line: String) -> Bool {
        guard let first = line.first, promptMarks.contains(first) else { return false }
        return isMenuChoice(line)
    }

    /// The agent's own input line: a prompt mark alone or before text that
    /// is not a menu choice.
    static func isInputPrompt(_ line: String) -> Bool {
        guard let first = line.first, promptMarks.contains(first) else { return false }
        let rest = line.dropFirst()
        guard rest.isEmpty || rest.first == " " else { return false }
        return !isMenuChoice(line)
    }

    /// A shell waiting for a command: the line ends with a prompt character.
    static func isShellPrompt(_ line: String) -> Bool {
        guard let last = line.last else { return false }
        return ["$", "%", "#", "\u{276F}"].contains(last)
    }

    /// Drops the frame a TUI draws around its text and the padding.
    static func strip(_ line: String) -> String {
        let frame = CharacterSet(charactersIn: "\u{2500}"..."\u{257F}").union(.whitespaces)
        return line.trimmingCharacters(in: frame)
    }

    static func excerpt(_ line: String) -> String {
        let collapsed = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return collapsed.count <= excerptLimit ? collapsed : String(collapsed.prefix(excerptLimit - 1)) + "\u{2026}"
    }

    /// FNV-1a over the pane text: the same text gives the same number in
    /// every process, unlike `Hasher`.
    static func hash(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01b3
        }
        return h
    }
}
