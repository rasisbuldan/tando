#!/bin/bash
# End-to-end test of tando against the throwaway container (test/server). Starts from a clean
# `test/server/up.sh --reset`. One PASS/FAIL line per check; exits non-zero on any failure.
# Checks 1-10 are docs/history/PROTOTYPE.md's definition of done; 11-17 the second round; 18-21 the third
# (zero failed requests, benchmark fixes, several hosts).
# Usage: test/e2e.sh [--no-reset]
set -u
# Server: TANDO_TEST_NAME, TANDO_TEST_SSH_PORT, TANDO_TEST_HTTP_PORT (default tando-testvm, 2222,
# 8080). The server is reset first when run by hand on the default one, or when TANDO_TEST_OWNED=1.
TN=${TANDO_TEST_NAME:-tando-testvm} SP=${TANDO_TEST_SSH_PORT:-2222} HP=${TANDO_TEST_HTTP_PORT:-8080}
export TANDO_TEST_NAME=$TN TANDO_TEST_SSH_PORT=$SP TANDO_TEST_HTTP_PORT=$HP
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
E=${T_WORK:-$ROOT/test/.e2e-$TN}   # one work dir per test server
W=$E/w R=$ROOT/bin/tando SSH=$ROOT/test/server/ssh.sh
AGENT=/opt/tando/bin/tando-agent
export TANDO_CONFIG_DIR=$E/cfg TANDO_COLOR=never
export TANDO_SOAK=${TANDO_SOAK:-2} TANDO_WAIT=1   # a short soak (30 s by default) keeps the suite fast
FAILS=0

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local n=$1; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
log() { echo "---- $*" >&2; }
get() { curl -s -m 3 "http://$1.localhost:$HP${2:-/}"; }
ver() { get hello | sed -n 's/^hello v\([0-9]*\).*/\1/p'; }
eqv() { [ "$(ver)" = "$1" ]; }
srv() { "$SSH" "$@"; }
st() { srv "sudo sed -n 's/^$2=//p' /opt/tando/apps/$1/state"; }
until_() { local t=$1; shift; while ! "$@"; do t=$((t - 1)); [ $t -gt 0 ] || return 1; sleep 1; done; }
rel_status() { "$R" releases -a hello | awk -v id="$1" '$2 == id {print $4}'; }
cur_id() { "$R" releases -a hello | awk '/current/ && $2 ~ /^[0-9]/ {print $2}'; }
cur_status() { "$R" releases -a hello | awk '/current/ && $2 ~ /^[0-9]/ {print $4}'; }
setv() { echo "$1" > "$W/hello/VERSION"; }
rid() { sed -n 's/.*release \([0-9-]*\) *│/\1/p' "$1" | head -1; }   # release id in a deploy box
kill_client() { kill "$1" 2> /dev/null; pkill -f "ControlPath=$TANDO_CONFIG_DIR"; wait "$1" 2> /dev/null; }
# request loop: about 10 requests a second through Caddy while an operation runs
loop_start() { # name
  rm -f "$E/loop.stop"
  (
    while [ ! -f "$E/loop.stop" ]; do
      curl -s -o /dev/null -m 30 -w '%{http_code} %{time_total}\n' http://hello.localhost:$HP/
      sleep 0.1
    done
  ) > "$E/loop.$1" &
  LOOP=$!
  sleep 0.5
}
loop_check() { # name: stop the loop, then check it saw only 200s
  sleep 0.5; touch "$E/loop.stop"; wait $LOOP
  local n bad max
  n=$(grep -c . "$E/loop.$1")
  bad=$(awk '$1 != 200' "$E/loop.$1" | wc -l | tr -d ' ')
  max=$(awk '$2 > m { m = $2 } END { printf "%.3f", m }' "$E/loop.$1")
  echo "loop $1: $n requests, $bad failed, longest ${max}s" >> "$E/loops"
  check "18 $1 under load: $n requests, $bad failed, longest ${max}s" test "$bad" = 0 -a "$n" -gt 5
}
conf_set() { # file key value: replace or add "key = value"
  grep -v "^$2 *=" "$1" > "$1.tmp"; [ -n "$3" ] && echo "$2 = $3" >> "$1.tmp"; mv "$1.tmp" "$1"
}

if [ "${1:-}" != --no-reset ] && { [ "$TN" = tando-testvm ] || [ "${TANDO_TEST_OWNED:-}" = 1 ]; }; then
  log "resetting test server"
  "$ROOT/test/server/up.sh" --reset >&2 || exit 1
fi
rm -rf "${E:?}"
mkdir -p "$W"
cp -R "$ROOT/examples/hello" "$ROOT/examples/site" "$W/"
head -c 300000 /dev/urandom > "$W/hello/blob.bin"   # bulk the release so deltas are visible
cd "$W/hello"

# 1. host setup, up, link answers v1
"$R" host add test vmadmin@127.0.0.1 --port $SP --key "$ROOT/test/server/id_test" --yes >&2   # the real trust path
"$R" host setup test public_port=$HP >&2
"$R" up > "$E/up1.out" 2>&1; cat "$E/up1.out" >&2
check "1 host setup + up: link answers version 1" eqv 1
# two host setups at once queue on the server's install lock: both succeed, the files are the tree's
"$R" host setup test public_port=$HP > "$E/ps1.out" 2>&1 & p1=$!
"$R" host setup test public_port=$HP > "$E/ps2.out" 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
# lint: allow RL02 shasum first (macOS); sha256sum only where there is no shasum
sha256_of() { { shasum -a 256 "$1" 2> /dev/null || sha256sum "$1"; } | cut -d' ' -f1; }
same_bins() {
  local b f c
  c=$(srv 'uname -m'); case $c in x86_64) c=amd64;; *) c=arm64;; esac
  for b in tando-agent tando-logs tando-metrics tando-watch tandod tando-status tando-gate tando-install-recover; do
    f=$ROOT/server/$b; [ -f "$f" ] || f=$ROOT/dist/server/linux-$c/$b   # a Go program: the binary for its CPU
    [ "$(srv "sudo sha256sum /opt/tando/bin/$b" | cut -d' ' -f1)" = "$(sha256_of "$f")" ] || return 1
  done
  [ -z "$(srv 'sudo find /opt/tando/bin -name ".tando-*"')" ]
}
check "1b two host setups at once both succeed ($r1 $r2); installed helpers match the tree, no temp files" \
  eval '[ $r1 = 0 ] && [ $r2 = 0 ] && same_bins'

# 1c-1f. the install switches the whole set or none: a cut-off install is finished or undone.
# Fault injection is a test-only wrapper for mv in /usr/local/bin of THIS test server (sudo's PATH
# finds it before /usr/bin; nothing of it is in the product): /run/tando-test-mv says "kill N"
# (kill the install script right after N files were renamed into place) or "fail NAME" (the rename
# of NAME fails, as on a full disk). Without that file it just runs /usr/bin/mv.
HOOK=/usr/local/bin/mv
srv "sudo tee $HOOK > /dev/null && sudo chmod 755 $HOOK" <<'EOH'
#!/bin/bash
c=/run/tando-test-mv
if [ -f $c ] && [ "${2:-}" != "${2%.new}" ] && [[ ${3:-} == /opt/tando/bin/tando* ]]; then   # a rename into place
  read -r mode arg < $c
  case $mode in
    kill) n=$(( $(cat $c.n 2> /dev/null || echo 0) + 1 )); echo $n > $c.n
          [ $n -le "$arg" ] || { kill -9 $PPID; exit 137; };;
    fail) [ "${3##*/}" = "$arg" ] && { echo "mv: No space left on device" >&2; exit 1; };;
  esac
fi
exec /usr/bin/mv "$@"
EOH
FB="tando-logs tando-metrics tando-watch"
ssum() { srv "sudo sha256sum /opt/tando/bin/$1" | cut -d' ' -f1; }
tsum() {   # the tree's file for this server's CPU (a Go program is a binary per CPU)
  local c f; c=$(srv 'uname -m'); case $c in x86_64) c=amd64;; *) c=arm64;; esac
  f=$ROOT/server/$1; [ -f "$f" ] || f=$ROOT/dist/server/linux-$c/$1
  sha256_of "$f"
}
hook() { srv "sudo rm -f /run/tando-test-mv.n; echo '$*' | sudo tee /run/tando-test-mv > /dev/null"; }
unhook() { srv "sudo rm -f /run/tando-test-mv /run/tando-test-mv.n"; }
drift3() { local b; for b in $FB; do srv "echo '# old' | sudo tee -a /opt/tando/bin/$b > /dev/null"; done; OLDS=$(for b in $FB; do ssum $b; done); }
nnew() { local b k=0; for b in $FB; do [ "$(ssum $b)" = "$(tsum $b)" ] && k=$((k + 1)); done; echo $k; }
nold() { [ "$(for b in $FB; do ssum $b; done)" = "$OLDS" ]; }   # every file as before the install
clean_dir() { [ -z "$(srv 'sudo find /opt/tando/bin -name ".*.new" -o -name ".*.old" -o -name ".install.pending*"')" ]; }
drift3; hook kill 1
"$R" host setup test public_port=$HP > "$E/cut1.out" 2>&1; rc=$?
check "1c install killed after 1 of 3 renames: host setup fails (rc=$rc) and says it may be cut off, how to repair" \
  eval '[ $rc != 0 ] && grep -q "cut off" "$E/cut1.out" && grep -q "tando host setup test" "$E/cut1.out"'
check "1c the cut-off install left a mixed set (1 of 3 new) and its journal" \
  eval '[ "$(nnew)" = 1 ] && srv "sudo test -f /opt/tando/bin/.install.pending"'
# (doctor shows the programs that differ as one row since the tando.conf/doctor change; --verbose
# names each, so the check reads both)
"$R" doctor > "$E/cut-doc.out" 2>&1; "$R" doctor --verbose > "$E/cut-docv.out" 2>&1
check "1c tando doctor reports the interrupted install and the differing programs before any repair" \
  eval 'tr -d "│\n" < "$E/cut-doc.out" | tr -s " " | grep -q "cut off between files" &&
        tr -d "│\n" < "$E/cut-doc.out" | tr -s " " | grep -qE "[0-9]+ of [0-9]+ programs differ from the client.*tando host setup test" &&
        grep -qE "(logs|metrics|watch).*(differs|tando host setup)" "$E/cut-docv.out"'
unhook
"$R" host setup test public_port=$HP > "$E/cut2.out" 2>&1; rc=$?
check "1d the next host setup finishes the switch (rc=$rc): every file is the tree's, no journal or leftovers" \
  eval '[ $rc = 0 ] && grep -q "finished an install" "$E/cut2.out" && [ "$(nnew)" = 3 ] && same_bins && clean_dir'
# a staged file lost as well: the repair cannot go forward, so it goes back (nothing mixed), and
# the host setup after it installs the new set
drift3; hook kill 1
"$R" host setup test public_port=$HP > "$E/cut3.out" 2>&1
unhook
srv 'sudo rm -f /opt/tando/bin/.tando-watch.new /opt/tando/bin/.tando-metrics.new'
ihs() { TANDO_HOME=$ROOT bash -c ". $ROOT/lib/common.sh; install_helpers_script" | srv "sudo bash -s" 2>&1; }
ihs > "$E/cut4.out"
check "1e a cut-off install that cannot go forward is undone: every file is back to its old version, none mixed" \
  eval 'grep -q "undid an install" "$E/cut4.out" && nold && clean_dir'
"$R" host setup test public_port=$HP > "$E/cut5.out" 2>&1; rc=$?
check "1e host setup after the undo installs the new set (rc=$rc)" eval '[ $rc = 0 ] && [ "$(nnew)" = 3 ] && same_bins && clean_dir'
# a rename that fails (full disk, immutable file): every file goes back at once, and it is said
drift3; hook fail tando-watch
"$R" host setup test public_port=$HP > "$E/cut6.out" 2>&1; rc=$?
check "1f a failing rename: host setup fails (rc=$rc) saying every file is back to its old version; set unchanged" \
  eval '[ $rc != 0 ] && grep -q "back to its old version" "$E/cut6.out" && nold && clean_dir'
unhook
"$R" host setup test public_port=$HP > "$E/cut7.out" 2>&1; rc=$?
[ $rc = 0 ] || cat "$E/cut7.out" >&2
check "1f host setup once the fault is gone installs the new set (rc=$rc)" eval '[ $rc = 0 ] && same_bins && clean_dir'
# 1g. a kill between renames and then a reboot: nobody runs host setup, the boot repairs the set
drift3; hook kill 1
"$R" host setup test public_port=$HP > "$E/cut8.out" 2>&1
unhook
jpend() { srv "sudo test -f /opt/tando/bin/.install.pending"; }
cat "$E/cut8.out" >&2
check "1g the kill left a journal and a mixed set" eval 'jpend && [ "$(nnew)" = 1 ]'
docker restart "$TN" >&2
jgone() { srv "sudo test ! -e /opt/tando/bin/.install.pending"; }   # (true only when ssh worked and it is gone)
until_ 120 srv true; until_ 180 jgone
until_ 120 eqv 1   # (the app is back too)
log "after the reboot: $(for b in $FB; do [ "$(ssum $b)" = "$(tsum $b)" ] && echo "$b new" || echo "$b old"; done | tr "\n" ";") $(srv 'sudo ls -A /opt/tando/bin | grep -E "^[.]" | tr "\n" " "'); $(srv 'sudo journalctl -b -u tando-recover --no-pager | tail -5')"
check "1g after a reboot the set is complete again with no human action (finished forward, no leftovers)" \
  eval '[ "$(nnew)" = 3 ] && same_bins && clean_dir'
# 1h. a mutating agent verb with a journal pending repairs first; a read-only verb only warns
drift3; hook kill 1
"$R" host setup test public_port=$HP > "$E/cut9.out" 2>&1
unhook
srv "sudo $AGENT info 2>&1 > /dev/null" > "$E/cut-warn.out"; rcw=$?
check "1h a read-only verb with a journal pending warns on stderr, runs, and does not repair (rc=$rcw)" \
  eval '[ $rcw = 0 ] && grep -q "cut off between files" "$E/cut-warn.out" && jpend'
srv "sudo $AGENT recover hello" > /dev/null 2>&1
check "1h a mutating verb (recover) with a journal pending first finishes the install" \
  eval '! jpend && [ "$(nnew)" = 3 ] && same_bins && clean_dir'
# 1i. the agent execs tando-status only while the install manifest is newer than both; a stand-in
# that prints FAKE shows which one answered
srv 'printf "#!/bin/sh\necho FAKE\n" | sudo tee /opt/tando/bin/tando-status > /dev/null'
srv "sudo $AGENT status" > "$E/st-fb.out" 2>&1; rcs=$?
check "1i a tando-status newer than the manifest is not exec-ed: the shell version answers (rc=$rcs)" \
  eval '[ $rcs = 0 ] && ! grep -q FAKE "$E/st-fb.out" && grep -q hello "$E/st-fb.out"'
srv 'sudo touch /opt/tando/bin/.versions'
check "1i with the manifest newer again the agent hands status to tando-status" \
  eval 'srv "sudo $AGENT status" | grep -q FAKE'
"$R" host setup test public_port=$HP > "$E/cut10.out" 2>&1; rc=$?
check "1i host setup puts the real tando-status back and rewrites the manifest (rc=$rc)" \
  eval '[ $rc = 0 ] && same_bins && ! srv "sudo $AGENT status" | grep -q FAKE &&
        srv "sudo test /opt/tando/bin/.versions -nt /opt/tando/bin/tando-status && sudo grep -q \" tando-status\\\$\" /opt/tando/bin/.versions"'
srv "sudo rm -f $HOOK"

# 2. change, deploy, v2; only the changed file is uploaded; no request fails meanwhile
fails0=$(srv "journalctl -u tando-hello --no-pager | grep -c \"Failed with result\"")
loop_start deploy
setv 2; "$R" deploy > "$E/d2.out" 2>&1; cat "$E/d2.out" >&2
loop_check deploy
fails1=$(srv "journalctl -u tando-hello --no-pager | grep -c \"Failed with result\"")
check "19a a normal stop is not logged as a failure (SuccessExitStatus=143: $fails0 -> $fails1)" \
  test "$fails0" = "$fails1"
check "19b client phases have tenths of a second" grep -qE 'upload +[0-9]+\.[0-9]s' "$E/d2.out"
check "2a deploy: link answers version 2" eqv 2
files=$(sed -n 's/.* \([0-9][0-9]*\) files\{0,1\} changed.*/\1/p' "$E/d2.out")
sent=$(sed -n 's/.*changed, \([0-9.]* [KMG]*B\) sent.*/\1/p' "$E/d2.out")
check "2b second upload sent only the changed file (files=$files, sent=$sent, release ~300 KB)" \
  test "$files" = 1 -a -n "$(echo "$sent" | grep -E '^[0-9.]+ (B|KB)$')"
# 23. outside a terminal (this log), each step says when it starts, before its result line
first() { grep -n -E -- "$2" "$1" | head -1 | cut -d: -f1; }
starts() { # file: every step's start line comes before its result line
  local f=$1 s r a b
  for s in "stage: copying|[0-9]/7  stage" "upload: sending|[0-9]/7  upload" "copy: the server copies|[0-9]/7  copy" \
           "pre-flight: the new release starts|[0-9]/7  preflight" "switch: traffic moves|[0-9]/7  switch" \
           "verify: checking the live release|[0-9]/7  verify"; do
    r=${s#*|}; s=${s%%|*}; a=$(first "$f" "$s"); b=$(first "$f" "$r")
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || { echo "  no start line before \"$r\" ($a, $b)" >&2; return 1; }
  done
}
check "23a outside a terminal every step has a start line before its result (stage, upload, copy, pre-flight, switch, verify)" \
  starts "$E/d2.out"
# 24. deploy --dry-run builds and stages but sends nothing and leaves nothing on the server: no
#     lease, no release, no history line, incoming/ and app.conf unchanged; for an app that does
#     not exist yet nothing is created
snap() { srv "sudo sh -c 'cd /opt/tando/apps/hello && ls releases; test -e upload && echo LEASE; wc -l < history.tsv;
  find incoming -printf \"%P %s %T@\n\" | sort | cksum; cksum < app.conf; ls /opt/tando/apps'"; }  # lint: allow RL02 runs on the server
# shellcheck disable=SC2034 # s0 is read by the eval'd check
s0=$(snap); setv 99
"$R" deploy --dry-run > "$E/dry.out" 2>&1; rc=$?; cat "$E/dry.out" >&2
check "24a deploy --dry-run: built and staged, file count and size, nothing uploaded (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -q "2/7  stage" "$E/dry.out" && grep -qE "[0-9]+ files, [0-9.]+ [KMG]?B in .tando/stage" "$E/dry.out" &&
        grep -q "dry run: nothing was uploaded" "$E/dry.out" && ! grep -q "3/7  upload" "$E/dry.out"'
check "24b ... the server is as it was (lease, releases, history, incoming, app.conf), still v2" \
  eval '[ "$(snap)" = "$s0" ] && eqv 2'
setv 2
cp -R "$W/hello" "$W/drynew" && conf_set "$W/drynew/tando.conf" app drynew && rm -rf "${W:?}/drynew/.tando"
(cd "$W/drynew" && "$R" deploy --dry-run) > "$E/drynew.out" 2>&1; rc=$?; cat "$E/drynew.out" >&2
check "24c dry run of an app that does not exist: staged, says tando up creates it; no app, user or directory on the server (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -q "drynew is not on test yet (tando up creates it)" "$E/drynew.out" &&
        grep -q "dry run: nothing was uploaded" "$E/drynew.out" &&
        srv "! test -e /opt/tando/apps/drynew && ! id tando-drynew" > /dev/null 2>&1'
rm -rf "${W:?}/drynew"

# 3. unhealthy release: never stops answering, marked bad, history shows it
"$R" env set UNHEALTHY_VERSION=3 >&2
(
  end=$((SECONDS + 90))
  while [ $SECONDS -lt $end ] && [ ! -f "$E/stop" ]; do
    printf '%s\n' "$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://hello.localhost:$HP/)"
    sleep 0.2
  done
) > "$E/probe" &
probe=$!
sleep 1
setv 3; "$R" deploy > "$E/d3.out" 2>&1; rc=$?; cat "$E/d3.out" >&2
sleep 1; touch "$E/stop"; wait $probe; rm -f "$E/stop"
id3=$(rid "$E/d3.out")
check "3a failed deploy exits non-zero" test $rc -ne 0
check "3b app kept answering during the failed deploy ($(sort "$E/probe" | uniq -c | tr -s ' \n' ' '))" \
  test -s "$E/probe" -a -z "$(grep -v '^200$' "$E/probe")"
check "3c still on version 2" eqv 2
check "3d release $id3 failed: its files are deleted, its history line stays" \
  eval '! srv "sudo test -e /opt/tando/apps/hello/releases/$id3" && "$R" history -a hello | grep -q "failed"'
"$R" history > "$E/h3.out"; cat "$E/h3.out" >&2
check "3e history shows the failure" grep -q "$id3.*failed" "$E/h3.out"
check "19c the failure box shows what the health check got" grep -q 'answered HTTP 500' "$E/d3.out"

# 4. rollback twice
id2=$(rid "$E/d2.out")
loop_start rollback
"$R" rollback >&2
loop_check rollback
check "4a rollback: version 1 serves" eqv 1
check "4b the release left ($id2) is marked rolled back (not failed)" test "$(rel_status "$id2")" = rolled-back
"$R" rollback >&2 2> "$E/rb2.err"; rc=$?; cat "$E/rb2.err" >&2
check "4c second rollback does not roll forward (rc=$rc, still v1)" test $rc -ne 0 -a "$(ver)" = 1
setv 4; "$R" deploy > "$E/d4.out" 2>&1; cat "$E/d4.out" >&2
check "4d deploy after rollbacks: version 4" eqv 4

# 5. env with spaces, quotes, backslash
val='a b "c" '"'d'"' \e \\f $HOME `x` end  '
loop_start "env set"
"$R" env set "GREETING=$val" >&2
loop_check "env set"
check "5 env set reaches the app with spaces, quotes, backslash" test "$(get hello)" = "hello v4 greeting=$val"
loop_start restart
"$R" restart >&2
loop_check restart
pid=$(srv "systemctl show -P MainPID tando-hello")
check "19d node apps get MALLOC_ARENA_MAX=2" \
  eval 'srv "sudo cat /proc/$pid/environ" | tr "\\0" "\\n" | grep -qx MALLOC_ARENA_MAX=2'
"$R" env set MALLOC_ARENA_MAX=4 >&2
pid=$(srv "systemctl show -P MainPID tando-hello")
check "19e the env file overrides it" \
  eval 'srv "sudo cat /proc/$pid/environ" | tr "\\0" "\\n" | grep -qx MALLOC_ARENA_MAX=4'
"$R" env unset MALLOC_ARENA_MAX >&2

# 6. kill the client's ssh during activation
loop_start "slow restart"
"$R" env set SLOW_START=5 >&2
loop_check "slow restart"
setv 5
"$R" deploy > "$E/d6.out" 2>&1 & dp=$!
until_ 40 eval '[ "$(st hello phase)" = preflight ]'; ph=$(st hello phase)
kill_client $dp
log "killed client during phase=$ph"
until_ 60 eval '[ "$(st hello phase)" = idle ] && eqv 5'
check "6 client killed during $ph: activation finished, version 5 verified" \
  test "$(ver)" = 5 -a "$(cur_status)" = verified

# 7. docker restart during activation (after the switch, then during pre-flight)
setv 6; "$R" deploy > "$E/d7.out" 2>&1 & dp=$!
until_ 60 eval 'case "$(st hello phase)" in switch|verify) true;; *) false;; esac'; ph=$(st hello phase)
log "docker restart during phase=$ph"; docker restart "$TN" >&2
kill_client $dp
until_ 90 srv true; until_ 90 eval '[ "$(st hello phase)" = idle ] && [ -n "$(ver)" ]'
v=$(ver) cs=$(cur_status)
check "7 restart during $ph: after boot serves verified release (v$v, $cs)" test -n "$v" -a "$cs" = verified

setv 7; "$R" deploy > "$E/d7b.out" 2>&1 & dp=$!
until_ 60 eval '[ "$(st hello phase)" = preflight ]'; ph=$(st hello phase)
log "docker restart during phase=$ph"; docker restart "$TN" >&2
kill_client $dp
until_ 90 srv true; until_ 90 eval '[ "$(st hello phase)" = idle ] && [ -n "$(ver)" ]'
v=$(ver) cs=$(cur_status)
check "7b restart during $ph: after boot serves verified release (v$v, $cs)" test "$v" = 6 -a "$cs" = verified
"$R" env unset SLOW_START >&2

# 21. stop answers 503 at once; start drops no request; a unit that gives up shows 503 at once
port=$(srv "sudo sed -n 's/^port=//p' /opt/tando/apps/hello/app.conf")
live=$(ver)
"$R" stop >&2
st0=$(curl -s -o "$E/stopped.body" -w '%{http_code} %{time_total}' http://hello.localhost:$HP/)
check "21a stopped: 503 \"hello is stopped\" at once ($st0)" \
  eval 'echo "$st0" | grep -qE "^503 0\.[0-4]" && grep -q "hello is stopped" "$E/stopped.body"'
check "21b a stopped app stays stopped after a reboot (unit disabled)" \
  eval '! srv "systemctl -q is-enabled tando-hello"'
loop_start start
"$R" start >&2
sleep 0.5; touch "$E/loop.stop"; wait $LOOP
n=$(grep -c . "$E/loop.start"); bad=$(awk '$1 != 200 && $1 != 503' "$E/loop.start" | wc -l | tr -d ' ')
late=$(awk '$1 == 200 { seen = 1 } seen && $1 != 200' "$E/loop.start" | wc -l | tr -d ' ')
max=$(awk '$2 > m { m = $2 } END { printf "%.3f", m }' "$E/loop.start")
echo "loop start: $n requests, $bad failed, longest ${max}s" >> "$E/loops"
check "21c start under load: $n requests, $bad failed (503 only before the switch, $late after), longest ${max}s" \
  test "$bad" = 0 -a "$late" = 0
# (written into the env file by hand: `env set` would put the previous env back when the app then
# fails its health check, test n2 of e2e-faults)
srv "sudo sh -c 'echo CRASH_VERSION=\"$live@$port\" >> /opt/tando/apps/hello/env && systemctl restart tando-hello'" > /dev/null 2>&1
until_ 40 eval 'srv "systemctl show -P ActiveState tando-hello" | grep -qx failed'
# the 503 page is put in place by the unit's failure handler (tando-down@), which runs after the
# unit failed and ends with a Caddy reload: wait until the server has recorded it (a fixed 2 s was
# too short once in a census of five full runs on a busy machine: the request was held), then ask
dn_t0=$(date +%s)
until_ 30 eval 'srv "sudo grep -qx down=1 /opt/tando/apps/hello/state"'
echo "21d: the failure handler had the page in place within $(($(date +%s) - dn_t0)) s of the unit failing" >&2
dn=$(curl -s -o "$E/down.body" -w '%{http_code} %{time_total}' http://hello.localhost:$HP/)
check "21d a unit that gave up: 503 \"unavailable\" at once, not a held request ($dn)" \
  eval 'echo "$dn" | grep -qE "^503 0\.[0-4]" && grep -q "hello is unavailable" "$E/down.body"'
"$R" env unset CRASH_VERSION >&2
check "21e env unset restarts it and proxying resumes (v$live)" eqv "$live"

# 21f. an app with no release yet (first deploy still running, or failed): 503 "being deployed"
# at once with Retry-After, not a held request and an empty 502; the page goes away by itself when
# the first release is live. (hello keeps its release throughout: it never gets the page)
cp -R "$W/hello" "$W/shop" && sed -i.bak 's/^app = hello/app = shop/' "$W/shop/tando.conf"
rm -f "$W/shop/blob.bin"; echo 1 > "$W/shop/VERSION"   # (UNHEALTHY_VERSION below is this number)
( cd "$W/shop" || exit 1
  "$R" env set UNHEALTHY_VERSION=1 >&2
  "$R" up --yes > "$E/shop1.out" 2>&1 )
nl=$(curl -s -D "$E/shop.hdr" -o "$E/shop.body" -w '%{http_code} %{time_total}' -m 5 http://shop.localhost:$HP/)
check "21f first deploy failed, nothing live: 503 \"shop is being deployed\" at once with Retry-After ($nl)" \
  eval 'echo "$nl" | grep -qE "^503 0\.[0-4]" && grep -q "shop is being deployed" "$E/shop.body" &&
        grep -qi "^retry-after: 10" "$E/shop.hdr" && grep -qi "^content-type: text/html" "$E/shop.hdr" &&
        ! grep -qiE "/opt/|tando" "$E/shop.body"'
check "21f the page is not another app's and hello still answers v$live" eqv "$live"
( cd "$W/shop" || exit 1
  "$R" env unset UNHEALTHY_VERSION >&2
  "$R" env set SLOW_START=8 >&2
  "$R" up --yes > "$E/shop2.out" 2>&1 ) &
shop_up=$!
# while the first release is being brought up it is the same page (until the link switches)
shop_503() { curl -s -m 5 http://shop.localhost:$HP/ | grep -q "shop is being deployed"; }
check "21f during the first deploy the page is served" until_ 30 shop_503
wait $shop_up
shop_live() { [ "$(curl -s -m 5 http://shop.localhost:$HP/)" = "hello v1 greeting=" ]; }
check "21f first release live: the page is gone and the app answers" until_ 30 shop_live
# 21g. a release directory removed by hand while the app runs (fault g9): the link dangles, but the
# app has a release by tando's records and its process answers: never the "being deployed" page
srv "sudo sh -c 'rm -rf /opt/tando/apps/shop/releases/*'"
rn=$(curl -s -o "$E/shop.dang" -w '%{http_code}' -m 5 http://shop.localhost:$HP/)
check "21g releases emptied by hand, app still running: it answers 200, not the deploying page ($rn)" \
  eval '[ "$rn" = 200 ] && ! grep -q "being deployed" "$E/shop.dang"'
( cd "$W/shop" && echo shop | "$R" destroy --purge >&2 )

# 3f. healthy in pre-flight but failing after the switch: automatic rollback
port=$(srv "sudo sed -n 's/^port=//p' /opt/tando/apps/hello/app.conf")
"$R" env set "UNHEALTHY_VERSION=8@$port" >&2; setv 8
"$R" deploy > "$E/d8.out" 2>&1; rc=$?; cat "$E/d8.out" >&2
id8=$(rid "$E/d8.out")
check "3f fails after switch: rolled back automatically (rc=$rc, v$(ver), $id8 $(rel_status "$id8"))" \
  test $rc -ne 0 -a "$(ver)" = 6 -a -z "$(rel_status "$id8")" -a "$(cur_status)" = verified   # (its files deleted)

# 3g. a release whose start command is wrong fails pre-flight. The live release keeps its own
#     start command: when it crashes afterwards, systemd brings it back (found on a real server:
#     the refused deploy's start line stayed in app.conf and the live app could not restart)
"$R" env unset UNHEALTHY_VERSION >&2
conf_set tando.conf start "node missing-on-purpose.js"
"$R" deploy > "$E/d3g.out" 2>&1; rc=$?; cat "$E/d3g.out" >&2
srv "sudo systemctl kill -s KILL tando-hello"
sleep 2; until_ 30 eqv 6
check "3g refused release (rc=$rc) does not change how the live one restarts (v$(ver) after a kill)" \
  test $rc -ne 0 -a "$(ver)" = 6
conf_set tando.conf start "node server.js"
"$R" restart > /dev/null 2>&1
check "3h and a plain restart of the live release still works (v$(ver))" eqv 6

# 12. a crash-looping release fails fast after the switch, not after the health timeout;
#     env unset clears a variable
conf_set tando.conf health_timeout 60
"$R" env unset UNHEALTHY_VERSION >&2
"$R" env set "CRASH_VERSION=9@$port" >&2
setv 9; "$R" up > "$E/d9.out" 2>&1; rc=$?; cat "$E/d9.out" >&2
secs=$(sed -n 's/.*✗ 7\/7  verify *\([0-9.]*\)s.*/\1/p' "$E/d9.out")
check "12a crash loop after the switch detected in ${secs:-?}s of a 60s timeout, rolled back to v$(ver)" \
  test $rc -ne 0 -a -n "$secs" -a "${secs%.*}" -lt 20 -a "$(ver)" = 6
check "12b failure names the crash loop" grep -q 'crash-looping' "$E/d9.out"
COLUMNS=80 "$R" history -a hello > "$E/hist80.out" 2>&1; cat "$E/hist80.out" >&2
check "12f history at 80 columns says why the release was rolled back" \
  grep -qE "why [0-9]{8}-[0-9]{6}: [a-z]" "$E/hist80.out"
# the newest row's time is its epoch ("at" in --json) in UTC, never an age or the local time
hist_gmt() {
  local at want
  at=$("$R" history -a hello --json | sed -n 's/^[^[]*\[{"at":\([0-9]*\),.*/\1/p')
  want=$(TZ=UTC date -r "$at" '+%m-%d %H:%M' 2> /dev/null || TZ=UTC date -d "@$at" '+%m-%d %H:%M')
  grep -q 'TIME (GMT)' "$E/hist80.out" && ! grep -qE ' ago|WHEN' "$E/hist80.out" &&
    grep -q " $want " "$E/hist80.out"
}
check "12g history's TIME (GMT) column is the UTC time of the deploy" hist_gmt
"$R" env ls > "$E/envmask.out" 2>&1; "$R" env ls --show > "$E/envshow.out" 2>&1
check "12e env ls hides values (CRASH_VERSION's 9@$port), --show prints them" \
  eval 'grep -q "CRASH_VERSION" "$E/envmask.out" && ! grep -q "9@$port" "$E/envmask.out" &&
        grep -q "CRASH_VERSION *9@$port" "$E/envshow.out"'
"$R" env unset CRASH_VERSION GREETING >&2
check "12c env unset reaches the app" test "$(get hello)" = "hello v6 greeting="
"$R" env ls > "$E/envls.out"; cat "$E/envls.out" >&2
check "12d env ls no longer lists the unset keys" eval '! grep -qE "CRASH_VERSION|GREETING" "$E/envls.out"'
# 12h. env log: every change of the env is one entry of key NAMES (added, changed, removed), never a value
log "12h env log"
canary=$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 48)
elog_n() { "$R" env log --json | grep -o '"n":' | wc -l | tr -d ' '; }
elog_e() { "$R" env log --json | sed -e "s/},{\"n\":$(($1 + 1)),.*/}/" -e 's/^.*"entries":\[//'; }   # entry n of the JSON
e0=$(elog_n)
check "12h1 the env unset above is entry 1: verb unset, removed CRASH_VERSION and GREETING, nothing added or changed" \
  eval 'e=$(elog_e 1); case $e in "{\"n\":1,"*"\"verb\":\"unset\""*"\"added\":[]"*"\"changed\":[]"*"\"removed\":[\"CRASH_VERSION\",\"GREETING\"]"*) true;; *) echo "  $e" >&2; false;; esac'
"$R" env set --note "first batch" ELOG_A=one ELOG_B=two >&2
check "12h2 set with a note: added ELOG_A and ELOG_B, the note, nothing changed or removed" \
  eval 'e=$(elog_e 1); case $e in *"\"verb\":\"set\""*"\"note\":\"first batch\""*"\"added\":[\"ELOG_A\",\"ELOG_B\"]"*"\"changed\":[]"*"\"removed\":[]"*) true;; *) echo "  $e" >&2; false;; esac'
"$R" env set "ELOG_A=$canary" ELOG_C=three >&2
check "12h3 set of one new and one existing key: ELOG_C added, ELOG_A changed; no note, so \"set 2 keys\"" \
  eval 'e=$(elog_e 1); case $e in *"\"note\":\"set 2 keys\""*"\"added\":[\"ELOG_C\"]"*"\"changed\":[\"ELOG_A\"]"*"\"removed\":[]"*) true;; *) echo "  $e" >&2; false;; esac'
n1=$(elog_n)
"$R" env set "ELOG_A=$canary" > "$E/noop.out" 2>&1
check "12h4 setting what is already set changes nothing and writes no entry ($n1 -> $(elog_n))" \
  eval '[ "$(elog_n)" = "$n1" ] && [ "$n1" = $((e0 + 2)) ] && grep -q "nothing changed" "$E/noop.out"'
"$R" env unset ELOG_B ELOG_C --note "drop two" >&2
check "12h5 unset: both removed, the note" \
  eval 'e=$(elog_e 1); case $e in *"\"verb\":\"unset\""*"\"note\":\"drop two\""*"\"added\":[]"*"\"changed\":[]"*"\"removed\":[\"ELOG_B\",\"ELOG_C\"]"*) true;; *) echo "  $e" >&2; false;; esac'
printf '# a comment\nexport ELOG_D="four"\nELOG_A=other\n' > "$E/elog.env"
"$R" env import "$E/elog.env" >&2
check "12h6 import: verb import, ELOG_D added, ELOG_A changed, \"imported 2 keys\"" \
  eval 'e=$(elog_e 1); case $e in *"\"verb\":\"import\""*"\"note\":\"imported 2 keys\""*"\"added\":[\"ELOG_D\"]"*"\"changed\":[\"ELOG_A\"]"*"\"removed\":[]"*) true;; *) echo "  $e" >&2; false;; esac'
check "12h7 four entries since the start ($e0 -> $(elog_n))" test "$(elog_n)" = $((e0 + 4))
# no value in any form anywhere the log goes: the file, the list, every page, the JSON
# shellcheck disable=SC2034 # (read inside the eval string of the check)
csha=$(printf '%s' "$canary" | openssl dgst -sha256 -r | cut -d' ' -f1)
# shellcheck disable=SC2034
cmd5=$(printf '%s' "$canary" | openssl dgst -md5 -r | cut -d' ' -f1)
"$R" env log > "$E/elog.list" 2>&1; "$R" env log --json > "$E/elog.json" 2>&1
: > "$E/elog.pages"; for i in $(seq 1 "$(elog_n)"); do "$R" env log "$i" >> "$E/elog.pages" 2>&1; done
srv "sudo cat /opt/tando/apps/hello/env.log" > "$E/elog.file"
check "12h8 the canary value, its sha256 and its md5 are nowhere in the log file, the list, the pages or the JSON (file $(wc -c < "$E/elog.file") bytes)" \
  eval '[ -s "$E/elog.file" ] && [ -s "$E/elog.pages" ] && ! grep -qF -e "$canary" -e "$csha" -e "$cmd5" "$E/elog.file" "$E/elog.list" "$E/elog.pages" "$E/elog.json"'
check "12h9 the log file is 600 root:root next to the app's other state" \
  eval '[ "$(srv "sudo stat -c %a:%U:%G /opt/tando/apps/hello/env.log")" = "600:root:root" ]'
check "12h10 list rows are [time] [note] >, newest first" \
  eval 'head -1 "$E/elog.list" | grep -qE "^\[20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}\] \[imported 2 keys\] >$" &&
        sed -n 2p "$E/elog.list" | grep -q "^\[.*\] \[drop two\] >$" && [ "$(grep -c . "$E/elog.list")" = "$(elog_n)" ]'
check "12h11 the page of an entry names the keys under Added, Changed and Removed" \
  eval '"$R" env log 4 > "$E/elog.p4" 2>&1; grep -q "Added (2)" "$E/elog.p4" && grep -q "ELOG_B" "$E/elog.p4" && grep -q "first batch" "$E/elog.p4" && grep -q "Removed (0)" "$E/elog.p4"'
# refusals
n1=$(elog_n)
"$R" env set --note "$(printf 'a\tb')" ELOG_X=1 > "$E/ctl.out" 2>&1; rc1=$?
"$R" env set --note "$(printf 'x%.0s' $(seq 1 201))" ELOG_X=1 > "$E/long.out" 2>&1; rc2=$?
srv "printf 'ELOG_X=1\n' | sudo $AGENT env-set hello note64=$(printf 'x%.0s' $(seq 1 201) | base64 | tr -d '\n')" > "$E/slong.out" 2>&1; rc3=$?
srv "printf 'ELOG_X=1\n' | sudo $AGENT env-set hello note64=$(printf 'a\tb' | base64)" > "$E/sctl.out" 2>&1; rc4=$?
check "12h12 a note with a control character or over 200 characters is refused by the client and by the agent, and nothing is changed ($rc1 $rc2 $rc3 $rc4)" \
  eval '[ $rc1 != 0 ] && [ $rc2 != 0 ] && [ $rc3 != 0 ] && [ $rc4 != 0 ] && [ "$(elog_n)" = "$n1" ] && ! "$R" env ls --show | grep -q ELOG_X &&
        grep -q "control" "$E/ctl.out" && grep -q "at most 200" "$E/long.out" && grep -q "over 200" "$E/slong.out" && grep -q "control" "$E/sctl.out"'
# (its pre-flight port: preflight_port= from 14100-14999, port + 100 for an app made before)
pfp=$(srv "sudo sed -n 's/^preflight_port=//p' /opt/tando/apps/hello/app.conf"); pfp=${pfp:-$((port + 100))}
"$R" env set "UNHEALTHY_VERSION=$(ver)@$pfp" > "$E/pf.out" 2>&1; rc=$?
check "12h13 a change refused by the pre-flight is not logged (rc=$rc, $n1 -> $(elog_n))" \
  eval '[ $rc != 0 ] && grep -q "nothing was changed" "$E/pf.out" && [ "$(elog_n)" = "$n1" ]'
# the bound: an app that does not exist yet (its env is staged), 205 changes; the 200 newest stay
srv "for i in \$(seq 1 205); do printf 'KEY%s=v\n' \$i | sudo $AGENT env-set elogapp > /dev/null || echo failed \$i; done"
check "12h14 205 changes: the newest 200 are kept (KEY6 to KEY205)" \
  eval '[ "$(srv "sudo cat /opt/tando/staged/elogapp/env.log" | grep -c .)" = 200 ] &&
        srv "sudo head -1 /opt/tando/staged/elogapp/env.log" | grep -q "	KEY6	" && srv "sudo tail -1 /opt/tando/staged/elogapp/env.log" | grep -q "	KEY205	"'
srv "sudo rm -rf /opt/tando/staged/elogapp"
"$R" env unset ELOG_A ELOG_D >&2
conf_set tando.conf health_timeout 15

# 13. build step (summary on success, output on failure, seconds in history) and start_shell
printf 'echo compiling\nsleep 1\ndate +%%s > BUILT\necho "built 3 files"\n' > build.sh
conf_set tando.conf build "sh build.sh"
conf_set tando.conf start 'echo "started via sh as $(id -un)" && exec node server.js'
conf_set tando.conf start_shell true
setv 10; "$R" up > "$E/d10.out" 2>&1; rc=$?; cat "$E/d10.out" >&2
check "13a deploy with a build step: v$(ver), summary shown" \
  eval '[ $rc = 0 ] && [ "$(ver)" = 10 ] && grep -q "build.*built 3 files" "$E/d10.out"'
b=$(srv "sudo tail -1 /opt/tando/apps/hello/history.tsv" | cut -f6)
check "13b history records build seconds ($b)" awk -v b="${b:-0}" 'BEGIN { exit !(b >= 1) }'
"$R" logs -n 20 > "$E/logs.out"
check "13c start_shell runs the start command through sh as the app user" \
  grep -q 'started via sh as tando-hello' "$E/logs.out"
newest() { "$R" releases | awk '$2 ~ /^20/ {print $2; exit}'; }
n0=$(newest)
conf_set tando.conf build 'echo boom-error >&2; exit 3'
setv 11; "$R" deploy > "$E/d11.out" 2>&1; rc=$?; cat "$E/d11.out" >&2
check "13d failing build: non-zero, output shown, nothing uploaded, still v$(ver)" \
  eval '[ $rc != 0 ] && grep -q boom-error "$E/d11.out" && [ "$(ver)" = 10 ] &&
        [ "$(newest)" = "$n0" ]'
conf_set tando.conf build ""

# 14. rollback to a named release (an older verified one, not the previous)
idr=$("$R" releases | awk '$4 == "verified" && !/current/ {print $2}' | tail -1)
vr=$(srv "sudo cat /opt/tando/apps/hello/releases/$idr/VERSION")
"$R" rollback "$idr" >&2; rc=$?
check "14 rollback $idr: current is that release and v$vr serves" \
  test $rc = 0 -a "$(cur_id)" = "$idr" -a "$(ver)" = "$vr"
# 14b. a rollback of a stopped app (tando stop) does what a deploy to it does: a target that passes
# its health check goes live and runs; one that fails it leaves the app as it was: its release,
# stopped (the unit inactive and disabled, the stopped page)
idt=$("$R" releases | awk '$4 == "verified" && !/current/ {print $2}' | head -1)
vt=$(srv "sudo cat /opt/tando/apps/hello/releases/$idt/VERSION")
"$R" stop >&2
"$R" env set "UNHEALTHY_VERSION=$vt" >&2
"$R" rollback "$idt" > "$E/rb14b.out" 2>&1; rc=$?; cat "$E/rb14b.out" >&2
code=$(curl -s -o "$E/rb14b.body" -w '%{http_code}' -m 5 http://hello.localhost:$HP/)
check "14b a rollback of a stopped app to $idt (v$vt) that fails its check leaves it stopped on $idr (rc=$rc, $code, current $(cur_id), stopped=$(st hello stopped))" \
  eval '[ $rc != 0 ] && [ "$code" = 503 ] && grep -q "hello is stopped" "$E/rb14b.body" && [ "$(st hello stopped)" = 1 ] &&
        ! srv "systemctl -q is-active tando-hello" && ! srv "systemctl -q is-enabled tando-hello" && [ "$(cur_id)" = "$idr" ]'
"$R" env unset UNHEALTHY_VERSION >&2
"$R" rollback "$idt" > "$E/rb14c.out" 2>&1; rc=$?; cat "$E/rb14c.out" >&2
check "14c a rollback of a stopped app that passes its check starts it, as a deploy does (rc=$rc, v$(ver))" \
  eval '[ $rc = 0 ] && [ "$(ver)" = "$vt" ] && [ -z "$(st hello stopped)" ] && srv "systemctl -q is-enabled tando-hello"'
setv 12; "$R" deploy >&2
setv 13; "$R" deploy >&2      # so that rollback in 11b has a previous verified release

# 11. concurrent deploys of one app never mix uploads; rollback is not blocked
tok=$(srv "sudo $AGENT begin hello other@laptop" | sed -n 's/^token=//p')
"$R" deploy > "$E/d12.out" 2>&1; rc=$?; cat "$E/d12.out" >&2
check "11a deploy refused while another upload holds the lease" eval \
  '[ $rc != 0 ] && grep -q "another deploy is uploading (started [0-9]*s ago by other@laptop)" "$E/d12.out"'
"$R" rollback > "$E/rb11.out" 2>&1; rc=$?; cat "$E/rb11.out" >&2
check "11b rollback works while the lease is held (rc=$rc, v$(ver))" test $rc = 0 -a "$(ver)" = 12
"$R" unlock > "$E/unlock.out" 2>&1; cat "$E/unlock.out" >&2
check "19f unlock clears the lease and says who held it" grep -q 'held by other@laptop' "$E/unlock.out"
rm -rf "${W:?}/hello2"; cp -R "$W/hello" "$W/hello2"
echo 21 > "$W/hello/VERSION"; echo 22 > "$W/hello2/VERSION"
head -c 4000000 /dev/urandom > "$W/hello2/blob.bin"
( cd "$W/hello" && "$R" deploy --force > "$E/c1.out" 2>&1; echo $? > "$E/c1.rc" ) &   # hello2 deployed it last
( cd "$W/hello2" && "$R" deploy --force > "$E/c2.out" 2>&1; echo $? > "$E/c2.rc" ) &   # same app, other dir
wait
cat "$E/c1.out" "$E/c2.out" >&2
ok=0 mixed=0 other=0
for i in 1 2; do
  if [ "$(cat "$E/c$i.rc")" = 0 ]; then
    ok=$((ok + 1)); id=$(rid "$E/c$i.out")
    want="2$i $(cksum < "$W/hello$( [ $i = 2 ] && echo 2)/blob.bin" | cut -d' ' -f1)"
    rd=/opt/tando/apps/hello/releases/$id
    have=$(srv "sudo cat $rd/VERSION; sudo cksum $rd/blob.bin" |
      cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')
    [ "$want" = "$have" ] || mixed=$((mixed + 1))
  elif ! grep -qE 'another deploy is|another deploy of .* started while|another deploy of .* is uploading now|lease expired' "$E/c$i.out"; then
    other=$((other + 1))
  fi
done
check "11c two concurrent deploys: $ok succeeded, the rest refused cleanly, no mixed release" \
  test $ok -ge 1 -a $mixed = 0 -a $other = 0
check "11d the link serves one of them (v$(ver))" eval 'case "$(ver)" in 21|22) true;; *) false;; esac'

# 15. --watch repaints on a pseudo-terminal: a second frame comes without any input. Each frame
# is one ssh round trip, which takes seconds on a loaded machine, so this waits for the second
# frame (up to 30 s) instead of counting frames in a fixed window.
( COLUMNS=80 "$ROOT/test/pty-run.sh" "$E/watch.out" "$R" status --watch 1 < /dev/null > /dev/null 2>&1 & )
frames=0 t0=$SECONDS
while [ $((SECONDS - t0)) -lt 30 ]; do
  sleep 0.5
  frames=$(perl -ne '$n += () = /\e\[H/g; END { print $n + 0 }' "$E/watch.out" 2> /dev/null)
  [ "${frames:-0}" -ge 2 ] && break
done
wsecs=$((SECONDS - t0)); pkill -f "tando status --watch"; sleep 0.5
check "15 status --watch 1 repainted ($frames frames in ${wsecs}s) with a trend line" \
  eval '[ "${frames:-0}" -ge 2 ] && grep -q trend "$E/watch.out"'

# 16. tls = internal: Caddy's local CA, verify through https, then back to plain http
"$R" host setup test tls=internal > "$E/tls.out" 2>&1; cat "$E/tls.out" >&2
echo 30 > VERSION; "$R" deploy --force > "$E/d30.out" 2>&1; rc=$?; cat "$E/d30.out" >&2
ca=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
body=$(srv "sudo curl -s --cacert $ca --resolve hello.localhost:443:127.0.0.1 https://hello.localhost/")
check "16a tls internal: deploy verified through https, answers with Caddy's CA ($body)" \
  eval '[ $rc = 0 ] && [ "$body" = "hello v30 greeting=" ] && grep -q "https://hello.localhost" "$E/d30.out"'
"$R" host setup test tls=off > /dev/null 2>&1
check "16b back to tls off: http link answers" eqv 30
# --wait as a flag (the suite exports TANDO_WAIT=1): waits out the soak; without it, returns at live
# (each with a change: an unchanged tree is "already live" and activates nothing)
echo 31 > VERSION; TANDO_WAIT="" "$R" deploy --wait > "$E/dwait.out" 2>&1; rc=$?; cat "$E/dwait.out" >&2
check "16c deploy --wait (TANDO_WAIT unset) waits out the soak: 7/7 verify has a time (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -qE "7/7 +verify +[0-9]" "$E/dwait.out"'
echo 32 > VERSION; TANDO_WAIT="" "$R" deploy > "$E/dnowait.out" 2>&1; rc=$?; cat "$E/dnowait.out" >&2
# (the unchanged deploy after v32's soak: during it, a deploy supersedes the soak, and the release
# is then not verified, so the same tree is activated again; 16f)
t_until 30 srv "! sudo grep -qx result=running /opt/tando/apps/hello/activation"
"$R" deploy > "$E/dsame.out" 2>&1; rc2=$?
check "16e deploy of the unchanged tree: already live, nothing activated (rc=$rc2)" \
  eval '[ $rc2 = 0 ] && grep -q "already live" "$E/dsame.out" && ! grep -qE "^[^a-z]* release [0-9]{8}-[0-9]{6} *[^a-z]*$" "$E/dsame.out"'
check "16d deploy without --wait returns once live; the server watches the soak (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -q "the server watches it" "$E/dnowait.out"'
# an unchanged tree deployed while the live release still soaks: that soak is superseded (live, not
# verified), so "already live" does not apply: the same files go live again and are verified
echo 33 > VERSION; TANDO_SOAK=20 TANDO_WAIT="" "$R" deploy > "$E/dsup1.out" 2>&1
TANDO_SOAK=20 TANDO_WAIT="" "$R" deploy > "$E/dsup2.out" 2>&1; rc=$?
sid=$(sed -n 's/.*release \([0-9-]*\) *│.*/\1/p' "$E/dsup1.out" | head -1)
check "16f an unchanged deploy during the soak supersedes it and goes live verified (rc=$rc; $sid $(rel_status "$sid"))" \
  eval '[ $rc = 0 ] && grep -q "supersedes it" "$E/dsup2.out" && grep -q "live in" "$E/dsup2.out" && [ "$(rel_status "$sid")" = superseded ] && eqv 33'
t_until 40 srv "! sudo grep -qx result=running /opt/tando/apps/hello/activation"   # (its own 20 s soak ends)

# 22. the release command (release = in tando.conf; docs/COMMANDS.md "The release command"): once
# per deploy on the server, as the app's user, after pre-flight and the pre-deploy backup, before
# the switch. The app relc serves the "schema" its release command wrote into the data directory.
# >>> release-command
mkdir -p "$W/relc"; cd "$W/relc" || exit 2
cat > server.js <<'EOF'
// relc: "relc v<VERSION> schema=<what the release command wrote>"; /health is 500 when
// UNHEALTHY_VERSION is <version>@<port> (healthy in pre-flight, failing once live)
const http = require('http');
const fs = require('fs');
const v = fs.readFileSync(__dirname + '/VERSION', 'utf8').trim();
const port = Number(process.env.PORT);
const [uv, up] = (process.env.UNHEALTHY_VERSION || '').split('@');
const bad = uv === v && Number(up) === port;
const schema = () => { try { return fs.readFileSync(process.env.TANDO_DATA_DIR + '/schema', 'utf8').trim(); } catch (e) { return 'none'; } };
const s = http.createServer((q, r) => {
  if (q.url === '/health') { r.writeHead(bad ? 500 : 200); return r.end(bad ? 'unhealthy\n' : 'ok\n'); }
  r.end(`relc v${v} schema=${schema()}\n`);
});
s.listen(port, '127.0.0.1');
process.on('SIGTERM', () => { s.close(() => process.exit(0)); s.closeIdleConnections(); setInterval(() => s.closeIdleConnections(), 100).unref(); });
EOF
cat > release.sh <<'EOF'
#!/bin/sh
# the "migration": what it does comes from the shipped file MIGRATE
v=$(cat VERSION)
echo "migrating to $v as uid $(id -u)"
case $(cat MIGRATE) in
  ok) echo "$v" > "$TANDO_DATA_DIR/schema" &&
        echo "$v $(id -u) $(id -un) $GREETING $(pwd -P) $TANDO_RELEASE" >> "$TANDO_DATA_DIR/runs";;
  fail) echo half > "$TANDO_DATA_DIR/partial"; echo "migration 0007 failed: column exists" >&2; exit 3;;
  slow) echo "a slow migration"; sleep 600;;
esac
EOF
printf 'app = relc\nrecipe = node\nstart = node server.js\nhealth = /health\nmemory = 128M\nhealth_timeout = 15\ndata = data\n' > tando.conf
RD=/opt/tando/apps/relc
rpage() { get relc; }
flat() { tr -d '│\n' < "$1" | tr -s ' '; }                 # a box's text without its wrapping
runs() { srv "sudo cat $RD/shared/data/runs" 2> /dev/null; }
nruns() { runs | grep -c .; }
rdeploy() { echo "$1" > VERSION; echo "$2" > MIGRATE; "$R" "${4:-deploy}" > "$E/$3.out" 2>&1; rc=$?; cat "$E/$3.out" >&2; return $rc; }
: "${out:=}" "${out2:=}" "${idr1:=}" "${hrow:=}"   # (set below, read inside the checks' eval strings)
agent_check() { # recipe line [line]: what the server's configure says to these settings (check only)
  printf 'check=1\nrecipe=%s\nstart=node server.js\nhealth=/health\nmemory=128M\n%s\n%s\n' "$1" "$2" "${3:-}" |
    srv "sudo $AGENT configure relc" 2>&1
}

# 22a. what cannot be run safely is refused, by the client before anything is built and by the server
conf_set tando.conf release 'sh release.sh && echo done'
rdeploy 1 ok r0 up
check "22a release with shell syntax but no release_shell: refused by the client (rc=$rc), nothing created" \
  eval '[ $rc != 0 ] && flat "$E/r0.out" | grep -q "release_shell = true" && ! srv "sudo test -e $RD"'
out=$(agent_check node 'release=sh release.sh | tee log')
check "22a2 ... and by the server" eval 'echo "$out" | grep -q "release has shell syntax"'
out=$(agent_check static 'release=sh release.sh'); out2=$(agent_check container 'release=sh release.sh')
check "22a3 the server refuses a release command for a static site and for a container, saying why" \
  eval 'echo "$out" | grep -q "not supported for a static site" && echo "$out2" | grep -q "not supported for recipe = container"'
out=$(agent_check node 'release=sh release.sh' 'release_timeout=0'); out2=$(agent_check node 'release_timeout=30')
check "22a4 release_timeout is validated (0 refused; without release refused)" \
  eval 'echo "$out" | grep -q "bad release_timeout" && echo "$out2" | grep -q "need release"'
mkdir -p "$E/relst" && printf 'app = relst\nrecipe = static\nrelease = sh x.sh\n' > "$E/relst/tando.conf"
out=$(cd "$E/relst" && "$R" deploy 2>&1); rc=$?
check "22a5 the client refuses it for a static site too (rc=$rc)" eval '[ $rc != 0 ] && echo "$out" | grep -q "not supported for a static site"'

# 22b-e. success: its own phase, its effect served by the new release, as the app's user with the
# app's env, in the new release's directory
conf_set tando.conf release 'sh release.sh'
"$R" env set GREETING=hola > "$E/r-env.out" 2>&1          # (staged: the app does not exist yet)
rdeploy 1 ok r1 up
idr1=$(rid "$E/r1.out"); uidr=$(srv "id -u tando-relc")
check "22b up with a release command (rc=$rc): the new release serves what the command wrote ($(rpage))" \
  test "$rc" = 0 -a "$(rpage)" = "relc v1 schema=1"
check "22c the deploy box shows release as its own phase with a time, between pre-flight and switch" \
  awk '/5\/8 +preflight +[0-9]/ { p = NR } /6\/8 +release +[0-9.]+s/ { r = NR } /7\/8 +switch +[0-9]/ { s = NR }
       END { exit !(p && r > p && s > r) }' "$E/r1.out"
last=$(runs | tail -1)
check "22d it ran as the app's user (uid ${uidr:-?}, not root) with the app's env, in the new release ($last)" \
  eval '[ -n "$uidr" ] && [ "$uidr" != 0 ] && [ "$last" = "1 $uidr tando-relc hola $RD/releases/$idr1 $idr1" ]'
COLUMNS=160 "$R" history -a relc > "$E/rh1.out" 2>&1; cat "$E/rh1.out" >&2
hrow=$(srv "sudo tail -1 $RD/history.tsv")
check "22e history: a RELCMD column; the deploy's line has the command's seconds as a 13th field; release_s in --json" \
  eval 'grep -qE "PRE +RELCMD +SWITCH" "$E/rh1.out" && echo "$hrow" | awk -F "\t" "{ exit !(NF == 13 && \$13 ~ /^[0-9]+[.][0-9]\$/) }" &&
        "$R" history -a relc --json | grep -qE "\"release_s\":[0-9]"'
check "22e2 an app without a release command keeps the 7-step box and a history without RELCMD" \
  eval 'grep -qE "7/7 +verify" "$E/dwait.out" && ! COLUMNS=160 "$R" history -a hello | grep -q RELCMD'

# 22f-m. a failing release command, under a request loop: the deploy fails, nothing is switched, no
# request fails, the box and the history say why with the command's last lines and the backup's id
rm -f "$E/rloop.stop"
( while [ ! -f "$E/rloop.stop" ]; do
    curl -s -o /dev/null -m 30 -w '%{http_code}\n' "http://relc.localhost:$HP/"; sleep 0.1
  done ) > "$E/rloop" &
RLOOP=$!
rdeploy 2 fail r2
touch "$E/rloop.stop"; wait $RLOOP
idr2=$(rid "$E/r2.out")
n=$(grep -c . "$E/rloop"); bad=$(grep -cv '^200$' "$E/rloop")
check "22f a failing release command fails the deploy (rc=$rc)" test "$rc" != 0
check "22g ... under load: $n requests, $bad failed; the old release still serves ($(rpage))" \
  test "$bad" = 0 -a "$n" -gt 5 -a "$(rpage)" = "relc v1 schema=1"
check "22h the box says the release command failed, its exit status and its last output" \
  eval 'flat "$E/r2.out" | grep -q "release command failed (exit status 3), so nothing was switched" &&
        flat "$E/r2.out" | grep -q "migration 0007 failed: column exists"'
bkid=$(flat "$E/r2.out" | grep -oE 'backup [0-9]{8}-[0-9]{6}-predeploy' | head -1 | cut -d' ' -f2)
check "22i the message names the pre-deploy backup (${bkid:-none}): it exists and holds the data as it was before the command" \
  eval '[ -n "$bkid" ] && srv "sudo tar -tzf /var/backups/tando/relc/$bkid/data.tar.gz" > "$E/r2.tar" &&
        grep -q "schema" "$E/r2.tar" && ! grep -q partial "$E/r2.tar"'
check "22j the release phase is the failed one, nothing after it ran; the release is gone, v1's stays current" \
  eval 'grep -qE "6/8 +release" "$E/r2.out" && ! grep -qE "7/8 +switch +[0-9]" "$E/r2.out" &&
        ! srv "sudo test -e $RD/releases/$idr2" && [ "$(st relc current)" = "$idr1" ] && [ "$(st relc phase)" = idle ]'
"$R" history -a relc > "$E/rh2.out" 2>&1; cat "$E/rh2.out" >&2
check "22k history shows the failed deploy and why, with the output's last line" \
  eval 'grep -q "$idr2.*failed" "$E/rh2.out" && flat "$E/rh2.out" | grep -q "release command failed (exit status 3)" &&
        flat "$E/rh2.out" | grep -q "migration 0007 failed"'
check "22l tando restored nothing: what the command wrote before it failed is still in the data" \
  srv "sudo test -f $RD/shared/data/partial"
"$R" logs -a relc --deploy "$idr2" > "$E/r2.log" 2>&1; "$R" logs -a relc --release "$idr2" > "$E/r2b.log" 2>&1
check "22m the command's whole output: tando logs --deploy <id> (and --release <id>, as the box says)" \
  eval 'grep -q "migrating to 2 as uid $uidr" "$E/r2.log" && grep -q "migration 0007 failed" "$E/r2.log" &&
        grep -q "migrating to 2 as uid $uidr" "$E/r2b.log"'

# 22n. a release command that does not end is stopped at release_timeout
conf_set tando.conf release_timeout 3
t0=$SECONDS; rdeploy 3 slow r3; secs=$((SECONDS - t0))
check "22n timeout: the deploy fails (rc=$rc) in ${secs}s saying release_timeout; v1 serves ($(rpage))" \
  eval '[ $rc != 0 ] && [ $secs -lt 120 ] && flat "$E/r3.out" | grep -q "did not finish within 3 s (release_timeout)" &&
        [ "$(rpage)" = "relc v1 schema=1" ]'
# (units that run, are starting or stopping, or failed: one that ended and is not unloaded yet is no trace)
relunits() { srv "systemctl list-units --plain --no-legend 'tando-relc-rel-*'"; }
check "22n2 the stopped command left no running or failed unit and no process of the app's user sleeping ($(relunits | tr -s ' \n' ' '))" \
  eval '[ -z "$(relunits)" ] && ! srv "pgrep -u tando-relc sleep"'
conf_set tando.conf release_timeout ''

# 22o. it does not run on rollback, restart or env set; a rollback does not undo what it did
rdeploy 4 ok r4; n4=$(nruns)
check "22o0 the next deploy works and runs it (rc=$rc, $(rpage), $n4 runs)" test "$rc" = 0 -a "$(rpage)" = "relc v4 schema=4" -a "$n4" = 2
"$R" rollback >&2; "$R" restart >&2; "$R" env set RELC_X=1 >&2
check "22o rollback, restart and env set do not run it ($n4 -> $(nruns) runs); the rollback did not undo it ($(rpage))" \
  test "$(nruns)" = "$n4" -a "$(rpage)" = "relc v1 schema=4"
# 22p. a release that fails after the switch: the command ran for the deploy, not for the automatic rollback
rport=$(srv "sudo sed -n 's/^port=//p' $RD/app.conf")
"$R" env set "UNHEALTHY_VERSION=5@$rport" >&2
rdeploy 5 ok r5; n5=$(nruns)
check "22p rolled back after the switch (rc=$rc): the command ran once, not again for the automatic rollback ($n4 -> $n5, $(rpage))" \
  eval '[ $rc != 0 ] && grep -q "rolled back" "$E/r5.out" && [ "$n5" = $((n4 + 1)) ] && [ "$(rpage)" = "relc v1 schema=5" ]'
# 22q. the same code again: it runs again (a deploy with a release command is never "already live")
"$R" env unset UNHEALTHY_VERSION >&2
rdeploy 5 ok r6; rc6=$rc n6=$(nruns)
rdeploy 5 ok r7; n7=$(nruns)
check "22q a deploy of unchanged code runs it again (rc=$rc6 $rc, $n6 -> $n7 runs, not \"already live\")" \
  eval '[ $rc6 = 0 ] && [ $rc = 0 ] && [ "$n7" = $((n6 + 1)) ] && ! grep -q "already live" "$E/r7.out"'
# 22r. release_shell = true: through sh -c, with the app's env
conf_set tando.conf release 'echo "shell $GREETING" > "$TANDO_DATA_DIR/shellran" && sh release.sh'
conf_set tando.conf release_shell true
rdeploy 6 ok r8
check "22r release_shell = true runs it with sh -c (rc=$rc, $(rpage), $(srv "sudo cat $RD/shared/data/shellran"))" \
  eval '[ $rc = 0 ] && [ "$(rpage)" = "relc v6 schema=6" ] && [ "$(srv "sudo cat $RD/shared/data/shellran")" = "shell hola" ]'
relc_log=$(srv "sudo stat -c %a:%U /opt/tando/apps/relc/env.log" 2>&1)
echo relc | "$R" destroy --purge > "$E/relc-destroy.out" 2>&1
check "22s destroy --purge removes the env log (it was $relc_log)" \
  eval '[ "$relc_log" = "600:root" ] && srv "sudo test ! -e /opt/tando/apps/relc"'
# <<< release-command

# 9. second app: own user, port, link; cannot read hello's env
cd "$W/site"
echo "job.tick = *:*:0/5 | mkdir -p \"\$TANDO_DATA_DIR\" && date +%s > \"\$TANDO_DATA_DIR/tick\"; echo ticked" >> tando.conf
"$R" env set STAGED_X=early > "$E/staged.out" 2>&1; cat "$E/staged.out" >&2
check "9s env set before the first up is staged" grep -q "staged for site (not on test yet)" "$E/staged.out"
"$R" up > "$E/site.out" 2>&1; cat "$E/site.out" >&2
"$R" env ls --show > "$E/stagedls.out" 2>&1
check "9t the first up applied the staged env" grep -q "STAGED_X *early" "$E/stagedls.out"
"$R" env log -a site --json > "$E/sitelog.json" 2>&1
check "9t2 the change staged before the app existed is the first entry of its env log" \
  eval 'grep -q "\"added\":\[\"STAGED_X\"\]" "$E/sitelog.json" && ! grep -q early "$E/sitelog.json"'
"$R" env set SITE_Y=1 -a site >&2
check "9t3 a static site (nothing restarts) logs a change too" \
  eval '"$R" env log -a site --json | grep -q "\"added\":\[\"SITE_Y\"\]"'
"$R" jobs run tick > "$E/jobrun.out" 2>&1; rc=$?; cat "$E/jobrun.out" >&2
check "9u jobs run tick: its output and ok (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -q "job tick: ok in" "$E/jobrun.out" && srv "sudo test -s /opt/tando/apps/site/shared/data/tick"'
check "9a site link answers" eval 'get site | grep -q "tando static site"'
p1=$(srv "sudo sed -n 's/^port=//p' /opt/tando/apps/hello/app.conf")
p2=$(srv "sudo sed -n 's/^port=//p' /opt/tando/apps/site/app.conf")
u=$(srv "sudo stat -c %U /opt/tando/apps/site/shared; sudo stat -L -c %U:%G /opt/tando/apps/site/current;
  pgrep -u tando-site | wc -l" | tr '\n' ' ')
check "9b site: own user and port (hello:$p1 site:$p2), served by Caddy, root:caddy release, no process ($u)" \
  test -n "$p2" -a "$p1" != "$p2" -a "$u" = "tando-site root:caddy 0 "
check "9f hello's user cannot read the static site's release" \
  eval '! srv "sudo -u tando-hello ls /opt/tando/apps/site/current/" > /dev/null 2>&1'
check "9c site user cannot read hello's env" \
  eval '! srv "sudo -u tando-site cat /opt/tando/apps/hello/env" 2> /dev/null'
readable=$(srv 'cd /opt/tando/apps/hello && for f in app.conf state activation history.tsv activation.log lock; do
  sudo -u tando-site cat $f > /dev/null 2>&1 && echo "$f"; sudo -u nobody cat $f > /dev/null 2>&1 && echo "$f"; done' |
  tr '\n' ' ')
check "9g other users cannot read hello's metadata (readable: ${readable:-none})" test -z "$readable"
modes=$(srv 'cd /opt/tando/apps/hello && stat -c "%n=%a:%G" app.conf state history.tsv activation.log' | tr '\n' ' ')
check "9h hello's metadata is 640 root:tando-m-hello, activation.log 600 ($modes)" \
  test "$modes" = "app.conf=640:tando-m-hello state=640:tando-m-hello history.tsv=640:tando-m-hello activation.log=600:root "
check "9i hello's own user reads its app.conf (exec-app needs it)" \
  eval 'srv "sudo -u tando-hello cat /opt/tando/apps/hello/app.conf" > /dev/null'
check "9d site user cannot read hello's release" \
  eval '! srv "sudo -u tando-site ls /opt/tando/apps/hello/current/" > /dev/null 2>&1'
check "9e hello user cannot write the release it runs" \
  eval '! srv "sudo -u tando-hello touch /opt/tando/apps/hello/current/x" 2> /dev/null'

# 8. boxed output at 80 and 120 columns, no line wider than the terminal
cd "$W/hello"
for w in 80 120; do
  for c in "ls" "status" "history" "releases" "status -a site" "doctor"; do
    COLUMNS=$w "$R" $c > "$E/view.out" 2>&1; rc=$?
    max=$(perl -CS -ne 's/\e\[[0-9;?]*[A-Za-z]//g; chomp; $m = length if length > $m; END { print $m+0 }' \
      < "$E/view.out")
    check "8 $c at $w columns: boxed, widest line $max" eval \
      "[ $rc = 0 ] && [ $max -le $w ] && head -1 '$E/view.out' | grep -q '^╭' &&
       tail -1 '$E/view.out' | grep -q '^╰'"
    [ $w = 80 ] && cat "$E/view.out" >&2
  done
done

# 10. scheduled job runs as the app user; no command text in unit files
until_ 20 srv "sudo test -s /opt/tando/apps/site/shared/data/tick"
check "10a job ran as tando-site" \
  test "$(srv 'sudo stat -c %U /opt/tando/apps/site/shared/data/tick' 2> /dev/null)" = tando-site
check "10b job command not in any unit file" \
  eval '! srv "grep -rl \"date +%s\" /etc/systemd/system/" > /dev/null 2>&1'
(cd "$W/site" && "$R" jobs >&2)

# 17. doctor: clean host passes; a changed agent shows as drift
"$R" doctor > "$E/doc.out" 2>&1; rc=$?
check "17a doctor on a healthy host: no failures (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -q "agent.*same as the client" "$E/doc.out"'
srv "echo '# drift' | sudo tee -a $AGENT > /dev/null"
"$R" doctor > "$E/doc2.out" 2>&1; cat "$E/doc2.out" >&2; "$R" doctor --verbose > "$E/doc2v.out" 2>&1
check "17b doctor reports agent drift (one row; --verbose names the agent), its fix not cut at 80 columns" \
  eval 'grep -q "1 of [0-9]* programs differ" "$E/doc2.out" &&
        grep -qE "agent.*(differs from the client|differs from this tando|changed since setup)" "$E/doc2v.out" &&
        tr -d "│\n" < "$E/doc2.out" | tr -s " " | grep -q "tando host setup test"'
"$R" host setup test > /dev/null 2>&1

# 19g-i. a failed first up leaves a resumable app; destroy asks for the name
cd "$W" || exit 2
rm -rf "${W:?}/broke"; cp -R "$ROOT/examples/hello" broke; cd broke || exit 2
conf_set tando.conf app broke
ln -s /etc/passwd passwd
"$R" up > "$E/broke.out" 2>&1; rc=$?; cat "$E/broke.out" >&2
check "19g stage failure: a failed stage step in the box, nothing created on the server" \
  eval '[ $rc != 0 ] && grep -q "✗ 2/7  stage" "$E/broke.out" && ! srv "test -d /opt/tando/apps/broke"'
rm passwd
"$R" up > "$E/broke2.out" 2>&1; rc=$?
check "19h up again creates and deploys it" eval '[ $rc = 0 ] && get broke | grep -q "hello v1"'
echo wrong | "$R" destroy > "$E/d-wrong.out" 2>&1; rc=$?
check "19i destroy refuses a wrong name" eval '[ $rc != 0 ] && srv "test -d /opt/tando/apps/broke"'
# every trace a feature leaves for an app: users and groups, files, units, journals, alerts
traces() {
  srv 'a=broke; for u in tando-$a tando-d-$a; do getent passwd $u; done; for g in tando-$a tando-m-$a; do getent group $g; done
    sudo sh -c "ls -d /opt/tando/apps/$a /opt/tando/ci/$a /etc/sudoers.d/tando-d-$a /etc/systemd/journald@tando-$a.conf \
      /var/log/journal/*.tando-$a /var/log/tando/$a /var/cache/tando-logs/$a.stats /var/lib/tando/metrics/$a.tsv* \
      /etc/caddy/tando/$a.caddy /etc/systemd/system/tando-$a.service /etc/systemd/system/tando-$a-* \
      /var/backups/tando/$a /opt/tando/run/$a-* 2> /dev/null"
    systemctl list-units --all --plain --no-legend "tando-$a*" "*@tando-$a*" | awk "\$3 != \"inactive\" {print \$1}"
    sudo grep -l "^$a\\." /var/lib/tando/watch/state 2> /dev/null' | sort -u
}
(cd "$W/broke" && "$R" ci setup > /dev/null 2>&1)
"$R" backup now > /dev/null 2>&1
srv "sudo systemctl start tando-watch.service"     # a metrics sample and an alert run for broke
# an app whose name starts with "broke-" must survive destroying broke (tando-broke-* globs)
rm -rf "${W:?}/broke-2"; cp -R "$W/broke" "$W/broke-2"; rm -rf "$W/broke-2/.tando"
conf_set "$W/broke-2/tando.conf" app broke-2
(cd "$W/broke-2" && printf 'job.tick = hourly | true\n' >> tando.conf && "$R" up > "$E/broke2up.out" 2>&1) ||
  cat "$E/broke2up.out" >&2
before=$(traces | wc -l | tr -d ' ')
echo broke | "$R" destroy --purge > "$E/d-ok.out" 2>&1; rc=$?; cat "$E/d-ok.out" >&2
check "19l destroy broke leaves broke-2 alone: its unit, job timer and link" \
  eval 'srv "systemctl -q is-active tando-broke-2 && systemctl -q is-enabled tando-broke-2_job-tick.timer" &&
        get broke-2 | grep -q "hello v"'
(cd "$W/broke-2" && echo broke-2 | "$R" destroy --purge > /dev/null 2>&1)
traces > "$E/left"
# (a stopped unit that systemd has not unloaded yet is not a trace: only units that are not
# inactive count. What state the leftovers are in, for the log:)
[ -s "$E/left" ] && srv 'systemctl list-units --all --plain --no-legend "tando-broke*" "*@tando-broke*"; systemctl list-jobs --no-legend | head -20' >&2
code=$(curl -s -o /dev/null -w '%{http_code}' http://broke.localhost:$HP/)
check "19j destroy --purge removes every trace ($before before, left: $(tr '\n' ' ' < "$E/left"), http $code)" \
  test $rc = 0 -a "$before" -ge 6 -a ! -s "$E/left" -a "$code" = 404

# 19k. a long TANDO_CONFIG_DIR still works (ssh control socket path budget)
long=$E/a-config-directory-with-a-rather-long-name-to-test-the-socket-path
mkdir -p "$long"; cp -R "$E/cfg/hosts" "$long/"; cp "$E/cfg/known_hosts" "$long/" 2> /dev/null
(cd "$W/hello" && TANDO_CONFIG_DIR=$long "$R" ls > "$E/long.out" 2>&1); rc=$?
check "19k long config dir (${#long} chars): ls works" test $rc = 0

# S. security review fixes: each reproduces the attack and expects it to fail closed
# S1 (F1). an app's user cannot reach Caddy's admin API: not on TCP 2019, socket closed to it
hp=$(srv "sudo sed -n 's/^port=//p' /opt/tando/apps/hello/app.conf")
tcp=$(srv "sudo -u tando-hello curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:2019/config/" 2>&1)
sock=$(srv "sudo -u tando-hello curl -s -m 3 -o /dev/null -w '%{http_code}' --unix-socket /run/caddy/admin.sock \
  http://localhost/config/" 2>&1)
rootsock=$(srv "sudo curl -s -m 3 -o /dev/null -w '%{http_code}' --unix-socket /run/caddy/admin.sock http://localhost/config/")
# (root gets an HTTP answer through the socket: 200 on Caddy 2.11, 403 for this Host on 2.6.2)
check "S1 Caddy admin: app user gets nothing on 2019 ($tcp) or the socket ($sock); root reaches it ($rootsock)" \
  test "$tcp" = 000 -a "$sock" = 000 -a "$rootsock" != 000
# S2 (F1). an app's user cannot reach another app's port on loopback; its own works
other=$(srv "sudo -u tando-site curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:$hp/" 2>&1)
own=$(srv "sudo -u tando-hello curl -s -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:$hp/" 2>&1)
check "S2 loopback rules: tando-site to hello's port $hp: $other, tando-hello to its own: $own" \
  test "$other" = 000 -a "$own" = 200
# S3 (F7). a file name with a newline and C1 controls cannot forge history rows or reach the terminal
n0=$(srv "sudo cat /opt/tando/apps/hello/history.tsv" | wc -l | tr -d ' ')
tok=$(srv "sudo $AGENT begin hello e2e" | sed -n 's/^token=//p')
srv "sudo bash -s" <<'EOF'
n=$(printf '.env\302\2332J\nforged=1\tok')
printf x > "/opt/tando/apps/hello/incoming/$n"
EOF
id=$(echo "$tok" | srv "sudo $AGENT activate hello 0 0" | sed -n 's/^id=//p')
until_ 20 eval '[ -n "$(srv "sudo $AGENT deploy-status hello $id" | grep "^result=failed")" ]'
n1=$(srv "sudo cat /opt/tando/apps/hello/history.tsv" | wc -l | tr -d ' ')
raw=$(srv "sudo sh -c 'tail -1 /opt/tando/apps/hello/history.tsv; cat /opt/tando/apps/hello/activation'" |
  LC_ALL=C grep -c "$(printf '\302\233')")
keys=$(srv "sudo grep -c '^forged' /opt/tando/apps/hello/activation")
srv "sudo find /opt/tando/apps/hello/incoming -name '.env*' -delete"
check "S3 a forged file name: one history row ($n0 -> $n1), no C1 byte ($raw), no injected key ($keys)" \
  test "$n1" = $((n0 + 1)) -a "$raw" = 0 -a "$keys" = 0

# AS. fingerprinted assets: a page of the old release asks for the old release's hashed files
# (docs/ARCHITECTURE.md "Assets"). A Vite-like static site (assets/index-<hash>.js, found by its names)
# and a node app with `assets = public/build, /build/` that sets a header of its own.
ah() { curl -s -m 5 -D - -o /dev/null "http://$1.localhost:$HP$2" | tr -d '\r'; }   # headers of a GET
site_release() { # dir n: release n of the site: a hashed js and css, an unhashed page
  mkdir -p "$1/assets"; rm -f "$1"/assets/*
  AS_H=$(printf 'rel%s' "$2" | cksum | cut -d' ' -f1)
  { echo "console.log('release $2');"; head -c 3000 /dev/zero | tr '\0' ' '; } > "$1/assets/index-$AS_H.js"
  echo "b{c:$2}" > "$1/assets/style-$AS_H.css"; mkdir -p "$E/ref"; cp "$1/assets/index-$AS_H.js" "$E/ref/rel$2.js"
  printf '<!doctype html><script src=/assets/index-%s.js></script><h1>release %s</h1>\n' "$AS_H" "$2" > "$1/index.html"
}
mkdir -p "$W/skew"; printf 'app = skew\nrecipe = static\n' > "$W/skew/tando.conf"
cd "$W/skew" || exit 2
site_release "$W/skew" 1; H1=$AS_H
"$R" up > "$E/as1.out" 2>&1; rc=$?
"$R" domain add skew.example.test --force > "$E/asdom.out" 2>&1   # (no DNS here: --force)
check "AS0 the static site deploys (rc=$rc)" test $rc = 0 -a "$(get skew | grep -c 'release 1')" = 1
for n in 2 3; do site_release "$W/skew" $n; "$R" deploy > "$E/as$n.out" 2>&1; done; H3=$AS_H
# shellcheck disable=SC2034  # read in the eval of a check below
hdr=$(ah skew "/assets/index-$H1.js")
check "AS1 release 1's hashed file still answers after releases 2 and 3 went live, with the immutable header" \
  eval 'echo "$hdr" | head -1 | grep -q " 200" && echo "$hdr" | grep -qi "^cache-control: public, max-age=31536000, immutable"'
check "AS1b its bytes are release 1's" eval '[ "$(curl -s "http://skew.localhost:$HP/assets/index-$H1.js" | cksum)" = "$(cksum < "$E/ref/rel1.js")" ]'
check "AS2 the page itself gets no caching header from tando" eval '! ah skew / | grep -qi "^cache-control"'
check "AS2b a path that is not in the shared directory is the site's: its 404 gets no caching header either" \
  eval 'h=$(ah skew /assets/none-12345678.js); echo "$h" | head -1 | grep -q " 404" && ! echo "$h" | grep -qi "^cache-control"'
check "AS2c a custom domain of the site is in the same site block as the assets handle, and Caddy accepts the file" \
  eval 'srv "sudo grep -q tandoassets /etc/caddy/tando/skew.caddy" && srv "sudo grep -q skew.example.test /etc/caddy/tando/skew.caddy" &&
        srv "sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile" > /dev/null 2>&1'
check "AS2d a Host with a port is still answered 400 (not served from the shared directory)" \
  eval '[ "$(curl -s -o /dev/null -w "%{http_code}" -H "Host: skew.localhost:99" "http://127.0.0.1:$HP/assets/index-$H1.js")" = 400 ]'
links=$(srv "sudo stat -c %h /opt/tando/apps/skew/assets/assets/index-$H3.js")
check "AS3 the shared file is a hard link of the release's (link count $links): no second copy on disk" test "$links" -ge 2
# rollback: its own assets
"$R" rollback > "$E/asrb.out" 2>&1; rc=$?
check "AS4 after a rollback the page is release 2's and its file answers with its own bytes (rc=$rc)" \
  eval '[ $rc = 0 ] && get skew | grep -q "release 2" && src=$(get skew | grep -o "/assets/index-[^ >]*\.js") &&
        [ "$(curl -s "http://skew.localhost:$HP$src" | cksum)" = "$(cksum < "$E/ref/rel2.js")" ]'
"$R" deploy > "$E/as4.out" 2>&1
# pruning: five more releases push release 1 out
for n in 4 5 6 7 8; do site_release "$W/skew" $n; "$R" deploy > "$E/as$n.out" 2>&1; done
# shellcheck disable=SC2034  # read in the eval of a check below
H8=$AS_H
nrel=$(srv "sudo ls /opt/tando/apps/skew/releases | wc -l" | tr -d ' ')
code1=$(curl -s -o /dev/null -w '%{http_code}' "http://skew.localhost:$HP/assets/index-$H1.js")
on1=$(srv "sudo find /opt/tando/apps/skew/assets /opt/tando/apps/skew/assetlog -name '*$H1*' | wc -l" | tr -d ' ')
check "AS5 release 1 was pruned (kept $nrel releases): its file answers $code1 and is gone from disk ($on1 left)" \
  eval '[ "$code1" = 404 ] && [ "$on1" = 0 ] && [ "$(curl -s -o /dev/null -w "%{http_code}" "http://skew.localhost:$HP/assets/index-$H8.js")" = 200 ]'
nfiles=$(srv "sudo find /opt/tando/apps/skew/assets -type f | wc -l" | tr -d ' ')
nlist=$(srv "sudo cat \$(sudo find /opt/tando/apps/skew/assetlog -maxdepth 1 -type f ! -name '*.*') | sort -u | wc -l" | tr -d ' ')
check "AS5b the shared directory holds exactly what the kept releases list ($nfiles files, $nlist listed)" test "$nfiles" = "$nlist" -a "$nfiles" -ge 2
# CG0. precompressed copies of the hashed text files (made at link time; listed so pruning takes them)
AD=/opt/tando/apps/skew
check "CG0a release 8's script has a .gz in the shared directory, and its tiny stylesheet (under 1 KB) has none" \
  eval 'srv "test -f $AD/assets/assets/index-$H8.js.gz" && srv "test -f $AD/assets/assets/style-$H8.css" && ! srv "test -e $AD/assets/assets/style-$H8.css.gz"'
ngz=$(srv "find $AD/assets -name '*.gz' | wc -l" | tr -d ' ')
orph=$(srv "cd $AD/assets && find . -name '*.gz' | while read -r g; do [ -f \"\${g%.gz}\" ] || echo \"\$g\"; done" | wc -l | tr -d ' ')
listed=$(srv "sudo cat \$(sudo find $AD/assetlog -maxdepth 1 -type f ! -name '*.*') | grep -c '\\.gz\$'" | tr -d ' ')
check "CG0b the kept releases list the .gz files ($ngz on disk, $listed listed, $orph without their file), and release 1's went with it when it was pruned" \
  eval '[ "$orph" = 0 ] && [ "$ngz" -ge 1 ] && [ "$listed" -ge 1 ] && [ -z "$(srv "find $AD/assets -name \"*$H1*\"")" ]'
curl -s -m 5 -H 'Accept-Encoding: gzip' -D "$E/cg.h" -o "$E/cg.gz" "http://skew.localhost:$HP/assets/index-$H8.js"
check "CG0c a visitor that accepts gzip gets the precompressed file: Content-Encoding gzip, Vary, the immutable header, and after gunzip the same bytes" \
  eval 'tr -d "\r" < "$E/cg.h" | grep -qi "^content-encoding: gzip" && tr -d "\r" < "$E/cg.h" | grep -qi "^vary: .*accept-encoding" &&
        tr -d "\r" < "$E/cg.h" | grep -qi "^cache-control: public, max-age=31536000, immutable" &&
        [ "$(gunzip -c "$E/cg.gz" | cksum)" = "$(cksum < "$E/ref/rel8.js")" ] && [ "$(wc -c < "$E/cg.gz")" -lt 500 ]'
check "CG0d one that does not accept it gets the plain bytes, no Content-Encoding" \
  eval 'h=$(curl -s -m 5 -H "Accept-Encoding: identity" -D - -o "$E/cg.id" "http://skew.localhost:$HP/assets/index-$H8.js" | tr -d "\r"); ! echo "$h" | grep -qi "^content-encoding" &&
        [ "$(cksum < "$E/cg.id")" = "$(cksum < "$E/ref/rel8.js")" ]'
# detection says nothing about names that are not hashed: no mount, no header
mkdir -p "$W/plain/assets"; printf 'app = plain\nrecipe = static\n' > "$W/plain/tando.conf"
echo "x" > "$W/plain/assets/app.js"; echo "x" > "$W/plain/assets/logo-large.png"; echo "<h1>plain</h1>" > "$W/plain/index.html"
(cd "$W/plain" && "$R" up > "$E/asp.out" 2>&1)
check "AS6 a directory whose names are not all hashed is not shared and gets no caching header" \
  eval '! ah plain /assets/app.js | grep -qi "^cache-control" && [ "$(get plain /assets/app.js)" = x ] &&
        [ -z "$(srv "sudo ls /opt/tando/apps/plain/assetlog 2> /dev/null")" ] && ! srv "sudo grep -q tandoassets /etc/caddy/tando/plain.caddy"'
# a single-page app (spa = true): its router's fallback (index.html for a path that is no file) is a
# rewrite, which Caddy runs before the assets handle: it must never answer under an assets prefix
mkdir -p "$W/spa"; printf 'app = spa\nrecipe = static\nspa = true\n' > "$W/spa/tando.conf"
cd "$W/spa" || exit 2
site_release "$W/spa" 1
# shellcheck disable=SC2034  # read in the eval of a check below
SP1=$AS_H
"$R" up > "$E/spa1.out" 2>&1; rc=$?
site_release "$W/spa" 2; "$R" deploy > "$E/spa2.out" 2>&1; rc2=$?
check "AS8 spa = true (rc=$rc/$rc2): an older release's hashed file answers with its own bytes as JavaScript, not index.html" \
  eval '[ "$(curl -s "http://spa.localhost:$HP/assets/index-$SP1.js" | cksum)" = "$(cksum < "$E/ref/rel1.js")" ] &&
        ah spa "/assets/index-$SP1.js" | grep -qi "^content-type: text/javascript"'
check "AS8b spa = true: a hashed file that is in no release is a 404, never index.html" \
  eval 'ah spa /assets/index-99999999.js | head -1 | grep -q " 404" && ! curl -s "http://spa.localhost:$HP/assets/index-99999999.js" | grep -q "<h1>release"'
check "AS8c spa = true: a deep link of the router is still the live index.html" \
  eval 'get spa /orders/42 | grep -q "<h1>release 2" && get spa / | grep -q "<h1>release 2"'
# a node app: assets = <dir>, <url prefix>; its own Cache-Control stays
mkdir -p "$W/skewn/public/build"; cd "$W/skewn" || exit 2
cat > server.js <<'JS'
const http = require("http"), fs = require("fs"), path = require("path");
http.createServer((req, res) => {
  const u = req.url.split("?")[0];
  if (u.startsWith("/build/")) {   // the app's own caching for its files
    const f = path.join(__dirname, "public", u);
    if (!fs.existsSync(f)) { res.statusCode = 404; return res.end("no"); }
    res.setHeader("Cache-Control", "public, max-age=3600"); return res.end(fs.readFileSync(f));
  }
  res.end("node release " + fs.readFileSync(path.join(__dirname, "VERSION"), "utf8").trim());
}).listen(process.env.PORT, "127.0.0.1");
JS
printf 'app = skewn\nrecipe = node\nstart = node server.js\nhealth = /\nmemory = 128M\nassets = public/build, /build/\n' > tando.conf
echo 1 > VERSION; echo "var r=1;" > public/build/app-7f3a9c21.js
"$R" up > "$E/asn1.out" 2>&1; rc=$?
echo 2 > VERSION; rm -f public/build/app-7f3a9c21.js; echo "var r=2;" > public/build/app-b81d40e5.js
"$R" deploy > "$E/asn2.out" 2>&1
# shellcheck disable=SC2034  # read in the eval of a check below
h=$(ah skewn /build/app-7f3a9c21.js)
check "AS7 node app: release 1's file (gone from the app) answers 200 after release 2; the app's own Cache-Control is what it carries (rc=$rc)" \
  eval 'echo "$h" | head -1 | grep -q " 200" && echo "$h" | grep -qi "^cache-control: public, max-age=3600$" && ! echo "$h" | grep -qi immutable'
check "AS7b the app answers what the shared directory does not hold (a file made after the deploy)" \
  eval 'srv "sudo sh -c '"'"'echo late > /opt/tando/apps/skewn/current/public/build/late.js'"'"'"; [ "$(get skewn /build/late.js)" = late ]'
check "AS7c a container app with assets is refused by the server" \
  eval 'agent_check container "assets=assets" | grep -q "assets is not supported for a container"'
check "AS7d a bad assets value is refused (a path outside the release)" \
  eval 'agent_check node "assets=../etc" | grep -q "bad assets"'
# CZ. compression (docs/CONFIG.md "compress"): Caddy's encode for text answers, never twice, never
# for a stream; `compress = off` sends everything as it is. A node app that makes each kind of answer.
mkdir -p "$W/cz"; cp "$ROOT/test/fixtures/compress-server.js" "$W/cz/server.js"; cd "$W/cz" || exit 2
printf 'app = cz\nrecipe = node\nstart = node server.js\nhealth = /\nmemory = 128M\n' > tando.conf
"$R" up > "$E/cz1.out" 2>&1; rc=$?
czu() { echo "http://cz.localhost:$HP$1"; }
czh() { curl -s -m 8 -D - -o /dev/null -H "Accept-Encoding: $1" "$(czu "$2")" | tr -d '\r'; }   # headers
check "CZ0 the compression test app deploys (rc=$rc)" test $rc = 0 -a "$(get cz /)" = ok
check "CZ1 a 68 KB text answer to a visitor that accepts gzip is gzip with Vary: Accept-Encoding, and gunzip gives the bytes of the plain answer" \
  eval 'h=$(czh gzip /big); echo "$h" | grep -qi "^content-encoding: gzip" && echo "$h" | grep -qi "^vary: .*accept-encoding" &&
        [ "$(curl -s -m 8 -H "Accept-Encoding: gzip" "$(czu /big)" | gunzip | cksum)" = "$(curl -s -m 8 "$(czu /big)" | cksum)" ] &&
        [ "$(curl -s -m 8 -H "Accept-Encoding: gzip" "$(czu /big)" | wc -c)" -lt 20000 ]'
check "CZ1b zstd is used when the visitor accepts it, and its bytes decode to the same too" \
  eval 'czh "gzip, zstd" /big | grep -qi "^content-encoding: zstd" &&
        [ "$(curl -s -m 8 -H "Accept-Encoding: zstd" "$(czu /big)" | zstd -dc | cksum)" = "$(curl -s -m 8 "$(czu /big)" | cksum)" ]'
check "CZ2 a visitor that sends no Accept-Encoding gets the plain answer (68 KB, no Content-Encoding)" \
  eval '! curl -s -D - -o /dev/null "$(czu /big)" | grep -qi "^content-encoding" && [ "$(curl -s "$(czu /big)" | wc -c)" -gt 60000 ]'
check "CZ3 an app that compresses by itself is not compressed again: one gzip layer, the app's own bytes" \
  eval 'h=$(czh "gzip, zstd" /own); [ "$(echo "$h" | grep -ci "^content-encoding")" = 1 ] && echo "$h" | grep -qi "^content-encoding: gzip" &&
        [ "$(curl -s -m 8 -H "Accept-Encoding: gzip, zstd" "$(czu /own)" | gunzip | cksum)" = "$(curl -s -m 8 "$(czu /big)" | cksum)" ]'
sse=$(curl -sN -m 10 -H 'Accept-Encoding: gzip' -D "$E/cz.sse.h" -w '%{time_starttransfer} %{time_total}' "$(czu /sse)")
sse_first=$(echo "$sse" | tail -1 | awk '{print $1}'); sse_total=$(echo "$sse" | tail -1 | awk '{print $2}')
check "CZ4 an event stream (4 events, 400 ms apart) still streams: the first byte after ${sse_first}s of ${sse_total}s, all 4 events, not compressed" \
  eval 'awk -v a="$sse_first" -v b="$sse_total" "BEGIN { exit !(b > 1.0 && a < 0.5 && a < b / 2) }" && [ "$(echo "$sse" | grep -c "^data: ")" = 4 ] &&
        ! grep -qi "^content-encoding" "$E/cz.sse.h"'
# shellcheck disable=SC2034  # read in the eval of a check below
ws=$(curl -s -m 5 -i --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' -H 'Accept-Encoding: gzip' "$(czu /ws)")
check "CZ5 a websocket upgrade still switches protocols and the app's bytes after it arrive" \
  eval 'echo "$ws" | head -1 | grep -q " 101" && echo "$ws" | tail -1 | grep -q "ws-ok" && ! echo "$ws" | grep -qi "^content-encoding"'
check "CZ6 a custom domain of the site is in the same block as encode, and Caddy 2.6 accepts the file" \
  eval '"$R" domain add cz.example.test --force > "$E/czdom.out" 2>&1; srv "sudo grep -q \"encode zstd gzip\" /etc/caddy/tando/cz.caddy" &&
        srv "sudo grep -q cz.example.test /etc/caddy/tando/cz.caddy" && srv "sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile" > /dev/null 2>&1 &&
        czh gzip /big | grep -qi "^content-encoding: gzip"'
"$R" stop > "$E/cz-stop.out" 2>&1; "$R" start > "$E/cz-start.out" 2>&1
check "CZ7 after stop and start the site is still compressed" eval 'czh gzip /big | grep -qi "^content-encoding: gzip"'
printf 'app = cz\nrecipe = node\nstart = node server.js\nhealth = /\nmemory = 128M\ncompress = off\n' > tando.conf
"$R" deploy > "$E/cz2.out" 2>&1; rc=$?
check "CZ8 compress = off (rc=$rc): the same visitor gets the plain 68 KB, no Content-Encoding, no Vary, and the site has no encode line" \
  eval 'h=$(czh "gzip, zstd" /big); [ $rc = 0 ] && ! echo "$h" | grep -qi "^content-encoding" && ! echo "$h" | grep -qi "^vary" &&
        ! srv "sudo grep -q encode /etc/caddy/tando/cz.caddy" && [ "$(curl -s -m 8 -H "Accept-Encoding: gzip" "$(czu /big)" | wc -c)" -gt 60000 ]'
cp tando.conf "$E/cz-keep.conf"; echo "compress = maybe" >> tando.conf
# shellcheck disable=SC2034  # read in the eval of a check below
czbad=$("$R" deploy 2>&1); cp "$E/cz-keep.conf" tando.conf
check "CZ9 a bad value is refused by the client and by the server" \
  eval 'echo "$czbad" | grep -q "compress must be on or off" && agent_check node "compress=maybe" | grep -q "compress must be on or off"'
cd "$W/skewn" || exit 2   # (the next section, HL, works in the node app of AS7)
# HL. a release shares the live release's unchanged files by hard link (docs/ARCHITECTURE.md "copy"):
# never a file of a writable or assets directory, never one the app can write, and no change to one
# release shows in another
mkdir -p lib cache; head -c 200000 /dev/urandom > lib/same.bin; echo seed > cache/seed.txt
printf 'writable = cache\n' >> tando.conf
echo 3 > VERSION; "$R" deploy > "$E/hl3.out" 2>&1; hl3=$(rid "$E/hl3.out")
echo 4 > VERSION; "$R" deploy > "$E/hl4.out" 2>&1; rc=$?; hl4=$(rid "$E/hl4.out")
RA=/opt/tando/apps/skewn/releases
hl() { srv "sudo stat -c '%i %h %U %a' $RA/$1/$2" 2> /dev/null; }
# shellcheck disable=SC2034  # read in the eval of a check below
a3=$(hl "$hl3" lib/same.bin) a4=$(hl "$hl4" lib/same.bin)
check "HL1 an unchanged file is one file in both releases, root's, mode 640 (rc=$rc; $a3 / $a4)" \
  eval '[ $rc = 0 ] && [ -n "$a3" ] && [ "$a3" = "$a4" ] && [ "${a4#* }" = "2 root 640" ]'
check "HL2 the app's user cannot write it" \
  eval '! srv "sudo -u tando-skewn sh -c \"echo x >> $RA/$hl4/lib/same.bin\"" 2> /dev/null'
check "HL3 a file of a writable directory is the release's own (the app's, one link)" \
  eval '[ "$(hl "$hl4" cache/seed.txt | cut -d" " -f2,3)" = "1 tando-skewn" ] &&
        [ "$(hl "$hl3" cache/seed.txt | cut -d" " -f1)" != "$(hl "$hl4" cache/seed.txt | cut -d" " -f1)" ]'
check "HL4 a file of the assets directory is not shared with the other release (only with what Caddy serves)" \
  eval '[ "$(hl "$hl3" public/build/app-b81d40e5.js | cut -d" " -f1)" != "$(hl "$hl4" public/build/app-b81d40e5.js | cut -d" " -f1)" ]'
check "HL5 every file the new release shares with another is root's with mode 640 or 750" \
  eval '[ -z "$(srv "sudo find $RA/$hl4 ! -type d ! -type l -links +1 ! -path \"*/public/build/*\" \\( ! -user root -o ! \\( -perm 640 -o -perm 750 \\) \\) -print")" ]'
# HL6: the import sets owner and mode only where they differ (release_own, the agent's own
# function): the same result as chown -R and chmod -R on a tree of every kind of entry, and a file
# that is already right (as a shared one is) is not touched (its ctime stays)
hl6=$(srv "sudo bash -s" 2>&1 <<'EOF'
eval "$(sed -n '/^release_own() {/,/^}/p' /opt/tando/bin/tando-agent)"
t=$(mktemp -d)
for x in a b; do
  mkdir -p $t/$x/d/e $t/$x/s; chmod 700 $t/$x/d; chmod 2775 $t/$x/s
  for m in 600 644 755 4755 777 640 750 444 711; do echo $m > $t/$x/d/f$m; chmod $m $t/$x/d/f$m; done
  echo n > $t/$x/d/e/nobody; chown nobody:nogroup $t/$x/d/e/nobody; ln -s d/f600 $t/$x/l; ln -s /etc/hostname $t/$x/d/out
  chown -h nobody $t/$x/l; chown root:nogroup $t/$x/d/f640 $t/$x/d/f750
done
c0=$(stat -c %Z.%z $t/b/d/f640 $t/b/d/f750); sleep 0.1   # (proves nothing happens: a wait)
chown -RhP root:nogroup $t/a && chmod -R a-st,u=rwX,g=rX,o= $t/a; release_own $t/b nogroup || echo "release_own failed"
c1=$(stat -c %Z.%z $t/b/d/f640 $t/b/d/f750)
diff <(cd $t/a && find . -printf '%P %U %G %m %y\n' | sort) <(cd $t/b && find . -printf '%P %U %G %m %y\n' | sort) || echo "differs from chown/chmod -R"
[ "$c0" = "$c1" ] || echo "a file already right was changed (ctime $c0 -> $c1)"
type release_own > /dev/null 2>&1 || echo "no release_own in the agent"
rm -rf "$t"
EOF
)
check "HL6 the import's owner and mode are those of chown -R and chmod -R, and a file already right is not touched (${hl6:-same})" test -z "$hl6"
# HL7-HL9: with the live release's manifest (sums/<id>) the import reads none of the live
# release's bytes: an unchanged file's access time stays as set (a read sets it: relatime) and it
# is still shared; a same-size change is copied. Without a manifest (an older agent's release) or
# with a damaged one, the import compares bytes as before (a manifest whose line was changed would
# otherwise link the old bytes)
SM=/opt/tando/apps/skewn/sums
srv "sudo touch -a -d 2001-01-01 $RA/$hl4/lib/same.bin"
at4=$(srv "sudo stat -c '%i %X' $RA/$hl4/lib/same.bin")
echo one > lib/flip.txt
echo 5 > VERSION; "$R" deploy > "$E/hl5.out" 2>&1; rc=$?; hr5=$(rid "$E/hl5.out")
# shellcheck disable=SC2034  # read in the eval of a check below
at5=$(srv "sudo stat -c '%i %X' $RA/$hr5/lib/same.bin")
check "HL7 the next import read no byte of the live release's unchanged file and shares it (rc=$rc; $at4 / $at5); a same-size change is copied" \
  eval '[ $rc = 0 ] && [ -n "$at4" ] && [ "$at4" = "$at5" ] && [ "$(srv "sudo cat $RA/$hr5/VERSION")" = 5 ] && srv "sudo test -s $SM/$hr5"'
srv "sudo rm -f $SM/$hr5"
echo two > lib/flip.txt
echo 6 > VERSION; "$R" deploy > "$E/hl6.out" 2>&1; rc=$?; hr6=$(rid "$E/hl6.out")
check "HL8 a live release without a manifest: the import compares bytes (rc=$rc): the change is copied, the rest shared, a manifest written" \
  eval '[ $rc = 0 ] && [ "$(srv "sudo cat $RA/$hr6/lib/flip.txt $RA/$hr6/VERSION" | tr "\n" " ")" = "two 6 " ] &&
        [ "$(hl "$hr5" lib/same.bin | cut -d" " -f1)" = "$(hl "$hr6" lib/same.bin | cut -d" " -f1)" ] && srv "sudo test -s $SM/$hr6"'
# the manifest says flip.txt holds the next deploy's bytes (same size); its own checksum is not changed
h2=$(printf 'two\n' | shasum -a 256 | cut -c1-64) h3=$(printf 'tri\n' | shasum -a 256 | cut -c1-64)
srv "sudo sed -i 's/^$h2\(.*\tlib\/flip.txt\)$/$h3\1/' $SM/$hr6"
# shellcheck disable=SC2034  # read in the eval of a check below
hl9m=$(srv "sudo grep -c '^$h3' $SM/$hr6")
echo tri > lib/flip.txt
echo 7 > VERSION; "$R" deploy > "$E/hl7.out" 2>&1; rc=$?
# shellcheck disable=SC2034  # read in the eval of a check below
hr7=$(rid "$E/hl7.out")
check "HL9 a damaged manifest is not trusted (rc=$rc, changed lines $hl9m): the new bytes are copied, the rest shared" \
  eval '[ $rc = 0 ] && [ "$hl9m" = 1 ] && [ "$(srv "sudo cat $RA/$hr7/lib/flip.txt")" = tri ] &&
        [ "$(hl "$hr6" lib/same.bin | cut -d" " -f1)" = "$(hl "$hr7" lib/same.bin | cut -d" " -f1)" ]'
cd "$W" || exit 2

for a in skew plain spa skewn cz; do "$R" destroy "$a" --purge --yes > /dev/null 2>&1; done   # (section 20 counts the host's apps)
# 20. several hosts: the same container under two names plus one that does not answer
"$R" host add test2 vmadmin@127.0.0.1 --port $SP --key "$ROOT/test/server/id_test" --insecure-test >&2  # the one insecure entry
"$R" host add dead vmadmin@127.0.0.1 --port 2299 --key "$ROOT/test/server/id_test" --no-check >&2
# the hosts are asked in parallel (each for at most 10 s of wall clock); a refused one answers at
# once, so --all on three hosts takes about as long as one (measured here, under the same load,
# rather than a fixed bound that a busy machine exceeds)
t0=$SECONDS; "$R" ls -H test > /dev/null 2>&1; one=$((SECONDS - t0))
t0=$SECONDS
COLUMNS=100 "$R" ls --all > "$E/all.out" 2>&1; rc=$?; cat "$E/all.out" >&2
secs=$((SECONDS - t0))
check "20a ls --all: one box for the 3 hosts, the dead one first, not answering with its reason, both others' apps, in ${secs}s (one host: ${one}s)" \
  eval '[ $rc = 0 ] && [ "$(grep -c "╭─ tando ls --all .* 3 servers" "$E/all.out")" = 1 ] &&
        sed -n 2p "$E/all.out" | grep -q "dead  not answering: connection refused" &&
        grep -Eq "^│ test +[a-z]" "$E/all.out" && grep -Eq "^│ test2 +[a-z]" "$E/all.out" &&
        [ $secs -le $((2 * one + 6)) ]'
COLUMNS=120 "$R" host ls > "$E/hostls.out" 2>&1; cat "$E/hostls.out" >&2
check "20b host ls shows app counts and reachability, with the reason for the dead one" \
  eval 'grep -qE "test2 .* 2 .*yes" "$E/hostls.out" && grep -qE "dead .*connection refused" "$E/hostls.out"'

echo
cat "$E/loops"
echo "$FAILS failed"
[ $FAILS -eq 0 ]
