import Foundation
import XCTest
@testable import Awake

/// The Release workflow's helper scripts under .github/scripts, run for real
/// in a scratch folder. notarize.sh runs against a stub `xcrun`, so nothing
/// is sent to Apple; package-release.sh runs with the real ditto, hdiutil
/// and codesign on a scratch ad-hoc bundle. signing-keychain.sh creates a
/// keychain and edits the user's keychain search list, so only its argument
/// checks run here.
final class ReleaseScriptsTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-scripts-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func run(_ args: [String], environment: [String: String] = [:], currentDirectory: URL? = nil) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": scratch.path, "TMPDIR": scratch.path].merging(environment) { _, new in new }
        p.currentDirectoryURL = currentDirectory ?? scratch
        let outURL = scratch.appendingPathComponent("out.\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        defer { try? out.close() }
        p.standardOutput = out
        p.standardError = out
        let childExit = ProcessExit(p)
        try p.run()
        childExit.wait()
        return (p.terminationStatus, (try? String(contentsOf: outURL, encoding: .utf8)) ?? "")
    }

    /// A private copy of a .github/scripts script with the named fixed-path
    /// tool lines replaced, as the other script tests do.
    private func patched(_ name: String, tools: [String: String]) throws -> URL {
        var lines = try String(contentsOf: Self.repoRoot.appendingPathComponent(".github/scripts/\(name)"), encoding: .utf8).components(separatedBy: "\n")
        for (tool, value) in tools {
            let hits = lines.indices.filter { lines[$0].hasPrefix("\(tool)=") }
            XCTAssertEqual(hits.count, 1, "\(name) must have exactly one \(tool)= line")
            lines[hits[0]] = "\(tool)='\(value)'"
        }
        let url = scratch.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A minimal ad-hoc signed Awake.app, enough for codesign, ditto and
    /// hdiutil.
    private func scratchBundle() throws -> URL {
        let fm = FileManager.default
        let app = scratch.appendingPathComponent("dist/Awake.app", isDirectory: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Awake").path)
        try fm.copyItem(at: Self.repoRoot.appendingPathComponent("Resources/Info.plist"), to: app.appendingPathComponent("Contents/Info.plist"))
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", app.path]
        sign.standardOutput = FileHandle.nullDevice
        sign.standardError = FileHandle.nullDevice
        let signExit = ProcessExit(sign)
        try sign.run()
        signExit.wait()
        XCTAssertEqual(sign.terminationStatus, 0)
        return app
    }

    // MARK: - notarize.sh

    /// A stub xcrun that logs each call and answers `notarytool submit`
    /// with the JSON in `answer`.
    private func stubXcrun() throws -> (xcrun: URL, calls: URL, answer: URL) {
        let calls = scratch.appendingPathComponent("xcrun-calls")
        let answer = scratch.appendingPathComponent("answer.json")
        let xcrun = scratch.appendingPathComponent("xcrun")
        try TestScripts.write("""
            #!/bin/bash
            printf '%s\\n' "$*" >> '\(calls.path)'
            if [[ "$1 $2" == "notarytool submit" ]]; then
              /bin/cat '\(answer.path)'
            fi
            exit 0

            """, to: xcrun)
        return (xcrun, calls, answer)
    }

    private let credentials = ["APPLE_ID": "owner@example.com", "APPLE_TEAM_ID": "ABCDE12345", "APPLE_APP_PASSWORD": "abcd-efgh-ijkl-mnop"]

    /// An accepted app: the upload is a zip of the bundle, and the ticket
    /// is stapled to the bundle itself, then validated.
    func testNotarizeZipsAnAppSubmitsItAndStaplesTheBundleWhenAppleAccepts() throws {
        let app = try scratchBundle()
        let (xcrun, calls, answer) = try stubXcrun()
        let script = try patched("notarize.sh", tools: ["XCRUN": xcrun.path])
        try #"{"id":"11111111-2222-3333-4444-555555555555","status":"Accepted","message":"Processing complete"}"#.write(to: answer, atomically: true, encoding: .utf8)

        let r = try run([script.path, app.path], environment: credentials)

        XCTAssertEqual(r.status, 0, r.output)
        let recorded = try String(contentsOf: calls, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(recorded.count, 3, "\(recorded)")
        XCTAssertNotNil(recorded[0].range(of: #"^notarytool submit .*/Awake\.zip --apple-id owner@example\.com --team-id ABCDE12345 --password abcd-efgh-ijkl-mnop --wait --output-format json$"#, options: .regularExpression), recorded[0])
        XCTAssertEqual(Array(recorded[1...]), ["stapler staple \(app.path)", "stapler validate \(app.path)"])
        XCTAssertTrue(r.output.contains("submission 11111111-2222-3333-4444-555555555555: Accepted"), r.output)
        XCTAssertFalse(r.output.contains("abcd-efgh-ijkl-mnop"), "the password is never printed: \(r.output)")
    }

    /// A disk image is uploaded as it is.
    func testNotarizeSubmitsADiskImageItself() throws {
        let dmg = scratch.appendingPathComponent("Awake-1.2.3.dmg")
        try Data("not really an image".utf8).write(to: dmg)
        let (xcrun, calls, answer) = try stubXcrun()
        let script = try patched("notarize.sh", tools: ["XCRUN": xcrun.path])
        try #"{"id":"1","status":"Accepted"}"#.write(to: answer, atomically: true, encoding: .utf8)

        let r = try run([script.path, dmg.path], environment: credentials)

        XCTAssertEqual(r.status, 0, r.output)
        let recorded = try String(contentsOf: calls, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertTrue(recorded.first?.hasPrefix("notarytool submit \(dmg.path) ") == true, "\(recorded)")
        XCTAssertEqual(recorded.last, "stapler validate \(dmg.path)")
    }

    /// `notarytool submit --wait` exits 0 whatever Apple answered. Anything
    /// but Accepted fails the step, fetches Apple's log and staples nothing.
    func testNotarizeFailsAndStaplesNothingWhenAppleDoesNotAccept() throws {
        let app = try scratchBundle()
        let (xcrun, calls, answer) = try stubXcrun()
        let script = try patched("notarize.sh", tools: ["XCRUN": xcrun.path])
        for body in [#"{"id":"abc","status":"Invalid"}"#, #"{"id":"abc","status":"Rejected"}"#, "", "not json"] {
            try? FileManager.default.removeItem(at: calls)
            try body.write(to: answer, atomically: true, encoding: .utf8)

            let r = try run([script.path, app.path], environment: credentials)

            XCTAssertEqual(r.status, 1, "\(body): \(r.output)")
            let recorded = try String(contentsOf: calls, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
            XCTAssertFalse(recorded.contains { $0.hasPrefix("stapler") }, "\(body): \(recorded)")
            XCTAssertEqual(recorded.contains { $0.hasPrefix("notarytool log abc ") }, body.contains("abc"), "\(body): \(recorded)")
            XCTAssertTrue(r.output.contains("Apple did not accept"), r.output)
        }
    }

    /// Without all three credentials nothing is submitted.
    func testNotarizeNeedsAllThreeCredentialsAndAKnownKindOfFile() throws {
        let app = try scratchBundle()
        let (xcrun, calls, _) = try stubXcrun()
        let script = try patched("notarize.sh", tools: ["XCRUN": xcrun.path])
        for missing in credentials.keys.sorted() {
            var environment = credentials
            environment[missing] = ""
            let r = try run([script.path, app.path], environment: environment)
            XCTAssertEqual(r.status, 1, r.output)
            XCTAssertTrue(r.output.contains("\(missing) is not set"), r.output)
        }
        let text = scratch.appendingPathComponent("notes.txt")
        try "x".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run([script.path, text.path], environment: credentials).status, 2)
        XCTAssertEqual(try run([script.path], environment: credentials).status, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path), "nothing reached xcrun")
    }

    // MARK: - package-release.sh

    /// The files of a release: a zip with Awake.app at its top level, a
    /// disk image with the app and a shortcut to /Applications, and the two
    /// scripts. The bundle in each still verifies.
    func testPackageWritesTheZipTheDiskImageAndTheScripts() throws {
        let fm = FileManager.default
        let app = try scratchBundle()
        let out = scratch.appendingPathComponent("release", isDirectory: true)
        let script = Self.repoRoot.appendingPathComponent(".github/scripts/package-release.sh")

        let r = try run([script.path, "--app", app.path, "--name", "Awake-1.2.3", "--output", out.path])

        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path).sorted(), ["Awake-1.2.3.dmg", "Awake-1.2.3.zip", "install.sh", "uninstall.sh"])
        for name in ["install.sh", "uninstall.sh"] {
            XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(name)), try Data(contentsOf: Self.repoRoot.appendingPathComponent("scripts/\(name)")), name)
        }

        let unpacked = scratch.appendingPathComponent("unpacked", isDirectory: true)
        XCTAssertEqual(try run(["-c", #"/usr/bin/ditto -x -k "$1" "$2""#, "sh", out.appendingPathComponent("Awake-1.2.3.zip").path, unpacked.path]).status, 0)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: unpacked.path), ["Awake.app"], "Awake.app at the zip's top level")
        XCTAssertEqual(try run(["-c", #"/usr/bin/codesign --verify --strict "$1""#, "sh", unpacked.appendingPathComponent("Awake.app").path]).status, 0)

        let mount = scratch.appendingPathComponent("mount", isDirectory: true)
        let attach = try run(["-c", #"/usr/bin/hdiutil attach -nobrowse -readonly -mountpoint "$2" "$1""#, "sh", out.appendingPathComponent("Awake-1.2.3.dmg").path, mount.path])
        XCTAssertEqual(attach.status, 0, attach.output)
        defer { _ = try? run(["-c", #"/usr/bin/hdiutil detach -force "$1""#, "sh", mount.path]) }
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: mount.appendingPathComponent("Applications").path), "/Applications")
        XCTAssertEqual(try run(["-c", #"/usr/bin/codesign --verify --strict "$1""#, "sh", mount.appendingPathComponent("Awake.app").path]).status, 0)
    }

    /// A second run never replaces a file of the first, a bundle whose
    /// seal is broken is not packaged, and the name is checked before it
    /// becomes a file name.
    func testPackageRefusesToReplaceFilesABrokenBundleAndAnOddName() throws {
        let app = try scratchBundle()
        let out = scratch.appendingPathComponent("release", isDirectory: true)
        let script = Self.repoRoot.appendingPathComponent(".github/scripts/package-release.sh")

        XCTAssertEqual(try run([script.path, "--app", app.path, "--name", "Awake-../x", "--output", out.path]).status, 2)
        XCTAssertEqual(try run([script.path, "--app", app.path, "--output", out.path]).status, 2)
        XCTAssertEqual(try run([script.path, "--app", scratch.path, "--name", "Awake-1.2.3", "--output", out.path]).status, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))

        XCTAssertEqual(try run([script.path, "--app", app.path, "--name", "Awake-1.2.3", "--output", out.path]).status, 0)
        let again = try run([script.path, "--app", app.path, "--name", "Awake-1.2.3", "--output", out.path])
        XCTAssertEqual(again.status, 1, again.output)
        XCTAssertTrue(again.output.contains("already exists; refusing to replace it"), again.output)

        try Data("edited".utf8).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let broken = try run([script.path, "--app", app.path, "--name", "Awake-1.2.4", "--output", out.path])
        XCTAssertNotEqual(broken.status, 0, broken.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("Awake-1.2.4.zip").path))
    }

    // MARK: - signing-keychain.sh

    /// Only the argument and environment checks: a real run creates a
    /// keychain and changes the keychain search list.
    func testSigningKeychainStopsBeforeTouchingAnythingWithoutItsInputs() throws {
        let script = Self.repoRoot.appendingPathComponent(".github/scripts/signing-keychain.sh")
        let keychain = scratch.appendingPathComponent("signing.keychain-db")
        XCTAssertEqual(try run([script.path]).status, 2)
        XCTAssertEqual(try run([script.path, "create"]).status, 2)
        XCTAssertEqual(try run([script.path, "bogus", keychain.path]).status, 2)
        for environment in [[:], ["APPLE_CERTIFICATE_P12": "AAAA"], ["APPLE_CERTIFICATE_PASSWORD": "x"]] {
            let r = try run([script.path, "create", keychain.path], environment: environment)
            XCTAssertEqual(r.status, 1, r.output)
            XCTAssertTrue(r.output.contains("APPLE_CERTIFICATE_P12 and APPLE_CERTIFICATE_PASSWORD must both be set"), r.output)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: keychain.path))
    }
}
