import Foundation

/// Phase 0: "Wi-Fi connected" is not "internet works". A captive portal
/// (hotel, café) answers every request with its login page, and dead DNS
/// or a dead upstream leaves the path satisfied with nothing behind it.
/// The probe fetches Apple's captive-portal page over plain HTTP, the same
/// check macOS runs on join, and calls the internet reachable only when
/// the page comes back as Apple serves it.
protocol InternetProbing: Sendable {
    /// true: reachable; false: not reachable (no answer, or a portal's
    /// answer); nil: the probe could not run at all and knows nothing.
    func reachable() async -> Bool?
}

enum InternetProbe {
    static let url = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    static let timeout: TimeInterval = 5
    /// Apple's page is `<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>`.
    static let successMarker = "Success"

    /// The verdict on one response, pure. A portal answers 200 with its
    /// own page, or 302 to it; both are "not reachable".
    static func verdict(status: Int?, body: String?) -> Bool {
        guard status == 200, let body else { return false }
        return body.contains(successMarker)
    }
}

/// Counts consecutive probe failures so one lost packet does not start an
/// outage. `down` after `failuresToDeclare` failures in a row; one success
/// clears it. nil (unknown) results are ignored.
struct ReachabilityTracker: Equatable, Sendable {
    static let failuresToDeclare = 2

    private(set) var failures = 0
    private(set) var down = false

    /// Returns true when `down` changed.
    @discardableResult
    mutating func record(_ reachable: Bool?) -> Bool {
        guard let reachable else { return false }
        let before = down
        if reachable {
            failures = 0
            down = false
        } else {
            failures += 1
            if failures >= Self.failuresToDeclare { down = true }
        }
        return before != down
    }
}

/// The live probe over URLSession, with caching off so a portal's cached
/// page cannot pass.
struct CaptivePortalProbe: InternetProbing {
    func reachable() async -> Bool? {
        var request = URLRequest(url: InternetProbe.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: InternetProbe.timeout)
        request.httpMethod = "GET"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = InternetProbe.timeout
        config.timeoutIntervalForResource = InternetProbe.timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return InternetProbe.verdict(status: status, body: String(data: data, encoding: .utf8))
        } catch {
            return false
        }
    }

    /// A redirect is a portal: report the 302 itself, do not follow it.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
