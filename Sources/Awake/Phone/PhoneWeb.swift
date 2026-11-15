import Foundation

/// The phone web app's files, embedded in the executable by SwiftPM
/// (`.embedInCode` in Package.swift), so the app bundle stays one signed
/// binary. Nothing is read from disk and there is no directory to walk:
/// these cases are every static path the server knows.
enum PhoneWebAsset: String, CaseIterable, Sendable {
    case index
    case script
    case style
    case manifest
    case serviceWorker
    case icon180
    case icon192
    case icon512

    var paths: [String] {
        switch self {
        case .index: ["/", "/index.html"]
        case .script: ["/app.js"]
        case .style: ["/app.css"]
        case .manifest: ["/manifest.webmanifest"]
        case .serviceWorker: ["/sw.js"]
        case .icon180: ["/icon-180.png", "/apple-touch-icon.png", "/apple-touch-icon-precomposed.png"]
        case .icon192: ["/icon-192.png", "/favicon.ico"]
        case .icon512: ["/icon-512.png"]
        }
    }

    var contentType: String {
        switch self {
        case .index: "text/html; charset=utf-8"
        case .script, .serviceWorker: "text/javascript; charset=utf-8"
        case .style: "text/css; charset=utf-8"
        case .manifest: "application/manifest+json; charset=utf-8"
        case .icon180, .icon192, .icon512: "image/png"
        }
    }

    var data: Data {
        switch self {
        case .index: Data(PackageResources.index_html)
        case .script: Data(PackageResources.app_js)
        case .style: Data(PackageResources.app_css)
        case .manifest: Data(PackageResources.manifest_webmanifest)
        case .serviceWorker: Data(PackageResources.sw_js)
        case .icon180: Data(PackageResources.icon_180_png)
        case .icon192: Data(PackageResources.icon_192_png)
        case .icon512: Data(PackageResources.icon_512_png)
        }
    }

    var response: PhoneResponse {
        PhoneResponse(status: 200, contentType: contentType, body: data)
    }
}
