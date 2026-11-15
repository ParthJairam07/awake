import XCTest
@testable import Awake

/// scripts/link-cli.sh in a scratch HOME, with its /usr/local/bin pointed
/// at a scratch directory in a private copy of the script.
final class LinkCLIScriptTests: XCTestCase {
    var root: URL!
    var home: URL!
    var app: URL!
    var systemBin: URL!
    var script: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("awake-linkcli-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        app = home.appendingPathComponent("Applications/Awake.app", isDirectory: true)
        systemBin = root.appendingPathComponent("usr-local-bin", isDirectory: true)
        let command = CommandLink.command(inBundle: app)
        try fm.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: command.path)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/link-cli.sh")
        var lines = try String(contentsOf: source, encoding: .utf8).components(separatedBy: "\n")
        let hits = lines.indices.filter { lines[$0].hasPrefix("SYSTEM_BIN=") }
        XCTAssertEqual(hits.count, 1, "link-cli.sh must have exactly one SYSTEM_BIN= line")
        lines[hits[0]] = "SYSTEM_BIN='\(systemBin.path)'"
        script = root.appendingPathComponent("link-cli.sh")
        try lines.joined(separator: "\n").write(to: script, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func runScript(_ args: [String] = [], path: String = "/usr/bin:/bin") throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script.path] + args
        p.environment = ["HOME": home.path, "PATH": path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    func testWithoutAWritableSystemDirectoryTheLinkGoesToLocalBin() throws {
        let r = try runScript()
        XCTAssertEqual(r.status, 0, r.err)
        let link = home.appendingPathComponent(".local/bin/awake")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), CommandLink.command(inBundle: app).path)
        XCTAssertTrue(r.out.contains("\(link.path) -> "), r.out)
        XCTAssertTrue(r.out.contains("is not on your PATH"), r.out)
    }

    func testAWritableSystemDirectoryIsPreferredAndAnOldLinkReplaced() throws {
        try fm.createDirectory(at: systemBin, withIntermediateDirectories: true)
        let link = systemBin.appendingPathComponent("awake")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/awake")

        let r = try runScript(path: "\(systemBin.path):/usr/bin:/bin")

        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), CommandLink.command(inBundle: app).path)
        XCTAssertFalse(r.out.contains("is not on your PATH"), r.out)
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".local").path))
    }

    func testAFileThatIsNotALinkIsLeftAlone() throws {
        let dir = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: dir.appendingPathComponent("awake"))

        let r = try runScript(["--dir", dir.path])

        XCTAssertEqual(r.status, 1)
        XCTAssertTrue(r.err.contains("already exists and is not a link"), r.err)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("awake"), encoding: .utf8), "mine")
    }

    func testNoInstalledCommandAndBadArguments() throws {
        let missing = try runScript(["--app", root.appendingPathComponent("Nope.app").path])
        XCTAssertEqual(missing.status, 1)
        XCTAssertTrue(missing.err.contains("no awake command at"), missing.err)
        XCTAssertEqual(try runScript(["--bogus"]).status, 2)
        XCTAssertEqual(try runScript(["--dir"]).status, 2)
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".local").path), "nothing was created")
    }

    func testTheScriptNeverUsesSudo() throws {
        let text = try String(contentsOf: script, encoding: .utf8)
        let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
        XCTAssertFalse(code.contains("sudo"))
    }
}
