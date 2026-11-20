#!/bin/bash
# End-to-end test of the container and python recipes, tando init and tando recipes.
# Needs docker (or podman) on the laptop to build examples/container, and network access on the
# server for `host setup podman=yes python=yes` and pip. One PASS/FAIL line per check.
# Usage: test/e2e-recipes.sh [--no-reset]
set -u
# Server: TANDO_TEST_NAME, TANDO_TEST_SSH_PORT, TANDO_TEST_HTTP_PORT (default tando-testvm, 2222,
# 8080). The server is reset first when run by hand on the default one, or when TANDO_TEST_OWNED=1.
TN=${TANDO_TEST_NAME:-tando-testvm} SP=${TANDO_TEST_SSH_PORT:-2222} HP=${TANDO_TEST_HTTP_PORT:-8080}
export TANDO_TEST_NAME=$TN TANDO_TEST_SSH_PORT=$SP TANDO_TEST_HTTP_PORT=$HP
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
. "$ROOT/test/lib.sh"   # t_until (this suite keeps its own pass/fail/check, defined below)
E=${T_WORK:-$ROOT/test/.e2e-recipes-$TN}   # one work dir per test server
W=$E/w R=$ROOT/bin/tando SSH=$ROOT/test/server/ssh.sh
export TANDO_CONFIG_DIR=$E/cfg TANDO_COLOR=never
export TANDO_SOAK=${TANDO_SOAK:-2} TANDO_WAIT=1   # a short soak (30 s by default) keeps the suite fast
FAILS=0

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local n=$1; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
log() { echo "---- $*" >&2; }
srv() { "$SSH" "$@"; }
get() { curl -s -m 5 "http://$1.localhost:$HP${2:-/}"; }
rid() { sed -n 's/.*release \([0-9-]*\) *│/\1/p' "$1" | head -1; }
sent() { sed -n 's/.*changed, \([0-9.]* [KMG]*B\) sent.*/\1/p' "$1"; }
live() { sed -n 's/.*live in \([0-9.ms ]*\)  .*/\1/p' "$1"; }
phase() { sed -n "s/.*[✓✗] [0-9]\/7  $2 *\([0-9.]*s\).*/\1/p" "$1"; }
loop_start() { # app
  rm -f "$E/loop.stop"
  (
    while [ ! -f "$E/loop.stop" ]; do
      curl -s -o /dev/null -m 30 -w '%{http_code} %{time_total}\n' "http://$1.localhost:$HP/"
      sleep 0.1
    done
  ) > "$E/loop" &
  LOOP=$!
  sleep 0.5
}
secret() { awk -v n="--- $2" '$0 == n { f = 1; next } /^--- / { f = 0 } f' "$1"; }   # tando ci setup output
by_key() { # setup-output command...: run tando with the deploy key of that output, as CI does
  local s=$1; shift
  TANDO_DEPLOY_KEY=$(secret "$s" TANDO_DEPLOY_KEY) TANDO_HOST=$(secret "$s" TANDO_HOST) \
    TANDO_PORT=$(secret "$s" TANDO_PORT) TANDO_KNOWN_HOSTS=$(secret "$s" TANDO_KNOWN_HOSTS) TANDO_PLAIN=1 "$@"
}
loop_check() { # name
  sleep 0.5; touch "$E/loop.stop"; wait $LOOP
  local n bad max
  n=$(grep -c . "$E/loop"); bad=$(awk '$1 != 200' "$E/loop" | wc -l | tr -d ' ')
  max=$(awk '$2 > m { m = $2 } END { printf "%.3f", m }' "$E/loop")
  check "$1 under load: $n requests, $bad failed, longest ${max}s" test "$bad" = 0 -a "$n" -gt 5
}

if [ "${1:-}" != --no-reset ] && { [ "$TN" = tando-testvm ] || [ "${TANDO_TEST_OWNED:-}" = 1 ]; }; then
  log "resetting test server"
  "$ROOT/test/server/up.sh" --reset >&2 || exit 1
fi
rm -rf "${E:?}"
mkdir -p "$W"
cp -R "$ROOT/examples/container" "$ROOT/examples/python" "$W/"

# I. tando recipes, tando init on every example
"$R" recipes > "$E/recipes.out" 2>&1; cat "$E/recipes.out" >&2
nrec=$(grep -cE "│ (next|node|python|container|static) " "$E/recipes.out")
check "I1 tando recipes: a box listing the five recipes ($nrec)" \
  test "$(head -c 3 "$E/recipes.out")" = "╭" -a "$nrec" = 5
for ex in hello next python container site; do
  mkdir -p "$E/init/$ex"
  rsync -a --exclude tando.conf --exclude node_modules --exclude .next "$ROOT/examples/$ex/" "$E/init/$ex/"
  (cd "$E/init/$ex" && "$R" init > "$E/init/$ex.out" 2>&1)
done
got=""
for ex in hello next python container site; do got="$got $ex=$(sed -n 's/^recipe = //p' "$E/init/$ex/tando.conf")"; done
check "I2 init picks the recipe of each example ($got)" \
  test "$got" = " hello=node next=next python=python container=container site=static"
check "I3 init on hello starts its entry file" grep -qx 'start = node server.js' "$E/init/hello/tando.conf"

# C1. host setup installs Podman and Python
"$R" host add test vmadmin@127.0.0.1 --port "$SP" --key "$ROOT/test/server/id_test" --yes >&2
t0=$SECONDS
"$R" host setup test public_port=$HP podman=yes python=yes > "$E/setup.out" 2>&1; rc=$?; cat "$E/setup.out" >&2
check "C1 host setup podman=yes python=yes in $((SECONDS - t0))s" \
  eval '[ $rc = 0 ] && srv "podman --version && python3 -c \"import venv\"" > /dev/null'
mem0=$(srv "free -k | awk '/^Mem:/ {print \$3}'")

# C2. first deploy of the container example
cd "$W/container" || exit 2
"$R" up > "$E/c1.out" 2>&1; rc=$?; cat "$E/c1.out" >&2
check "C2 container up: answers v1 (rc=$rc, $(sent "$E/c1.out") sent, live in $(live "$E/c1.out"))" \
  test "$(get box)" = "container v1"
port=$(srv "sudo sed -n 's/^port=//p' /opt/tando/apps/box/app.conf")

# C3. the container has no more privilege than a directory app
pid=$(srv "pgrep -x httpd | head -1")
info=$(srv "ps -o user= -p $pid; grep -E '^(CapEff|NoNewPrivs)' /proc/$pid/status | tr -s '\t' ' ';
  ss -Hltn 'sport = :$port' | awk '{print \$4}'; sudo podman exec tando-box-$port touch /x 2>&1 | tail -1" |
  tr '\n' '|')
log "container: $info"
c3() { case "$info" in "tando-box|CapEff: 0000000000000000|NoNewPrivs: 1|127.0.0.1:$port|"*"Read-only file system|") ;;
  *) return 1;; esac; }
check "C3 runs as tando-box, no capabilities, no new privileges, 127.0.0.1 only, read-only root" c3

# C4. one-line change under load: zero failed requests; only the changed layer travels
echo 'container v2' > www/index.html
loop_start box
"$R" deploy > "$E/c2.out" 2>&1; rc=$?; cat "$E/c2.out" >&2
loop_check "C4a container deploy"
check "C4b one-line change: v2, $(sent "$E/c2.out") sent (first $(sent "$E/c1.out")), live in $(live "$E/c2.out")" \
  eval '[ "$(get box)" = "container v2" ] && sent "$E/c2.out" | grep -qE "^[0-9.]+ (B|KB)$"'
echo "container: first deploy $(sent "$E/c1.out") in $(live "$E/c1.out"); one-line change $(sent "$E/c2.out")" \
  "in $(live "$E/c2.out") (build $(phase "$E/c2.out" build) stage $(phase "$E/c2.out" stage)" \
  "upload $(phase "$E/c2.out" upload) copy $(phase "$E/c2.out" copy) preflight $(phase "$E/c2.out" preflight)" \
  "switch $(phase "$E/c2.out" switch) verify $(phase "$E/c2.out" verify))" > "$E/numbers"

# C5. a release without /health fails pre-flight; the app keeps answering v2
rm www/health; echo 'container v3' > www/index.html
"$R" deploy > "$E/c3.out" 2>&1; rc=$?; cat "$E/c3.out" >&2
id3=$(rid "$E/c3.out")
check "C5 broken image refused by pre-flight (rc=$rc), still v2, $id3 failed and deleted" \
  eval '[ $rc != 0 ] && [ "$(get box)" = "container v2" ] && ! "$R" releases | grep -q "$id3" &&
        "$R" history | grep -q "failed"'
echo ok > www/health

# C6. rollback, env, data volume, logs, status
loop_start box
"$R" rollback > /dev/null 2>&1; rc=$?
loop_check "C6a container rollback"
check "C6b rollback: v1 (rc=$rc)" test "$(get box)" = "container v1"
"$R" env set GREETING=from-env > /dev/null 2>&1
g=$(srv "sudo podman exec tando-box-$port printenv GREETING")
check "C6c env reaches the container ($g)" test "$g" = from-env
srv "sudo podman exec tando-box-$port sh -c 'echo stored > /www/data/note'"
own=$(srv "sudo stat -c %U /opt/tando/apps/box/shared/data/note")
check "C6d data volume = shared/data, written as the app user ($own), served ($(get box /data/note))" \
  test "$own" = tando-box -a "$(get box /data/note)" = stored
"$R" logs -n 30 > "$E/logs.out" 2>&1
check "C6e logs come from the journal" grep -q 'response:200' "$E/logs.out"
COLUMNS=100 "$R" status > "$E/status.out" 2>&1; cat "$E/status.out" >&2
check "C6f status shows the container's memory against its cap" \
  grep -qE 'memory .*[0-9.]+ [KM]B of 64 MB' "$E/status.out"
id=$("$R" backup now 2>&1 | sed -n 's/^backed up [a-z0-9-]*: \([^ ]*\).*/\1/p')
check "C6g backup holds the data volume ($id)" \
  eval 'srv "sudo tar -tzf /var/backups/tando/box/$id/data.tar.gz" | grep -q note'

# C7. keep 5 releases and their images
for v in 4 5 6 7; do echo "container v$v" > www/index.html; "$R" deploy > /dev/null 2>&1; done
# (a poll: the old releases are pruned when the last one is verified, which may be a moment after
# the deploy command returned; seen once under load: 6 kept)
c7_n() { nrel=$("$R" releases | grep -c '│ 20'); nimg=$(srv "sudo podman images --format '{{.Repository}}' | grep -c '^localhost/tando-box$'"); [ "$nrel" = 5 ] && [ "$nimg" -le 5 ]; }
t_until 30 c7_n
check "C7 after 9 releases: $nrel kept, $nimg images" test "$nrel" = 5 -a "$nimg" -le 5
check "C7b serves the last one" test "$(get box)" = "container v7"

# K1. a container release through a CI deploy key (tando-gate): upload, activate, status
"$R" ci setup > "$E/ci.box" 2> "$E/ci.box.err"; cat "$E/ci.box.err" >&2
echo 'container v8' > www/index.html
by_key "$E/ci.box" "$R" deploy > "$E/k1.out" 2>&1; rc=$?; cat "$E/k1.out" >&2
check "K1a container deploy through a deploy key: v8 (rc=$rc)" test "$(get box)" = "container v8"
by_key "$E/ci.box" "$R" status > "$E/k1s.out" 2>&1; rc=$?
check "K1b status through the key (rc=$rc)" grep -q 'container' "$E/k1s.out"
by_key "$E/ci.box" "$R" env ls > "$E/k1e.out" 2>&1; rc=$?
check "K1c env ls through the key is refused (rc=$rc)" eval '[ $rc != 0 ] && grep -q "not allowed with a deploy key" "$E/k1e.out"'
mem1=$(srv "free -k | awk '/^Mem:/ {print \$3}'")
cg=$(srv "cat /sys/fs/cgroup/system.slice/tando-box.service/memory.current")
res=$(srv "ps -eo rss,comm | awk '/conmon|podman|catatonit|httpd|slirp4netns/ {s += \$1; n = n \" \" \$2 \"=\" \$1}
  END {print s \" KB:\" n}'")
echo "podman with one app: unit cgroup $((cg / 1024)) KB; resident $res; host used $((mem1 - mem0)) KB vs before" \
  >> "$E/numbers"

# P1. python: venv built on the server, bounded, reported
cd "$W/python" || exit 2
"$R" up > "$E/p1.out" 2>&1; rc=$?; cat "$E/p1.out" >&2
venv=$(sed -n 's/.*venv: \(.*[^ ]\) *│.*/\1/p' "$E/p1.out")
check "P1 python up: answers v1 (rc=$rc), venv built on the server ($venv)" \
  eval '[ "$(get pyapp)" = "python v1 greeting=" ] && echo "$venv" | grep -q "peak memory"'
echo "python venv build, first release: $venv" >> "$E/numbers"
user=$(srv "ps -o user= -p \$(systemctl show -P MainPID tando-pyapp)")
rel=$(srv "readlink -f /opt/tando/apps/pyapp/current")
vown=$(srv "sudo stat -c %U:%G $rel/.venv/bin/python3 $rel/.venv/lib")
check "P2 runs as tando-pyapp from a root-owned venv ($user, $(echo $vown))" \
  test "$user" = tando-pyapp -a "$(echo $vown)" = "root:tando-pyapp root:tando-pyapp"
echo 2 > VERSION
loop_start pyapp
"$R" deploy > "$E/p2.out" 2>&1; rc=$?; cat "$E/p2.out" >&2
loop_check "P3 python deploy"
venv2=$(sed -n 's/.*venv: \(.*[^ ]\) *│.*/\1/p' "$E/p2.out")
check "P4 second release: new venv ($venv2), v2" test "$(get pyapp)" = "python v2 greeting="
echo "python venv build, second release (pip cache warm): $venv2; deploy live in $(live "$E/p2.out")" >> "$E/numbers"

# S5 (F5). an image upload with a symbolic link (image-ref -> another app's secret) is refused and
# nothing of the target is echoed
cd "$W/container" || exit 2
srv "sudo sh -c 'echo sk_live_SECRETTOKEN > /opt/tando/apps/pyapp/env.secret-test; chmod 600 /opt/tando/apps/pyapp/env.secret-test'"
tok=$(srv "sudo /opt/tando/bin/tando-agent begin box e2e" | sed -n 's/^token=//p')
srv "sudo sh -c 'cd /opt/tando/apps/box/incoming && find . -mindepth 1 -delete && ln -s /opt/tando/apps/pyapp/env.secret-test image-ref'"
id=$(echo "$tok" | srv "sudo /opt/tando/bin/tando-agent activate box 0 0" | sed -n 's/^id=//p')
finished() { srv "sudo /opt/tando/bin/tando-agent deploy-status box $id" | grep -q '^result=' &&
  ! srv "sudo /opt/tando/bin/tando-agent deploy-status box $id" | grep -qx 'result=running'; }
T_UNTIL_STEP=0.5 t_until 60 finished
ds=$(srv "sudo /opt/tando/bin/tando-agent deploy-status box $id")
check "S5 image-ref through a symlink: refused, the target never echoed ($(echo "$ds" | sed -n 's/^message=//p'))" \
  eval 'echo "$ds" | grep -q "^result=failed" && echo "$ds" | grep -q "symbolic link" && ! echo "$ds" | grep -q SECRETTOKEN'
srv "sudo rm -f /opt/tando/apps/pyapp/env.secret-test; sudo find /opt/tando/apps/box/incoming -mindepth 1 -delete"
cd "$W/python" || exit 2

# K2. a python release through a CI deploy key: the venv is built on the server as usual
"$R" ci setup > "$E/ci.py" 2> "$E/ci.py.err"; cat "$E/ci.py.err" >&2
echo 3 > VERSION
by_key "$E/ci.py" "$R" deploy > "$E/k2.out" 2>&1; rc=$?; cat "$E/k2.out" >&2
check "K2 python deploy through a deploy key: v3 with a new venv (rc=$rc)" \
  eval '[ "$(get pyapp)" = "python v3 greeting=" ] && grep -q "venv:" "$E/k2.out"'

echo
cat "$E/numbers"
echo "$FAILS failed"
[ $FAILS -eq 0 ]
