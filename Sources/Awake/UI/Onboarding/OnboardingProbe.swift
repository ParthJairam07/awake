import AppKit
import ApplicationServices
import CoreGraphics
import UserNotifications

/// Step E: reads the machine for the Setup window. Each reading is
/// injectable, so tests assemble `OnboardingProbes` from fakes; the live
/// values ask macOS and change nothing (no prompt is raised by a read).
struct OnboardingProbe: Sendable {
    typealias Runner = @Sendable (_ exe: String, _ args: [String]) async throws -> ShellResult

    var notifications: @Sendable () async -> OnboardingReading
    var accessibility: @Sendable () -> OnboardingReading
    var screenRecording: @Sendable () -> OnboardingReading
    var fileExists: @Sendable (String) -> Bool
    var run: Runner

    /// The four commands of the sudoers rule, as `sudo -n -l` is asked
    /// about them. Listing a command runs nothing: no power setting changes.
    static let pmsetCommands: [[String]] = [
        ["-a", "disablesleep", "1"], ["-a", "disablesleep", "0"],
        ["-b", "lowpowermode", "1"], ["-b", "lowpowermode", "0"],
    ]

    /// Whether sudo grants all four commands without a password. A sudo
    /// that cannot be run or does not answer is unknown, not "no".
    func sudoersRule() async -> OnboardingReading {
        for command in Self.pmsetCommands {
            do {
                let result = try await run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset"] + command)
                if !result.succeeded { return .no }
            } catch {
                return .unknown
            }
        }
        return .yes
    }

    /// Everything at once. `config` supplies the phone settings; the test
    /// result is the window's own state.
    /// The notifications reading once macOS has an answer. After "Allow
    /// notifications" the system prompt stays up until someone answers it,
    /// and the reading is unknown until then: read again after each `wait`
    /// while it is, at most `attempts` times.
    func notificationsOnceDecided(
        attempts: Int = 120,
        wait: @Sendable () async -> Void = { try? await Task.sleep(for: .seconds(1)) }
    ) async -> OnboardingReading {
        var reading = await notifications()
        var left = attempts
        while reading == .unknown, left > 0, !Task.isCancelled {
            await wait()
            reading = await notifications()
            left -= 1
        }
        return reading
    }

    func read(config: Config, phoneTestSucceeded: Bool) async -> OnboardingProbes {
        let services = PhonePush.servicesEnabled(config: config)
        return OnboardingProbes(
            notifications: await notifications(),
            sudoersRule: await sudoersRule(),
            accessibility: accessibility(),
            screenRecording: screenRecording(),
            phoneConfigured: services.ntfy || services.pushover,
            phoneTestSucceeded: phoneTestSucceeded,
            tailscaleInstalled: OnboardingModel.tailscaleInstalled(exists: fileExists)
        )
    }

    static let live = OnboardingProbe(
        notifications: {
            // Outside an app bundle the notification center raises an
            // exception Swift cannot catch (see Notifier).
            guard Notifier.runningInsideAppBundle() else { return .unknown }
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional: return .yes
            case .denied: return .no
            default: return .unknown
            }
        },
        accessibility: { AXIsProcessTrusted() ? .yes : .no },
        screenRecording: { CGPreflightScreenCaptureAccess() ? .yes : .no },
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        run: { try await CancellableCommand().run($0, $1, timeout: 10) }
    )
}
