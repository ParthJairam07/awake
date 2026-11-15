import AppKit
import Foundation
import Observation

/// Phase 3: the phone app as the rest of Awake sees it. Owns the server,
/// the paired phones and the API, follows `Config.phoneApp` and
/// `Config.phonePort`, and keeps the listeners on the Mac's Tailscale
/// address as it comes and goes. Settings and the menu read their lines
/// from here.
@MainActor
@Observable
final class PhoneAppController {
    let auth: PhoneAuth
    @ObservationIgnored let api: PhoneAPI
    @ObservationIgnored let server = PhoneServer()
    @ObservationIgnored let paths: Paths

    /// The server is meant to be running (the setting is on).
    private(set) var enabled = false
    private(set) var port = Config().phonePort
    /// Addresses with a listener that is ready, loopback first.
    private(set) var listening: [String] = []
    /// Why a listener could not start, per address.
    private(set) var problems: [String] = []
    private(set) var tailscale = Tailscale.Addresses.none
    private(set) var serve = TailscaleServeStatus.unknown
    private(set) var screenRecordingGranted = false

    @ObservationIgnored private let interfaces: NetworkInterfaces.Reader
    @ObservationIgnored private let shell: any PhoneShellRunning
    @ObservationIgnored private let screen: any ScreenCapturing
    @ObservationIgnored private let refreshStatus: @MainActor () -> Void
    @ObservationIgnored private var interfaceTimer: (any DispatchSourceTimer)?
    @ObservationIgnored private var statusTimer: (any DispatchSourceTimer)?
    @ObservationIgnored private var lastStatus: Data?
    @ObservationIgnored private var serveTask: Task<Void, Never>?

    /// How often the interfaces are re-read while the server runs, so the
    /// tailnet listener follows Tailscale connecting and disconnecting.
    static let interfaceInterval: TimeInterval = 30
    /// How often the status is compared while a phone has the event
    /// stream open. Nothing is polled when no phone is watching.
    static let statusInterval: TimeInterval = 5

    /// What the phone may do to agents. Phase 2 sets its registry here.
    var agentActions: any AgentActing {
        get { api.agents }
        set { api.agents = newValue }
    }

    init(
        paths: Paths,
        session: any PhoneSessionControlling,
        locker: any ScreenLocking,
        machine: any PhoneMachineProbing,
        screen: any ScreenCapturing = ScreenCaptureKitCapture(),
        deviceStore: any PhoneDeviceStoring = KeychainPhoneDeviceStore(),
        interfaces: @escaping NetworkInterfaces.Reader = { NetworkInterfaces.current() },
        shell: any PhoneShellRunning = LivePhoneShell(),
        refreshStatus: @escaping @MainActor () -> Void = {}
    ) {
        self.paths = paths
        self.interfaces = interfaces
        self.shell = shell
        self.screen = screen
        self.refreshStatus = refreshStatus
        let auth = PhoneAuth(store: deviceStore)
        self.auth = auth
        let logFile = paths.logFile
        api = PhoneAPI(
            auth: auth,
            session: session,
            locker: locker,
            screen: screen,
            machine: machine,
            audit: PhoneAuditLog(url: paths.auditLog),
            logTail: { PhoneLogTail.lines($0, of: logFile) }
        )
        api.serverInfoProvider = { [weak self] in self?.serverInfo() ?? [:] }
        api.onChange = { [weak self] in self?.pushStatus(force: true) }
        server.setHandler { [api] request, peer in await api.handle(request, peer: peer) }
        server.initialEvent = { [weak self] deviceID in
            guard let self, let device = self.auth.devices.first(where: { $0.id == deviceID }) else { return nil }
            return self.api.statusBody(device: device)
        }
        server.onStateChange = { [weak self] in self?.listenersChanged() }
        server.onEventClientsChanged = { [weak self] count in self?.eventClientsChanged(count) }
        auth.onRevoked = { [weak self] ids in self?.server.closeEventStreams(of: ids) }
    }

    // MARK: Following the settings

    /// Starts, stops or moves the server to match the settings.
    func apply(_ config: Config) {
        let wantedPort = Self.validPort(config.phonePort) ? config.phonePort : Config().phonePort
        guard config.phoneApp else {
            if enabled { Log.info("phone app off") }
            enabled = false
            port = wantedPort
            stopTimers()
            server.stop()
            auth.cancelPairing()
            return
        }
        let starting = !enabled || port != wantedPort
        enabled = true
        port = wantedPort
        if starting {
            Task { [weak self] in
                guard let self else { return }
                if !self.auth.loaded { await self.auth.load() }
                guard self.enabled else { return }
                self.bind()
                self.startInterfaceTimer()
                await self.refresh()
            }
        }
    }

    nonisolated static func validPort(_ port: Int) -> Bool { (1024...65535).contains(port) }

    /// Re-reads the interfaces and listens on loopback plus the tailnet
    /// addresses, and nothing else.
    private func bind() {
        guard enabled else { return }
        tailscale = Tailscale.addresses(in: interfaces())
        server.listen(port: port, addresses: Self.bindAddresses(tailscale))
    }

    nonisolated static func bindAddresses(_ tailscale: Tailscale.Addresses) -> Set<String> {
        var out: Set<String> = [PhoneServer.loopback]
        if let v4 = tailscale.ipv4 { out.insert(v4) }
        if let v6 = tailscale.ipv6 { out.insert(v6) }
        return out
    }

    /// Everything Settings shows, read again: the interfaces, whether
    /// `tailscale serve` fronts the port, and the Screen Recording grant.
    func refresh() async {
        screenRecordingGranted = screen.permissionGranted()
        let before = tailscale
        if enabled { bind() } else { tailscale = Tailscale.addresses(in: interfaces()) }
        _ = before
        let port = self.port
        let shell = self.shell
        serve = await TailscaleCLI.read(port: port, shell: shell)
    }

    private func listenersChanged() {
        listening = server.ready.sorted { a, b in
            if a == PhoneServer.loopback { return true }
            if b == PhoneServer.loopback { return false }
            return a < b
        }
        problems = server.failures.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    }

    private func startInterfaceTimer() {
        guard interfaceTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.interfaceInterval, repeating: Self.interfaceInterval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.enabled else { return }
                let before = self.tailscale
                self.bind()
                // Tailscale came or went: what `tailscale serve` says may
                // have changed with it.
                if before != self.tailscale {
                    self.serveTask?.cancel()
                    self.serveTask = Task { [weak self] in await self?.refresh() }
                }
            }
        }
        timer.resume()
        interfaceTimer = timer
    }

    private func stopTimers() {
        interfaceTimer?.cancel()
        interfaceTimer = nil
        statusTimer?.cancel()
        statusTimer = nil
        serveTask?.cancel()
        serveTask = nil
        lastStatus = nil
    }

    // MARK: Events

    private func eventClientsChanged(_ count: Int) {
        if count == 0 {
            statusTimer?.cancel()
            statusTimer = nil
            lastStatus = nil
            return
        }
        guard statusTimer == nil else { return }
        lastStatus = Self.comparable(api.statusBody())
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.statusInterval, repeating: Self.statusInterval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.pushStatus(force: false) }
        }
        timer.resume()
        statusTimer = timer
    }

    /// Sends the status to every open stream if it changed since the last
    /// one sent (or `force`). The battery and the lid are read first:
    /// outside a session nothing else keeps them fresh.
    func pushStatus(force: Bool) {
        guard server.eventClientCount > 0 else { return }
        if !force { refreshStatus() }
        let now = Self.comparable(api.statusBody())
        guard force || now != lastStatus else { return }
        lastStatus = now
        let devices = Dictionary(auth.devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        server.broadcast(event: "status") { id in
            devices[id].map { self.api.statusBody(device: $0) }
        }
    }

    /// The status without the fields that change every second, so only a
    /// real change is pushed. The phone counts the time down itself.
    nonisolated static func comparable(_ body: Data) -> Data {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return body }
        if var status = object["status"] as? [String: Any] {
            status["updatedAt"] = nil
            status["remainingSeconds"] = nil
            object["status"] = status
        }
        if var server = object["server"] as? [String: Any] {
            server["time"] = nil
            object["server"] = server
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? body
    }

    // MARK: What Settings, the menu and the phone are told

    private func serverInfo() -> [String: Any] {
        var info: [String: Any] = [
            "name": LivePhoneMachine.computerName() ?? "Mac",
            "version": AppBuild.current.label,
            "port": port,
            "https": serve.httpsURL != nil,
            "screenRecording": screen.permissionGranted(),
        ]
        if let v4 = tailscale.ipv4 { info["tailscaleIPv4"] = v4 }
        if let url = serve.httpsURL { info["httpsURL"] = url }
        return info
    }

    /// The addresses the phone can open, best first: the HTTPS one from
    /// `tailscale serve`, the MagicDNS name, the tailnet IP.
    var phoneURLs: [String] {
        var out: [String] = []
        if let https = serve.httpsURL { out.append(https) }
        guard tailscale.found else { return out }
        if let name = serve.dnsName { out.append("http://\(name):\(port)") }
        if let v4 = tailscale.ipv4 { out.append(PhoneServer.url(address: v4, port: port)) }
        return out
    }

    /// The address shown and encoded in the QR code: the best tailnet one,
    /// or this Mac's loopback when Tailscale was not found.
    var primaryURL: String {
        phoneURLs.first ?? loopbackURL
    }

    var loopbackURL: String { PhoneServer.url(address: PhoneServer.loopback, port: port) }

    /// The address with the pairing code in the fragment, which browsers
    /// do not send to any server or keep in a referrer.
    func pairingURL(code: String) -> String {
        "\(primaryURL)/#pair=\(code)"
    }

    nonisolated static let tailscaleNotFound = "Tailscale not found"

    /// One line on where the server is reachable.
    var statusLine: String {
        Self.statusLine(enabled: enabled, listening: listening, problems: problems, tailscale: tailscale, port: port)
    }

    nonisolated static func statusLine(enabled: Bool, listening: [String], problems: [String], tailscale: Tailscale.Addresses, port: Int) -> String {
        guard enabled else { return "Off" }
        guard !listening.isEmpty else {
            return problems.isEmpty ? "Starting on port \(port)\u{2026}" : "Not listening on port \(port): \(problems.joined(separator: "; "))"
        }
        guard let v4 = tailscale.ipv4 else {
            return "\(tailscaleNotFound): serving this Mac only, on \(PhoneServer.url(address: PhoneServer.loopback, port: port))"
        }
        guard listening.contains(v4) else {
            return "Tailscale address \(v4) found, but the listener on it is not up yet"
        }
        return "Serving the tailnet on \(PhoneServer.url(address: v4, port: port))"
    }

    /// The right-click menu's line: nil while the phone app is off.
    var menuLine: (text: String, isWarning: Bool)? {
        Self.menuLine(enabled: enabled, listening: listening, tailscale: tailscale, paired: auth.devices.count, pairingCode: auth.pairingWindow?.code)
    }

    nonisolated static func menuLine(enabled: Bool, listening: [String], tailscale: Tailscale.Addresses, paired: Int, pairingCode: String?) -> (text: String, isWarning: Bool)? {
        guard enabled else { return nil }
        if let pairingCode { return ("Phone app: pairing code \(pairingCode)", false) }
        guard !listening.isEmpty else { return ("Phone app: not listening", true) }
        guard tailscale.found else { return ("Phone app: \(tailscaleNotFound)", true) }
        return ("Phone app: \(paired == 0 ? "no phone paired" : paired == 1 ? "1 phone paired" : "\(paired) phones paired")", false)
    }

    // MARK: Screen Recording

    /// Asks macOS for the Screen Recording permission (it shows its prompt
    /// once per build) and re-reads the grant.
    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        screenRecordingGranted = screen.permissionGranted()
    }

    static let screenRecordingPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    func openScreenRecordingPane() {
        NSWorkspace.shared.open(Self.screenRecordingPane)
    }

    func revealAuditLog() {
        let url = paths.auditLog
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([paths.appSupport])
        }
    }
}

/// The last lines of awake.log for the phone's Log tab.
enum PhoneLogTail {
    /// Reads at most this much of the end of the file.
    static let maxBytes = 512 * 1024

    static func lines(_ count: Int, of url: URL) -> [String] {
        guard count > 0, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        var lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        // The first line of a read that began mid-file is a fragment.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return Array(lines.suffix(count))
    }
}
