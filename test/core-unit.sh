#!/bin/bash
# test/core-unit.sh: unit checks of the deploy engine's own logic that need no server: functions
# of server/tando-agent (taken out of the file with sed, as test/ui-test.sh does) and of the
# client (lib/*.sh) on stubs in a temp directory. Run by test/ui-test.sh (and on its own);
# bash 3.2 compatible.
#
#   test/core-unit.sh [tando-root]     (default: this checkout)
#
# One line per failed check; the last line is "core-unit: <n> checks, <m> failed".
set -u
here=$(cd "$(dirname "$0")/.." && pwd -P)
ROOT=${1:-$here}
T=$(mktemp -d "${TMPDIR:-/tmp}/core-unit.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
n=0 nf=0
check() { # text command...
  local t=$1; shift
  n=$((n + 1))
  "$@" > /dev/null 2>&1 || { nf=$((nf + 1)); echo "FAIL core-unit: $t"; }
}
# agent_fn names...: the definitions of those functions of the agent, for eval
agent_fn() {
  local f s=""
  for f; do s="$s/^$f() {/,/^}/p;"; done
  sed -n "$s" "$ROOT/server/tando-agent"
}

# ---- U1 port_pick: a new app's port is no other app's port or pre-flight port (port + 100, or
# its preflight_port), and its own pre-flight port is none of those either. A stopped app listens
# on neither, so `ss` alone does not see them (a range widened past 100 ports, as the docs advise
# when it is used up, gave an app another app's pre-flight port: that app's every deploy failed
# "pre-flight port in use", and the loopback rules let its user reach the new app)
# (ss: a stub; $T/listen holds the ports something listens on)
pp() { # lo hi app-ports... -> the port port_pick picks (empty when none)
  local lo=$1 hi=$2 a i=0
  shift 2
  rm -rf "${T:?}/apps"; mkdir -p "$T/apps"
  for a; do
    i=$((i + 1)); mkdir -p "$T/apps/a$i"
    case $a in
      *+*) printf 'port=%s\npreflight_port=%s\n' "${a%+*}" "${a#*+}" > "$T/apps/a$i/app.conf";;
      *) printf 'port=%s\n' "$a" > "$T/apps/a$i/app.conf";;
    esac
  done
  # shellcheck disable=SC2016
  R=$T "$BASH" -c 'eval "$1"
    ss() { local p; for p in $(cat "$R/listen" 2> /dev/null); do case " $* " in *":$p "*) echo "LISTEN 0 0 127.0.0.1:$p";; esac; done; }
    port_pick "$2" "$3"' _ "$(agent_fn grepq ports_used port_pick)" "$lo" "$hi"
}
eq() { [ "$1" = "$2" ] || { echo "got [$1], want [$2]" >&2; return 1; }; }
: > "$T/listen"
check "U1a first free port of the range" eq "$(pp 4100 4199)" 4100
check "U1b a taken port is skipped" eq "$(pp 4100 4199 4100 4101)" 4102
# 4100..4199 taken, the range widened to 4399: 4200..4299 are their pre-flight ports
check "U1c not another app's pre-flight port (port + 100)" eq "$(pp 4100 4399 $(seq 4100 4199))" 4300
# 4300 is free, but its pre-flight port 4400 is a (stopped) app's port
check "U1d its own pre-flight port is not another app's port" eq "$(pp 4300 4301 4400)" 4301
check "U1e not an adopted app's preflight_port" eq "$(pp 4100 4199 9000+4100)" 4101
check "U1f its pre-flight port not an adopted app's preflight_port" eq "$(pp 4100 4199 9000+4200)" 4101
echo 4100 > "$T/listen"
check "U1g a port something listens on is skipped" eq "$(pp 4100 4199)" 4101
echo 4200 > "$T/listen"
check "U1h a pre-flight port something listens on is skipped" eq "$(pp 4100 4199)" 4101
: > "$T/listen"
check "U1i none free: fails" eq "$(pp 4100 4100 4100 || echo none)" none

# ---- U2 dir_lock (lib/deploy.sh): one deploy at a time from a project directory. A lock left by
# a deploy that died (its pid is gone) is taken over by one of two deploys that find it at once,
# never by both: the second one must not move away the lock the first has just taken.
# (kill: a stub that answers "gone" for the dead pid after DELAY seconds, so the two checks of
# that pid overlap; each deploy holds the lock 1.5 s and says when it has it)
dl() { # delay: one deploy from $T/proj
  # shellcheck disable=SC2016
  (cd "$T/proj" && DELAY=$1 "$BASH" -c '. "$1/lib/common.sh"; . "$1/lib/deploy.sh"
    kill() { if [ "$1" = -0 ] && [ "$2" = 999999 ]; then sleep "$DELAY"; return 1; fi; command kill "$@"; }
    dir_lock; echo "in $(date +%s)"; sleep 1.5; echo "out $(date +%s)"' _ "$ROOT")
}
rm -rf "${T:?}/proj"; mkdir -p "$T/proj/.tando/deploy.lock"; echo 999999 > "$T/proj/.tando/deploy.lock/pid"
dl 0.3 > "$T/dl1" 2>&1 & p1=$!
dl 0.6 > "$T/dl2" 2>&1 & p2=$!
wait $p1; wait $p2
both() { # the two deploys never held the lock at once (the second one waited, or was refused)
  local a1 b1 a2 b2
  a1=$(sed -n 's/^in //p' "$T/dl1"); b1=$(sed -n 's/^out //p' "$T/dl1")
  a2=$(sed -n 's/^in //p' "$T/dl2"); b2=$(sed -n 's/^out //p' "$T/dl2")
  cat "$T/dl1" "$T/dl2"
  [ -z "$a1" ] || [ -z "$a2" ] || [ "$a2" -ge "$b1" ] || [ "$a1" -ge "$b2" ]
}
check "U2a a stale deploy lock is taken over by one of two deploys, not by both" both
check "U2b ... and one of them has it" grep -q '^in ' "$T/dl1" "$T/dl2"

# ---- U3 act_follow (lib/deploy.sh): the laptop slept (or the CI runner stalled) while the
# server activated the release. On waking, the client asks for the result before it gives up on
# its deadline: a deploy that went live (or failed) is reported as such, not as "has not finished".
# (now: a stub; the first deploy-status says running and the clock then jumps a day ahead, the
# next one says ok)
af() { # [stuck] -> act_follow's output and status (stuck: deploy-status never says more than running)
  rm -rf "${T:?}/af"; mkdir -p "$T/af"
  [ -z "${1:-}" ] || : > "$T/af/stuck"
  # shellcheck disable=SC2016
  TMPD=$T/af "$BASH" -c '. "$1/lib/common.sh"; . "$1/lib/deploy.sh"
    now() { if [ -f "$TMPD/woke" ]; then echo 90000; else echo 1000; fi; }
    agent_raw() { if [ -f "$TMPD/woke" ] && [ ! -f "$TMPD/stuck" ]; then printf "phase=done\nresult=ok\n"; else : > "$TMPD/woke"; printf "phase=copy\nresult=running\n"; fi; }
    show_phases() { :; }; ui_box_close() { :; }; ui_dur() { echo "$1"; }
    APP=a HOST=h C_release="" C_timeout="" C_soak=""
    act_follow 20260101-000000 1000; echo "rc=$? result=$K_result"' _ "$ROOT" 2>&1
}
check "U3a after a long sleep the deploy's result is read before the deadline gives up" eq "$(af | tail -1)" "rc=0 result=ok"
check "U3b an activation that never ends is still given up at the deadline" eval 'af stuck | grep -q "has not finished"'

echo "core-unit: $n checks, $nf failed"
[ "$nf" = 0 ]
