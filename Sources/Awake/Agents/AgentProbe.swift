import Darwin
import Foundation

/// One process as the agent registry needs it: the kernel entry plus the
/// path and arguments that say what it is.
struct AgentProcess: Sendable, Equatable {
    let entry: ProcessEntry
    /// `proc_pidpath`; empty when the kernel would not say.
    let executable: String
    /// argv, argv[0] first; empty when unreadable (another user's process).
    let arguments: [String]

    var pid: Int32 { entry.pid }

    init(entry: ProcessEntry, executable: String, arguments: [String] = []) {
        self.entry = entry
        self.executable = executable
        self.arguments = arguments
    }
}

/// What costs a syscall per pid, read only for the pids of an agent.
struct AgentProcessUsage: Sendable, Equatable {
    /// User plus system CPU time since the process started, nanoseconds.
    var cpuNanos: UInt64
    var residentBytes: UInt64
    /// Working directory, when readable.
    var cwd: String?

    init(cpuNanos: UInt64, residentBytes: UInt64, cwd: String? = nil) {
        self.cpuNanos = cpuNanos
        self.residentBytes = residentBytes
        self.cwd = cwd
    }
}

/// The process side of agent discovery. The live one reads the kernel;
/// tests hand in a fixed table.
protocol AgentProcessProbing: Sendable {
    func processes() -> [AgentProcess]
    func apps() -> [RunningApp]
    func usage(pid: Int32) -> AgentProcessUsage?
    /// The parent of a pid right now, for a pid that is not in the last
    /// snapshot (a hook's short-lived shell).
    func parent(of pid: Int32) -> Int32?
}

/// Live probe: the existing process snapshot (`Freezer.processSnapshot`)
/// plus `proc_pidpath`, `KERN_PROCARGS2` and `proc_pidinfo`. No `ps`, no
/// `lsof`.
struct LiveAgentProbe: AgentProcessProbing {
    func processes() -> [AgentProcess] {
        Freezer.processSnapshot().compactMap { entry in
            guard entry.pid > 0 else { return nil }
            let path = Self.path(of: entry.pid)
            guard !path.isEmpty else { return nil }
            // Arguments cost a sysctl each: read them only where the path
            // alone cannot settle what the process is.
            let base = AgentCatalog.baseName(path)
            let needsArguments = AgentCatalog.commands[base] != nil || AgentCatalog.launchers.contains(base)
                || base.hasPrefix("python") || base.hasPrefix("node")
            return AgentProcess(entry: entry, executable: path, arguments: needsArguments ? Self.arguments(of: entry.pid) : [])
        }
    }

    func apps() -> [RunningApp] {
        // NSWorkspace is main-thread bound for KVO only; the array read is
        // safe from any thread.
        Freezer.runningApps()
    }

    func usage(pid: Int32) -> AgentProcessUsage? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        let ticks = info.pti_total_user &+ info.pti_total_system
        return AgentProcessUsage(
            cpuNanos: Self.nanos(fromMachTicks: ticks),
            residentBytes: info.pti_resident_size,
            cwd: Self.cwd(of: pid)
        )
    }

    func parent(of pid: Int32) -> Int32? {
        guard case let .present(state) = SignalProcessControl.processTableState(pid: pid) else { return nil }
        return state.ppid
    }

    static func path(of pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "" }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func cwd(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// argv from `KERN_PROCARGS2`: an int argc, the executable path, NUL
    /// padding, then argc NUL-terminated strings.
    static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    static func parseProcArgs(_ bytes: [UInt8]) -> [String] {
        let header = MemoryLayout<Int32>.size
        guard bytes.count > header else { return [] }
        let argc = bytes.prefix(header).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 4096 else { return [] }
        var index = header
        // The executable path, then the NULs that pad it.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var out: [String] = []
        while out.count < Int(argc), index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            out.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return out
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// `pti_total_user`/`system` are in Mach time units on Apple Silicon.
    static func nanos(fromMachTicks ticks: UInt64) -> UInt64 {
        let t = timebase
        guard t.denom != 0, t.numer != t.denom else { return ticks }
        return ticks / UInt64(t.denom) * UInt64(t.numer) + (ticks % UInt64(t.denom)) * UInt64(t.numer) / UInt64(t.denom)
    }
}

/// Finds the git work tree a directory belongs to by walking up to the
/// first `.git` (a directory, or the file a worktree or submodule has).
enum GitRepoLocator {
    static func root(of directory: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        for _ in 0..<64 {
            if fileExists(url.appendingPathComponent(".git").path) { return url.path }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }

    static func name(of root: String) -> String {
        (root as NSString).lastPathComponent
    }
}
