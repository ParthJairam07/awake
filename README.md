# Awake

**Run your coding agents overnight. Watch and steer them from your phone.**

Awake is a macOS menu bar app plus a phone companion for people who run many AI coding agents at once (Claude Code, Codex, Cursor, Devin, local models) and want to walk away from the laptop: to sleep, commute, or go to the gym.

It keeps a MacBook awake for a set time, keeps the agents fast, and tells you on your phone when something needs you: an agent stuck on a prompt, a dying battery, a laptop getting hot, Wi-Fi that looks connected but isn't.

> Status: planning. No code yet. See [PLAN.md](PLAN.md).

## Why

Today the best tool for this, [Insomnia](https://github.com/krishhgg/Insomnia), is very good at one thing: keeping the Mac awake and then putting everything back exactly as it was. It is weak at what someone who has walked away actually needs:

1. **You can't see or control it from away.** Every alert is a macOS notification on a laptop whose lid is closed.
2. **It doesn't know about your agents.** The session runs on a timer, not on the work. It can't tell "all six agents finished at 2am" from "agent three is stuck on a permission prompt".
3. **Some safety checks miss real cases.** A charger too weak for the load counts as "charging", so the battery can drain to 0% mid-session. Lid closed with an external monitor still freezes your apps. Nothing locks the screen.

Awake starts from those gaps.

## What Awake does

**On the Mac**
- Keeps the Mac awake for a fixed time, never forever, with a recovery journal so everything is undone even after a crash (the Insomnia model).
- Knows each agent: alive, busy, idle, stalled, or waiting for input.
- Detects pop-ups and prompts that block agents (Gatekeeper, permission dialogs, "proceed? (y/n)", 2FA) and reports their text.
- Watches battery trend and charger wattage, battery temperature, thermal throttling, memory pressure, free disk, and real internet reachability (not just "Wi-Fi connected").
- Locks the screen on lid close. Leaves you alone when an external monitor is attached.
- Lets agents ask for awake time themselves: a **lease** per task, released when done. The Mac stays awake while any lease is held, capped by a limit you set.

**On the phone**
- Push alerts for the things that matter: agent waiting for you, battery or heat, internet down, session ending, something not restored.
- One screen per agent, one tap to answer a prompt, nudge, pause, or stop it.
- Extend or end the session, lock the screen, take a screenshot, commit and push a repo.
- A morning summary: what ran, what finished, what stalled, outages, battery used.

## Principles

- **Journal first.** Every change to the machine is written to disk before it is made, and undone from disk, never from memory.
- **Prove ownership.** Never pause or resume a process unless we can prove it is the one we touched (start time to the microsecond, boot session).
- **"Unknown" is a real state.** A reading we can't take is not "fine" and not "broken"; it is unknown, and we say so.
- **Fail closed.** When unsure, do nothing irreversible and tell the user.
- **Say what was checked.** Measured facts, assumptions and guesses are labelled as such.

## Non-goals (for now)

- Not a replacement for running agents on a desktop or a cloud box. For heavy loads that is still the safer answer, and Awake should say so.
- No remote unlock of the Mac. Apple does not allow it, and we would not want it.
- No kernel extension, no background daemon that outlives the session.

## Requirements

macOS 26 or later on Apple Silicon. A phone with a browser or the companion app. Tailscale (or similar) for the phone-to-Mac connection.

## License

MIT.
