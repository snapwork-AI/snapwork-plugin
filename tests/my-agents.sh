#!/bin/sh
# Local tests for My agents (SnapWork M7): the connect link in a chat (snapwork-connect.sh through
# snapwork-plugin.sh) and the watcher (snapwork-watch.sh), with a temporary HOME, a fake curl
# (tests/fake-curl.sh) and a fake claude, so nothing reaches the gateway or starts a session.
#
#   sh tests/my-agents.sh           (also run at the end of tests/run.sh)
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPTS=$ROOT/plugins/snapwork/scripts
PLUGIN=$SCRIPTS/snapwork-plugin.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/home/proj" "$T/home/proj2" "$T/home/proj3" "$T/fake" "$T/tx"
cp "$ROOT/tests/fake-curl.sh" "$T/bin/curl"
# A claude that records how it was called and answers like Claude Code 2.1.312's --bg: a fork or a
# fresh chat gets a new id; --resume without --fork-session keeps the chat's id (as Claude Code
# does), unless claude_copy says it was running (then it starts a copy with a new id).
# agents_extra adds rows to `agents --json`; claude_nobg makes --bg fail without an id. `stop` is
# recorded; claude_stopfail makes it fail.
cat > "$T/bin/claude" << 'EOF'
#!/bin/sh
if [ "${1:-}" = stop ]; then
  printf 'stop |%s\n' "${2:-}" >> "$FAKE_DIR/claude_stops"
  [ ! -e "$FAKE_DIR/claude_stopfail" ] || exit 1
  exit 0
fi
if [ "${1:-}" = agents ]; then
  printf '[{"sessionId":"e2858c3e-d4ee-49ef-b4a0-57ce8ff97fa8","kind":"background"},{"sessionId": "fee53b8c-6a51-45d3-8d48-980b9689f68a","kind":"background"}%s]\n' "$(cat "$FAKE_DIR/agents_extra" 2> /dev/null)"
  exit 0
fi
{ printf 'cwd=%s path=%s' "$(pwd -P)" "$PATH"; for a in "$@"; do printf ' |%s' "$a"; done; printf '\n'; } >> "$FAKE_DIR/claude_calls"
if [ "${1:-}" = plugin ]; then
  [ ! -e "$FAKE_DIR/claude_slow" ] || sleep 6
  [ ! -e "$FAKE_DIR/claude_nobg" ] || exit 1
  exit 0
fi
if [ -e "$FAKE_DIR/claude_untrusted" ]; then
  echo "Workspace not trusted. Run \`claude\` in $(pwd) once and accept the trust prompt, then retry." >&2
  exit 1
fi
if [ -e "$FAKE_DIR/claude_nobg" ]; then
  echo "Error: could not start the background service" >&2
  exit 1
fi
id=fee53b8c
if [ "${1:-}" = --resume ] && [ "${3:-}" != --fork-session ] && [ ! -e "$FAKE_DIR/claude_copy" ]; then
  id=$(printf '%s' "$2" | cut -c 1-8)
fi
printf 'Starting background service\342\200\246\nbackgrounded \302\267 %s \302\267 %s\n' "$id" "$6"
EOF
# A codex that records how it was called and answers `exec resume` like Codex 0.166: an unknown
# chat (codex_gone) is "no rollout found", codex_fail any other early failure; otherwise the chat
# runs on (its listener waits), here for 4 seconds.
cat > "$T/bin/codex.fake" << 'EOF2'
#!/bin/sh
{ printf 'cwd=%s path=%s' "$(pwd -P)" "$PATH"; for a in "$@"; do printf ' |%s' "$a"; done; printf '\n'; } >> "$FAKE_DIR/codex_calls"
if [ "${1:-}" = plugin ]; then
  [ ! -e "$FAKE_DIR/codex_fail" ] || exit 1
  exit 0
fi
if [ -e "$FAKE_DIR/codex_gone" ]; then
  echo "Error: thread/resume: thread/resume failed: no rollout found for thread id $4 (code -32600)" >&2
  exit 1
fi
if [ -e "$FAKE_DIR/codex_fail" ]; then
  echo "Error: could not start" >&2
  exit 1
fi
echo "session id: $4"
sleep 4
EOF2
chmod 755 "$T/bin/curl" "$T/bin/claude" "$T/bin/codex.fake"
HOMEDIR=$(cd "$T/home" && pwd -P)
P1=$HOMEDIR/proj
P2=$HOMEDIR/proj2
SW=$HOMEDIR/.snapwork
CONNECT=https://space.snapwork.ai/c/
INVITE=https://space.snapwork.ai/j/
ROOM_A=aaaaaaaa-0000-4000-8000-000000000001
printf 'kfr-aaaa-0001|%s|Space A\n' "$ROOM_A" > "$T/fake/spaces"
for n in 2 3 4 5 6; do printf 'kfr-aaaa-000%s|aaaaaaaa-0000-4000-8000-00000000000%s|Space %s\n' "$n" "$n" "$n" >> "$T/fake/spaces"; done
: > "$T/fake/calls"
S1=11111111-aaaa-4000-8000-000000000001
S2=22222222-aaaa-4000-8000-000000000002
S3=33333333-aaaa-4000-8000-000000000003
ADD1=adadadad-0000-4000-8000-000000000001
FORK_ID=fee53b8c-6a51-45d3-8d48-980b9689f68a
TAB=$(printf '\t')

# Windows (Git Bash, where Claude Code runs hooks there) has no Unix file modes, and ln -s copies
# instead of linking: those checks are skipped there and counted.
case $(uname -s 2> /dev/null) in MINGW* | MSYS* | CYGWIN*) WINDOWS=1 ;; *) WINDOWS=0 ;; esac
SKIPPED=0
unix() { [ "$WINDOWS" -eq 0 ] || { SKIPPED=$((SKIPPED + 1)); return 1; }; }
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; [ -z "${2:-}" ] || printf '  output: %s\n' "$2"; }
has() { if grep -q -F -e "$2" "$T/out"; then ok; else bad "$1 (wanted: $2)" "$(cat "$T/out")"; fi; }
called() { if grep -q -F -e "$2" "$T/fake/calls"; then ok; else bad "$1 (no call: $2)" "$(cat "$T/fake/calls")"; fi; }
not_called() { if grep -q -F -e "$2" "$T/fake/calls"; then bad "$1 (unwanted call: $2)"; else ok; fi; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
reset() { : > "$T/fake/calls"; rm -f "$T/fake/claim_status" "$T/fake/claim_bodies" "$T/fake/connect_status" "$T/fake/key_refused" "$T/fake/claude_calls" "$T/fake/claude_untrusted" "$T/fake/work_status" "$T/fake/lookup_status" "$T/fake/lookup_runtime" "$T/fake/claude_nobg" "$T/fake/claude_copy" "$T/fake/agents_extra" "$T/fake/claude_stops" "$T/fake/claude_stopfail" "$T/fake/codex_calls" "$T/fake/codex_gone" "$T/fake/codex_fail"; }

transcript() { f=$T/tx/$1.jsonl; printf '{"type":"user","sessionId":"%s"}\n' "$1" > "$f"; printf '%s' "$f"; }
prompt() { printf '{"session_id":"%s","transcript_path":"%s","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"%s"}' "$1" "$2" "$3" "$4"; }
run() {
  # An empty and a relative entry on the chat's PATH: neither may reach the saved home.
  printf '%s' "$2" | env HOME="$HOMEDIR" SNAPWORK_HOME="$SW" PATH="$T/bin:.::$PATH" FAKE_DIR="$T/fake" \
    SNAPWORK_WATCH_SERVICE=test SNAPWORK_LISTEN_SECONDS=0 ${TEST_SH:-sh} "$PLUGIN" "$1" > "$T/out" 2> "$T/err"
}
watch() {
  env HOME="$HOMEDIR" SNAPWORK_HOME="$SW" PATH="$T/bin:/usr/bin:/bin" FAKE_DIR="$T/fake" SNAPWORK_WATCH_ONCE=1 \
    SNAPWORK_CODEX_START_S=2 SNAPWORK_CHATGPT_APP="${CHATGPT_APP:-$T/no-such-app}" SNAPWORK_WATCH_WAIT_S=0 ${TEST_SH:-sh} "$SW/snapwork-watch.sh" > "$T/out" 2> "$T/err"
  echo $? > "$T/rc"
}
# connect <session> <transcript> <folder> <code>: paste the link twice (look up, then confirm).
connect() {
  run prompt "$(prompt "$1" "$2" "$3" "${CONNECT}$4")"
  run prompt "$(prompt "$1" "$2" "$3" "${CONNECT}$4")"
}
work_line() { printf 'start\t%s\tclaude-code\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" > "$T/fake/work_lines"; }

TX1=$(transcript "$S1")
TX2=$(transcript "$S2")
TX3=$(transcript "$S3")

echo "== 0. the first paste only says whose account the link is"
run prompt "$(prompt "$S1" "$TX1" "$P1" "${CONNECT}kfr-cccc-0001")"
has "names the account" "belongs to the SnapWork account \"Minh Vo\" (m"
has "says what connecting allows" "start copies of this chat, working in this project folder, in its rooms"
has "says how to confirm" "paste the same link again to connect this chat"
called "looked it up" "connect-lookup kfr-cccc-0001"
not_called "nothing connected yet" "connect kfr-cccc-0001"
check "nothing saved yet" '[ ! -f "$SW/computer.json" ]'
run prompt "$(prompt "$S2" "$TX2" "$P2" "${CONNECT}kfr-cccc-0001")"
not_called "another chat's paste does not confirm" "connect kfr-cccc-0001"
has "it is asked again" "belongs to the SnapWork account"

echo "== 1. the same link again in the same chat makes it the agent's home"
reset
run prompt "$(prompt "$S1" "$TX1" "$P1" "${CONNECT}kfr-cccc-0001")"
run prompt "$(prompt "$S1" "$TX1" "$P1" "${CONNECT}kfr-cccc-0001")"
has "connected line" "connected. This chat is now the home of \"Claude\""
has "the person is told how to add it" "add \"Claude\" to any room you are in"
called "connect call" "connect kfr-cccc-0001"
check "the plugin names its app and the chat" 'grep -q "\"home_session\":\"$S1\",\"runtime\":\"claude-code\",\"folder\":\"proj\"" "$T/fake/connect_body"'
unix && check "computer key mode 600" '[ "$(ls -l "$SW/computer.json" | cut -c 1-10)" = "-rw-------" ]'
check "computer key saved" 'grep -q "swc_testcomputerkey123" "$SW/computer.json"'
check "home saved with its folder, command and PATH" 'grep -q "\"project\": \"$P1\"" "$SW/homes/$S1.json" && grep -q "\"runner\": \"$T/bin/claude\"" "$SW/homes/$S1.json" && grep -q "\"path\": \"$T/bin:" "$SW/homes/$S1.json"'
unix && check "home file mode 600" '[ "$(ls -l "$SW/homes/$S1.json" | cut -c 1-10)" = "-rw-------" ]'
unix && check "watcher copied, owner only" '[ "$(ls -l "$SW/snapwork-watch.sh" | cut -c 1-10)" = "-rwx------" ]'
check "home file is valid JSON" 'python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SW/homes/$S1.json"'
check "computer file is valid JSON" 'python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SW/computer.json"'

echo "== 2. a second connect on this computer sends its key, in curl's config only"
reset
connect "$S2" "$TX2" "$P2" kfr-cccc-0002
has "connected again" "connected."
check "key went through curl's config" 'grep -q "Bearer swc_testcomputerkey123" "$T/fake/stdin_last"'
not_called "never in argv" "KEY-IN-ARGV"
check "the saved key is kept" 'grep -q "swc_testcomputerkey123" "$SW/computer.json"'

echo "== 2b. a connect link from room.snapwork.ai (the new address) connects the same way"
reset
KEPT_CONNECT=$CONNECT
CONNECT=https://room.snapwork.ai/c/
connect "$S2" "$TX2" "$P2" kfr-cccc-0099
CONNECT=$KEPT_CONNECT
has "connected from the new address" "connected."
called "the connect went to SnapWork" "connect kfr-cccc-0099"

echo "== 3. a disconnected computer's key: connected again as a new computer"
reset
touch "$T/fake/key_refused"
connect "$S2" "$TX2" "$P2" kfr-cccc-0003
has "connected" "connected."
check "two connect calls (with the key, then without)" '[ "$(grep -c "^connect kfr-cccc-0003" "$T/fake/calls")" = 2 ]'

echo "== 4. refusals say what to do"
for pair in "404|was not found" "410|was used or has expired" "403|another SnapWork account" "409|a limit was reached" "400|made for another app" "500|SnapWork answered 500"; do
  reset
  printf '%s' "${pair%%|*}" > "$T/fake/connect_status"
  connect "$S3" "$TX3" "$P2" kfr-cccc-0004
  has "status ${pair%%|*}" "${pair#*|}"
done
check "no home saved after a refusal" '[ ! -f "$SW/homes/$S3.json" ]'
for pair in "404|was not found" "410|was used or has expired"; do
  reset
  printf '%s' "${pair%%|*}" > "$T/fake/lookup_status"
  run prompt "$(prompt "$S3" "$TX3" "$P2" "${CONNECT}kfr-cccc-0008")"
  has "look-up status ${pair%%|*}" "${pair#*|}"
done
reset
printf 'codex' > "$T/fake/lookup_runtime"
run prompt "$(prompt "$S3" "$TX3" "$P2" "${CONNECT}kfr-cccc-0009")"
has "a Codex link in Claude is refused at the look-up" "made for another app"
reset
run prompt "$(prompt "$S3" "$TX3" "$P2" "${CONNECT}kfr-cccc-0010")"
printf 'x %s 1\n' "$S3" > "$SW/connect-pending"
run prompt "$(prompt "$S3" "$TX3" "$P2" "${CONNECT}kfr-cccc-0010")"
not_called "an old or changed confirm does not connect" "connect kfr-cccc-0010"

echo "== 5. a link inside other text, the home folder, a chat in a space"
reset
run prompt "$(prompt "$S3" "$TX3" "$P2" "connect with ${CONNECT}kfr-cccc-0005 please")"
has "paste it alone" "paste the connect link on its own"
not_called "no connect for a link inside text" "connect kfr-cccc-0005"
connect "$S3" "$TX3" "$HOMEDIR" kfr-cccc-0006
has "home folder refused" "open a project folder first"
run prompt "$(prompt "$S3" "$TX3" "$P2" "${INVITE}kfr-aaaa-0001")"
reset
connect "$S3" "$TX3" "$P2" kfr-cccc-0007
has "a chat in a room is never a home" "this chat is in the room \"Space A\""
not_called "no connect from a chat in a room" "connect kfr-cccc-0007"

echo "== 6. the watcher forks the home chat with the invitation as the only prompt"
reset
work_line "$ADD1" "$S1" "${INVITE}kfr-bbbb-0001" "Design review v2"
watch
check "one fork" '[ "$(wc -l < "$T/fake/claude_calls" | tr -d " ")" = 1 ]'
check "in the home's own folder" 'grep -q "^cwd=$P1 " "$T/fake/claude_calls"'
check "with the chat's PATH" 'grep -q " path=$T/bin:" "$T/fake/claude_calls"'
check "only absolute folders on it" '! grep -q " path=[^ ]*::" "$T/fake/claude_calls" && ! grep -q " path=[^ ]*:\.:" "$T/fake/claude_calls"'
check "the fork command, exactly" 'grep -q -F " |--resume |$S1 |--fork-session |--bg |--name |Design review v2 |${INVITE}kfr-bbbb-0001" "$T/fake/claude_calls"'
called "reported started with the full id" "report $ADD1 {\"state\":\"started\",\"session_id\":\"$FORK_ID\"}"
not_called "the key never in argv" "KEY-IN-ARGV"
check "exits cleanly after one poll" '[ "$(cat "$T/rc")" = 0 ]'

echo "== 6b. an invitation on room.snapwork.ai (the new address) is forked the same way"
reset
work_line "$ADD1" "$S1" "https://room.snapwork.ai/j/kfr-bbbb-0001" "Design"
watch
check "forked with the new address's invitation" 'grep -q -F " |--resume |$S1 |--fork-session |--bg |--name |Design |https://room.snapwork.ai/j/kfr-bbbb-0001" "$T/fake/claude_calls"'

echo "== 7. the watcher's refusals"
reset
touch "$T/fake/claude_untrusted"
work_line "$ADD1" "$S1" "${INVITE}kfr-bbbb-0001" "Design"
watch
called "untrusted folder" "report $ADD1 {\"state\":\"failed\",\"failure\":\"not_trusted\"}"
reset
work_line "$ADD1" "99999999-aaaa-4000-8000-000000000009" "${INVITE}kfr-bbbb-0001" "Design"
watch
called "a home this computer never registered" "report $ADD1 {\"state\":\"failed\",\"failure\":\"home_gone\"}"
check "nothing forked for it" '[ ! -f "$T/fake/claude_calls" ]'
reset
work_line "$ADD1" "$S3" "${INVITE}kfr-bbbb-0001" "Design"
mkdir -p "$SW/homes" && printf '{\n  "session": "%s",\n  "project": "%s"\n}\n' "$S3" "$P2" > "$SW/homes/$S3.json"
watch
called "a home that is in a room is never forked" "report $ADD1 {\"state\":\"failed\",\"failure\":\"home_gone\"}"
check "nothing forked for the chat in a room" '[ ! -f "$T/fake/claude_calls" ]'
reset
work_line "$ADD1" "$S1" "https://evil.example.com/j/kfr-bbbb-0001" "Design"
watch
check "an invitation to another host is ignored" '[ ! -f "$T/fake/claude_calls" ]'
not_called "and not reported" "report $ADD1"
reset
work_line "$ADD1" "$S1" "${INVITE}kfr-bbbb-0001" '-rf $(touch pwned)'
watch
check "a name a shell would read is replaced" 'grep -q -F " |--name |SnapWork |" "$T/fake/claude_calls"'
check "nothing ran from the name" '[ ! -e "$P1/pwned" ] && [ ! -e "$HOMEDIR/pwned" ]'
reset
printf 'start\t%s\tcodex\t%s\t%s\tDesign\n' "$ADD1" "$S1" "${INVITE}kfr-bbbb-0001" > "$T/fake/work_lines"
watch
called "Codex is not forked yet (7.4)" "report $ADD1 {\"state\":\"failed\",\"failure\":\"no_runtime\"}"

echo "== 8. a refused key stops the watcher; one watcher per computer"
reset
printf '401' > "$T/fake/work_status"
watch
check "exits 0 on 401" '[ "$(cat "$T/rc")" = 0 ]'
check "logged" 'grep -q "key-refused" "$SW/watch.log"'
reset
sleep 30 &
holder=$!
printf '%s' "$holder" > "$SW/watch.lock"
watch
kill "$holder" 2> /dev/null
called "a lock held by something that is not a watcher is taken over" "work"
reset
cp "$SW/snapwork-watch.sh" "$T/snapwork-watch.sh"
if unix; then
  env HOME="$HOMEDIR" SNAPWORK_HOME="$T/other" sh -c 'sleep 30; :' snapwork-watch.sh &
  holder=$!
  printf '%s' "$holder" > "$SW/watch.lock"
  watch
  kill "$holder" 2> /dev/null
  not_called "a live watcher keeps its lock" "work"
fi
rm -f "$SW/watch.lock"

echo "== 10. a join by invitation on a connected computer makes the agent the person's (7.6)"
P3=$HOMEDIR/proj3
S4=44444444-aaaa-4000-8000-000000000004
S5=55555555-aaaa-4000-8000-000000000005
S6=66666666-aaaa-4000-8000-000000000006
S7=77777777-aaaa-4000-8000-000000000007
S8=88888888-aaaa-4000-8000-000000000008
home_id() { h=$(printf '%s' "$1" | sha256sum | cut -c 1-32); printf '%s-%s-%s-%s-%s' "$(echo "$h" | cut -c 1-8)" "$(echo "$h" | cut -c 9-12)" "$(echo "$h" | cut -c 13-16)" "$(echo "$h" | cut -c 17-20)" "$(echo "$h" | cut -c 21-32)"; }
HID2=$(home_id "$P2")
HID1=$(home_id "$P1")
reset
run prompt "$(prompt "$S4" "$(transcript "$S4")" "$P2" "${INVITE}kfr-aaaa-0002")"
has "joined as usual" "you just joined the room \"Space 2\""
called "and claimed" "claim"
check "the claim names the folder's home id, the folder and the app" 'grep -q "\"home\":\"$HID2\",\"folder\":\"proj2\",\"runtime\":\"claude-code\"" "$T/fake/claim_bodies"'
check "the claim carries the agent's key, in the body" 'grep -q "\"agent_key\":\"testkey" "$T/fake/claim_bodies"'
not_called "no key on the command line" "KEY-IN-ARGV"
check "the computer key went through curl's config" 'grep -q "Bearer swc_testcomputerkey123" "$T/fake/stdin_last"'
unix && check "the folder home is saved, owner only" '[ "$(ls -l "$SW/homes/$HID2.json" | cut -c 1-10)" = "-rw-------" ]'
check "it is a folder home with its full path" 'grep -q "\"kind\": \"folder\"" "$SW/homes/$HID2.json" && grep -q "\"project\": \"$P2\"" "$SW/homes/$HID2.json" && grep -q "\"home\": \"$HID2\"" "$SW/homes/$HID2.json"'
check "a folder home has no session (an old watcher finds no chat)" '! grep -q "\"session\"" "$SW/homes/$HID2.json"'
check "the folder home is valid JSON" 'python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SW/homes/$HID2.json"'
check "the room's connection says it was claimed" 'grep -q "\"claimed\": \"$HID2\"" "$SW"/rooms/aaaaaaaa-0000-4000-8000-000000000002.*.json'
check "the log says so, without the key" 'grep -q "claim-ok status=201" "$SW/plugin.log" && ! grep -q "testkey" "$SW/plugin.log"'

echo "== 10a2. a claim refreshes an older watcher copy (computers connected on 0.3.0)"
reset
sed -i.bak 's/^VERSION=.*/VERSION=0.3.0/' "$SW/snapwork-watch.sh" && rm -f "$SW/snapwork-watch.sh.bak"
# The watcher's starts above left its "starting" flag; minutes have passed since.
rm -f "$SW/watch.starting"
SA2=a2a2a2a2-aaaa-4000-8000-0000000000a2
printf 'kfr-aaaa-00a2|aaaaaaaa-0000-4000-8000-0000000000a2|Space A2\n' >> "$T/fake/spaces"
run prompt "$(prompt "$SA2" "$(transcript "$SA2")" "$P2" "${INVITE}kfr-aaaa-00a2")"
check "the watcher copy is the plugin's again" 'grep -q "^VERSION=0.3.13$" "$SW/snapwork-watch.sh"'
unix && check "and stays owner only" '[ "$(ls -l "$SW/snapwork-watch.sh" | cut -c 1-10)" = "-rwx------" ]'

echo "== 10b. another chat in the same folder: the same home id"
reset
run prompt "$(prompt "$S5" "$(transcript "$S5")" "$P2" "${INVITE}kfr-aaaa-0003")"
check "same home id for the same folder" 'grep -q "\"home\":\"$HID2\"" "$T/fake/claim_bodies"'

echo "== 10c. a refused claim never spoils the join"
reset
printf '409' > "$T/fake/claim_status"
run prompt "$(prompt "$S6" "$(transcript "$S6")" "$P3" "${INVITE}kfr-aaaa-0004")"
has "joined all the same" "you just joined the room \"Space 4\""
check "logged as refused" 'grep -q "claim-refused status=409" "$SW/plugin.log"'
check "no folder home kept for a refused claim" '[ ! -f "$SW/homes/$(home_id "$P3").json" ]'

echo "== 10d. a copy started by an add (a fork) does not claim"
reset
TXF=$T/tx/$S7.jsonl
printf '{"type":"user","sessionId":"%s"}\n{"type":"user","sessionId":"%s"}\n' "$S1" "$S7" > "$TXF"
run prompt "$(prompt "$S7" "$TXF" "$P1" "${INVITE}kfr-aaaa-0005")"
has "the copy joined" "joined"
not_called "no claim from a copy" "claim"
check "its connection says it is a copy" 'grep -q "\"copy\": \"1\"" "$(grep -l "\"session\": \"$S7\"" "$SW"/rooms/*.json | head -n 1)"'

echo "== 10e. no computer key: nothing is claimed and nothing leaves the computer"
reset
mv "$SW/computer.json" "$T/computer.json.kept"
run prompt "$(prompt "$S8" "$(transcript "$S8")" "$P3" "${INVITE}kfr-aaaa-0006")"
has "joined" "you just joined the room \"Space 6\""
not_called "no claim without a connected computer" "claim"
mv "$T/computer.json.kept" "$SW/computer.json"

echo "== 10f. a connect claims every chat already in a room on this computer, once"
reset
R9=aaaaaaaa-0000-4000-8000-000000000009
A9=00000000-0000-4000-8000-0000000000a9
printf '{\n  "session": "%s",\n  "app": "claude",\n  "project": "%s",\n  "gateway": "https://space.snapwork.ai",\n  "roomId": "%s",\n  "agentId": "%s",\n  "spaceName": "Old room",\n  "agentName": "Claude",\n  "key": "testkeyold9"\n}\n' "$S2" "$P1" "$R9" "$A9" > "$SW/rooms/$R9.$A9.json"
printf '{\n  "session": "%s",\n  "app": "claude",\n  "project": "%s",\n  "gateway": "https://evil.example.com",\n  "roomId": "%s",\n  "agentId": "%s",\n  "key": "testkeyevil"\n}\n' "$S2" "$P1" "$R9" "00000000-0000-4000-8000-0000000000b9" > "$SW/rooms/$R9.00000000-0000-4000-8000-0000000000b9.json"
printf '{\n  "session": "%s",\n  "app": "claude",\n  "project": "relative/folder",\n  "gateway": "https://space.snapwork.ai",\n  "roomId": "%s",\n  "agentId": "%s",\n  "key": "testkeyrel"\n}\n' "$S2" "$R9" "00000000-0000-4000-8000-0000000000c9" > "$SW/rooms/$R9.00000000-0000-4000-8000-0000000000c9.json"
printf '{\n  "session": "%s",\n  "app": "claude",\n  "copy": "1",\n  "project": "%s",\n  "gateway": "https://space.snapwork.ai",\n  "roomId": "%s",\n  "agentId": "%s",\n  "key": "testkeycopy"\n}\n' "$S2" "$P1" "$R9" "00000000-0000-4000-8000-0000000000d9" > "$SW/rooms/$R9.00000000-0000-4000-8000-0000000000d9.json"
chmod 600 "$SW"/rooms/*.json
S9=99999999-aaaa-4000-8000-000000000099
mkdir -p "$HOMEDIR/proj9"
connect "$S9" "$(transcript "$S9")" "$HOMEDIR/proj9" kfr-cccc-0090
has "connected" "connected."
called "the chats already in rooms are claimed" "claim"
check "a chat that joined while the computer was not connected is claimed now" 'grep -q "\"home\":\"$(home_id "$P3")\"" "$T/fake/claim_bodies"'
check "never a relative folder" '! grep -q "testkeyrel" "$T/fake/claim_bodies"'
check "for the old room's chat and folder" 'grep -q "\"agent_key\":\"testkeyold9\",\"home\":\"$HID1\"" "$T/fake/claim_bodies"'
check "never another host's key" '! grep -q "testkeyevil" "$T/fake/claim_bodies"'
check "never a copy started by an add" '! grep -q "testkeycopy" "$T/fake/claim_bodies"'
not_called "no key on the command line" "KEY-IN-ARGV"
reset
connect "$S9" "$(transcript "$S9")" "$HOMEDIR/proj9" kfr-cccc-0091
not_called "a second connect claims nothing again" "claim"

echo "== 10f2. already yours (200): marked claimed, but no folder home is made"
reset
P10=$HOMEDIR/proj10
mkdir -p "$P10"
S10=10101010-aaaa-4000-8000-000000000010
printf 'kfr-aaaa-0010|aaaaaaaa-0000-4000-8000-000000000010|Space 10\n' >> "$T/fake/spaces"
printf '200' > "$T/fake/claim_status"
run prompt "$(prompt "$S10" "$(transcript "$S10")" "$P10" "${INVITE}kfr-aaaa-0010")"
called "claimed" "claim"
check "no folder home for an agent that was already the person's" '[ ! -f "$SW/homes/$(home_id "$P10").json" ]'
check "but its connection is marked, so it is not asked again" 'grep -q "\"claimed\": \"$(home_id "$P10")\"" "$SW"/rooms/aaaaaaaa-0000-4000-8000-000000000010.*.json'

echo "== 10f3. a claim records the claimed chat's own app's command, whatever chat connected"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/codex" && chmod 755 "$T/bin/codex"
runner=$(env PATH="$T/bin:/usr/bin:/bin" APP=codex GATEWAY=https://space.snapwork.ai SNAPWORK_HOME="$SW" ${TEST_SH:-sh} -c '. "$1"; claim_runner claude' sh "$(dirname "$PLUGIN")/snapwork-connect.sh")
check "a Claude chat's runner is claude, not the connecting chat's app" '[ "$runner" = "$T/bin/claude" ]'
runner=$(env PATH="$T/bin:/usr/bin:/bin" APP=claude GATEWAY=https://space.snapwork.ai SNAPWORK_HOME="$SW" ${TEST_SH:-sh} -c '. "$1"; claim_runner codex' sh "$(dirname "$PLUGIN")/snapwork-connect.sh")
check "a Codex chat's runner is codex (codex_comes_back_through_its_daemon)" '[ "$runner" = "$T/bin/codex" ]'
rm -f "$T/bin/codex"

echo "== 10f4. a connect claims a Codex chat already in a room, as Codex"
reset
RC=aaaaaaaa-0000-4000-8000-0000000000c1
AC=00000000-0000-4000-8000-0000000000c1
PC=$HOMEDIR/projc
mkdir -p "$PC"
cp "$T/bin/codex.fake" "$T/bin/codex"
printf '{\n  "session": "%s",\n  "app": "codex",\n  "project": "%s",\n  "gateway": "https://space.snapwork.ai",\n  "roomId": "%s",\n  "agentId": "%s",\n  "spaceName": "Codex room",\n  "agentName": "Codex",\n  "key": "testkeycodexc1"\n}\n' "$S2" "$PC" "$RC" "$AC" > "$SW/rooms/$RC.$AC.json"
chmod 600 "$SW/rooms/$RC.$AC.json"
S11=11111111-cccc-4000-8000-000000000011
mkdir -p "$HOMEDIR/proj11"
connect "$S11" "$(transcript "$S11")" "$HOMEDIR/proj11" kfr-cccc-0110
check "the Codex chat is claimed as codex" 'grep -q "\"agent_key\":\"testkeycodexc1\",\"home\":\"$(home_id "$PC")\",\"folder\":\"projc\",\"runtime\":\"codex\"" "$T/fake/claim_bodies"'
check "its folder home is Codex's own file, with codex as its command" 'grep -q "\"app\": \"codex\"" "$SW/homes/$(home_id "$PC").codex.json" && grep -q "\"runner\": \"$T/bin/codex\"" "$SW/homes/$(home_id "$PC").codex.json"'
rm -f "$T/bin/codex"

echo "== 10f5. a chat the watcher brings back outlives the watcher's own restart"
# The service files as written for each system, with stand-ins for systemctl and launchctl.
SV=$T/service
mkdir -p "$SV/bin" "$SV/home"
printf '#!/bin/sh\nexit 0\n' > "$SV/bin/systemctl"
printf '#!/bin/sh\nexit 0\n' > "$SV/bin/launchctl"
chmod 755 "$SV/bin/systemctl" "$SV/bin/launchctl"
env PATH="$SV/bin:/usr/bin:/bin" HOME="$SV/home" XDG_CONFIG_HOME="$SV/xdg" GATEWAY=https://space.snapwork.ai \
  SNAPWORK_HOME="$SV/home/.snapwork" ${TEST_SH:-sh} -c '. "$1"; install_systemd; install_launchd' sh \
  "$(dirname "$PLUGIN")/snapwork-connect.sh" > /dev/null 2>&1
check "systemd stops only the watcher, never the chats it started" 'grep -q "^KillMode=process$" "$SV/xdg/systemd/user/snapwork-watch.service"'
check "launchd leaves the chats it started running too" 'grep -q "<key>AbandonProcessGroup</key><true/>" "$SV/home/Library/LaunchAgents/"*.plist'

echo "== 10g. the watcher starts a fresh chat for a folder home (no copy)"
reset
printf 'start\t%s\tclaude-code\t%s\t%s\tRoom B\tfolder\n' "$ADD1" "$HID2" "${INVITE}kfr-bbbb-0002" > "$T/fake/work_lines"
watch
check "one fresh chat" '[ "$(wc -l < "$T/fake/claude_calls" | tr -d " ")" = 1 ]'
check "in the folder" 'grep -q "^cwd=$P2 " "$T/fake/claude_calls"'
check "the fresh chat command, exactly (no --resume)" 'grep -q -F " |--bg |--name |Room B |${INVITE}kfr-bbbb-0002" "$T/fake/claude_calls" && ! grep -q -F "resume" "$T/fake/claude_calls"'
called "reported started" "report $ADD1 {\"state\":\"started\",\"session_id\":\"$FORK_ID\"}"
reset
printf 'start\t%s\tclaude-code\t%s\t%s\tRoom B\tchat\n' "$ADD1" "$S1" "${INVITE}kfr-bbbb-0002" > "$T/fake/work_lines"
watch
check "a chat home with the 7th field is forked as before" 'grep -q -F " |--resume |$S1 |--fork-session |--bg |--name |Room B |" "$T/fake/claude_calls"'

echo "== 10h. folder home refusals"
reset
printf 'start\t%s\tclaude-code\t%s\t%s\tRoom B\tfolder\n' "$ADD1" "$S1" "${INVITE}kfr-bbbb-0002" > "$T/fake/work_lines"
watch
called "a chat home named as a folder home is refused" "report $ADD1 {\"state\":\"failed\",\"failure\":\"home_gone\"}"
check "nothing started" '[ ! -f "$T/fake/claude_calls" ]'
reset
printf 'start\t%s\tclaude-code\t%s\t%s\tRoom B\tchat\n' "$ADD1" "$HID2" "${INVITE}kfr-bbbb-0002" > "$T/fake/work_lines"
watch
called "a folder home named as a chat is refused (an old watcher's view)" "report $ADD1 {\"state\":\"failed\",\"failure\":\"home_gone\"}"
reset
HIDX=12345678-1234-1234-1234-123456789abc
printf '{\n  "kind": "folder",\n  "home": "%s",\n  "project": "relative/proj"\n}\n' "$HIDX" > "$SW/homes/$HIDX.json"
printf 'start\t%s\tclaude-code\t%s\t%s\tRoom B\tfolder\n' "$ADD1" "$HIDX" "${INVITE}kfr-bbbb-0002" > "$T/fake/work_lines"
watch
called "a relative folder is refused" "report $ADD1 {\"state\":\"failed\",\"failure\":\"home_gone\"}"
reset
printf '{\n  "kind": "folder",\n  "home": "%s",\n  "project": "%s/gone"\n}\n' "$HIDX" "$HOMEDIR" > "$SW/homes/$HIDX.json"
watch
called "a missing folder is refused" "report $ADD1 {\"state\":\"failed\",\"failure\":\"home_gone\"}"
check "nothing started for them" '[ ! -f "$T/fake/claude_calls" ]'
check "the watcher says it is 0.3.13" 'grep -q "^VERSION=0.3.13$" "$SW/snapwork-watch.sh"'
check "the connect script and the watcher name the same version" '[ "$(sed -n "s/^WATCH_VERSION=//p" "$SCRIPTS/snapwork-connect.sh")" = "$(sed -n "s/^VERSION=//p" "$SCRIPTS/snapwork-watch.sh")" ]'

echo "== 11. the watcher brings a chat in a room back (7.5)"
# The tests never look at a real Claude config folder.
unset CLAUDE_CONFIG_DIR
RV=e7e7e7e7-0000-4000-8000-000000000001
RSP=bbbbbbbb-0000-4000-8000-000000000011
RAG=00000000-0000-4000-8000-0000000000e1
RS=abcdef01-aaaa-4000-8000-0000000000e1
REVIVE_PROMPT='SnapWork brought you back: messages wait for you in your room. Read them and answer.'
# room_file <path> <session> <project> [<app>] [<agent id>]: a connection as the plugin saves it.
room_file() {
  printf '{\n  "session": "%s",\n  "app": "%s",\n  "setup": "x",\n  "project": "%s",\n  "gateway": "https://space.snapwork.ai",\n  "roomId": "%s",\n  "agentId": "%s",\n  "spaceName": "Room R",\n  "agentName": "Claude",\n  "key": "testkeyrevive"\n}\n' \
    "$2" "${4:-claude}" "$3" "$RSP" "${5:-$RAG}" > "$1"
  chmod 600 "$1"
}
RSTATE=$SW/rooms/$RSP.$RAG.json
room_file "$RSTATE" "$RS" "$P1"
revive_line() { printf 'revive\t%s\t%s\t%s\t%s\t%s\n' "$1" "${5:-claude-code}" "$2" "$3" "$4" > "$T/fake/work_lines"; }
# The arguments claude got, after its folder and PATH.
claude_args() { sed -n "${1:-1}p" "$T/fake/claude_calls" | sed 's/^cwd=[^ ]* path=[^ ]*//'; }
nothing_ran() { check "$1: nothing started" '[ ! -f "$T/fake/claude_calls" ]'; }
revival() { called "$1" "revival $RV {\"state\":\"failed\",\"failure\":\"$2\"}"; }

reset
revive_line "$RV" "$RSP" "$RAG" "Room R"
watch
check "one chat started" '[ "$(wc -l < "$T/fake/claude_calls" | tr -d " ")" = 1 ]'
check "in the chat's own folder" 'grep -q "^cwd=$P1 " "$T/fake/claude_calls"'
check "with the PATH its home recorded" 'grep -q " path=$T/bin:" "$T/fake/claude_calls"'
check "the resume command, exactly: the saved chat, the label, the fixed prompt" '[ "$(claude_args)" = " |--resume |$RS |--bg |--name |Room R |$REVIVE_PROMPT" ]'
check "no id from SnapWork reaches the command" '! grep -q -e "$RV" -e "$RSP" -e "$RAG" "$T/fake/claude_calls"'
called "reported started with the chat's id" "revival $RV {\"state\":\"started\",\"session_id\":\"$RS\"}"
not_called "not reported as an add" "report $RV"
check "the poll says the watcher knows Codex revivals too (v=0.3.13)" 'grep -q "[?&]v=0.3.13$" "$T/fake/work_url"'
check "logged with short ids only" 'grep -q "revive id=e7e7e7e7 session=abcdef01$" "$SW/watch.log" && grep -q "started revive=e7e7e7e7 session=abcdef01" "$SW/watch.log"'
check "the room's name is not logged" '! grep -q "Room R" "$SW/watch.log"'
check "the watcher marked that it was starting a chat, owner only" '[ -f "$SW/watch.starting" ] && { [ "$WINDOWS" -eq 1 ] || [ "$(ls -l "$SW/watch.starting" | cut -c 1-10)" = "-rw-------" ]; }'
check "the log keeps no full id" '! grep -q "$RS" "$SW/watch.log" && ! grep -q "$RV" "$SW/watch.log"'
not_called "the key never in argv" "KEY-IN-ARGV"
check "the computer key went through curl's config" 'grep -q "Bearer swc_testcomputerkey123" "$T/fake/stdin_last"'

echo "== 11a. what a revive line can and cannot change"
reset
revive_line "$RV" "$RSP" "$RAG" '-rf $(touch pwned)'
watch
check "a label a shell or a flag would read is replaced" '[ "$(claude_args)" = " |--resume |$RS |--bg |--name |SnapWork |$REVIVE_PROMPT" ]'
check "nothing ran from the label" '[ ! -e "$P1/pwned" ] && [ ! -e "$HOMEDIR/pwned" ]'
reset
printf 'revive\t%s\tclaude-code\t%s\t%s\tRoom R\tsomething new\n' "$RV" "$RSP" "$RAG" > "$T/fake/work_lines"
watch
check "a field this watcher does not know yet is dropped" '[ "$(claude_args)" = " |--resume |$RS |--bg |--name |Room R |$REVIVE_PROMPT" ]'
reset
revive_line "not-a-uuid" "$RSP" "$RAG" "Room R"
watch
nothing_ran "a bad revive id"
not_called "and nothing reported for it" "revival"
check "logged" 'grep -q "bad-item" "$SW/watch.log"'
reset
revive_line "$RV" "../../etc" "$RAG" "Room R"
watch
nothing_ran "a bad room id"
revival "a bad room id is a chat this computer does not have" chat_gone
reset
revive_line "$RV" "$RSP" "$RAG/../x" "Room R"
watch
nothing_ran "a bad agent id"
revival "a bad agent id too" chat_gone

reset
room_file "$RSTATE" "-bcdef01-aaaa-4000-8000-0000000000e1" "$P1"
revive_line "$RV" "$RSP" "$RAG" "Room R"
watch
nothing_ran "a saved chat id that starts with a dash (it would read as a flag)"
revival "and it counts as no chat" chat_gone
room_file "$RSTATE" "$RS" "$P1"

echo "== 11b. older lines still work next to revive lines; unknown ones are skipped"
reset
{
  printf 'start\t%s\tclaude-code\t%s\t%s\tDesign\n' "$ADD1" "$S1" "${INVITE}kfr-bbbb-0001"
  printf 'later\tsomething\tthis\twatcher\tdoes\tnot\tknow\n'
  printf 'revive\t%s\tclaude-code\t%s\t%s\tRoom R\n' "$RV" "$RSP" "$RAG"
  printf 'start\t%s\tclaude-code\t%s\t%s\tRoom B\tfolder\n' "$ADD1" "$HID2" "${INVITE}kfr-bbbb-0002"
} > "$T/fake/work_lines"
watch
check "three chats started" '[ "$(wc -l < "$T/fake/claude_calls" | tr -d " ")" = 3 ]'
check "a start line without the 7th field is still a fork" '[ "$(claude_args 1)" = " |--resume |$S1 |--fork-session |--bg |--name |Design |${INVITE}kfr-bbbb-0001" ]'
check "the revive in between" '[ "$(claude_args 2)" = " |--resume |$RS |--bg |--name |Room R |$REVIVE_PROMPT" ]'
check "a folder start after it" '[ "$(claude_args 3)" = " |--bg |--name |Room B |${INVITE}kfr-bbbb-0002" ]'
called "the add reported" "report $ADD1 {\"state\":\"started\",\"session_id\":\"$FORK_ID\"}"
called "the revival reported" "revival $RV {\"state\":\"started\",\"session_id\":\"$RS\"}"

echo "== 11c. chat_gone: no saved chat, folder or connection"
reset
revive_line "$RV" "$RSP" "00000000-0000-4000-8000-0000000000e9" "Room R"
watch
nothing_ran "an agent this computer never saved"
revival "an agent this computer never saved" chat_gone
reset
room_file "$RSTATE" "" "$P1"
revive_line "$RV" "$RSP" "$RAG" "Room R"
watch
nothing_ran "a connection with no chat"
revival "a connection with no chat (freed by /clear, or a one-line setup)" chat_gone
reset
room_file "$RSTATE" "$RS" "relative/proj"
watch
revival "a relative folder" chat_gone
reset
room_file "$RSTATE" "$RS" "$HOMEDIR/gone"
watch
nothing_ran "a folder that is gone"
revival "a folder that is gone" chat_gone
reset
room_file "$RSTATE" "$RS" "$P1"
sed 's/"roomId": "[^"]*"/"roomId": "bbbbbbbb-0000-4000-8000-000000000099"/' "$RSTATE" > "$T/other.json" && cp "$T/other.json" "$RSTATE"
watch
nothing_ran "a connection that names another room"
revival "a connection that names another room" chat_gone
room_file "$RSTATE" "$RS" "$P1"
if unix; then
  reset
  mv "$RSTATE" "$T/real.json"
  ln -s "$T/real.json" "$RSTATE"
  watch
  nothing_ran "a linked connection"
  revival "a linked connection is never read" chat_gone
  rm -f "$RSTATE"
  mv "$T/real.json" "$RSTATE"
fi

echo "== 11d. a room-only connection, only when it names that agent"
RSP2=bbbbbbbb-0000-4000-8000-000000000022
RAG2=00000000-0000-4000-8000-0000000000e2
RS2=abcdef02-aaaa-4000-8000-0000000000e2
reset
printf '{\n  "session": "%s",\n  "project": "%s",\n  "roomId": "%s",\n  "agentId": "%s",\n  "key": "testkeyroomonly"\n}\n' "$RS2" "$P2" "$RSP2" "$RAG2" > "$SW/rooms/$RSP2.json"
revive_line "$RV" "$RSP2" "$RAG2" "Room 2"
watch
check "resumed from the room-only connection, in its folder" 'grep -q "^cwd=$P2 " "$T/fake/claude_calls" && [ "$(claude_args)" = " |--resume |$RS2 |--bg |--name |Room 2 |$REVIVE_PROMPT" ]'
reset
revive_line "$RV" "$RSP2" "00000000-0000-4000-8000-0000000000e3" "Room 2"
watch
nothing_ran "a room-only connection of another agent"
revival "a room-only connection of another agent" chat_gone
rm -f "$SW/rooms/$RSP2.json"

echo "== 11e. no_runtime"
reset
revive_line "$RV" "$RSP" "$RAG" "Room R" codex
watch
nothing_ran "a Codex line for a chat saved as Claude's"
revival "the app SnapWork names must be the chat's own" no_runtime
reset
room_file "$RSTATE" "$RS" "$P1" codex
revive_line "$RV" "$RSP" "$RAG" "Room R"
watch
nothing_ran "a Codex chat saved here"
revival "a chat this computer saved as Codex's" no_runtime
room_file "$RSTATE" "$RS" "$P1"
reset
mv "$T/bin/claude" "$T/claude.kept"
watch
mv "$T/claude.kept" "$T/bin/claude"
revival "no claude on this computer" no_runtime

echo "== 11f. busy: it is still running"
reset
printf ',{"sessionId": "%s","kind":"interactive"}' "$RS" > "$T/fake/agents_extra"
watch
nothing_ran "a chat Claude lists"
revival "a chat Claude lists as running" busy
check "logged why" 'grep -q "busy why=listed" "$SW/watch.log"'
reset
mkdir -p "$HOMEDIR/.claude/projects/-proj"
TXR=$HOMEDIR/.claude/projects/-proj/$RS.jsonl
printf '{"type":"user"}\n' > "$TXR"
watch
nothing_ran "a chat whose transcript just changed"
revival "a chat whose transcript changed in the last 10 minutes" busy
reset
age() { python3 -c "import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))" "$1" "$2"; }
age "$TXR" 120
watch
nothing_ran "a transcript changed 2 minutes ago"
revival "a transcript changed 2 minutes ago" busy
reset
age "$TXR" 300
watch
called "a transcript 5 minutes old does not hold it back (3 minutes)" "revival $RV {\"state\":\"started\",\"session_id\":\"$RS\"}"
reset
touch -t 202001010000 "$TXR"
watch
called "an old transcript does not hold it back" "revival $RV {\"state\":\"started\",\"session_id\":\"$RS\"}"
reset
mkdir -p "$T/cfg/projects/-proj"
printf '{"type":"user"}\n' > "$T/cfg/projects/-proj/$RS.jsonl"
CLAUDE_CONFIG_DIR=$T/cfg
export CLAUDE_CONFIG_DIR
watch
unset CLAUDE_CONFIG_DIR
nothing_ran "a transcript under CLAUDE_CONFIG_DIR"
revival "CLAUDE_CONFIG_DIR is where Claude keeps transcripts" busy
reset
touch "$T/fake/claude_copy"
watch
revival "Claude made a copy (it was running after all)" busy
check "logged as a copy" 'grep -q "copy-started revive=e7e7e7e7 session=fee53b8c" "$SW/watch.log"'
not_called "never reported as started" "revival $RV {\"state\":\"started\""
check "the copy is stopped by its full id" '[ "$(cat "$T/fake/claude_stops")" = "stop |$FORK_ID" ]'
check "never the chat itself" '! grep -q "$RS" "$T/fake/claude_stops"'
check "logged as stopped" 'grep -q "copy-stopped revive=e7e7e7e7 session=fee53b8c" "$SW/watch.log"'
reset
touch "$T/fake/claude_copy" "$T/fake/claude_stopfail"
watch
revival "a copy that would not stop" busy
check "logged as left running" 'grep -q "copy-left-running revive=e7e7e7e7 session=fee53b8c" "$SW/watch.log"'
reset
check "no stop when the chat came back as itself" 'watch; [ ! -f "$T/fake/claude_stops" ]'
LISTENER=$SW/rooms/$RSP.$RAG.listener
# A stand-in listener and the sleep under it: none is left running.
stop_holder() { pkill -P "$holder" 2> /dev/null; kill "$holder" 2> /dev/null; }
if unix; then
  reset
  sh -c 'sleep 30; :' "$T/snapwork-hook.sh" --event Stop --rewake --room "$RSP" --agent "$RAG" &
  holder=$!
  printf '%s Mon Nov  3 10:00:00 2026\n' "$holder" > "$LISTENER"
  watch
  stop_holder
  nothing_ran "a live listener"
  revival "its listener holds the lock" busy
  check "logged why" 'grep -q "busy why=listener" "$SW/watch.log"'
  reset
  sleep 30 &
  holder=$!
  printf '%s Mon Nov  3 10:00:00 2026\n' "$holder" > "$LISTENER"
  watch
  stop_holder
  called "a lock held by something that is not its listener does not hold it back" "revival $RV {\"state\":\"started\""
  reset
  sh -c 'sleep 30; :' "$T/snapwork-hook.sh" --room "$RSP2" &
  holder=$!
  printf '%s x\n' "$holder" > "$LISTENER"
  watch
  stop_holder
  called "nor a listener of another room" "revival $RV {\"state\":\"started\""
  reset
  # A chat open in a terminal (claude --resume <id>), with no listener and not in Claude's list.
  sh -c 'sleep 30; :' claude --resume "$RS" &
  holder=$!
  watch
  stop_holder
  nothing_ran "a process that names the chat"
  revival "a process that names the chat (open in a terminal)" busy
  check "logged why" 'grep -q "busy why=process" "$SW/watch.log"'
fi
reset
printf '99999999 x\n' > "$LISTENER"
watch
called "a lock left by a listener that is gone does not hold it back" "revival $RV {\"state\":\"started\""
rm -f "$LISTENER"

echo "== 11g. not_trusted and start_failed"
reset
touch "$T/fake/claude_untrusted"
watch
revival "an untrusted folder" not_trusted
reset
touch "$T/fake/claude_nobg"
watch
revival "no id printed" start_failed
check "the watcher says it knows revivals on its poll" 'grep -q "^VERSION=0.3.13$" "$SW/snapwork-watch.sh"'

echo "== 11i. a Codex chat comes back through Codex's own daemon (codex_comes_back_through_its_daemon)"
codex_args() { sed -n "${1:-1}p" "$T/fake/codex_calls" | sed 's/^cwd=[^ ]* path=[^ ]*//'; }
room_file "$RSTATE" "$RS" "$P1" codex
cp "$T/bin/codex.fake" "$T/bin/codex"
for bad in / "$HOMEDIR"; do
  reset
  room_file "$RSTATE" "$RS" "$bad" codex
  revive_line "$RV" "$RSP" "$RAG" "Room R" codex
  watch
  check "never in $bad (no git guard there)" '[ ! -f "$T/fake/codex_calls" ]'
  revival "a chat saved for $bad counts as no chat" chat_gone
done
room_file "$RSTATE" "$RS" "$P1" codex
reset
revive_line "$RV" "$RSP" "$RAG" "Room R" codex
watch
check "one start, no claude" '[ "$(wc -l < "$T/fake/codex_calls" | tr -d " ")" = 1 ] && [ ! -f "$T/fake/claude_calls" ]'
check "in the chat's own folder" 'grep -q "^cwd=$P1 " "$T/fake/codex_calls"'
check "the command, exactly: the saved chat resumed headless with the fixed prompt" '[ "$(codex_args)" = " |exec |--skip-git-repo-check |resume |$RS |$REVIVE_PROMPT" ]'
check "nothing the chat prints is kept on disk" '! grep -rq "session id:" "$SW" 2> /dev/null'
check "no id from SnapWork and no label reach the command" '! grep -q -e "$RV" -e "$RSP" -e "$RAG" -e "Room R" "$T/fake/codex_calls"'
called "reported started with the chat's id" "revival $RV {\"state\":\"started\",\"session_id\":\"$RS\"}"
check "logged with short ids only" 'grep -q "started revive=e7e7e7e7 session=abcdef01" "$SW/watch.log" && ! grep -q "$RS" "$SW/watch.log"'
check "the chat is still running when the watcher has reported (its listener waits)" 'ps -A -o args= | grep -v grep | grep -q "exec --skip-git-repo-check resume $RS"'
# The fake chat ends after 4 seconds; until then the watcher rightly calls it busy.
sleep 4
reset
touch "$T/fake/codex_gone"
revive_line "$RV" "$RSP" "$RAG" "Room R" codex
watch
revival "a chat Codex no longer has" chat_gone
reset
touch "$T/fake/codex_fail"
revive_line "$RV" "$RSP" "$RAG" "Room R" codex
watch
revival "any other failure" start_failed
sleep 4
reset
mkdir -p "$HOMEDIR/.codex/sessions/2026/11/05"
touch "$HOMEDIR/.codex/sessions/2026/11/05/rollout-2026-11-05T17-01-18-$RS.jsonl"
revive_line "$RV" "$RSP" "$RAG" "Room R" codex
watch
check "a chat Codex wrote to in the last minutes is not started again" '[ ! -f "$T/fake/codex_calls" ]'
revival "it is busy" busy
rm -rf "$HOMEDIR/.codex"
reset
revive_line "$RV" "$RSP" "$RAG" "Room R" claude-code
watch
check "a Claude line for a chat saved as Codex's runs nothing" '[ ! -f "$T/fake/codex_calls" ] && [ ! -f "$T/fake/claude_calls" ]'
revival "and says so" no_runtime
rm -f "$T/bin/codex"
reset
revive_line "$RV" "$RSP" "$RAG" "Room R" codex
watch
revival "no codex on this computer" no_runtime
reset
CHATGPT_APP=$T/apps/ChatGPT.app
mkdir -p "$CHATGPT_APP/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS"
cp "$T/bin/codex.fake" "$CHATGPT_APP/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
revive_line "$RV" "$RSP" "$RAG" "Room R" codex
watch
check "on a Mac with only the ChatGPT app, its own codex brings the chat back" '[ "$(codex_args)" = " |exec |--skip-git-repo-check |resume |$RS |$REVIVE_PROMPT" ]'
called "and it is reported started" "revival $RV {\"state\":\"started\",\"session_id\":\"$RS\"}"
CHATGPT_APP=
rm -rf "$T/apps"
sleep 4
room_file "$RSTATE" "$RS" "$P1"

echo "== 11h. a chat starting on a connected computer brings an older watcher copy up to date"
S12=12121212-aaaa-4000-8000-000000000012
start_chat() { run start "{\"session_id\":\"$1\",\"transcript_path\":\"$2\",\"cwd\":\"$P2\",\"hook_event_name\":\"SessionStart\",\"source\":\"${3:-startup}\"}"; }
set_watch_version() { sed -i.bak "s/^VERSION=.*/VERSION=$1/" "$SW/snapwork-watch.sh" && rm -f "$SW/snapwork-watch.sh.bak"; }
reset
rm -f "$SW/watch.starting" "$SW/watch-refresh.stamp"
set_watch_version 0.3.2
touch "$SW/watch.starting"
start_chat "$S12" "$(transcript "$S12")"
check "not while the watcher is starting a chat (or just did)" 'grep -q "^VERSION=0.3.2$" "$SW/snapwork-watch.sh" && grep -q "watcher-refresh-later why=starting" "$SW/plugin.log"'
check "and that is not counted for the hourly limit" '[ ! -f "$SW/watch-refresh.stamp" ]'
age "$SW/watch.starting" 600
start_chat "$S12" "$(transcript "$S12")"
check "the watcher copy is this plugin's again" 'grep -q "^VERSION=0.3.13$" "$SW/snapwork-watch.sh"'
check "logged" 'grep -q "watcher-refreshed to=0.3.13" "$SW/plugin.log"'
check "the chat is told nothing about it" '! grep -q -i "watcher" "$T/out"'
unix && check "the hourly stamp is owner only" '[ "$(ls -l "$SW/watch-refresh.stamp" | cut -c 1-10)" = "-rw-------" ]'
: > "$SW/plugin.log"
start_chat "$S12" "$(transcript "$S12")"
check "the same version is left alone" '! grep -q "watcher-refreshed" "$SW/plugin.log"'
set_watch_version 0.3.2
start_chat "$S12" "$(transcript "$S12")"
check "at most once an hour" 'grep -q "^VERSION=0.3.2$" "$SW/snapwork-watch.sh"'
age "$SW/watch-refresh.stamp" 3700
S13=13131313-aaaa-4000-8000-000000000013
TXC=$T/tx/$S13.jsonl
printf '{"type":"user","sessionId":"%s","forkedFrom":{"sessionId":"%s"}}\n' "$S13" "$S12" > "$TXC"
start_chat "$S13" "$TXC" resume
check "never from a copy (/fork, or a chat the watcher started)" 'grep -q "^VERSION=0.3.2$" "$SW/snapwork-watch.sh"'
start_chat "$S12" "$(transcript "$S12")" startup
check "after an hour, again" 'grep -q "^VERSION=0.3.13$" "$SW/snapwork-watch.sh"'
rm -f "$SW/watch-refresh.stamp"
set_watch_version 0.3.99
: > "$SW/plugin.log"
start_chat "$S12" "$(transcript "$S12")"
check "a newer copy (the other app's plugin) is never taken back" 'grep -q "^VERSION=0.3.99$" "$SW/snapwork-watch.sh" && ! grep -q "watcher-refreshed" "$SW/plugin.log"'
reset
connect "$S9" "$(transcript "$S9")" "$HOMEDIR/proj9" kfr-cccc-0092
has "connected" "connected."
check "nor by a connect" 'grep -q "^VERSION=0.3.99$" "$SW/snapwork-watch.sh" && grep -q "watcher-kept version=0.3.99" "$SW/plugin.log"'
set_watch_version 0.3.13

echo "== 11j. the watcher updates the SnapWork plugin (7.9, plugins_update_from_the_watcher)"
UP=f1f1f1f1-0000-4000-8000-000000000001
update_line() { printf 'update\t%s\t%s\t%s\n' "$1" "$2" "$3" > "$T/fake/work_lines"; }
reset
update_line "$UP" claude-code 0.3.13
watch
check "claude refreshes the snapwork marketplace, then updates the plugin" '[ "$(claude_args 1)" = " |plugin |marketplace |update |snapwork" ] && [ "$(claude_args 2)" = " |plugin |update |snapwork@snapwork" ]'
check "never marketplace add (it drops the auto-update setting)" '! grep -q " |marketplace |add" "$T/fake/claude_calls"'
check "from ~/.snapwork, with the PATH a home recorded" 'grep -q "^cwd=$SW " "$T/fake/claude_calls" && grep -q " path=$T/bin:" "$T/fake/claude_calls"'
called "reported done" "update $UP {\"state\":\"done\"}"
check "logged with short ids" 'grep -q "update id=f1f1f1f1 app=claude to=0.3.13" "$SW/watch.log" && grep -q "updated id=f1f1f1f1 app=claude" "$SW/watch.log"'
reset
touch "$T/fake/claude_nobg"
update_line "$UP" claude-code 0.3.13
watch
called "a failing update says so" "update $UP {\"state\":\"failed\",\"failure\":\"update_failed\"}"
reset
touch "$T/fake/claude_slow"
update_line "$UP" claude-code 0.3.13
SNAPWORK_UPDATE_MAX_S=1 watch
rm -f "$T/fake/claude_slow"
called "an update that hangs is stopped and said failed" "update $UP {\"state\":\"failed\",\"failure\":\"update_failed\"}"
check "logged as a timeout" 'grep -q "update-timeout id=f1f1f1f1 after=1s" "$SW/watch.log"'
reset
cp "$T/bin/codex.fake" "$T/bin/codex"
update_line "$UP" codex 0.3.13
watch
check "codex upgrades the marketplace, then adds the plugin again" '[ "$(codex_args 1)" = " |plugin |marketplace |upgrade |snapwork" ] && [ "$(codex_args 2)" = " |plugin |add |snapwork@snapwork" ]'
called "codex: reported done" "update $UP {\"state\":\"done\"}"
rm -f "$T/bin/codex"
reset
update_line "$UP" 'rm -rf' 0.3.13
watch
called "an app it does not know: no_runtime, nothing run" "update $UP {\"state\":\"failed\",\"failure\":\"no_runtime\"}"
check "nothing ran for it" '[ ! -f "$T/fake/claude_calls" ] && [ ! -f "$T/fake/codex_calls" ]'
reset
update_line "$UP" claude-code '0.3;touch pwned'
watch
check "a version that is not digits and dots runs nothing" '[ ! -f "$T/fake/claude_calls" ] && [ ! -e "$SW/pwned" ]'
not_called "and reports nothing" "update $UP"
reset
update_line "not-a-uuid" claude-code 0.3.13
watch
check "a bad update id runs nothing" '[ ! -f "$T/fake/claude_calls" ]'

echo "== 9. logs keep no keys, codes or invitations"
unix && check "watch log mode 600" '[ "$(ls -l "$SW/watch.log" | cut -c 1-10)" = "-rw-------" ]'
check "watch log: no key" '! grep -q "swc_" "$SW/watch.log"'
check "watch log: no invitation" '! grep -q "kfr-" "$SW/watch.log"'
check "plugin log: no connect code" '! grep -q "kfr-cccc" "$SW/plugin.log"'
check "plugin log: no key" '! grep -q "swc_" "$SW/plugin.log"'
check "plugin log: no agent key" '! grep -q "testkey" "$SW/plugin.log"'
check "watch log: no agent key" '! grep -q "testkey" "$SW/watch.log"'

printf '\nmy agents: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$SKIPPED" -eq 0 ] || printf 'my agents: %s skipped on Windows (file modes, ps)\n' "$SKIPPED"
[ "$FAIL" -eq 0 ]
