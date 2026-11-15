import AwakeLeaseKit
import XCTest

/// A scratch directory per test; nothing here reads AWAKE_HOME.
class LeaseScratchCase: XCTestCase {
    var root: URL!
    var home: LeaseHome!
    var store: LeaseStore!
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("awake-lease-tests-\(UUID().uuidString)", isDirectory: true)
        home = LeaseHome(appSupport: root.appendingPathComponent("Awake", isDirectory: true))
        store = LeaseStore(directory: home.leasesDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }
}

final class LeaseModelTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let process = LeaseProcess(pid: 4242, startedAt: 1_799_999_000, startedAtMicros: 123_456, bootSession: "boot-1")

    func testALeaseRoundTripsWithEveryKindOfUntil() throws {
        let pane = LeasePane(target: "work:1.0", paneId: "%3", socketPath: "/private/tmp/tmux-501/default", process: process)
        for until in [nil, LeaseUntil.pid(process), .tmux(pane), .command(process, name: "make")] {
            let lease = Lease(owner: "claude", reason: "refactor billing", createdAt: t0, expiresAt: t0.addingTimeInterval(7200), until: until, graceSeconds: 600, source: .mcp)
            let data = try LeaseJSON.encoder().encode(lease)
            XCTAssertEqual(try LeaseJSON.decoder().decode(Lease.self, from: data), lease)
        }
    }

    func testTheFileIsPlainJSONWithWholeSecondDatesAndALowerCaseId() throws {
        let id = try XCTUnwrap(UUID(uuidString: "21E3921E-5A5D-4F18-A13F-73B21855C47D"))
        let lease = Lease(id: id, owner: "claude", reason: "refactor billing", createdAt: t0, expiresAt: t0.addingTimeInterval(7200), until: .pid(process), graceSeconds: 60, source: .cli)
        let text = String(decoding: try LeaseJSON.encoder().encode(lease), as: UTF8.self)
        XCTAssertEqual(text, """
        {
          "createdAt" : "2027-01-15T08:00:00Z",
          "expiresAt" : "2027-01-15T10:00:00Z",
          "graceSeconds" : 60,
          "id" : "21e3921e-5a5d-4f18-a13f-73b21855c47d",
          "owner" : "claude",
          "reason" : "refactor billing",
          "source" : "cli",
          "until" : {
            "bootSession" : "boot-1",
            "kind" : "pid",
            "pid" : 4242,
            "startedAt" : 1799999000,
            "startedAtMicros" : 123456
          },
          "version" : 1
        }
        """)
        XCTAssertEqual(lease.fileName, "21e3921e-5a5d-4f18-a13f-73b21855c47d.json")
    }

    func testAHandWrittenLeaseNeedsOnlyTheEssentials() throws {
        let json = #"{"id":"21E3921E-5A5D-4F18-A13F-73B21855C47D","owner":"me","createdAt":"2027-01-15T08:00:00Z","expiresAt":"2027-01-15T09:00:00Z","source":"hook"}"#
        let lease = try LeaseJSON.decoder().decode(Lease.self, from: Data(json.utf8))
        XCTAssertEqual(lease.reason, "")
        XCTAssertEqual(lease.graceSeconds, 0)
        XCTAssertEqual(lease.version, 1)
        XCTAssertEqual(lease.source, .hook)
        XCTAssertNil(lease.until)
    }

    func testAnUntilWithoutAProcessIdentityOrOfAnUnknownKindIsNotALease() {
        for until in [#"{"kind":"pid","pid":4242}"#, #"{"kind":"moon"}"#, #"{"kind":"tmux","target":"a:0.0","paneId":"%1"}"#] {
            let json = #"{"id":"21E3921E-5A5D-4F18-A13F-73B21855C47D","owner":"me","createdAt":"2027-01-15T08:00:00Z","expiresAt":"2027-01-15T09:00:00Z","source":"cli","until":\#(until)}"#
            XCTAssertThrowsError(try LeaseJSON.decoder().decode(Lease.self, from: Data(json.utf8)), until)
        }
    }

    func testRules() {
        var lease = Lease(owner: "claude", reason: "", createdAt: t0, expiresAt: t0.addingTimeInterval(3600), source: .cli)
        XCTAssertNil(LeaseRules.problem(with: lease, now: t0))
        XCTAssertNil(LeaseRules.problem(with: lease, now: t0.addingTimeInterval(3599)))
        XCTAssertEqual(LeaseRules.problem(with: lease, now: t0.addingTimeInterval(3600)), .expired)
        XCTAssertNil(LeaseRules.problem(with: lease, now: t0.addingTimeInterval(-200)), "a clock a few minutes behind the writer's is allowed")
        XCTAssertEqual(LeaseRules.problem(with: lease, now: t0.addingTimeInterval(-400)), .createdInTheFuture)
        lease.version = 2
        XCTAssertEqual(LeaseRules.problem(with: lease, now: t0), .unknownVersion(2))
        lease.version = 1
        lease.owner = "\u{1B}\n"
        XCTAssertEqual(LeaseRules.problem(with: lease, now: t0), .emptyOwner)
        lease.owner = "x"
        lease.expiresAt = t0
        XCTAssertEqual(LeaseRules.problem(with: lease, now: t0), .datesOutOfOrder)
    }

    func testTheCapCountsFromTheLeasesCreation() {
        let lease = Lease(owner: "claude", reason: "", createdAt: t0, expiresAt: t0.addingTimeInterval(20 * 3600), source: .cli)
        XCTAssertEqual(LeaseRules.effectiveExpiry(of: lease, capSeconds: 8 * 3600), t0.addingTimeInterval(8 * 3600))
        XCTAssertEqual(LeaseRules.effectiveExpiry(of: lease, capSeconds: 40 * 3600), lease.expiresAt)
        XCTAssertEqual(LeaseRules.effectiveExpiry(of: lease, capSeconds: nil), lease.expiresAt)
    }

    func testTextFromAnotherProgramIsMadeOneSafeLine() {
        XCTAssertEqual(LeaseRules.clean("  refactor\n\tbilling \u{1B}[31m now  ", limit: 200), "refactor billing [31m now")
        XCTAssertEqual(LeaseRules.clean(String(repeating: "a", count: 300), limit: 10), "aaaaaaaaa\u{2026}")
        XCTAssertEqual(LeaseRules.clean("\u{202E}evil", limit: 20), "evil", "a direction override is a format character")
        XCTAssertEqual(LeaseRules.cleanOwner("claude"), "claude")
    }

    func testDurations() {
        XCTAssertEqual(LeaseDuration.seconds(from: "2h"), 7200)
        XCTAssertEqual(LeaseDuration.seconds(from: "90m"), 5400)
        XCTAssertEqual(LeaseDuration.seconds(from: "1h30m"), 5400)
        XCTAssertEqual(LeaseDuration.seconds(from: " 1H 30M "), 5400)
        XCTAssertEqual(LeaseDuration.seconds(from: "45s"), 45)
        XCTAssertEqual(LeaseDuration.seconds(from: "1d"), 86400)
        for bad in ["", "90", "h", "2x", "-2h", "2h3", "1.5h", "0m", "99999999999999999999h", "٢h"] {
            XCTAssertNil(LeaseDuration.seconds(from: bad), bad)
        }
        XCTAssertEqual(LeaseDuration.format(4320), "1h 12m")
        XCTAssertEqual(LeaseDuration.format(7200), "2h")
        XCTAssertEqual(LeaseDuration.format(59), "59s")
        XCTAssertEqual(LeaseDuration.format(60), "1m")
        XCTAssertEqual(LeaseDuration.format(90000), "1d 1h")
        XCTAssertEqual(LeaseDuration.format(-5), "0s")
    }

    func testStatusLinesForTheMenu() {
        let a = LeaseStatus(lease: Lease(owner: "claude", reason: "refactor billing", createdAt: t0, expiresAt: t0.addingTimeInterval(4320), source: .mcp), now: t0)
        let b = LeaseStatus(lease: Lease(owner: "codex", reason: "", createdAt: t0, expiresAt: t0.addingTimeInterval(600), until: .pid(process), source: .cli), now: t0)
        XCTAssertEqual(a.line, "claude 'refactor billing' 1h 12m left")
        XCTAssertEqual(b.line, "codex 10m left")
        XCTAssertEqual(b.until, "pid 4242")
        XCTAssertEqual(LeaseStatus.menuLines([]), [])
        XCTAssertEqual(LeaseStatus.menuLines([b, a]), ["Leases: 2 \u{2014} claude 'refactor billing' 1h 12m left", "    codex 10m left"], "the longest-lived first")
        XCTAssertEqual(LeaseStatus.menuLines([a], waiting: true), ["Leases: 1 (waiting for a session) \u{2014} claude 'refactor billing' 1h 12m left"])
        let many = (0..<9).map { i in LeaseStatus(lease: Lease(owner: "a\(i)", reason: "", createdAt: t0, expiresAt: t0.addingTimeInterval(TimeInterval(600 + i * 60)), source: .cli), now: t0) }
        let lines = LeaseStatus.menuLines(many)
        XCTAssertEqual(lines.count, 7)
        XCTAssertEqual(lines.last, "    and 3 more")
        let capped = LeaseStatus(lease: Lease(owner: "x", reason: "", createdAt: t0, expiresAt: t0.addingTimeInterval(20 * 3600), source: .cli), now: t0.addingTimeInterval(3600), capSeconds: 8 * 3600)
        XCTAssertEqual(capped.remainingSeconds, 7 * 3600)
    }
}

final class LeaseStoreTests: LeaseScratchCase {
    func testAWriteIsOwnerOnlyAndLeavesNoTempFile() throws {
        let lease = Lease(owner: "claude", reason: "x", createdAt: t0, expiresAt: t0.addingTimeInterval(60), source: .cli)

        try store.write(lease)

        XCTAssertEqual(try mode(store.url(for: lease.id)), 0o600)
        XCTAssertEqual(try mode(store.directory), 0o700)
        XCTAssertEqual(try mode(home.appSupport), 0o700, "the support directory too, when the command is the first to make it")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path), [lease.fileName])
        XCTAssertEqual(store.load(id: lease.id), lease)
    }

    func testAWriteReplacesTheLeaseInOneStep() throws {
        var lease = Lease(owner: "claude", reason: "x", createdAt: t0, expiresAt: t0.addingTimeInterval(60), source: .cli)
        try store.write(lease)
        lease.expiresAt = t0.addingTimeInterval(3600)
        try store.write(lease)
        XCTAssertEqual(store.scan().leases, [lease])
        XCTAssertEqual(try mode(store.url(for: lease.id)), 0o600)
    }

    func testALooseDirectoryIsTightenedAndBitsAreOnlyCleared() throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try store.ensureDirectory()
        XCTAssertEqual(try mode(store.directory), 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.directory.path)
        try store.ensureDirectory()
        XCTAssertEqual(try mode(store.directory), 0o500)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path)
    }

    func testRemoveSaysWhetherThereWasALease() throws {
        let lease = Lease(owner: "claude", reason: "x", createdAt: t0, expiresAt: t0.addingTimeInterval(60), source: .cli)
        try store.write(lease)
        XCTAssertTrue(try store.remove(id: lease.id))
        XCTAssertFalse(try store.remove(id: lease.id))
        XCTAssertNil(store.load(id: lease.id))
    }

    func testAMissingDirectoryIsAnEmptyScan() {
        XCTAssertEqual(store.scan(), LeaseStore.Scan())
    }

    func testScanReadsLeasesOldestFirstAndRejectsEverythingElseWithAReason() throws {
        let newer = Lease(owner: "b", reason: "", createdAt: t0.addingTimeInterval(10), expiresAt: t0.addingTimeInterval(600), source: .cli)
        let older = Lease(owner: "a", reason: "", createdAt: t0, expiresAt: t0.addingTimeInterval(600), source: .mcp)
        try store.write(newer)
        try store.write(older)
        let dir = store.directory
        let fm = FileManager.default
        try Data("{".utf8).write(to: dir.appendingPathComponent("\(Lease.idText(UUID())).json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("notes.json"))
        // A lease copied to another name is not that lease.
        try fm.copyItem(at: store.url(for: older.id), to: dir.appendingPathComponent("\(Lease.idText(UUID())).json"))
        try fm.createSymbolicLink(at: dir.appendingPathComponent("\(Lease.idText(UUID())).json"), withDestinationURL: store.url(for: older.id))
        try fm.createDirectory(at: dir.appendingPathComponent("\(Lease.idText(UUID())).json"), withIntermediateDirectories: false)
        try Data(count: 70_000).write(to: dir.appendingPathComponent("\(Lease.idText(UUID())).json"))
        // Never looked at: a write in flight, and files that are not .json.
        try Data("x".utf8).write(to: dir.appendingPathComponent(".\(older.fileName).tmp-1"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".hidden.json"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("README"))

        let scan = store.scan()

        XCTAssertEqual(scan.leases, [older, newer])
        let reasons = scan.rejected.map(\.why).sorted()
        XCTAssertEqual(reasons.count, 6, "\(reasons)")
        XCTAssertEqual(reasons.filter { $0 == "not a regular file" }.count, 2, "the symlink and the directory are never opened")
        XCTAssertTrue(reasons.contains("its name is not a lease id"))
        XCTAssertTrue(reasons.contains("its id is not its file name"))
        XCTAssertTrue(reasons.contains("larger than a lease can be"))
        XCTAssertTrue(reasons.contains { $0.hasPrefix("not a lease: ") })
        XCTAssertTrue(scan.rejected.allSatisfy { $0.modifiedAt != nil })
    }

    func testAFIFOInTheDirectoryIsNotOpened() throws {
        try store.ensureDirectory()
        let fifo = store.directory.appendingPathComponent("\(Lease.idText(UUID())).json")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        // Would block forever if the scan opened it.
        XCTAssertEqual(store.scan().rejected.map(\.why), ["not a regular file"])
    }

    func testTheSettingsTheCommandReadsFromConfigJSON() throws {
        XCTAssertEqual(home.settings(), LeaseHome.Settings(), "no config.json: the app's defaults")
        XCTAssertEqual(home.settings().capSeconds, 8 * 3600)
        try FileManager.default.createDirectory(at: home.appSupport, withIntermediateDirectories: true)
        try Data(#"{"leasesEnabled":false,"leaseCapHours":3,"leasesMayStartSession":false,"other":1}"#.utf8).write(to: home.configFile)
        let s = home.settings()
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.capHours, 3)
        XCTAssertFalse(s.mayStartSession)
        try Data(#"{"leaseCapHours":0}"#.utf8).write(to: home.configFile)
        XCTAssertEqual(home.settings().capHours, 8, "a cap of 0 is not a cap")
        try Data("not json".utf8).write(to: home.configFile)
        XCTAssertEqual(home.settings(), LeaseHome.Settings())
    }

    func testTheHomeFollowsAWAKE_HOME() {
        XCTAssertEqual(LeaseHome.fromEnvironment(["AWAKE_HOME": "/x"]).leasesDirectory.path, "/x/leases")
        XCTAssertTrue(LeaseHome.fromEnvironment([:]).leasesDirectory.path.hasSuffix("/Library/Application Support/Awake/leases"))
        XCTAssertTrue(LeaseHome.fromEnvironment(["AWAKE_HOME": ""]).appSupport.path.hasSuffix("/Library/Application Support/Awake"))
    }
}

final class LeaseProcessProbeTests: XCTestCase {
    func testThisProcessIsPresentAndTellsItselfFromAnother() throws {
        guard case let .present(me) = LeaseProcessProbe.lookup(pid: getpid()) else { return XCTFail("this process is running") }
        XCTAssertEqual(me.pid, getpid())
        XCTAssertFalse(me.bootSession.isEmpty)
        XCTAssertEqual(LeaseProcessProbe.isRunning(me), true)
        var earlier = me
        earlier.startedAt -= 100
        XCTAssertEqual(LeaseProcessProbe.isRunning(earlier), false, "same pid, another start time: a reused pid")
        var otherBoot = me
        otherBoot.bootSession = "another-boot"
        XCTAssertEqual(LeaseProcessProbe.isRunning(otherBoot), false)
    }

    func testAbsentUnreadableAndUnprovable() {
        XCTAssertEqual(LeaseProcessProbe.lookup(pid: 0), .absent)
        XCTAssertEqual(LeaseProcessProbe.lookup(pid: -5), .absent)
        let p = LeaseProcess(pid: 77, startedAt: 1, startedAtMicros: 2, bootSession: "b")
        XCTAssertEqual(LeaseProcessProbe.isRunning(p) { _ in .absent }, false)
        XCTAssertNil(LeaseProcessProbe.isRunning(p) { _ in .unreadable(EPERM) })
        XCTAssertEqual(LeaseProcessProbe.isRunning(p) { _ in .present(p) }, true)
        var noBootNow = p
        noBootNow.bootSession = ""
        XCTAssertNil(LeaseProcessProbe.isRunning(p) { _ in .present(noBootNow) }, "no boot session to compare: unknown")
        XCTAssertEqual(LeaseProcessProbe.isRunning(noBootNow) { _ in .present(p) }, false, "a lease that never recorded one proves nothing")
    }

    func testAnExitedChildIsAbsent() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        XCTAssertEqual(LeaseProcessProbe.lookup(pid: child.processIdentifier), .absent)
    }
}

final class LeaseTmuxTests: XCTestCase {
    private func line(_ id: String, dead: String = "0", pid: String = "700", command: String) -> String {
        [id, dead, pid, "/tmp/tmux-501/default", command].joined(separator: LeaseTmux.separator) + "\n"
    }
    let shell = LeaseProcess(pid: 700, startedAt: 1, startedAtMicros: 2, bootSession: "b")

    func testInterpret() {
        XCTAssertEqual(
            LeaseTmux.interpret(.init(status: 0, stdout: line("%3", command: "node"), stderr: "")),
            .pane(.init(paneId: "%3", dead: false, pid: 700, socketPath: "/tmp/tmux-501/default", command: "node"))
        )
        // tmux 3.x: a target that names no pane exits 0 with empty fields.
        XCTAssertEqual(LeaseTmux.interpret(.init(status: 0, stdout: line("", dead: "", pid: "", command: ""), stderr: "")), .gone)
        XCTAssertEqual(LeaseTmux.interpret(.init(status: 0, stdout: "", stderr: "")), .gone)
        XCTAssertEqual(LeaseTmux.interpret(.init(status: 1, stdout: "", stderr: "can't find pane: %9\n")), .gone)
        XCTAssertEqual(LeaseTmux.interpret(.init(status: 1, stdout: "", stderr: "no server running on /tmp/tmux-501/default")), .gone)
        XCTAssertEqual(LeaseTmux.interpret(.init(status: 1, stdout: "", stderr: "error connecting to /tmp/x (No such file or directory)")), .gone)
        XCTAssertEqual(LeaseTmux.interpret(.init(status: 127, stdout: "", stderr: "could not run /opt/homebrew/bin/tmux: no such file or directory")), .unknown("could not run /opt/homebrew/bin/tmux: no such file or directory"))
        XCTAssertEqual(LeaseTmux.interpret(.init(status: 1, stdout: "", stderr: "")), .unknown("tmux exited 1"))
        XCTAssertEqual(LeaseTmux.interpret(.init(status: 0, stdout: "nonsense\n", stderr: "")), .unknown("unexpected tmux answer: nonsense"))
    }

    func testAShellPromptIsNotBusy() {
        func busy(_ command: String, dead: Bool = false) -> Bool {
            LeaseTmux.Reading(paneId: "%1", dead: dead, pid: 1, socketPath: "", command: command).isBusy
        }
        for shell in ["zsh", "-zsh", "bash", "fish", "sh", "login"] { XCTAssertFalse(busy(shell), shell) }
        for work in ["node", "claude", "python3.12", "make", "sleep"] { XCTAssertTrue(busy(work), work) }
        XCTAssertFalse(busy("node", dead: true))
        XCTAssertFalse(busy(""))
    }

    func testStateOfAPane() {
        let pane = LeasePane(target: "work:1.0", paneId: "%3", socketPath: "/tmp/tmux-501/default", process: shell)
        func state(_ out: LeaseTmux.Output?, lookup: LeaseProcessLookup? = nil) -> LeaseTmux.PaneState {
            LeaseTmux.state(of: pane, runner: { _ in out }, processLookup: { _ in lookup ?? .present(self.shell) })
        }
        XCTAssertEqual(state(.init(status: 0, stdout: line("%3", command: "node"), stderr: "")), .busy)
        XCTAssertEqual(state(.init(status: 0, stdout: line("%3", command: "zsh"), stderr: "")), .finished)
        XCTAssertEqual(state(.init(status: 0, stdout: line("%3", dead: "1", command: "node"), stderr: "")), .finished)
        XCTAssertEqual(state(.init(status: 1, stdout: "", stderr: "can't find pane: %3")), .finished)
        XCTAssertEqual(state(.init(status: 0, stdout: line("%3", pid: "999", command: "node"), stderr: "")), .finished, "the id now belongs to another pane")
        var later = shell
        later.startedAt += 9
        XCTAssertEqual(state(.init(status: 0, stdout: line("%3", command: "node"), stderr: ""), lookup: .present(later)), .finished, "and so does the pid")
        XCTAssertEqual(state(.init(status: 0, stdout: line("%3", command: "node"), stderr: ""), lookup: .unreadable(EPERM)), .unknown("the pane's process could not be read"))
        guard case .unknown = state(nil) else { return XCTFail("tmux not installed is unknown, not finished") }
    }

    func testArgumentsOnlyEverRead() {
        XCTAssertEqual(LeaseTmux.arguments(target: "work:1.0", socketPath: nil), ["display-message", "-p", "-t", "work:1.0", "-F", LeaseTmux.format])
        XCTAssertEqual(LeaseTmux.arguments(target: "%3", socketPath: "/tmp/s"), ["-S", "/tmp/s", "display-message", "-p", "-t", "%3", "-F", LeaseTmux.format])
    }

    /// Against a private tmux server, so the format, the separator and the
    /// "no such pane" answer are the real ones. Skipped without tmux.
    func testAgainstARealPrivateServer() throws {
        guard let tmux = LeaseTmux.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("tmux is not installed")
        }
        let socket = "/tmp/awake-lease-test-\(getpid()).sock"
        func run(_ args: [String]) throws -> Int32 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tmux)
            p.arguments = ["-S", socket, "-f", "/dev/null"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        }
        XCTAssertEqual(try run(["new-session", "-d", "-s", "lease", "-x", "80", "-y", "24", "/bin/sleep 600"]), 0)
        defer { _ = try? run(["kill-server"]) }

        // The pane's command is `sleep` once the server has started it.
        var answer = LeaseTmux.read(target: "lease:0.0", socketPath: socket)
        for _ in 0..<50 {
            if case let .pane(r) = answer, r.command == "sleep" { break }
            usleep(100_000)
            answer = LeaseTmux.read(target: "lease:0.0", socketPath: socket)
        }
        guard case let .pane(reading) = answer else { return XCTFail("\(answer)") }
        XCTAssertTrue(reading.paneId.hasPrefix("%"))
        XCTAssertEqual(reading.command, "sleep")
        XCTAssertTrue(reading.isBusy)
        XCTAssertFalse(reading.dead)
        XCTAssertEqual(URL(fileURLWithPath: reading.socketPath).resolvingSymlinksInPath().path, URL(fileURLWithPath: socket).resolvingSymlinksInPath().path)
        guard case let .present(process) = LeaseProcessProbe.lookup(pid: reading.pid) else { return XCTFail("the pane's process is running") }
        let pane = LeasePane(target: "lease:0.0", paneId: reading.paneId, socketPath: socket, process: process)
        XCTAssertEqual(LeaseTmux.state(of: pane), .busy)

        XCTAssertEqual(LeaseTmux.read(target: "nope:9.9", socketPath: socket), .gone)
        XCTAssertEqual(LeaseTmux.read(target: "%99", socketPath: socket), .gone)

        XCTAssertEqual(try run(["kill-server"]), 0)
        XCTAssertEqual(LeaseTmux.state(of: pane), .finished)
        XCTAssertEqual(LeaseTmux.read(target: "lease:0.0", socketPath: socket), .gone)
    }
}
