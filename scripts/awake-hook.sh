#!/bin/bash
# awake-hook.sh: tell Awake what an AI coding agent is doing.
#
#   awake-hook.sh <kind> [event] [json]
#
# <kind>  the agent: claude, codex, or any name of lower-case letters,
#         digits, - and _.
# [event] what happened, when the JSON does not say: waiting, finished,
#         heartbeat or ended. Claude Code's hook input names its own event
#         (hook_event_name) and Codex's notify payload has a type, so both
#         can leave it out.
# [json]  the agent's payload as an argument (Codex notify passes it that
#         way). Without it the payload is read from stdin (Claude Code
#         hooks), unless stdin is a terminal.
#
# Posts to Awake's Unix socket in Application Support. Awake listens only
# while a session runs; with no session, or no Awake, this exits 0 at once
# and prints nothing, so a hook never blocks or fails the agent.
#
# Runs under the system bash 3.2. See docs/agents.md for the hook configs.

kind="${1:-}"
event="${2:-}"
payload="${3:-}"

case "$kind" in
    ''|*[!a-z0-9_-]*) exit 0 ;;
esac
case "$event" in
    *[!A-Za-z0-9_-]*) exit 0 ;;
esac

socket="${AWAKE_HOME:-$HOME/Library/Application Support/Awake}/hooks.sock"
[ -S "$socket" ] || exit 0

if [ -z "$payload" ] && [ ! -t 0 ]; then
    payload="$(cat)"
fi
[ -n "$payload" ] || payload='{}'

url="http://awake/hooks/$kind?pid=$PPID"
if [ -n "$event" ]; then
    url="$url&event=$event"
fi

printf '%s' "$payload" | /usr/bin/curl --silent --show-error --max-time 2 \
    --unix-socket "$socket" \
    --header 'Content-Type: application/json' \
    --data-binary @- \
    "$url" >/dev/null 2>&1
exit 0
