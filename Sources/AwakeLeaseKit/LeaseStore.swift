import Darwin
import Foundation

/// The leases directory: one `<id>.json` per lease.
///
/// Files are written the way the app writes its own (`Store`): to a temp
/// file created 0600 in the same directory, then renamed into place, so a
/// reader never sees half a lease and the file is owner-only from its first
/// byte. The directory is created 0700.
public struct LeaseStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(home: LeaseHome = .fromEnvironment()) {
        self.init(directory: home.leasesDirectory)
    }

    public enum StoreError: Error, LocalizedError, Equatable {
        case create(path: String, errno: Int32)
        case write(path: String, errno: Int32)
        case rename(path: String, errno: Int32)
        case remove(path: String, errno: Int32)

        public var errorDescription: String? {
            func text(_ e: Int32) -> String { String(cString: strerror(e)) }
            switch self {
            case let .create(path, e): return "could not create \(path): \(text(e))"
            case let .write(path, e): return "could not write \(path): \(text(e))"
            case let .rename(path, e): return "could not move a lease into place at \(path): \(text(e))"
            case let .remove(path, e): return "could not remove \(path): \(text(e))"
            }
        }
    }

    public func url(for id: UUID) -> URL {
        directory.appendingPathComponent(Lease.fileName(for: id))
    }

    /// Creates the directory 0700, and its parent (Awake's support
    /// directory) 0700 too when that does not exist yet: the command may
    /// run before the app ever has. An existing directory with a looser
    /// mode is tightened; bits are only ever cleared.
    public func ensureDirectory() throws {
        for dir in [directory.deletingLastPathComponent(), directory] {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw StoreError.create(path: dir.path, errno: (error as NSError).domain == NSPOSIXErrorDomain ? Int32((error as NSError).code) : EIO)
            }
            var st = stat()
            if lstat(dir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, (st.st_mode & 0o777) & ~0o700 != 0 {
                _ = chmod(dir.path, st.st_mode & 0o700)
            }
        }
    }

    /// Atomic, owner-only write of `lease` to `<id>.json`.
    public func write(_ lease: Lease) throws {
        try ensureDirectory()
        let data = try LeaseJSON.encoder().encode(lease)
        let final = url(for: lease.id)
        // A leading dot and no .json suffix: a scan never takes it for a lease.
        let tmp = directory.appendingPathComponent(".\(final.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError.write(path: tmp.path, errno: errno) }
        var failure: Int32?
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += n
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = errno }
        close(fd)
        if let failure {
            unlink(tmp.path)
            throw StoreError.write(path: tmp.path, errno: failure)
        }
        if rename(tmp.path, final.path) != 0 {
            let e = errno
            unlink(tmp.path)
            throw StoreError.rename(path: final.path, errno: e)
        }
    }

    /// Removes the lease's file. False when there was none.
    @discardableResult
    public func remove(id: UUID) throws -> Bool {
        try removeFile(url(for: id))
    }

    @discardableResult
    public func removeFile(_ url: URL) throws -> Bool {
        if unlink(url.path) == 0 { return true }
        if errno == ENOENT { return false }
        throw StoreError.remove(path: url.path, errno: errno)
    }

    /// A file in the directory that is not a lease.
    public struct Rejected: Equatable, Sendable {
        public var url: URL
        public var why: String
        /// When the file was last written. A file that has only just
        /// appeared may still be being written by a program that does not
        /// rename into place, so the app gives it a moment before deleting.
        public var modifiedAt: Date?
    }

    public struct Scan: Equatable, Sendable {
        /// Files that decode as a lease named by their own file name,
        /// oldest first. Not yet checked against the clock (`LeaseRules`).
        public var leases: [Lease] = []
        public var rejected: [Rejected] = []
    }

    /// Reads every `*.json` regular file in the directory. Dot files (the
    /// temp files of a write in flight) and anything else are not looked
    /// at. A missing directory is an empty scan.
    public func scan() -> Scan {
        var result = Scan()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return result }
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
            func reject(_ why: String) { result.rejected.append(Rejected(url: url, why: why, modifiedAt: modified)) }
            // Only a regular file is opened: a FIFO would block the read,
            // and a symlink could point anywhere.
            guard (st.st_mode & S_IFMT) == S_IFREG else { reject("not a regular file"); continue }
            guard st.st_size <= 64 * 1024 else { reject("larger than a lease can be"); continue }
            guard let id = UUID(uuidString: String(name.dropLast(5))) else { reject("its name is not a lease id"); continue }
            guard let data = try? Data(contentsOf: url) else { reject("could not be read"); continue }
            do {
                let lease = try LeaseJSON.decoder().decode(Lease.self, from: data)
                guard lease.id == id else { reject("its id is not its file name"); continue }
                result.leases.append(lease)
            } catch {
                reject("not a lease: \(Self.brief(error))")
            }
        }
        result.leases.sort { ($0.createdAt, Lease.idText($0.id)) < ($1.createdAt, Lease.idText($1.id)) }
        return result
    }

    /// The lease with this id, or nil when there is no such file or it is
    /// not a lease.
    public func load(id: UUID) -> Lease? {
        guard let data = try? Data(contentsOf: url(for: id)),
              let lease = try? LeaseJSON.decoder().decode(Lease.self, from: data),
              lease.id == id
        else { return nil }
        return lease
    }

    private static func brief(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        func path(_ c: DecodingError.Context) -> String {
            let p = c.codingPath.map(\.stringValue).joined(separator: ".")
            return p.isEmpty ? "" : "\(p): "
        }
        switch e {
        case let .dataCorrupted(c): return path(c) + c.debugDescription
        case let .keyNotFound(k, c): return path(c) + "missing key \(k.stringValue)"
        case let .typeMismatch(t, c): return path(c) + "expected \(t)"
        case let .valueNotFound(t, c): return path(c) + "missing \(t)"
        @unknown default: return String(describing: e)
        }
    }
}
