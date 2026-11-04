# Awake: plan

This is the plan before any code. It records what we are building, in what order, and the decisions already made. Change it by pull request.

The plan builds on three write-ups kept outside this repo for now: a full read of the Insomnia codebase, a critique with feature ideas, and a list of everything a MacBook can report. The useful parts of each are folded in below.

## 1. Goal

One engineer, one MacBook, many coding agents, lid closed, owner away with only a phone. Awake must:

1. Keep the Mac awake for a fixed time and undo every change it made, even after a crash.
2. Know what each agent is doing and tell the phone when one needs a person.
3. Catch the ways an unattended laptop fails: weak charger, heat, no real internet, full memory or disk, forced restart, unlocked screen.
4. Let the owner act from the phone: answer a prompt, extend, end, lock, pause an agent, commit and push.

## 2. What we keep from Insomnia

Insomnia (krishhgg/Insomnia, MIT) already solves the "keep awake and restore" problem well. We keep its model and, where the licence allows, its approach:

- **Journal first.** `state.json` records a change before it is made; undo reads the journal from disk.
- **One transaction at a time** across the app and a recovery script, with a shared `flock` lock.
- **Recovery agent** (a launchd job every minute) that undoes the journal if the app is gone, pinned to the signed build.
- **Root limited to four `pmset` commands** through a sudoers rule; never SIGKILL `sudo`.
- **Process identity** (start time to the microsecond + boot session) before any SIGSTOP/SIGCONT.
- **Lid actions**: darken, mute, freeze chat apps, optional Docker pause, Low Power Mode, all reversible.
- **Hotspot handoff** and the opt-in tmux nudge.

Decision to make in phase 0: fork Insomnia and build on it, or start a new Swift app that re-implements the journal model. Leaning: **fork**, because the recovery code is the hard, well-tested part (1,284 tests), and the phone and agent layers are additive.

## 3. What we add

### 3.1 Phase 0: fix the gaps that bite today (weeks 1–2)

| Item | Why | Source of truth |
|---|---|---|
| Battery floors use the **trend** (percent per minute, watts) as well as the charger flag | A weak charger counts as "charging" today, so a plugged-in Mac can drain to 0% | `AppleSmartBattery`: `InstantAmperage`, `Voltage`, `AdapterDetails.Watts` |
| **Lock the screen on lid close** (default on) | An unattended Mac with sleep disabled may stay unlocked | session lock API |
| **External monitor = not a "closed lid"** | Lid actions run today even in clamshell desk mode | `CGGetActiveDisplayList`, `CGDisplayIsBuiltin` |
| **Real internet check** before calling it an outage | Captive portals and dead DNS look "connected" | HTTPS HEAD to the agent APIs; `captive.apple.com` probe |
| **Battery temperature and thermal throttle %** in the floor rules | Bag detection before macOS says "critical" | `AppleSmartBattery.Temperature`, `pmset -g therm` |
| **Memory pressure and free disk** alerts | Many agents plus Docker fill both overnight | memory-pressure dispatch source, volume capacity |

### 3.2 Phase 1: the phone gets the alerts (weeks 3–4)

- Every alert also goes to the phone: ntfy and Pushover first (no app to build), Telegram and a webhook next.
- Alert set: agent waiting for input, agent stalled, agent exited, battery or heat floor, internet down and back, session ending in 10 min, session ended, restore incomplete, pending OS restart.
- **Morning summary**: duration, battery used, outages, thermal events, agents that ran, finished, stalled, repos with unpushed commits, anything not restored.
- Local `status.json` and a tiny HTTP endpoint for dashboards (Raycast, SketchyBar).

### 3.3 Phase 2: the Mac knows the agents (weeks 5–8)

- **Agent registry**: find agent processes by bundle id or command line (Claude Code, Codex, Cursor, Aider, Devin CLI, Ollama, LM Studio), and tmux panes by user mark.
- **Per-agent state**: alive, CPU, memory, last output age (tmux pane hash, log file mtime), waiting-for-input (prompt patterns + hook events), stalled (no change for N min), exited.
- **Prompt and dialog detector**: Accessibility API for sheets and dialogs (Gatekeeper, TCC, keychain, sudo), text and buttons captured and sent to the phone.
- **Hooks**: shipped configs for Claude Code (`Notification`, `Stop`) and Codex notify, posting to Awake's local endpoint.
- **Pre-end hooks**: before a battery or heat end, send a save signal to agents and, opt-in, `git commit -am wip && git push` per repo.
- **Priority**: pause low-priority agents first under battery, heat or memory pressure, with the same journaled, identity-checked SIGSTOP.

### 3.4 Phase 3: the phone controls the Mac (weeks 9–12)

- A phone web app (PWA) served from the Mac over **Tailscale**; no port forwarding, device-authenticated, pairing code on first use.
- Screens: session (time left, extend, end), agents (cards, nudge, answer prompt, pause, stop), machine (battery, trend, charger watts, temperature, throttle, memory, disk, network type, data used), security (lock, screenshot, who is connected), log.
- Actions are allow-listed, signed, rate-limited and written to an audit log. "Panic" ends the session and locks the screen.
- Native iOS app later, only if the PWA is not enough (push reliability is the deciding factor).

### 3.5 Phase 4: agents ask for awake time (weeks 13+)

- **Leases.** `awake lease --for 2h --reason "refactor billing"` from a CLI, and the same as an **MCP tool** so agents call it themselves. The Mac stays awake while any lease is held, capped by the owner's maximum, and ends when the last lease is released or expires. Each lease has an owner, a reason and an expiry, shown on the phone.
- "Awake until these finish": a pid, pane or command plus an idle grace period, with a hard cap.
- Schedules and profiles: end at a clock time, recurring nights, Overnight / Commute / Clamshell desk / Demo.

## 4. Decisions already made

- **Platform:** macOS 26 or later, Apple Silicon, Swift 6, SwiftUI in an `NSStatusItem`. No Dock icon.
- **Phone first as a PWA**, not a native app.
- **Transport:** push out via ntfy/Pushover; pull and control over Tailscale. No cloud relay of our own in v1.
- **Safety rules carried over unchanged:** journal before change; clear an entry only after a confirmed undo; never SIGKILL `sudo`; never signal a pid we can't prove is ours; a session never starts unless the recovery agent is armed.
- **Honesty rule:** every reading is labelled measured, derived or unknown. "Unknown" never counts as "fine".
- **Licence:** MIT.

## 5. Open questions

1. Fork Insomnia or start fresh (see §2)? Decide after a week of reading its `SessionManager` and recovery script.
2. Which agents to support first? Proposal: Claude Code and Codex in tmux, then Cursor and the GUI agents.
3. How much automation on prompts? Proposal: report by default; remote one-tap answer opt-in per agent; never auto-answer.
4. Where do secrets live (hotspot password, ntfy token, Tailscale auth)? Proposal: login Keychain, as Insomnia does.
5. Notarized builds and a Homebrew cask, or ad-hoc signed like Insomnia? Affects install friction a lot.

## 6. What we will not do

- Remote unlock of the Mac.
- Reading iMessage or Notification Center databases in v1 (powerful, but a privacy decision to make on its own).
- Auto-answering agent prompts without a person.
- Pretending recovery is guaranteed. The README says it can fail, and the app shows a warning instead of hiding it.

## 7. How we will know it works

Each phase ships with a real-Mac checklist run on a ventilated desk with disposable work, and the result recorded with the exact build, macOS version and hardware. Unit tests use fakes and temp folders only; nothing in the test suite changes the developer's power settings, processes or Wi-Fi.
