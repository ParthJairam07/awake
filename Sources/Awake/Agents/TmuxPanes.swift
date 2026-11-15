import Foundation

/// One tmux pane as `list-panes -a` reports it.
struct TmuxPane: Sendable, Equatable {
    /// `%N`, unique in the server for the pane's life.
    let id: String
    /// `session:window.pane`, what a person types as a target.
    let target: String
    /// The pane's first process (usually a shell).
    let pid: Int32
    /// The pane carries the `@awake` option (set to anything but 0, off,
    /// false or no) or a title that starts with `awake:`.
    let marked: Bool
    let title: String
    let currentCommand: String
    let currentPath: String
    let dead: Bool

    init(id: String, target: String, pid: Int32, marked: Bool = false, title: String = "", currentCommand: String = "", currentPath: String = "", dead: Bool = false) {
        self.id = id
        self.target = target
        self.pid = pid
        self.marked = marked
        self.title = title
        self.currentCommand = currentCommand
        self.currentPath = currentPath
        self.dead = dead
    }
}

/// Read-only tmux access for the agent registry. Nothing here sends keys.
protocol TmuxReading: Sendable {
    func panes() async -> [TmuxPane]
    /// The visible text of a pane, nil when it could not be read.
    func capture(paneId: String) async -> String?
}

enum TmuxPaneList {
    static let markOption = "@awake"
    static let titlePrefix = "awake:"
    /// tmux prints control characters in `-F` output as `_`, so the fields
    /// are split on a printable run no path is likely to hold.
    static let separator = "|:|"
    /// Title last: it is the one field a program can put anything into.
    static let format = [
        "#{pane_id}", "#{session_name}:#{window_index}.#{pane_index}", "#{pane_pid}", "#{pane_dead}",
        "#{\(markOption)}", "#{pane_current_command}", "#{pane_current_path}", "#{pane_title}",
    ].joined(separator: separator)

    /// The command the user runs in a pane to mark it; shown in Settings.
    static let markCommand = "tmux set-option -p \(markOption) 1"

    static func isMarkValue(_ value: String) -> Bool {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        return !v.isEmpty && !["0", "off", "false", "no"].contains(v)
    }

    static func parse(_ output: String) -> [TmuxPane] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = split(String(line))
            guard fields.count == 8, fields[0].hasPrefix("%"), let pid = Int32(fields[2]), pid > 0 else { return nil }
            let title = fields[7]
            let marked = isMarkValue(fields[4]) || title.lowercased().hasPrefix(titlePrefix)
            return TmuxPane(id: fields[0], target: fields[1], pid: pid, marked: marked, title: title, currentCommand: fields[5], currentPath: fields[6], dead: fields[3] == "1")
        }
    }

    /// At most eight fields: what follows the seventh separator is the title.
    static func split(_ line: String) -> [String] {
        var fields: [String] = []
        var rest = Substring(line)
        while fields.count < 7, let range = rest.range(of: separator) {
            fields.append(String(rest[..<range.lowerBound]))
            rest = rest[range.upperBound...]
        }
        fields.append(String(rest))
        return fields
    }

    /// The name a marked pane goes by: the title after `awake:`, else the
    /// command it runs.
    static func name(of pane: TmuxPane) -> String {
        if pane.title.lowercased().hasPrefix(titlePrefix) {
            let rest = pane.title.dropFirst(titlePrefix.count).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return pane.currentCommand.isEmpty ? pane.target : pane.currentCommand
    }
}

/// Live reader over the tmux binary. A missing tmux, or no server, is an
/// empty list, not an error: most Macs run none.
struct LiveTmuxReader: TmuxReading {
    let socketName: String?
    let command: CancellableCommand

    init(socketName: String? = nil, command: CancellableCommand = CancellableCommand()) {
        self.socketName = socketName
        self.command = command
    }

    private var server: [String] { socketName.map { ["-L", $0] } ?? [] }

    func panes() async -> [TmuxPane] {
        guard let tmux = Shell.locate(TmuxNudge.candidates) else { return [] }
        guard let r = try? await command.run(tmux, server + ["list-panes", "-a", "-F", TmuxPaneList.format], timeout: 5), r.succeeded else { return [] }
        return TmuxPaneList.parse(r.stdout)
    }

    func capture(paneId: String) async -> String? {
        guard let tmux = Shell.locate(TmuxNudge.candidates) else { return nil }
        guard let r = try? await command.run(tmux, server + ["capture-pane", "-p", "-t", paneId], timeout: 5), r.succeeded else { return nil }
        return r.stdout
    }
}

/// A reader for a Mac without tmux, and for tests that need none.
struct NoTmuxReader: TmuxReading {
    func panes() async -> [TmuxPane] { [] }
    func capture(paneId: String) async -> String? { nil }
}
