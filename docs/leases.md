# Leases: agents ask for awake time

A **lease** is a request to keep the Mac awake: who is asking, why, and
until when. While any lease is held, Awake runs a session. When the last one
is released or expires, a session that only leases were holding ends a few
minutes later.

A lease is one file, `~/Library/Application Support/Awake/leases/<id>.json`.
The `awake` command and the MCP server write and delete those files; the app
watches the folder (and re-reads it every 30 s). Nothing talks to the app
over a socket, so a lease can be asked for while Awake.app is not running
and is picked up when it starts.

## Install the command

The command is inside the app, at `Awake.app/Contents/Helpers/awake`. Put it
on your PATH with Settings > Leases > **Install `awake` command**, or:

```bash
./scripts/link-cli.sh        # links into /usr/local/bin, or ~/.local/bin if that needs a password
```

## From a shell

```bash
id=$(awake lease --for 2h --reason "refactor billing")   # prints the lease id
awake leases                  # table of leases; --json for scripts
awake extend "$id" --by 1h
awake release "$id"           # or: awake release --all, awake release --owner claude
awake status                  # session, battery, lid, leases; --json prints status.json
```

Tie a lease to the work instead of to a guess:

```bash
awake lease --until-exit -- make test          # held while make runs, released when it exits; exits with make's status
awake lease --for 6h --until-pid 4242 --grace 10m
awake lease --for 6h --until-tmux work:1.0     # released when that pane is back at a shell prompt, or gone
```

- `--for` is the most the lease can last: `90m`, `2h`, `1h30m`. It is
  needed unless an `--until` is given; then it defaults to the lease cap.
- `--grace` is how long the lease outlives the thing it waits for.
- `--owner` defaults to your user name, or `$AWAKE_LEASE_OWNER`.
- An id can be shortened to its first characters (at least four).

If Awake.app is not running the command still writes the lease and prints
`Awake.app is not running; lease will take effect when it starts`.

## From an agent (MCP)

`awake mcp` is a Model Context Protocol server on stdin/stdout (protocol
2025-06-18) with five tools: `awake_lease(duration, reason, owner?, grace?)`,
`awake_release(id)`, `awake_leases()`, `awake_status()` and
`awake_extend(id, by)`.

**Claude Code**

```bash
claude mcp add awake -- awake mcp
```

**Codex** (`~/.codex/config.toml`)

```toml
[mcp_servers.awake]
command = "awake"
args = ["mcp"]
```

**Cursor** (`~/.cursor/mcp.json`, or `.cursor/mcp.json` in a project)

```json
{
  "mcpServers": {
    "awake": { "command": "awake", "args": ["mcp"] }
  }
}
```

If the agent's environment has no `awake` on its PATH, use the full path:
`~/Applications/Awake.app/Contents/Helpers/awake`.

A lease made through MCP lasts until it is released or expires, also if the
agent's session ends first, so ask agents to release when they finish.

## The rules

- **Start.** With no session running, the first lease starts one, with your
  default duration as its first end time. Turn this off in Settings and
  leases only stretch a session you started.
- **End time.** The session ends at the later of the end it already had and
  the last lease's expiry plus the grace (5 minutes by default).
- **Cap.** Leases hold the Mac for at most the cap (8 hours by default):
  counted from when a lease was made, and from the first lease of a session
  for all of them together. Your maximum session length applies on top.
- **Your session is yours.** A session you started is never cut short by
  leases. When they go, it returns to the end you chose. If you add time to
  a session leases started, it becomes yours.
- **Release.** When the last lease is released or expires, a session that
  only leases were holding ends after the grace, and says so: "Last lease
  released", then "Session ended".
- **Floors win.** The battery and heat rules end the session whatever leases
  say. A session that ends for any reason other than the leases themselves
  or quitting Awake **revokes its leases** (the files are deleted), so they
  cannot start the next session straight away. A new lease starts a new one.
- **`--until`.** Checked every 30 s. A process is identified by its pid,
  its start time to the microsecond and the boot it started in, so a later
  process that is given the same pid never holds a lease. A tmux pane is
  identified by its pane id, its server's socket and its first process;
  it counts as busy while something other than a shell is in front.
  Something Awake cannot check (tmux missing, an unreadable process) is
  unknown, not finished: the lease then lasts until its expiry.
- **Tidying.** Expired leases are deleted. A `.json` file in the folder that
  is not a lease is deleted once it is 10 seconds old.

Leases show in the right-click menu ("Leases: 2 — claude 'refactor billing'
1h 12m left"), in `status.json` (`leases`) and in the session summary.

## Settings

Settings > Leases:

| Setting | Default | `config.json` key |
|---|---|---|
| Honour leases | on | `leasesEnabled` |
| A lease may start a session | on | `leasesMayStartSession` |
| Leases hold the Mac for at most | 8 h | `leaseCapHours` |
| End after the last lease | 5 min later | `leaseGraceMinutes` |
| Notify when a lease is granted and when the last one is released | on | `leaseNotifications` |

## The file

```json
{
  "createdAt" : "2027-01-15T08:00:00Z",
  "expiresAt" : "2027-01-15T10:00:00Z",
  "graceSeconds" : 0,
  "id" : "21e3921e-5a5d-4f18-a13f-73b21855c47d",
  "owner" : "claude",
  "reason" : "refactor billing",
  "source" : "cli",
  "version" : 1
}
```

`source` is `cli`, `mcp` or `hook`. The file's name is its `id` plus
`.json`. Write it to a temporary name and rename it into place, as the
command does; the folder and the files are owner-only. An optional `until`
object has a `kind` (`pid`, `tmux` or `command`) and the identity fields the
command records; make those with the command, not by hand.
