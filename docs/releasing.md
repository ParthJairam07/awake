# Releasing

The single checklist for cutting an Awake release: tag → CI → cask →
announce. The Release workflow (`.github/workflows/release.yml`) does the
building, signing and publishing; this page says what it needs, what to do
around it, and how to verify the result.

In short:

1. [One-time setup](#one-time-setup): signing secrets, the update key, the
   Homebrew tap. A release works without any of them; each one adds
   something.
2. [Cut the release](#cutting-a-stable-release): test a manual run on a real
   Mac, push the tag `v<version>`, watch the run.
3. [Homebrew cask](#homebrew-cask): the workflow points the cask at the
   release; copy it to the tap if the token is not set.
4. [Announce](#announce).

## Channels

| | Stable | Nightly |
| --- | --- | --- |
| Made by | pushing a tag `v<version>` | the daily schedule (07:17 UTC), or a manual run with the nightly input, on `main` |
| Tag | `v<version>`, pushed by the maintainer | `nightly-<YYYYMMDD>-<first 12 hex digits of the commit>`, created by the workflow |
| Zip and disk image | `Awake-<version>.zip`, `Awake-<version>.dmg` | `Awake-<version>-nightly-<YYYYMMDD>-<commit>.zip` and `.dmg` |
| Version in the app | the tag's digits | `CFBundleShortVersionString` from `Resources/Info.plist` |
| Update feed (`appcast.xml`) | yes, when the update key is set | never |
| Homebrew cask updated | yes | no |
| Title | `Awake <version> (stable)` | `Awake nightly <YYYY-MM-DD> (<commit>)` |
| GitHub marks | Latest, not a prerelease | Pre-release, never Latest |
| Attestation source ref | `refs/tags/v<version>` | `refs/heads/main` |

Both channels run the same tests, build, signing, package, checksum and
attestation steps; they differ only in how the run starts, the names and the release
flags. Nobody chooses a nightly: it is whatever `main` held when the run
started.

`v0.1.0` is an exception to this table. It was packaged by hand from the
app installed on the maintainer's Mac and published as the first stable
release; no workflow built it. Its zip is `Awake-0.1.0-macos-arm64.zip`
with `scripts/install.sh`, `scripts/uninstall.sh` and `scripts/backstop.sh`
from the `v0.1.0` tag, it has no attestation, and its release notes give its
own checksum and install commands. Version 0.1.0 belongs to that release,
so the next stable release needs a higher version.

## One-time setup

All of these are repository secrets (Settings > Secrets and variables >
Actions). The workflow never fails because one is missing: it publishes what
it can and says in the run's annotations and in the release notes what kind
of build it made.

| Secret | What it adds | Without it |
| --- | --- | --- |
| `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD` | Developer ID signature with the hardened runtime | ad-hoc signed; notes say "Unsigned build: right-click → Open on first launch" |
| `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | notarization and stapling of the app and the disk image, checked with `spctl` | signed but not notarized; notes say so |
| `SPARKLE_PRIVATE_KEY` (plus the public key committed) | `appcast.xml`, so installed copies update themselves | no feed; the app's updater stays off |
| `HOMEBREW_TAP_TOKEN` | the cask committed to the tap repository | the cask is on the `homebrew` branch only; copy it by hand |

The repository has to be public for any of the install paths to work: the
curl installer, the cask, the update feed and the release downloads all
read from it without credentials.

### Developer ID certificate and notarization

Needs membership of the Apple Developer Program.

1. In Xcode (Settings > Accounts > Manage Certificates) or on
   developer.apple.com (Certificates, IDs & Profiles), create a **Developer
   ID Application** certificate. It lands in the login keychain.
2. In Keychain Access, select the certificate together with its private
   key, File > Export Items, format .p12, and set a password.
3. Store both:

   ```bash
   base64 -i DeveloperID.p12 | gh secret set APPLE_CERTIFICATE_P12 -R ParthJairam07/awake
   gh secret set APPLE_CERTIFICATE_PASSWORD -R ParthJairam07/awake   # paste the .p12 password
   ```

   Delete the .p12 afterwards.
4. For notarization, create an app-specific password at
   [account.apple.com](https://account.apple.com) (Sign-In and Security >
   App-Specific Passwords), and find the team id (ten characters) under
   Membership details on developer.apple.com:

   ```bash
   gh secret set APPLE_ID -R ParthJairam07/awake            # the Apple Account email
   gh secret set APPLE_TEAM_ID -R ParthJairam07/awake
   gh secret set APPLE_APP_PASSWORD -R ParthJairam07/awake  # the app-specific password
   ```

The workflow imports the certificate into a keychain that exists only for
the job (`.github/scripts/signing-keychain.sh`), signs with
`scripts/build-app.sh --sign-identity`, submits with
`xcrun notarytool submit --wait` and staples (`.github/scripts/notarize.sh`),
and then requires `spctl -a -vv` to accept the app.

The first time a signed build is installed over an unsigned one, macOS
treats it as a different app: grant Accessibility, Screen Recording and
Location again, and the recovery agent is reloaded with the new code
requirement by the app's next launch.

### Updates

Awake updates itself with [Sparkle](https://sparkle-project.org). The app
reads `https://github.com/ParthJairam07/awake/releases/latest/download/appcast.xml`
and accepts only an update signed with the EdDSA key whose public half is in
`scripts/sparkle-public-key.txt`. That file is empty today, so the updater
is off in every build. To turn it on, once:

1. Build once so SwiftPM unpacks Sparkle's tools, then make the key pair.
   The private key is stored in your login keychain; the command prints the
   public key:

   ```bash
   swift build
   .build/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

2. Put the printed public key, alone on one line, in
   `scripts/sparkle-public-key.txt` and commit it. `scripts/build-app.sh`
   writes it into the bundle as `SUPublicEDKey`.
3. Export the private key and store it as a secret, then delete the file:

   ```bash
   .build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key.txt
   gh secret set SPARKLE_PRIVATE_KEY -R ParthJairam07/awake < sparkle-private-key.txt
   rm -P sparkle-private-key.txt
   ```

   Keep the keychain item (or an offline copy): losing the private key
   means installed copies can never be updated again except by hand.

From the next stable release on, the workflow runs Sparkle's
`generate_appcast` (`.github/scripts/generate-appcast.sh`) and attaches
`appcast.xml`. It stops if the secret is not the pair of the committed
public key.

The updater runs only in a build that has the public key **and** a
Developer ID signature. An ad-hoc build cannot host Sparkle's installer
safely (nothing ties the update to the app's signer), so there "Check for
Updates…" explains that and offers the releases page; nothing is downloaded.
The first release that carries the key is therefore the first one that can
update itself: every earlier install has to be upgraded by hand once.
Updates are never checked or installed while a session runs.

### Homebrew tap

`Casks/awake.rb` in this repository is the cask. Homebrew installs from a
tap repository named `homebrew-awake`, created once:

```bash
gh repo create ParthJairam07/homebrew-awake --public --description "Homebrew tap for Awake"
git clone https://github.com/ParthJairam07/homebrew-awake.git
mkdir -p homebrew-awake/Casks
git -C awake show homebrew:Casks/awake.rb > homebrew-awake/Casks/awake.rb   # after the first release
git -C homebrew-awake add Casks/awake.rb
git -C homebrew-awake commit -m "awake <version>"
git -C homebrew-awake push
```

Users then run:

```bash
brew tap ParthJairam07/awake && brew install --cask awake
```

To let the workflow update the tap, create a fine-grained personal access
token limited to `ParthJairam07/homebrew-awake` with Contents: read and
write, and store it: `gh secret set HOMEBREW_TAP_TOKEN -R ParthJairam07/awake`.

## What a release contains

| File | What it is |
| --- | --- |
| `Awake-<version>.zip` | `Awake.app` at the top level (`ditto -c -k --keepParent`). The cask, the curl installer and Sparkle download this. |
| `Awake-<version>.dmg` | The same app with an Applications shortcut, for a drag install. |
| `install.sh`, `uninstall.sh` | The scripts from the released commit. |
| `SHA256SUMS` | SHA-256 of the four files above. |
| `appcast.xml` | The update feed, stable releases with the update key only. |

The zip and the disk image carry a GitHub build provenance attestation that
names the repository, the ref, the commit and the workflow run that
produced them.

The binary is arm64 only, because the build job runs on an Apple Silicon
runner and no universal build is made. A release therefore runs on Apple
Silicon Macs only: the release notes and the README say so, and
`install.sh --app` stops on a Mac where `sysctl -n hw.optional.arm64` does not
read 1.

The bundle is the one `scripts/build-app.sh` makes: the release binary,
`Resources/Info.plist` with the version written in (`--version`), the icon,
`Sparkle.framework` under `Contents/Frameworks`, and `backstop.sh` and
`install.sh` sealed under `Contents/Resources` before signing. `install.sh`
runs the same script for a source install, so a downloaded app and a
source-built app have the same layout. Their contents can still differ,
because a source build is ad-hoc signed and may use another checkout,
toolchain or architecture, or `AWAKE_LID_SIMULATION=1`. The workflow sets
`AWAKE_LID_SIMULATION` empty, so a release never carries the
`simulate-lid.sh` watcher.

`install.sh` and `uninstall.sh` never take scripts from the folder above
their own (`ReleaseWorkflowTests` checks the ones the Package step copies),
and they take sibling scripts only from a source checkout's `scripts/`
folder with `Package.swift` one level up. A download folder is not one, so
there `install.sh` needs `--app`, and `uninstall.sh` runs only the
`backstop.sh` sealed in the installed app, after verifying the app. A
`build-app.sh` or `backstop.sh` added to that folder is not run.

## Cutting a stable release

1. Pick the version: three numbers, higher than the last release. `0.1.0`
   is taken (see Channels). Nothing needs editing: the tag's digits are
   written into the bundle's `CFBundleShortVersionString` and
   `CFBundleVersion`. Update `Resources/Info.plist` too if you want nightlies
   and source builds to report the new version.
2. Test the commit before anything is published. Start a manual run on it
   (Actions, Release, Run workflow, with the nightly box left unticked),
   download the run's artifact, check it with
   `shasum -a 256 -c SHA256SUMS`, and install it with
   `bash install.sh --allow-unverified-origin --app ./Awake.app` on a Mac you
   can afford to reinstall on. Then run the
   [real-Mac checks](#real-mac-checks-before-a-release), all but the
   release channel ones, and record the results in
   `docs/release-validation.md`. Fix anything that fails and start again.
   The manual run signs and notarizes like a release when the secrets
   exist, so this is also where a new certificate is first tried.
3. Tag the tested commit `v<version>` and push the tag:

   ```bash
   git tag v0.2.0 <tested commit>
   git push origin v0.2.0
   ```

   The workflow refuses a tag that is not `v<major>.<minor>.<patch>`.
4. Watch the run. It runs `swift test`, builds and signs the bundle
   (Developer ID and notarized, or ad-hoc: see One-time setup), packages the
   zip and the disk image, writes the update feed when the key is set,
   attests, and creates the GitHub Release, marked Latest, with generated
   notes: what kind of build it is, the checksums, the verify commands and
   an Install section. `gh release create` fails if the tag already has a
   release, so a rerun never replaces published assets. Read the run's
   annotations: each missing secret leaves one.
5. Check the release the way a user would: download, verify (below), and
   install with each of the three commands in the notes on a Mac you can
   afford to reinstall on. For a notarized build, `spctl -a -vv
   ~/Applications/Awake.app` reads "accepted, source=Notarized Developer
   ID". This is the stable release channel check; record its result with the
   others.
6. Do the [Homebrew cask](#homebrew-cask) step, then [announce](#announce).

A manual run (Actions, Release, Run workflow) with the nightly box left
unticked builds and packages the chosen branch and uploads the zip, the
disk image, the scripts and `SHA256SUMS` as a workflow artifact. It does not
attest or publish anything, so it is the way to try the pipeline and to get
the build that step 2 tests. Every pull request also runs the
`release-dry-run` job in `ci.yml`, which builds and packages an ad-hoc
`0.0.0-ci` and uploads the zip, so packaging breakage shows before a tag.

## Homebrew cask

After a stable release is published, the workflow's `cask` job writes the
release's version and the zip's SHA-256 (from `SHA256SUMS`) into
`Casks/awake.rb` with `.github/scripts/update-cask.sh` and commits that one
file to the **`homebrew` branch** of this repository. It never writes to
`main`: a release does not change the code it was built from, and `main`
stays protected. The copy on `main` keeps placeholder values; the `homebrew`
branch always holds the cask for the latest stable release.

- With `HOMEBREW_TAP_TOKEN` set, the job also commits the file to
  `ParthJairam07/homebrew-awake`, and the step is done.
- Without it, copy the file yourself:

  ```bash
  git -C awake fetch origin homebrew
  git -C awake show origin/homebrew:Casks/awake.rb > homebrew-awake/Casks/awake.rb
  git -C homebrew-awake commit -am "awake <version>" && git -C homebrew-awake push
  ```

Then check it: `brew update && brew upgrade --cask awake` on a Mac with the
previous version, or `brew install --cask awake` on one without, and
`brew style --cask ParthJairam07/awake/awake`.

The cask installs to `~/Applications`, like `install.sh`, quits the app and
unloads the recovery agent on uninstall, and with `--zap` also removes the
sudoers rule, settings and logs. Homebrew does not run `install.sh`: the
sudoers rule is installed from the app's Setup window on first launch.

## Announce

1. Read the published notes once more; edit them on the release page if a
   line is wrong for this release.
2. Add the release's results to `docs/release-validation.md` and commit.
3. Update the README's "There is no Awake release yet" line after the first
   release, and the screenshots in `docs/assets/screenshots/` when the UI
   changed.
4. Post where the users are, with the release link, the one-line install
   command and whether the build is notarized.

## Nightly prereleases

The schedule runs the workflow on `main` once a day. A first job, with
read-only access, lists the repository's `nightly-*` tags and releases:

- If a nightly tag already names the head of `main` and has a release,
  nothing is built. A day without new commits publishes nothing.
- If such a tag exists without a release, the run fails and builds nothing,
  until `main` moves on. That happens only when an earlier run created the
  tag and then failed to create the release: rerun that run's failed jobs
  (the nightly job finds its own tag on the same commit and goes on), or
  delete the tag.
- If a nightly tag with this commit's first 12 hex digits points at another
  commit, the run fails.
- Otherwise it picks the tag `nightly-<today, UTC>-<commit>` and the run
  goes on to test, build and package that commit.

The publishing job creates the tag through the API call that fails when the
ref exists, so it never moves a tag, then creates the release with
`--prerelease --latest=false`. Scheduled and manual runs on `main` share one
concurrency group, so two runs never publish the same commit at once.

To publish a nightly now, start a manual run on `main` with the nightly box
ticked. The same checks apply, and a run on any other branch fails before
it builds.

GitHub disables scheduled workflows in a public repository after 60 days
without repository activity; the Release workflow then has to be enabled
again under Actions. The tags are not protected by a repository rule, so
someone with write access could still move or delete one by hand.

## Signing

A release is signed one of three ways, chosen by which secrets exist (see
[One-time setup](#one-time-setup)), and its notes open with which:

- **Notarized**: Developer ID signature, hardened runtime,
  `scripts/entitlements.plist` (one entitlement: Location, which macOS
  requires for reading Wi-Fi names; no sandbox), notarized and stapled.
  Opens like any downloaded app.
- **Developer ID, not notarized**: when the notary secrets are missing.
  macOS blocks the first launch.
- **Unsigned (ad-hoc)**: when the certificate is missing. `build-app.sh`
  signs with `codesign --sign -`, so the signature identifies only that
  build (its cdhash). The notes read "Unsigned build: right-click → Open on
  first launch"; on current macOS the user may have to allow it once in
  System Settings > Privacy & Security instead. The curl installer offers to
  remove the quarantine flag for such a build, after asking.

Nightlies are signed the same way as stable releases. The stable label is
about the channel, not the signature.

## Verifying a download

```bash
shasum -a 256 -c SHA256SUMS --ignore-missing
gh attestation verify <zip> -R ParthJairam07/awake \
  --signer-workflow ParthJairam07/awake/.github/workflows/release.yml \
  --source-ref <ref> --source-digest <commit>
```

`<ref>` is `refs/tags/v<version>` for a stable release and `refs/heads/main`
for a nightly; `<commit>` is the full commit the release was built from. The
release notes carry the command filled in.

The first line checks each downloaded file against the checksum published
with it (`--ignore-missing` skips the ones you did not download). The
second asks GitHub for the attestation signed when the workflow ran and
checks that this zip is its subject, that the signing workflow is this
repository's `release.yml` (`--signer-workflow`; with `-R` alone any workflow
of the repository would do), that it ran for that ref (`--source-ref`), so a
nightly built from `main` does not pass for a stable tag, and that it built
that commit (`--source-digest`). Together they show the bytes are what the
Release workflow built from that commit. They do not show the code is safe;
the README's warnings apply to every build. `v0.1.0` has no attestation; only
the checksum in its release notes covers it.

The `install.sh --app` attached to a workflow-built release then copies the bundle into
a private temporary directory and checks that copy before the password
prompt: it runs
`codesign --verify --strict --deep` and checks the bundle identifier and
version. It installs that copy, not the path it was given, so a bundle
replaced at that path while the prompt waits is never installed. The copy it
puts in `~/Applications` is checked once more against the requirement the
recovery agent pins.

What is verified: the checksum shows the zip was not altered after
`SHA256SUMS` was written; the attestation shows this repository's Release
workflow built this exact zip from that ref and commit; `install.sh --app`
shows the bundle inside is intact (signature and resource seal), has the
expected identifier and a version, and carries the sealed backstop. What is
not: `install.sh` cannot tell a bundle from this repository apart from one
anyone else signed with the same identifier, and it does not take any
signature, ad-hoc or not, as proof of where a bundle came from. So it
refuses to install without `--allow-unverified-origin`, the flag that says
you ran the two commands above yourself. The release notes carry that flag
in the install command.

## What is not automated

The workflow does not install anything anywhere. The real-Mac checks below
are run by hand after a real install, and their results go in
`docs/release-validation.md`. Nothing checks a nightly beyond the workflow's
`swift test`.

## Real-Mac checks before a release

Run these on a real Mac before each stable release, on a workflow build of
the commit the release will be tagged on (step 2 of
[Cutting a stable release](#cutting-a-stable-release)), and record the
results in `docs/release-validation.md` with the commit, the Mac, the macOS
version and the date. A passing `swift test`, a source review or a green CI
run is not a result.

Two kinds of check are exceptions. A release build leaves out the
`simulate-lid.sh` watcher, so run the simulated lid close/open check on a
source build of the same commit installed with
`AWAKE_LID_SIMULATION=1 ./scripts/install.sh`, and record that build
setting with its result. The release channel checks need a published
release, so the stable one runs at step 5, after the tag push, and the
nightly one after a nightly run publishes.

Run them under supervision and never at the cost of active work. Use a
stable, ventilated surface, not an enclosure. Do not overheat a Mac on
purpose to check thermal handling; try injected thermal events first.

`swift test` covers the same paths with fakes. Launchd sequencing uses a
fake command runner. PackagingTests run the agent's verify-then-exec command
line against a scratch ad-hoc bundle with the real codesign: an intact
bundle runs its sealed script, and an edited script or another build's
requirement is refused and logged. Installer tests redirect every app,
LaunchAgent, sudoers and command target into a temporary folder. The checks
below cover what only a real Mac shows.

### Sessions and recovery

- Normal end, deadline expiry, and repeated Quit restore live power state
- Sleep guard read back: on a Mac where another process sets SleepDisabled back to 0 about 2 s after `pmset -a disablesleep 1` (for example a root LaunchDaemon that loops `pmset -a disablesleep 0`), Start fails after about 5 s with "SleepDisabled read 0 again" and no session runs; on a Mac where the bit holds, the session starts about 5 s after Start and `pmset -g` reads SleepDisabled 1
- Force-quit followed by launchd deadline recovery and retry after failure
- The recovery agent between sessions (no session.json, the clean journal a finished session leaves): `launchctl print gui/$(id -u)/com.awake.backstop` counts a run each minute with last exit code 0, the backstop writes nothing to awake.log and state.json is unchanged; a force-quit in the next session is still recovered at the deadline
- Unreadable session.json moved aside by the app at launch and by the agent, then uninstall with and without --purge
- session.json without read permission during a session: the agent restores sleep within a minute and renames the file to `session.json.unreadable-<time>`, or the app does both at launch and notifies; after fixing the copy's permissions, a relaunch does not resume the session
- Reboot/login with active or dirty journals
- Backstop resuming a frozen test process through the installed `Awake --resume-frozen`, and keeping the entry when the bundle is removed or its Info.plist lacks `AwakeResumeFrozenVersion`
- Existing Low Power Mode preference and saved audio restoration
- Low Power Mode on macOS 27, where `pmset -g custom` prints `powermode` and no `lowpowermode` (a session on battery with the lid closed and "Low Power Mode while the lid is closed" on, or below the Low Power floor): the log has no "could not read low power mode" line, `pmset -g custom` shows `powermode 1` under Battery Power while the mode is on, and the session end leaves it at `0`; with High Power set beforehand (`powermode 2` under Battery Power), the read is refused, the log says so, and `powermode 2` is still set after the session
- App Nap opt-in: previous `NSAppSleepDisabled` put back at session end, by the backstop after a force-quit, and by uninstall
- App Nap on macOS 27, where `defaults read` of a missing key prints "Could not find key 'NSAppSleepDisabled' in domain '<id>'." or "Domain '<id>' not found.": an `appNapOverrides` entry whose key is already gone (deleted by hand after a force-quit) is cleared by the agent with "the key is already absent" and the run exits 0, and uninstall counts agent apps without the key as checked, not unreadable; with a sandboxed agent app on the list (one with `~/Library/Containers/<id>`), its container's preferences have no `NSAppSleepDisabled` left after the agent clears its entry
- Battery/thermal event behavior on supported hardware
- A `sudo pmset` that ignores SIGTERM: left running, lock held, journal intact, quit refused until it exits
- The same command with the app force-quit: the backstop does not take the lock until the command exits; the relaunch names the pid from `unfinished-command.json`, and at its next retry after the command exits (retries start 30 s after each refusal) resumes the session with its battery floors
- A left-running `disablesleep 0` that exits 0: the end finishes without running it again
- After that command exits: Low Power Mode ownership matches the mode, and a lid open made meanwhile is undone
- `SleepDisabled 1` set by hand with no session: left alone and reported at launch, not cleared
- Unreadable battery (IOKit miss) ends the session on a laptop after the second read; desktop unaffected
- Settings floor steppers keep the end floor below the Low Power Mode floor by moving the other stepper
- First launch over an existing install tightens Application Support/Awake and Logs/Awake to 0700 and their files to 0600

### Menu bar

- A session with the lid open holds the app near idle: start a session, wait
  10 s, then sample `ps -o %cpu= -p <pid>` every 0.5 s for 20 s. The mean
  stays under about 5%, and the countdown still changes every second. It read
  about 46% before the countdown stopped animating its digits

### Lid close

- Lid-close/open and safe recovery of explicitly selected test processes
- Freeze-all scope with agents running (Cursor/T3 Code/Claude untouched)
- Freeze-all off on a fresh config.json (list only) and on with a terminal, a non-Chrome browser and a JetBrains IDE open (all untouched)
- Real lid close with freeze-all on during a Zoom or Teams call on AirPods, with Wispr Flow or Granola taking notes: none of their processes stopped (`ps -o stat` shows no `T`), the call and the notes continue, other Dock apps frozen, sound muted
- Upgrade notice: install over a build whose config.json has `freezeAllApps: true` and `muteOnLidClose: false`; the first launch posts one "Lid-close settings changed" notification and shows the same line in Settings (also with notifications off for Awake), both settings change and config.json gets `lidCloseDefaultsApplied: true`; a setting turned back stays back after a relaunch with no second notice; Dismiss removes the line; a fresh install shows no notice
- Mute with a changing output: close the lid on AirPods, put them in the case so the speakers take over, open the lid; the speakers keep their volume and mute and the AirPods are unmuted when reconnected. Close the lid again on the speakers while the AirPods are still away: the speakers are muted too, and the next lid open restores them
- Output away at session end: close the lid on AirPods, put them in the case, choose End; sleep is restored, the notification and the menu say the AirPods are still muted. Take them out with Awake running: their volume comes back and the menu line goes. Again with Quit instead of End, then launch Awake with the AirPods connected: restored at launch. "Stop waiting for AirPods" drops the entry and leaves them muted; uninstall stops while one is waiting
- Backstop and uninstall over saved audio of an output device renamed to `Headset \u0041` (a Bluetooth headset renamed in Bluetooth settings, the lid closed on it with muting on, then the app quit with `kill -9` and the session left to expire): the backstop log has no "malformed" and shows "pmset -a disablesleep 0 ok", state.json keeps the headset's entry, and the next launch with the headset connected restores its volume and mute
- Lid close with a freeze-list app stopped beforehand by `kill -STOP` (left stopped on lid open, not in the journal)
- Lid close during a session after `chflags uchg` on state.json (mode 0444 is not enough: the app writes a new file and renames it over state.json, and rename needs write access only to the folder): no process stopped, every app logged as left running; `chflags nouchg` before lid open
- Simulated lid close/open via scripts/simulate-lid.sh on a build installed with `AWAKE_LID_SIMULATION=1 ./scripts/install.sh` (the launch log, status menu and Settings show "Lid simulation build")
- A normal install (no `AWAKE_LID_SIMULATION`) ignores scripts/simulate-lid.sh during a session: no log line, no lid actions, trigger file left in place; no "Lid simulation build" marker anywhere
- Docker Desktop idle/busy behavior with another Docker context selected
- Docker rule off on a fresh config.json (no `docker ps`, Docker untouched) and on with a container started between the two idle checks (Docker untouched, both checks logged with their answers)
- Docker rule on, lid opened while an idle check is still running (Docker never paused, the display and frozen apps restored without waiting for `docker ps`, awake.log says the lid opened during that check), and a session started with the lid already closed (no countdown redraw until the lid opens)
- tmux cancellation with a dedicated disposable pane
- tmux nudge on the user's own tmux server: marked pane gets `continue` only, Enter toggle submits it, unmarked pane untouched
- Headed-browser throttling with the lid closed
- Relaunch unthrottled: confirmation alert, profile arguments carried over, a browser that has not quit after 10 s is left as it is and the notification names it, a browser not running 5 s after `open` is reported
- Relaunch failure while Awake is frontmost: with notifications allowed, the "Browser not relaunched" banner shows without switching apps after the confirmation; with notifications off for Awake, the reason is a warning line in the right-click menu
- Comet (`ai.perplexity.comet`): with freeze-all on and Comet running but not on the freeze list, a lid close leaves it untouched; "Relaunch Comet unthrottled" carries its profile arguments over, and the headed-browser throttling check above passes in Comet after it

### Display and keyboard backlight

- Lid-close display/keyboard darkening and restore
- Darkening still runs under the private-call guards on macOS 26 (close the lid during a session: the log shows "display darkened" and "keyboard backlight off" and no "refused" line; Settings shows no note under the darken toggle)
- Darkening refused on an unmeasured macOS version (a macOS major other than 26 or 27, or a `KeyboardBrightnessClient` whose methods changed: the log shows the "refused" line once and "skipped" at lid close, nothing is journaled for that device, and Settings names the reason under the darken toggle; with both refused the log shows "display sleep not requested" and the panel is lit when the lid opens; a level saved by the earlier build stays in state.json with `displayRestoreRefused` or `keyboardRestoreRefused` after the first open or launch, the menu says it could not be restored on this macOS build and names each saved level, Settings shows the saved level under the darken toggle, no "Restore incomplete" follows, and the backstop log does not fail for it)
- A kept brightness on a build that can make the call (after a refused restore, set the keyboard backlight by hand, put the display to sleep, then launch that build and wake the display): the log shows "not read: macOS has the backlight suppressed or dimmed" and then "set since its restore", and the backlight stays at the level set
- A kept keyboard backlight when a session ends with the lid closed, on a build that can make the call: the log shows "the lid is not known to be open, so the kept value is not read", and about a minute or less after the lid opens, with no session, "set since its restore" or "keyboard backlight restored"
- A kept brightness at a launch with no session and the lid closed (an external display in clamshell mode, after a refused restore), on a build that can make the call: the log shows "not read: the lid is not known to be open" for each kept device and nothing is written, and once the lid opens "set since its restore" or "restored"
- A kept display brightness restored late during a session (launch with the display asleep after a refused restore, wake it, start a session at once, wait for "display restored", then close and open the lid within 30 s): the close logs "display darkened (was brightness" with the restored level, and the open brings the panel back at that level, not black
- A kept display brightness under Awake's own Low Power Mode, on a build that can make the call (after a refused restore, set the display by hand, start a session on battery below the floor so Awake switches the mode on, then open the lid): the log shows "under our low power mode, which rescales it" and nothing is written; once the mode is off, "after our low power mode was or may have been on in this run" and nothing is written, and a close logs "stays journaled and undecided, and the display is not darkened" and the panel goes dark only if the display sleep request is honored; after a relaunch with the lid open, "since the Mac last started" and nothing is written; after a restart, "set since its restore" with the level set by hand, and a close and open after that bring back that level
- A kept display brightness over a restart with Awake's Low Power Mode claimed (as in the row above, quit the app with `kill -9` while the mode is on, restart the Mac, set the display by hand, then launch on battery): the log shows "journaled as ours before the Mac last started, reads on" or "reads off; it may have gone off only a moment ago"; either way nothing is written and the display is not darkened at a close until the next restart, and after it "set since its restore" with the level set by hand. After an open under the mode read the panel above 0, set the display to 0 by hand, relaunch and then restart: the kept value never comes back over that 0, after the restart the log shows "only a reading above 0 tells them apart" and the entry stays in state.json, and once the display is raised above 0 by hand, "set since its restore" with that level
- A kept display brightness when the recovery agent switches Awake's Low Power Mode off after a restart (as in the row above, quit with `kill -9` while the mode is on, restart the Mac, and wait for "pmset -b lowpowermode 0 ok" in the backstop log before launching on battery): the backstop log shows "kept display entry's record given this boot" before "pmset -b lowpowermode 0 ok", state.json's `keptDisplayUnderLowPowerBoot` is this boot's `kern.bootsessionuuid`, the launch logs "since the Mac last started" and writes nothing, and after the next restart "set since its restore"
- Quit while a reading above 0 of the kept display entry is not yet in state.json (as in the restart row above, `chflags uchg` state.json before the launch after the restart that reads the panel above 0, then Quit): the menu says "do not quit until state.json can be written" and Awake keeps running; after `chflags nouchg`, Quit within the next retry quits, and state.json has `keptDisplayReadLit`
- The recovery agent when state.json refuses writes over a kept display entry (as in the agent row above, `chflags uchg` state.json in the new boot before the agent runs): the backstop log shows "Low Power Mode left on, keeping journal entry for retry", `pmset -g` still shows lowpowermode 1, and sleep is restored; after `chflags nouchg`, the next run logs "record given this boot" and then "pmset -b lowpowermode 0 ok"
- Quit while the clear of a settled kept display brightness is not yet in state.json (after a refused restore, set the display by hand above 0, `chflags uchg` state.json, launch with no session so the log shows "set since its restore", set the display to 0 by hand, then Quit): the notification says "do not quit until state.json can be written", Awake keeps running and Start is refused; after `chflags nouchg`, the next retry clears the entry from state.json, Quit quits, and a relaunch leaves the display at 0
- A kept display brightness read above 0 that a close under the closing lid reads at 0 (as in the row above, after the launch that leaves the entry waiting, keep the display asleep until the session starts, wake it with auto-brightness on, then close the lid in a dark room before the next re-read): the close logs "where auto-brightness under the closing lid may have pulled it down" and "stays journaled and undecided", nothing is written at the close or the open, and while the panel reads 0 the open and every re-read log "only a reading above 0 tells them apart" and the entry stays in state.json; once the panel reads above 0, "set since its restore" with that level, and the kept value is never written
- The same entry across a relaunch (as in the row above, quit Awake after the close with the lid still closed, open the lid, and relaunch Awake while the panel still reads 0): the launch logs "only a reading above 0 tells them apart" while the panel reads 0, nothing is written, and once the panel reads above 0, "set since its restore" with that level
- Backstop and uninstall with a hand-edited state.json whose `keptDisplayReadLit` is `1e-400` (a copy of a journal from the restart row above, in a test home): the backstop logs "is unreadable or malformed; nothing undone, evidence kept", uninstall prints "state.json is unreadable or malformed" and removes nothing, and state.json is unchanged

### Hotspot

- Hotspot permission, association, cancellation, and reconnect
- Hotspot password after a reinstall: menu and Settings report it unreadable, no prompt during an outage, re-save replaces the item (prompt on Save allowed)
- Settings location note matches what System Settings shows after the grant

### Install, upgrade and uninstall

- Install/upgrade/uninstall with recoverable failure conditions
- Settings > App shows the version from the installed bundle's Info.plist, and the launch line in awake.log carries the same; "Check for updates" names the newest stable and nightly tags as the releases page shows them and says whether the installed version is behind, and with Wi-Fi off it shows "Could not check" with the reason, the log has the failure line, and nothing else changes
- Recovery agent refuses to run after the installed bundle or its sealed backstop.sh is modified, and logs why
- Running app refuses to arm (session start refused, reason shown) after its installed bundle is edited or re-signed under it
- Upgrade whose new agent fails to load puts the previous bundle back and reloads the previous agent, on a working Mac
- Upgrade whose new agent plist cannot be saved, and a rerun after an install killed mid-swap, leave the app and the agent's plist matching, on a working Mac
- Upgrade whose bundle rename is refused (the new build cannot be moved in, or the previous app cannot be moved back) puts the previous app back and reloads its agent, or keeps both bundles and prints the commands, on a working Mac
- Install whose `sudo -n -l` check or `launchctl` call stalls while it holds the recovery lock (for example a directory-service lookup that does not answer) stops after 30 s and releases the lock, and the agent's next run can take it, on a working Mac
- Install from a release zip with `install.sh --allow-unverified-origin --app` on a working Mac, first launch of the downloaded app
- Installed bundle from a release zip has no group or other write bit and no ACL (`ls -leR ~/Applications/Awake.app`), keeps its quarantine flag (`xattr -p com.apple.quarantine`) and passes `codesign --verify --strict --deep`, on a working Mac
- `uninstall.sh` run from a release zip unpacked in `/tmp` runs the installed app's sealed `backstop.sh` after `codesign --verify`, on a working Mac
- `install.sh` and `uninstall.sh` from a release zip unpacked in `/tmp`, with a `build-app.sh` and a `backstop.sh` added to the unpacked folder, run neither (install without `--app` stops, uninstall runs the sealed copy), on a working Mac
- `install.sh --app` from a release zip stops with the Apple Silicon message on an Intel Mac, and installs on an Apple Silicon Mac from a Terminal running under Rosetta
- Install or uninstall whose own process is killed (`kill -9 <pid>`) during a `launchctl bootout` keeps the recovery lock until that bootout has ended or been stopped, about 33 s at most, and the app started afterwards keeps its agent loaded, on a working Mac
- The installed recovery agent on the supported macOS release: launchd bootstraps its plist, loads it at login and runs its verify-then-exec command line, and the agent recovers a session after the app crashes
- The installed agent's plist is the one install.sh wrote
- A source install end to end: `./scripts/install.sh` builds, signs and installs the app with the administrator password, and stops while a running app refuses to quit
- Install and uninstall with Kong's Insomnia API client open: `codesign --verify -R='anchor apple generic and identifier "com.insomnia.app" and certificate leaf[subject.OU] = "FX44YY62GV"' <pid>` exits 0 for the client and 3 for this app; each script prints "Ignoring pid <pid>: it is Kong's Insomnia API client (com.insomnia.app, team FX44YY62GV), not this app." once, leaves the client running and goes on; with this app running too, each still asks it to quit and stops while it refuses, on a working Mac

### Release channels

- Release workflow end to end: tag push, tests, package, attestation, GitHub Release, `gh attestation verify` of the download
- The release's signing matches its notes: for a notarized build `spctl -a -vv` accepts the installed app and the mounted disk image's app, `xcrun stapler validate` passes on both, and a downloaded copy opens with no Gatekeeper prompt beyond the "downloaded from the internet" one; for an unsigned build the notes open with the unsigned line and the first launch needs right-click → Open or Privacy & Security
- Each install path on a clean account: `brew tap ParthJairam07/awake && brew install --cask awake`, the disk image dragged to Applications, and the curl one-liner; each ends with the app launching and the Setup window showing
- `brew uninstall --zap --cask awake` quits the app, unloads the recovery agent and removes the sudoers rule, settings and logs
- Update from the previous release with "Check for Updates…" (Developer ID build with the update key): the new version is offered, installs, relaunches, and the recovery agent is reloaded for the new bundle; with a session running the check is refused with the reason
- "Check for Updates…" in an unsigned build explains why it cannot update and opens the releases page; nothing is downloaded

### Setup window

- First launch after a clean install shows Setup once; closing it or finishing it does not show it again; "Setup…" in the right-click menu reopens it
- Notifications step: "Allow notifications" raises the macOS prompt and the status follows the answer
- Sudoers step: "Run in Terminal" opens Terminal with the bundled `install.sh --sudoers-only`, which asks for the password in Terminal; after it finishes "Check again" reads installed and a session can start
- Accessibility and Screen Recording buttons open the right System Settings panes and the status follows a grant without reopening the window
- Phone alerts step: a topic typed there is the one in Settings > Phone alerts, and "Send test" arrives on the phone
- Tailscale step reads installed with Tailscale.app present and not installed without
- Launch at login toggle on the last step matches Settings > App
- Nightly channel end to end: scheduled run on `main`, tag `nightly-<date>-<commit>` created by the workflow, prerelease not marked Latest, `gh attestation verify --source-ref refs/heads/main --source-digest <commit>` of the download, and a second run on the same commit skipped before building

### Launch at login

- Launch at login survives a reinstall by install.sh, including a second install.sh run on the same unchanged build (switch on, reinstall, relaunch: the log shows the launch-time check, System Settings > General > Login Items lists Awake as enabled, and the Settings switch reads on; a pending approval shows the note and the Open Login Items button)
- Launch at login heals on the first upgrade from a build without the install record (switch on in the previous build, upgrade with install.sh, relaunch: the log shows "registering once and recording the install", Login Items lists Awake, and config.json has `launchAtLoginInstall`)
- Launch at login removed in System Settings stays removed (switch on, relaunch once so the install is on file, remove Awake under System Settings > General > Login Items, relaunch: the log says the removal was respected, the Settings switch is off, and Login Items does not list Awake again)
- Pending approval withdrawn from Settings (switch on while macOS reports it waiting for approval, turn the switch off: Login Items no longer lists Awake and the next launch does not register it)
- Approval given in System Settings shows in an open Settings window (turn the switch on, approve under Login Items, click back into the Settings window: the pending note goes away without reopening the window)
