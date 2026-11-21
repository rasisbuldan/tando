#!/bin/bash
# test/runner-test.sh: the test runner itself (test/all.sh, test/select.sh, test/server/up.sh), with
# no server and no Docker: all.sh runs in a sandbox copy of the tree whose suites are tiny fakes and
# whose `docker` is a fake that writes down what it was asked. Seconds long.
#
#   r1 --list: the suites in start order (longest first) and about how long the run takes
#   r2 the smoke tier keeps the short suites and names the ones it leaves for the quick tier
#   r3 the smoke tier stops at a failing test/check.sh before any suite starts
#   r4 --fail-fast: a failing suite stops the running one (its whole process tree) at once, shows
#      it as stopped, and removes its server
#   r5 an interrupted run kills its suites' processes and removes its own containers (by name and
#      by its run label), in one docker call, and no container of anyone else
#   r6 test/server/up.sh: --build-only builds and prints the image; with TANDO_TEST_IMAGE_BUILT
#      a start does not build again; TANDO_TEST_RUN labels the container
#   r7 test/suites.map: rules that were missing or too wide (matrix driver, docs, the map itself)
#   r8 --save-durations: the median of the last runs' passing times
# bash 3.2 compatible.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init runner-test
cd "$ROOT" || exit 1
SB=$E/sb FK=$E/fake
mkdir -p "$SB/lib" "$SB/test/server" "$SB/src" "$FK/bin"
cp lib/ui.sh "$SB/lib/"
cp test/all.sh test/select.sh "$SB/test/"
export FAKE_DOCKER_LOG=$FK/docker.log FAKE_DOCKER_STATE=$FK/containers FAKE_DIR=$FK
: > "$FAKE_DOCKER_LOG"; : > "$FAKE_DOCKER_STATE"

# ---- the fakes
cat > "$FK/bin/docker" <<'EOF'
#!/bin/bash
echo "$*" >> "$FAKE_DOCKER_LOG"
case "$1 ${2:-}" in
  "ps -a") cat "$FAKE_DOCKER_STATE"; exit 0;;
  "ps -aq") echo fakelabelled1; exit 0;;
  "container inspect") exit 1;;
  "image inspect") exit 0;;
esac
case $1 in exec) cat > /dev/null;; run) echo cid;; esac
exit 0
EOF
cat > "$SB/test/server/up.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = --build-only ] && { echo img:fake; exit 0; }
echo "$TANDO_TEST_NAME" >> "$FAKE_DOCKER_STATE"
EOF
printf '#!/bin/bash\nexit 0\n' > "$SB/test/server/down.sh"
printf '#!/bin/bash\necho "fake check"; exit "${FAKE_CHECK_RC:-0}"\n' > "$SB/test/check.sh"
suite() { # name body
  printf '#!/bin/bash\n: "${TANDO_TEST_SSH_PORT:-2222}"\n%s\n' "$2" > "$SB/test/$1.sh"
}
suite e2e-trial 'echo "PASS t1 trial"'
suite e2e-fast 'echo "PASS f1 fast"'
suite e2e-long 'echo "PASS l1 long"'
suite e2e-bad 'sleep 1; echo "FAIL b1 bad"; exit 1'
suite e2e-slow 'sleep 300 & echo $! > "$FAKE_DIR/slow.pid"; echo "PASS s0 started"; wait'
printf 'e2e-trial\t10\ne2e-fast\t20\ne2e-bad\t30\ne2e-slow\t300\ne2e-long\t500\n' > "$SB/test/durations.tsv"
cat > "$SB/test/suites.map" <<'EOF'
src/*      e2e-fast e2e-long
EOF
chmod +x "$FK/bin/docker" "$SB"/test/*.sh "$SB"/test/server/*.sh
export PATH=$FK/bin:$PATH TANDO_ALL_PREFIX=tando-rt$$- TANDO_ALL_SSH_BASE=47300 TANDO_ALL_HTTP_BASE=47600
unset TANDO_TIER GO_QUICK

# ---- r1 --list
out=$(TANDO_ALL_SLOTS=2 "$SB/test/all.sh" --list 2>&1)
first=$(printf '%s\n' "$out" | awk 'NR == 1 { print $1 }')
check "r1 --list starts the longest suite first (first: $first)" t_eq e2e-long "$first"
# two slots: 500 | 300 + 30 + 20 + 10 = 360, so the run is the 500 s suite
check "r1b --list estimates the run: $(printf '%s\n' "$out" | tail -1)" \
  test "$(printf '%s\n' "$out" | tail -1 | cut -c1-17)" = "about 8 min 20 s "

# ---- r2 smoke: e2e-long (500 s) is left for the quick tier, e2e-fast and the smoke deploy stay
out=$("$SB/test/all.sh" --smoke --files src/a.c --list 2>&1)
listed=$(printf '%s\n' "$out" | awk '/^e2e-/ { print $1 }' | sort | tr '\n' ' ')
check "r2 smoke keeps the short suites ($listed)" t_eq "e2e-fast e2e-trial " "$listed"
check "r2b smoke names what it left for the quick tier" grep -q 'left for the quick tier.*e2e-long' <<< "$out"
out=$("$SB/test/all.sh" --tier quick --files src/a.c --list 2>&1)
listed=$(printf '%s\n' "$out" | awk '/^e2e-/ { print $1 }' | sort | tr '\n' ' ')
check "r2c the quick tier keeps both ($listed)" t_eq "e2e-fast e2e-long e2e-trial " "$listed"

# ---- r3 smoke: a failing check stops it before a suite starts
rm -rf "${SB:?}/.tando"
out=$(FAKE_CHECK_RC=1 "$SB/test/all.sh" --smoke --files src/a.c 2>&1); rc=$?
check "r3 smoke stops at a failing test/check.sh (rc=$rc), no suite ran" \
  test "$rc" = 1 -a ! -d "$SB/.tando/all/latest"

# ---- r4 --fail-fast
: > "$FAKE_DOCKER_LOG"; : > "$FAKE_DOCKER_STATE"; rm -f "$FK/slow.pid"
t0=$SECONDS
out=$("$SB/test/all.sh" --only e2e-bad,e2e-slow --fail-fast 2>&1); rc=$?
secs=$((SECONDS - t0))
spid=$(cat "$FK/slow.pid" 2> /dev/null)
check "r4 --fail-fast ends the run when e2e-bad fails (rc=$rc, ${secs} s, not 300)" test "$rc" = 1 -a "$secs" -lt 60
check "r4b the running suite's child (sleep, pid ${spid:-none}) was killed" test -n "$spid" && ! kill -0 "$spid" 2> /dev/null
check "r4c the summary shows e2e-slow as stopped" grep -q 'e2e-slow.*stopped' <<< "$out"
check "r4d its server was removed ($(grep '^rm -f' "$FAKE_DOCKER_LOG" | tail -1))" grep -q "^rm -f .*tando-rt$$-" "$FAKE_DOCKER_LOG"
[ -n "$spid" ] && kill "$spid" 2> /dev/null

# ---- r5 interrupt
: > "$FAKE_DOCKER_LOG"; : > "$FAKE_DOCKER_STATE"; rm -f "$FK/slow.pid"
"$SB/test/all.sh" --only e2e-slow > "$E/r5.out" 2>&1 &
apid=$!
t_until 30 test -s "$FK/slow.pid"
spid=$(cat "$FK/slow.pid" 2> /dev/null)
kill -TERM "$apid" 2> /dev/null
t_until 30 sh -c "! kill -0 $apid 2> /dev/null"
check "r5 an interrupted run ends (all.sh gone)" sh -c "! kill -0 $apid 2> /dev/null"
check "r5b and its suite's child (sleep, pid ${spid:-none}) is gone" test -n "$spid" && ! kill -0 "$spid" 2> /dev/null
rmline=$(grep '^rm -f' "$FAKE_DOCKER_LOG" | tail -1)
check "r5c its server and its labelled containers go in one docker call ($rmline)" \
  grep -q "^rm -f tando-rt$$-[0-9]* fakelabelled1\$" "$FAKE_DOCKER_LOG"
check "r5d the label filter is this run's (tando.run=tando-rt$$-<pid>)" \
  grep -q "^ps -aq --filter label=tando.run=tando-rt$$--[0-9][0-9]*\$" "$FAKE_DOCKER_LOG"
[ -n "$spid" ] && kill "$spid" 2> /dev/null
wait "$apid" 2> /dev/null

# ---- r6 test/server/up.sh with the fake docker (bare: no HTTP wait)
# up_env: up.sh with none of the variables it reads from outside (inside test/all.sh, the run's
# TANDO_TEST_RUN, image and ports are exported: r6e then saw the outer run's label), only those given
up_env() { env -u TANDO_TEST_RUN -u TANDO_TEST_IMAGE_BUILT -u TANDO_TEST_BARE -u TANDO_TEST_NAME -u TANDO_TEST_NODE \
  -u TANDO_TEST_CADDY -u TANDO_TEST_DOCKER_ARGS -u TANDO_TEST_SSH_PORT -u TANDO_TEST_HTTP_PORT "$@"; }
U=$E/up; mkdir -p "$U"
cp test/server/up.sh "$U/"; printf '#!/bin/bash\nexit 0\n' > "$U/ssh.sh"; chmod +x "$U/ssh.sh"
: > "$U/id_test"; : > "$U/id_test.pub"
: > "$FAKE_DOCKER_LOG"
img=$(up_env TANDO_TEST_BARE=1 "$U/up.sh" --build-only)
check "r6 --build-only builds and prints the image ($img), starts nothing" \
  test "$img" = tando-testvm:bare -a "$(grep -c '^build' "$FAKE_DOCKER_LOG")" = 1 -a "$(grep -c '^run' "$FAKE_DOCKER_LOG")" = 0
: > "$FAKE_DOCKER_LOG"
up_env TANDO_TEST_BARE=1 TANDO_TEST_IMAGE_BUILT=tando-testvm:bare TANDO_TEST_RUN=rt-label TANDO_TEST_NAME=tando-rt$$-u \
  "$U/up.sh" > /dev/null 2>&1; rc=$?
check "r6b a start after it does not build (rc=$rc)" test "$rc" = 0 -a "$(grep -c '^build' "$FAKE_DOCKER_LOG")" = 0
check "r6c TANDO_TEST_RUN labels the container" grep -q '^run .*--label tando.run=rt-label ' "$FAKE_DOCKER_LOG"
: > "$FAKE_DOCKER_LOG"
up_env TANDO_TEST_BARE=1 TANDO_TEST_IMAGE_BUILT=tando-testvm:other TANDO_TEST_NAME=tando-rt$$-u "$U/up.sh" > /dev/null 2>&1
check "r6d another image's name does not skip the build" test "$(grep -c '^build' "$FAKE_DOCKER_LOG")" = 1
check "r6e no run label without TANDO_TEST_RUN" sh -c "! grep -q 'tando.run' '$FAKE_DOCKER_LOG'"

# ---- r7 the real map
sel() { test/select.sh --files "$@" 2> /dev/null; }
s=$(sel test/e2e-matrix.sh); check "r7 the matrix driver selects the quick matrix cells ($s)" grep -qw e2e-matrix-quick <<< "$s"
s=$(sel docs/COMMANDS.md); check "r7b a docs page selects lint and ui-test, no server suite ($s)" t_eq "lint ui-test" "$s"
s=$(sel test/suites.map); check "r7c the map itself selects its check, not every suite ($s)" grep -qw runner-test <<< "$s"
s=$(sel .shellcheckrc); check "r7d .shellcheckrc selects lint ($s)" t_eq lint "$s"
s=$(sel lib/common.sh); check "r7e a core file still selects ALL ($s)" t_eq ALL "$s"

# ---- r8 --save-durations: the median of the last passing times
for r in 20260101-000001 20260101-000002 20260101-000003; do mkdir -p "$SB/.tando/all/$r"; done
echo "0 100" > "$SB/.tando/all/20260101-000001/e2e-fast.rc"
echo "0 300" > "$SB/.tando/all/20260101-000002/e2e-fast.rc"
echo "0 120" > "$SB/.tando/all/20260101-000003/e2e-fast.rc"
echo "1 900" > "$SB/.tando/all/20260101-000003/e2e-bad.rc"
"$SB/test/all.sh" --save-durations > /dev/null 2>&1
got=$(awk -F'\t' '$1 == "e2e-fast" { print $2 } $1 == "e2e-bad" { print "bad=" $2 }' "$SB/test/durations.tsv" | tr '\n' ' ')
check "r8 --save-durations: median 120 of 100/300/120; a failed run does not count ($got)" t_eq "120 bad=30 " "$got"
t_done
