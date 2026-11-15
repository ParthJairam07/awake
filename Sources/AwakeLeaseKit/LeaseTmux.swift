import Foundation

/// Reading a tmux pane for `--until-tmux`. Only ever `display-message -p`:
/// nothing is typed into a pane and no option is changed.
public enum LeaseTmux {
    public static let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    /// A pane whose foreground program is one of these is at a prompt: the
    /// work the lease was for has finished. A leading "-" (a login shell)
    /// is dropped before the comparison.
    public static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "elvish", "xonsh", "pwsh", "login"]

    /// Between fields. Not a tab or another control character: tmux prints
    /// those as "_". A socket path or a command name with a space in it
    /// stays one field.
    public static let separator = "|~|"
    public static let format = ["#{pane_id}", "#{pane_dead}", "#{pane_pid}", "#{socket_path}", "#{pane_current_command}"].joined(separator: separator)

    public struct Reading: Equatable, Sendable {
        public var paneId: String
        public var dead: Bool
        public var pid: Int32
        public var socketPath: String
        public var command: String

        /// Something other than a shell is in the foreground of a live pane.
        public var isBusy: Bool {
            guard !dead else { return false }
            var name = command
            if name.hasPrefix("-") { name.removeFirst() }
            return !name.isEmpty && !LeaseTmux.shells.contains(name)
        }
    }

    public enum Answer: Equatable, Sendable {
        case pane(Reading)
        /// tmux says there is no such pane, or no server at all.
        case gone
        /// tmux is not installed, could not be run, or answered something
        /// else. Unknown: neither running nor finished.
        case unknown(String)
    }

    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String

        public init(status: Int32, stdout: String, stderr: String) {
            self.status = status
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    /// Runs tmux with these arguments; nil when tmux is not installed.
    public typealias Runner = @Sendable ([String]) -> Output?

    /// `display-message` for `target` (a `session:window.pane`, or a `%N`
    /// pane id), on the server at `socketPath` when one is given.
    public static func arguments(target: String, socketPath: String?) -> [String] {
        var args: [String] = []
        if let socketPath, !socketPath.isEmpty { args += ["-S", socketPath] }
        return args + ["display-message", "-p", "-t", target, "-F", format]
    }

    public static func read(target: String, socketPath: String? = nil, runner: Runner = liveRunner) -> Answer {
        guard let out = runner(arguments(target: target, socketPath: socketPath)) else {
            return .unknown("tmux is not installed (looked in \(candidates.joined(separator: ", ")))")
        }
        return interpret(out)
    }

    /// Pure, so the cases are tested without a tmux server.
    public static func interpret(_ out: Output) -> Answer {
        guard out.status == 0 else {
            let message = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = message.lowercased()
            if lowered.contains("can't find") || lowered.contains("no server running") || lowered.contains("error connecting to") {
                return .gone
            }
            return .unknown(message.isEmpty ? "tmux exited \(out.status)" : message)
        }
        let line = out.stdout.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let fields = line.components(separatedBy: separator)
        // For a target that names no pane tmux 3.x exits 0 and prints the
        // format with every pane field empty; a pane always has an id.
        if line.isEmpty || (fields.count == 5 && fields[0].isEmpty) { return .gone }
        guard fields.count == 5, fields[0].hasPrefix("%"), let pid = Int32(fields[2]) else {
            return .unknown("unexpected tmux answer: \(line)")
        }
        return .pane(Reading(paneId: fields[0], dead: fields[1] == "1", pid: pid, socketPath: fields[3], command: fields[4]))
    }

    /// What `pane` is doing now.
    public enum PaneState: Equatable, Sendable {
        /// The same pane, with a program other than a shell in front.
        case busy
        /// The pane is gone, dead, at a shell prompt, or another pane now
        /// has its id.
        case finished
        case unknown(String)
    }

    public static func state(
        of pane: LeasePane,
        runner: Runner = liveRunner,
        processLookup: (Int32) -> LeaseProcessLookup = LeaseProcessProbe.lookup
    ) -> PaneState {
        switch read(target: pane.paneId, socketPath: pane.socketPath, runner: runner) {
        case .gone:
            return .finished
        case let .unknown(why):
            return .unknown(why)
        case let .pane(reading):
            guard reading.paneId == pane.paneId, reading.pid == pane.process.pid else { return .finished }
            switch LeaseProcessProbe.isRunning(pane.process, lookup: processLookup) {
            case false?: return .finished
            case nil: return .unknown("the pane's process could not be read")
            case true?: return reading.isBusy ? .busy : .finished
            }
        }
    }

    public static let liveRunner: Runner = { args in
        guard let exe = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            return Output(status: 127, stdout: "", stderr: "could not run \(exe): \(error.localizedDescription)")
        }
        // display-message prints one short line; neither pipe can fill.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self), stderr: String(decoding: errData, as: UTF8.self))
    }
}
