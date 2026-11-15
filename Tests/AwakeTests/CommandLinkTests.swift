import XCTest
@testable import Awake

/// Settings' "Install `awake` command", in scratch directories.
final class CommandLinkTests: XCTestCase {
    var root: URL!
    var bundle: URL!
    var systemBin: URL!
    var home: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("awake-link-\(UUID().uuidString)", isDirectory: true)
        bundle = root.appendingPathComponent("Awake.app", isDirectory: true)
        systemBin = root.appendingPathComponent("usr-local-bin", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        let command = CommandLink.command(inBundle: bundle)
        try fm.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(atPath: "/usr/bin/true", toPath: command.path)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: systemBin.path)
        try? fm.removeItem(at: root)
    }

    private func install() -> Result<CommandLink.Installed, CommandLink.Failure> {
        CommandLink.install(bundle: bundle, systemBin: systemBin, home: home)
    }

    func testTheCommandIsNotBesideTheAppsExecutable() {
        XCTAssertEqual(CommandLink.command(inBundle: URL(fileURLWithPath: "/A/Awake.app")).path, "/A/Awake.app/Contents/Helpers/awake")
    }

    func testAWritableSystemDirectoryGetsTheLink() throws {
        try fm.createDirectory(at: systemBin, withIntermediateDirectories: true)

        let installed = try install().get()

        XCTAssertEqual(installed.link.path, systemBin.appendingPathComponent("awake").path)
        XCTAssertFalse(installed.needsPath)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: installed.link.path), CommandLink.command(inBundle: bundle).path)
        XCTAssertEqual(installed.message, "Installed at \(installed.link.path).")
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".local").path))
    }

    func testWithoutOneTheLinkGoesToTheUsersLocalBin() throws {
        // No such directory, then one this user cannot write: both mean sudo.
        var installed = try install().get()
        XCTAssertEqual(installed.link.path, home.appendingPathComponent(".local/bin/awake").path)
        XCTAssertTrue(installed.needsPath)
        XCTAssertTrue(installed.message.contains("add \(home.path)/.local/bin to your PATH"))

        try fm.createDirectory(at: systemBin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o555])
        installed = try install().get()
        XCTAssertEqual(installed.link.path, home.appendingPathComponent(".local/bin/awake").path)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: systemBin.path), [])
    }

    func testAnExistingLinkIsReplacedEvenADanglingOne() throws {
        let link = home.appendingPathComponent(".local/bin/awake")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/nonexistent/Awake.app/Contents/Helpers/awake")

        let installed = try install().get()

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: installed.link.path), CommandLink.command(inBundle: bundle).path)
        XCTAssertNoThrow(try install().get(), "and again over its own link")
    }

    func testAFileThatIsNotALinkIsLeftAlone() throws {
        let link = home.appendingPathComponent(".local/bin/awake")
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: link)

        XCTAssertEqual(install(), .failure(.occupied(link.path)))
        XCTAssertEqual(try String(contentsOf: link, encoding: .utf8), "#!/bin/sh\n")
    }

    func testABuildWithoutTheCommandSaysSo() throws {
        try fm.removeItem(at: CommandLink.command(inBundle: bundle))
        XCTAssertEqual(install(), .failure(.noCommand(CommandLink.command(inBundle: bundle).path)))
        XCTAssertFalse(fm.fileExists(atPath: home.appendingPathComponent(".local").path), "nothing was created")
    }
}
