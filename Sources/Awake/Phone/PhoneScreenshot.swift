import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One still of a display through ScreenCaptureKit, scaled down and
/// encoded as JPEG in memory. Nothing is written to disk. Needs the
/// Screen Recording permission, which macOS ties to the build's
/// signature: an ad-hoc signed reinstall has to be allowed again.
struct ScreenCaptureKitCapture: ScreenCapturing {
    static let jpegQuality = 0.6

    func permissionGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func captureJPEG(display: String, maxWidth: Int) async throws -> Data {
        // Asking ScreenCaptureKit without the permission raises the system
        // prompt on the Mac, in front of nobody; refuse first.
        guard permissionGranted() else { throw ScreenCaptureError.permissionDenied }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            if (error as NSError).code == SCStreamError.userDeclined.rawValue { throw ScreenCaptureError.permissionDenied }
            throw ScreenCaptureError.failed(error.localizedDescription)
        }
        guard let target = Self.pick(display, from: content.displays) else { throw ScreenCaptureError.noSuchDisplay }
        let size = Self.outputSize(width: target.width, height: target.height, maxWidth: maxWidth)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = true
        let filter = SCContentFilter(display: target, excludingWindows: [])
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            if (error as NSError).code == SCStreamError.userDeclined.rawValue { throw ScreenCaptureError.permissionDenied }
            throw ScreenCaptureError.failed(error.localizedDescription)
        }
        guard let jpeg = Self.jpeg(image, quality: Self.jpegQuality) else {
            throw ScreenCaptureError.failed("the image could not be encoded")
        }
        return jpeg
    }

    private static func pick(_ display: String, from displays: [SCDisplay]) -> SCDisplay? {
        if display == "main" {
            let main = CGMainDisplayID()
            return displays.first { $0.displayID == main } ?? displays.first
        }
        guard let index = Int(display), displays.indices.contains(index) else { return nil }
        return displays[index]
    }

    /// The display's size in points scaled to at most `maxWidth` wide,
    /// never enlarged, both sides even and at least 2.
    static func outputSize(width: Int, height: Int, maxWidth: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0, maxWidth > 0 else { return (2, 2) }
        let scale = min(1, Double(maxWidth) / Double(width))
        let w = max(2, Int((Double(width) * scale).rounded()) & ~1)
        let h = max(2, Int((Double(height) * scale).rounded()) & ~1)
        return (w, h)
    }

    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Returns scripted bytes; for tests.
final class FakeScreenCapture: ScreenCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(display: String, maxWidth: Int)] = []
    var granted = true
    var result: Result<Data, ScreenCaptureError> = .success(Data([0xFF, 0xD8, 0xFF, 0xD9]))
    var calls: [(display: String, maxWidth: Int)] { lock.withLock { _calls } }

    func permissionGranted() -> Bool { granted }

    func captureJPEG(display: String, maxWidth: Int) async throws -> Data {
        lock.withLock { _calls.append((display, maxWidth)) }
        return try result.get()
    }
}
