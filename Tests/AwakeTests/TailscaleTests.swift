import XCTest
@testable import Awake

final class FakePhoneShell: PhoneShellRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var executables: Set<String> = []
    /// Output by the arguments joined with spaces; a missing entry is a
    /// program that could not be run.
    var outputs: [String: ShellResult] = [:]
    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ exe: String, _ args: [String]) async -> ShellResult? {
        lock.withLock { _calls.append([exe] + args) }
        return outputs[args.joined(separator: " ")]
    }

    func isExecutable(_ path: String) -> Bool { executables.contains(path) }
}

final class TailscaleAddressTests: XCTestCase {
    func testCGNATRange() {
        for ok in ["100.64.0.1", "100.100.100.100", "100.127.255.254", "100.101.102.103"] {
            XCTAssertTrue(Tailscale.isCGNAT(ok), ok)
        }
        for no in ["100.63.255.255", "100.128.0.1", "10.0.0.1", "192.168.1.5", "127.0.0.1", "101.64.0.1", "100.64.0", "100.64.0.1.2", "100.64.0.256", "fd7a:115c:a1e0::1", "", "100.64.a.1"] {
            XCTAssertFalse(Tailscale.isCGNAT(no), no)
        }
    }

    func testFindsTheTailnetAddressOnAUtunInterface() {
        let interfaces = [
            InterfaceAddress(interface: "lo0", address: "127.0.0.1", isIPv6: false),
            InterfaceAddress(interface: "en0", address: "192.168.1.20", isIPv6: false),
            InterfaceAddress(interface: "utun2", address: "fe80::1", isIPv6: true),
            InterfaceAddress(interface: "utun4", address: "100.101.102.103", isIPv6: false),
            InterfaceAddress(interface: "utun4", address: "fd7a:115c:a1e0::abcd", isIPv6: true),
        ]
        XCTAssertEqual(Tailscale.addresses(in: interfaces), Tailscale.Addresses(ipv4: "100.101.102.103", ipv6: "fd7a:115c:a1e0::abcd"))
    }

    func testACGNATAddressOffAUtunIsNotTailscale() {
        // A carrier-grade NAT address on Wi-Fi or Ethernet is the ISP's, not
        // the tailnet's: binding to it would serve the local network.
        let interfaces = [
            InterfaceAddress(interface: "en0", address: "100.70.1.2", isIPv6: false),
            InterfaceAddress(interface: "bridge0", address: "100.64.0.1", isIPv6: false),
        ]
        XCTAssertEqual(Tailscale.addresses(in: interfaces), .none)
        XCTAssertFalse(Tailscale.addresses(in: interfaces).found)
    }

    func testAnotherVPNsTunnelIsNotTailscale() {
        let interfaces = [
            InterfaceAddress(interface: "utun3", address: "10.8.0.2", isIPv6: false),
            InterfaceAddress(interface: "utun3", address: "fd7a:115c:a1e0::1", isIPv6: true),
        ]
        XCTAssertEqual(Tailscale.addresses(in: interfaces), .none, "an IPv6 address alone never counts")
    }

    func testIPv6OnADifferentTunnelIsNotPaired() {
        let interfaces = [
            InterfaceAddress(interface: "utun4", address: "100.101.102.103", isIPv6: false),
            InterfaceAddress(interface: "utun5", address: "fd7a:115c:a1e0::abcd", isIPv6: true),
        ]
        XCTAssertEqual(Tailscale.addresses(in: interfaces), Tailscale.Addresses(ipv4: "100.101.102.103", ipv6: nil))
    }

    func testBindAddressesAreLoopbackPlusTheTailnetOnly() {
        XCTAssertEqual(PhoneAppController.bindAddresses(.none), ["127.0.0.1"])
        XCTAssertEqual(PhoneAppController.bindAddresses(Tailscale.Addresses(ipv4: "100.101.102.103", ipv6: "fd7a:115c:a1e0::abcd")), ["127.0.0.1", "100.101.102.103", "fd7a:115c:a1e0::abcd"])
    }

    func testTheRealInterfaceListIsReadable() {
        let all = NetworkInterfaces.current()
        XCTAssertTrue(all.contains { $0.address == "127.0.0.1" && !$0.isIPv6 }, "loopback is always up: \(all)")
        XCTAssertFalse(all.contains { $0.address.contains("%") }, "scopes are stripped")
    }
}

final class TailscaleCLITests: XCTestCase {
    private let statusJSON = """
    {"Version":"1.80.0","BackendState":"Running","TailscaleIPs":["100.101.102.103","fd7a:115c:a1e0::abcd"],
     "Self":{"HostName":"mac","DNSName":"mac.tail1234.ts.net.","Online":true}}
    """
    private let serveJSON = """
    {"TCP":{"443":{"HTTPS":true}},
     "Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7788"}}}}}
    """

    func testParsesStatus() {
        let s = TailscaleCLI.parseStatus(statusJSON)
        XCTAssertTrue(s.running)
        XCTAssertEqual(s.dnsName, "mac.tail1234.ts.net")
        XCTAssertFalse(TailscaleCLI.parseStatus("{\"BackendState\":\"NeedsLogin\",\"Self\":{\"DNSName\":\"\"}}").running)
        XCTAssertNil(TailscaleCLI.parseStatus("{\"BackendState\":\"Stopped\",\"Self\":{\"DNSName\":\"\"}}").dnsName)
        XCTAssertFalse(TailscaleCLI.parseStatus("garbage").running)
    }

    func testServeStatusGivesTheHTTPSAddressForThisPort() {
        XCTAssertEqual(TailscaleCLI.httpsURL(fromServeStatus: serveJSON, port: 7788), "https://mac.tail1234.ts.net")
        XCTAssertNil(TailscaleCLI.httpsURL(fromServeStatus: serveJSON, port: 7789), "a proxy to another port is not ours")
        XCTAssertNil(TailscaleCLI.httpsURL(fromServeStatus: "{}", port: 7788), "nothing served")
        XCTAssertNil(TailscaleCLI.httpsURL(fromServeStatus: "", port: 7788))
    }

    func testServeOnAnotherTCPPortKeepsThePort() {
        let json = """
        {"TCP":{"8443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://localhost:7788"}}}}}
        """
        XCTAssertEqual(TailscaleCLI.httpsURL(fromServeStatus: json, port: 7788), "https://mac.tail1234.ts.net:8443")
    }

    func testServeThatIsNotHTTPSOrNotAtTheRootDoesNotCount() {
        let plain = """
        {"TCP":{"80":{"HTTP":true}},"Web":{"mac.tail1234.ts.net:80":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:7788"}}}}}
        """
        XCTAssertNil(TailscaleCLI.httpsURL(fromServeStatus: plain, port: 7788))
        let subpath = """
        {"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/awake":{"Proxy":"http://127.0.0.1:7788"}}}}}
        """
        XCTAssertNil(TailscaleCLI.httpsURL(fromServeStatus: subpath, port: 7788), "the web app is served from the root")
        let text = """
        {"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail1234.ts.net:443":{"Handlers":{"/":{"Text":"hi"}}}}}
        """
        XCTAssertNil(TailscaleCLI.httpsURL(fromServeStatus: text, port: 7788))
    }

    func testProxyTargets() {
        for ok in ["http://127.0.0.1:7788", "http://localhost:7788", "127.0.0.1:7788", "7788", "http://127.0.0.1:7788/", "http://[::1]:7788"] {
            XCTAssertTrue(TailscaleCLI.proxies(ok, toLocalPort: 7788), ok)
        }
        for no in ["http://127.0.0.1:77880", "http://10.0.0.5:7788", "https://127.0.0.1:7788", "http://127.0.0.1:778", "", "http://example.com:7788"] {
            XCTAssertFalse(TailscaleCLI.proxies(no, toLocalPort: 7788), no)
        }
    }

    func testReadAsksTheCLIFoundAndReportsServe() async {
        let shell = FakePhoneShell()
        shell.executables = ["/usr/local/bin/tailscale"]
        shell.outputs["status --json"] = ShellResult(status: 0, stdout: statusJSON, stderr: "")
        shell.outputs["serve status --json"] = ShellResult(status: 0, stdout: serveJSON, stderr: "")
        let s = await TailscaleCLI.read(port: 7788, shell: shell)
        XCTAssertEqual(s, TailscaleServeStatus(cliFound: true, running: true, dnsName: "mac.tail1234.ts.net", httpsURL: "https://mac.tail1234.ts.net"))
        XCTAssertEqual(shell.calls, [["/usr/local/bin/tailscale", "status", "--json"], ["/usr/local/bin/tailscale", "serve", "status", "--json"]])
    }

    func testNoCLIRunsNothing() async {
        let shell = FakePhoneShell()
        let s = await TailscaleCLI.read(port: 7788, shell: shell)
        XCTAssertEqual(s, .unknown)
        XCTAssertFalse(s.cliFound)
        XCTAssertTrue(shell.calls.isEmpty)
    }

    func testAStoppedTailscaleIsNotAskedAboutServe() async {
        let shell = FakePhoneShell()
        shell.executables = ["/opt/homebrew/bin/tailscale"]
        shell.outputs["status --json"] = ShellResult(status: 0, stdout: "{\"BackendState\":\"Stopped\"}", stderr: "")
        let s = await TailscaleCLI.read(port: 7788, shell: shell)
        XCTAssertEqual(s, TailscaleServeStatus(cliFound: true, running: false, dnsName: nil, httpsURL: nil))
        XCTAssertEqual(shell.calls.count, 1)
    }

    func testAFailingCLIIsUnknownNotRunning() async {
        let shell = FakePhoneShell()
        shell.executables = ["/opt/homebrew/bin/tailscale"]
        shell.outputs["status --json"] = ShellResult(status: 1, stdout: "", stderr: "failed to connect to local Tailscale service")
        let s = await TailscaleCLI.read(port: 7788, shell: shell)
        XCTAssertTrue(s.cliFound)
        XCTAssertFalse(s.running)
        XCTAssertNil(s.httpsURL)
    }

    func testTheServeCommandIsTheDocumentedOne() {
        XCTAssertEqual(TailscaleCLI.serveCommand(port: 7788), "tailscale serve --bg 7788")
    }
}
