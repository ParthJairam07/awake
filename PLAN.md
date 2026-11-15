# Awake: plan

This is the plan. It records what we are building, in what order, and the decisions already made. Change it by pull request.

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

**Decided: fork.** Awake is a fork of Insomnia at commit `b8e7e20`, renamed throughout (bundle id `com.parthjairam.awake`, `~/Library/Application Support/Awake`, `com.awake.backstop`, `/etc/sudoers.d/awake`), so it installs beside an existing Insomnia without touching it. The recovery code is the hard, well-tested part, and the phone and agent layers are additive. Insomnia's MIT notice is kept in `THIRD_PARTY_NOTICES`.

## 3. What we add

### 3.1 Phase 0: fix the gaps that bite today (weeks 1–2)

**Done** (all six, each with a setting, defaults on, and unit tests over fakes):

| Item | Why | How it is done |
|---|---|---|
| Battery floors use the **trend** as well as the charger flag | A weak charger counts as "charging", so a plugged-in Mac can drain to 0% | `ChargerTrend`: on AC, two points below the high seen on this charger, or two discharging `InstantAmperage × Voltage` reads in a row, means "draining"; the floors then treat the Mac as on battery; one "Charger too weak" notice per spell |
| **Lock the screen on lid close** (default on) | An unattended Mac with sleep disabled stays unlocked | `ScreenLock`: `SACLockScreenImmediate` (login.framework), first lid action, not journaled; failure logged and announced once per session |
| **External monitor = not a "closed lid"** | Lid actions ran even in clamshell desk mode | `LidPolicy` + `DisplayObserver`: a non-built-in display online makes the close "desk": no actions, no lid Low Power Mode; unplugging it with the lid closed runs them, plugging one in undoes them |
| **Real internet check** before calling it an outage | Captive portals and dead DNS look "connected" | `CaptivePortalProbe`: `captive.apple.com/hotspot-detect.html` every 60 s while Wi-Fi is up; two failures open an outage like a lost path; a path recovery behind a portal is not a recovery |
| **Battery temperature and thermal throttle %** in the floor rules | Bag detection before macOS says "critical" | `ThermalProbe`: `pmset -g therm` CPU speed limit ≤ 50% or battery ≥ 45 °C → Low Power Mode; ≥ 55 °C ends the session. Many Apple Silicon Macs (the author's Air among them) report no battery temperature; then only the speed limit and thermal state apply |
| **Memory pressure and free disk** alerts | Many agents plus Docker fill both overnight | `ResourceMonitor`: critical memory pressure (dispatch source) and free space on the home volume under 10 GB, one notice per crossing |

Still to do for phase 0: the real-Mac checklist of section 7 (lid close with and without a monitor, a weak charger, a captive portal) recorded in `docs/release-validation.md`.

### 3.2 Phase 1: the phone gets the alerts (weeks 3–4)

**Done:**

- Every alert also goes to the phone: `PhoneAlerts` wraps the Mac notifier and forwards each post to the ntfy topic and/or Pushover account from Settings (tokens in the login keychain, service `awake-phone`), with one retry and one local "Phone alert failed" notice per launch. Telegram and a webhook are still to come.
- Alert set today: battery, heat and weak-charger floors, Low Power Mode on/off, "Internet down" once an outage lasts the nudge threshold and "Internet back" / "Network recovered", "10 minutes left" (was 5, Mac-only), session ended, restore incomplete, screen not locked, memory pressure, disk almost full. Agent waiting/stalled/exited arrived with phase 2; "pending OS restart" is deferred (no reliable public API).
- **Session summary**: `report.json` tallies the session as it runs (lid closes, Low Power Mode and heat events, weak-charger spells, outages) and one "Session summary" notification at the end gives duration, reason, battery start→end and whether everything was restored; a report left by a session Awake did not see end is summarised at the next launch. Agents and unpushed repos joined it in phase 2.
- `status.json` in Application Support on every change, served on `http://127.0.0.1:<port>/status.json` when a port is set (loopback only, off by default).

### 3.3 Phase 2: the Mac knows the agents (weeks 5–8)

**Done** (each with settings under Settings > Agents and unit tests over fakes; details in `docs/agents.md`):

- **Agent registry** (`Sources/Awake/Agents`): Claude Code, Codex, Cursor, Aider, Devin CLI, Gemini CLI, Ollama and LM Studio by command line or bundle id over the existing process snapshot, plus tmux panes marked with `@awake` or an `awake:` title. Polled every 20 s and when the menu opens. Each agent is keyed by pid and start identity and carries its pids, tmux target, cwd, git repo, CPU %, RSS, first and last seen.
- **Per-agent state** (`AgentStateMachine`, pure): alive, busy, idle, waitingForInput, stalled, exited, from CPU over time, the tmux pane's text (hash and prompt patterns on the last lines), Claude Code's transcript mtime and hook events. Stalled after `agentStallMinutes` (10) without output or a heartbeat, only where output can be seen.
- **Hooks**: `POST /hooks/<kind>` on the loopback status port and on an owner-only Unix socket, `hooks.sock`, that works with the port off; `scripts/awake-hook.sh` (also installed into Application Support) posts to it. Configs for Claude Code (`Notification`, `Stop`, `SubagentStop`, `SessionEnd`, optional `PreToolUse`) and Codex `notify` are in `docs/agents.md`. Unmatched events create a hook-only agent.
- **Alerts** through the same notifier as phase 1 (so also to the phone): Agent waiting, Agent stalled, Agent exited, once per transition, and All agents finished after `allDoneMinutes` (5).
- **Dialog detector**: with the Accessibility permission, every 5 s during a session and only when nobody has touched the Mac for a minute, reads sheets, dialogs and system prompts (TCC, keychain, Gatekeeper) in the frontmost and agent apps and posts "Dialog blocking" once per dialog with its text and buttons. Never clicks. `sudo` in a terminal is caught as a tmux prompt.
- **Menu and status**: one line per agent in the menu; `status.json` gains `agents`.
- **Session summary**: agents that ran, finished, stalled or were waiting at the end, repos with unpushed commits, and the result of the wip save.
- **Pre-end hooks** (opt-in): before a battery, heat or planned end, the intent is journaled to `pre-end.json`, "Session ending" is posted and, with `wipCommitOnEnd`, each agent repo gets `git add -A`, a commit and a push, 60 s per repo, never forced.
- **Priority pause** (opt-in): under the Low Power Mode floor, heat or critical memory pressure, the lowest-priority agents are paused first, one priority a minute and never the highest present, with the same journaled, identity-checked SIGSTOP as a lid-close freeze, and resumed in the same order when it clears. Never an agent at a sudo prompt or with sudo running under it.

Still to do for phase 2: the real-Mac check (real Claude Code and Codex sessions with the hooks installed, a real permission dialog with Accessibility allowed, a real wip push), recorded in `docs/release-validation.md`.

### 3.4 Phase 3: the phone controls the Mac (weeks 9–12)

**Done** (setup and security model in [docs/phone.md](docs/phone.md)):

- **Server**: `PhoneServer` (`Sources/Awake/Phone/`), HTTP/1.1 on `NWListener`, bound only to the Mac's Tailscale addresses (a `utun` interface with a `100.64.0.0/10` address, plus the tailnet IPv6 address) and `127.0.0.1`, on `phonePort` (7788), when `phoneApp` is on (off by default). Never all interfaces. Without Tailscale it serves loopback only and Settings and the menu say "Tailscale not found". Plain HTTP on the tailnet; `tailscale serve --bg 7788` gives https, and Settings shows that address and its QR code when it finds it.
- **Pairing and auth**: a six-digit code (5 minutes, 5 tries, then a new one) shown with a QR code in Settings and in the menu; a 32-byte bearer token per phone, stored on the Mac only as a salted SHA-256 in the login keychain; Forget per phone and Forget all. 30 requests / 10 s per phone, 5 failed sign-ins a minute per address then a 5-minute block. Every action goes to an owner-only `audit.log`, rotated at 5 MB.
- **API**, allow-listed, everything else 404: status and a server-sent event stream of it, session start / extend / end, lock, panic (lock, then end the session, which resumes what Awake froze), screenshot (ScreenCaptureKit, in memory, 403 without Screen Recording), log tail, machine readings, agent actions through `AgentActing`.
- **PWA**, no framework and no build step, embedded in the app: Session, Agents, Machine, Security, Log. Agents and leases are rendered when the status carries them; until phase 2 is wired in, `AgentActing` is a stand-in that answers "not available yet".
- **Not done**: web push from the PWA (ntfy and Pushover stay the push path), data used, "commit and push a repo", and the screen-sharing tiers of section 8 past the still screenshot.
- Native iOS app later, only if the PWA is not enough (push reliability is the deciding factor).

### 3.5 Phase 4: agents ask for awake time (weeks 13+)

**Done** (leases and "awake until these finish"; [docs/leases.md](docs/leases.md)):

- **Leases.** One JSON file per lease in `Application Support/Awake/leases` (owner, reason, expiry, source), written by the `awake` command or its MCP server and watched by the app (`LeaseManager`: directory events plus a 30 s poll). No socket: a lease can be asked for while the app is not running. While any lease is held a session runs (started if needed, first end = the default duration) and ends at the later of its own end and the last expiry plus the grace; when the last lease goes, a session only leases held ends after `leaseGraceMinutes` (5) with the reason "leases released". A session the user started is never shortened. Capped by `leaseCapHours` (8) and the maximum session length. The floors win: any other end revokes the session's leases.
- **"Awake until these finish".** `--until-pid`, `--until-tmux` and `--until-exit -- cmd`, each with `--grace`, bounded by the lease's expiry. A pid is trusted only with its start time and boot session, so a reused pid never holds a lease.
- **`awake` command** (`lease`, `release`, `leases`, `status`, `extend`, `mcp`), shipped at `Awake.app/Contents/Helpers/awake` and linked onto the PATH by Settings or `scripts/link-cli.sh`. **MCP server** (`awake mcp`, stdio, protocol 2025-06-18) with `awake_lease`, `awake_release`, `awake_leases`, `awake_status`, `awake_extend`.
- Leases show in the menu, in `status.json` and in the session summary; "Lease granted" and "Last lease released" go to the Mac and the phone. Settings > Leases has the toggles.

Still to do: schedules and profiles (end at a clock time, recurring nights, Overnight / Commute / Clamshell desk / Demo); leases on the phone screens arrive with phase 3; a real-Mac check of a lease-held overnight session recorded in `docs/release-validation.md`.

## 4. Decisions already made

- **Platform:** macOS 26 or later, Apple Silicon, Swift 6, SwiftUI in an `NSStatusItem`. No Dock icon.
- **Phone first as a PWA**, not a native app.
- **Transport:** push out via ntfy/Pushover; pull and control over Tailscale. No cloud relay of our own in v1.
- **Safety rules carried over unchanged:** journal before change; clear an entry only after a confirmed undo; never SIGKILL `sudo`; never signal a pid we can't prove is ours; a session never starts unless the recovery agent is armed.
- **Honesty rule:** every reading is labelled measured, derived or unknown. "Unknown" never counts as "fine".
- **Licence:** all rights reserved for Awake's own code (the owner may sell it later), with Insomnia's MIT notice kept for the code it came from. Open-sourcing part of it is a later decision; closed to open is one commit, open to closed is impossible.

## 5. Open questions

1. Which agents to support first? Proposal: Claude Code and Codex in tmux, then Cursor and the GUI agents.
2. How much automation on prompts? Proposal: report by default; remote one-tap answer opt-in per agent; never auto-answer.
3. Where do secrets live (hotspot password, ntfy token, Tailscale auth)? Proposal: login Keychain, as Insomnia does.
4. Notarized builds and a Homebrew cask, or ad-hoc signed like Insomnia? Affects install friction a lot.

## 6. What we will not do

- Remote unlock of the Mac.
- Reading iMessage or Notification Center databases in v1 (powerful, but a privacy decision to make on its own).
- Auto-answering agent prompts without a person.
- Pretending recovery is guaranteed. The README says it can fail, and the app shows a warning instead of hiding it.

## 7. How we will know it works

Each phase ships with a real-Mac checklist run on a ventilated desk with disposable work, and the result recorded with the exact build, macOS version and hardware. Unit tests use fakes and temp folders only; nothing in the test suite changes the developer's power settings, processes or Wi-Fi.

## 8. Seeing the Mac screen from the phone

Three levels, cheapest first. Each is a step in the phases above.

1. **No code (now):** macOS Screen Sharing + Tailscale + a VNC client on the iPhone (Screens, Jump Desktop). Use it to learn what people actually need to see.
2. **Screenshots (phase 1):** `ScreenCaptureKit` snapshot every 2–5 s, shrunk, shown in the phone web app. Near-zero CPU and battery cost.
3. **Live mirror (phase 3):** `ScreenCaptureKit` → hardware HEVC/H.264 (`VideoToolbox`) → WebRTC → iPhone (`AVSampleBufferDisplayLayer`, Picture-in-Picture) or Safari. Target 10–15 fps at ~1280 px wide, 1–3 Mbit/s, 150–300 ms delay. Per-window capture for terminals; a text view (tmux capture or a web terminal) for agents in tmux, which is sharper and cheaper than video.

Edge cases to handle, in test order:

- Lid closed, panel at brightness 0: capture works; a truly sleeping display may stop drawing, so hold a display assertion or capture windows.
- Locked screen: whole-screen capture shows the lock screen. Decide between window capture (verify it renders while locked), or "unlocked while a paired phone is connected, re-lock on disconnect".
- Screen saver and idle dim take over the picture; disable during a session or capture windows.
- Screen Recording permission is asked again after every rebuild (signature changes). Nothing can capture before login after a reboot.
- NAT and IP changes (Wi-Fi → hotspot): reconnect by itself. Phone-as-hotspot is the fastest case (same network).
- Data and battery: 0.5–1.5 GB per hour of live video on cellular; 3–8% CPU on the Mac. Stream only while the phone is looking; otherwise screenshots.
- Readability: a 14-inch Retina screen on a phone needs zoom or a single-window view.
- Display changes (external monitor, resolution, Low Power Mode rescale) restart the capture.
- Security: encrypt end to end (Tailscale or WebRTC DTLS), pairing, never record to disk, re-lock on disconnect.
- iPhone: iOS stops background video; use PiP. A native app needs a developer account for a lasting install (TestFlight).
- Apple's own tools go the other way (iPhone Mirroring) or are Mac-to-Mac only (high-performance Screen Sharing).

## 9. Distribution

### Mac: direct download, notarized (not the Mac App Store)

The App Store sandbox forbids what Awake needs: `sudo pmset`, SIGSTOP on other apps, reading other apps' windows, writing another app's preferences, a launchd recovery agent. So:

1. **Notarized zip/dmg on GitHub Releases + Homebrew cask** (`brew install --cask awake`) + Sparkle for updates. Needs the $99/year Apple Developer ID. This is the default path.
2. **`install.sh` / CLI installer** kept for terminal users (as Insomnia and REA do), never the only path.
3. **Ad-hoc signed zip** (Insomnia today) only for early testers: every stranger hits a Gatekeeper block.
4. **Setapp** later, for discovery and payments; needs notarization anyway.
5. **Mac App Store** only ever for a cut-down viewer, if at all.

**Built (Step E).** Paths 1 to 3 above exist and share one pipeline:

- **Release workflow** (`.github/workflows/release.yml`): a tag `v<version>` tests, builds, signs, packages and publishes `Awake-<version>.zip`, `.dmg`, `install.sh`, `uninstall.sh` and `SHA256SUMS`, with an attestation and notes that open with how the build is signed. With the Developer ID secrets it signs with the hardened runtime, notarizes and staples; without them it publishes an ad-hoc build labelled "Unsigned build: right-click → Open on first launch". Nothing fails for a missing secret. The tag's digits become the bundle's version (`scripts/build-app.sh --version`).
- **Sparkle 2** for updates: "Check for Updates…" in the menu and Settings > App > "Check for updates automatically". The feed is `appcast.xml` on the latest release, written by CI when `SPARKLE_PRIVATE_KEY` is set. The updater runs only in a Developer ID build that carries the public key (`scripts/sparkle-public-key.txt`, empty until the owner generates the pair) and never during a session; any other build explains why and links the releases page.
- **Homebrew cask** (`Casks/awake.rb`): CI writes each release's version and SHA-256 into it on the `homebrew` branch, and into the tap `ParthJairam07/homebrew-awake` when `HOMEBREW_TAP_TOKEN` is set.
- **`curl … install.sh | bash`**: downloads the latest release, checks it against `SHA256SUMS`, asks, then runs that release's installer.
- **Setup window** on first launch (and "Setup…" in the menu): what Awake does and how it can fail, notifications, the sudoers rule (Copy / Run in Terminal, never a silent sudo), Accessibility and Screen Recording, ntfy with a test, Tailscale, launch at login. Every step can be skipped.
- **CI**: every pull request builds and packages an ad-hoc `0.0.0-ci`.

Still to do by hand, once: the Developer ID certificate and notary secrets, the Sparkle key pair, the tap repository, and making the repository public. `docs/releasing.md` is the checklist. Setapp and the App Store are untouched.

### iPhone: PWA first, then TestFlight, then App Store

1. **PWA** served by the Mac over Tailscale: home-screen icon, full screen, web push (iOS 16.4+). No review, ships at once, same code on Android. Limits: no background work, weaker push, no PiP video.
2. **Native iOS app on TestFlight** (free with the developer account, 10,000 testers, 90-day builds) once people want PiP live view and reliable push. **App Store** after that.
3. Zero-app fallbacks that already work: ntfy / Pushover / Telegram for alerts, Screen Sharing for the picture.
4. Web distribution of iOS apps exists only in the EU with its own fees; ignore for now.

### How the phone reaches the Mac

1. **Peer-to-peer, no server (v1):** Tailscale (or ZeroTier / NetBird). The Mac serves the PWA and API on its private IP. Free, encrypted, no data through anyone's server. Cost: users install Tailscale on both devices. `tsnet` or Tailscale Serve can give the Mac a real HTTPS certificate.
2. **Small relay we host (later, the paid layer):** Cloudflare Tunnel or a Fly.io / Cloudflare Worker that brokers WebRTC or WebSocket plus push (APNs, web push). Removes the Tailscale requirement; adds a service people depend on.
3. **Full backend** (accounts, history, team dashboards) only when there is a team product. Changes the privacy story.
4. **Out of the box:** CloudKit as a free Apple-hosted relay between one person's own Mac and iPhone; or a Telegram / Discord bot as the whole control channel (push, buttons, screenshots, no app).

### Business shape

- Source stays readable on GitHub for trust (the app runs `sudo` and pauses other apps, and people will want to read it), but under all rights reserved for now. Whether to open-source the Mac core later is decided when there is something to sell.
- Paid layer: the native phone app and/or the hosted relay. One-time purchase through Lemon Squeezy or Paddle (they handle tax) unless the relay makes a subscription honest.

### Order of work

1. Pay the Apple Developer fee now (notarization and TestFlight both need it).
2. Mac: notarized release + Homebrew cask + Sparkle; keep `install.sh`. *(pipeline built; waits on the certificate, see above)*
3. Phone: PWA over Tailscale with web push; ntfy / Pushover as fallback.
4. Native iOS app on TestFlight; App Store after.
5. Relay service as the paid option for people who will not install Tailscale.
