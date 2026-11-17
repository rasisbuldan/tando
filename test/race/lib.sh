#!/bin/bash
# test/race/lib.sh: shared helpers for the concurrency tests (bash 3.2 safe, set -u safe).
#   . "$(dirname "$0")/lib.sh"; race_init <name>
# Server: TANDO_TEST_NAME (tando-race), TANDO_TEST_SSH_PORT (2446), TANDO_TEST_HTTP_PORT (8446).
# The CLI and agent under test are a snapshot of the checkout ($SNAP, made by setup.sh), so
# edits to server/ in the repository during a run do not change what is tested.
# Two "laptops": config dirs $E/cfgA and $E/cfgB (separate ControlMaster sockets).
set -u
RACE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd "$RACE_DIR/../.." && pwd -P)
export TANDO_TEST_NAME=${TANDO_TEST_NAME:-tando-race}
export TANDO_TEST_SSH_PORT=${TANDO_TEST_SSH_PORT:-2446}
export TANDO_TEST_HTTP_PORT=${TANDO_TEST_HTTP_PORT:-8446}
export TANDO_TEST_CADDY=${TANDO_TEST_CADDY:-ubuntu}
E=${RACE_WORK:-$ROOT/test/.race-$TANDO_TEST_NAME}
SNAP=${RACE_SNAP:-$E/snap}
R=$SNAP/bin/tando
HP=$TANDO_TEST_HTTP_PORT
export TANDO_COLOR=never TANDO_SOAK=${TANDO_SOAK:-2} TANDO_WAIT=1
SSH="$ROOT/test/server/ssh.sh"
RACE_V=0       # violations in this scenario
RACE_IT=0

race_init() { T_SUITE=$1; mkdir -p "$E/log/$1"; LOG=$E/log/$1; }

# rA/rB: the CLI as laptop A / laptop B (own config dir, own ControlMaster)
rA() { TANDO_CONFIG_DIR=$E/cfgA "$R" "$@"; }
rB() { TANDO_CONFIG_DIR=$E/cfgB "$R" "$@"; }
rX() { local c=$1; shift; TANDO_CONFIG_DIR=$E/cfg$c "$R" "$@"; }   # rX A|B|C... args
srv() { "$SSH" "$@"; }
sroot() { "$SSH" "sudo $(printf '%q ' "$@")"; }

# jitter: sleep 0-<max ms> (default 300) at random
jitter() { local m=${1:-300}; sleep "$(awk -v r=$RANDOM -v m="$m" 'BEGIN{printf "%.3f", (r%m)/1000}')"; }

# mkproj <laptop> <app> [version]: a copy of examples/hello named <app> under $E/proj/<laptop>/<app>
mkproj() {
  local p=$E/proj/$1/$2
  if [ ! -d "$p" ]; then
    mkdir -p "$E/proj/$1"; cp -R "$SNAP/examples/hello" "$p"
    sed -i '' "s/^app = .*/app = $2/" "$p/tando.conf" 2> /dev/null || sed -i "s/^app = .*/app = $2/" "$p/tando.conf"
    echo "host = test" >> "$p/tando.conf"
  fi
  [ -n "${3:-}" ] && echo "$3" > "$p/VERSION"
  echo "$p"
}
setv() { echo "$3" > "$E/proj/$1/$2/VERSION"; }

# served <app>: the version the app answers through Caddy ("-" when none)
served() { curl -s -m 5 "http://$1.localhost:$HP/" | sed -n 's/^hello v\([^ ]*\).*/\1/p' | head -1; }

# settle <app...>: wait until no activation unit / lock of the apps is busy (max 120 s)
settle() {
  local i
  for i in $(seq 1 120); do
    srv "sudo bash -c 'for a in $*; do f=/opt/tando/apps/\$a/lock; [ -f \$f ] || continue; flock -n \$f true || exit 1; done; systemctl list-units --plain --no-legend \"tando-*-act-*\" \"tando-*-pre-*\" | grep -q . && exit 1; exit 0'" 2> /dev/null && return 0
    sleep 1
  done
  return 1
}

# inv <iteration label> [app expected-version]...: check every invariant; logs and counts violations
inv() {
  local it=$1 out a v s; shift
  out=$(srv sudo bash -s < "$RACE_DIR/inv-server.sh" 2>&1)
  while [ $# -ge 2 ]; do
    a=$1 v=$2; shift 2
    s=$(served "$a")
    local cv; cv=$(srv "sudo cat /opt/tando/apps/$a/current/VERSION" 2> /dev/null)
    [ "$s" = "$cv" ] || out="$out
VIOL $a serves v${s:-none} but current release has v${cv:-none}"
    if [ "$v" != "*" ] && [ "$v" != any ]; then
      case " $v " in *" $s "*) ;; *) out="$out
VIOL $a serves v${s:-none}, expected one of: $v";; esac
    fi
  done
  if printf '%s\n' "$out" | grep -q '^VIOL'; then
    RACE_V=$((RACE_V + 1))
    printf '%s\n' "$out" | grep '^VIOL' | sed "s/^/[$T_SUITE $it] /" | tee -a "$LOG/violations" >&2
    return 1
  fi
  return 0
}

# doctor_ok <laptop>: doctor through the CLI reports 0 failed
doctor_ok() {
  local o; o=$(rX "$1" doctor 2>&1)
  if ! printf '%s' "$o" | grep -q ' 0 failed'; then
    printf '%s\n' "$o" | grep -E 'fail|✗' | head -8 | sed "s/^/[$T_SUITE doctor] VIOL /" | tee -a "$LOG/violations" >&2
    RACE_V=$((RACE_V + 1)); return 1
  fi
  return 0
}

# bad_output <file>: shell errors in client output (torn reads, unbound variables, arithmetic)
bad_output() {
  grep -E 'unbound variable|syntax error|arithmetic|integer expression|command not found|bad substitution|No such file|division by 0|line [0-9]+:' "$1"
}

# result line for the scenario table
race_result() { # name iterations
  echo "RESULT $1 iterations=$2 violations=$RACE_V" | tee -a "$E/results"
}
