import AppKit
import CoreImage

/// The QR code Settings shows for the phone's camera: the address of the
/// phone app, with the pairing code in the fragment while a window is
/// open. Core Image draws it; nothing leaves the Mac.
enum PhoneQR {
    /// One module per pixel, with the quiet zone Core Image adds. nil when
    /// the text cannot be encoded (too long for a QR code).
    static func modules(for text: String) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        // M: 15% of the code can be lost; a phone reads it off a screen
        // at an angle.
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent)
    }

    /// The code scaled up without smoothing to about `side` points.
    static func image(for text: String, side: CGFloat = 180) -> NSImage? {
        guard let small = modules(for: text) else { return nil }
        let scale = max(1, Int((side * 2) / CGFloat(small.width)))
        let width = small.width * scale
        guard let context = CGContext(
            data: nil, width: width, height: width, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(small, in: CGRect(x: 0, y: 0, width: width, height: width))
        guard let scaled = context.makeImage() else { return nil }
        return NSImage(cgImage: scaled, size: NSSize(width: side, height: side))
    }
}
