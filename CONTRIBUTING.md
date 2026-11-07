# Contributing

Awake is a native Swift macOS app. Build and run the Swift test suite on
macOS 26 with an Xcode toolchain that supports the package's Swift 6.2 tools
version. Pull requests should include regression tests for changed behavior
and pass the build, test, and shell-script checks.

CI runs on every pull request and push to main. The macOS job parses
`scripts/*.sh` with `/bin/bash -n` under the system bash 3.2 and greps them
for bash 4 builtins and expansions (`mapfile`, `declare -A`, `${x,,}`),
because the LaunchAgent, install.sh and uninstall.sh run under 3.2 and
ShellCheck on Linux does not catch those. It then runs `swift test` and
builds the release with `-Xswiftc -warnings-as-errors`, so a compiler
warning fails the build. Two Linux jobs run ShellCheck over `scripts/` and
`.github/scripts/` and actionlint plus zizmor over `.github/workflows`. The rules reviewers apply are in `.greptile/rules.md`.

The ShellCheck job, with the ShellCheck version it pins, also lists every
finding that a directive hides in `scripts/`, and fails unless the list
matches `.github/shellcheck-hidden.txt`. A directive covers the next
command, so a `{` added after an existing one and a `}` at the end would
put the rest of the script under it without touching the directive. If
your change hides something new on purpose, copy the list CI prints into
that file. The
check also fails if a `# shellcheck` stands outside a comment, in a
string, a here-document or backticks, since it could not then remove the
directives without changing how the script parses.

The tmux integration cases require tmux at one of the executable paths probed
by the app. CI installs it explicitly; when checking a local run, inspect the
skip count so missing tmux is not mistaken for integration coverage. Tests
use private servers, not a contributor's existing panes.

Use injected system dependencies and temporary journals for automated tests.
The test bundle links the AwakeTestHome target (Tests/AwakeTestHome),
whose constructor points `AWAKE_HOME` at a throwaway directory when the
bundle loads, before XCTest runs anything and whatever `--filter` is used,
so no test writes to the real ~/Library/Logs or ~/Library/Application
Support. TestIsolationTests fails if AWAKE_HOME is unset or missing, or
if any path the app resolves, such as the log a default-argument line goes
to, falls outside it or inside the real ~/Library.
Do not execute installation, uninstallation, power-setting changes, process
freezing, or hotspot switching against a contributor's working machine as part
of the test suite. Never embed credentials or personal SSIDs in fixtures or logs.

For lifecycle changes, test suspension at asynchronous boundaries, shutdown
during in-flight work, failed restoration, persistence failures, and recovery
after interruption. Assert observable settings and journal consistency, not
only that a mock method was called.

Review comments and passing CI provide review evidence, not a safety
certification. Real-machine validation requires a supervised, separately
approved run on a ventilated surface with recoverable work. Record the exact
revision, macOS/hardware versions, observed result, and remaining limitations
in the release validation record. New behavior that needs a real-Mac check
adds an item to the "Real-Mac checks before a release" list in
docs/releasing.md. Never stress or heat a machine in a bag. A pull request
that changes the app's behaviour also needs its own real-Mac report before
it merges; see "Real-Mac evidence" below.

The app icon is the menu bar's open eye on a charcoal tile.
[AppIconArtwork](Sources/Awake/UI/AppIconArtwork.swift) draws it from the
same [vector geometry](Sources/Awake/UI/EyeMarkGeometry.swift) as the menu
bar's closed eye, which opens while a session runs. After changing the
artwork, run `./scripts/generate-app-icon.sh`. It regenerates the packaged PNG
and ICNS assets and the README's SVG offline, with Xcode's swiftc and
iconutil.

## How a pull request merges

A pull request merges into main when CI passes at its head commit (the
Swift tests and release build on macOS, ShellCheck, actionlint and zizmor),
every review conversation is resolved, and the owner has approved it. Before
you build a new feature or change a default, open an issue so the owner can
say whether Awake should have it at all.

CI runs your code, so a test could make a check pass without doing its
work. The release build and the lid check run before the tests for that
reason, and review looks for tests and sources that skip, weaken or tamper
with checks.

### Pictures for changes you can see

A pull request that adds or changes anything a user sees, such as the menu
bar item, its menu or popover, Settings, an alert, a notification or the
app icon, needs pictures in its description, so the owner can tell what
changes before approving it:

- **Screenshots.** Before (main) and after (your head commit), cropped to
  the part that changed. Show light and dark appearance if they differ.
- **A video or GIF** for anything that moves or takes more than one step:
  an animation, a click or hold, a flow from start to end. Record it with
  Screenshot (Shift-Command-5) and drag the file into the description;
  GitHub uploads it.

Take them on your head commit, and replace them when a later push changes
what they show. Keep personal details out of them: Wi-Fi names, your user
name in paths, other apps' windows and notifications.

### Real-Mac evidence

A pull request that changes anything outside `docs/`, `Tests/`, `.github/`,
`.greptile/`, README.md, CONTRIBUTING.md, SECURITY.md, LICENSE and
.gitignore needs a report from your own Mac for its head commit. Post it as
a comment after your last push. If you push again, post a new one. For the
owner's own pull requests, the owner posts it.

- **Build.** A clean checkout of the head commit, with no other pull
  requests applied, installed with `./scripts/install.sh`. Post
  `git rev-parse HEAD` and `git status --short`, which should print nothing.
- **Mac.** Post `sw_vers`, `sysctl -n hw.model` and
  `sysctl -n machdep.cpu.brand_string`.
- **Checks.** Every item in "Real-Mac checks before a release" in
  [docs/releasing.md](docs/releasing.md) that your change can affect,
  including any item it adds. For each one, post the steps you ran with
  times, pass or fail, and the raw output that shows it:
  - the lines of `~/Library/Logs/Awake/awake.log` for that run;
  - pmset samples from a sampler you start before the check and leave
    running:
    ```sh
    while :; do date '+%T'; pmset -g | grep SleepDisabled; pmset -g custom | sed -n '/Battery Power/,/AC Power/p' | grep -E 'powermode|lowpowermode'; sleep 5; done | tee -a ~/awake-samples.txt
    ```
  - `pmset -g log | grep -E ' (Sleep|Wake|DarkWake) '` for that time
    window, which shows whether the Mac slept;
  - any other reading the item names.
- **Not run.** List anything you could not run, and why.

Put long logs in a gist and link it. Run the checks while you are with the
Mac, on a stable, ventilated surface, never in a bag, and with no unsaved
work open. The owner checks that the report covers the head and every
affected item before merging.
