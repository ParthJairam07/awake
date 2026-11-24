import XCTest
@testable import Awake

/// Statements the docs made that stopped being true: the repository is
/// public (so the nightly is attested), and the phone's agent actions and
/// the phone app are built.
final class StaleDocsTests: XCTestCase {
    private func file(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func testNothingStillSaysTheRepositoryIsPrivate() throws {
        let releasing = try file("docs/releasing.md")
        XCTAssertFalse(releasing.contains("While this repository is one"))
        XCTAssertTrue(releasing.contains("This repository is public, so stable releases and nightlies are both attested."))
        XCTAssertFalse(try file("PLAN.md").contains("making the repository public"))
    }

    func testBuiltFeaturesAreNotCalledPlanned() throws {
        let readme = try file("README.md")
        XCTAssertFalse(readme.contains("the rest are planned"))
        XCTAssertFalse(readme.contains("Agent cards fill in with the agent layer"))
        XCTAssertFalse(try file("docs/faq.md").contains("The phone app (coming)"))
        let plan = try file("PLAN.md")
        XCTAssertFalse(plan.contains("until phase 2 is wired in"))
        XCTAssertFalse(plan.contains("leases on the phone screens arrive with phase 3"))
    }

    /// The nightly attests by the workflow's own check, and the fallback
    /// for a private repository of a user account is still there.
    func testTheNightlyStillAttestsByItsOwnCheck() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let workflow = try String(contentsOf: root.appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        XCTAssertTrue(workflow.contains(#"gh api "repos/$GITHUB_REPOSITORY" --jq '.private and .owner.type == "User"'"#))
        XCTAssertTrue(workflow.contains("if: steps.attest.outputs.available == 'true'\n        uses: actions/attest-build-provenance@"))
        XCTAssertTrue(workflow.contains(#"origin="**No attestation:**"#), "the private-repository fallback")
    }

    /// Every finding of the November 19 run that was fixed is under "Fixed
    /// since" with its commit, and no longer under the open findings.
    func testTheValidationRecordMovesTheFixedFindings() throws {
        let record = try file("docs/release-validation.md")
        let open = try XCTUnwrap(record.range(of: "### Open findings, not fixed"))
        let fixed = try XCTUnwrap(record.range(of: "### Fixed since"))
        let notRun = try XCTUnwrap(record.range(of: "### Not run here"))
        XCTAssertLessThan(fixed.lowerBound, open.lowerBound)
        let stillOpen = String(record[open.upperBound..<notRun.lowerBound])
        for gone in ["Session restored", "no Wi-Fi port", "Lid: open", "Ran 3m 39s", "empty \"Awake Settings\" window", "link-cli.sh"] {
            XCTAssertFalse(stillOpen.contains(gone), "still listed as open: \(gone)")
        }
        let fixedList = String(record[fixed.upperBound..<open.lowerBound])
        XCTAssertEqual(fixedList.components(separatedBy: "Commit `").count - 1, 9, "nine fixes, each naming its commit")
        XCTAssertTrue(fixedList.contains("Seen fixed on the running app"))
        XCTAssertTrue(fixedList.contains("Unit-tested only"))
    }
}
