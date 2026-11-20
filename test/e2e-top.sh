#!/bin/bash
# End-to-end test of `tando top`. Drives the real dashboard in a pseudo-terminal with
# test/top-pty.py (python3 is a test-only dependency; tando itself never needs it).
#
#   test/e2e-top.sh [--reset]      --reset: recreate the server first (only one this suite owns)
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT, default tando-test-top on
# 2302/8302 (this suite's own). The default server, or any with TANDO_TEST_OWNED=1, may be reset;
# another one is reused as it is and must have no apps but the hello and site this suite deploys.
# Work directory ${T_WORK:-test/.top-<server>}. TANDO_BIN picks the tando to test (default
# bin/tando). Output: PASS/FAIL lines (docs/TESTING.md), summary, exit status.
# Stops and starts its server with docker (check 5). Nothing leaves the machine.
set -u
export TANDO_TEST_NAME=${TANDO_TEST_NAME:-tando-test-top}
export TANDO_TEST_SSH_PORT=${TANDO_TEST_SSH_PORT:-2302} TANDO_TEST_HTTP_PORT=${TANDO_TEST_HTTP_PORT:-8302}
[ "$TANDO_TEST_NAME" = tando-test-top ] && export TANDO_TEST_OWNED=1
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init top
R=${TANDO_BIN:-$R}
PTY="python3 $ROOT/test/top-pty.py"

# run_top name rows cols steps [tando args...]: run the dashboard; the steps file gets the
# top-pty steps; stty modes after exit are written to $E/<name>.stty
# shellcheck disable=SC2329 # called through check
metrics_timer() { # tando-metrics sample runs once a minute, from tando-watch's unit
  "$SSH" 'systemctl is-enabled -q tando-watch.timer &&
    systemctl cat tando-watch.service | grep -q "tando-metrics sample"' 2> /dev/null
}
run_top() {
  local name=$1 rows=$2 cols=$3 steps=$4
  shift 4
  $PTY "$rows" "$cols" "$steps" -- /bin/bash -c '"$@"; rc=$?; stty -a > "$STTY_OUT"; exit $rc' _ "$R" top "$@" \
    > "$E/$name.out" 2>&1
  echo $? > "$E/$name.rc"
}
steps() { cat > "$E/$1.steps"; }
# shellcheck disable=SC2329 # the predicates below are called through check
ok_run() { # name: the pty script finished (no wait timed out)
  [ "$(cat "$E/$1.rc")" = 0 ]
}
# shellcheck disable=SC2329 # called through check
final() { grep '^final:' "$E/$1.out"; }
# shellcheck disable=SC2329 # called through check
restored() { # name: cursor visible, alternate screen left, tty back in canonical mode with echo
  final "$1" | grep -q 'cursor=visible altscreen=off' &&
  grep -q '[^-]icanon' "$E/$1.stty" && grep -q '[^-]echo ' "$E/$1.stty" &&
  ! grep -q -- '-icanon' "$E/$1.stty"
}
# shellcheck disable=SC2329 # called through check
no_overflow() { final "$1" | grep -q 'overflow=0$' && ! grep -q '^OVERFLOW' "$E/$1.out"; }
restarts() { "$SSH" "systemctl show -p ActiveEnterTimestampMonotonic --value tando-$1"; }

setup() {
  log "setting up $TANDO_TEST_NAME"
  if [ "${1:-}" = --reset ]; then t_server_up --reset || exit 1; else t_server_up || exit 1; fi
  mkdir -p "$E/w"
  local a
  t_host_add top1; t_host_add top2      # one server under two names: two hosts in the strip
  "$R" host setup top1 public_port="$TANDO_TEST_HTTP_PORT" >&2 || exit 1
  # host setup installs the sampler; it runs from tando-watch.timer (the alert checks' unit,
  # ExecStartPre=-tando-metrics sample): check 7a
  for a in hello site; do
    rm -rf "${E:?}/w/$a"; cp -R "$ROOT/examples/$a" "$E/w/"
    (cd "$E/w/$a" && echo "host = top1" >> tando.conf && "$R" up >&2) || exit 1
  done
  "$SSH" 'sudo /opt/tando/bin/tando-metrics sample'   # the apps have a point before the first tick
}

command -v python3 > /dev/null || { echo "python3 is needed for the pty driver"; exit 1; }
setup "${1:-}"
export STTY_OUT

# ---- 1. 80x24: paints, navigates, detail, log, history -----------------------------------------
log "80x24 navigation"
steps nav80 <<'EOF'
wait apps · top1 20
wait recent deploys 15
dump start
check
send j
wait ├─ site 5
dump moved
send \r
gone ├─ site 5
dump nodetail
send \r
wait ├─ site 5
send k
wait ├─ hello 5
send l
wait logs hello 5
wait tando-hello 10
dump log
send k
wait paused 5
send f
wait following 5
send q
wait apps · top1 5
send h
wait history hello 5
wait deploy 10
dump history
send \e
wait apps · top1 5
send \e[C
wait apps · top2 10
send \e[D
wait apps · top1 10
check
send q
exit 10
EOF
STTY_OUT=$E/nav80.stty run_top nav80 24 80 "$E/nav80.steps"
check "1a 80x24 paints and every step answered" ok_run nav80
check "1b 80x24 no line wider than the terminal" no_overflow nav80
check "1c the selection moves and the detail follows (j: site)" grep -q '^├─ site' "$E/nav80.out"
check "1d enter hides the detail pane" sh -c "sed -n '/^=== nodetail/,/^=== end/p' '$E/nav80.out' | grep -q 'apps · top1' && ! sed -n '/^=== nodetail/,/^=== end/p' '$E/nav80.out' | grep -q 'release '"
check "1e log view shows the journal and pauses/follows" grep -q 'logs hello' "$E/nav80.out"
check "1f history view lists deploys" sh -c "sed -n '/^=== history/,/^=== end/p' '$E/nav80.out' | grep -q 'VERIFY'"
check "1g q restores the terminal" restored nav80

# ---- 2. read-only refuses mutations -------------------------------------------------------------
log "read-only"
before=$(restarts hello)
steps ro <<'EOF'
wait recent deploys 20
send r
wait started with --read-only 5
dump ro
send x
send s
wait disabled 5
send x
send b
wait disabled 5
send x
send q
exit 10
EOF
STTY_OUT=$E/ro.stty run_top ro 24 80 "$E/ro.steps" --read-only
check "2a --read-only answers r, s and b with a note" ok_run ro
sleep 1
check "2b --read-only: hello was not restarted" test "$(restarts hello)" = "$before"

# ---- 3. confirmed restart, cancelled restart ----------------------------------------------------
log "restart"
before=$(restarts hello)
steps restart <<'EOF'
wait recent deploys 20
send r
wait Really restart hello 5
send n
gone Really 5
sleep 1
send r
wait Really restart hello 5
dump confirm
send y
wait health check passes 40
dump result
send x
check
send q
exit 10
EOF
STTY_OUT=$E/restart.stty run_top restart 30 100 "$E/restart.steps"
check "3a restart asks, n cancels, y restarts and reports the health check" ok_run restart
after=$(restarts hello)
check "3b the server restarted hello (ActiveEnterTimestamp $before -> $after)" test "$after" != "$before"

# ---- 4. 120x40, resize, compact view ------------------------------------------------------------
log "120x40 and resize"
steps wide <<'EOF'
wait apps · top1 20
wait recent deploys 15
sleep 2
dump wide
check
resize 24 80
wait ├─ apps · top1 5
sleep 1
dump resized80
check
resize 18 70
wait tando top · top1 5
dump compact
send \r
wait state 8
dump compactdetail
check
resize 40 120
wait apps · top1 5
check
send q
exit 10
EOF
STTY_OUT=$E/wide.stty run_top wide 40 120 "$E/wide.steps"
check "4a 120x40 paints side by side, survives resizes to 80x24 and 70x18 (compact)" ok_run wide
check "4b no line wider than the terminal at any size" no_overflow wide
check "4c the wide layout has the split pane" sh -c "sed -n '/^=== wide/,/^=== end/p' '$E/wide.out' | grep -q '┬'"

# ---- 5. server goes away and comes back ---------------------------------------------------------
log "stopped server"
steps down <<'EOF'
wait recent deploys 20
sleep 1
dump before
EOF
steps down2 <<'EOF'
wait unreachable|reconnecting|no answer 40
dump down
send ?
wait keys 3
send x
EOF
steps down3 <<'EOF'
wait ●  load 90
dump back
check
send q
exit 10
EOF
if [ "${TANDO_TEST_OWNED:-0}" != 1 ]; then
  skip "5a stopped server: not stopping $TANDO_TEST_NAME, this suite does not own it (TANDO_TEST_OWNED=1)"
  skip "5b old data stays visible while the host is down"
else
  # one pty session; docker stop/start happen from a background helper at fixed times
  ( sleep 8; docker stop -t 1 "$TANDO_TEST_NAME" > /dev/null; sleep 20; docker start "$TANDO_TEST_NAME" > /dev/null ) &
  helper=$!
  cat "$E/down.steps" "$E/down2.steps" "$E/down3.steps" > "$E/downall.steps"
  STTY_OUT=$E/down.stty run_top down 30 100 "$E/downall.steps"
  wait $helper
  "$ROOT/test/server/up.sh" > /dev/null 2>&1    # reinstall the key, wait for ssh
  check "5a a stopped server shows as unreachable, keys keep working, and it recovers" ok_run down
  check "5b old data stays visible (greyed) while the host is down" sh -c "sed -n '/^=== down\$/,/^=== end/p' '$E/down.out' | grep -q 'hello'"
fi

# ---- 6. Ctrl-C and SIGTERM restore the terminal -------------------------------------------------
log "signals"
steps ctrlc <<'EOF'
wait apps · top1 20
send \x03
exit 10
EOF
STTY_OUT=$E/ctrlc.stty run_top ctrlc 24 80 "$E/ctrlc.steps"
check "6a Ctrl-C exits (130) and restores the terminal" sh -c "grep -q 'final: exit=130' '$E/ctrlc.out'"
check "6b Ctrl-C: cursor, screen and tty modes restored" restored ctrlc
steps term <<'EOF'
wait apps · top1 20
signal TERM
exit 10
EOF
# signal goes to the wrapper's child: send it to the whole group via the helper's TERM to pid
$PTY 24 80 "$E/term.steps" -- "$R" top > "$E/term.out" 2>&1
check "6c SIGTERM exits (143) and restores cursor and screen" sh -c "grep -q 'final: exit=143 cursor=visible altscreen=off' '$E/term.out'"

# ---- 7. metrics sampler ------------------------------------------------------------------------
log "metrics"
check "7a the metrics sampler runs from an enabled timer" metrics_timer
check "7b read returns per-minute points for hello" sh -c "'$SSH' 'sudo -n /opt/tando/bin/tando-metrics read hello 5 60' | grep -q '^m	'"
check "7c read refuses bad arguments" sh -c "! '$SSH' 'sudo -n /opt/tando/bin/tando-metrics read ../x 5 60' 2> /dev/null"
rot=$("$SSH" 'set -e; d=$(mktemp -d); now=$(date +%s)
  printf "hello 0 %s 3\nsite 0 %s 5100\n.host 0 %s 1\n" $((now - 302401)) $now $now > $d/.state
  printf "1\t1\t1\t0\tr\n" | tee $d/hello.tsv > $d/site.tsv
  sudo -n env TANDO_METRICS_DIR=$d /opt/tando/bin/tando-metrics sample
  echo "$(test -f $d/hello.tsv.1 && echo rotated) $(sudo -n cat $d/hello.tsv | wc -l) $(test -f $d/site.tsv.1 && echo rotated) $(sudo -n cat $d/site.tsv | wc -l)"
  sudo rm -rf $d')
check "7d files rotate after 3.5 days or 5100 lines (got: $rot)" test "$rot" = "rotated 1 rotated 1"
cost=$("$SSH" 'TIMEFORMAT="%3U %3S"; { time sudo -n /opt/tando/bin/tando-metrics sample; } 2>&1; { time sudo -n true; } 2>&1')
ms=$(echo "$cost" | awk 'NR == 1 { a = ($1 + $2) * 1000 } NR == 2 { b = ($1 + $2) * 1000 } END { printf "%d", a - b }')
check "7e one sample costs ${ms} ms CPU (under 20 ms, sudo excluded)" test "$ms" -lt 20
check "7f nothing keeps running after a sample" sh -c "! '$SSH' 'pgrep -f \"tando-metrics sample\"' > /dev/null"
v=$("$SSH" '/opt/tando/bin/tando-metrics version' 2> /dev/null)
check "7g tando-metrics version is the client's ($v)" t_eq "$v" "$(cat "$ROOT/VERSION")"
# (root's alone: an app must not read another app's samples; tando top reads them through sudo)
modes=$("$SSH" 'sudo -n stat -c "%a %U" /var/lib/tando/metrics /var/lib/tando/metrics/.state /var/lib/tando/metrics/hello.tsv' 2> /dev/null | sort -u | tr '\n' ' ')
check "7h the metrics directory is 700 and its files 600, root's ($modes)" t_eq "$modes" "600 root 700 root "

# ---- 8. costs ---------------------------------------------------------------------------------
log "costs"
steps idle <<'EOF'
wait recent deploys 20
sleep 30
send q
exit 10
EOF
STTY_OUT=$E/idle.stty run_top idle 40 120 "$E/idle.steps"
cpu=$(sed -n 's/^rusage: user=\([0-9.]*\) sys=\([0-9.]*\)/\1 \2/p' "$E/idle.out")
echo "laptop CPU, dashboard open ~34 s (30 s idle) at 120x40: user+sys = $cpu s"
srv=$("$SSH" 'A=/opt/tando/bin/tando-agent M=/opt/tando/bin/tando-metrics; TIMEFORMAT="%3U %3S"
  { time (for i in 1 2 3 4 5 6 7 8 9 10; do $A status > /dev/null; done); } 2>&1
  { time (for i in 1 2 3 4 5 6 7 8 9 10; do $A status; $A releases hello; $A history hello 6; $M read hello 60 60; done > /dev/null); } 2>&1
  { time (for i in 1 2 3 4 5 6 7 8 9 10; do sudo -n $M sample; done); } 2>&1
  { time (for i in 1 2 3 4 5 6 7 8 9 10; do sudo -n true; done); } 2>&1')
echo "server CPU (user sys, 10 runs each): status | status+detail+metrics | metrics sample | sudo alone:"
echo "$srv"

log "screens and logs in $E"
t_done
