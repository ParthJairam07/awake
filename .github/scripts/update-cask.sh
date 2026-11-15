#!/bin/bash
# Point the Homebrew cask at one release.
#
#   update-cask.sh --version X.Y.Z --sha256 HEX [--file Casks/awake.rb]
#
#   Rewrites the `version "..."` and `sha256 "..."` lines of the cask in
#   place: the version of the release and the SHA-256 of its
#   Awake-<version>.zip, as SHA256SUMS lists it. Everything else in the file
#   is left as it is. Stops without changing the file unless it has exactly
#   one of each line.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() { echo "usage: $0 --version X.Y.Z --sha256 HEX [--file Casks/awake.rb]" >&2; }
VERSION=""
SHA256=""
FILE="$ROOT/Casks/awake.rb"
while (( $# )); do
  case "$1" in
    --version) [[ $# -ge 2 ]] || { usage; exit 2; }; VERSION="$2"; shift 2 ;;
    --sha256) [[ $# -ge 2 ]] || { usage; exit 2; }; SHA256="$2"; shift 2 ;;
    --file) [[ $# -ge 2 ]] || { usage; exit 2; }; FILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "--version '$VERSION' is not X.Y.Z" >&2
  usage
  exit 2
fi
if [[ ! "$SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "--sha256 '$SHA256' is not 64 lowercase hex digits" >&2
  usage
  exit 2
fi
[[ -f "$FILE" ]] || { echo "$FILE does not exist" >&2; exit 1; }

versions="$(grep -c '^  version "[^"]*"$' "$FILE" || true)"
sums="$(grep -c '^  sha256 "[^"]*"$' "$FILE" || true)"
if [[ "$versions" != 1 || "$sums" != 1 ]]; then
  echo "$FILE must have exactly one version line and one sha256 line (found $versions and $sums). Nothing was changed." >&2
  exit 1
fi

updated="$(mktemp "${TMPDIR:-/tmp}/awake-cask.XXXXXX")"
trap 'rm -f "$updated"' EXIT
sed -e "s/^  version \"[^\"]*\"\$/  version \"$VERSION\"/" \
    -e "s/^  sha256 \"[^\"]*\"\$/  sha256 \"$SHA256\"/" "$FILE" > "$updated"
grep -qxF "  version \"$VERSION\"" "$updated"
grep -qxF "  sha256 \"$SHA256\"" "$updated"
cat "$updated" > "$FILE"
echo "$FILE: version $VERSION, sha256 $SHA256"
