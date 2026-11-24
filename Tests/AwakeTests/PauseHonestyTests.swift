import XCTest
@testable import Awake

/// A pause (SIGSTOP) of an agent started from an interactive shell hands
/// the terminal back to the shell and leaves the agent a background job.
/// The mechanism is unchanged; every place that offers a pause says so,
/// in the same sentence.
final class PauseHonestyTests: XCTestCase {
    private func file(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Markdown as prose: line breaks and code marks aside.
    private func prose(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func testTheSentenceSaysWhatHappens() {
        let s = AgentPauseCopy.shellJob
        for part in ["started from a shell prompt", "background job", "takes the terminal back", "after the resume", "fg"] {
            XCTAssertTrue(s.contains(part), "missing: \(part)")
        }
    }

    func testThePhonePauseConfirmationSaysIt() throws {
        let page = try PhoneScript()
        let asked = page.call("pauseConfirmation", "\"claude\"")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(asked.utf8)) as? [String: String])
        XCTAssertEqual(object["title"], "Pause claude?")
        XCTAssertEqual(object["ok"], "Pause")
        XCTAssertEqual(object["body"], "The agent is frozen until you resume it. " + AgentPauseCopy.shellJob)
        // The Pause button asks exactly this.
        XCTAssertTrue(try file("Sources/Awake/Phone/Web/app.js").contains("ask(pauseConfirmation(name))"))
    }

    func testTheSettingsCaptionForPriorityPauseSaysIt() throws {
        let settings = try file("Sources/Awake/UI/SettingsView.swift")
        let toggle = try XCTUnwrap(settings.range(of: "Toggle(\"Pause low-priority agents under battery, heat or memory pressure\""))
        let after = settings[toggle.upperBound...]
        let caption = try XCTUnwrap(after.range(of: "An agent at a sudo prompt is never paused. \\(AgentPauseCopy.shellJob)\")"))
        XCTAssertLessThan(settings.distance(from: toggle.upperBound, to: caption.lowerBound), 1500, "the caption is the one under the priority pause toggle")
    }

    func testTheDocsHaveTheSameSentence() throws {
        let agents = prose(try file("docs/agents.md"))
        XCTAssertEqual(agents.components(separatedBy: AgentPauseCopy.shellJob).count - 1, 2, "under Priority pause and under From the phone")
        XCTAssertTrue(prose(try file("docs/phone.md")).contains(AgentPauseCopy.shellJob))
    }
}
