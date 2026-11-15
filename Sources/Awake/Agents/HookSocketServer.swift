import Darwin
import Foundation

/// The hook endpoint on a Unix-domain socket in Application Support
/// (`hooks.sock`, owner-only), so hooks work whatever `Config.statusPort`
/// is. Speaks the same tiny HTTP as the loopback endpoint: `curl
/// --unix-socket <path> http://awake/hooks/<kind>`.
///
/// Plain POSIX sockets: one accept source on a private queue, each
/// connection read with a deadline and closed after its one reply.
final class HookSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (AgentHookEvent) -> Void

    private let queue = DispatchQueue(label: "com.parthjairam.awake.hooks")
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var source: (any DispatchSourceRead)?
    private var boundPath: String?
    static let readTimeoutSeconds = 2

    var isListening: Bool { lock.withLock { listenFD >= 0 } }

    /// Longest path `sockaddr_un` holds, without the NUL.
    static var maxPathLength: Int { MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1 }

    /// Binds and listens. A socket file left by an earlier run is removed
    /// first; a live one cannot be told from a stale one by name, and the
    /// directory is Awake's own and owner-only.
    @discardableResult
    func start(path: String, handler: @escaping Handler) -> Bool {
        stop()
        guard path.utf8.count <= Self.maxPathLength else {
            Log.error("hook socket path is too long (\(path.utf8.count) bytes, limit \(Self.maxPathLength)); hooks need the status port instead")
            return false
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Log.error("hook socket: socket() failed: \(String(cString: strerror(errno)))")
            return false
        }
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8.prefix(raw.count - 1))
        }
        // Created owner-only: no window in which another user could connect.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(previousMask)
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            Log.error("hook socket: could not listen on \(path): \(String(cString: strerror(errno)))")
            close(fd)
            unlink(path)
            return false
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: fd, handler: handler) }
        source.setCancelHandler { close(fd) }
        lock.withLock {
            listenFD = fd
            self.source = source
            boundPath = path
        }
        source.resume()
        Log.info("hook socket listening at \(path)")
        return true
    }

    func stop() {
        let (source, path): ((any DispatchSourceRead)?, String?) = lock.withLock {
            let s = self.source
            let p = boundPath
            self.source = nil
            boundPath = nil
            listenFD = -1
            return (s, p)
        }
        source?.cancel()
        if let path { unlink(path) }
    }

    deinit { stop() }

    private func accept(on fd: Int32, handler: @escaping Handler) {
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return }
        var timeout = timeval(tv_sec: Self.readTimeoutSeconds, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global(qos: .utility).async {
            defer { close(client) }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            var reply: Data?
            reading: while true {
                switch HookHTTP.parse(data) {
                case .invalid:
                    reply = StatusHTTP.response(status: 400, reason: "Bad Request", body: Data("{\"error\":\"bad request\"}".utf8))
                    break reading
                case let .request(request):
                    let handled = HookHTTP.handleHook(request, overTCP: false)
                    reply = handled.reply
                    if let event = handled.event { handler(event) }
                    break reading
                case .needMore:
                    let n = read(client, &buffer, buffer.count)
                    guard n > 0 else { break reading }
                    data.append(buffer, count: n)
                }
            }
            guard let reply else { return }
            reply.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(client, raw.baseAddress! + offset, raw.count - offset)
                    guard n > 0 else { return }
                    offset += n
                }
            }
        }
    }
}
