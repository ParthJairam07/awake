#!/bin/bash
# Write the Sparkle update feed (appcast.xml) for one release.
#
#   generate-appcast.sh --zip PATH/Awake-<version>.zip --tag v<version>
#                       --repository OWNER/REPO --output PATH/appcast.xml
#                       [--tools DIR]
#
#   SPARKLE_PRIVATE_KEY (environment): the EdDSA private key that
#   `generate_keys -x` exports. It reaches Sparkle's tool on standard input
#   and is never written to a file or printed.
#
#   --tools is the folder with Sparkle's generate_appcast. The default is
#   where SwiftPM unpacks it once the package has been built:
#   .build/artifacts/sparkle/Sparkle/bin.
#
# The feed has one item, this release, whose download is the zip attached to
# the GitHub Release for the tag. The app reads the feed from
# releases/latest/download/appcast.xml, so each stable release replaces it.
#
# Stops without writing anything when the key does not belong to the public
# key the app in the zip carries (SUPublicEDKey, from
# scripts/sparkle-public-key.txt): every installed copy would refuse an
# update signed with another key. Also stops when the feed comes out
# without a signature.
set -euo pipefail

DITTO=/usr/bin/ditto
SWIFT=/usr/bin/swift
PLUTIL=/usr/bin/plutil

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() { echo "usage: $0 --zip PATH/Awake-<version>.zip --tag v<version> --repository OWNER/REPO --output PATH/appcast.xml [--tools DIR]" >&2; }
ZIP=""
TAG=""
REPOSITORY=""
OUTPUT=""
TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
while (( $# )); do
  case "$1" in
    --zip) [[ $# -ge 2 ]] || { usage; exit 2; }; ZIP="$2"; shift 2 ;;
    --tag) [[ $# -ge 2 ]] || { usage; exit 2; }; TAG="$2"; shift 2 ;;
    --repository) [[ $# -ge 2 ]] || { usage; exit 2; }; REPOSITORY="$2"; shift 2 ;;
    --output) [[ $# -ge 2 ]] || { usage; exit 2; }; OUTPUT="$2"; shift 2 ;;
    --tools) [[ $# -ge 2 ]] || { usage; exit 2; }; TOOLS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
[[ -n "$ZIP" && -n "$TAG" && -n "$REPOSITORY" && -n "$OUTPUT" ]] || { usage; exit 2; }
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "--tag '$TAG' is not v<major>.<minor>.<patch>" >&2
  exit 2
fi
if [[ ! "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "--repository '$REPOSITORY' is not OWNER/REPO" >&2
  exit 2
fi
[[ -f "$ZIP" ]] || { echo "$ZIP does not exist" >&2; exit 1; }
if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
  echo "SPARKLE_PRIVATE_KEY is not set" >&2
  exit 1
fi
if [[ ! -x "$TOOLS/generate_appcast" ]]; then
  echo "$TOOLS/generate_appcast not found; build the package first (swift build) or pass --tools" >&2
  exit 1
fi
if [[ -e "$OUTPUT" ]]; then
  echo "$OUTPUT already exists; refusing to replace it" >&2
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/awake-appcast.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# The key the app in this zip will check updates against.
mkdir "$WORK/unpacked" "$WORK/archives"
"$DITTO" -x -k "$ZIP" "$WORK/unpacked"
embedded="$("$PLUTIL" -extract SUPublicEDKey raw -o - "$WORK/unpacked/Awake.app/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$embedded" ]]; then
  echo "the app in $(basename "$ZIP") has no SUPublicEDKey: scripts/sparkle-public-key.txt was empty when it was built, so it cannot update itself and a feed for it would be unsigned. Nothing was written." >&2
  exit 1
fi
derived="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SWIFT" "$SCRIPT_DIR/eddsa-public-key.swift")"
if [[ "$derived" != "$embedded" ]]; then
  echo "SPARKLE_PRIVATE_KEY does not belong to the public key in scripts/sparkle-public-key.txt ($embedded). Installed copies would refuse the update. Nothing was written." >&2
  exit 1
fi

cp "$ZIP" "$WORK/archives/"
# generate_appcast caches unpacked archives under ~/Library/Caches; HOME is
# pointed at the scratch folder so nothing is left behind or reused.
printf '%s' "$SPARKLE_PRIVATE_KEY" | HOME="$WORK" "$TOOLS/generate_appcast" \
  --ed-key-file - \
  --download-url-prefix "https://github.com/$REPOSITORY/releases/download/$TAG/" \
  --full-release-notes-url "https://github.com/$REPOSITORY/releases/tag/$TAG" \
  --link "https://github.com/$REPOSITORY/releases" \
  -o "$WORK/appcast.xml" "$WORK/archives"

url="https://github.com/$REPOSITORY/releases/download/$TAG/$(basename "$ZIP")"
if ! grep -qF "url=\"$url\"" "$WORK/appcast.xml"; then
  echo "the feed does not name $url. Nothing was written." >&2
  exit 1
fi
if ! grep -q 'sparkle:edSignature="[A-Za-z0-9+/=]\{80,\}"' "$WORK/appcast.xml"; then
  echo "the feed's download carries no EdDSA signature. Nothing was written." >&2
  exit 1
fi
mkdir -p "$(dirname "$OUTPUT")"
cp "$WORK/appcast.xml" "$OUTPUT"
echo "wrote $OUTPUT for $url"
