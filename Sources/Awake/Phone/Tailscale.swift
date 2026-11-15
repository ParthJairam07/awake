import Foundation

/// One address of one network interface, as `getifaddrs` reports it.
struct InterfaceAddress: Equatable, Sendable {
    var interface: String
    /// Numeric form, without a scope: `100.101.102.103`, `fd7a:115c:a1e0::1`.
    var address: String
    var isIPv6: Bool
}

enum NetworkInterfaces {
    typealias Reader = @Sendable () -> [InterfaceAddress]

    /// Every IPv4 and IPv6 address of every interface that is up.
    static func current() -> [InterfaceAddress] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var out: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let sa = entry.pointee.ifa_addr, (Int32(entry.pointee.ifa_flags) & IFF_UP) != 0 else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if let scope = address.firstIndex(of: "%") { address = String(address[..<scope]) }
            out.append(InterfaceAddress(interface: String(cString: entry.pointee.ifa_name), address: address, isIPv6: family == AF_INET6))
        }
        return out
    }
}

/// Phase 3: the phone reaches the Mac over Tailscale, so the phone server
/// binds only to the Mac's tailnet address (and loopback). Tailscale's
/// addresses are recognisable without asking it anything: its tunnel is a
/// `utun` interface carrying an address in 100.64.0.0/10 (the CGNAT range
/// Tailscale assigns from) and one in fd7a:115c:a1e0::/48.
enum Tailscale {
    struct Addresses: Equatable, Sendable {
        var ipv4: String?
        var ipv6: String?

        static let none = Addresses()
        var found: Bool { ipv4 != nil }
    }

    /// The tailnet addresses among `interfaces`. An IPv6 address counts
    /// only on a `utun` that also carries the IPv4 one, so another VPN's
    /// tunnel is never taken for the tailnet.
    static func addresses(in interfaces: [InterfaceAddress]) -> Addresses {
        guard let v4 = interfaces.first(where: { !$0.isIPv6 && $0.interface.hasPrefix("utun") && isCGNAT($0.address) }) else {
            return .none
        }
        let v6 = interfaces.first { $0.isIPv6 && $0.interface == v4.interface && isTailscaleULA($0.address) }
        return Addresses(ipv4: v4.address, ipv6: v6?.address)
    }

    /// 100.64.0.0/10: first octet 100, second 64...127.
    static func isCGNAT(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] == 100 && (64...127).contains(octets[1])
    }

    /// fd7a:115c:a1e0::/48.
    static func isTailscaleULA(_ address: String) -> Bool {
        address.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }
}

/// Runs the `tailscale` command line. Tests script the output; the app
/// uses `Shell` with a timeout.
protocol PhoneShellRunning: Sendable {
    /// nil when the program could not be run or did not finish in time.
    func run(_ exe: String, _ args: [String]) async -> ShellResult?
    func isExecutable(_ path: String) -> Bool
}

struct LivePhoneShell: PhoneShellRunning {
    static let timeout: TimeInterval = 5

    func run(_ exe: String, _ args: [String]) async -> ShellResult? {
        try? await Shell.run(exe, args, timeout: Self.timeout)
    }

    func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

/// What `tailscale status --json` and `tailscale serve status --json` say,
/// reduced to what Settings shows.
struct TailscaleServeStatus: Equatable, Sendable {
    /// The CLI was found.
    var cliFound = false
    /// `BackendState` is `Running`.
    var running = false
    /// The Mac's MagicDNS name without the trailing dot.
    var dnsName: String?
    /// `https://<name>` when `tailscale serve` proxies to the phone port.
    var httpsURL: String?

    static let unknown = TailscaleServeStatus()
}

enum TailscaleCLI {
    /// Where the three Tailscale installs put the command line: the
    /// Homebrew formula, the standalone app's "Install CLI", and the app
    /// itself, whose executable is the CLI when run with arguments (the
    /// Mac App Store build has no other).
    static let candidates = [
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// The exact command the docs and Settings give the user.
    static func serveCommand(port: Int) -> String {
        "tailscale serve --bg \(port)"
    }

    static func locate(_ shell: any PhoneShellRunning) -> String? {
        candidates.first { shell.isExecutable($0) }
    }

    static func read(port: Int, shell: any PhoneShellRunning) async -> TailscaleServeStatus {
        guard let exe = locate(shell) else { return .unknown }
        var out = TailscaleServeStatus(cliFound: true)
        if let status = await shell.run(exe, ["status", "--json"]), status.succeeded {
            let parsed = parseStatus(status.stdout)
            out.running = parsed.running
            out.dnsName = parsed.dnsName
        }
        guard out.running else { return out }
        if let serve = await shell.run(exe, ["serve", "status", "--json"]), serve.succeeded {
            out.httpsURL = httpsURL(fromServeStatus: serve.stdout, port: port)
        }
        return out
    }

    /// `BackendState` and `Self.DNSName` of `tailscale status --json`.
    static func parseStatus(_ json: String) -> (running: Bool, dnsName: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return (false, nil) }
        let running = (object["BackendState"] as? String) == "Running"
        var name = (object["Self"] as? [String: Any])?["DNSName"] as? String
        while name?.hasSuffix(".") == true { name?.removeLast() }
        if name?.isEmpty == true { name = nil }
        return (running, name)
    }

    /// The HTTPS address `tailscale serve` gives the phone port, from
    /// `tailscale serve status --json` (Tailscale's ServeConfig):
    ///
    ///     {"TCP": {"443": {"HTTPS": true}},
    ///      "Web": {"mac.tail1234.ts.net:443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:7788"}}}}}
    ///
    /// Only a handler at `/` that proxies to this Mac's `port`, on a TCP
    /// port marked HTTPS, counts. nil when nothing is served (the command
    /// prints `{}`) or the proxy points elsewhere.
    static func httpsURL(fromServeStatus json: String, port: Int) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let web = object["Web"] as? [String: Any] else { return nil }
        let tcp = object["TCP"] as? [String: Any] ?? [:]
        for hostPort in web.keys.sorted() {
            guard let handlers = (web[hostPort] as? [String: Any])?["Handlers"] as? [String: Any],
                  let root = handlers["/"] as? [String: Any],
                  let proxy = root["Proxy"] as? String,
                  proxies(proxy, toLocalPort: port) else { continue }
            guard let colon = hostPort.lastIndex(of: ":") else { continue }
            let host = String(hostPort[..<colon])
            let servedPort = String(hostPort[hostPort.index(after: colon)...])
            guard !host.isEmpty, (tcp[servedPort] as? [String: Any])?["HTTPS"] as? Bool == true else { continue }
            return servedPort == "443" ? "https://\(host)" : "https://\(host):\(servedPort)"
        }
        return nil
    }

    /// `http://127.0.0.1:7788`, `http://localhost:7788`, `127.0.0.1:7788`
    /// or the bare port, as `tailscale serve` records its target.
    static func proxies(_ proxy: String, toLocalPort port: Int) -> Bool {
        var target = proxy.trimmingCharacters(in: .whitespaces)
        if target == "\(port)" { return true }
        if target.hasPrefix("https://") { return false }
        if target.hasPrefix("http://") { target.removeFirst("http://".count) }
        if let slash = target.firstIndex(of: "/") { target = String(target[..<slash]) }
        return ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(target)
    }
}
