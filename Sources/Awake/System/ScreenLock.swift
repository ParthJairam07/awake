import Foundation

/// Locks the login session so an unattended Mac with sleep disabled does
/// not sit open to the terminals and agents on it. Failure is reported,
/// never hidden: the lid close goes on without the lock, and the user is
/// told once per session.
protocol ScreenLocking: Sendable {
    /// Lock now. Throws when the lock could not be requested.
    func lock() throws
}

struct ScreenLockError: Error, CustomStringConvertible {
    let description: String
}

/// Records lock requests for tests; `failWith` makes them fail.
final class RecordingScreenLock: ScreenLocking, @unchecked Sendable {
    private let mutex = NSLock()
    private var _calls = 0
    var failWith: String?
    var calls: Int { mutex.withLock { _calls } }

    func lock() throws {
        mutex.withLock { _calls += 1 }
        if let failWith { throw ScreenLockError(description: failWith) }
    }
}

/// Never locks; the default where the caller has not wired a lock.
struct NoopScreenLock: ScreenLocking {
    func lock() throws {}
}

/// The lock behind the Lock Screen menu item and ⌃⌘Q: `SACLockScreenImmediate`
/// from the private login framework, which locks without logging out,
/// switching users, or needing Accessibility access. There is no public
/// API that locks the screen; a public fallback would be `pmset
/// displaysleepnow`, which only locks when "Require password immediately"
/// is set, so the private call is used and its absence is an error rather
/// than a silent no-op.
struct LoginFrameworkScreenLock: ScreenLocking {
    private static let frameworkPath = "/System/Library/PrivateFrameworks/login.framework/login"
    private static let symbol = "SACLockScreenImmediate"

    func lock() throws {
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else {
            let why = dlerror().map { String(cString: $0) } ?? "dlopen failed"
            throw ScreenLockError(description: "login.framework not found: \(why)")
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, Self.symbol) else {
            throw ScreenLockError(description: "\(Self.symbol) not found in login.framework")
        }
        typealias Lock = @convention(c) () -> Int32
        let call = unsafeBitCast(sym, to: Lock.self)
        let rc = call()
        if rc != 0 {
            throw ScreenLockError(description: "\(Self.symbol) returned \(rc)")
        }
    }
}
