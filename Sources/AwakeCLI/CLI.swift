import AwakeLeaseKit
import Foundation

/// The `awake` command. `run` returns the exit status: 0 done, 1 could not
/// be done, 2 the arguments were wrong. `lease --until-exit` returns its
/// command's own status.
enum CLI {
    static let usage = """
    usage: awake <command>

      awake lease --for 2h --reason "refactor billing" [--owner NAME] [--grace 10m]
                  [--until-pid PID | --until-tmux SESSION:WINDOW.PANE | --until-exit -- COMMAND...]
          Ask Awake to keep the Mac awake. Prints the lease id.
          --for         how long at most: 90m, 2h, 1h30m. Needed unless an
                        --until is given; then the default is Awake's lease cap.
          --until-pid   release when that process exits.
          --until-tmux  release when that pane is back at a shell prompt or gone.
          --until-exit  run COMMAND, hold the lease while it runs, release when
                        it exits, and exit with its status.
          --grace       how long the lease outlives what it waits for.
      awake release <ID | --all | --owner NAME>
      awake extend <ID> --by 1h
      awake leases [--json]
      awake status [--json]
      awake mcp     Serve the same as MCP tools on stdin/stdout, for agents.

    An ID can be shortened to its first characters. Leases are files in
    Application Support/Awake/leases; Awake.app does not have to be running.
    """

    enum Usage: Error, Equatable {
        case message(String)
    }

    static func run(_ args: [String], in env: CLIEnvironment) -> Int32 {
        guard let command = args.first else {
            env.err(usage)
            return 2
        }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "lease": return try lease(rest, env)
            case "release": return try release(rest, env)
            case "extend": return try extend(rest, env)
            case "leases", "list": return try leases(rest, env)
            case "status": return try status(rest, env)
            case "mcp":
                guard rest.isEmpty else { throw Usage.message("awake mcp takes no arguments") }
                return MCPServer(env: env).serveStandardInput()
            case "help", "--help", "-h":
                env.out(usage)
                return 0
            case "version", "--version":
                env.out("awake \(env.version)")
                return 0
            default:
                throw Usage.message("unknown command: \(command)")
            }
        } catch let Usage.message(text) {
            env.err("awake: \(text)")
            env.err("Run `awake help` for the commands.")
            return 2
        } catch {
            env.err("awake: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: Arguments

    /// Options with a value and flags without, in any order; `--` ends
    /// them and everything after it is `trailing`.
    struct Parsed {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        var positional: [String] = []
        var trailing: [String]?
    }

    static func parse(_ args: [String], values: Set<String>, flags: Set<String>, trailingAfter: String? = nil) throws -> Parsed {
        var parsed = Parsed()
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" {
                guard trailingAfter != nil else { throw Usage.message("unexpected --") }
                parsed.trailing = Array(args[(i + 1)...])
                break
            }
            if arg.hasPrefix("--") {
                var name = arg
                var inline: String?
                if let eq = arg.firstIndex(of: "=") {
                    name = String(arg[..<eq])
                    inline = String(arg[arg.index(after: eq)...])
                }
                if values.contains(name) {
                    guard parsed.values[name] == nil else { throw Usage.message("\(name) given twice") }
                    if let inline {
                        parsed.values[name] = inline
                    } else {
                        guard i + 1 < args.count else { throw Usage.message("\(name) needs a value") }
                        i += 1
                        parsed.values[name] = args[i]
                    }
                } else if flags.contains(name), inline == nil {
                    parsed.flags.insert(name)
                    if name == trailingAfter {
                        // `--until-exit -- cmd`; the `--` may be left out.
                        let after = Array(args[(i + 1)...])
                        parsed.trailing = after.first == "--" ? Array(after.dropFirst()) : after
                        break
                    }
                } else {
                    throw Usage.message("unknown option: \(name)")
                }
            } else {
                parsed.positional.append(arg)
            }
            i += 1
        }
        return parsed
    }

    // MARK: lease

    private static func lease(_ args: [String], _ env: CLIEnvironment) throws -> Int32 {
        let p = try parse(args, values: ["--for", "--reason", "--owner", "--until-pid", "--until-tmux", "--grace"], flags: ["--until-exit"], trailingAfter: "--until-exit")
        guard p.positional.isEmpty else { throw Usage.message("unexpected argument: \(p.positional[0])") }
        let untils = [p.values["--until-pid"] != nil, p.values["--until-tmux"] != nil, p.flags.contains("--until-exit")].filter { $0 }.count
        guard untils <= 1 else { throw Usage.message("give one of --until-pid, --until-tmux and --until-exit") }
        if p.trailing != nil, !p.flags.contains("--until-exit") { throw Usage.message("a command after -- needs --until-exit") }
        guard untils == 1 || p.values["--for"] != nil else { throw Usage.message("--for is needed (for example --for 2h)") }

        let service = LeaseService(env: env)
        let duration = try p.values["--for"].map(LeaseService.duration)
        let grace = try p.values["--grace"].map(LeaseService.grace) ?? 0
        if p.values["--grace"] != nil, untils == 0 { throw Usage.message("--grace goes with an --until") }
        let owner = p.values["--owner"] ?? env.environment["AWAKE_LEASE_OWNER"] ?? env.userName
        let reason = p.values["--reason"] ?? ""

        if p.flags.contains("--until-exit") {
            guard let command = p.trailing, !command.isEmpty else { throw Usage.message("--until-exit needs a command: awake lease --until-exit -- make test") }
            return try holdWhileRunning(command, service: service, duration: duration, reason: reason, owner: owner, grace: grace, env: env)
        }

        var until: LeaseUntil?
        if let text = p.values["--until-pid"] {
            guard let pid = Int32(text), pid > 0 else { throw Usage.message("--until-pid needs a process id") }
            until = try service.untilPid(pid)
        } else if let target = p.values["--until-tmux"] {
            let found = try service.untilTmux(target)
            until = found.until
            if !found.reading.isBusy {
                env.err("awake: warning: pane \(target) is at a \(found.reading.dead ? "dead pane" : "shell prompt (\(found.reading.command))"); the lease is released \(grace > 0 ? "after its grace" : "at Awake's next check") unless a command is running there")
            }
        }
        let lease = try service.grant(duration: duration, reason: reason, owner: owner, until: until, graceSeconds: grace, source: .cli)
        warn(about: lease, service: service, env: env)
        env.out(Lease.idText(lease.id))
        return 0
    }

    /// What the caller should know about the lease just made, on stderr so
    /// stdout stays the id alone.
    private static func warn(about lease: Lease, service: LeaseService, env: CLIEnvironment) {
        for note in service.cautions() { env.err("awake: warning: \(note)") }
        let settings = env.home.settings()
        let capped = LeaseRules.effectiveExpiry(of: lease, capSeconds: settings.capSeconds)
        if capped < lease.expiresAt {
            env.err("awake: note: Awake's lease cap is \(settings.capHours)h, so this lease counts for \(LeaseDuration.format(capped.timeIntervalSince(lease.createdAt)))")
        }
    }

    private static func holdWhileRunning(_ command: [String], service: LeaseService, duration: TimeInterval?, reason: String, owner: String, grace: Int, env: CLIEnvironment) throws -> Int32 {
        let child: any SpawnedCommand
        do {
            child = try env.spawn(command)
        } catch let error as SpawnError {
            env.err("awake: \(error.localizedDescription)")
            if case .notFound = error { return 127 }
            return 126
        }
        let name = URL(fileURLWithPath: command[0]).lastPathComponent
        var lease: Lease?
        // The lease names the child by pid and start time, so the app
        // releases it by itself if this process is killed before it can.
        if case let .present(process) = env.processLookup(child.pid), !process.bootSession.isEmpty {
            do {
                let made = try service.grant(duration: duration, reason: reason.isEmpty ? name : reason, owner: owner, until: .command(process, name: name), graceSeconds: grace, source: .cli)
                lease = made
                warn(about: made, service: service, env: env)
                env.err("awake: lease \(Lease.idText(made.id)) held while \(name) runs")
            } catch {
                env.err("awake: warning: no lease was made (\(error.localizedDescription)); \(name) runs without one")
            }
        } else {
            env.err("awake: warning: \(name) had already exited, or could not be read; no lease was made")
        }
        let status = child.wait()
        if let lease {
            do {
                // Only if the file is still this lease: one released by
                // hand, or revoked by the app, is not written back.
                if let current = env.store.load(id: lease.id), current == lease {
                    if grace > 0 {
                        var kept = lease
                        kept.until = nil
                        kept.expiresAt = min(lease.expiresAt, LeaseJSON.wholeSeconds(env.now()).addingTimeInterval(TimeInterval(grace)))
                        try env.store.write(kept)
                    } else {
                        try service.release(lease)
                    }
                }
            } catch {
                env.err("awake: warning: lease \(Lease.idText(lease.id)) could not be released (\(error.localizedDescription)); Awake releases it once it sees \(name) gone")
            }
        }
        return status
    }

    // MARK: release / extend

    private static func release(_ args: [String], _ env: CLIEnvironment) throws -> Int32 {
        let p = try parse(args, values: ["--owner"], flags: ["--all"])
        let service = LeaseService(env: env)
        let ways = (p.flags.contains("--all") ? 1 : 0) + (p.values["--owner"] != nil ? 1 : 0) + (p.positional.isEmpty ? 0 : 1)
        guard ways == 1, p.positional.count <= 1 else { throw Usage.message("give one lease id, or --all, or --owner NAME") }
        if let id = p.positional.first {
            let lease = try service.find(id)
            try service.release(lease)
            env.out("released \(Lease.idText(lease.id))")
            return 0
        }
        let released = try service.releaseAll(owner: p.values["--owner"])
        if released.isEmpty {
            env.out("no leases to release")
        }
        for lease in released { env.out("released \(Lease.idText(lease.id))") }
        return 0
    }

    private static func extend(_ args: [String], _ env: CLIEnvironment) throws -> Int32 {
        let p = try parse(args, values: ["--by"], flags: [])
        guard p.positional.count == 1, let by = p.values["--by"] else { throw Usage.message("usage: awake extend <ID> --by 1h") }
        guard let seconds = LeaseDuration.seconds(from: by) else { throw LeaseService.Failure.badDuration(by) }
        let service = LeaseService(env: env)
        let extended = try service.extend(try service.find(p.positional[0]), by: seconds)
        warn(about: extended, service: service, env: env)
        let left = extended.expiresAt.timeIntervalSince(env.now())
        env.out("\(Lease.idText(extended.id)) now expires in \(LeaseDuration.format(left))")
        return 0
    }

    // MARK: leases / status

    private static func leases(_ args: [String], _ env: CLIEnvironment) throws -> Int32 {
        let p = try parse(args, values: [], flags: ["--json"])
        guard p.positional.isEmpty else { throw Usage.message("unexpected argument: \(p.positional[0])") }
        let statuses = LeaseService(env: env).statuses()
        if p.flags.contains("--json") {
            env.out(String(decoding: try LeaseJSON.encoder().encode(statuses), as: UTF8.self))
            return 0
        }
        if !statuses.isEmpty {
            for note in LeaseService(env: env).cautions(plural: true) { env.err("awake: warning: \(note)") }
        }
        if statuses.isEmpty {
            env.out("no leases")
            return 0
        }
        for line in table(statuses) { env.out(line) }
        return 0
    }

    static func table(_ statuses: [LeaseStatus]) -> [String] {
        let header = ["ID", "OWNER", "LEFT", "UNTIL", "SOURCE", "REASON"]
        let rows = statuses.map { [$0.id, $0.owner, LeaseDuration.format(TimeInterval($0.remainingSeconds)), $0.until ?? "-", $0.source, $0.reason] }
        var widths = header.map(\.count)
        for row in rows {
            for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) }
        }
        func line(_ cells: [String]) -> String {
            var out = ""
            for (i, cell) in cells.enumerated() {
                // The last column is not padded: no trailing spaces.
                out += i == cells.count - 1 ? cell : cell.padding(toLength: widths[i] + 2, withPad: " ", startingAt: 0)
            }
            return out
        }
        return [line(header)] + rows.map(line)
    }

    private static func status(_ args: [String], _ env: CLIEnvironment) throws -> Int32 {
        let p = try parse(args, values: [], flags: ["--json"])
        guard p.positional.isEmpty else { throw Usage.message("unexpected argument: \(p.positional[0])") }
        let service = LeaseService(env: env)
        let running = env.appRunning()
        guard let data = service.statusData(), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            env.err("awake: no status yet: \(env.home.statusFile.path) is written by Awake.app\(running ? " at its next change" : ", which is not running")")
            return 1
        }
        if p.flags.contains("--json") {
            env.out(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
            return 0
        }
        for line in statusLines(object, leases: service.statuses(), appRunning: running, now: env.now()) { env.out(line) }
        return 0
    }

    /// The status for a person. The time left is worked out from the end
    /// time now, not read from the file, which is as old as its last write.
    static func statusLines(_ status: [String: Any], leases: [LeaseStatus], appRunning: Bool, now: Date) -> [String] {
        var lines: [String] = []
        let iso = ISO8601DateFormatter()
        func date(_ key: String) -> Date? { (status[key] as? String).flatMap { iso.date(from: $0) } }
        if !appRunning {
            lines.append("Awake.app is not running; this is the last status it wrote.")
        }
        if status["active"] as? Bool == true, let end = date("endsAt") {
            let left = end.timeIntervalSince(now)
            lines.append(left > 0 ? "Session: active, \(LeaseDuration.format(left)) left" : "Session: its time is up")
        } else {
            lines.append("Session: none")
        }
        if status["hasBattery"] as? Bool == false {
            lines.append("Power: mains (no battery)")
        } else if let percent = status["batteryPercent"] as? Int {
            let charging = status["isCharging"] as? Bool == true
            let weak = status["chargerDraining"] as? Bool == true
            lines.append("Battery: \(percent)%\(charging ? (weak ? ", charger too weak" : ", charging") : "")")
        }
        if status["lidKnown"] as? Bool == false {
            // The Mac cannot read its lid (a desktop, a virtual machine).
            lines.append("Lid: unknown")
        } else if let closed = status["lidClosed"] as? Bool {
            let desk = status["lidOnDesk"] as? Bool == true
            lines.append("Lid: \(closed ? (desk ? "closed, external display" : "closed") : "open")")
        }
        if let thermal = status["thermalState"] as? String { lines.append("Thermal: \(thermal)") }
        if leases.isEmpty {
            lines.append("Leases: none")
        } else {
            lines.append("Leases: \(leases.count)")
            for lease in leases { lines.append("  \(lease.line)") }
        }
        if let updated = date("updatedAt") {
            lines.append("Updated: \(LeaseDuration.format(max(0, now.timeIntervalSince(updated)))) ago")
        }
        return lines
    }
}
