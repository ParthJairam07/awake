# FAQ

Short answers. The [README](../README.md) has the overview,
[install.md](install.md) every install step, and [recovery.md](recovery.md)
every recovery case.

## Installing

**Which Macs does it run on?**
Apple Silicon Macs with macOS 26 or later. Releases are built for arm64
only.

**macOS says the app "cannot be opened" or is from an unidentified
developer.**
That release is an unsigned build; its notes open with "Unsigned build:
right-click → Open on first launch". Right-click Awake in Finder and choose
Open. If macOS still refuses, open System Settings > Privacy & Security,
scroll to the message about Awake and click Open Anyway. A release whose
notes say "notarized by Apple" opens without this.

**Why does it want my password?**
Once, to install one sudoers rule. Switching sleep off (`pmset disablesleep`)
needs administrator rights; the rule lets your account run exactly four
`pmset` commands (sleep off, sleep on, Low Power Mode on, off) without a
password, so a session can start and, more importantly, end with nobody at
the keyboard. Any program running as you can use that rule too. Awake never
asks for the password itself: Terminal does, running a command you can read
first. The rule is `/etc/sudoers.d/awake`; the README lists its four lines.

**Can I use it without the sudoers rule?**
No. Without it a session cannot start, and Awake says so.

**Why Accessibility and Screen Recording?**
Keeping the Mac awake needs neither. They are for the agent features:
reading a dialog that blocks an agent, and sending the phone a picture of
the screen when you ask for one. Skip them and everything else works.

**Why Location?**
Only if you use the iPhone hotspot handoff. macOS requires Location
Services access to read Wi-Fi network names. Awake never reads your
location.

**I skipped Setup. How do I get it back?**
Right-click the menu bar icon and choose "Setup…".

## Updating

**How do updates work?**
A build signed with Awake's Developer ID checks GitHub Releases for a signed
update, in the background (Settings > App > "Check for updates
automatically") or when you choose "Check for Updates…" in the right-click
menu, and asks before installing. It never checks or installs during a
session, because installing quits the app.

**"Check for Updates…" says this build cannot update itself.**
Unsigned builds and source builds do not update themselves: there is no
signature to tie an update to. Use the button to open the releases page, or
`brew upgrade --cask awake`, or run the curl installer again.

## Sessions

**Does it keep the Mac awake forever?**
No. Every session has an end time, and there is no "forever".

**Does it work with the lid closed and no monitor?**
Yes; that is the point. Awake locks the screen, turns the display off and
mutes audio when the lid closes, and puts everything back when it opens.

**Can I put the Mac in a bag?**
Don't. With sleep off the Mac keeps producing heat, and a bag traps it. The
heat rules end the session at critical heat, but they only run while the
app does, and no software can see inside a bag.

**What ends a session early?**
You, the battery floor (below 10% on battery by default) or critical heat.
The end reason is in the session summary and the log.

**Will my agents slow down with the lid closed?**
Not because of sleep. Chrome-family browsers throttle hidden windows; the
menu offers to relaunch them without that. Low Power Mode, which Awake turns
on at lid close by default, does slow the CPU; turn that lid action off in
Settings if speed matters more than battery.

## When something goes wrong

**The app crashed. Is my Mac stuck awake?**
Not for long. A recovery agent runs every minute and switches sleep back on
once the session's end time has passed. To do it now, open Awake again, or
run `sudo pmset -a disablesleep 0`.

**How do I check whether sleep is switched off?**
`pmset -g | grep -i sleepdisabled`. `1` means sleep is off.

**An app is frozen after a session.**
Awake only unfreezes a process it can prove it froze. Open Awake: the menu
names what is left. [recovery.md](recovery.md) has the manual steps.

**Where are the logs?**
`~/Library/Logs/Awake/awake.log`. They can contain Wi-Fi names and process
names, so read one before sharing it.

## Phone

**Do I need an account?**
No. Phone alerts use [ntfy](https://ntfy.sh): install its app, subscribe to
a topic with a long random name, type the same name in Awake. Pushover works
too if you already use it.

**Who can read my alerts?**
On the public ntfy.sh server, anyone who knows the topic name; that is why
it should be long and random. Settings > Phone alerts takes your own ntfy
server and an access token if you want it private.

**Why Tailscale?**
The phone app (coming) talks to the Mac directly over Tailscale, a private
network between your own devices, so nothing is exposed to the internet.
Alerts through ntfy do not need it.

## Privacy

**What does Awake send, and where?**
Nothing to us: there are no servers of ours, no telemetry and no account.
Alerts go to ntfy or Pushover only if you configure them. Update checks
read one file from this project's GitHub releases.

## Removing it

**How do I uninstall?**
`brew uninstall --zap --cask awake`, or `uninstall.sh` (see
[install.md](install.md#uninstall)). Both remove the app, the recovery agent
and the sudoers rule; `--zap` and `--purge` also remove settings and logs.
