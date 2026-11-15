# The phone app

Awake can serve a small web app to your phone: time left, extend, end or
start a session, lock the Mac, a screenshot of its screen, the machine's
readings (battery, heat, memory, disk, network) and the log. It is off
until you turn it on, and it is reachable only over
[Tailscale](https://tailscale.com), from phones you have paired.

## Set it up

1. **Install Tailscale on the Mac and on the iPhone** and sign both in to
   the same tailnet. On the Mac either build works (the App Store app or
   the standalone one from tailscale.com); on the phone it is the
   Tailscale app from the App Store. Leave it connected on both.
2. **Turn the phone app on**: Awake's menu > Settings… > *Phone app* >
   *Phone app*. The status line shows where it is listening, for example
   `Serving the tailnet on http://100.101.102.103:7788`. If it says
   *Tailscale not found*, the Mac has no tailnet address yet; the app then
   answers only on the Mac itself (`http://127.0.0.1:7788`), which is
   useful for trying it in a browser on the Mac and nothing else.
3. **Get an https address (recommended).** In Terminal on the Mac, once:

   ```sh
   tailscale serve --bg 7788
   ```

   (Use your port if you changed it. With the App Store build the command
   is `/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg 7788`
   unless you installed the CLI from Tailscale's menu. Tailscale may ask
   you to enable HTTPS certificates for the tailnet the first time; follow
   the link it prints.) Reopen Awake's Settings: *Open on the phone* now
   shows `https://<mac-name>.<tailnet>.ts.net`, and the QR code uses it.
   `tailscale serve --https=443 off` turns it off again.
4. **Pair.** Click *Pair phone…* (in Settings, or in Awake's right-click
   menu). Settings shows a six-digit code and a QR code. Point the
   iPhone's camera at the QR code and open the link; the code is filled
   in. Or open the address by hand and type the code. A code works once,
   for five minutes, and is replaced after five wrong tries.
5. **Add to Home Screen.** In Safari: Share > *Add to Home Screen*. Awake
   then opens full screen like an app. Pair from the home-screen app if
   you want to use it there: iOS keeps a home-screen app's storage
   separate from Safari's, so a pairing made in Safari does not carry
   over.

## What it does

| Tab | What is there |
| --- | --- |
| Session | Time left, +30 m / +1 h / +2 h, End, and Start with your presets or a number of minutes |
| Agents | One card per agent with its state, last output, repository and the prompt it is waiting on; Nudge, Answer, Pause, Resume, Stop, each confirmed. |
| Machine | Battery and its trend in watts, charger, heat, CPU speed limit, battery temperature, memory pressure, free disk, network and Wi-Fi name, Tailscale address, lid, Low Power Mode |
| Security | Lock now, a screenshot (pinch to zoom, optional refresh every 5 s), the paired phones, and Panic (hold): lock the Mac and end the session, which resumes everything Awake froze |
| Log | The end of Awake's log, refreshed as you watch |

What the Agents tab can do to an agent, while a session runs: **Nudge**
sends Enter to its tmux pane and **Answer** types one line (up to 500
characters, no control characters) followed by Enter, both only into a
pane you marked (`tmux set-option -p @awake 1` or an `awake:` title) that
is alive and not in copy mode. **Pause** stops the agent's processes
(SIGSTOP) and **Resume** continues them (SIGCONT), through the same
journal as the priority pause, so the session's end, a lid open, the
recovery agent or the next launch resumes a paused agent if you do not.
**Stop** sends SIGTERM to the agent's main process only, never SIGKILL,
and only if it is still the process Awake has been tracking. An agent
known only from hooks has no process and no pane, so it can only be
watched; an agent with `sudo` under it is not paused. Nothing here runs
`sudo`. See [agents.md](agents.md#from-the-phone).

The page stays live over one long-lived connection (server-sent events)
and reconnects with a growing delay; while it cannot reach the Mac it
says so in a banner and its buttons report the failure instead of
pretending.

The screenshot needs **Screen & System Audio Recording** for Awake on the
Mac (System Settings > Privacy & Security). Settings' *Phone app* section
shows whether it is allowed and opens the pane. Until it is, the phone is
told so plainly. macOS asks again after each reinstall of an unsigned
build, and Awake must be reopened after you allow it. Screenshots are made
in memory and sent to the phone; none is written to the Mac's disk.

## Security model

- **Tailnet only.** The server binds to the Mac's Tailscale address
  (`100.64.0.0/10` on a `utun` interface, and the tailnet IPv6 address)
  and to `127.0.0.1`, never to all interfaces. Nothing listens on the
  Wi-Fi or Ethernet address, so other devices on the same network cannot
  connect. Tailscale encrypts and authenticates the path between phone
  and Mac.
- **Pairing, then a bearer token.** Pairing gives the phone a random
  32-byte token. The phone keeps it in the browser's storage; the Mac
  keeps only a salted SHA-256 of it, in the login keychain (service
  `awake-phone-app`). Every `/api/` request must carry it. *Forget* or
  *Forget all phones* in Settings ends a phone's access at once, and the
  phone can unpair itself.
- **Allow-list.** The server answers a fixed list of routes and returns
  404 for everything else. There is no route that runs a command, reads a
  file by name, types keys, or changes a setting. The static pages carry a
  strict Content-Security-Policy and no third-party code.
- **Rate limits.** 30 requests per 10 seconds per phone. Five failed
  sign-ins or pairing attempts in a minute from one address blocks that
  address for five minutes.
- **Audit log.** Every pairing and every action is appended to
  `~/Library/Application Support/Awake/audit.log` (owner-only, one JSON
  object per line, rotated to `audit.log.1` at 5 MB): time, phone,
  action, arguments, result, address. Tokens, pairing codes and the text
  of an answer to an agent are never written. *Reveal in Finder* in
  Settings shows the file.
- **No remote unlock.** The phone can lock the Mac. It cannot unlock it,
  and Awake does not try. A locked Mac still runs its session and its
  agents, and the phone app keeps working.

Anyone holding a paired, unlocked phone can do what the app can do, so
treat it like the Mac's keys: use a passcode on the phone and *Forget*
one that is lost.

## What works without HTTPS

Over the plain `http://100.x.y.z:7788` address everything above works in
the browser: pairing, all five tabs, live updates and the screenshot.
What needs the https address from `tailscale serve`:

- a home-screen app that works as its own offline-capable app (the
  service worker that keeps the shell available registers only on https);
  over http, Add to Home Screen still gives an icon that opens the page;
- notifications from the web app, when Awake gains web push. This build
  has none: phone notifications go through ntfy or Pushover (Settings >
  *Phone alerts*), which work alongside the phone app.

## Troubleshooting

- *Tailscale not found*: open Tailscale on the Mac and connect, then
  reopen Awake's Settings (it re-reads the addresses when the window
  becomes active, and once a minute while the phone app is on).
- *Could not listen on port 7788*: something else has the port. Change
  *Port* in Settings and, if you use it, rerun `tailscale serve --bg`
  with the new port.
- The phone says *not paired* after working before: its token was
  forgotten on the Mac, the browser's storage was cleared, or Awake was
  reinstalled. An unsigned (ad-hoc) install has a new identity each time,
  and the keychain does not let the new build read the record the old one
  saved; Settings then says the paired phones were saved by another build.
  Pair again; macOS may ask to allow Awake to replace the old item.
- The phone shows *offline*: check that Tailscale is connected on the
  phone and that Awake is running on the Mac.
