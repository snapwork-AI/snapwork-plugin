#!/bin/sh
# snapwork-ask.sh: Claude Code's PreToolUse hook on Bash (hooks/hooks.json, reads the hook input
# JSON on stdin).
#
# A post into another of the person's rooms (snapwork-hook.sh --elsewhere post <room id>) goes only
# when the person said so in this chat (snapwork-grants.sh):
# - a grant for this chat names that room (they typed /snapwork:send-to-room naming it), or that
#   exact command (they replied yes to it): "allow", and the grant is used up;
# - otherwise the post is kept as pending and refused ("deny"), with how to ask the person once in
#   the chat. Their yes (snapwork-plugin.sh, UserPromptSubmit) turns it into a grant.
# Only a post that is one plain call, with its text in single quotes, can be allowed: anything else
# around it (a second command, an unquoted text) gets Claude Code's own permission prompt ("ask"),
# which shows the whole command. A link that makes this agent someone's (snapwork-hook.sh --mine)
# always asks, also in auto mode. Any other call: no output, exit 0.
#
# This runs on every Bash call: one read of stdin, no network, and a call that never names
# snapwork-hook.sh leaves after one case. The command is matched like the ask rules match it, on
# its text, with quotes and backslashes dropped and spaces squeezed, so any path to the script,
# a quoted path or extra spaces still match.

INPUT=$(cat)
case $INPUT in *snapwork-hook.sh*) ;; *) exit 0 ;; esac
# Codex sets PLUGIN_ROOT to CLAUDE_PLUGIN_ROOT when the ChatGPT app also loads hooks.json
# (snapwork-plugin.sh): these are Claude's hooks, so step aside.
[ -z "${PLUGIN_ROOT:-}" ] || [ "$PLUGIN_ROOT" != "${CLAUDE_PLUGIN_ROOT:-}" ] || exit 0

# tool_input.command, the only "command" key of a Bash call's input, still JSON-escaped; then as one
# padded line.
RAW=$(printf '%s\n' "$INPUT" | sed -n -E 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/\1/p')
CMD=$(printf '%s\n' "$RAW" | sed -E 's/^/ /; s/$/ /; s/\\[nrt]/ /g; s/[\\"'\'']//g; s/[[:space:]]+/ /g')

decide() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
  exit 0
}

case $CMD in
  *"snapwork-hook.sh --elsewhere post "*) ;;
  *"snapwork-hook.sh --mine "*) decide ask 'Make a link that makes this agent yours?' ;;
  *) exit 0 ;;
esac
ASK_POST='Post this message into your other room, under your name?'

# One plain call: sh <the script> --elsewhere post <id> --room <id> [--agent <id>] -- '<text>', the
# text single-quoted (a quote inside written as '\''), nothing before or after it.
ONE_POST=$(printf '^ *sh +([A-Za-z0-9._/~-]*/snapwork-hook[.]sh|\\\\"[A-Za-z0-9._/~ -]*/snapwork-hook[.]sh\\\\") +--elsewhere +post +[A-Za-z0-9-]+ +--room +[A-Za-z0-9_-]+( +--agent +[A-Za-z0-9_-]+)? +-- +\047([^\047]|\047\\\\\\\\\047\047)*\047 *$')
printf '%s\n' "$RAW" | grep -q -E -e "$ONE_POST" || decide ask "$ASK_POST"

SNAPWORK_HOME=${SNAPWORK_HOME:-${HOME:-}/.snapwork}
. "$(dirname "$0")/snapwork-grants.sh" || decide ask "$ASK_POST"
CHAT=$(printf '%s' "$INPUT" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n 1 \
  | sed 's/^"session_id"[[:space:]]*:[[:space:]]*"//;s/"$//' | tr -cd 'A-Za-z0-9_-' | cut -c 1-100)
[ -n "$CHAT" ] || decide ask "$ASK_POST"
TARGET=${CMD#*"snapwork-hook.sh --elsewhere post "}
TARGET=${TARGET%% *}
if command -v sha256sum > /dev/null 2>&1; then SHA=$(printf '%s' "$CMD" | sha256sum | cut -d ' ' -f 1)
elif command -v shasum > /dev/null 2>&1; then SHA=$(printf '%s' "$CMD" | shasum -a 256 | cut -d ' ' -f 1)
else decide ask "$ASK_POST"
fi

if grant_take "$CHAT" room "$TARGET" || grant_take "$CHAT" cmd "$SHA"; then
  decide allow 'Your person asked for this post in this chat.'
fi
printf 'cmd %s %s\n' "$SHA" "$(grant_until)" | grant_put "$CHAT" pending || decide ask "$ASK_POST"
decide deny "Not posted: your person has not said yes to this post. Ask them in one line, in exactly this shape, with your text and the room's name from the list: Post \\\"<the text>\\\" in '<room name>'? Reply yes to send it. Then end your turn. Once they reply yes, run the same command again, unchanged."
