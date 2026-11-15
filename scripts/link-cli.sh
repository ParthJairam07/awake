#!/bin/bash
# Put the `awake` command on your PATH: a symlink named awake that points at
# the command inside the installed app (Awake.app/Contents/Helpers/awake).
# Settings > Leases > Install `awake` command does the same from the app.
#
# Usage: scripts/link-cli.sh [--app PATH/Awake.app] [--dir DIR]
#   --app  the bundle to link to; default ~/Applications/Awake.app.
#   --dir  where the link goes; default /usr/local/bin when you can write
#          there, else ~/.local/bin.
#
# Never uses sudo: a /usr/local/bin that needs a password is skipped for
# ~/.local/bin. An `awake` that is already there is replaced only when it is
# a symlink; anything else is left alone and reported.
set -euo pipefail

# Fixed tool paths: never taken from PATH.
LN=/bin/ln
MKDIR=/bin/mkdir
RM=/bin/rm

APP="$HOME/Applications/Awake.app"
SYSTEM_BIN=/usr/local/bin
USER_BIN="$HOME/.local/bin"
DIR=""

usage() { echo "usage: $0 [--app PATH/Awake.app] [--dir DIR]" >&2; }
while (( $# )); do
  case "$1" in
    --app) [[ $# -ge 2 ]] || { usage; exit 2; }; APP="$2"; shift 2 ;;
    --dir) [[ $# -ge 2 ]] || { usage; exit 2; }; DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

SOURCE="$APP/Contents/Helpers/awake"
if [[ ! -x "$SOURCE" ]]; then
  echo "no awake command at $SOURCE; install Awake first (scripts/install.sh), or pass --app" >&2
  exit 1
fi
# The link holds an absolute path, so it still works from another directory.
case "$SOURCE" in
  /*) ;;
  *) SOURCE="$(cd "$(dirname "$SOURCE")" && pwd)/awake" ;;
esac

if [[ -z "$DIR" ]]; then
  if [[ -d "$SYSTEM_BIN" && -w "$SYSTEM_BIN" ]]; then
    DIR="$SYSTEM_BIN"
  else
    DIR="$USER_BIN"
  fi
fi

"$MKDIR" -p "$DIR"
LINK="$DIR/awake"
if [[ -L "$LINK" ]]; then
  "$RM" -f "$LINK"
elif [[ -e "$LINK" ]]; then
  echo "$LINK already exists and is not a link, so it was left alone; remove it and run this again" >&2
  exit 1
fi
"$LN" -s "$SOURCE" "$LINK"
echo "$LINK -> $SOURCE"

case ":$PATH:" in
  *":$DIR:"*) ;;
  *) echo "$DIR is not on your PATH; add it to your shell profile:  export PATH=\"$DIR:\$PATH\"" ;;
esac
