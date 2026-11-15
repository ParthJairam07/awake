import AwakeLeaseKit
import Darwin
import Foundation

/// Everything the command touches outside its own arguments, so the tests
/// replace each with a fake: the clock, the files, the process table,
/// tmux, whether the app is running, and where output goes.
struct CLIEnvironment: Sendable {
    var home: LeaseHome
    var now: @Sendable () -> Date
    var appRunning: @Sendable () -> Bool
    var processLookup: @Sendable (Int32) -> LeaseProcessLookup
    var tmux: LeaseTmux.Runner
    /// The default owner of a lease made from a shell.
    var userName: String
    var environment: [String: String]
    var out: @Sendable (String) -> Void
    var err: @Sendable (String) -> Void
    /// Starts the command of `--until-exit`.
    var spawn: @Sendable ([String]) throws -> any SpawnedCommand
    var version: String

    var store: LeaseStore { LeaseStore(directory: home.leasesDirectory) }

    static func live() -> CLIEnvironment {
        CLIEnvironment(
            home: .fromEnvironment(),
            now: { Date() },
            appRunning: { AppProbe.isRunning() },
            processLookup: { LeaseProcessProbe.lookup(pid: $0) },
            tmux: LeaseTmux.liveRunner,
            userName: NSUserName(),
            environment: ProcessInfo.processInfo.environment,
            out: { line in
                FileHandle.standardOutput.write(Data((line + "\n").utf8))
            },
            err: { line in
                FileHandle.standardError.write(Data((line + "\n").utf8))
            },
            spawn: { try LiveCommand(arguments: $0) },
            version: AppProbe.version()
        )
    }
}

/// A child process started for `--until-exit`.
protocol SpawnedCommand: Sendable {
    var pid: Int32 { get }
    /// Blocks until the child has exited. Its exit status, or 128 + the
    /// signal that ended it, as a shell reports it.
    func wait() -> Int32
}

enum SpawnError: Error, LocalizedError {
    case notFound(String)
    case failed(String, String)

    var errorDescription: String? {
        switch self {
        case let .notFound(name): "\(name): command not found"
        case let .failed(name, why): "could not run \(name): \(why)"
        }
    }
}

/// The real child: the command with this process's stdin, stdout, stderr,
/// environment and working directory.
final class LiveCommand: SpawnedCommand, @unchecked Sendable {
    private let process = Process()
    private var forwarders: [any DispatchSourceSignal] = []
    let pid: Int32

    init(arguments: [String]) throws {
        guard let name = arguments.first else { throw SpawnError.notFound("") }
        guard let exe = Self.resolve(name) else { throw SpawnError.notFound(name) }
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = Array(arguments.dropFirst())
        do {
            try process.run()
        } catch {
            throw SpawnError.failed(name, error.localizedDescription)
        }
        pid = process.processIdentifier
        // Ctrl-C reaches the child by itself: it is in the terminal's
        // foreground group with this process. This process has to outlive
        // it to release the lease, so it ignores the interrupt and passes
        // the signals a terminal does not deliver to the group on.
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        for sig in [SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            let child = pid
            source.setEventHandler { kill(child, sig) }
            source.resume()
            forwarders.append(source)
        }
    }

    func wait() -> Int32 {
        process.waitUntilExit()
        for source in forwarders { source.cancel() }
        switch process.terminationReason {
        case .exit: return process.terminationStatus
        case .uncaughtSignal: return 128 + process.terminationStatus
        @unknown default: return process.terminationStatus
        }
    }

    /// A name with a slash is a path; anything else is looked up on PATH,
    /// as a shell would.
    static func resolve(_ name: String, path: String? = ProcessInfo.processInfo.environment["PATH"]) -> String? {
        let fm = FileManager.default
        func runnable(_ candidate: String) -> Bool {
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: candidate, isDirectory: &isDirectory) && !isDirectory.boolValue && fm.isExecutableFile(atPath: candidate)
        }
        if name.contains("/") { return runnable(name) ? name : nil }
        for dir in (path ?? "/usr/bin:/bin").split(separator: ":") where !dir.isEmpty {
            let candidate = "\(dir)/\(name)"
            if runnable(candidate) { return candidate }
        }
        return nil
    }
}

/// What the command can tell about the app without talking to it.
enum AppProbe {
    /// True when a process whose executable is the app's is running: a
    /// path ending in `Awake.app/Contents/MacOS/Awake`, or a development
    /// build named `Awake`. The comparison is exact, so this command
    /// (`awake`) is never taken for the app on a volume that ignores case.
    static func isRunning() -> Bool {
        let capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { return false }
        var pids = [pid_t](repeating: 0, count: capacity + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return false }
        let mine = getpid()
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(count) where pid > 0 && pid != mine {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
            if isAppExecutable(String(decoding: bytes, as: UTF8.self)) { return true }
        }
        return false
    }

    static func isAppExecutable(_ path: String) -> Bool {
        path.hasSuffix("/Awake.app/Contents/MacOS/Awake") || path.hasSuffix("/debug/Awake") || path.hasSuffix("/release/Awake")
    }

    /// The app's version when this command sits inside its bundle
    /// (`Awake.app/Contents/Helpers/awake`), else "dev".
    static func version(executable: URL? = Bundle.main.executableURL) -> String {
        guard let executable else { return "dev" }
        let contents = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let plist = contents.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String
        else { return "dev" }
        return version
    }
}
