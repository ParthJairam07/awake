import AwakeLeaseKit
import XCTest
@testable import awake_cli

/// Collects what the command prints.
final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    var text: String { lines.joined(separator: "\n") }
    func add(_ line: String) { lock.withLock { _lines.append(line) } }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

/// A child for `--until-exit` that never starts a process.
final class FakeCommand: SpawnedCommand, @unchecked Sendable {
    let pid: Int32
    let status: Int32
    let whileRunning: @Sendable () -> Void
    init(pid: Int32, status: Int32, whileRunning: @escaping @Sendable () -> Void = {}) {
        self.pid = pid
        self.status = status
        self.whileRunning = whileRunning
    }
    func wait() -> Int32 {
        whileRunning()
        return status
    }
}

class CLICase: LeaseScratchCase {
    var out: Lines!
    var err: Lines!
    var clock: Box<Date>!
    var appRunning: Box<Bool>!
    var processes: Box<[Int32: LeaseProcessLookup]>!
    var tmux: Box<LeaseTmux.Output?>!
    var spawned: Box<[[String]]>!
    var nextCommand: Box<FakeCommand?>!

    override func setUpWithError() throws {
        try super.setUpWithError()
        out = Lines()
        err = Lines()
        clock = Box(t0)
        appRunning = Box(true)
        processes = Box([:])
        tmux = Box(nil)
        spawned = Box([])
        nextCommand = Box(nil)
    }

    var env: CLIEnvironment {
        let (out, err, clock, appRunning, processes, tmux, spawned, nextCommand) = (out!, err!, clock!, appRunning!, processes!, tmux!, spawned!, nextCommand!)
        return CLIEnvironment(
            home: home,
            now: { clock.value },
            appRunning: { appRunning.value },
            processLookup: { processes.value[$0] ?? .absent },
            tmux: { _ in tmux.value },
            userName: "parth",
            environment: [:],
            out: { out.add($0) },
            err: { err.add($0) },
            spawn: { args in
                spawned.value.append(args)
                guard let command = nextCommand.value else { throw SpawnError.notFound(args[0]) }
                return command
            },
            version: "9.9"
        )
    }

    @discardableResult
    func run(_ args: String...) -> Int32 { CLI.run(args, in: env) }

    func process(_ pid: Int32) -> LeaseProcess {
        let p = LeaseProcess(pid: pid, startedAt: 1_799_999_000, startedAtMicros: 42, bootSession: "boot-1")
        processes.value[pid] = .present(p)
        return p
    }

    var onDisk: [Lease] { store.scan().leases }
}

final class CLILeaseTests: CLICase {
    func testLeasePrintsTheIdAndWritesTheFile() throws {
        XCTAssertEqual(run("lease", "--for", "2h", "--reason", "refactor billing", "--owner", "claude"), 0)

        let lease = try XCTUnwrap(onDisk.first)
        XCTAssertEqual(out.lines, [Lease.idText(lease.id)], "stdout is the id alone, for $(...)")
        XCTAssertEqual(err.lines, [])
        XCTAssertEqual(lease.owner, "claude")
        XCTAssertEqual(lease.reason, "refactor billing")
        XCTAssertEqual(lease.createdAt, t0)
        XCTAssertEqual(lease.expiresAt, t0.addingTimeInterval(7200))
        XCTAssertEqual(lease.source, .cli)
        XCTAssertNil(lease.until)
        XCTAssertEqual(try mode(store.url(for: lease.id)), 0o600)
    }

    func testTheOwnerDefaultsToTheUserOrTheEnvironment() throws {
        run("lease", "--for", "1h")
        XCTAssertEqual(onDisk.first?.owner, "parth")
        var e = env
        e.environment = ["AWAKE_LEASE_OWNER": "codex"]
        XCTAssertEqual(CLI.run(["lease", "--for=1h", "--reason=x"], in: e), 0)
        XCTAssertTrue(onDisk.contains { $0.owner == "codex" && $0.reason == "x" })
    }

    func testItWorksAndWarnsWhenTheAppIsNotRunning() throws {
        appRunning.value = false
        XCTAssertEqual(run("lease", "--for", "30m", "--reason", "x"), 0)
        XCTAssertEqual(onDisk.count, 1, "the file is written all the same")
        XCTAssertEqual(err.lines, ["awake: warning: Awake.app is not running; lease will take effect when it starts"])
        XCTAssertEqual(out.lines.count, 1)
    }

    func testItWarnsWhenLeasesAreOffOrCannotStartASession() throws {
        try FileManager.default.createDirectory(at: home.appSupport, withIntermediateDirectories: true)
        try Data(#"{"leasesEnabled":false}"#.utf8).write(to: home.configFile)
        run("lease", "--for", "30m")
        XCTAssertEqual(err.lines, ["awake: warning: leases are turned off in Awake's Settings; this lease holds nothing until they are turned on"])

        err = Lines()
        try Data(#"{"leasesMayStartSession":false}"#.utf8).write(to: home.configFile)
        run("lease", "--for", "30m")
        XCTAssertEqual(err.lines, ["awake: warning: leases may not start a session (Awake's Settings) and none is running; this lease holds nothing until you start one"])

        err = Lines()
        try Data(#"{"active":true,"endsAt":"2027-01-15T09:00:00Z"}"#.utf8).write(to: home.statusFile)
        run("lease", "--for", "30m")
        XCTAssertEqual(err.lines, [], "a session is running: the lease stretches it")
    }

    func testALeaseLongerThanTheCapSaysSo() throws {
        try FileManager.default.createDirectory(at: home.appSupport, withIntermediateDirectories: true)
        try Data(#"{"leaseCapHours":3}"#.utf8).write(to: home.configFile)
        XCTAssertEqual(run("lease", "--for", "10h"), 0)
        XCTAssertEqual(err.lines, ["awake: note: Awake's lease cap is 3h, so this lease counts for 3h"])
        XCTAssertEqual(onDisk.first?.expiresAt, t0.addingTimeInterval(36000), "the file keeps what was asked; the app applies the cap")
    }

    func testBadArguments() {
        let cases: [([String], Int32, String)] = [
            ([], 2, "usage: awake <command>"),
            (["frobnicate"], 2, "unknown command: frobnicate"),
            (["lease"], 2, "--for is needed"),
            (["lease", "--for"], 2, "--for needs a value"),
            (["lease", "--for", "2h", "--bogus"], 2, "unknown option: --bogus"),
            (["lease", "--for", "2h", "extra"], 2, "unexpected argument: extra"),
            (["lease", "--for", "2h", "--for", "3h"], 2, "--for given twice"),
            (["lease", "--for", "90"], 1, "\"90\" is not a duration"),
            (["lease", "--for", "30s"], 1, "a lease lasts at least 1m"),
            (["lease", "--for", "2h", "--grace", "5m"], 2, "--grace goes with an --until"),
            (["lease", "--for", "2h", "--until-pid", "1", "--until-tmux", "a:0.0"], 2, "give one of"),
            (["lease", "--for", "2h", "--until-pid", "abc"], 2, "--until-pid needs a process id"),
            (["lease", "--for", "2h", "--until-pid", "5", "--grace", "soon"], 1, "is not a grace period"),
            (["lease", "--for", "2h", "--until-exit"], 2, "--until-exit needs a command"),
            (["lease", "--for", "2h", "--", "make"], 2, "a command after -- needs --until-exit"),
            (["lease", "--for", "2h", "--owner", "  "], 1, "the owner is empty"),
            (["release"], 2, "give one lease id"),
            (["release", "--all", "--owner", "x"], 2, "give one lease id"),
            (["extend", "abcd"], 2, "usage: awake extend"),
            (["leases", "--yaml"], 2, "unknown option: --yaml"),
            (["mcp", "now"], 2, "awake mcp takes no arguments"),
        ]
        for (args, status, message) in cases {
            err = Lines()
            XCTAssertEqual(CLI.run(args, in: env), status, "\(args)")
            XCTAssertTrue(err.text.contains(message), "\(args): \(err.text)")
        }
        XCTAssertEqual(onDisk, [], "nothing was written by any of them")
    }

    func testHelpAndVersion() {
        XCTAssertEqual(run("help"), 0)
        XCTAssertTrue(out.text.contains("awake lease --for 2h"))
        out = Lines()
        XCTAssertEqual(run("--version"), 0)
        XCTAssertEqual(out.lines, ["awake 9.9"])
    }

    // MARK: until

    func testUntilPidRecordsTheProcessIdentity() throws {
        let p = process(4242)
        XCTAssertEqual(run("lease", "--until-pid", "4242", "--grace", "10m", "--reason", "build"), 0)
        let lease = try XCTUnwrap(onDisk.first)
        XCTAssertEqual(lease.until, .pid(p))
        XCTAssertEqual(lease.graceSeconds, 600)
        XCTAssertEqual(lease.expiresAt, t0.addingTimeInterval(8 * 3600), "without --for, the cap")
    }

    func testUntilPidRefusesAProcessItCannotIdentify() {
        XCTAssertEqual(run("lease", "--for", "1h", "--until-pid", "4242"), 1)
        XCTAssertEqual(err.lines, ["awake: no process with pid 4242"])
        processes.value[7] = .unreadable(EPERM)
        XCTAssertEqual(run("lease", "--for", "1h", "--until-pid", "7"), 1)
        processes.value[8] = .present(LeaseProcess(pid: 8, startedAt: 1, startedAtMicros: 1, bootSession: ""))
        XCTAssertEqual(run("lease", "--for", "1h", "--until-pid", "8"), 1)
        XCTAssertEqual(onDisk, [])
    }

    func testUntilTmuxRecordsThePaneItsSocketAndItsProcess() throws {
        let shell = process(700)
        tmux.value = .init(status: 0, stdout: ["%3", "0", "700", "/tmp/tmux-501/default", "node"].joined(separator: LeaseTmux.separator), stderr: "")
        XCTAssertEqual(run("lease", "--for", "3h", "--until-tmux", "work:1.0"), 0)
        XCTAssertEqual(onDisk.first?.until, .tmux(LeasePane(target: "work:1.0", paneId: "%3", socketPath: "/tmp/tmux-501/default", process: shell)))
        XCTAssertEqual(err.lines, [])
    }

    func testUntilTmuxWarnsAboutAPaneAtAPromptAndRefusesOneThatIsNotThere() {
        _ = process(700)
        tmux.value = .init(status: 0, stdout: ["%3", "0", "700", "/tmp/s", "zsh"].joined(separator: LeaseTmux.separator), stderr: "")
        XCTAssertEqual(run("lease", "--for", "3h", "--until-tmux", "work:1.0"), 0)
        XCTAssertTrue(err.text.contains("pane work:1.0 is at a shell prompt (zsh)"), err.text)

        tmux.value = .init(status: 1, stdout: "", stderr: "can't find pane: nope")
        XCTAssertEqual(run("lease", "--for", "3h", "--until-tmux", "nope"), 1)
        XCTAssertTrue(err.text.contains("tmux has no pane nope"))
        tmux.value = nil
        XCTAssertEqual(run("lease", "--for", "3h", "--until-tmux", "x"), 1)
        XCTAssertTrue(err.text.contains("tmux is not installed"))
        XCTAssertEqual(onDisk.count, 1)
    }

    func testUntilExitHoldsTheLeaseWhileTheCommandRunsAndPassesItsStatusOn() throws {
        let child = process(555)
        let store = store!
        let seen = Box<[Lease]>([])
        nextCommand.value = FakeCommand(pid: 555, status: 7) { seen.value = store.scan().leases }

        XCTAssertEqual(run("lease", "--for", "2h", "--owner", "ci", "--until-exit", "--", "/usr/bin/make", "test", "--for", "x"), 7)

        XCTAssertEqual(spawned.value, [["/usr/bin/make", "test", "--for", "x"]], "everything after -- is the command's")
        let held = try XCTUnwrap(seen.value.first, "the lease existed while the command ran")
        XCTAssertEqual(held.until, .command(child, name: "make"))
        XCTAssertEqual(held.reason, "make", "the command's name stands in for a reason; its arguments are never written")
        XCTAssertEqual(held.owner, "ci")
        XCTAssertEqual(onDisk, [], "released on exit")
        XCTAssertEqual(out.lines, [], "stdout belongs to the command")
        XCTAssertEqual(err.lines, ["awake: lease \(Lease.idText(held.id)) held while make runs"])
    }

    func testUntilExitWithAGraceLeavesAPlainLeaseThatExpiresAfterIt() throws {
        _ = process(555)
        let clock = clock!
        nextCommand.value = FakeCommand(pid: 555, status: 0) { clock.value = clock.value.addingTimeInterval(1000) }

        XCTAssertEqual(run("lease", "--for", "2h", "--grace", "5m", "--until-exit", "sleep", "1"), 0)

        let left = try XCTUnwrap(onDisk.first)
        XCTAssertNil(left.until)
        XCTAssertEqual(left.expiresAt, t0.addingTimeInterval(1000 + 300))
        XCTAssertEqual(spawned.value, [["sleep", "1"]], "the -- may be left out")
    }

    func testUntilExitDoesNotWriteBackALeaseReleasedOrRevokedMeanwhile() throws {
        _ = process(555)
        let store = store!
        nextCommand.value = FakeCommand(pid: 555, status: 0) {
            for lease in store.scan().leases { _ = try? store.remove(id: lease.id) }
        }
        XCTAssertEqual(run("lease", "--for", "2h", "--grace", "5m", "--until-exit", "--", "make"), 0)
        XCTAssertEqual(onDisk, [], "the app revoked it; the command does not bring it back")
    }

    func testUntilExitRunsTheCommandEvenWhenNoLeaseCanBeMade() {
        nextCommand.value = FakeCommand(pid: 556, status: 3)
        XCTAssertEqual(run("lease", "--for", "2h", "--until-exit", "--", "true"), 3)
        XCTAssertTrue(err.text.contains("no lease was made"), err.text)
        XCTAssertEqual(onDisk, [])
    }

    func testUntilExitWithACommandThatDoesNotExist() {
        XCTAssertEqual(run("lease", "--for", "2h", "--until-exit", "--", "no-such-command"), 127)
        XCTAssertEqual(err.lines, ["awake: no-such-command: command not found"])
    }

    /// The real child path: a real process, its real status, a real lease
    /// in the scratch directory while it runs.
    func testUntilExitWithARealCommand() throws {
        var e = env
        e.processLookup = { LeaseProcessProbe.lookup(pid: $0) }
        e.spawn = { try LiveCommand(arguments: $0) }
        let marker = root.appendingPathComponent("seen")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = "ls \"$1\" > \"$2\"; exit 5"

        let status = CLI.run(["lease", "--for", "5m", "--reason", "real", "--until-exit", "--", "/bin/sh", "-c", script, "sh", store.directory.path, marker.path], in: e)

        XCTAssertEqual(status, 5)
        let listed = try String(contentsOf: marker, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(listed.count, 1, "the lease file was there while the command ran")
        XCTAssertTrue(listed[0].hasSuffix(".json"))
        XCTAssertEqual(onDisk, [])
        signal(SIGINT, SIG_DFL)
        signal(SIGQUIT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
        signal(SIGHUP, SIG_DFL)
    }

    func testCommandLookup() {
        XCTAssertEqual(LiveCommand.resolve("sh", path: "/nonexistent:/bin"), "/bin/sh")
        XCTAssertEqual(LiveCommand.resolve("/bin/sh", path: ""), "/bin/sh")
        XCTAssertNil(LiveCommand.resolve("sh", path: "/nonexistent"))
        XCTAssertNil(LiveCommand.resolve("/bin", path: "/"), "a directory is not a command")
    }

    // MARK: release / extend / leases / status

    func testReleaseByIdByPrefixByOwnerAndAll() throws {
        for owner in ["claude", "claude", "codex", "aider"] { run("lease", "--for", "1h", "--owner", owner) }
        let ids = out.lines
        out = Lines()

        XCTAssertEqual(run("release", ids[0]), 0)
        XCTAssertEqual(out.lines, ["released \(ids[0])"])
        XCTAssertEqual(run("release", String(ids[1].prefix(8)).uppercased()), 0, "a prefix, in either case")
        XCTAssertEqual(run("release", ids[0]), 1)
        XCTAssertTrue(err.text.contains("no lease \(ids[0])"))
        XCTAssertEqual(run("release", "abc"), 1, "too short to be a prefix")

        out = Lines()
        XCTAssertEqual(run("release", "--owner", "codex"), 0)
        XCTAssertEqual(out.lines, ["released \(ids[2])"])
        XCTAssertEqual(run("release", "--all"), 0)
        XCTAssertEqual(onDisk, [])
        out = Lines()
        XCTAssertEqual(run("release", "--all"), 0)
        XCTAssertEqual(out.lines, ["no leases to release"])
    }

    func testAnAmbiguousPrefixIsRefused() throws {
        let a = Lease(id: try XCTUnwrap(UUID(uuidString: "aaaa1111-0000-4000-8000-000000000001")), owner: "a", reason: "", createdAt: t0, expiresAt: t0.addingTimeInterval(600), source: .cli)
        let b = Lease(id: try XCTUnwrap(UUID(uuidString: "aaaa1111-0000-4000-8000-000000000002")), owner: "b", reason: "", createdAt: t0, expiresAt: t0.addingTimeInterval(600), source: .cli)
        try store.write(a)
        try store.write(b)
        XCTAssertEqual(run("release", "aaaa1111"), 1)
        XCTAssertTrue(err.text.contains("2 leases start with aaaa1111"))
        XCTAssertEqual(onDisk.count, 2)
    }

    func testExtend() throws {
        run("lease", "--for", "1h", "--owner", "claude")
        let id = out.lines[0]
        out = Lines()
        clock.value = t0.addingTimeInterval(600)

        XCTAssertEqual(run("extend", id, "--by", "30m"), 0)

        XCTAssertEqual(onDisk.first?.expiresAt, t0.addingTimeInterval(5400))
        XCTAssertEqual(onDisk.first?.createdAt, t0)
        XCTAssertEqual(out.lines, ["\(id) now expires in 1h 20m"])

        clock.value = t0.addingTimeInterval(6000)
        XCTAssertEqual(run("extend", id, "--by", "30m"), 1, "an expired lease is not brought back")
        XCTAssertEqual(run("extend", id, "--by", "soon"), 1)
        XCTAssertEqual(run("extend", "ffffffff", "--by", "1h"), 1)
    }

    func testLeasesTableAndJSON() throws {
        let p = process(4242)
        try store.write(Lease(id: try XCTUnwrap(UUID(uuidString: "11111111-0000-4000-8000-000000000001")), owner: "claude", reason: "refactor billing", createdAt: t0, expiresAt: t0.addingTimeInterval(4320), source: .mcp))
        try store.write(Lease(id: try XCTUnwrap(UUID(uuidString: "22222222-0000-4000-8000-000000000002")), owner: "ci", reason: "", createdAt: t0.addingTimeInterval(1), expiresAt: t0.addingTimeInterval(600), until: .pid(p), source: .cli))
        try store.write(Lease(owner: "old", reason: "", createdAt: t0.addingTimeInterval(-7200), expiresAt: t0.addingTimeInterval(-10), source: .cli))

        XCTAssertEqual(run("leases"), 0)
        XCTAssertEqual(out.lines, [
            "ID                                    OWNER   LEFT    UNTIL     SOURCE  REASON",
            "11111111-0000-4000-8000-000000000001  claude  1h 12m  -         mcp     refactor billing",
            "22222222-0000-4000-8000-000000000002  ci      10m     pid 4242  cli     ",
        ])
        XCTAssertEqual(onDisk.count, 3, "listing deletes nothing, the expired file included")

        out = Lines()
        XCTAssertEqual(run("leases", "--json"), 0)
        let decoded = try LeaseJSON.decoder().decode([LeaseStatus].self, from: Data(out.text.utf8))
        XCTAssertEqual(decoded.map(\.owner), ["claude", "ci"])
        XCTAssertEqual(decoded[0].remainingSeconds, 4320)
        XCTAssertEqual(decoded[1].until, "pid 4242")

        out = Lines()
        appRunning.value = false
        run("leases")
        XCTAssertEqual(err.lines, ["awake: warning: Awake.app is not running; leases will take effect when it starts"])
    }

    func testNoLeases() {
        XCTAssertEqual(run("leases"), 0)
        XCTAssertEqual(out.lines, ["no leases"])
        out = Lines()
        XCTAssertEqual(run("leases", "--json"), 0)
        XCTAssertEqual(out.text.filter { !$0.isWhitespace }, "[]")
    }

    func testStatusReadsStatusJSON() throws {
        XCTAssertEqual(run("status"), 1)
        XCTAssertTrue(err.text.contains("no status yet"), err.text)

        try FileManager.default.createDirectory(at: home.appSupport, withIntermediateDirectories: true)
        let json = #"{"active":true,"batteryPercent":64,"chargerDraining":false,"dockerPaused":false,"endsAt":"2027-01-15T09:12:00Z","frozenCount":0,"isCharging":true,"leases":[],"lidClosed":true,"lidOnDesk":false,"lowPowerSetByUs":false,"remainingSeconds":9999,"thermalState":"nominal","updatedAt":"2027-01-15T07:59:30Z"}"#
        try Data(json.utf8).write(to: home.statusFile)
        run("lease", "--for", "30m", "--owner", "claude", "--reason", "x")
        out = Lines()

        XCTAssertEqual(run("status"), 0)
        XCTAssertEqual(out.lines, [
            "Session: active, 1h 12m left",
            "Battery: 64%, charging",
            "Lid: closed",
            "Thermal: nominal",
            "Leases: 1",
            "  claude 'x' 30m left",
            "Updated: 30s ago",
        ], "the time left is worked out from endsAt now, not the stale remainingSeconds")

        out = Lines()
        XCTAssertEqual(run("status", "--json"), 0)
        XCTAssertEqual(out.text, json, "the file as it is")

        out = Lines()
        appRunning.value = false
        clock.value = t0.addingTimeInterval(3 * 3600)
        run("status")
        XCTAssertEqual(Array(out.lines.prefix(2)), ["Awake.app is not running; this is the last status it wrote.", "Session: its time is up"])

        try Data("garbage".utf8).write(to: home.statusFile)
        XCTAssertEqual(run("status"), 1)
    }

    func testTheAppIsToldFromThisCommandByItsExactPath() {
        XCTAssertTrue(AppProbe.isAppExecutable("/Users/x/Applications/Awake.app/Contents/MacOS/Awake"))
        XCTAssertTrue(AppProbe.isAppExecutable("/x/.build/debug/Awake"))
        XCTAssertFalse(AppProbe.isAppExecutable("/Users/x/Applications/Awake.app/Contents/Helpers/awake"))
        XCTAssertFalse(AppProbe.isAppExecutable("/x/.build/debug/awake-cli"))
        XCTAssertFalse(AppProbe.isAppExecutable("/usr/local/bin/awake"))
        XCTAssertEqual(AppProbe.version(executable: URL(fileURLWithPath: "/nonexistent/Contents/Helpers/awake")), "dev")
    }
}
