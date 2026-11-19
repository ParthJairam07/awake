# Release validation

> The records from "v0.1.0" down were inherited from Insomnia, the project Awake was forked from, and describe Insomnia's builds. The first Awake record is the November 19, 2026 one below; it ran on a macOS virtual machine, so no Awake build has been validated on a physical MacBook yet.

This page records the real-Mac checks each release passed and the audits
behind the safety fixes. It is not a certification that unattended or
lid-closed use is safe. The checks to run before the next release are in
[Releasing](releasing.md#real-mac-checks-before-a-release).

## November 19, 2026 real-Mac run on a macOS virtual machine (Awake)

The first run of Awake itself outside its test fakes, for
[issue #5](https://github.com/ParthJairam07/awake/issues/5). It ran on a
macOS **virtual machine**, not a MacBook: `VirtualMac2,1`, Apple M4 Pro
(Virtual), arm64, macOS 26.6.2 (25G83), Xcode 26.6 (17F113), Swift 6.3.3,
tmux 3.8, on November 19, 2026 between 05:00 and 06:10 UTC. The VM has no
battery, no lid sensor, no Wi-Fi port, no audio output device, no Tailscale
and no iPhone, and its only display counts as an external display. Whatever
needs one of those is in the list at the end and was **not run**.

Builds, all ad-hoc signed source builds installed with `scripts/install.sh`
into the standard per-user locations (no `AWAKE_HOME`):

- Checks up to the upgrade ran on commit `3729c63`.
- The lid simulation ran on the same commit installed with
  `AWAKE_LID_SIMULATION=1 ./scripts/install.sh`.
- The retests of the fixes ran on `3729c63` plus the source changes of this
  record's commit, before it was rebased onto `207155b`. The rebased tree
  passed `swift test` (1,869 tests, no failures); it was not installed again.

| Check | Result |
| --- | --- |
| `swift build` and `swift test` on `3729c63` (1,855 tests) | Passed |
| `scripts/install.sh` from source: app, LaunchAgent `com.awake.backstop`, the four-command sudoers rule | Passed |
| Setup wizard, all seven steps: notifications, sudoers, Accessibility, Screen Recording, phone alerts (skipped), Tailscale (not installed, skipped), launch at login | Passed, with the two Setup defects below |
| 2-minute session: `SleepDisabled` 1 during, timer end, `SleepDisabled` 0, "Session ended" and summary notifications | Passed |
| 5-minute session: extend by 3 minutes, end by hand | Passed |
| Quit during a session restores sleep and clears the session | Passed |
| `kill -9` during a session, app left down: the recovery agent restored `SleepDisabled` 0 within a minute of the deadline, journal cleared, last exit code 0 | Passed |
| `kill -9` then relaunch before the deadline: "reconcile: session valid", session resumed, ended on its timer | Passed |
| Recovery agent between sessions over 2 minutes: runs counted up, last exit code 0, nothing written to awake.log, state.json untouched | Passed |
| CPU of the app: 0.0% idle over 2 minutes (9 samples), at most 0.5% during a session (4 samples) | Passed |
| `scripts/link-cli.sh` (links into `~/.local/bin` without sudo) | Passed |
| `awake lease --for 10m`: lease granted, session started, `awake leases`, `awake status`, lease in the right-click menu | Passed |
| `awake extend` by short id, `awake release --owner`, `awake release --all`, expiry of a 3-minute lease | Passed |
| `awake lease --until-exit -- sh -c 'sleep 3; exit 7'` (exit status 7 passed through), `--until-pid` (released within about 40 s of the process being killed) | Passed |
| `awake mcp` driven by hand over stdin: initialize, tools/list, `awake_lease`, `awake_leases`, `awake_status` | Passed |
| Last lease gone: "Last lease released", session ended 5 minutes later with reason `leasesReleased`, sleep restored | Passed |
| Adding time to a lease-started session makes it the user's ("the session is now yours") | Passed |
| Marked tmux pane (`@awake 1` and an `awake:` title) running a stand-in script: found, busy, then waiting with its `(y/n)` prompt in the notification, the menu and `status.json` | Passed |
| Phone app on `http://127.0.0.1:7788` in Chrome on the same machine: pairing with the six-digit code, Session tab, +30 m, Agents, Machine, Security and Log tabs, a screenshot of the Mac | Passed |
| Phone app refuses every API route without a paired token (401) and listens on 127.0.0.1 only; audit.log is 0600 and records an answer's length, not its text | Passed |
| Phone Answer to a waiting agent in a marked pane | Passed |
| Phone Pause and Resume: processes stopped and continued, journaled in state.json and cleared | Passed for the signals and the journal; see the open finding on what a pause does to a job started from a shell |
| Phone Nudge, Stop, and Answer after a pause | **Failed on `3729c63`**, fixed here, see below |
| Upgrade: `install.sh` run over a running session quits the app, restores sleep, replaces the bundle and reloads the LaunchAgent | Passed |
| Simulated lid close/open with `scripts/simulate-lid.sh` on the `AWAKE_LID_SIMULATION=1` build: both triggers logged; the close was treated as desk mode ("external display online, lid actions skipped") | Trigger path passed; the lid actions themselves were not exercised |
| A normal install ignores `scripts/simulate-lid.sh`: no log line, trigger file left in place, no "Lid simulation build" line | Passed |
| `scripts/uninstall.sh` during a session: sleep restored, journal clean, LaunchAgent, sudoers rule and app removed, config.json and logs kept | Passed |

### Defects found and fixed in this commit

Each was seen on the running app, has a regression test, and, except the
second, was seen fixed on the running app afterwards.

1. **Setup was lost half way.** Allowing Screen Recording makes System
   Settings offer "Quit & Reopen". The quit closed the Setup window, which
   marked setup as done, so the reopened app never showed steps 5 to 7.
   A window closed because the app is quitting no longer counts.
2. **Setup kept saying notifications were off** after "Allow notifications"
   and the macOS prompt were both answered, until "Check again": the step
   read the status once, one second after the click. It now follows the
   reading until macOS has an answer. Unit-tested only: macOS does not ask
   twice, so the prompt could not be shown again on this machine.
3. **The phone's Nudge confirmation said `Types "continue" into the
   agent`**; it sends Enter. The text now says so.
4. **The phone's Stop did nothing for an agent in a marked tmux pane and
   reported success.** The signal went to the pane's first process, an
   interactive zsh, which ignores SIGTERM. It now goes to the job running
   in the pane.
5. **After a phone Pause and Resume, the phone's Answer was run by the
   pane's shell as a command** (`echo ANSWER-RAN-IN-SHELL` was executed).
   Nudge and Answer are now refused while the pane's shell is in front of
   the agent.

### Open findings, not fixed

- **A pause turns an agent started from a shell prompt into a background
  job.** SIGSTOP makes the interactive shell print "suspended" and take the
  terminal back; after SIGCONT the agent is a background job, and one that
  reads the terminal stops again until someone types `fg`. tmux also
  continues a stopped first process of a pane. This is how job control
  works, and it applies to the priority pause too. Item 5 above only stops
  the phone from typing into the shell. A Stop sent to such a job takes
  effect only when the job is continued. Not tried with a real Claude Code.
- Quitting with no session posts "Session restored — Awake quit. Sleep is
  back to normal."
- With no Wi-Fi port, every session posts "Internet down — Wi-Fi has had no
  connection for 1m 30s", and the session log says "on battery" on a machine
  with no battery. The menu and `awake status` say "Lid: open" where the
  phone's Machine tab says "unknown".
- After the recovery agent ends a session, the summary at the next launch
  counts the time up to that launch ("Ran 3m 39s" for a 3-minute session).
- The app menu's "Settings…" (the SwiftUI `Settings` scene) opens an empty
  "Awake Settings" window; the real one opens from the status item's menu.
- A rebuilt ad-hoc source build cannot read the previous build's paired
  phones (Settings says so) and macOS asks for Screen Recording again.
- The first phone screenshot raises a macOS dialog on the Mac ("bypass the
  system private window picker") that someone at the Mac has to answer.
- `uninstall.sh` leaves the `~/.local/bin/awake` link that `link-cli.sh`
  made.

### Not run here: needs a physical MacBook, or more than this VM has

- A real lid close and open, and every lid-close action: display and
  keyboard darkening, mute and audio restore, lock, Low Power Mode, the
  freeze list, Docker, headed-browser throttling, clamshell with a real
  external display.
- Battery: the floors, the trend, a weak charger, unplugging, battery
  temperature. Thermal pressure. The sleep guard read back against another
  process that resets `SleepDisabled`.
- Wi-Fi: hotspot join and failover, captive portals, the Wi-Fi name with
  Location allowed.
- A real iPhone: Tailscale and `tailscale serve`, the QR code, Add to Home
  Screen, web push, ntfy and Pushover alerts. Lock now and Panic from the
  phone were not pressed either.
- Reboot and login with an active or dirty journal, and launch at login
  after a restart (the login item was only registered).
- A real agent (Claude Code, Codex, Cursor) with its hooks and through MCP;
  the dialog detector; the pre-end wip commit and push; the priority pause
  under real pressure.
- A release build: Developer ID signature, notarization, Gatekeeper, the
  updater, the release zip's `install.sh --app`, `uninstall.sh --purge`.

Screenshots of this run are in
[assets/screenshots/real-mac-2026-11-19](assets/screenshots/real-mac-2026-11-19).

## v0.1.0

The maintainer ran these checks on a MacBook with an Apple M5 (Mac17,2) and
32 GB of memory, on macOS 26.2 (25C56), before the release on October 10,
2026, and recorded them here on October 11, 2026. The tested build is the
release's Awake.app (version 0.1.0, build 1) with the scripts from the
`v0.1.0` tag, commit `ea5ce15`.

| Check | Result |
| --- | --- |
| Normal end, deadline expiry, and repeated Quit restore live power state | Passed |
| Force-quit followed by launchd deadline recovery and retry after failure | Passed |
| Reboot/login with active or dirty journals | Passed |
| Lid-close/open and safe recovery of explicitly selected test processes | Passed |
| Lid-close display/keyboard darkening and restore | Passed |
| Freeze-all scope with agents running (Cursor/T3 Code/Claude untouched) | Passed |
| Simulated lid close/open via scripts/simulate-lid.sh | Passed |
| Existing Low Power Mode preference and saved audio restoration | Passed |
| Docker Desktop idle/busy behavior with another Docker context selected | Passed |
| Hotspot permission, association, cancellation, and reconnect | Passed |
| tmux cancellation with a dedicated disposable pane | Passed |
| Headed-browser throttling with the lid closed | Passed |
| Battery/thermal event behavior on supported hardware | Passed |
| Install/upgrade/uninstall with recoverable failure conditions | Passed |
| Install from the 0.1.0 release zip with `scripts/install.sh --app ./Awake.app` on a working Mac, including its `codesign --verify --strict --deep` of the prebuilt bundle and first launch under Gatekeeper | Passed |
| `scripts/uninstall.sh` run from the unpacked 0.1.0 release folder | Passed |

The release zip holds the Awake.app that was installed on the
maintainer's Mac, copied file for file and not re-signed. No GitHub workflow
built or attested it. Its executable matches the local release build of a
clean checkout at `b05652c`, apart from two Mach-O size fields and the code
signature that ad-hoc signing writes; that comparison does not prove which
commit the build came from. The `v0.1.0` tag adds `install.sh --app`, its
tests and its documentation on top of `b05652c`, with app sources unchanged.

## September 14, 2026 baseline

The pre-fix audit found lifecycle races, incomplete recovery reporting,
uninstall recovery loss, Docker daemon-selection ambiguity, and tmux work
continuing after session end. The main-branch baseline passed 178 Swift tests;
the separate icon PR added one packaging test. Seven audit-only failure-path
tests reproduced bugs despite that green baseline. A historical secret scan
reported no detected secrets across 175 locally available commits.

## Remediation evidence

- [CI PR #2](https://github.com/kgarg2468/Insomnia/pull/2), commit
  `f20a860`: hosted macOS tests/release build, ShellCheck, and Greptile check
  succeeded. No unresolved review threads were present at verification.
- [Automation PR #3](https://github.com/kgarg2468/Insomnia/pull/3), commit
  `52a3b29`: after addressing three Greptile findings and a timeout-reporting
  defect, an independent snapshot passed 206 tests, release compilation, and
  ShellCheck. The three review threads are resolved. Follow-up `ba82712`
  installs tmux on the hosted runner: CI now executes the pane tests instead
  of skipping them. Hosted CI reports 206 tests with one animation-dependent
  UI test skipped, zero failures, and a successful release build and ShellCheck.
  The Greptile check also passed. These tests include
  private tmux-server tests and a fake Docker executable against a temporary
  Unix socket. Removing cancellation and endpoint guards caused regression
  tests to fail. Additional cases cover cancelling a queued command before
  launch, retaining the checked tmux pane across an active-pane change, and
  stopping during a suspended hotspot join. This is not a live Docker-freeze
  or hotspot validation.
- Recovery/lifecycle remediation before PR review: an independent snapshot of the source,
  test, and script tree passed 315 tests with zero failures, zero skips, and no
  compiler warnings. Release compilation and ShellCheck passed. A redacted
  source secret scan detected no findings. Tests exercise injected power/audio
  failures, lifecycle races, process identity, launchd sequencing, and temporary
  recovery/install/uninstall fixtures; they do not mutate live power settings or
  install/remove the working app. Hosted CI and automated review must also be
  checked on the resulting PR's latest head.
- PR #4 review reproduced two further failure paths: unconfirmed process
  ownership after a failed journal save, and installer loss of the previous
  recovery agent. Follow-up tests cover provisional non-resumable freeze
  entries, preserving the trusted plist on bootstrap failure, and holding the
  shared recovery lock throughout installer recovery and agent replacement.
  The hosted lock-test fixture now uses an explicit release signal instead of
  assuming its simulated command stays alive for a fixed number of seconds.
  Independent verification of the combined follow-up source/tests/scripts
  passed 329 tests with zero failures, zero skips, and no compiler warnings;
  release compilation and ShellCheck also passed. Hosted checks remain a
  separate gate on the PR's latest commit.

Check each PR's latest commit and check results; this record does not make an
earlier green run evidence for subsequent changes.

## September 16, 2026 lid-close audit

During an active session on the development MacBook the user closed the lid
and the panel stayed lit with the keyboard backlight on. The log shows the
session starting at 00:48:12, the lid closing at 00:48:19 and opening at
00:48:25, with Awake's lid-close transaction running and freezing Slack
(6 pids) only. `pmset -g log` has no "Display is turned off" event in that
window; the next display-off is the 2-minute idle timer at 01:08:51. Root
cause: `pmset -a disablesleep 1` (the sleep guard) removes the only path by
which macOS turns the built-in panel and keyboard backlight off on clamshell
close (the system-sleep path), and spec section 4 claimed both were "already
off by hardware", so `LidActions` never touched them. Primitives measured on
that machine, without root, and now used by `DisplayPower.swift`:
`DisplayServicesGetBrightness` / `SetBrightness` / `CanChangeBrightness`
(present, rc 0, immediate; `GetBrightness` can return a dimmed value during
the "delayDisplayOff" phase); display sleep via `IORequestIdle` on
`IODisplayWrangler` (honoured only without `PreventUserIdleDisplaySleep`
assertions and deferred ~30 s after a wake, so best effort); wake via
`IOPMAssertionDeclareUserActivity(kIOPMUserActiveLocal)` within ~1 s; and
`KeyboardBrightnessClient` (`copyKeyboardBacklightIDs`, `isKeyboardBuiltIn:`,
`brightnessForKeyboard:`, `setBrightness:forKeyboard:`; one built-in id).
Display brightness 0 does not switch the keyboard backlight off. The
computer-use agent declares `UserIsActive` and `PreventUserIdleDisplaySleep`
every ~40 s, so the design does not fight it: brightness 0 keeps the panel
dark either way. No sudoers or install change was needed. Unit tests with
fakes cover the fix, and v0.1.0's darkening check above ran it on a real
Mac.

A simulated run of that fix on the same machine, later on September 16, 2026
(`scripts/simulate-lid.sh` during a session, lid open), found a defect in
what was saved. The close happened after the panel had idle-dimmed and slept:
`DisplayServicesGetBrightness` returned the idle-dim value (0.0625, user value
0.5), and with the display asleep the keyboard backlight was suppressed
(`isBacklightSuppressedOnKeyboard:` true), so `brightnessForKeyboard:`
returned 0; the journal held 0.0625 and 0, and the open restored a dim panel
and a dead backlight. Also measured: powerd keeps its own "pre-dim"
brightness and re-applies it asynchronously on every display wake, so a
restore written right after `IOPMAssertionDeclareUserActivity` can be
overridden a moment later; writes made while the display is asleep never
update that memory; the keyboard idle-dims on its own
(`isBacklightDimmedOnKeyboard:`); and
`CGEventSource.secondsSinceLastEventType(.hidSystemState, kCGAnyInputEventType)`
(public, no permission) gives the idle time, with the idle dim never starting
within 30 s of input. The fix: a reading is trusted only with idle under 30 s
and the device awake/unsuppressed, `BrightnessSampler` keeps the last trusted
reading (every 30 s with the lid open, at start, 3 s after each open), the
close journals the trusted value or the sample, leaves the keyboard alone when
neither exists, and the open re-asserts the restore 2 s after the wake. Unit
tests with fakes cover it, and it is part of v0.1.0.

Measured on October 1, 2026 on the same machine (macOS 26.2, 25C56, arm64),
read-only through the Objective-C runtime, the `KeyboardBrightnessClient`
instance method type encodings: `copyKeyboardBacklightIDs` `@16@0:8`,
`isKeyboardBuiltIn:` `B24@0:8Q16`, `brightnessForKeyboard:` `f24@0:8Q16`,
`setBrightness:forKeyboard:` `B28@0:8f16Q20`,
`isBacklightSuppressedOnKeyboard:` `B24@0:8Q16`,
`isBacklightDimmedOnKeyboard:` `B24@0:8Q16`. `DisplayPower.swift` now
refuses the DisplayServices calls on any macOS major other than 26, and the
keyboard class when a required method is missing or an encoding (offsets
removed) differs from these; on an Intel Mac `BOOL` encodes as `c`, so the
keyboard backlight is refused there until measured. A refused device is
skipped at lid close, journals nothing, and is named in Settings; with
both devices refused the close does not request display sleep, since the
open wakes the display only for a journaled brightness. A value
journaled before an update that the guard now refuses stays journaled,
flagged as refused so it no longer counts as dirty, with an error that
names each saved level and says to set it by hand; backstop.sh and
uninstall.sh read the flag. A later build that can make the call writes
the kept value only while the device still reads 0, the level the close
left, so a level set by hand since is not overwritten. It decides only
on a reading taken with the lid known to be open, the display awake and
the keyboard backlight neither suppressed nor dimmed, keeps the entry
when the read fails, and reads again every 3 s for a minute, then every
minute while the entry waits, reading nothing while the lid is not known
to be open. An entry found set since, or written, that state.json cannot
clear is not read or written again, and only its clear is retried; the
clear goes into the journal ahead of any later write, so a lid close
journals the level the device reads. When the write fails and state.json
cannot take the cleared flag either, backstop.sh would pass over the
entry, so Awake retries it in process and holds Quit until the write
lands or the flag is on disk. The sampler takes no reading of a device
whose brightness is journaled, and each level written from the journal
or found set since becomes its sample, so a close right after a late
restore journals that level. A display reading above 0 under Awake's
own Low Power Mode, or after it in the same boot, relaunches included,
decides nothing, and a launch after a restart reads the entry again. A
backstop run whose `lowpowermode 0` exits 0 gives that record its own boot,
so a launch in that boot doubts the reading too. A later reading of 0, in
that run, a relaunch or after a restart, does not bring the kept value back
either (the reading above 0 is journaled), unless the reading above 0 was
taken under a closing lid, of a panel asleep, or of another entry. That 0
is not taken as a level set since either, however late it is read, since
macOS may still hold the panel at a closing lid's 0: the entry stays
flagged until the panel reads above 0. If state.json refuses that record,
Quit waits until it lands. A Low Power Mode claim journaled before a
restart is read before the switch-off, and the read only goes to the
log. Whether the mode reads on, off or not at all, the switch-off counts
as Awake's in this boot, since a mode that reads off may have gone off
only a moment ago. The kept display entry is recorded for this boot, so
it stays flagged, and the display is not sampled, through this boot,
relaunches included. A mode off since long before the launch reads the
same, and its entry waits the same way, at the same cost. Only a launch
after a restart that came after state.json took the ownership clear can
decide the entry, and only by a trusted reading with the lid known open
and the panel awake. After a reading above 0, a 0 still waits for a
reading above 0. A boot session that cannot be read, a lid not known to
be open, a panel asleep or unreadable, or a state.json that refuses the
writes can keep the entry waiting longer. That a restart ends the mode's
rescale is assumed, not measured, and a restart clears no entry by
itself. A close with no trusted level leaves the
entry flagged and the panel lit, and only asks the display to sleep. After
a reading above 0, a close whose only level is a 0 read under the closing
lid leaves the entry flagged too. A write whose clear state.json refuses is still written again 2 s
later and, under the mode, after it. A `lowpowermode 0` that exits 0 while
state.json refuses the ownership clear still does the write owed after
the mode, and the display sample stays the level written after it until
the clear lands; one that exits 0 while state.json cannot be read does
that write once state.json reads again and still owes it. A write after
the mode dropped while state.json refuses that clear stays dropped. Unit
tests with an injected version and fake classes cover the guards. They came
after v0.1.0, so their real-Mac checks are in the release checklist.

## October 10, 2026 macOS 27.0.1 (MacBook Pro, Apple M5 Pro)

Machine: MacBook Pro, Apple M5 Pro, 64 GB, macOS 27.0.1 (26A434). Build:
main `b5f7cf0` plus the DisplayServices major gate opened to 27, compiled with
the Command Line Tools' Swift 6.4 against the macOS 26.5 SDK (the macOS 27 SDK
expands SwiftUI `@State` as a macro whose plugin ships with Xcode only, so a
Command Line Tools build against it fails), ad-hoc signed, installed with
`scripts/install.sh`.

- A read-only probe on 27.0.1 found `DisplayServicesGetBrightness`,
  `DisplayServicesSetBrightness` and `DisplayServicesCanChangeBrightness`;
  `GetBrightness` returned 0 with brightness 1.0 and `CanChangeBrightness`
  returned true for the built-in display. All six `KeyboardBrightnessClient`
  type encodings matched the macOS 26 measurements.
- Supervised lid test on AC power on a desk: a 900 s session, lid closed
  for about 11 minutes. `pmset -g log` shows no sleep or wake in the window;
  a logger sampling every 30 s kept running. The log shows "display
  darkened (was brightness 1.0)"; the built-in brightness read 0.000 for the
  whole closed period and was restored to 1.0 at the timer end. The keyboard
  backlight, audio mute and the WhatsApp freeze were applied and undone.
  Battery temperature (`ioreg` "Temperature") went from 34.0 to 35.4 °C
  while charging from 48 to 67 %; thermal state stayed nominal.
- Low Power Mode was never enabled in that session: macOS 27 `pmset -g
  custom` prints `powermode` instead of `lowpowermode`, so the read failed
  ("no lowpowermode line under Battery Power") on every power event. On the
  same machine `sudo -n pmset -b lowpowermode 1` set `powermode 1` under
  Battery Power and `lowpowermode 0` set it back to `0`, so the existing
  sudoers commands still apply; only the read changes. The parser now falls
  back to `powermode` and reads `powermode 2` (High Power) as unknown.
  A standalone harness of the new parser read the live output as off and
  passed 8 cases; the Swift test suite was not run on this machine (the
  Command Line Tools have no XCTest), so hosted CI is the gate for it.
- Not exercised: a lid-closed session with the new Low Power read, any
  session on battery, a session longer than 15 minutes, or heavy load.

## October 11, 2026 Comet relaunch (MacBook Pro, Apple M2 Max)

Machine: MacBook Pro (Mac14,6), Apple M2 Max, 64 GB, macOS 27.0 (26A428).
Build: `main` `bb5cf2b` with the Comet change and the open PRs #58, #76 and
#74 applied, built with Xcode 27.1 (Swift 6.4), ad-hoc signed, installed
with `scripts/install.sh`. Comet 154.0.8037.179, Google Chrome 154.0.8037.98.

- Comet's Info.plist gives `ai.perplexity.comet`. Its framework binary has
  both `--disable-backgrounding-occluded-windows` and
  `--disable-renderer-backgrounding`, as Chrome's has.
- In a session with both browsers started without the flags, the log listed
  "throttled browsers: Comet, Google Chrome". "Relaunch Comet unthrottled"
  logged "relaunched ai.perplexity.comet unthrottled", and `ps -o args=`
  showed both flags on the new Comet main process. Chrome did the same.
- With Comet added to the freeze list by hand, two lid closes froze it (27
  and 21 processes) and the opens resumed all of them, none gone or failed.
- Not exercised: "Freeze every other app" with Comet running and not on the
  freeze list (FreezerTests covers the protected list), and page timers in
  Comet with the lid closed.

## Distribution boundary

Packaging is automated: `scripts/build-app.sh` makes the bundle, and the
Release workflow tests, packages, checksums, attests and publishes it, as a
stable release for a `v*` tag and as a nightly prerelease of `main` once a
day when it has new commits (`docs/releasing.md`). PackagingTests run a
patched copy of `build-app.sh` with the real codesign, RecoveryScriptTests
run `install.sh --app` against prebuilt fixtures, one of them ad-hoc signed
by the real codesign, and ReleaseWorkflowTests check that every action in the
workflows is pinned to a commit and that no job has more than read access
except the ones that publish. Releases are ad-hoc signed and not notarized;
stable releases are marked Latest, and nightlies are prereleases never marked
Latest. The first stable release, `v0.1.0`, was packaged by hand from the
maintainer's installed app, not by the workflow, and has no attestation (see
[v0.1.0](#v010)). Open-source availability and a passing PR are not
equivalent to readiness for a public binary release.
