import Darwin
import Foundation

/// Tells the lease manager that the leases directory changed. The app's
/// one is a DispatchSource on the directory; tests drive a fake.
@MainActor
protocol LeaseDirectoryWatching: AnyObject {
    /// Called on the main actor after a file was added, replaced or removed.
    var onChange: (@MainActor () -> Void)? { get set }
    /// Starts watching `directory`, or watches it again when the directory
    /// at that path is no longer the one being watched (it was deleted and
    /// made again). Cheap when nothing changed; called on every poll.
    func watch(_ directory: URL)
    func stop()
}

/// A `DispatchSource` on the directory's descriptor. A write to a
/// directory is a name added, removed or renamed in it, which is exactly
/// what a lease being granted, extended or released does.
@MainActor
final class LeaseDirectoryWatcher: LeaseDirectoryWatching {
    var onChange: (@MainActor () -> Void)?

    private var source: (any DispatchSourceFileSystemObject)?
    /// The directory the source holds open, to tell it from a new one at
    /// the same path.
    private var watched: (device: dev_t, inode: ino_t)?

    init() {}

    func watch(_ directory: URL) {
        var st = stat()
        let current: (device: dev_t, inode: ino_t)? = stat(directory.path, &st) == 0 ? (st.st_dev, st.st_ino) : nil
        if let watched, let current, watched == current, source != nil { return }
        stop()
        guard current != nil else { return }
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.error("leases: cannot watch \(directory.path): \(String(cString: strerror(errno))); the 30 s poll still reads it")
            return
        }
        var held = stat()
        guard fstat(fd, &held) == 0 else {
            close(fd)
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self] in
            Task { @MainActor in self?.onChange?() }
        }
        s.setCancelHandler { close(fd) }
        source = s
        watched = (held.st_dev, held.st_ino)
        s.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        watched = nil
    }
}
