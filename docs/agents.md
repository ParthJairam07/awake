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

## Dialogs

A dialog nobody answers stops an agent as surely as a question in its
terminal. With **Alert on dialogs and permission prompts** on (the
default) and Awake allowed under System Settings > Privacy & Security >
Accessibility (Settings > Agents has the button and shows the status),
Awake looks every 5 seconds during a session for:

- sheets, dialogs and alerts in the frontmost app and in the running apps
  on the "Agent apps" list (terminals, editors, browsers);
- any window of the processes macOS uses for its own prompts: permission
  requests (`UserNotificationCenter`), Gatekeeper and "downloaded from the
  internet" (`CoreServicesUIAgent`), the keychain and administrator
  password (`SecurityAgent`).

Each is reported once as **Dialog blocking: <app> — <title>** with its
text and button titles. The same dialog is reported again only after it
has been gone for two checks. Nothing is reported while someone is at the
Mac (keyboard or mouse used in the last minute): the dialog is theirs.
Awake never clicks a button. Without the permission nothing is read and
nothing is asked for until you press the button. `sudo` asking for a
password in a terminal is text, not a window: it is caught as a waiting
prompt in a tmux pane.

## In the menu, status.json and the summary

The menu bar menu shows one line per agent (Settings > Agents > Show
agents in the menu): a mark for the state, the name, the state, how long
it has been in it, and the repo or tmux pane, such as
`● claude  busy  3m  repo-name`. ● busy, ○ idle, ◆ waiting, ■ stalled,
× exited.

`status.json` (and the loopback endpoint) carries `agents`, one object
per agent: `id`, `kind`, `name`, `state`, `lastOutputAgeSeconds`, `repo`,
`tmuxTarget`, `waitingPrompt`, and also `stateSince`, `cpuPercent`,
`residentBytes`, `pids`, `cwd`.

The session summary ends with what the agents did, for example: "Agents:
3 ran, 2 finished, 1 stalled, 1 waiting for input at the end. Unpushed
commits: api (3). wip pushed: 2 repos, failed: 1." Unpushed commits are
counted per agent repo every five minutes with `git log @{u}..`; a repo
whose branch has no upstream is skipped.

## Before the session ends (opt-in)

Both off by default, under Settings > Agents.

**Before a battery, heat or planned end, post "Session ending"**: when the
battery or heat floor is about to end the session, or the timer runs out,
Awake first writes what it is about to do to
`~/Library/Application Support/Awake/pre-end.json` and posts "Session
ending" (to the phone too). Ending the session yourself, or quitting,
does not run it.

**Also commit and push work in progress in each agent repo**: after that
notice, in each repo an agent works in, on whatever branch is checked out:

    git add -A
    git commit --no-verify -m "wip: awake auto-save before session end"
    git push

- 60 seconds per repo for all three; a repo with nothing to commit is left
  alone. The session ends after the last repo, so a planned end can be up
  to a minute per repo late.
- Never `--force`, never `sudo`, and git cannot stop to ask for a password
  (`GIT_TERMINAL_PROMPT=0`): a push that needs one fails and is reported.
- The commit skips the repo's commit hooks (`--no-verify`) so a linter
  cannot veto the save. Push hooks still run.
- A branch without an upstream is committed but the push fails and is
  reported as failed; Awake does not create remote branches.
- `pre-end.json` records each repo before it is touched and its result
  after. If the Mac dies in the middle, the next session start posts
  "Pre-end save interrupted" naming the repos to check.
- The summary says "wip pushed: 2 repos, failed: 1".

This commits everything in the work tree, including files an agent has
half written. Turn it on only for repos where a wip commit on the current
branch is acceptable.

## Priority pause (opt-in)

Off by default. With **Pause low-priority agents under battery, heat or
memory pressure** on, each agent kind gets a priority: Low, Normal (the
default) or High. `agentPriorities` in config.json also accepts the name
of a marked tmux pane.

Pressure is any of: the battery under the Low Power Mode floor while on
battery (or on a charger too weak for the load), the Mac hot (thermal
state serious or critical, CPU limited, battery temperature at its
floor), or critical memory pressure.

Under pressure Awake pauses (SIGSTOP) the agents with the lowest priority
first, then the next priority a minute later if the pressure is still
there, and never the highest priority that is running. So with every
agent at Normal nothing is paused; mark the ones that can wait as Low.
When the pressure clears they are resumed (SIGCONT) in the order they
were paused, and "Agents paused" / "Agents resumed" say which.

An agent started from a shell prompt becomes a background job of that shell when it is paused: the shell takes the terminal back, and after the resume an agent that reads the terminal stays stopped until you type `fg` in that terminal.
Settings says so under the toggle, and the note under
[From the phone](#from-the-phone) has the detail.

The stops use the same machinery as freezing apps on lid close: each one
is journaled before the signal, tied to the process's start time, and
undone by the session end, the recovery agent or the next launch if Awake
is not there to do it. Opening the lid resumes everything Awake has
stopped, paused agents included; they are paused again if the pressure
is still there.

Never paused: an agent at a `sudo` password prompt, an agent with `sudo`
running anywhere under it, and agents known only from hooks (no process).

## From the phone

With the [phone app](phone.md) on, the Agents tab can act on an agent
while a session runs. Nudge (Enter) and Answer (one line of at most 500
characters, typed literally, then Enter) go to the agent's tmux pane and
only if that pane is marked, alive and not in copy mode; anything else is
refused with "agent is not in a marked tmux pane". They are also refused
while the pane's own shell is in front of the agent (see the note on Pause
below), because the shell would run what is typed. Pause and Resume use
the priority pause's stops: journaled before the signal, tied to each
process's start time, never an agent with `sudo` under it, and undone by
the session's end, a lid open, the recovery agent or the next launch. An
agent paused from the phone stays paused when pressure clears; one the
priority pause stopped can be resumed from the phone and is paused again
if the pressure is still there. Stop sends SIGTERM to the agent's root
process only, after checking that the pid is still the process Awake
tracked (a paused agent is resumed first, so it can act on the signal);
it is refused for an agent known only from hooks. For a marked pane, whose
first process is usually an interactive shell that ignores SIGTERM, the
signal goes to the job running in the pane instead: the process leading
the group in front of the pane, or the shell's only job when the shell
itself is in front. The phone API records
every action in the audit log, with the length of an answer, never its
text.

An agent started from a shell prompt becomes a background job of that shell when it is paused: the shell takes the terminal back, and after the resume an agent that reads the terminal stays stopped until you type `fg` in that terminal.

A pause is a SIGSTOP, and an interactive shell notices when a program it
started is stopped: it prints "suspended", takes the terminal back, and
after the resume the program is a background job of that shell (an agent
that reads the terminal then stops again until someone types `fg` in the
pane). tmux also continues a pane's first process when it is stopped. So
pausing an agent that was started from a shell prompt, in tmux or not,
leaves it for a person to bring back with `fg`. Until then Nudge and Answer
are refused for it.

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
