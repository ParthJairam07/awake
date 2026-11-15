import CoreImage
import XCTest
@testable import Awake

final class PhoneWebAssetTests: XCTestCase {
    private func text(_ asset: PhoneWebAsset) -> String {
        String(decoding: asset.data, as: UTF8.self)
    }

    func testEveryAssetIsEmbeddedAndTyped() {
        for asset in PhoneWebAsset.allCases {
            XCTAssertGreaterThan(asset.data.count, 100, "\(asset)")
            XCTAssertFalse(asset.paths.isEmpty)
            XCTAssertEqual(asset.response.status, 200)
        }
        XCTAssertEqual(PhoneWebAsset.index.contentType, "text/html; charset=utf-8")
        XCTAssertEqual(PhoneWebAsset.script.contentType, "text/javascript; charset=utf-8")
        XCTAssertEqual(PhoneWebAsset.serviceWorker.contentType, "text/javascript; charset=utf-8", "a service worker must be served as JavaScript")
        XCTAssertEqual(PhoneWebAsset.manifest.contentType, "application/manifest+json; charset=utf-8")
        for icon in [PhoneWebAsset.icon180, .icon192, .icon512] {
            XCTAssertEqual(Array(icon.data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], "PNG signature")
        }
    }

    func testIconsHaveTheSizesTheirNamesSay() throws {
        for (asset, side) in [(PhoneWebAsset.icon180, 180), (.icon192, 192), (.icon512, 512)] {
            let image = try XCTUnwrap(CIImage(data: asset.data))
            XCTAssertEqual(Int(image.extent.width), side)
            XCTAssertEqual(Int(image.extent.height), side)
        }
    }

    func testThePageCanBeAddedToTheIPhoneHomeScreen() {
        let html = text(.index)
        XCTAssertTrue(html.contains("<title>Awake</title>"))
        XCTAssertTrue(html.contains("<meta name=\"apple-mobile-web-app-capable\" content=\"yes\">"))
        XCTAssertTrue(html.contains("<link rel=\"apple-touch-icon\" href=\"/icon-180.png\">"))
        XCTAssertTrue(html.contains("<link rel=\"manifest\" href=\"/manifest.webmanifest\">"))
        XCTAssertTrue(html.contains("viewport-fit=cover"))
    }

    func testEveryFileThePageLoadsIsServed() {
        let router = PhoneAPI.makeRouter()
        let html = text(.index)
        let pattern = try! NSRegularExpression(pattern: "(?:href|src)=\"([^\"]+)\"")
        let matches = pattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
        XCTAssertGreaterThanOrEqual(matches.count, 5)
        for match in matches {
            let path = String(html[Range(match.range(at: 1), in: html)!])
            XCTAssertTrue(path.hasPrefix("/"), "only this server's own files: \(path)")
            XCTAssertNotNil(router.match(method: "GET", path: path), path)
        }
    }

    /// The Content-Security-Policy is `default-src 'self'`: an inline
    /// script, style or handler would be blocked on the phone.
    func testThePageHasNothingInline() {
        let html = text(.index)
        XCTAssertFalse(html.contains("<script>"), "no inline script")
        XCTAssertFalse(html.contains("<style"), "no inline style sheet")
        XCTAssertFalse(html.contains(" style=\""), "no inline style attribute")
        XCTAssertNil(html.range(of: " on[a-z]+=\"", options: .regularExpression), "no inline event handler")
        XCTAssertFalse(html.contains("http://") || html.contains("https://"), "nothing loaded from another origin")
    }

    /// Agent prompts, log lines and device names are text from elsewhere;
    /// the script must never put any of it on the page as HTML or run it.
    func testTheScriptNeverWritesHTMLOrEvaluatesText() {
        let js = text(.script)
        for banned in ["innerHTML", "outerHTML", "insertAdjacentHTML", "document.write", "eval(", "new Function", "setAttribute('style'", "setAttribute(\"style\""] {
            XCTAssertFalse(js.contains(banned), banned)
        }
        XCTAssertTrue(js.contains("textContent"))
        XCTAssertFalse(js.contains("http://") || js.contains("https://"), "the script calls only its own origin")
    }

    func testTheScriptSendsTheTokenAsABearerHeaderNotInAURL() {
        let js = text(.script)
        XCTAssertTrue(js.contains("'Bearer ' + token"))
        XCTAssertFalse(js.contains("?token="))
        XCTAssertFalse(js.contains("&token="))
        XCTAssertFalse(js.contains("new EventSource"), "EventSource cannot send the Authorization header")
    }

    func testTheScriptCallsOnlyRoutesTheServerHas() {
        let router = PhoneAPI.makeRouter()
        let js = text(.script)
        let pattern = try! NSRegularExpression(pattern: "'(GET|POST)', '(/api/[a-z/]+)[?']")
        let matches = pattern.matches(in: js, range: NSRange(js.startIndex..., in: js))
        XCTAssertGreaterThanOrEqual(matches.count, 12)
        for match in matches {
            let method = String(js[Range(match.range(at: 1), in: js)!])
            let path = String(js[Range(match.range(at: 2), in: js)!])
            XCTAssertNotNil(router.match(method: method, path: path), "\(method) \(path)")
        }
        XCTAssertTrue(js.contains("fetch('/api/events'"))
        XCTAssertTrue(js.contains("'/api/agents/' + encodeURIComponent(agent.id) + '/'"))
    }

    func testTheManifestIsAStandaloneApp() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: PhoneWebAsset.manifest.data) as? [String: Any])
        XCTAssertEqual(object["name"] as? String, "Awake")
        XCTAssertEqual(object["display"] as? String, "standalone")
        XCTAssertEqual(object["start_url"] as? String, "/")
        let icons = try XCTUnwrap(object["icons"] as? [[String: Any]])
        let router = PhoneAPI.makeRouter()
        XCTAssertTrue(icons.contains { $0["sizes"] as? String == "192x192" })
        XCTAssertTrue(icons.contains { $0["sizes"] as? String == "512x512" })
        for icon in icons {
            XCTAssertNotNil(router.match(method: "GET", path: icon["src"] as? String ?? ""))
        }
    }

    func testTheServiceWorkerNeverTouchesTheAPI() {
        let sw = text(.serviceWorker)
        XCTAssertTrue(sw.contains("url.pathname.startsWith('/api/')) return;"), "API calls go straight to the Mac")
        let router = PhoneAPI.makeRouter()
        let shell = sw.range(of: "const SHELL = \\[[^\\]]+\\]", options: .regularExpression).map { String(sw[$0]) } ?? ""
        let pattern = try! NSRegularExpression(pattern: "'(/[^']*)'")
        let matches = pattern.matches(in: shell, range: NSRange(shell.startIndex..., in: shell))
        XCTAssertGreaterThanOrEqual(matches.count, 5)
        for match in matches {
            let path = String(shell[Range(match.range(at: 1), in: shell)!])
            XCTAssertNotNil(router.match(method: "GET", path: path), path)
        }
    }
}

final class PhoneQRTests: XCTestCase {
    func testTheCodeReadsBackAsTheAddress() throws {
        let text = "https://mac.tail1234.ts.net/#pair=123456"
        let image = try XCTUnwrap(PhoneQR.image(for: text, side: 200))
        XCTAssertEqual(image.size.width, 200)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cg.width, cg.height)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(options: [.useSoftwareRenderer: true]), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: CIImage(cgImage: cg))
        XCTAssertEqual((features.first as? CIQRCodeFeature)?.messageString, text)
    }

    func testModulesAreSquareAndSmall() throws {
        let modules = try XCTUnwrap(PhoneQR.modules(for: "http://100.101.102.103:7788"))
        XCTAssertEqual(modules.width, modules.height)
        XCTAssertLessThan(modules.width, 80, "one pixel per module")
    }
}

@MainActor
final class PhoneAppControllerTests: XCTestCase {
    func testStatusLines() {
        let ts = Tailscale.Addresses(ipv4: "100.101.102.103", ipv6: nil)
        XCTAssertEqual(PhoneAppController.statusLine(enabled: false, listening: [], problems: [], tailscale: .none, port: 7788), "Off")
        XCTAssertEqual(PhoneAppController.statusLine(enabled: true, listening: [], problems: [], tailscale: .none, port: 7788), "Starting on port 7788\u{2026}")
        XCTAssertEqual(PhoneAppController.statusLine(enabled: true, listening: [], problems: ["127.0.0.1: Address already in use"], tailscale: .none, port: 7788), "Not listening on port 7788: 127.0.0.1: Address already in use")
        XCTAssertEqual(PhoneAppController.statusLine(enabled: true, listening: ["127.0.0.1"], problems: [], tailscale: .none, port: 7788), "Tailscale not found: serving this Mac only, on http://127.0.0.1:7788")
        XCTAssertEqual(PhoneAppController.statusLine(enabled: true, listening: ["127.0.0.1", "100.101.102.103"], problems: [], tailscale: ts, port: 7788), "Serving the tailnet on http://100.101.102.103:7788")
        XCTAssertTrue(PhoneAppController.statusLine(enabled: true, listening: ["127.0.0.1"], problems: [], tailscale: ts, port: 7788).contains("not up yet"))
    }

    func testMenuLines() {
        let ts = Tailscale.Addresses(ipv4: "100.101.102.103", ipv6: nil)
        XCTAssertNil(PhoneAppController.menuLine(enabled: false, listening: [], tailscale: .none, paired: 0, pairingCode: nil))
        let none = PhoneAppController.menuLine(enabled: true, listening: ["127.0.0.1"], tailscale: .none, paired: 1, pairingCode: nil)
        XCTAssertEqual(none?.text, "Phone app: Tailscale not found")
        XCTAssertEqual(none?.isWarning, true)
        XCTAssertEqual(PhoneAppController.menuLine(enabled: true, listening: ["127.0.0.1"], tailscale: ts, paired: 0, pairingCode: nil)?.text, "Phone app: no phone paired")
        XCTAssertEqual(PhoneAppController.menuLine(enabled: true, listening: ["127.0.0.1"], tailscale: ts, paired: 1, pairingCode: nil)?.text, "Phone app: 1 phone paired")
        XCTAssertEqual(PhoneAppController.menuLine(enabled: true, listening: ["127.0.0.1"], tailscale: ts, paired: 3, pairingCode: nil)?.text, "Phone app: 3 phones paired")
        XCTAssertEqual(PhoneAppController.menuLine(enabled: true, listening: ["127.0.0.1"], tailscale: .none, paired: 0, pairingCode: "042137")?.text, "Phone app: pairing code 042137")
        XCTAssertEqual(PhoneAppController.menuLine(enabled: true, listening: [], tailscale: ts, paired: 1, pairingCode: nil)?.isWarning, true)
    }

    func testOnlyARealChangeIsPushed() {
        let a = Data("{\"server\":{\"name\":\"Mac\",\"time\":\"2026-11-15T08:00:00Z\"},\"status\":{\"active\":true,\"remainingSeconds\":100,\"updatedAt\":\"2026-11-15T08:00:00Z\",\"batteryPercent\":80}}".utf8)
        let b = Data("{\"server\":{\"name\":\"Mac\",\"time\":\"2026-11-15T08:00:05Z\"},\"status\":{\"active\":true,\"remainingSeconds\":95,\"updatedAt\":\"2026-11-15T08:00:05Z\",\"batteryPercent\":80}}".utf8)
        let c = Data("{\"server\":{\"name\":\"Mac\",\"time\":\"2026-11-15T08:00:05Z\"},\"status\":{\"active\":true,\"remainingSeconds\":95,\"updatedAt\":\"2026-11-15T08:00:05Z\",\"batteryPercent\":79}}".utf8)
        XCTAssertEqual(PhoneAppController.comparable(a), PhoneAppController.comparable(b), "the clock ticking is not a change")
        XCTAssertNotEqual(PhoneAppController.comparable(b), PhoneAppController.comparable(c))
    }

    func testPorts() {
        XCTAssertTrue(PhoneAppController.validPort(7788))
        XCTAssertTrue(PhoneAppController.validPort(1024))
        XCTAssertFalse(PhoneAppController.validPort(80), "no privileged ports")
        XCTAssertFalse(PhoneAppController.validPort(0))
        XCTAssertFalse(PhoneAppController.validPort(65536))
    }

    private func makeController(home: TempHome, interfaces: [InterfaceAddress], shell: FakePhoneShell = FakePhoneShell(), store: MemoryPhoneDeviceStore = MemoryPhoneDeviceStore()) -> PhoneAppController {
        PhoneAppController(
            paths: home.paths,
            session: FakePhoneSession(),
            locker: RecordingScreenLock(),
            machine: FakePhoneMachine(),
            screen: FakeScreenCapture(),
            deviceStore: store,
            interfaces: { interfaces },
            shell: shell
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<150 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    func testOffByDefaultAndListensOnNothing() async throws {
        let home = TempHome()
        defer { home.destroy() }
        XCTAssertFalse(Config().phoneApp)
        XCTAssertEqual(Config().phonePort, 7788)
        let c = makeController(home: home, interfaces: [])
        c.apply(Config())
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(c.enabled)
        XCTAssertTrue(c.server.addresses.isEmpty)
        XCTAssertNil(c.menuLine)
        XCTAssertEqual(c.statusLine, "Off")
    }

    func testWithoutTailscaleItServesLoopbackOnlyAndSaysSo() async throws {
        let home = TempHome()
        defer { home.destroy() }
        // A LAN address and a carrier NAT address on Wi-Fi: neither is bound.
        let c = makeController(home: home, interfaces: [
            InterfaceAddress(interface: "en0", address: "192.168.1.20", isIPv6: false),
            InterfaceAddress(interface: "en0", address: "100.70.0.3", isIPv6: false),
        ])
        var config = Config()
        config.phoneApp = true
        config.phonePort = 33000 + Int.random(in: 0..<2000)
        c.apply(config)
        defer { c.apply(Config()) }
        try await waitUntil { c.listening == ["127.0.0.1"] }
        XCTAssertEqual(c.server.addresses, ["127.0.0.1"])
        XCTAssertEqual(c.listening, ["127.0.0.1"])
        XCTAssertTrue(c.statusLine.hasPrefix("Tailscale not found"), c.statusLine)
        XCTAssertEqual(c.menuLine?.text, "Phone app: Tailscale not found")
        XCTAssertEqual(c.primaryURL, "http://127.0.0.1:\(config.phonePort)")
        XCTAssertTrue(c.phoneURLs.isEmpty)
        XCTAssertEqual(c.pairingURL(code: "123456"), "http://127.0.0.1:\(config.phonePort)/#pair=123456")

        // The server answers, and turning the setting off closes it.
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(config.phonePort)/")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("<title>Awake</title>"))
        c.auth.beginPairing()
        c.apply(Config())
        XCTAssertFalse(c.enabled)
        XCTAssertTrue(c.server.addresses.isEmpty)
        XCTAssertNil(c.auth.pairingWindow, "turning the phone app off closes an open pairing window")
    }

    func testTailscaleAndServeGiveTheHTTPSAddressFirst() async throws {
        let home = TempHome()
        defer { home.destroy() }
        let shell = FakePhoneShell()
        shell.executables = ["/usr/local/bin/tailscale"]
        shell.outputs["status --json"] = ShellResult(status: 0, stdout: "{\"BackendState\":\"Running\",\"Self\":{\"DNSName\":\"mac.tail1234.ts.net.\"}}", stderr: "")
        shell.outputs["serve status --json"] = ShellResult(status: 0, stdout: "{\"TCP\":{\"443\":{\"HTTPS\":true}},\"Web\":{\"mac.tail1234.ts.net:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:7788\"}}}}}", stderr: "")
        // Not enabled, so nothing is bound: the test machine has no such
        // address. The lines and addresses are still worked out.
        let c = makeController(home: home, interfaces: [InterfaceAddress(interface: "utun4", address: "100.101.102.103", isIPv6: false)], shell: shell)
        await c.refresh()
        XCTAssertEqual(c.tailscale.ipv4, "100.101.102.103")
        XCTAssertEqual(c.serve.httpsURL, "https://mac.tail1234.ts.net")
        XCTAssertEqual(c.phoneURLs, ["https://mac.tail1234.ts.net", "http://mac.tail1234.ts.net:7788", "http://100.101.102.103:7788"])
        XCTAssertEqual(c.primaryURL, "https://mac.tail1234.ts.net")
        XCTAssertEqual(c.pairingURL(code: "042137"), "https://mac.tail1234.ts.net/#pair=042137")
        XCTAssertTrue(c.server.addresses.isEmpty)
    }

    func testForgettingADeviceWhileRunningLocksItOut() async throws {
        let home = TempHome()
        defer { home.destroy() }
        let c = makeController(home: home, interfaces: [])
        var config = Config()
        config.phoneApp = true
        config.phonePort = 35000 + Int.random(in: 0..<2000)
        c.apply(config)
        defer { c.apply(Config()) }
        try await waitUntil { c.listening == ["127.0.0.1"] }
        let window = c.auth.beginPairing()
        guard case let .paired(token, device) = await c.auth.pair(code: window.code, name: "iPhone") else { return XCTFail("not paired") }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(config.phonePort)/api/status")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, ok) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((ok as? HTTPURLResponse)?.statusCode, 200)
        await c.auth.forget(id: device.id)
        let (_, gone) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((gone as? HTTPURLResponse)?.statusCode, 401)
    }
}

final class PhoneLogTailTests: XCTestCase {
    func testReturnsTheLastLines() throws {
        let home = TempHome()
        defer { home.destroy() }
        let url = home.root.appendingPathComponent("x.log")
        try (1...500).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(PhoneLogTail.lines(3, of: url), ["line 498", "line 499", "line 500"])
        XCTAssertEqual(PhoneLogTail.lines(1000, of: url).count, 500)
        XCTAssertEqual(PhoneLogTail.lines(0, of: url), [])
        XCTAssertEqual(PhoneLogTail.lines(5, of: home.root.appendingPathComponent("missing.log")), [])
    }

    func testABigLogIsReadFromItsEndWithoutAFragment() throws {
        let home = TempHome()
        defer { home.destroy() }
        let url = home.root.appendingPathComponent("big.log")
        let line = String(repeating: "x", count: 99)
        let count = (PhoneLogTail.maxBytes / 100) * 2
        try (1...count).map { _ in line }.joined(separator: "\n").appending("\nlast\n").write(to: url, atomically: true, encoding: .utf8)
        let lines = PhoneLogTail.lines(1000, of: url)
        XCTAssertEqual(lines.count, 1000)
        XCTAssertEqual(lines.last, "last")
        XCTAssertTrue(lines.dropLast().allSatisfy { $0 == line }, "no half line from the middle of the file")
    }
}

final class PhoneMachineTests: XCTestCase {
    func testMemoryPressureLevels() {
        XCTAssertEqual(LivePhoneMachine.memoryPressure(level: 1), "normal")
        XCTAssertEqual(LivePhoneMachine.memoryPressure(level: 2), "warning")
        XCTAssertEqual(LivePhoneMachine.memoryPressure(level: 4), "critical")
        XCTAssertNil(LivePhoneMachine.memoryPressure(level: nil))
        XCTAssertNil(LivePhoneMachine.memoryPressure(level: 3), "a level this build does not know is unknown, not normal")
    }

    func testNetworkTypes() {
        XCTAssertEqual(LivePhoneMachine.networkType(satisfied: false, wifi: true, wired: false, cellular: false), "none")
        XCTAssertEqual(LivePhoneMachine.networkType(satisfied: true, wifi: true, wired: false, cellular: false), "wifi")
        XCTAssertEqual(LivePhoneMachine.networkType(satisfied: true, wifi: true, wired: true, cellular: false), "wired")
        XCTAssertEqual(LivePhoneMachine.networkType(satisfied: true, wifi: false, wired: false, cellular: true), "cellular")
        XCTAssertEqual(LivePhoneMachine.networkType(satisfied: true, wifi: false, wired: false, cellular: false), "other")
    }

    func testScreenshotSizes() {
        var s = ScreenCaptureKitCapture.outputSize(width: 1512, height: 982, maxWidth: 1280)
        XCTAssertEqual(s.width, 1280)
        XCTAssertEqual(s.height, 830)
        s = ScreenCaptureKitCapture.outputSize(width: 1512, height: 982, maxWidth: 2560)
        XCTAssertEqual(s.width, 1512, "never enlarged")
        XCTAssertEqual(s.height, 982)
        s = ScreenCaptureKitCapture.outputSize(width: 0, height: 0, maxWidth: 1280)
        XCTAssertEqual(s.width, 2)
    }

    func testEndOutcomesAreSaidPlainly() {
        XCTAssertTrue(LivePhoneSession.describe(.restored).ok)
        for outcome in [EndOutcome.incomplete(agentArmed: true), .incomplete(agentArmed: false), .locked, .sessionRetained, .journalUnreadable, .privilegedCommandRunning(pid: 1)] {
            let r = LivePhoneSession.describe(outcome)
            XCTAssertFalse(r.ok, "\(outcome)")
            XCTAssertFalse(r.message.isEmpty)
        }
        XCTAssertEqual(LivePhoneSession.duration(30), "30 min")
        XCTAssertEqual(LivePhoneSession.duration(120), "2 h")
        XCTAssertEqual(LivePhoneSession.duration(90), "1 h 30 min")
    }
}
