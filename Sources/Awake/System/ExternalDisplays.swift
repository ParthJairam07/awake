import CoreGraphics
import Foundation

/// Phase 0: a lid closed on a desk with a monitor attached is not a lid
/// closed on a laptop in a bag. `ExternalDisplays.online` is the pure
/// question; `DisplayObserver` reports when the answer may have changed.
enum ExternalDisplays {
    /// Whether any online display is not the built-in panel.
    static func online(among ids: [CGDirectDisplayID], isBuiltIn: (CGDirectDisplayID) -> Bool) -> Bool {
        ids.contains { !isBuiltIn($0) }
    }

    /// The live answer, or nil when the display list cannot be read, in
    /// which case the caller treats the lid as a real lid close (fail
    /// closed: the actions run).
    static func read() -> Bool? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else { return nil }
        return online(among: Array(ids.prefix(Int(count))), isBuiltIn: { CGDisplayIsBuiltin($0) != 0 })
    }
}

/// Calls `onChange` on the main actor after any display reconfiguration
/// (connect, disconnect, mirror, resolution). The reader is injectable so
/// tests can drive the desk-mode logic without displays.
@MainActor
final class DisplayObserver {
    typealias Reader = @Sendable () -> Bool?

    var onChange: (() -> Void)?
    private let reader: Reader
    private var registered = false

    init(reader: @escaping Reader = { ExternalDisplays.read() }) {
        self.reader = reader
    }

    /// nil when the display list cannot be read.
    var externalOnline: Bool? { reader() }

    func start() {
        guard !registered else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if CGDisplayRegisterReconfigurationCallback(Self.callback, refcon) == .success {
            registered = true
        } else {
            Log.error("display observer: CGDisplayRegisterReconfigurationCallback failed")
        }
    }

    func stop() {
        guard registered else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(Self.callback, refcon)
        registered = false
    }

    /// Reconfiguration arrives as a begin flag for each display and then
    /// the changes; only the completed changes are reported, once per
    /// display, which is cheap enough to re-read the list on.
    private static let callback: CGDisplayReconfigurationCallBack = { _, flags, refcon in
        guard let refcon, !flags.contains(.beginConfigurationFlag) else { return }
        let observer = Unmanaged<DisplayObserver>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { observer.onChange?() }
    }
}

/// What a lid event means given the displays (phase 0, pure).
enum LidPolicy: Equatable, Sendable {
    /// Run the lid close actions: the Mac is being left.
    case close
    /// Lid closed on a desk with an external display: leave everything
    /// alone and watch the displays.
    case desk
    /// Undo the lid actions.
    case open

    /// `externalOnline` nil (unreadable) counts as no external display, so
    /// the actions run: with sleep disabled, the cost of a wrong "desk" is
    /// an unlocked, unmuted, full-speed laptop in a bag.
    static func decide(closed: Bool, externalOnline: Bool?, config: Config) -> LidPolicy {
        guard closed else { return .open }
        if config.skipLidActionsOnExternalDisplay, externalOnline == true { return .desk }
        return .close
    }
}
