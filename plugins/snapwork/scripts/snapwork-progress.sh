# snapwork-progress.sh: sourced by snapwork-plugin.sh (not run by itself). Claude's to-do list in
# the room: when a chat that is in a room changes its tasks (TaskCreate, TaskUpdate), the chat's
# whole list goes to the room, which shows it as one live message.
#
# A chat whose Claude has TodoWrite instead of the task tools (SNAP-40) sends that list: PostToolUse
# for TodoWrite carries the whole list in tool_input.todos; its items are kept in <connection>.todos
# (mode 600) so Stop can send them again. The source used last wins: a TaskCreate or TaskUpdate
# removes that file. Agents with neither tool use snapwork-hook.sh --progress (the listener).
#
# Claude keeps the list as one JSON file per task in ${CLAUDE_CONFIG_DIR:-~/.claude}/tasks/<chat>/,
# already up to date when PostToolUse runs. Only the subject (the activeForm of a task being worked
# on), the status and, for a blocked task, metadata.snapwork_blocked leave this computer; the
# description and everything else stay here. Each string is copied as the JSON token it already is
# in the file (escapes and UTF-8 untouched), so nothing is unescaped or rebuilt in sh and the body
# stays valid JSON. A file that does not read as a whole JSON object is left out.
#
# Claude waits for PostToolUse and Stop hooks, so every send runs in the background. Hooks overlap
# (several task changes in a row), so sends take turns on a lock next to the connection, read the
# files only once they hold it, and carry a time later than the last one: the newest list wins
# whatever order the hooks ran in. <connection>.progress (mode 600) says this chat has a list in the
# room: "<session> <last time sent> <last Stop>". Stop sends the list again as not working (a change
# from before that Stop is then not sent as working); SessionEnd closes the list and removes the
# file. Codex has no task tools: never there.
#
# Uses from snapwork-plugin.sh / snapwork-onoff.sh: SID, APP, STATE, WORK, pick, is_off, plog,
# valid_session, work_dir, api, API_STATUS. The key travels as api sends it (curl's config on stdin,
# fixed GATEWAY only). The log gets the step and the number of items, never their text.

PROGRESS_MAX_ITEMS=50
# A TodoWrite step longer than this (bytes, as escaped JSON) is left out: the gateway shortens a
# long step itself, but 50 huge ones would pass its 256 KiB body limit and the whole list would fail.
PROGRESS_TODO_MAX_BYTES=4096
# Task files read at most (a few may be left out: unknown status, no subject).
PROGRESS_SCAN_FILES=200
PROGRESS_FILE_MAX_BYTES=262144
# Turns on the lock: 0.2 s each, longer than one call can take (API_SECONDS), then it is taken.
PROGRESS_LOCK_TRIES=100
PROGRESS_MARK=
PROGRESS_LOCK=
PROGRESS_TODOS=

# The time in milliseconds (seconds times 1000 where date has no %N, as on macOS).
progress_now_ms() {
  ms=$(date +%s%N 2> /dev/null)
  case $ms in
    '' | *[!0-9]*) ms=$(($(date +%s) * 1000)) ;;
    *) if [ "${#ms}" -ge 16 ]; then ms=$(printf '%s' "$ms" | cut -c 1-13); else ms=$(($(date +%s) * 1000)); fi ;;
  esac
  printf '%s' "$ms"
}

# A time this file wrote: digits, no leading zero (the shell would read it as octal).
progress_number() {
  case $1 in 0) return 0 ;; '' | 0* | *[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 16 ]
}

M_SID=
M_AT=0
M_STOP=0
progress_read_mark() {
  M_SID=
  M_AT=0
  M_STOP=0
  { [ -f "$PROGRESS_MARK" ] && [ ! -L "$PROGRESS_MARK" ]; } || return 1
  read -r M_SID M_AT M_STOP < "$PROGRESS_MARK" 2> /dev/null || :
  valid_session "$M_SID" || { M_SID=; return 1; }
  progress_number "$M_AT" || M_AT=0
  progress_number "$M_STOP" || M_STOP=0
}
# Written beside, then renamed: a rename replaces a planted link instead of following it.
progress_write_mark() {
  (umask 077 && printf '%s %s %s\n' "$SID" "$1" "$2" > "$PROGRESS_MARK.$$" && mv -f "$PROGRESS_MARK.$$" "$PROGRESS_MARK") 2> /dev/null \
    || rm -f "$PROGRESS_MARK.$$"
}

progress_lock() {
  tries=0
  until (umask 077 && mkdir "$PROGRESS_LOCK") 2> /dev/null; do
    tries=$((tries + 1))
    if [ "$tries" -ge "$PROGRESS_LOCK_TRIES" ]; then
      # Left by a send that was killed: no live one holds it this long.
      rm -rf "$PROGRESS_LOCK"
      (umask 077 && mkdir "$PROGRESS_LOCK") 2> /dev/null
      return 0
    fi
    sleep 0.2 2> /dev/null || sleep 1
  done
}

# The fields a task file may give, read with a small JSON scanner (strings, depth, keys), so a
# "status" inside the description or inside metadata is never taken for the task's own.
# shellcheck disable=SC2016
PROGRESS_AWK='
BEGIN { sep = sprintf("%c", 30); ctl = "[" sprintf("%c", 1) "-" sprintf("%c", 31) "]" }
function scan(   n, i, c, j, d, tok, depth) {
  split("", top); split("", meta); split("", lastkey); split("", isobj)
  n = length(buf); depth = 0; i = 1
  while (i <= n) {
    c = substr(buf, i, 1)
    if (c == "\"") {
      j = i + 1
      while (j <= n) {
        d = substr(buf, j, 1)
        if (d == "\\") { j += 2; continue }
        if (d == "\"") break
        j++
      }
      if (j > n) return 0
      tok = substr(buf, i, j - i + 1)
      i = j + 1
      while (i <= n && index(" \t\r\n", substr(buf, i, 1)) > 0) i++
      if (i <= n && substr(buf, i, 1) == ":") { lastkey[depth] = tok; i++; continue }
      if (depth == 1 && isobj[1]) top[lastkey[1]] = tok
      else if (depth == 2 && isobj[2] && lastkey[1] == "\"metadata\"") meta[lastkey[2]] = tok
      continue
    }
    if (c == "{" || c == "[") { depth++; isobj[depth] = (c == "{"); lastkey[depth] = "" }
    else if (c == "}" || c == "]") { depth--; if (depth < 0) return 0 }
    i++
  }
  return depth == 0 && isobj[1]
}
# A string with something in it, nothing JSON forbids raw, and only escapes JSON knows.
function usable(t,   s) {
  if (t == "" || t ~ /^" *"$/ || t ~ ctl) return 0
  s = t
  gsub(/\\(["\\\/bfnrt]|u[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])/, "", s)
  return index(s, "\\") == 0
}
function emit(   status, subject, active, blocked, text, state, item) {
  if (count >= max || !scan()) return
  status = top["\"status\""]; subject = top["\"subject\""]
  active = top["\"activeForm\""]; blocked = meta["\"snapwork_blocked\""]
  if (!usable(subject)) return
  if (status == "\"completed\"") { state = "done"; text = subject }
  else if (status != "\"in_progress\"" && status != "\"pending\"") return
  else if (usable(blocked)) { state = "blocked"; text = subject }
  else if (status == "\"in_progress\"") { state = "working"; text = usable(active) ? active : subject }
  else { state = "todo"; text = subject }
  item = "{\"text\":" text ",\"state\":\"" state "\""
  if (state == "blocked") item = item ",\"reason\":" blocked
  printf "%s%s,\"key\":\"%s\"}", (count > 0 ? "," : ""), item, id
  count++
}
substr($0, 1, 1) == sep { if (id != "") emit(); id = substr($0, 2); buf = ""; next }
{ buf = buf $0 "\n" }
END { if (id != "") emit(); printf "%d\n", count > countfile }
'

# TodoWrite's list from the hook input: the objects of tool_input.todos only (tool_response repeats
# them as oldTodos/newTodos and is never read). The same scanner rules as PROGRESS_AWK: each string is
# copied as the JSON token it is; content is the step, activeForm the step while it is worked on.
# shellcheck disable=SC2016
PROGRESS_TODO_AWK='
BEGIN { ctl = "[" sprintf("%c", 1) "-" sprintf("%c", 31) "]" }
function usable(t,   s) {
  if (t == "" || t ~ /^" *"$/ || t ~ ctl) return 0
  s = t
  gsub(/\\(["\\\/bfnrt]|u[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])/, "", s)
  return index(s, "\\") == 0
}
function emit(   status, content, active, text, state) {
  status = f["\"status\""]; content = f["\"content\""]; active = f["\"activeForm\""]
  if (count >= max || !usable(content)) return
  if (status == "\"completed\"") { state = "done"; text = content }
  else if (status == "\"in_progress\"") { state = "working"; text = usable(active) ? active : content }
  else if (status == "\"pending\"") { state = "todo"; text = content }
  else return
  if (length(text) > maxbytes) return
  printf "%s{\"text\":%s,\"state\":\"%s\",\"key\":\"t%d\"}", (count > 0 ? "," : ""), text, state, count + 1
  count++
}
{ buf = buf $0 "\n" }
END {
  n = length(buf); depth = 0; i = 1; intodo = 0
  while (i <= n) {
    c = substr(buf, i, 1)
    if (c == "\"") {
      j = i + 1
      while (j <= n) {
        d = substr(buf, j, 1)
        if (d == "\\") { j += 2; continue }
        if (d == "\"") break
        j++
      }
      if (j > n) break
      tok = substr(buf, i, j - i + 1)
      i = j + 1
      while (i <= n && index(" \t\r\n", substr(buf, i, 1)) > 0) i++
      if (i <= n && substr(buf, i, 1) == ":") { lastkey[depth] = tok; i++; continue }
      if (intodo && depth == 4) f[lastkey[4]] = tok
      continue
    }
    if (c == "{" || c == "[") {
      depth++; isobj[depth] = (c == "{"); lastkey[depth] = ""
      if (depth == 4 && isobj[4] && !isobj[3] && isobj[2] && isobj[1] \
        && lastkey[1] == "\"tool_input\"" && lastkey[2] == "\"todos\"") { intodo = 1; split("", f) }
    } else if (c == "}" || c == "]") {
      if (intodo && depth == 4) { emit(); intodo = 0 }
      depth--
      if (depth < 0) break
    }
    i++
  }
}
'

# progress_take_todos: keep this TodoWrite list for the sends (empty: the file goes).
progress_take_todos() {
  todos=$(printf '%s' "$INPUT" | LC_ALL=C awk -v max="$PROGRESS_MAX_ITEMS" -v maxbytes="$PROGRESS_TODO_MAX_BYTES" "$PROGRESS_TODO_AWK")
  if [ -z "$todos" ]; then rm -f "$PROGRESS_TODOS"; return 1; fi
  (umask 077 && printf '%s\n' "$todos" > "$PROGRESS_TODOS.$$" && mv -f "$PROGRESS_TODOS.$$" "$PROGRESS_TODOS") 2> /dev/null \
    || { rm -f "$PROGRESS_TODOS.$$"; return 1; }
}

# progress_items <count file>: this chat's items as JSON objects joined by commas (its TodoWrite
# list, else its task files in the order of their ids); their number goes into the count file.
progress_items() {
  if [ -f "$PROGRESS_TODOS" ] && [ ! -L "$PROGRESS_TODOS" ]; then
    head -n 1 "$PROGRESS_TODOS" | tr -d '\n'
    head -n 1 "$PROGRESS_TODOS" | grep -o '"state":"' | wc -l | tr -d ' ' > "$1"
    return 0
  fi
  pdir=${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/tasks/$SID
  ids=$(for pf in "$pdir"/*.json; do
    pn=${pf##*/}
    pn=${pn%.json}
    case $pn in '' | *[!0-9]*) continue ;; esac
    [ "${#pn}" -le 9 ] && [ -f "$pf" ] && [ ! -L "$pf" ] && printf '%s\n' "$pn"
  done | sort -n | head -n "$PROGRESS_SCAN_FILES")
  # One stream, each file after a line "<RS><id>": a file deleted meanwhile is simply empty.
  for pn in $ids; do
    printf '\036%s\n' "$pn"
    head -c "$PROGRESS_FILE_MAX_BYTES" "$pdir/$pn.json" 2> /dev/null
    printf '\n'
  done | LC_ALL=C awk -v max="$PROGRESS_MAX_ITEMS" -v countfile="$1" "$PROGRESS_AWK"
}

# progress_job <work|stop|end> <time of the hook>: one send, in the background.
progress_job() {
  WORK=
  work_dir || exit 0
  # After work_dir, which would end the send on a hang-up (the app closing its terminal).
  trap '' HUP INT
  progress_lock
  trap 'rmdir "$PROGRESS_LOCK" 2> /dev/null; rm -rf "$WORK"' EXIT
  progress_read_mark
  case $1 in
    end)
      api DELETE progress
      case $API_STATUS in 2??) plog "progress-end" ;; *) plog "progress-end-failed status=$API_STATUS" ;; esac
      exit 0 ;;
    stop)
      # SessionEnd closed the list meanwhile.
      [ "$M_SID" = "$SID" ] || exit 0
      working=false
      stopped=$2 ;;
    *)
      working=true
      stopped=0
      if [ "$M_SID" = "$SID" ]; then
        stopped=$M_STOP
        # A Stop after this change already sent the newest list as not working (the same time
        # counts: where date has no %N, both may fall in one second).
        if [ "$M_STOP" -ge "$2" ]; then plog "progress-after-stop"; exit 0; fi
      fi ;;
  esac
  at=$(progress_now_ms)
  [ "$M_SID" != "$SID" ] || [ "$at" -gt "$M_AT" ] || at=$((M_AT + 1))
  {
    printf '{"list_id":"%s","items":[' "$SID"
    progress_items "$WORK/count"
    printf '],"working":%s,"at":%s}' "$working" "$at"
  } > "$WORK/progress.json"
  api PUT progress "$WORK/progress.json"
  progress_write_mark "$at" "$stopped"
  count=$(cat "$WORK/count" 2> /dev/null)
  case $count in '' | *[!0-9]*) count=0 ;; esac
  case $API_STATUS in
    2??) plog "progress-$1 items=$count" ;;
    *) plog "progress-$1-failed items=$count status=$API_STATUS" ;;
  esac
  exit 0
}

# progress_start <work|stop|end>: starts the send and returns at once (its output goes nowhere, so
# the app does not wait for it). It outlives the hook, and the app closing does not cut it short.
progress_start() {
  pt0=$(progress_now_ms)
  (progress_job "$1" "$pt0") < /dev/null > /dev/null 2>&1 &
}

progress_paths() {
  PROGRESS_MARK=${STATE%.json}.progress
  PROGRESS_LOCK=$PROGRESS_MARK.lock
  PROGRESS_TODOS=${STATE%.json}.todos
}

# PostToolUse (TaskCreate, TaskUpdate, TodoWrite): send this chat's list, when the chat is in a room
# and on. TodoWrite's list comes in the hook input; the task tools' lists are read from their files.
on_progress() {
  { [ "$APP" = claude ] && [ -n "$SID" ]; } || exit 0
  pick bound || exit 0
  if is_off; then plog "progress-off"; exit 0; fi
  progress_paths
  if [ "$(input_field tool_name)" = TodoWrite ]; then
    if ! progress_take_todos; then
      # An emptied list: close this chat's list in the room, so no card is left working.
      if progress_read_mark && [ "$M_SID" = "$SID" ]; then
        rm -f "$PROGRESS_MARK"
        plog "progress-cleared"
        progress_start end
      else
        plog "progress-skip"
      fi
      exit 0
    fi
  else
    rm -f "$PROGRESS_TODOS"
  fi
  progress_start work
  exit 0
}

# Stop, before listening: the chat stopped for now, so its list is not being worked on.
progress_on_stop() {
  [ "$APP" = claude ] || return 0
  progress_paths
  progress_read_mark || return 0
  [ "$M_SID" = "$SID" ] || return 0
  progress_start stop
}

# SessionEnd (also /clear, whose chat goes on under a new session id with a list of its own).
progress_on_end() {
  [ "$APP" = claude ] || return 0
  progress_paths
  { [ -f "$PROGRESS_MARK" ] && [ ! -L "$PROGRESS_MARK" ]; } || return 0
  rm -f "$PROGRESS_MARK" "$PROGRESS_TODOS"
  progress_start end
}
