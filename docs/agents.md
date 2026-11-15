# Agents

During a session Awake finds the AI coding agents running on the Mac,
follows what each one is doing, and tells you (and your phone, when phone
alerts are set up) when one needs a person. Nothing here types into an
agent or answers a prompt for it.

## What counts as an agent

Checked every 20 seconds while a session runs:

| Agent | How it is found |
|---|---|
| Claude Code | a process named `claude`, or `node` running the `claude` script |
| Codex | a process named `codex` |
| Cursor | the Cursor app (bundle id), or `cursor-agent` |
| Aider | `aider`, or `python -m aider` |
| Devin CLI | a process named `devin` |
| Gemini CLI | `gemini`, or `node` running the gemini-cli package |
| Ollama | `ollama` (the server and its runners are one agent), or the Ollama app |
| LM Studio | the LM Studio app, or `lms` |
| Anything else | a tmux pane you mark, or a hook you write (both below) |

A process has to be seen on two checks in a row before it is tracked, so
`claude --version` is never announced. An agent is one process and its
children; a pid is never trusted alone: the record is keyed by the pid and
the process's start time, so a reused pid is a new agent.

For each agent Awake keeps: kind, name, pids, tmux pane (if it runs in
one), working directory, the git repo that directory is in, CPU %, memory,
first seen and last seen.

### Marking a tmux pane

To track something Awake does not recognise (a long build, a script, an
agent not in the table), mark its pane. In that pane run:

    tmux set-option -p @awake 1

or give the pane a title that starts with `awake:` (the rest is the name
shown):

    tmux select-pane -T "awake: nightly build"

`tmux set-option -pu @awake` removes the mark. Awake only reads marked
panes (`list-panes`, `capture-pane`); it never sends keys to them. The
separate "continue" nudge after a network outage has its own mark,
`@awake-nudge`, and stays off unless you set it.

## States

| State | Meaning |
|---|---|
| alive | just found, not enough readings yet |
| busy | using CPU (3% of a core or more), printing, or sending hook heartbeats |
| idle | running and quiet, or a hook said it finished its turn |
| waiting | asking a person something |
| stalled | in the middle of something and silent for the stall time (default 10 minutes) |
| exited | the process is gone |

How each is decided:

- **Waiting** comes from a hook (below), or from the last ten lines of the
  agent's tmux pane when they have not changed since the previous check and
  hold a question: `(y/n)`, `[Y/n]`, `Allow?`, `Do you want to`, `Press
  Enter`, a numbered menu with the cursor on a choice (Claude Code's "Do you
  want to proceed?"), Codex's approval prompt, an SSH passphrase or a `sudo`
  password prompt. A question above the agent's own input line has already
  been answered and is ignored.
- **Stalled** needs something whose silence can be measured: a tmux pane,
  or hook heartbeats. An agent sitting at its own input line, or one whose
  hook said it finished, is idle however long it sits there. Without a pane
  or hooks Awake can only see CPU, so such an agent is busy or idle,
  never stalled or waiting. Ollama, LM Studio and the Cursor app never
  wait or stall: they are busy or idle.
- **Last output age** is the time since the pane text changed, a hook
  heartbeat arrived, or (Claude Code) its transcript file was written.

## Alerts

Each is sent once per change, through the same notifier as every other
Awake alert, so it also goes to ntfy or Pushover when those are set up.
Each has a toggle under Settings > Agents.

- **Agent waiting: claude** with the question, and the repo.
- **Agent stalled: claude** with the minutes and the repo.
- **Agent exited: claude** with the repo. The exit status of a process
  Awake did not start cannot be read, so the alert says the process is
  gone; when a hook reported the end of the session its reason is shown.
- **All agents finished** when every command-line agent has been idle or
  gone for the all-done time (default 5 minutes). Sent once, and again only
  after one of them has worked in between.

## Hooks

Hooks are the exact signal: the agent itself says "I need permission" or
"I finished". They work without tmux.

Awake listens on a Unix socket, owner-only, while a session runs:

    ~/Library/Application Support/Awake/hooks.sock

and installs a small script next to it that posts to that socket with
`curl --unix-socket`:

    ~/Library/Application Support/Awake/awake-hook.sh <kind> [event] [json]

The script is written when a session starts and from Settings > Agents >
"Install hook script" (the same file is in this repo as
`scripts/awake-hook.sh`). With no session running, or Awake not running,
it exits 0 at once and prints nothing, so a hook never slows or fails the
agent.

If you set a status port (Settings > Phone alerts), the same events are
also accepted on `http://127.0.0.1:<port>/hooks/<kind>`. A post there must
carry the header `X-Awake-Hook: 1`; a request without it, or with an
`Origin` header, is refused, so a web page open in a browser cannot forge
agent events.

### Claude Code

Add to `~/.claude/settings.json` (merge with any `hooks` you already have):

```json
{
  "hooks": {
    "Notification": [
      { "hooks": [{ "type": "command", "command": "\"$HOME/Library/Application Support/Awake/awake-hook.sh\" claude" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "\"$HOME/Library/Application Support/Awake/awake-hook.sh\" claude" }] }
    ],
    "SubagentStop": [
      { "hooks": [{ "type": "command", "command": "\"$HOME/Library/Application Support/Awake/awake-hook.sh\" claude heartbeat" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "\"$HOME/Library/Application Support/Awake/awake-hook.sh\" claude" }] }
    ]
  }
}
```

Optional heartbeat, so a Claude Code outside tmux can be seen to stall
(one `curl` to a local socket per tool call):

```json
    "PreToolUse": [
      { "matcher": "*", "hooks": [{ "type": "command", "command": "\"$HOME/Library/Application Support/Awake/awake-hook.sh\" claude" }] }
    ]
```

What each event does:

| Claude Code event | Awake |
|---|---|
| `Notification` (permission needed) | waiting, with Claude's message as the prompt |
| `Notification` ("Claude is waiting for your input", sent after a minute at rest) | idle |
| `Stop` | idle (the turn is over) |
| `SubagentStop` | busy as sent above (a subagent finishing means the main agent goes on); idle if you leave out `heartbeat` |
| `PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `SessionStart` | busy (heartbeat) |
| `SessionEnd` | exited once the process is gone; shown with its reason |

### Codex

Add to `~/.codex/config.toml`:

```toml
notify = ["/bin/sh", "-c", "\"$HOME/Library/Application Support/Awake/awake-hook.sh\" codex '' \"$1\"", "awake-hook"]
```

Codex runs the program with its JSON payload as the last argument; the
`sh -c` wrapper is only there so `$HOME` can be used. `agent-turn-complete`
makes the agent idle. Codex has no hook for its approval prompt, so
"waiting" for Codex comes from its tmux pane.

### Anything else

Any program can report itself. `<kind>` is a name of lower-case letters,
digits, `-` and `_`; the event is one of `waiting`, `finished`,
`heartbeat`, `ended`:

    "$HOME/Library/Application Support/Awake/awake-hook.sh" mybot heartbeat
    echo '{"message":"Deploy to prod?","cwd":"'"$PWD"'"}' | "$HOME/Library/Application Support/Awake/awake-hook.sh" mybot waiting

### How a hook finds its agent

In this order: the pid that ran the hook (walking up its parents until it
reaches a tracked agent), the agent's own session id (`session_id`,
`thread-id`) once one event has tied it to an agent, then the working
directory together with the kind. An event that matches nothing creates a
"hook-only" agent, named after the kind, which has states and alerts like
any other but no pid, CPU or memory.
