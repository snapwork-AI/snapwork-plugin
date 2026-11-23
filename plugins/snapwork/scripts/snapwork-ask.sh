#!/bin/sh
# snapwork-ask.sh: Claude Code's PreToolUse hook on Bash (hooks/hooks.json, reads the hook input
# JSON on stdin).
#
# A post into another of the person's rooms (snapwork-hook.sh --elsewhere post) and a link that
# makes this agent someone's (snapwork-hook.sh --mine) always show the person Claude Code's own
# permission prompt, also in auto mode: it prints permissionDecision "ask". The listener's --install
# puts the same two commands in permissions.ask, but a plugin install never runs --install. Any
# other call: no output, exit 0. Never "allow" or "deny".
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

# tool_input.command, the only "command" key of a Bash call's input, as one padded line.
CMD=$(printf '%s\n' "$INPUT" \
  | sed -n -E 's/.*"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)".*/ \1 /p' \
  | sed -E 's/\\[nrt]/ /g; s/[\\"'\'']//g; s/[[:space:]]+/ /g')

case $CMD in
  *"snapwork-hook.sh --elsewhere post "*)
    REASON='Post this message into your other room, under your name?' ;;
  *"snapwork-hook.sh --mine "*)
    REASON='Make a link that makes this agent yours?' ;;
  *) exit 0 ;;
esac
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$REASON"
