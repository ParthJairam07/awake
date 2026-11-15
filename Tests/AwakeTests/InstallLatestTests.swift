import Foundation
import XCTest
@testable import Awake

/// Step E: `curl ... install.sh | bash` and `install.sh --latest`. A patched
/// copy of install.sh runs with a fake curl that serves a scratch release, a
/// file in place of the terminal, and a stub in place of the release's own
/// install.sh, so nothing is downloaded and nothing is installed.
final class InstallLatestTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var scratch: URL!
    private var served: URL { scratch.appendingPathComponent("served", isDirectory: true) }
    private var tty: URL { scratch.appendingPathComponent("tty") }
    private var installerCalls: URL { scratch.appendingPathComponent("installer-calls") }
    private let releases = "https://github.com/ParthJairam07/awake/releases"

    override func setUpWithError() throws {
        let fm = FileManager.default
        scratch = fm.temporaryDirectory.appendingPathComponent("install-latest-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try fm.createDirectory(at: served, withIntermediateDirectories: true)
        try fm.createDirectory(at: scratch.appendingPathComponent("tmp"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func sh(_ command: String, _ args: [String] = []) throws -> (status: Int32, output: String) {
        try runBash(["-c", command, "sh"] + args, stdin: nil)
    }

    private func runBash(_ args: [String], stdin: URL?) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": scratch.path, "TMPDIR": scratch.appendingPathComponent("tmp").path, "USER": "tester"]
        p.currentDirectoryURL = scratch
        let outURL = scratch.appendingPathComponent("out.\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL)
        defer { try? out.close() }
        p.standardOutput = out
        p.standardError = out
        p.standardInput = try stdin.map { try FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        let childExit = ProcessExit(p)
        try p.run()
        childExit.wait()
        return (p.terminationStatus, (try? String(contentsOf: outURL, encoding: .utf8)) ?? "")
    }

    /// install.sh with its fixed-path tools replaced. `arm64` is what the
    /// fake sysctl prints.
    private func patchedInstall(arm64: String = "1") throws -> URL {
        let bin = scratch.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let curl = bin.appendingPathComponent("curl")
        try TestScripts.write("""
            #!/bin/bash
            printf '%s\\n' "$*" >> '\(scratch.path)/curl-calls'
            out=""
            url=""
            lookup=0
            while (( $# )); do
              case "$1" in
                -o) out="$2"; shift 2 ;;
                -w) lookup=1; shift 2 ;;
                --proto|--retry) shift 2 ;;
                -*) shift ;;
                *) url="$1"; shift ;;
              esac
            done
            if (( lookup )); then
              [[ -f '\(served.path)/latest-url' ]] || exit 22
              exec /bin/cat '\(served.path)/latest-url'
            fi
            [[ -f '\(served.path)/'"${url##*/}" ]] || exit 22
            exec /bin/cp -p '\(served.path)/'"${url##*/}" "$out"

            """, to: curl)
        let sysctl = bin.appendingPathComponent("sysctl")
        try TestScripts.write("#!/bin/bash\necho '\(arm64)'\n", to: sysctl)
        var lines = try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/install.sh"), encoding: .utf8).components(separatedBy: "\n")
        for (name, value) in ["CURL": curl.path, "SYSCTL": sysctl.path, "TTY": tty.path] {
            let hits = lines.indices.filter { lines[$0].hasPrefix("\(name)=") }
            XCTAssertEqual(hits.count, 1, "install.sh must have exactly one \(name)= line")
            lines[hits[0]] = "\(name)='\(value)'"
        }
        let script = scratch.appendingPathComponent("install.sh")
        try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
        return script
    }

    /// A release in `served`: an ad-hoc Awake.app zipped at the top level,
    /// a stub install.sh that records its arguments, and SHA256SUMS.
    private func serveRelease(tag: String = "v1.2.3", quarantined: Bool = false) throws {
        let fm = FileManager.default
        let app = scratch.appendingPathComponent("build/Awake.app", isDirectory: true)
        try? fm.removeItem(at: app)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Awake").path)
        try fm.copyItem(at: Self.repoRoot.appendingPathComponent("Resources/Info.plist"), to: app.appendingPathComponent("Contents/Info.plist"))
        let version = String(tag.dropFirst())
        var made = try sh(#"/usr/bin/codesign --force --sign - "$1" 2>/dev/null"#, [app.path])
        XCTAssertEqual(made.status, 0, made.output)
        try TestScripts.write("""
            #!/bin/bash
            printf '%s\\n' "$*" > '\(installerCalls.path)'
            /usr/bin/xattr -p com.apple.quarantine "$3" >/dev/null 2>&1 && echo quarantined >> '\(installerCalls.path)'
            exit 0

            """, to: served.appendingPathComponent("install.sh"), executable: false)
        made = try sh(#"cd "$1" && rm -f ./*.zip && /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$2" "Awake-$3.zip" && /usr/bin/shasum -a 256 "Awake-$3.zip" install.sh > SHA256SUMS"#,
                      [served.path, app.path, version])
        XCTAssertEqual(made.status, 0, made.output)
        if quarantined {
            // A zip a browser downloaded: ditto passes its flag on to what
            // it unpacks. (The fake curl copies with the flag kept.)
            made = try sh(#"/usr/bin/xattr -w com.apple.quarantine "0081;00000000;Safari;" "$1""#, [served.appendingPathComponent("Awake-\(version).zip").path])
            XCTAssertEqual(made.status, 0, made.output)
        }
        try "\(releases)/tag/\(tag)".write(to: served.appendingPathComponent("latest-url"), atomically: true, encoding: .utf8)
    }

    private func leftovers() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: scratch.appendingPathComponent("tmp").path).filter { $0.hasPrefix("awake-latest.") }
    }

    /// Piped into bash, as the README's one line does: the latest release is
    /// looked up, its zip and installer are downloaded over https and
    /// checked against SHA256SUMS, the user is told what gets installed,
    /// and on yes the release's own install.sh runs with the unpacked
    /// bundle. The temporary folder is gone afterwards.
    func testAPipedRunDownloadsVerifiesAsksAndRunsTheReleasesInstaller() throws {
        let script = try patchedInstall()
        try serveRelease()
        try "y\n".write(to: tty, atomically: true, encoding: .utf8)

        let r = try runBash([], stdin: script)

        XCTAssertEqual(r.status, 0, r.output)
        let calls = try String(contentsOf: scratch.appendingPathComponent("curl-calls"), encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(calls.count, 4, "\(calls)")
        XCTAssertTrue(calls[0].hasSuffix(" \(releases)/latest"), calls[0])
        for (call, name) in zip(calls[1...], ["SHA256SUMS", "Awake-1.2.3.zip", "install.sh"]) {
            XCTAssertTrue(call.hasPrefix("-fsSL --proto =https --tlsv1.2 --retry 2 -o "), call)
            XCTAssertTrue(call.hasSuffix(" \(releases)/download/v1.2.3/\(name)"), call)
        }
        for line in ["Awake-1.2.3.zip: OK", "install.sh: OK", "copies Awake.app to \(scratch.path)/Applications", "writes /etc/sudoers.d/awake",
                     "This step asks for your password.", "This is an unsigned build", "run 'gh attestation verify'"] {
            XCTAssertTrue(r.output.contains(line), "missing '\(line)' in: \(r.output)")
        }
        let installer = try String(contentsOf: installerCalls, encoding: .utf8)
        XCTAssertNotNil(installer.range(of: #"^--allow-unverified-origin --app .*/awake-latest\.[A-Za-z0-9]+/unpacked/Awake\.app\n$"#, options: .regularExpression), installer)
        XCTAssertEqual(try leftovers(), [], "the download folder is removed")
    }

    /// `--latest` from a file does the same; any other answer than yes, or
    /// no terminal to ask on, installs nothing.
    func testNothingIsInstalledWithoutAYes() throws {
        let script = try patchedInstall()
        try serveRelease()
        for answer in ["n\n", "\n", "maybe\n", ""] {
            try answer.write(to: tty, atomically: true, encoding: .utf8)
            let r = try runBash([script.path, "--latest"], stdin: nil)
            XCTAssertEqual(r.status, 0, "\(answer): \(r.output)")
            XCTAssertTrue(r.output.contains("Nothing was installed and nothing was changed."), r.output)
        }
        try FileManager.default.removeItem(at: tty)
        let r = try runBash([script.path, "--latest"], stdin: nil)
        XCTAssertEqual(r.status, 1, r.output)
        XCTAssertTrue(r.output.contains("There is no terminal to ask on"), r.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installerCalls.path), "the installer never ran")
        XCTAssertEqual(try leftovers(), [])
        XCTAssertEqual(try runBash([script.path, "--latest", "--app", "x"], stdin: nil).status, 2)
        XCTAssertEqual(try runBash(["-s", "--", "--app", "x"], stdin: script).status, 2, "a piped run takes no other argument")
    }

    /// A download that does not match SHA256SUMS, a file the sums do not
    /// list, a missing asset, no stable release and an Intel Mac all stop
    /// before the question, with nothing installed.
    func testADownloadThatDoesNotMatchItsChecksumIsRefused() throws {
        let script = try patchedInstall()
        try "y\n".write(to: tty, atomically: true, encoding: .utf8)
        func expectRefusal(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let r = try runBash([], stdin: script)
            XCTAssertEqual(r.status, 1, r.output, file: file, line: line)
            XCTAssertTrue(r.output.contains(message), r.output, file: file, line: line)
            XCTAssertTrue(r.output.contains("Nothing was changed."), r.output, file: file, line: line)
            XCTAssertFalse(r.output.contains("Install Awake"), "asked anyway: \(r.output)", file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: installerCalls.path), file: file, line: line)
            XCTAssertEqual(try leftovers(), [], file: file, line: line)
        }

        try expectRefusal("could not reach \(releases)/latest")

        try serveRelease()
        try Data("tampered".utf8).write(to: served.appendingPathComponent("Awake-1.2.3.zip"))
        try expectRefusal("Awake-1.2.3.zip does not match SHA256SUMS")

        try serveRelease()
        try "#!/bin/bash\necho evil\n".write(to: served.appendingPathComponent("install.sh"), atomically: true, encoding: .utf8)
        try expectRefusal("install.sh does not match SHA256SUMS")

        try serveRelease()
        let sums = try String(contentsOf: served.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        try sums.components(separatedBy: "\n").filter { !$0.hasSuffix("install.sh") }.joined(separator: "\n")
            .write(to: served.appendingPathComponent("SHA256SUMS"), atomically: true, encoding: .utf8)
        try expectRefusal("SHA256SUMS of v1.2.3 does not list install.sh")

        try serveRelease()
        try FileManager.default.removeItem(at: served.appendingPathComponent("SHA256SUMS"))
        try expectRefusal("could not download SHA256SUMS of v1.2.3")

        for url in ["\(releases)", "\(releases)/tag/nightly-20261009-0123456789ab", "https://example.com/releases/tag/v1.2.3"] {
            try serveRelease()
            try url.write(to: served.appendingPathComponent("latest-url"), atomically: true, encoding: .utf8)
            try expectRefusal("did not lead to a release tagged v<major>.<minor>.<patch>")
        }

        try serveRelease()
        let intel = try patchedInstall(arm64: "0")
        let r = try runBash([], stdin: intel)
        XCTAssertEqual(r.status, 1, r.output)
        XCTAssertTrue(r.output.contains("Apple Silicon Macs only"), r.output)
    }

    /// The quarantine flag is removed only from an unsigned build and only
    /// after its own yes; a no leaves it on the bundle the installer gets.
    func testQuarantineIsRemovedOnlyFromAnUnsignedBuildAndOnlyOnAYes() throws {
        let script = try patchedInstall()
        try serveRelease(quarantined: true)

        // Each question opens the terminal file afresh and reads its
        // first line, so one "y" answers both here.
        try "y\n".write(to: tty, atomically: true, encoding: .utf8)
        var r = try runBash([], stdin: script)
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertTrue(r.output.contains("quarantine flag removed"), r.output)
        XCTAssertFalse(try String(contentsOf: installerCalls, encoding: .utf8).contains("quarantined"), "the installer got a bundle without the flag")

        // Not quarantined (what curl leaves): the question is never asked.
        try serveRelease()
        r = try runBash([], stdin: script)
        XCTAssertEqual(r.status, 0, r.output)
        XCTAssertFalse(r.output.contains("quarantine"), r.output)
    }
}
