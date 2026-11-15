import Foundation

/// The live session behind the phone API: `SessionManager` does the work,
/// exactly as the menu bar does, so the journal, the recovery agent and
/// the one-transaction-at-a-time rule all apply to a start, extend or end
/// asked from the phone.
@MainActor
final class LivePhoneSession: PhoneSessionControlling {
    private let manager: SessionManager
    private let services: AppServices

    init(manager: SessionManager, services: AppServices) {
        self.manager = manager
        self.services = services
    }

    func statusJSON() -> Data {
        (try? StatusSnapshot.encode(services.snapshot())) ?? Data("{}".utf8)
    }

    var presetMinutes: [Int] {
        manager.config.presets.map { Int($0 / 60) }.filter { $0 >= 1 }
    }

    var maxMinutes: Int {
        max(1, Int(manager.config.maxDuration / 60))
    }

    func start(minutes: Int) async -> PhoneActionResult {
        guard !manager.isActive else { return .failed("A session is already running. Extend it instead.") }
        await manager.start(duration: TimeInterval(minutes * 60))
        guard manager.isActive else {
            return .failed(manager.lastError ?? "The session did not start. See Awake's menu on the Mac.")
        }
        return .done("Session started for \(Self.duration(minutes)).")
    }

    func extend(minutes: Int) async -> PhoneActionResult {
        guard let before = manager.session?.endsAt else { return .failed("No session is running.") }
        await manager.extend(by: TimeInterval(minutes * 60))
        guard let after = manager.session?.endsAt else { return .failed("The session ended before it could be extended.") }
        guard after > before else {
            return .failed(manager.lastError ?? "The session was not extended: it is already at the longest length Settings allows.")
        }
        let added = Int((after.timeIntervalSince(before) / 60).rounded())
        return .done(added == minutes ? "Extended by \(Self.duration(minutes))." : "Extended by \(Self.duration(added)), up to the longest length Settings allows.")
    }

    func end() async -> PhoneActionResult {
        guard manager.isActive || manager.pendingEnd != nil else { return .done("No session is running.") }
        return Self.describe(await manager.end(reason: .user))
    }

    nonisolated static func describe(_ outcome: EndOutcome) -> PhoneActionResult {
        switch outcome {
        case .restored:
            .done("Session ended. Everything was put back.")
        case .incomplete(agentArmed: true):
            .failed("Session ended, but something could not be put back yet. The recovery agent keeps trying; check Awake's menu on the Mac.")
        case .incomplete(agentArmed: false):
            .failed("Session ended, but something could not be put back and the recovery agent is not loaded. Awake keeps trying while it runs; check the Mac.")
        case .locked:
            .failed("The session was not ended: the recovery lock is held by another process. Awake retries by itself.")
        case .sessionRetained:
            .failed("The session's changes were undone but its file could not be removed. Awake retries by itself.")
        case .journalUnreadable:
            .failed("The session was not ended: Awake's journal cannot be read, and it will not guess what to undo. This needs a person at the Mac.")
        case .privilegedCommandRunning:
            .failed("The session was not ended yet: a power command is still running. Awake ends it when that command exits.")
        }
    }

    nonisolated static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}

/// Scripted session; for tests.
@MainActor
final class FakePhoneSession: PhoneSessionControlling {
    var json = Data("{\"active\":false}".utf8)
    var presetMinutes = [30, 60, 120]
    var maxMinutes = 43_200
    var startResult = PhoneActionResult.done("Session started for 30 min.")
    var extendResult = PhoneActionResult.done("Extended by 30 min.")
    var endResult = PhoneActionResult.done("Session ended. Everything was put back.")
    private(set) var calls: [String] = []

    func statusJSON() -> Data { json }

    func start(minutes: Int) async -> PhoneActionResult {
        calls.append("start \(minutes)")
        return startResult
    }

    func extend(minutes: Int) async -> PhoneActionResult {
        calls.append("extend \(minutes)")
        return extendResult
    }

    func end() async -> PhoneActionResult {
        calls.append("end")
        return endResult
    }
}
