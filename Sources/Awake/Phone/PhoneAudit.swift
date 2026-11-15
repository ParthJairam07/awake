import Foundation

/// Every phone action, one JSON object per line, in
/// `Application Support/Awake/audit.log`: when, which phone, what it
/// asked for, with what arguments, and what came of it. Owner-only like
/// the journal and rotated to `audit.log.1` past 5 MB. Tokens, pairing
/// codes and the text typed for an agent are never written.
struct PhoneAuditLog: Sendable {
    static let maxBytes: UInt64 = 5 * 1024 * 1024

    struct Entry: Codable, Equatable, Sendable {
        var time: Date
        /// The paired phone's name, or `-` before a phone has a token.
        var device: String
        var deviceID: String?
        /// The address the request came from.
        var address: String
        var action: String
        var args: [String: String]
        var result: String
    }

    let url: URL
    let maxBytes: UInt64

    init(url: URL, maxBytes: UInt64 = PhoneAuditLog.maxBytes) {
        self.url = url
        self.maxBytes = maxBytes
    }

    static func line(_ entry: Entry) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(entry)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Appends the entry. A failure to write is logged, never thrown: the
    /// action it describes has already happened.
    func record(_ entry: Entry) {
        do {
            try OwnerOnly.appendToLog(Self.line(entry), at: url, maxBytes: maxBytes)
        } catch {
            Log.error("audit.log: \(error.localizedDescription)")
        }
    }
}
