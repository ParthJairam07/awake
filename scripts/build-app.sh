#!/bin/bash
# Build Awake and assemble a signed Awake.app. install.sh runs this for
# source installs, and .github/workflows/release.yml runs it for the
# downloadable package, so both produce the same bundle.
#
# Usage: scripts/build-app.sh --output DIR [--version X.Y.Z[-suffix]]
#                             [--sign-identity IDENTITY]
#   Writes DIR/Awake.app, replacing a bundle already at that path. DIR is
#   created if needed. Prints the bundle path last.
#
#   --version        written into the bundle's Info.plist as
#                    CFBundleShortVersionString and CFBundleVersion. The
#                    Release workflow passes the tag's digits; without the
#                    flag the bundle keeps what Resources/Info.plist says.
#   --sign-identity  a Developer ID Application identity in the keychain
#                    search list (its name or SHA-1 hash). The bundle is then
#                    signed with the hardened runtime, a secure timestamp and
#                    scripts/entitlements.plist, which is what notarization
#                    needs. Only the flag selects this; nothing is read from
#                    the environment.
#
# Without --sign-identity the signature is ad-hoc (`codesign --sign -`). It
# identifies only this build (its cdhash), and macOS blocks the first launch
# of a downloaded copy until the user allows it. There is no --deep: nested
# code, when the build has any, is signed on its own before the bundle, and
# backstop.sh under Contents/Resources is sealed as a resource.
set -euo pipefail

# Fixed tool paths: never taken from PATH. Tests patch these lines in a
# private copy of the script.
SWIFT=/usr/bin/swift
CODESIGN=/usr/bin/codesign
PLUTIL=/usr/bin/plutil
PLISTBUDDY=/usr/libexec/PlistBuddy
OTOOL=/usr/bin/otool
DITTO=/usr/bin/ditto
RM=/bin/rm
MKDIR=/bin/mkdir
CP=/bin/cp
CHMOD=/bin/chmod

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { echo "usage: $0 --output DIR [--version X.Y.Z[-suffix]] [--sign-identity IDENTITY]" >&2; }
OUTPUT=""
VERSION=""
SIGN_IDENTITY=""
while (( $# )); do
  case "$1" in
    --output) [[ $# -ge 2 ]] || { usage; exit 2; }; OUTPUT="$2"; shift 2 ;;
    --version) [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }; VERSION="$2"; shift 2 ;;
    --sign-identity) [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }; SIGN_IDENTITY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$OUTPUT" ]] || { usage; exit 2; }
# Checked before anything is built: three numbers, and optionally a suffix of
# letters, digits, dots and hyphens (0.0.0-ci). It goes into a plist and into
# file names, so nothing else is accepted.
if [[ -n "$VERSION" && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "--version '$VERSION' is not X.Y.Z or X.Y.Z-suffix" >&2
  usage
  exit 2
fi
ENTITLEMENTS="$ROOT/scripts/entitlements.plist"
if [[ -n "$SIGN_IDENTITY" && ! -f "$ENTITLEMENTS" ]]; then
  echo "--sign-identity needs $ENTITLEMENTS, which is missing" >&2
  exit 1
fi
# Resolved now, before the build changes into the checkout: a relative
# --output means relative to the caller's directory, not to the checkout.
"$MKDIR" -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"

step() { printf '\n==> %s\n' "$*"; }

# The Swift that wrote a .swiftinterface, from its first header line.
interface_compiler() {
  local line
  line="$(grep -m 1 '^// swift-compiler-version: ' "$1" 2>/dev/null)" || return 0
  printf '%s\n' "${line#// swift-compiler-version: }"
}

# SwiftPM's PackageDescription and PackagePlugin interfaces that an older
# Swift wrote, one path per line: a .private.swiftinterface whose writer is
# not the writer of the .swiftinterface beside it. An update of the Command
# Line Tools or Xcode that does not delete files its new version no longer
# ships leaves them there, and the compiler reads a .private.swiftinterface
# first, so Package.swift is compiled against the old API. Looked up only
# after a failed build, in the toolchain this script's swift reports.
stale_package_interfaces() {
  local resources f
  resources="$("$SWIFT" -print-target-info 2>/dev/null | sed -n 's|^ *"runtimeResourcePath": "\(.*\)",*$|\1|p')" || return 0
  [[ -n "$resources" ]] || return 0
  for f in "$resources"/pm/*/*.swiftmodule/*.private.swiftinterface; do
    [[ -f "$f" && -f "${f%.private.swiftinterface}.swiftinterface" ]] || continue
    if [[ "$(interface_compiler "$f")" != "$(interface_compiler "${f%.private.swiftinterface}.swiftinterface")" ]]; then
      printf '%s\n' "$f"
    fi
  done
}

# 1. Build -------------------------------------------------------------------
step "Building (release)"
cd "$ROOT"
# AWAKE_LID_SIMULATION=1 compiles the scripts/simulate-lid.sh file trigger
# (LidSimulation.swift) into this release build, for release validation on
# a machine whose lid stays open (install.sh passes it through from its own
# environment). A normal build has no watcher: nothing reads the trigger
# file. Such a build says so in the log at launch, in the status menu and in
# Settings. The release workflow never sets it.
BUILD_FLAGS=()
if [[ "${AWAKE_LID_SIMULATION:-}" == 1 ]]; then
  BUILD_FLAGS+=(-Xswiftc -DAWAKE_LID_SIMULATION)
  echo "lid simulation compiled in (AWAKE_LID_SIMULATION=1): scripts/simulate-lid.sh will drive the lid actions during sessions"
fi
# ${arr[@]+"${arr[@]}"}: an empty array expands to nothing under set -u on
# the bash 3.2 that ships with macOS.
build_rc=0
"$SWIFT" build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} || build_rc=$?
if (( build_rc != 0 )); then
  stale="$(stale_package_interfaces)"
  if [[ -n "$stale" ]]; then
    listed="" remove=""
    while IFS= read -r f; do
      listed+="  $f"$'\n'"    written by $(interface_compiler "$f")"$'\n'
      remove+=" $(printf '%q' "$f")"
    done <<< "$stale"
    cat >&2 <<STALE

The build failed. The Swift toolchain it used also holds package interfaces
written by an older Swift than the ones beside them:
$listed
Swift reads a .private.swiftinterface before the .swiftinterface beside it, so
Package.swift is compiled against that older PackageDescription. An error above
such as "reference to member 'v26' cannot be resolved" or "has no member
'swiftLanguageMode'" comes from them. An update of the Command Line Tools or
Xcode that did not delete the previous version's files leaves them behind.
Delete them (or reinstall the Command Line Tools or Xcode), then rerun:
  sudo rm$remove
STALE
  fi
  exit "$build_rc"
fi
BIN="$("$SWIFT" build -c release ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --show-bin-path)/Awake"
[[ -x "$BIN" ]] || { echo "binary not found at $BIN" >&2; exit 1; }

# 2. Bundle ------------------------------------------------------------------
APP="$OUTPUT/Awake.app"
step "Assembling $APP"
"$RM" -rf "$APP"
"$MKDIR" -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"$CP" "$BIN" "$APP/Contents/MacOS/Awake"
"$CP" "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
"$CP" "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# backstop.sh goes into the bundle before it is signed, so the signature's
# resource seal covers it. The LaunchAgent install.sh writes verifies the
# bundle and only then runs this copy; an edited script fails that check.
"$CP" "$ROOT/scripts/backstop.sh" "$APP/Contents/Resources/backstop.sh"
"$CHMOD" 755 "$APP/Contents/Resources/backstop.sh"
# install.sh too, sealed the same way, so the app's Setup window can hand
# Terminal a script this build's signature covers (install.sh --sudoers-only).
"$CP" "$ROOT/scripts/install.sh" "$APP/Contents/Resources/install.sh"
"$CHMOD" 755 "$APP/Contents/Resources/install.sh"
# Sparkle.framework (auto-updates). SwiftPM leaves the binary framework
# beside the executable; the app looks for it in Contents/Frameworks (the
# @executable_path/../Frameworks rpath in Package.swift). ditto keeps the
# framework's symlinks. A binary that links it but has no framework to
# carry would not launch, so that stops the build.
SPARKLE=""
if "$OTOOL" -L "$BIN" | grep -q '@rpath/Sparkle\.framework/'; then
  if [[ ! -d "$(dirname "$BIN")/Sparkle.framework" ]]; then
    echo "$BIN links Sparkle.framework, but it is not beside the binary" >&2
    exit 1
  fi
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  "$MKDIR" -p "$APP/Contents/Frameworks"
  "$DITTO" "$(dirname "$BIN")/Sparkle.framework" "$SPARKLE"
fi
# The key Sparkle checks a downloaded update against: the public half of the
# EdDSA pair whose private half signs the appcast in the Release workflow
# (docs/releasing.md). An empty or missing file means no key: the app then
# never starts Sparkle (UpdaterAvailability) and says so in its log.
KEY_FILE="$ROOT/scripts/sparkle-public-key.txt"
UPDATE_KEY=""
if [[ -f "$KEY_FILE" ]]; then
  UPDATE_KEY="$(tr -d '[:space:]' < "$KEY_FILE")"
fi
if [[ -n "$UPDATE_KEY" ]]; then
  # An Ed25519 public key is 32 bytes: 44 base64 characters, one of them padding.
  if [[ ! "$UPDATE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
    echo "$KEY_FILE does not hold an EdDSA public key (44 base64 characters, as generate_keys prints)" >&2
    exit 1
  fi
  "$PLISTBUDDY" -c "Add :SUPublicEDKey string $UPDATE_KEY" "$APP/Contents/Info.plist"
  echo "update key from $KEY_FILE"
else
  echo "no update key in $KEY_FILE: this build will not update itself"
fi
if [[ -n "$VERSION" ]]; then
  "$PLISTBUDDY" -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
  echo "version $VERSION"
fi
"$PLUTIL" -lint "$APP/Contents/Info.plist" >/dev/null

# 3. Sign --------------------------------------------------------------------
# Nested code first, inside out, each piece on its own: codesign --deep would
# give every piece the app's entitlements and is not what Apple recommends.
# The order and the flags are the ones Sparkle documents for a build signed
# outside Xcode; Downloader.xpc keeps the entitlements it shipped with.
sign_nested() { # codesign flags and the path
  if [[ -n "$SIGN_IDENTITY" ]]; then
    "$CODESIGN" --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$@"
  else
    "$CODESIGN" --force --sign - "$@"
  fi
}
if [[ -n "$SPARKLE" ]]; then
  step "Signing Sparkle.framework"
  sign_nested "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  sign_nested --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  sign_nested "$SPARKLE/Versions/B/Autoupdate"
  sign_nested "$SPARKLE/Versions/B/Updater.app"
  sign_nested "$SPARKLE"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  step "Signing with $SIGN_IDENTITY (hardened runtime, timestamp, entitlements)"
  "$CODESIGN" --force --sign "$SIGN_IDENTITY" --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$APP"
else
  step "Signing ad-hoc (this build is identified only by its cdhash)"
  "$CODESIGN" --force --sign - "$APP"
fi
"$CODESIGN" --verify --strict "$APP"
if [[ -n "$SPARKLE" ]]; then
  # The framework and what is inside it, which the line above does not open.
  "$CODESIGN" --verify --strict --deep "$APP"
fi
"$CODESIGN" -dvv "$APP" 2>&1 | grep -E '^(Identifier|Signature|Authority|TeamIdentifier|CDHash)=' || true
echo "$APP"
