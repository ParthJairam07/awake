import Darwin
import Foundation

/// What the process table says about a pid.
public enum LeaseProcessLookup: Equatable, Sendable {
    case present(LeaseProcess)
    /// The kernel confirmed there is no such process (a zombie counts: it
    /// has exited).
    case absent
    /// The lookup failed (errno). Unknown is not gone.
    case unreadable(Int32)
}

/// Reads a process's identity from the process table (sysctl
/// KERN_PROC_PID, as `ps` does), which answers for every user's processes.
/// The same reading the app takes before it trusts a pid.
public enum LeaseProcessProbe {
    /// `kern.bootsessionuuid`: one UUID per boot.
    public static let bootSession: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    public static func lookup(pid: Int32) -> LeaseProcessLookup {
        guard pid > 0 else { return .absent }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var entry = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &entry, &size, nil, 0) == 0 else { return .unreadable(errno) }
        guard size == MemoryLayout<kinfo_proc>.stride, entry.kp_proc.p_pid == pid else { return .absent }
        guard entry.kp_proc.p_stat != UInt8(SZOMB) else { return .absent }
        let started = entry.kp_proc.p_starttime
        return .present(LeaseProcess(
            pid: pid,
            startedAt: Int64(started.tv_sec),
            startedAtMicros: Int32(truncatingIfNeeded: started.tv_usec),
            bootSession: bootSession
        ))
    }

    /// Whether the process `recorded` names is the one running under its
    /// pid now. nil when that cannot be told (a failed lookup, or no boot
    /// session on either side): unknown, which is neither running nor gone.
    public static func isRunning(_ recorded: LeaseProcess, lookup: (Int32) -> LeaseProcessLookup = LeaseProcessProbe.lookup) -> Bool? {
        switch lookup(recorded.pid) {
        case .absent:
            return false
        case .unreadable:
            return nil
        case let .present(live):
            // A lease from before a restart names a process that is gone.
            guard !recorded.bootSession.isEmpty else { return false }
            guard !live.bootSession.isEmpty else { return nil }
            return live == recorded
        }
    }
}
