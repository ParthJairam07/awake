import Foundation
import Observation

/// Where the phone tokens live: the login keychain, service `awake-phone`,
/// one account per secret (`PhoneSecrets`). The settings window only talks
/// to this protocol; a save may wait on a keychain dialog, so every call
/// is async and runs on `KeychainQueue`.
@MainActor
protocol PhoneSecretStore: AnyObject, Sendable {
    func load() async throws -> PhoneSecrets
    /// Saves each non-nil field; an empty string deletes that secret.
    func save(_ secrets: PhoneSecrets) async throws
}

@MainActor
final class KeychainPhoneSecretStore: PhoneSecretStore {
    private let keychain: any KeychainStoring
    private let queue: KeychainQueue

    init(keychain: any KeychainStoring = KeychainStore(), queue: KeychainQueue = .shared) {
        self.keychain = keychain
        self.queue = queue
    }

    func load() async throws -> PhoneSecrets {
        let keychain = self.keychain
        return try await queue.run {
            PhoneSecrets(
                ntfyToken: try keychain.get(service: PhoneSecrets.service, account: PhoneSecrets.ntfyTokenAccount),
                pushoverAppToken: try keychain.get(service: PhoneSecrets.service, account: PhoneSecrets.pushoverAppTokenAccount),
                pushoverUserKey: try keychain.get(service: PhoneSecrets.service, account: PhoneSecrets.pushoverUserKeyAccount)
            )
        }
    }

    func save(_ secrets: PhoneSecrets) async throws {
        let keychain = self.keychain
        try await queue.run {
            let pairs: [(String, String?)] = [
                (PhoneSecrets.ntfyTokenAccount, secrets.ntfyToken),
                (PhoneSecrets.pushoverAppTokenAccount, secrets.pushoverAppToken),
                (PhoneSecrets.pushoverUserKeyAccount, secrets.pushoverUserKey),
            ]
            for (account, value) in pairs {
                guard let value else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    try keychain.delete(service: PhoneSecrets.service, account: account)
                } else {
                    try keychain.set(service: PhoneSecrets.service, account: account, value: trimmed)
                }
            }
        }
    }
}

/// The Phone section's field state: what is typed, whether a secret is on
/// file, and the outcome of the last save or test.
@MainActor
@Observable
final class PhoneSettingsModel {
    var ntfyToken = ""
    var pushoverAppToken = ""
    var pushoverUserKey = ""
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var notice: String?

    /// Which secrets the keychain already holds, so the fields can say so
    /// without showing the value.
    private(set) var onFile = PhoneSecrets.none

    func load(from store: any PhoneSecretStore) async {
        guard !loaded else { return }
        do {
            let s = try await store.load()
            onFile = s
            loaded = true
        } catch {
            notice = "The keychain could not be read: \(error.localizedDescription)"
        }
    }

    /// Saves the typed secrets (empty fields are left as they are on file).
    func save(to store: any PhoneSecretStore) async {
        busy = true
        defer { busy = false }
        let typed = PhoneSecrets(
            ntfyToken: ntfyToken.isEmpty ? nil : ntfyToken,
            pushoverAppToken: pushoverAppToken.isEmpty ? nil : pushoverAppToken,
            pushoverUserKey: pushoverUserKey.isEmpty ? nil : pushoverUserKey
        )
        guard typed != .none else {
            notice = "Nothing typed to save."
            return
        }
        do {
            try await store.save(typed)
            if let t = typed.ntfyToken { onFile.ntfyToken = t }
            if let t = typed.pushoverAppToken { onFile.pushoverAppToken = t }
            if let t = typed.pushoverUserKey { onFile.pushoverUserKey = t }
            ntfyToken = ""
            pushoverAppToken = ""
            pushoverUserKey = ""
            notice = "Saved to the login keychain."
        } catch {
            notice = "Not saved: \(error.localizedDescription)"
        }
    }

    /// Removes every phone secret from the keychain.
    func clear(in store: any PhoneSecretStore) async {
        busy = true
        defer { busy = false }
        do {
            try await store.save(PhoneSecrets(ntfyToken: "", pushoverAppToken: "", pushoverUserKey: ""))
            onFile = .none
            notice = "Removed from the keychain."
        } catch {
            notice = "Not removed: \(error.localizedDescription)"
        }
    }

    func test(with alerts: PhoneAlerts?) async {
        guard let alerts else {
            notice = "Phone alerts are not wired in this build."
            return
        }
        busy = true
        defer { busy = false }
        if let problem = await alerts.sendTest() {
            notice = problem
        } else {
            notice = "Test alert sent."
        }
    }

    static func onFileLabel(_ value: String?) -> String {
        value == nil ? "not on file" : "on file"
    }
}
