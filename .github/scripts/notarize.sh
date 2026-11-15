#!/bin/bash
# Notarize one artifact with Apple and staple the ticket to it.
#
#   notarize.sh PATH
#     PATH is an .app bundle, a .dmg or a .pkg, already signed with a
#     Developer ID certificate and the hardened runtime. An .app is zipped
#     for the upload (Apple takes archives, not folders) and the ticket is
#     stapled to the bundle itself; a .dmg or .pkg is uploaded and stapled
#     as it is.
#
#   Credentials come from the environment, never from the command line of
#   this script:
#     APPLE_ID            the Apple Account that owns the team
#     APPLE_TEAM_ID       the ten-character team identifier
#     APPLE_APP_PASSWORD  an app-specific password for that account
#
# `notarytool submit --wait` exits 0 when Apple answered, whatever the
# answer was, so the status is read from its JSON. Anything but Accepted
# prints Apple's log for the submission and fails.
set -euo pipefail

XCRUN=/usr/bin/xcrun
DITTO=/usr/bin/ditto
PLUTIL=/usr/bin/plutil

usage() { echo "usage: $0 PATH" >&2; }
[[ $# -eq 1 && -n "$1" ]] || { usage; exit 2; }
TARGET="$1"
for name in APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD; do
  if [[ -z "${!name:-}" ]]; then
    echo "$name is not set; notarization needs APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD" >&2
    exit 1
  fi
done
[[ -e "$TARGET" ]] || { echo "$TARGET does not exist" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/awake-notarize.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

case "$TARGET" in
  *.app|*.app/)
    TARGET="${TARGET%/}"
    UPLOAD="$WORK/$(basename "${TARGET%.app}").zip"
    "$DITTO" -c -k --keepParent "$TARGET" "$UPLOAD"
    ;;
  *.dmg|*.pkg) UPLOAD="$TARGET" ;;
  *) echo "$TARGET is not an .app, .dmg or .pkg" >&2; exit 2 ;;
esac

echo "Submitting $(basename "$UPLOAD") to Apple's notary service (this waits for the answer)"
RESULT="$WORK/result.json"
"$XCRUN" notarytool submit "$UPLOAD" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
  --wait --output-format json > "$RESULT"
status="$("$PLUTIL" -extract status raw -o - "$RESULT" 2>/dev/null || true)"
id="$("$PLUTIL" -extract id raw -o - "$RESULT" 2>/dev/null || true)"
echo "submission ${id:-<no id>}: ${status:-<no status>}"
if [[ "$status" != Accepted ]]; then
  echo "Apple did not accept $(basename "$UPLOAD"). Its answer:" >&2
  cat "$RESULT" >&2 || true
  if [[ -n "$id" ]]; then
    echo "Apple's log for the submission:" >&2
    "$XCRUN" notarytool log "$id" \
      --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" >&2 || true
  fi
  exit 1
fi

"$XCRUN" stapler staple "$TARGET"
"$XCRUN" stapler validate "$TARGET"
echo "notarized and stapled: $TARGET"
