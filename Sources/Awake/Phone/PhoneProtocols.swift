import Foundation

/// What an action asked from the phone came to: whether it happened, and
/// one sentence for the phone to show.
struct PhoneActionResult: Equatable, Sendable {
    var ok: Bool
    var message: String

    static func done(_ message: String) -> PhoneActionResult { PhoneActionResult(ok: true, message: message) }
    static func failed(_ message: String) -> PhoneActionResult { PhoneActionResult(ok: false, message: message) }
}

/// The session as the phone API sees it. The app adapts `SessionManager`;
/// tests script it.
@MainActor
protocol PhoneSessionControlling: AnyObject {
    /// The `StatusSnapshot` as JSON, exactly as status.json has it.
    func statusJSON() -> Data
    /// The Settings presets, in minutes, for the phone's Start buttons.
    var presetMinutes: [Int] { get }
    /// The longest session Settings allows, in minutes.
    var maxMinutes: Int { get }
    func start(minutes: Int) async -> PhoneActionResult
    func extend(minutes: Int) async -> PhoneActionResult
    /// Ends the session and undoes everything it changed, frozen apps
    /// included.
    func end() async -> PhoneActionResult
}

/// What the phone may do to an agent. Phase 2's registry implements this;
/// until it is wired in, `UnavailableAgentActions` answers every call.
@MainActor
protocol AgentActing: AnyObject {
    /// Whether the actions do anything; the phone hides the buttons when not.
    var available: Bool { get }
    func nudge(id: String) async -> PhoneActionResult
    func answer(id: String, text: String) async -> PhoneActionResult
    func pause(id: String) async -> PhoneActionResult
    func resume(id: String) async -> PhoneActionResult
    func stop(id: String) async -> PhoneActionResult
}

@MainActor
final class UnavailableAgentActions: AgentActing {
    static let message = "not available yet"
    let available = false

    func nudge(id: String) async -> PhoneActionResult { .failed(Self.message) }
    func answer(id: String, text: String) async -> PhoneActionResult { .failed(Self.message) }
    func pause(id: String) async -> PhoneActionResult { .failed(Self.message) }
    func resume(id: String) async -> PhoneActionResult { .failed(Self.message) }
    func stop(id: String) async -> PhoneActionResult { .failed(Self.message) }
}

enum AgentAction: String, CaseIterable, Sendable {
    case nudge, answer, pause, resume, stop
}

enum ScreenCaptureError: Error, Equatable, Sendable {
    /// Screen Recording is not granted to this build of Awake.
    case permissionDenied
    case noSuchDisplay
    case failed(String)
}

/// One still of a display as JPEG, in memory only. The app uses
/// ScreenCaptureKit; tests return bytes.
protocol ScreenCapturing: Sendable {
    /// Whether Screen Recording is granted, without asking for it.
    func permissionGranted() -> Bool
    /// `display` is `main` or a display's index among the online displays.
    func captureJPEG(display: String, maxWidth: Int) async throws -> Data
}

/// The machine as the phone's Machine tab shows it. A value that could
/// not be read is nil, and the phone says "unknown": never a guess.
struct PhoneMachineInfo: Codable, Equatable, Sendable {
    var hostName: String?
    var batteryPercent: Int?
    /// On AC power or charging.
    var isCharging: Bool?
    /// On AC and still losing charge (`ChargerTrend`).
    var chargerDraining: Bool?
    /// Battery flow in watts: negative while discharging.
    var batteryWatts: Double?
    /// The power adapter's rating, when one is connected and reports it.
    var adapterWatts: Int?
    var thermalState: String?
    /// `pmset -g therm` CPU speed limit in percent; 100 is unthrottled.
    var cpuSpeedLimit: Int?
    var batteryTemperatureC: Double?
    /// `normal`, `warning` or `critical`.
    var memoryPressure: String?
    var freeDiskBytes: Int64?
    /// `wifi`, `wired`, `cellular`, `other` or `none`.
    var networkType: String?
    var wifiSSID: String?
    var tailscaleIPv4: String?
    var lidClosed: Bool?
    var lowPowerMode: Bool?
    var uptimeSeconds: Int?
}

@MainActor
protocol PhoneMachineProbing: AnyObject {
    func read() async -> PhoneMachineInfo
}

/// Web push (step 5). `available` is false until keys exist.
@MainActor
protocol PhonePushSubscribing: AnyObject {
    /// Whether this Mac can send web push at all. The phone hides its
    /// notifications card when it cannot.
    var available: Bool { get }
    /// The VAPID public key (base64url, uncompressed P-256 point) the
    /// browser subscribes with, or nil when web push is not available.
    func publicKey() async -> String?
    func subscribe(deviceID: String, subscription: [String: Any]) async -> PhoneActionResult
    func unsubscribe(deviceID: String) async -> PhoneActionResult
    func sendTest(deviceID: String) async -> PhoneActionResult
}

@MainActor
final class UnavailablePhonePush: PhonePushSubscribing {
    let available = false
    func publicKey() async -> String? { nil }
    func subscribe(deviceID: String, subscription: [String: Any]) async -> PhoneActionResult { .failed("web push is not available") }
    func unsubscribe(deviceID: String) async -> PhoneActionResult { .failed("web push is not available") }
    func sendTest(deviceID: String) async -> PhoneActionResult { .failed("web push is not available") }
}
