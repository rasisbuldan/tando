# shellcheck shell=bash
# test/lib.sh: shared helpers for tando test suites. bash 3.2 compatible; safe under set -u.
#
#   . "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
#   t_init mysuite                 # ROOT, R, E (work dir), TANDO_CONFIG_DIR, T_SSH_PORT, T_HTTP_PORT
#   t_server_up [--reset]          # own test server; --reset only when this suite started it
#   check "1a link answers" t_eq "$(curl -s "$(t_url hello)")" "hello v1"
#   t_done                         # summary line, exit status
#
# Conventions (docs/TESTING.md): the server name and ports come from TANDO_TEST_NAME,
# TANDO_TEST_SSH_PORT, TANDO_TEST_HTTP_PORT (defaults tando-testvm, 2222, 8080, so a suite run
# by hand behaves as before); every suite has its own TANDO_CONFIG_DIR and work directory
# under test/.<suite>/; a suite never resets a server it did not start (TANDO_TEST_OWNED=1 is
# set by whoever started it, e.g. test/all.sh).
#
# Output contract read by test/all.sh: one line per check, "PASS <id> <text>", "FAIL <id> <text>"
# or "SKIP <id> <text>"; the id is the first word (e.g. 3a, N2b). Diagnostics go to stderr.

T_PASS=0 T_FAIL=0 T_SKIP=0 T_SUITE="" T_FAILED_IDS=""

# ---- setup ------------------------------------------------------------------------------------

# t_init <suite>: ROOT, R (the CLI), E (work dir test/.<suite>-<server>), SSH (ssh to the server), the
# server name and ports, and a private TANDO_CONFIG_DIR. Colour off so output can be grepped.
t_init() {
  T_SUITE=$1
  ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
  R=$ROOT/bin/tando
  T_NAME=${TANDO_TEST_NAME:-tando-testvm}
  E=${T_WORK:-$ROOT/test/.$T_SUITE-$T_NAME}   # one work dir per suite and server
  T_SSH_PORT=${TANDO_TEST_SSH_PORT:-2222}
  T_HTTP_PORT=${TANDO_TEST_HTTP_PORT:-8080}
  export TANDO_TEST_NAME=$T_NAME TANDO_TEST_SSH_PORT=$T_SSH_PORT TANDO_TEST_HTTP_PORT=$T_HTTP_PORT
  export TANDO_CONFIG_DIR=$E/cfg TANDO_COLOR=never
  export TANDO_SOAK=${TANDO_SOAK:-2} TANDO_WAIT=1         # a short soak (30 s by default) keeps suites fast
  SSH=$ROOT/test/server/ssh.sh
  case $E in "$ROOT"/test/.?*) rm -rf "${E:?}";; *) echo "t_init: refusing work dir $E" >&2; exit 2;; esac
  mkdir -p "$E/cfg"
}

# ---- checks -----------------------------------------------------------------------------------

pass() { T_PASS=$((T_PASS + 1)); echo "PASS $*"; }
fail() { T_FAIL=$((T_FAIL + 1)); T_FAILED_IDS="$T_FAILED_IDS ${1%% *}"; echo "FAIL $*"; }
skip() { T_SKIP=$((T_SKIP + 1)); echo "SKIP $*"; }
# check "<id> <text>" cmd args...: PASS when the command succeeds
check() { local n=$1; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
log() { echo "---- $*" >&2; }
# t_eq <got> <want>: equal and not both empty (an empty want is almost always a broken probe)
t_eq() {
  [ -n "$1$2" ] || { echo "  nothing to compare: got and want are both empty" >&2; return 1; }
  [ "$1" = "$2" ] || { echo "  expected [$2], got [$1]" >&2; return 1; }
}
# t_until <seconds> cmd...: wait for a condition instead of sleeping: run cmd until it succeeds,
# every T_UNTIL_STEP seconds (default 1, fractions allowed), for at most <seconds> of wall clock
# (the time cmd itself takes counts). On a timeout it says so on stderr and returns 1.
# Safe to source from a suite that keeps its own pass/fail/check (define those after sourcing).
t_until() {
  local secs=$1 step=${T_UNTIL_STEP:-1} end
  end=$((SECONDS + secs))
  shift
  until "$@"; do
    if [ "$SECONDS" -ge "$end" ]; then echo "  t_until: still false after $secs s: $*" >&2; return 1; fi
    sleep "$step"
  done
}

# t_done: print the summary and exit 0 only when nothing failed. A run where everything was
# skipped (nothing passed) proves nothing and fails too, unless TANDO_ALLOW_SKIP=1.
t_done() {
  echo "${T_SUITE:-suite}: $T_PASS passed, $T_FAIL failed, $T_SKIP skipped${T_FAILED_IDS:+ (failed:$T_FAILED_IDS)}"
  [ "$T_FAIL" = 0 ] || exit 1
  if [ "$T_PASS" = 0 ] && [ "$T_SKIP" -gt 0 ] && [ "${TANDO_ALLOW_SKIP:-0}" != 1 ]; then
    echo "${T_SUITE:-suite}: every check was skipped (TANDO_ALLOW_SKIP=1 accepts that)" >&2
    exit 1
  fi
  exit 0
}

# ---- test server ------------------------------------------------------------------------------

# t_port_free <port>: nothing listens on 127.0.0.1:<port> and no container publishes it
t_port_free() {
  (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null && return 1
  ! docker ps --format '{{.Ports}}' 2> /dev/null | grep -q ":$1->"
}

# t_free_ports <ssh-start> <http-start>: first offset where both ports are free -> T_SSH_PORT/T_HTTP_PORT
t_free_ports() {
  local i=0
  while [ $i -lt 50 ]; do
    if t_port_free $(($1 + i)) && t_port_free $(($2 + i)); then
      T_SSH_PORT=$(($1 + i)) T_HTTP_PORT=$(($2 + i))
      export TANDO_TEST_SSH_PORT=$T_SSH_PORT TANDO_TEST_HTTP_PORT=$T_HTTP_PORT
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# t_server_up [--reset]: start (or reuse) the suite's server. --reset recreates it, but only when
# this process or its caller owns it (TANDO_TEST_OWNED=1); a shared server is reused as it is.
t_server_up() {
  local a=""
  if [ "${1:-}" = --reset ]; then
    if [ "${TANDO_TEST_OWNED:-0}" = 1 ] || ! docker container inspect "$T_NAME" > /dev/null 2>&1; then
      a=--reset
    else
      log "not resetting $T_NAME: this suite did not start it (set TANDO_TEST_OWNED=1 to allow)"
    fi
  fi
  if ! docker container inspect "$T_NAME" > /dev/null 2>&1; then export TANDO_TEST_OWNED=1; fi
  "$ROOT/test/server/up.sh" $a >&2
}

# t_host_add [name]: register the suite's server in the suite's TANDO_CONFIG_DIR
t_host_add() {
  "$R" host add "${1:-test}" vmadmin@127.0.0.1 --port "$T_SSH_PORT" --key "$ROOT/test/server/id_test" \
    --yes >&2
}

t_srv() { "$SSH" "$@"; }
# t_url <app> [path]: the app's link on the suite's server
t_url() { echo "http://$1.localhost:$T_HTTP_PORT${2:-/}"; }

# ---- request loop -----------------------------------------------------------------------------

# t_loop_start <name> <url> [interval]: about 10 requests a second in the background, one line each:
# "<http code> <seconds taken> <epoch seconds at the end>"
t_loop_start() {
  local name=$1 url=$2 iv=${3:-0.1}
  rm -f "$E/loop.$name.stop"
  (
    while [ ! -f "$E/loop.$name.stop" ]; do
      curl -s -o /dev/null -m 30 -w '%{http_code} %{time_total}' "$url"
      perl -MTime::HiRes=time -e 'printf " %.3f\n", time'
      sleep "$iv"
    done
  ) > "$E/loop.$name" 2> /dev/null &
  printf -v "T_LOOP_$name" '%s' "$!"
  sleep 0.5
}

# t_loop_stop <name>: stop the loop; sets T_LOOP_N (requests), T_LOOP_BAD (non-200),
# T_LOOP_MAX (slowest request, s) and T_LOOP_STALL (longest time between two 200s, s)
t_loop_stop() {
  local name=$1 v="T_LOOP_$1" pid
  pid=${!v:-}
  sleep 0.5
  touch "$E/loop.$name.stop"
  [ -n "$pid" ] && wait "$pid" 2> /dev/null
  read -r T_LOOP_N T_LOOP_BAD T_LOOP_MAX T_LOOP_STALL < <(awk '
    { n++; if ($1 != 200) bad++; if ($2 > max) max = $2
      if ($1 == 200) { if (last != "" && $3 - last > stall) stall = $3 - last; last = $3 } }
    END { printf "%d %d %.3f %.3f\n", n, bad, max, stall }' "$E/loop.$name")
  echo "loop $name: $T_LOOP_N requests, $T_LOOP_BAD not 200, slowest ${T_LOOP_MAX}s," \
    "longest stall ${T_LOOP_STALL}s" >&2
}

# ---- terminal helpers ---------------------------------------------------------------------------

# t_pty <cols> <rows> <seconds> cmd...: run cmd on a pseudo-terminal of that size, print what it
# wrote (raw, with escape sequences). After <seconds> its process group gets SIGTERM; the pty is
# still drained (a child writing exit output would block on a full pty otherwise), and SIGKILL
# follows after T_PTY_GRACE seconds (default 3). Always returns, within about seconds + grace + 1.
# Status: the child's exit status, or 128 + signal. Needs python3.
t_pty() {
  local cols=$1 rows=$2 secs=$3
  shift 3
  python3 - "$cols" "$rows" "$secs" "${T_PTY_GRACE:-3}" "$@" <<'PY'
import fcntl, os, pty, select, signal, struct, sys, termios, time
cols, rows, secs, grace = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
pid, fd = pty.fork()
if pid == 0:
    os.environ["COLUMNS"], os.environ["LINES"] = str(cols), str(rows)
    os.execvp(sys.argv[5], sys.argv[5:])
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
os.kill(pid, signal.SIGWINCH)
out = sys.stdout.buffer
status = None

def reap():
    global status
    if status is None:
        try:
            p, st = os.waitpid(pid, os.WNOHANG)
            if p == pid: status = st
        except ChildProcessError:
            status = 0
    return status is not None

def signal_group(sig):
    for f in (lambda: os.killpg(pid, sig), lambda: os.kill(pid, sig)):
        try: f(); return
        except OSError: pass

# phases: run until <secs>; then SIGTERM and keep draining for <grace>; then SIGKILL and drain
# for at most one more second. The pty is read in every phase.
deadline, phase, eof = time.time() + secs, 0, False
while True:
    now = time.time()
    if now >= deadline:
        if reap() and eof: break
        if phase == 0: signal_group(signal.SIGTERM); phase, deadline = 1, now + grace
        elif phase == 1: signal_group(signal.SIGKILL); phase, deadline = 2, now + 1
        else: break
        continue
    if eof:
        if reap(): break
        time.sleep(0.05); continue
    r, _, _ = select.select([fd], [], [], min(deadline - now, 0.1))
    if r:
        try: data = os.read(fd, 65536)
        except OSError: data = b""   # EIO: the slave side is closed
        if not data: eof = True; continue
        try: out.write(data); out.flush()
        except BrokenPipeError: pass
    elif reap() and phase > 0:
        break
if not reap():
    signal_group(signal.SIGKILL)
    try: _, status = os.waitpid(pid, 0)
    except ChildProcessError: status = 0
st = status
sys.exit(os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st))
PY
}

# t_assert_width <file> <width>: every line (escape sequences removed, UTF-8 aware) is at most
# <width> columns and box lines (starting with a border glyph) are exactly <width>.
# Prints offending lines to stderr.
t_assert_width() {
  local out
  [ -s "$1" ] || { echo "  t_assert_width: $1 is missing or empty" >&2; return 1; }
  out=$(perl -CSD -Mutf8 -ne '
    BEGIN { $w = shift @ARGV }
    chomp; s/\e\[[0-9;?]*[A-Za-z]//g; s/\r//g; $n++;
    next if $_ eq "";
    $l = length($_);
    if (/^[╭│├╰+|]/) { print "line $n: width $l != $w: $_\n" if $l != $w }
    elsif ($l > $w) { print "line $n: width $l > $w: $_\n" }' "$2" "$1")
  [ -z "$out" ] && return 0
  printf '%s\n' "$out" | head -5 >&2
  return 1
}

# ---- self-check: bash test/lib.sh --self-check ------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --self-check ]; then
  # shellcheck disable=SC2329 # called through check
  t_check_pty() { # a child that ignores SIGTERM and floods the pty must not hang t_pty
    local t0 t1 rc
    t0=$(date +%s)
    t_pty 80 24 2 /bin/bash -c 'trap "" TERM; while :; do printf "%0200d\n" 0; done' > /dev/null
    rc=$?
    t1=$(date +%s)
    echo "  flood + ignored SIGTERM: returned after $((t1 - t0)) s (limit 2 + 5), status $rc" >&2
    [ $((t1 - t0)) -le 7 ] && [ "$rc" = 137 ]
  }
  # shellcheck disable=SC2329 # called through check
  t_check_exit() { # a child that writes a lot on SIGTERM and exits: its output is kept
    local out
    out=$(t_pty 80 24 1 /bin/bash -c 'trap "for i in \$(seq 3000); do echo bye-\$i; done; exit 3" TERM
      while :; do sleep 0.1; done')
    echo "  exit output after SIGTERM: status $?, last line $(printf '%s' "$out" | tail -1 | tr -d '\r')" >&2
    printf '%s' "$out" | tr -d '\r' | grep -qx bye-3000
  }
  T_SUITE=lib.sh
  check "P1 t_pty returns when the child ignores SIGTERM and floods the pty" t_check_pty
  check "P2 t_pty drains exit output after SIGTERM" t_check_exit
  check "P4 t_eq refuses two empty values" eval '! t_eq "" "" 2> /dev/null'
  check "P5 t_assert_width fails on an empty file" eval '! t_assert_width /dev/null 80 2> /dev/null'
  check "P3 t_pty passes the exit status" eval 't_pty 80 24 5 /bin/bash -c "echo hi; exit 7" > /dev/null; [ $? = 7 ]'
  t_done
fi
