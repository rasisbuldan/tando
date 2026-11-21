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

# ---- U1 port_pick: a new app's port and its own pre-flight port (from a range of its own, kept
# as preflight_port) are no other app's port or pre-flight port (preflight_port, or port + 100 for
# an app made before it), and nothing listens on them. A stopped app listens on neither, so `ss`
# alone does not see them (a range widened past 100 ports gave an app another app's pre-flight
# port: that app's every deploy failed "pre-flight port in use", and the loopback rules let its user
# reach the new app). (Before the pre-flight range, the new app's own pre-flight port was its port
# + 100: U1d, U1f and U1h check the same rules for the port from the pre-flight range.)
# (ss: a stub; $T/listen holds the ports something listens on)
pp() { # lo hi plo phi app-ports... -> "port preflight" as port_pick picks them (empty when none)
  local lo=$1 hi=$2 plo=$3 phi=$4 a i=0
  shift 4
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
    ss() { local p; for p in $(cat "$R/listen" 2> /dev/null); do echo "LISTEN 0 4096 127.0.0.1:$p 0.0.0.0:*"; done; }
    port_pick "$2" "$3" "$4" "$5"' _ "$(agent_fn ports_used port_pick)" "$lo" "$hi" "$plo" "$phi"
}
eq() { [ "$1" = "$2" ] || { echo "got [$1], want [$2]" >&2; return 1; }; }
: > "$T/listen"
check "U1a first free port of each range" eq "$(pp 4100 4199 14100 14199)" "4100 14100"
check "U1b a taken port is skipped" eq "$(pp 4100 4199 14100 14199 4100 4101)" "4102 14100"
# 4100..4199 taken (apps from before: pre-flight port + 100), the range widened to 4399
check "U1c not another app's pre-flight port (port + 100)" eq "$(pp 4100 4399 14100 14199 $(seq 4100 4199))" "4300 14100"
check "U1d its pre-flight port is not another app's pre-flight port" eq "$(pp 4100 4199 14100 14199 4100+14100)" "4101 14101"
check "U1e not an adopted app's preflight_port" eq "$(pp 4100 4199 14100 14199 9000+4100)" "4101 14100"
check "U1f its pre-flight port is not another app's port" eq "$(pp 4100 4199 14100 14199 14100)" "4100 14101"
echo 4100 > "$T/listen"
check "U1g a port something listens on is skipped" eq "$(pp 4100 4199 14100 14199)" "4101 14100"
echo 14100 > "$T/listen"
check "U1h a pre-flight port something listens on is skipped" eq "$(pp 4100 4199 14100 14199)" "4100 14101"
: > "$T/listen"
check "U1i none free: fails" eq "$(pp 4100 4100 14100 14199 4100 || echo none)" none
check "U1j no pre-flight port free: fails" eq "$(pp 4100 4199 14100 14100 9000+14100 || echo none)" none
check "U1k never Caddy's admin port or PostgreSQL's" eq "$(pp 5432 5433 2019 2020)" "5433 2020"
# port_ranges_ok: what host setup takes (port_min/port_max, preflight_min/preflight_max)
pr() { # lo hi plo phi -> ok, or why not
  # shellcheck disable=SC2016
  "$BASH" -c 'eval "$1"; PR_LO=$2 PR_HI=$3 PF_LO=$4 PF_HI=$5; if port_ranges_ok; then echo ok; else echo "$PR_WHY"; fi' _ "$(agent_fn port_ranges_ok)" "$@"
}
check "U1l the default ranges are taken" eq "$(pr 4100 4999 14100 14999)" ok
check "U1m overlapping ranges are refused" eval 'pr 4100 4999 4900 5899 | grep -q overlap'
check "U1n a range with PostgreSQL's port is refused" eval 'pr 4100 4999 5100 5999 | grep -q 5432'
check "U1o a pre-flight range smaller than the app range is refused" eval 'pr 4100 4999 14100 14199 | grep -q "at least as many"'

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

# ---- U4 the hold window of a restart takes Caddy's lock shared: restarts of different apps run
# beside each other (each window only keeps Caddy reloads out); a site change takes it exclusive
# (flock: a stub that records its options)
hw() { # function -> the flock options it used
  # shellcheck disable=SC2016
  R=$T "$BASH" -c 'eval "$1"; flock() { echo "$*" >> "$R/flock"; }; chmod() { :; }; '"$1"' 2> /dev/null; cat "$R/flock"' _ \
    "$(agent_fn hold_window_start caddy_try_lock)"
  rm -f "$T/flock"
}
check "U4a a restart's hold window locks shared" eval 'hw hold_window_start | grep -q -- "-s "'
check "U4b a site change locks exclusive" eval '! hw caddy_try_lock | grep -q -- "-s"'

# ---- U5 a job's start and end, and a failed release command's last lines, read only the app's
# journal namespace (and the main journal), never every app's (--namespace='*' opened every
# namespace's files: O(apps) per job run, O(apps squared) when every hourly job starts at :00)
# shellcheck disable=SC2016
jq_ns=$("$BASH" -c 'eval "$1"; jns() { echo "--namespace=+tando-$A"; }; A=a1; job_jq u.service; echo "${JQ[*]}"' _ "$(agent_fn job_jq)")
check "U5a a job's journal query is its app's namespace" eq "$(printf '%s\n' "$jq_ns" | grep -o -- '--namespace=[^ ]*')" "--namespace=+tando-a1"
# shellcheck disable=SC2016
jq_ns=$("$BASH" -c 'eval "$1"; jns() { :; }; A=a1; job_jq u.service; echo "${JQ[*]}"' _ "$(agent_fn job_jq)")
check "U5b an app without its own namespace: the main journal" eval '! printf "%s\n" "$jq_ns" | grep -q -- --namespace'
check "U5c no journal query of the agent opens every namespace" eval '! grep -n -- "--namespace=.\*" "$ROOT/server/tando-agent" | grep -v "^[0-9]*:#"'

# ---- U6 daemon-reload only when a unit file changed, and in host setup once for all apps
# (journal_dir reloaded systemd on every call: with 100 apps, host setup reloaded it 100 times and
# every reload re-reads every unit). Paths under /etc are moved into $T; systemctl, id and
# systemd-tmpfiles are stubs; $T/calls lists the systemctl calls.
jd() { # [DR_FLAG]: one journal_dir; prints the number of daemon-reloads
  : > "$T/calls"
  # shellcheck disable=SC2016
  R=$T DRF=${1:-} "$BASH" -c 'eval "$1"; systemctl() { echo "$*" >> "$R/calls"; }; id() { echo grp; }
    systemd-tmpfiles() { :; }; A=a1 AU=tando-a1; DR_FLAG=$DRF; journal_dir' _ \
    "$(agent_fn journal_dir write_if_changed dreload | sed "s#/etc/#$T/etc/#g")"
  grep -c daemon-reload "$T/calls"
}
rm -rf "${T:?}/etc"; mkdir -p "$T/etc/tmpfiles.d" "$T/etc/systemd/system"
check "U6a a new journal drop-in: one daemon-reload" eq "$(jd)" 1
check "U6b nothing changed: no daemon-reload" eq "$(jd)" 0
rm -rf "${T:?}/etc/systemd/system"; mkdir -p "$T/etc/systemd/system"; rm -f "$T/drf"
check "U6c in host setup's loop: none, only noted" eq "$(jd "$T/drf")" 0
check "U6d ... in the flag file setup reloads once for" test -f "$T/drf"
check "U6e host setup reloads systemd once, after the loop (not per app)" eval \
  'sed -n "/^cmd_setup() {/,/^}/p" "$ROOT/server/tando-agent" | grep -n "daemon-reload" | grep -q "drf"'

# ---- U7 host setup's sites: staged (<app>.caddy.new) by every app, then one validation and one
# reload for all; a refused config puts every file back. (caddy, systemctl: stubs; $T/calls)
cis() { # fail|ok -> the calls; the site files after it in $T/after
  : > "$T/calls"
  # shellcheck disable=SC2016
  R=$T FAILV=$1 "$BASH" -c 'eval "$1"; caddy() { echo "caddy $1" >> "$R/calls"; [ "$1" != validate ] || [ "$FAILV" != fail ] || { echo "Error: bad"; return 1; }; }
    systemctl() { echo "systemctl $*" >> "$R/calls"; }; flock() { :; }; chmod() { :; }; sync() { :; }; ss() { :; }; journalctl() { :; }; now() { date +%s; }
    caddy_install_staged; echo "rc=$? n=$WC_N why=$WC_WHY" >> "$R/calls"' _ \
    "$(agent_fn caddy_install_staged caddy_try_lock caddy_binds caddy_reload caddy_unload | sed "s#/etc/#$T/etc/#g")"
  cat "$T/etc/caddy/tando/"* > "$T/after" 2> /dev/null
}
rm -rf "${T:?}/etc/caddy"; mkdir -p "$T/etc/caddy/tando"
for i in 1 2 3; do echo "old$i" > "$T/etc/caddy/tando/a$i.caddy"; echo "new$i" > "$T/etc/caddy/tando/a$i.caddy.new"; done
cis ok
check "U7a three staged sites: one validation" eq "$(grep -c '^caddy validate' "$T/calls")" 1
check "U7b ... and one reload" eq "$(grep -c '^systemctl reload caddy' "$T/calls")" 1
check "U7c ... and all three are in place" eq "$(sort "$T/after" | tr '\n' ' ')" "new1 new2 new3 "
for i in 1 2 3; do echo "newer$i" > "$T/etc/caddy/tando/a$i.caddy.new"; done
cis fail
check "U7d Caddy refuses: no reload" eq "$(grep -c '^systemctl reload caddy' "$T/calls")" 0
check "U7e ... and every file is back as it was" eq "$(sort "$T/after" | tr '\n' ' ')" "new1 new2 new3 "
cis ok
check "U7f nothing staged: no validation, no reload" eq "$(grep -c 'validate\|reload' "$T/calls")" 0

echo "core-unit: $n checks, $nf failed"
[ "$nf" = 0 ]
