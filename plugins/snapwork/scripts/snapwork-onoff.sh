# snapwork-onoff.sh: sourced by snapwork-plugin.sh (not run by itself). Turning this chat's
# member off and on (/snapwork:exit-space, /snapwork:join-space; in Codex the skills $snapwork:exit-space,
# $snapwork:join-space) and noticing when Snapwork no
# longer accepts its key (removed, refused, or the space is gone).
#
# Uses from snapwork-plugin.sh: GATEWAY, ROOMS, ROOM, AGENT, STATE, API_SECONDS, field, set_line,
# is_off, space_of, agent_of, plog, made_by_setup. Calls go to the fixed GATEWAY only, with the key
# in curl's config on stdin (never on a command line). Answers are read as data with grep and sed.

API_STATUS=
API_BODY=
# api <GET|POST|PUT|DELETE> <path under /rooms/<id>/> [body file]: one call with this chat's key (a
# POST or PUT sends the body file, or {}). Sets API_STATUS (the HTTP status, or 000 when nothing came
# back) and API_BODY (a private temp file with the answer).
api() {
  API_STATUS=000
  key=$(field key "$STATE")
  case $key in '' | *[!A-Za-z0-9._~+/=-]*) key=; return 0 ;; esac
  # A connection saved for another gateway never sends its key here.
  case $(field gateway "$STATE") in "$GATEWAY" | "$ALT_GATEWAY") ;; *) key=; return 0 ;; esac
  command -v curl > /dev/null 2>&1 || { key=; return 0; }
  work_dir || { key=; return 0; }
  API_BODY=$WORK/api.body
  rm -f "$API_BODY"
  case $1 in
    POST | PUT)
      data='{}'
      [ -z "${3:-}" ] || data=@$3
      API_STATUS=$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl -q -K - --proto =https -sS --max-time "$API_SECONDS" \
        -o "$API_BODY" -w '%{http_code}' -X "$1" -H 'content-type: application/json' --data-binary "$data" \
        "$GATEWAY/rooms/$ROOM/$2" 2> /dev/null) ;;
    DELETE)
      API_STATUS=$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl -q -K - --proto =https -sS --max-time "$API_SECONDS" \
        -o "$API_BODY" -w '%{http_code}' -X DELETE "$GATEWAY/rooms/$ROOM/$2" 2> /dev/null) ;;
    *)
      API_STATUS=$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl -q -K - --proto =https -sS --max-time "$API_SECONDS" \
        -o "$API_BODY" -w '%{http_code}' "$GATEWAY/rooms/$ROOM/$2" 2> /dev/null) ;;
  esac
  key=
  # curl prints the status even when it fails; anything else counts as no answer.
  case $API_STATUS in [0-9][0-9][0-9]) ;; *) API_STATUS=000 ;; esac
}
# body_has <text>: the answer contains this fixed text.
body_has() { [ -n "$API_BODY" ] && grep -q -F -e "$1" "$API_BODY" 2> /dev/null; }
# body_number <name>: a number field of the answer (first match), or nothing.
body_number() {
  [ -n "$API_BODY" ] || return 0
  tr -d '\r\n' < "$API_BODY" 2> /dev/null | grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9][0-9]*" | head -n 1 | sed 's/.*:[[:space:]]*//'
}
# body_word <name>: a lowercase string field of the answer (first match), or nothing.
body_word() {
  [ -n "$API_BODY" ] || return 0
  tr -d '\r\n' < "$API_BODY" 2> /dev/null | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[a-z_]*\"" | head -n 1 | sed 's/.*"\([a-z_]*\)"$/\1/'
}
# api_reason: Snapwork's reason in an error answer ("error" as a string, else the error's "message",
# one plain line), kept to safe characters, or nothing.
api_reason() {
  [ -n "$API_BODY" ] || return 0
  flat=$(LC_ALL=C tr -d '\r\n' < "$API_BODY" 2> /dev/null)
  reason=$(printf '%s' "$flat" | LC_ALL=C sed -n 's/.*"error"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$reason" ] || reason=$(printf '%s' "$flat" | LC_ALL=C sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  printf '%s' "$reason" | LC_ALL=C tr -cd 'A-Za-z0-9 _.,:;()/?-' | head -c 400
}
# A 404 from a gateway that does not have the route yet.
route_missing() { [ "$API_STATUS" = 404 ] && body_has '"message":"Route not found"'; }
# A 404 that is Snapwork saying the space is gone (anything else, say a proxy's page, is not).
space_missing() { [ "$API_STATUS" = 404 ] && body_has '"code":"NOT_FOUND"' && ! body_has 'Route not found'; }
# A 401 that is Snapwork not knowing the key (not a proxy's page).
key_unknown() { [ "$API_STATUS" = 401 ] && body_has '"code":"UNAUTHORIZED"'; }

# After the listener gave up: ask Snapwork once more, and set the connection aside only when it
# confirms (unknown key, refused member, or space gone). Otherwise nothing changes.
confirm_gone() {
  api GET listening
  if key_unknown; then gone 401; fi
  if [ "$API_STATUS" = 403 ] && gate_refused; then gone 403; fi
  if [ "$API_STATUS" = 200 ] && [ "$(body_word state)" = refused ]; then gone 403; fi
  if space_missing; then gone 404; fi
  plog "denied-not-confirmed status=$API_STATUS"
}

# Makes the listener of this chat's member stop: it checks its lock between reads and leaves
# quietly (without delivering or saving its cursor) once the lock no longer names it.
stop_local_listener() {
  lock=$ROOMS/$ROOM${AGENT:+.$AGENT}.listener
  { [ -f "$lock" ] && [ ! -L "$lock" ]; } || return 0
  (umask 077 && printf '0 off\n' > "$lock.$$" && mv "$lock.$$" "$lock") 2> /dev/null || rm -f "$lock.$$"
}

# gone <401|403|404>: Snapwork no longer accepts this chat's member. Stop listening with it, keep
# the file aside as <room>.<agent>.gone (no longer a saved connection for any hook or command),
# log it, and tell the person once: on stderr with exit 2 for the Stop hook (that wakes Claude),
# on stdout for the others.
gone() {
  space=$(space_of "$STATE")
  case $1 in
    401) why="you were removed from \"$space\" (or its key no longer works)" ;;
    403) why="Snapwork refused this chat's member in \"$space\" (for example because it did not say hello in time)" ;;
    *) why="the room \"$space\" no longer exists" ;;
  esac
  stop_local_listener
  # Kept aside for a person to look at, without the key (it no longer works anyway).
  aside=${STATE%.json}.gone
  [ ! -e "$aside" ] || aside=$aside.$$
  if (umask 077 && sed '/^[[:space:]]*"key"[[:space:]]*:/d' "$STATE" > "$aside"); then rm -f "$STATE"; else rm -f "$aside" "$STATE"; fi
  plog "gone-$1 room=$(printf '%s' "$ROOM" | cut -c 1-8)"
  text="Snapwork: $why, so messages from there no longer reach this chat. Paste a new invitation to join again. Tell the person this in one line; nothing else to do."
  if [ "$EVENT" = stop ]; then
    printf '%s\n' "$text" >&2
    exit 2
  fi
  printf '%s\n' "$text"
  exit 0
}

# A refusal from the listening gate (403) names the agent's state; "refused" is final.
gate_refused() { [ "$(body_word state)" = refused ]; }

# /snapwork:exit-space in a chat that is in a space. CMD_JOIN is spliced into printf formats here:
# it is one of two fixed words set in snapwork-plugin.sh, never anything a person or message chose.
exit_space() {
  space=$(space_of "$STATE")
  if is_off; then
    plog "exit-already-off"
    printf 'Snapwork: this chat is already turned off in "%s": messages for it wait in the room. You are still a member; '"$CMD_JOIN"' turns it back on. Tell the person this in one line.\n' "$space"
    exit 0
  fi
  api POST listening/stop
  if [ "$API_STATUS" = 200 ]; then
    off_at=$(body_number off_at)
    if ! set_line "$STATE" off "${off_at:-1}"; then
      printf 'Snapwork: Snapwork turned this member off, but the plugin could not save that; it may still wake this chat. Tell the person this in one line.\n'
      exit 0
    fi
    stop_local_listener
    plog "exit-off"
    printf 'Snapwork: turned this chat off in "%s": messages for it wait in the room. You are still a member; '"$CMD_JOIN"' turns it back on. Tell the person this in one line.\n' "$space"
    exit 0
  fi
  if key_unknown; then gone 401; fi
  if space_missing; then gone 404; fi
  if [ "$API_STATUS" = 403 ] && gate_refused; then gone 403; fi
  if [ "$API_STATUS" = 403 ]; then
    plog "exit-pending"
    printf 'Snapwork: this chat is still being added to "%s" (Snapwork has not had its hello yet), so there is nothing to turn off yet. Nothing was changed. Tell the person this in one line.\n' "$space"
  elif route_missing; then
    plog "exit-not-available"
    printf 'Snapwork: turning off is not available yet, so nothing was changed: this chat still gets messages from "%s". Tell the person this in one line.\n' "$space"
  else
    plog "exit-failed status=$API_STATUS"
    printf 'Snapwork: could not reach Snapwork (answer %s), so nothing was changed: this chat still gets messages from "%s". Tell the person this in one line.\n' "$API_STATUS" "$space"
  fi
  exit 0
}

waiting_words() {
  case $1 in
    '') printf '' ;;
    0) printf '; no messages were waiting' ;;
    1) if [ -n "$2" ]; then printf '; 1 or more messages were waiting'; else printf '; 1 message was waiting'; fi ;;
    *) printf '; %s%s messages were waiting' "$1" "${2:+ or more}" ;;
  esac
}

# Turns this chat's member back on (it was off here, or Snapwork says it is off).
turn_on() {
  space=$(space_of "$STATE")
  name=$(agent_of "$STATE")
  api POST listening/start
  case $API_STATUS in
    200)
      waiting=$(body_number waiting)
      more=
      body_has '"waiting_more":true' && more=1
      set_line "$STATE" off "" || true
      plog "join-on"
      printf 'Snapwork: this chat is on again in "%s" as "%s"%s. Messages for you arrive by themselves after you end this turn. Tell the person this in one line. %sThen end your turn.\n' \
        "$space" "$name" "$(waiting_words "$waiting" "$more")" "$(codex_steer_note)"
      exit 0 ;;
  esac
  if key_unknown; then gone 401; fi
  if space_missing; then gone 404; fi
  if [ "$API_STATUS" = 403 ] && gate_refused; then gone 403; fi
  case $API_STATUS in
    404)
      route_missing || unreachable_on
      # The gateway has no off switch: nothing there is off, so this chat simply listens again.
      set_line "$STATE" off "" || true
      plog "join-on-local"
      printf 'Snapwork: this chat is on again in "%s" as "%s". Messages for you arrive by themselves after you end this turn. Tell the person this in one line. %sThen end your turn.\n' "$space" "$name" "$(codex_steer_note)"
      exit 0 ;;
  esac
  unreachable_on
}
unreachable_on() {
  plog "join-on-failed status=$API_STATUS"
  printf 'Snapwork: could not turn this chat back on in "%s" (Snapwork answered %s). Nothing was changed. Tell the person this in one line.\n' "$space" "$API_STATUS"
  exit 0
}

# /snapwork:join-space (no invitation) in a chat that is in a space: turn it back on if it is off
# (here, or at Snapwork, for example by the email's stop link), otherwise say how it stands.
join_space_status() {
  is_off && turn_on
  space=$(space_of "$STATE")
  name=$(agent_of "$STATE")
  api GET listening
  case $API_STATUS in
    200)
      [ -z "$(body_number off_at)" ] || turn_on
      case $(body_word state) in
        pending)
          plog "status-pending"
          printf 'Snapwork: this chat is in the room "%s" as "%s"; Snapwork is still adding it and will ask it to say hello there. Tell the person this in one line.\n' "$space" "$name"
          exit 0 ;;
        refused) gone 403 ;;
      esac ;;
  esac
  if key_unknown; then gone 401; fi
  if space_missing; then gone 404; fi
  if [ "$API_STATUS" = 403 ] && gate_refused; then gone 403; fi
  plog "status-in-space"
  printf 'Snapwork: this chat is in the room "%s" as "%s", and messages for you arrive by themselves after each turn. Tell the person this in one line.\n' "$space" "$name"
  exit 0
}
