#!/bin/bash
# Turn a built Awake.app into the files a GitHub Release carries.
#
#   package-release.sh --app PATH/Awake.app --name NAME --output DIR
#                      [--sign-identity IDENTITY]
#
#   Writes into DIR (created if needed, must not already hold these files):
#     NAME.zip      Awake.app at the top level (`ditto -c -k --keepParent`),
#                   what Sparkle, the Homebrew cask and install.sh download
#     NAME.dmg      a compressed disk image with Awake.app and a shortcut to
#                   /Applications, for people who install by dragging
#     install.sh    the installer of this commit (scripts/install.sh)
#     uninstall.sh  the uninstaller of this commit (scripts/uninstall.sh)
#
#   --sign-identity signs the disk image with that Developer ID identity, so
#   it can be notarized. The app inside is whatever build-app.sh signed; this
#   script never signs or changes the bundle.
#
# SHA256SUMS is written by the workflow after the disk image has been
# notarized and stapled, since stapling changes the file.
set -euo pipefail

DITTO=/usr/bin/ditto
HDIUTIL=/usr/bin/hdiutil
CODESIGN=/usr/bin/codesign

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() { echo "usage: $0 --app PATH/Awake.app --name NAME --output DIR [--sign-identity IDENTITY]" >&2; }
APP=""
NAME=""
OUTPUT=""
SIGN_IDENTITY=""
while (( $# )); do
  case "$1" in
    --app) [[ $# -ge 2 ]] || { usage; exit 2; }; APP="$2"; shift 2 ;;
    --name) [[ $# -ge 2 ]] || { usage; exit 2; }; NAME="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || { usage; exit 2; }; OUTPUT="$2"; shift 2 ;;
    --sign-identity) [[ $# -ge 2 && -n "$2" ]] || { usage; exit 2; }; SIGN_IDENTITY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$APP" && -n "$NAME" && -n "$OUTPUT" ]] || { usage; exit 2; }
APP="${APP%/}"
if [[ "$(basename "$APP")" != Awake.app || ! -f "$APP/Contents/Info.plist" ]]; then
  echo "$APP is not an Awake.app bundle" >&2
  exit 1
fi
# NAME becomes file names and a volume name.
if [[ ! "$NAME" =~ ^Awake-[0-9A-Za-z.-]+$ ]]; then
  echo "--name '$NAME' must look like Awake-<version>" >&2
  exit 2
fi
# The bundle must be intact before it is copied anywhere.
"$CODESIGN" --verify --strict --deep "$APP"

mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
for file in "$NAME.zip" "$NAME.dmg" install.sh uninstall.sh; do
  if [[ -e "$OUTPUT/$file" ]]; then
    echo "$OUTPUT/$file already exists; refusing to replace it" >&2
    exit 1
  fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/awake-package.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "==> $NAME.zip"
"$DITTO" -c -k --sequesterRsrc --keepParent "$APP" "$OUTPUT/$NAME.zip"

echo "==> $NAME.dmg"
mkdir "$WORK/image"
"$DITTO" "$APP" "$WORK/image/Awake.app"
ln -s /Applications "$WORK/image/Applications"
"$HDIUTIL" create -volname "${NAME/-/ }" -srcfolder "$WORK/image" -fs HFS+ -format UDZO -quiet "$OUTPUT/$NAME.dmg"
if [[ -n "$SIGN_IDENTITY" ]]; then
  "$CODESIGN" --sign "$SIGN_IDENTITY" --timestamp "$OUTPUT/$NAME.dmg"
  "$CODESIGN" --verify --strict "$OUTPUT/$NAME.dmg"
fi

echo "==> install.sh, uninstall.sh"
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/uninstall.sh" "$OUTPUT/"

ls -l "$OUTPUT"
