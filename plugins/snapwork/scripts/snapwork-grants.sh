# snapwork-grants.sh: sourced by snapwork-plugin.sh and snapwork-ask.sh (not run by itself).
# One-use permissions to post into another of the person's rooms, per chat:
#
#   grants/<chat>.grant    room <room id> <until>   the person typed /snapwork:send-to-room naming
#                                                   that room: one post there goes without asking
#                          cmd <sha256> <until>     the person said yes to that exact post (Claude)
#   grants/<chat>.pending  cmd <sha256> <until>     Claude: a post stopped until the person says yes
#                          held <room id> <until>   Codex: a post held until the person says yes; the
#                                                   second line is the room's name, the third its
#                                                   text (JSON-escaped, as the block had it)
#
# <chat> is the hook input's session_id (letters, digits, _ and - only), <until> the epoch second
# the line stops counting, GRANT_SECONDS after it was written. A grant is removed when it is used, a
# pending post when the person answers. Files are mode 600 in a 700 folder, and a link in place of
# either is never followed or written through.
#
# Uses: SNAPWORK_HOME.

GRANT_SECONDS=600
GRANTS=$SNAPWORK_HOME/grants

grant_until() { printf '%s' "$(($(date +%s) + GRANT_SECONDS))"; }

# grant_put <chat> grant|pending: the file's content comes on stdin.
grant_put() {
  case $1 in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
  gf=$GRANTS/$1.$2
  (
    umask 077
    [ ! -L "$GRANTS" ] && mkdir -p "$GRANTS" && [ ! -L "$GRANTS" ] && chmod 700 "$GRANTS" || exit 1
    [ ! -L "$gf" ] || exit 1
    rm -f "$gf.$$"
    set -C
    cat > "$gf.$$" && chmod 600 "$gf.$$" && mv -f "$gf.$$" "$gf"
  ) 2> /dev/null || { rm -f "$gf.$$" 2> /dev/null; return 1; }
}

# grant_fresh <chat> grant|pending: true when the file is a plain file whose first line still
# counts (a stale one is removed). Sets GRANT_FILE and GRANT_LINE (that line).
grant_fresh() {
  GRANT_LINE=
  case $1 in '' | *[!A-Za-z0-9_-]*) return 1 ;; esac
  GRANT_FILE=$GRANTS/$1.$2
  { [ -f "$GRANT_FILE" ] && [ ! -L "$GRANT_FILE" ] && [ ! -L "$GRANTS" ]; } || return 1
  GRANT_LINE=$(head -n 1 "$GRANT_FILE" 2> /dev/null)
  gu=${GRANT_LINE##* }
  case $gu in '' | *[!0-9]*) gu=0 ;; esac
  [ "$gu" -ge "$(date +%s)" ] && return 0
  rm -f "$GRANT_FILE"
  return 1
}

# grant_take <chat> room|cmd <room id or sha>: true once for a fresh grant that names exactly this,
# which is used up. Moved aside first, so two calls can never both use one grant.
grant_take() {
  grant_fresh "$1" grant || return 1
  [ "${GRANT_LINE% *}" = "$2 $3" ] || return 1
  mv -f "$GRANT_FILE" "$GRANT_FILE.$$.used" 2> /dev/null || return 1
  rm -f "$GRANT_FILE.$$.used"
}

# is_yes <text, JSON-escaped>: the person's whole message says yes. The ask shows it as "yes", so
# quotes around it (' " `, a JSON-escaped " included) count as the same yes.
is_yes() {
  yes_word=$(printf '%s' "$1" | sed 's/\\[nrt]/ /g; s/\\"//g' | tr -d "'\"\`" | tr 'A-Z' 'a-z' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/[!.]$//')
  case $yes_word in yes | y | yep | yeah | ok | okay | sure | 'send it' | 'post it') return 0 ;; esac
  return 1
}
