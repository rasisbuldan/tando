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

# ---- U8 new_uid: app users and groups get ids from tando's band (uid_min-uid_max, default
# 30000-39999), not from 200-999 (used up after about 250 apps over a host's life); passwd and
# group are read once (getent per id forked 2 x 800 times); a retired id is used again only when
# the band has no other, the oldest first. (getent: a stub over $T/passwd, $T/group, $T/nss)
nu() { # [uid_min uid_max] -> the id new_uid picks, or "none"
  # shellcheck disable=SC2016
  R=$T LO=${1:-} HI=${2:-} "$BASH" -c 'eval "$1"; die() { echo none; exit 1; }
    getent() { if [ $# = 1 ]; then cat "$R/$1"; echo "$1" >> "$R/calls"; else grep -qx "$2" "$R/nss"; fi; }
    H_uid_min=$LO H_uid_max=$HI
    UID_MIN=30000 UID_MAX=39999
    new_uid' _ "$(agent_fn new_uid | sed 's/\${H\[uid_min\]:-/${H_uid_min:-/; s/\${H\[uid_max\]:-/${H_uid_max:-/')"
}
printf 'root:x:0:0::/:/bin/sh\ntando-x:x:30000:30000::/:/usr/sbin/nologin\n' > "$T/passwd"
printf 'root:x:0:\ng:x:30001:\n' > "$T/group"; echo 30002 > "$T/nss"; printf '999\n30003\n' > "$T/retired-uids"
: > "$T/calls"
check "U8a from the band: not a user's, group's, NSS's or retired id" eq "$(nu)" 30004
check "U8b passwd and group are read once each" eq "$(sort "$T/calls" | tr '\n' ' ')" "group passwd "
printf '30003\n30005\n30004\n' > "$T/retired-uids"
check "U8c only retired ones left: the oldest is used again" eq "$(nu 30003 30005)" 30003
printf 'root:x:0:\ng:x:30001:\nh:x:30003:\n' > "$T/group"
check "U8d none at all: fails" eq "$(nu 30003 30003)" none

# ---- U9 admission: a deploy that raises an app's memory caps is refused when every app's caps
# together would be over RAM x mem_overcommit (1.5); caps that do not grow always pass (a host
# that is over already still deploys); --force skips the check in configure. priority = high|low
# sets the OOM score. (/proc/meminfo: $T/meminfo; apps in $T/apps)
ma() { # this-app-MB [ram-MB] -> ok, or the reason
  echo "MemTotal: $((${2:-1000} * 1024)) kB" > "$T/meminfo"
  # shellcheck disable=SC2016
  R=$T D=$T/apps/a1 "$BASH" -c 'eval "$1"; MEM_OVERCOMMIT=1.5; A=a1; if mem_admit "$2"; then echo ok; else echo "$ADMIT_WHY"; fi' _ \
    "$(agent_fn mem_caps_mb mem_admit | sed "s#/proc/meminfo#$T/meminfo#g")" "$1"
}
rm -rf "${T:?}/apps"; mkdir -p "$T/apps/a1" "$T/apps/a2" "$T/apps/a3"
printf 'memory=256M\n' > "$T/apps/a1/app.conf"
printf 'memory=1G\nworker.q=x\nworker.r=y\nworker.r.memory=128M\n' > "$T/apps/a2/app.conf"   # 1024 + 1024 + 128
printf 'port=1\n' > "$T/apps/a3/app.conf"                                                 # 256 (the default)
check "U9a caps: memory, each worker's (or the app's), 256M by default" eq \
  "$("$BASH" -c 'eval "$1"; mem_caps_mb "$2"/apps/a*/app.conf' _ "$(agent_fn mem_caps_mb)" "$T" | sed "s#$T/apps/##; s#/app.conf##" | tr '\n' ' ')" "a1 256 a2 2176 a3 256 "
check "U9b within RAM x 1.5: taken" eq "$(ma 512 2000)" ok
check "U9c over it: refused, and says how much" eval 'ma 1024 2000 | grep -q "3456 MB with a1 at 1024 MB, over 3000 MB"'
check "U9d not raised (the host is over already): taken" eq "$(ma 256 500)" ok
check "U9e configure refuses unless --force" eval 'sed -n "/^cmd_configure() {/,/^}/p" "$ROOT/server/tando-agent" | grep -q "((!force)) && ! mem_admit"'
# U9h-j: an app with idle_stop is stopped most of the time: admission counts its web process at
# 2 MB plus 20% of its cap (idle_awake), its workers whole; static and container apps, and
# idle_stop = off, as before. 8 such apps of 256M and this one fit in 1000 MB x 1.5 (2304 MB of
# full caps were refused)
rm -rf "${T:?}/apps"; mkdir -p "$T/apps/a1"
for i in 2 3 4 5 6 7 8 9; do mkdir -p "$T/apps/a$i"; printf 'memory=256M\nidle_stop=6h\n' > "$T/apps/a$i/app.conf"; done
printf 'memory=128M\n' > "$T/apps/a1/app.conf"   # (raised to 256M below)
mkdir -p "$T/x"
printf 'memory=100M\nidle_stop=10m\nworker.q=x\n' > "$T/x/w.conf"          # 2 + 20 + 100
printf 'memory=100M\nidle_stop=off\n' > "$T/x/off.conf"                   # 100
printf 'memory=100M\nidle_stop=6h\nrecipe=container\n' > "$T/x/ct.conf"   # 100
mc() { "$BASH" -c 'eval "$1"; shift; mem_caps_mb "$@"' _ "$(agent_fn mem_caps_mb)" "$@" | sed "s#$T/x/##" | tr '\n' ' '; }
check "U9h admission counts an idle_stop app's web at 2 MB + 20% of its cap, its workers whole" eq \
  "$(mc -a "$T/x/w.conf" "$T/x/off.conf" "$T/x/ct.conf")" "w.conf 122 off.conf 100 ct.conf 100 "
check "U9i without -a (MemoryLow of high-priority apps): the whole caps" eq "$(mc "$T/x/w.conf")" "w.conf 200 "
check "U9j 8 idle_stop apps of 256M and one raised to 256M fit in 1000 MB RAM x 1.5" eq "$(ma 256 1000)" ok
# shellcheck disable=SC2016
oa() { "$BASH" -c 'eval "$1"; C_priority=$2; oom_adj' _ "$(agent_fn oom_adj | sed 's/\${C\[priority\]:-}/${C_priority:-}/')" "$1"; }
check "U9f priority: high 100, default 500, low 900" eq "$(oa high) $(oa '') $(oa low)" "100 500 900"
# write_slice: the app's slice file is written whatever its priority (a priority that was not
# high once ended the write as failed: no slice, the app's units in a slice without limits)
ws() { # priority -> the slice file's MemoryMax and MemoryLow lines
  rm -rf "${T:?}/etc"; mkdir -p "$T/etc/systemd/system"
  # shellcheck disable=SC2016
  # (bash 3.2 has no associative arrays: C[key] is C_key, and no workers)
  "$BASH" -c 'eval "$1"; C_memory=128M C_priority=$2; A=a1; write_slice; echo "rc=$?"' _ \
    "$(agent_fn write_slice size_mb write_if_changed app_slice prof_get mem_cap | sed -e "s#/etc/#$T/etc/#g" \
      -e 's/\${C\[\([a-z]*\)\]:-/${C_\1:-/g' -e 's/" \${!C\[\*\]}"/" "/')" "$1"
  grep -h '^Memory' "$T/etc/systemd/system/tando-a1.slice" 2> /dev/null | tr '\n' ' '
}
check "U9g write_slice: written for every priority (normal, low, high with MemoryLow)" eq \
  "$(ws '' | tr '\n' ' ')/$(ws low | tr '\n' ' ')/$(ws high | tr '\n' ' ')" \
  "rc=0 MemoryMax=384M /rc=0 MemoryMax=384M /rc=0 MemoryMax=384M MemoryLow=128M "

# ---- U10 jobs: the default spread is a sixth of the job's period, at most 10 minutes (100 apps'
# hourly jobs started within 15 s), each timer at a fixed offset; at most job_slots runs at once
# host-wide (job-begin waits for a slot, job-end gives it back). (systemd-analyze, date: stubs; a
# time is "@<epoch>")
sf() { # first-epoch second-epoch -> the spread
  # shellcheck disable=SC2016
  "$BASH" -c 'eval "$1"; JOB_SPREAD=15 JOB_SPREAD_MAX=600
    systemd-analyze() { printf "  Next elapse: x\n     (in UTC): @%s\n     Iter. #2: x\n     (in UTC): @%s\n" "$A1" "$A2"; }
    date() { local x=$2; echo "${x#@}"; }
    job_spread_for "*:00"' _ "$(agent_fn job_spread_for)"
}
check "U10a hourly: 10 minutes" eq "$(A1=3600 A2=7200 sf)" 600
check "U10b every 15 minutes: 150 s" eq "$(A1=900 A2=1800 sf)" 150
check "U10c daily: still at most 10 minutes" eq "$(A1=86400 A2=172800 sf)" 600
# shellcheck disable=SC2016
check "U10i a server in UTC (no \"(in UTC)\" lines): the same" eq "$("$BASH" -c 'eval "$1"; JOB_SPREAD=15 JOB_SPREAD_MAX=600
    systemd-analyze() { printf "  Next elapse: @900\n     From now: x\n     Iter. #2: @1800\n"; }
    date() { local x=$2; echo "${x#@}"; }; job_spread_for "*:0/15"' _ "$(agent_fn job_spread_for)")" 150
# shellcheck disable=SC2016
check "U10j ... and systemd 259's \"Iteration #2:\"" eq "$("$BASH" -c 'eval "$1"; JOB_SPREAD=15 JOB_SPREAD_MAX=600
    systemd-analyze() { printf "    Next elapse: @900\n       From now: x\n   Iteration #2: @1800\n"; }
    date() { local x=$2; echo "${x#@}"; }; job_spread_for "*:0/15"' _ "$(agent_fn job_spread_for)")" 150
check "U10d timers get a fixed offset (FixedRandomDelay)" grep -q "RandomizedDelaySec=%s.nFixedRandomDelay=yes" "$ROOT/server/tando-agent"
js() { # function args... (slots: $T/jobslots; units in $T/busy run)
  # shellcheck disable=SC2016
  R=$T "$BASH" -c 'eval "$1"; shift; job_busy() { grep -qx "$1" "$R/busy"; }; now() { date +%s; }; JS=2; "$@"' _ \
    "$(agent_fn job_slots job_slot_take job_slot_give | sed 's/\${H\[job_slots\]:-}/${JS:-}/')" "$@"
}
rm -rf "${T:?}/jobslots"; printf 'a.service\nb.service\n' > "$T/busy"
js job_slot_take a.service; js job_slot_take b.service
js job_slot_take c.service > /dev/null 2>&1 & jp=$!
sleep 2   # (proves c waits: both slots are held by runs going on)
check "U10e a third run waits while both slots are held" kill -0 "$jp"
js job_slot_give a.service
t_wait() { local i=0; while kill -0 "$jp" 2> /dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done; ! kill -0 "$jp" 2> /dev/null; }
check "U10f ... and gets the slot a run gave back" t_wait
check "U10g ... which now names it" eval 'cat "$T"/jobslots/*/unit | grep -qx c.service'
printf 'c.service\n' > "$T/busy"   # b's run ended without its job-end
check "U10h a slot whose run is over is taken over" eval 'js job_slot_take d.service && grep -qx d.service "$T/jobslots/2/unit"'
kill "$jp" 2> /dev/null

# ---- U11 backups: one host queue (tando-backups.timer at the start of backup_window) instead of a
# timer per app that all fired at midnight; an app keeps only its backup unit, and its timer of
# before goes (host setup does it for every app). (systemctl: a stub; /etc and /var in $T)
sb() { # backup-setting -> what is left of the app's backup units, and the systemctl calls
  : > "$T/calls"
  # shellcheck disable=SC2016
  R=$T BK=$1 "$BASH" -c 'eval "$1"; systemctl() { echo "$*" >> "$R/calls"; }; A=a1 AGENT=/x/tando-agent; C_backup=$BK; sync_backup_timer
    ls "$R/etc/systemd/system" | grep backup | tr "\n" " "' _ \
    "$(agent_fn sync_backup_timer write_if_changed dreload | sed "s#/etc/#$T/etc/#g; s#/var/lib/#$T/var/lib/#g; s/\${C\[backup\]:-off}/\${C_backup:-off}/")"
}
rm -rf "${T:?}/etc"; mkdir -p "$T/etc/systemd/system" "$T/var/lib/systemd/timers"
printf '[Timer]\nOnCalendar=daily\n' > "$T/etc/systemd/system/tando-a1-backup.timer"; : > "$T/var/lib/systemd/timers/stamp-tando-a1-backup.timer"
check "U11a an app's timer of before goes, its backup unit stays" eq "$(sb daily)" "tando-a1-backup.service "
check "U11b ... disabled first, and its stamp is gone" eval 'grep -q "disable -q --now tando-a1-backup.timer" "$T/calls" && [ ! -e "$T/var/lib/systemd/timers/stamp-tando-a1-backup.timer" ]'
check "U11c again: nothing changes, no daemon-reload" eval '[ "$(sb daily)" = "tando-a1-backup.service " ] && ! grep -q daemon-reload "$T/calls"'
check "U11d backup off: the unit goes" eq "$(sb off)" ""
check "U11e host setup moves every app to the queue and installs it" eval \
  'sed -n "/^cmd_setup() {/,/^}/p" "$ROOT/server/tando-agent" | grep -q "journal_dir; sync_backup_timer" &&
   sed -n "/^cmd_setup() {/,/^}/p" "$ROOT/server/tando-agent" | grep -q "backup_sched_install"'
# shellcheck disable=SC2016,SC2034  # (bo is read in the eval below)
bo=$("$BASH" -c 'eval "$1"; backup_order zeta alpha mid' _ "$(agent_fn backup_order)" | tr '\n' ' ')
check "U11f the queue's order: a hash of the name, the same each night (not the alphabet)" eval \
  '[ "$bo" != "alpha mid zeta " ] && [ "$(echo $bo | tr " " "\n" | sort | tr "\n" " ")" = "alpha mid zeta " ]'
bw() { "$BASH" -c 'eval "$1"; BACKUP_WINDOW=01:00-05:00; H_w=$2; backup_window' _ "$(agent_fn backup_window | sed 's/\${H\[backup_window\]:-/${H_w:-/')" "$1"; }
check "U11g backup_window: 01:00-05:00 by default, a bad one is the default" eq "$(bw '') / $(bw 22:30-03:00) / $(bw 25:00-1)" "01:00 05:00 / 22:30 03:00 / 01:00 05:00"

# ---- U12 PostgreSQL for 100 apps (docs/ARCHITECTURE.md, "PostgreSQL"): its memory settings from
# the server's RAM (pg_sizing: max_connections about 100 on 8 GB, shared_buffers 15%), and the
# apps' db_pool together checked against max_connections (db_pool_check)
pgsz() { # MemTotal-kB [cgroup memory.max] -> "max_connections shared_buffers work_mem maintenance effective"
  printf 'MemTotal:       %s kB\n' "$1" > "$T/meminfo"
  printf '%s\n' "${2:-max}" > "$T/memory.max"
  # shellcheck disable=SC2016
  "$BASH" -c 'eval "$1"; pg_sizing; echo "$PGS_MC $PGS_SB $PGS_WM $PGS_MWM $PGS_ECS"' _ \
    "$(agent_fn pg_sizing | sed -e "s#/proc/meminfo#$T/meminfo#" -e "s#/sys/fs/cgroup/memory.max#$T/memory.max#")"
}
check "U12a 8 GB: max_connections 100, shared_buffers 15%, work_mem 4 MB" eq "$(pgsz 8048000)" "100 1178 4 245 3929"
check "U12b 4 GB: max_connections 50" eq "$(pgsz 4020000 | cut -d' ' -f1-2)" "50 588"
check "U12c 1 GB: at least 50 connections, work_mem at least 2 MB" eq "$(pgsz 1000000 | cut -d' ' -f1-3)" "50 146 2"
check "U12d 64 GB: at most 400 connections" eq "$(pgsz 65000000 | cut -d' ' -f1)" 400
check "U12e a cgroup limit under MemTotal (a container) is the RAM" eq "$(pgsz 8048000 2147483648 | cut -d' ' -f1-2)" "50 307"
pgpool() { # mine max this-app-conf other-app-confs... (a conf: lines joined with ,) -> ok or the refusal
  local c i=0 mine=$1
  rm -rf "${T:?}/pa"; mkdir -p "$T/pa/apps/me"
  printf 'max_connections = %s\n' "$2" > "$T/pa/tando.conf"
  [ -z "$3" ] || printf '%s\n' "$3" | tr , '\n' > "$T/pa/apps/me/app.conf"
  shift 3
  for c; do i=$((i + 1)); mkdir -p "$T/pa/apps/a$i"; printf '%s\n' "$c" | tr , '\n' > "$T/pa/apps/a$i/app.conf"; done
  # shellcheck disable=SC2016
  R=$T/pa D=$T/pa/apps/me A=me "$BASH" -c 'eval "$1"; die() { echo "$*"; exit 1; }; DB_POOL=5 DB_TOOL_SLOTS=5
    db_pool_check "$2" "$R/tando.conf" && echo ok' _ "$(agent_fn db_pool_check)" "$mine" 2>&1
}
# max_connections 50: 42 for the apps (3 for the superuser, 5 for tando's own)
check "U12f a new app's pool that fits is taken" eq "$(pgpool 5 50 "" database=postgres database=postgres,db_pool=20 recipe=static)" ok
check "U12g one that brings the sum over max_connections is refused, and says what to do" \
  eval 'pgpool 20 50 "" database=postgres database=postgres,db_pool=20 | grep -q "connections to 45, over the 42 PostgreSQL has.*smaller db_pool"'
# a server already over (an older tando's apps): an app whose pool does not grow still deploys
check "U12h an app whose pool does not grow deploys on a server already over" \
  eq "$(pgpool 20 30 database=postgres,db_pool=20 database=postgres database=postgres)" ok
check "U12i ... and one that grows it is refused" \
  eval 'pgpool 21 30 database=postgres,db_pool=20 database=postgres database=postgres | grep -q "over the 22"'

# ---- U18 runtimes: node_lite (a `node` that adds V8's --lite-mode, first in the app's PATH: V8
# options such as --lite-mode are not allowed in NODE_OPTIONS) and workerd (the capnp config of
# one worker: its modules, compatibility settings, env as bindings)
lite() { # args -> what a (stub) node got through the shim
  rm -rf "${T:?}/lite"; mkdir -p "$T/lite/real" "$T/lite/etc"
  printf '#!/bin/sh\necho "$*"\n' > "$T/lite/real/node"; chmod +x "$T/lite/real/node"
  # shellcheck disable=SC2016
  "$BASH" -c 'eval "$1"; R=$2/etc; lite_shim && PATH=$R/lite:$3 && shift 3 && node "$@"' _ \
    "$(agent_fn lite_shim)" "$T/lite" "$T/lite/real:/usr/bin:/bin" "$@"
}
check "U18a node_lite: the shim runs node with --lite-mode first, then the app's arguments" \
  eq "$(lite server.js a)" "--lite-mode server.js a"
check "U18b node_lite: the shim is executable and written once (a second write leaves it as it is)" \
  eval 'lite x > /dev/null; test -x "$T/lite/etc/lite/node" && m=$(cksum < "$T/lite/etc/lite/node") &&
        "$BASH" -c "eval \"\$1\"; R=\$2/etc; lite_shim" _ "$(agent_fn lite_shim)" "$T/lite" && test "$m" = "$(cksum < "$T/lite/etc/lite/node")"'
wc_() { # dir port entry [name=value lines on stdin] -> the capnp config
  # shellcheck disable=SC2016
  "$BASH" -c 'eval "$1"; shift; workerd_capnp "$@"' _ "$(agent_fn workerd_capnp)" "$@"
}
mkdir -p "$T/w1/src/lib"
printf 'name = "x"\nmain = "src/index.js"\ncompatibility_date = "2025-06-01"\ncompatibility_flags = ["nodejs_compat", "global_navigator"]\n' > "$T/w1/wrangler.toml"
: > "$T/w1/src/index.js"; : > "$T/w1/src/util.js"; : > "$T/w1/src/lib/more.mjs"
mkdir -p "$T/w1/node_modules/x"; : > "$T/w1/node_modules/x/skip.js"
check "U18c workerd config: the entry is the first module, its siblings follow, node_modules is left out" \
  eval 'c=$(wc_ "$T/w1" 9100 src/index.js < /dev/null); printf "%s\n" "$c" | grep -n "esModule" | head -1 | grep -q "\"index.js\"" &&
        echo "$c" | grep -q "name = \"util.js\"" && echo "$c" | grep -q "name = \"lib/more.mjs\"" && ! echo "$c" | grep -q skip.js'
check "U18d workerd config: listens on 127.0.0.1:<port> only" \
  eval 'wc_ "$T/w1" 9100 src/index.js < /dev/null | grep -q "address = \"127.0.0.1:9100\""'
check "U18e workerd config: compatibility date and flags from wrangler.toml" \
  eval 'c=$(wc_ "$T/w1" 9100 src/index.js < /dev/null); echo "$c" | grep -q "compatibilityDate = \"2025-06-01\"" &&
        echo "$c" | grep -q "compatibilityFlags = \[\"nodejs_compat\", \"global_navigator\"\]"'
check "U18f workerd config: a date newer than the pinned workerd knows is lowered to what it knows" \
  eval 'sed -i.bak "s/2025-06-01/2031-01-01/" "$T/w1/wrangler.toml"; wc_ "$T/w1" 9100 src/index.js < /dev/null | grep -q "compatibilityDate = \"2025-10-01\""'
check "U18g workerd config: env vars are text bindings, quotes and backslashes escaped" \
  eval 'c=$(printf "%s\n" "GREETING=hi \"you\" \\\\ ok" "N=1" | wc_ "$T/w1" 9100 src/index.js); echo "$c" | grep -qF "(name = \"GREETING\", text = \"hi \\\"you\\\" \\\\\\\\ ok\")" &&
        echo "$c" | grep -qF "(name = \"N\", text = \"1\")"'
check "U18h workerd config: no wrangler.toml: today-ish default date, no flags" \
  eval 'mkdir -p "$T/w2"; : > "$T/w2/a.js"; c=$(wc_ "$T/w2" 9101 a.js < /dev/null); echo "$c" | grep -q "compatibilityDate = \"2025-09-01\"" && ! echo "$c" | grep -q compatibilityFlags'
# ---- U13 a new app's user and its metadata group take their ids under one host lock (uid_lock):
# two `tando up` of new apps at once picked the same free id and the second groupadd failed
# ("GID already exists"). (flock, groupadd, new_uid and the rest: stubs; $T/calls in order)
ap() {
  : > "$T/calls"
  # shellcheck disable=SC2016
  R=$T "$BASH" -c 'eval "$1"; getent() { return 2; }; lockfile() { :; }; new_uid() { echo 30001; }
    flock() { echo "flock $*" >> "$R/calls"; }; groupadd() { echo "groupadd $*" >> "$R/calls"; }
    usermod() { :; }; id() { return 1; }; deploy_user() { return 1; }; chown() { :; }; chmod() { :; }
    touch() { :; }; install() { :; }; meta_mode() { :; }; die() { echo "die $*" >> "$R/calls"; exit 1; }
    A=a1 D=$R/a1; app_perms' _ "$(agent_fn meta_group_ok uid_lock)" 2> /dev/null   # (app_perms comes with meta_group_ok's lines)
  tr '\n' ';' < "$T/calls"
}
check "U13a the metadata group's id is picked under the uid lock" eval 'ap | grep -q "^flock -w 120 14;groupadd "'
check "U13b configure picks the app user's id under the uid lock" eval \
  'sed -n "/^cmd_configure() {/,/^}/p" "$ROOT/server/tando-agent" | grep -q "uid_lock; nu=\$(new_uid)"'
check "U13c a new app's configure gives back the staged lock with the ports lock, not at its end" eval \
  'sed -n "/^cmd_configure() {/,/^}/p" "$ROOT/server/tando-agent" | grep -q "flock -u 8; exec 3>&-"'

# ---- U14 unit_boot: an app's unit is enabled (started at boot) only while a release is live, so
# a first deploy that failed leaves no unit that fails at every boot; an app that has none is
# disabled (recover does it for those left by an older tando). Never for a stopped, idle (its
# socket starts it) or static app. (systemctl: a stub; /etc is moved into $T; ${C[k]} and ${S[k]}
# become ${C_k} and ${S_k}: this runs under bash 3.2, which has no associative arrays)
na() { sed -e 's/\${\([CS]\)\[\([a-z_]*\)\]/${\1_\2/g' -e "s#/etc/#$T/etc/#g"; }
ub() { # current stopped recipe idle_stop wants(0|1|2: the wake socket) -> the systemctl calls
  rm -rf "${T:?}/etc"; mkdir -p "$T/etc/systemd/system/multi-user.target.wants"; : > "$T/calls"
  : > "$T/etc/systemd/system/tando-a1.service"
  [ "$5" = 1 ] && : > "$T/etc/systemd/system/multi-user.target.wants/tando-a1.service"
  [ "$5" = 2 ] && mkdir -p "$T/etc/systemd/system/sockets.target.wants" && : > "$T/etc/systemd/system/sockets.target.wants/tando-a1_wake.socket"
  # shellcheck disable=SC2016
  R=$T "$BASH" -c 'eval "$1"; systemctl() { echo "${SYSTEMCTL_INSTALL_CLIENT_SIDE:+client }$*" >> "$R/calls"; }; A=a1
    S_current=$2 S_stopped=$3 C_recipe=$4 C_idle_stop=$5; unit_boot' _ \
    "$(agent_fn unit_boot unit_enable has_unit | na)" "$1" "$2" "$3" "$4"   # (idle_app comes with has_unit's lines)
  tr '\n' ';' < "$T/calls"
}
# (the link made by systemctl itself, with no daemon-reload: through PID 1, an enable reloaded
# systemd, and a new app is created and deployed with none: e2e-idle I20)
check "U14a no release live, enabled: disabled" eq "$(ub "" "" node "" 1)" "client disable -q --no-reload tando-a1;"
check "U14b a release live, not enabled: enabled" eq "$(ub r1 "" node "" 0)" "client enable -q --no-reload tando-a1;"
check "U14c a release live, enabled: nothing" eq "$(ub r1 "" node "" 1)" ""
check "U14d no release, not enabled: nothing" eq "$(ub "" "" node "" 0)" ""
check "U14e a stopped app is not enabled" eq "$(ub r1 1 node "" 0)" ""
# (an idle app: enabling its unit enables its wake socket (Also=), whose link is looked at; a new
# idle app's socket was left not enabled, and did not come back at boot: e2e-idle I2)
check "U14f an idle app with a release: enabled (its wake socket, through Also=)" eq "$(ub r1 "" node 6h 0)" "client enable -q --no-reload tando-a1;"
check "U14j an idle app whose wake socket is enabled: nothing (not the multi-user link)" eq "$(ub r1 "" node 6h 2)" ""
check "U14g a static app has no unit" eq "$(ub "" "" static "" 1)" ""
check "U14h configure enables the unit only with a live release, and never for a new app" eval \
  'sed -n "/^cmd_configure() {/,/^}/p" "$ROOT/server/tando-agent" | grep -q "^  cfg_reload \"\$new\"" &&
   ! sed -n "/^cmd_configure() {/,/^}/p" "$ROOT/server/tando-agent" | grep -q "systemctl enable" &&
   sed -n "/^cfg_reload() {/,/^}/p" "$ROOT/server/tando-agent" | grep "enable" | grep -v "^ *#" | grep -c . | grep -qx 1 &&
   sed -n "/^cfg_reload() {/,/^}/p" "$ROOT/server/tando-agent" | grep "unit_enable enable" | grep -q "S\[current\]"'
check "U14i a verified operation's trailer runs unit_boot, and so does recover for an app with no release" eval \
  'sed -n "/^op_trailer() {/,/^}/p" "$ROOT/server/tando-agent" | grep -q "^  unit_boot" &&
   sed -n "/^rec_service() {/,/^}/p" "$ROOT/server/tando-agent" | grep -q "S\[current\]:-} \]\] || { unit_boot"'

# ---- U15 restarts_keep: an app systemd gave up on (down) that tando starts again loses its
# NRestarts (systemd begins again at 0), and tando-watch saw neither the crash loop nor its
# restarts. Its count plus that start is kept in the state's restarts_lost, added up over loops.
# (systemctl: a stub answering NRestarts; st: prints what it would save)
rk() { # NRestarts restarts_lost -> what st saves
  # shellcheck disable=SC2016
  "$BASH" -c 'eval "$1"; systemctl() { echo "$NR"; }; st() { echo "$*"; }; A=a1
    S_restarts_lost=$3; NR=$2 restarts_keep' _ "$(agent_fn restarts_keep | na)" "$1" "$2"
}
check "U15a the restarts of the loop plus the start are kept" eq "$(rk 4 "")" "restarts_lost 5"
check "U15b ... added to those kept before" eq "$(rk 4 2)" "restarts_lost 7"
check "U15c an unreadable count keeps the start" eq "$(rk "" 2)" "restarts_lost 3"
check "U15d restart_app keeps them for a down app and clears them on any other restart" eval \
  'sed -n "/^restart_app() {/,/^}/p" "$ROOT/server/tando-agent" | grep -q "then restarts_keep" &&
   sed -n "/^restart_app() {/,/^}/p" "$ROOT/server/tando-agent" | grep -c "st restarts_lost \"\"" | grep -qx 2'

# ---- U16 agent (lib/common.sh): a failed agent call ends the command with a message and the box
# closed where the user sees it, also when the call's stdout is a file (configure's): under
# parallel deploys, configure failed with nothing on stderr and the deploy ended with no word.
# (agent_raw: a stub that fails; its stderr file empty, or with the server's line)
ag() { # [server-line] -> what reached stdout|what reached stderr
  rm -rf "${T:?}/ag"; mkdir -p "$T/ag"
  [ -z "${1:-}" ] || echo "$1" > "$T/ag/err"
  # shellcheck disable=SC2016
  TMPD=$T/ag "$BASH" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; agent_raw() { return 1; }
    TANDO_COLOR=never ui_init 60; HOST=h; ui_box_open "deploy a" h > /dev/null; agent sudo configure a > "$TMPD/cfg"' _ "$ROOT" 2> "$T/ag/stderr"
  printf '%s|%s' "$(tr -d '\n' < "$T/ag/cfg")" "$(tr '\n' ' ' < "$T/ag/stderr")"
}
check "U16a an agent that failed silently is named, and the box closes on stderr, not into the call's file" \
  eval 'ag | grep -q "^|tando: the server ended .configure. with status 1 and gave no reason.*╰"'
check "U16b the server's own reason: no second message" eval 'ag "x" | grep -q "^|╰" '

# ---- U17 upload: an rsync whose ssh session the server turned away (sshd MaxSessions on a shared
# connection, parallel deploys) sent nothing and is tried again, not reported as a failed upload.
# (rsync: a stub refused N times; agent_raw, ssh_wrapper, sleep: stubs)
up1() { # refusals -> the number of rsync runs and upload's status
  rm -rf "${T:?}/up"; mkdir -p "$T/up/stage"
  # shellcheck disable=SC2016
  TMPD=$T/up "$BASH" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; . "$1/lib/deploy.sh"
    agent_raw() { echo token=abc; }; ssh_wrapper() { :; }; sleep() { :; }; phase_line() { :; }; box_say() { :; }
    rsync() { echo x >> "$TMPD/runs"; [ "$(wc -l < "$TMPD/runs")" -gt "$N" ] && return 0
      echo "mux_client_request_session: session request failed: Session open refused by peer"; return 255; }
    APP=a HOST=h TARGET=u@h STAGE=$TMPD/stage N=$2; (upload) > /dev/null 2>&1; rc=$?; echo "$(wc -l < "$TMPD/runs" | tr -d " ") $rc"' _ "$ROOT" "$1"
}
check "U17a a refused session: rsync is run again and the upload goes on" eq "$(up1 2)" "3 0"
check "U17b refused every time: it gives up after 6 runs" eq "$(up1 99)" "6 1"

# ---- U18 profiles (host setup profile.<name>=...; profile = <name>): the spec's keys and values,
# then what a profile makes of an app's settings: ceilings refuse ("bad"), the mandatory limits it
# does not set come from the profile ("set"); workers, worker memory, job timeouts, mail
ps_ok() { "$BASH" -c 'eval "$1"; if profile_spec_ok "$2"; then echo ok; else echo "$PROF_WHY"; fi' _ "$(agent_fn profile_spec_ok)" "$1"; }
check "U18a a full spec is valid" eq "$(ps_ok 'memory=256M,cpu=25%,tasks=256,workers=0,job_timeout=600,job_every=15m,mail_out=off')" ok
check "U18b cores for cpu" eq "$(ps_ok 'cpu=0.5')" ok
check "U18c an unknown key is refused" eval 'ps_ok "memory=256M,disk=1G" | grep -q "unknown key disk"'
check "U18d a bad value is refused" eval 'ps_ok "cpu=0" | grep -q "^cpu=0"'
check "U18e an empty value is refused" eval 'ps_ok "memory=" | grep -q "not key=value"'
check "U18f workers over 20 are refused" eval 'ps_ok "workers=21" | grep -q "0 to 20"'
pc() { # spec settings... -> profile_check's lines, sorted, joined by |
  local sp=$1; shift
  printf '%s\n' "$@" | "$BASH" -c 'eval "$1"; profile_check "$2"' _ "$(agent_fn profile_check)" "$sp" | sort | tr '\n' '|'
}
P='memory=256M,cpu=25%,tasks=256,workers=1,job_timeout=600,mail_out=off'
check "U18g unset limits come from the profile" eq "$(pc "$P" memory=128M)" "set cpu=25%|set job_timeout=600|set mail_out=off|set tasks=256|"
check "U18g2 no memory set: the profile's" eq "$(pc "$P" cpu=25%)" "set job_timeout=600|set mail_out=off|set memory=256M|set tasks=256|"
check "U18h settings within it pass as they are" eq "$(pc "$P" memory=256M cpu=0.2 tasks=100 job_timeout=60 mail_out=off)" ""
check "U18i over a ceiling is refused, each named" eq "$(pc "$P" memory=1G cpu=0.5 tasks=512 job_timeout=601 mail_out=on)" \
  "bad cpu = 0.5 is over 25%|bad job_timeout = 601 is over 600|bad mail_out = on: the profile has no outbound mail|bad memory = 1G is over 256M|bad tasks = 512 is over 256|"
check "U18j workers over the count, a worker's memory, a job's own timeout" eq \
  "$(pc "$P" cpu=25% tasks=256 job_timeout=60 mail_out=off 'worker.a=node a.js' 'worker.b=node b.js' worker.a.memory=512M 'job.x=daily|true' job.x.timeout=900)" \
  "bad 2 workers, the profile allows 1|bad job.x.timeout = 900 is over 600|bad worker.a.memory = 512M is over 256M|set memory=256M|"
check "U18k a profile without a key leaves it alone" eq "$(pc 'workers=0' memory=4G cpu=400%)" ""
# a rollback cannot raise memory past the profile: units take mem_cap
mcap() { "$BASH" -c 'eval "$1"; R=/nonexistent; C_memory=$2 C_profile=p H_spec=$3; prof_get() { local s=",$H_spec,"; [[ $s == *",$1="* ]] || return 1; s=${s#*",$1="}; echo "${s%%,*}"; }; mem_cap' _ \
  "$(agent_fn mem_cap size_mb | sed 's/\${C\[memory\]:-/${C_memory:-/')" "$@"; }
check "U18r mem_cap: over the profile, the profile's" eq "$(mcap 1G memory=256M)" 256M
check "U18s mem_cap: under it, the app's; no profile memory, the app's" eq "$(mcap 128M memory=256M)/$(mcap 1G cpu=10%)" "128M/1G"
# awake_auto: idle apps that fit, at their caps, beside the always-on apps' caps (RAM x mem_overcommit)
aa() { # MemTotal-kB app.conf-contents... -> awake_auto
  local m=$1 i=0 a; shift
  rm -rf "${T:?}/aa"; mkdir -p "$T/aa/apps"
  echo "MemTotal: $m kB" > "$T/aa/meminfo"
  for a; do i=$((i + 1)); mkdir -p "$T/aa/apps/a$i"; printf '%b' "$a" > "$T/aa/apps/a$i/app.conf"; done
  # shellcheck disable=SC2016
  R=$T/aa "$BASH" -c 'eval "$1"; MEM_OVERCOMMIT=1.5 IDLE_MB=2 IDLE_AWAKE=20; awake_auto' _ \
    "$(agent_fn mem_caps_mb awake_auto | sed "s#/proc/meminfo#$T/aa/meminfo#g")"
}
# 1000 MB x 1.5 = 1500; always-on 500; ten idle apps of 100 MB (2 MB each idle): (1500-500-20)/100 = 9
idle10=""; for i in 1 2 3 4 5 6 7 8 9 10; do idle10="$idle10 memory=100M\nidle_stop=10m\n"; done
check "U18l awake_auto from RAM and admission" eq "$(aa 1024000 'memory=500M\n' $idle10)" 9
check "U18m no idle app: no cap" eq "$(aa 1024000 'memory=500M\n')" 0
check "U18n at least 1 when nothing fits" eq "$(aa 102400 'memory=500M\n' 'memory=100M\nidle_stop=10m\n')" 1
# the governor's hooks: an idle app's unit counts its wake first; its site answers 503 while the
# governor says no (.full, <app>.cool), before it would start the app
check "U18o an idle app's unit asks wake-admit before it starts, and may be refused (ExecCondition, no -)" grep -q "ExecCondition=+%s wake-admit %s" "$ROOT/server/tando-agent"
check "U18p the site of an idle app answers 503 under the governor" eval 'grep -q "try_files .full \$A.cool" "$ROOT/server/tando-agent"'
check "U18t a wake whose count cannot be taken (lock timeout) is refused, never admitted unchecked" eval 'sed -n "/^cmd_wake_admit() {/,/^}/p" "$ROOT/server/tando-agent" | grep -q "awake_lock || {.*return 1; }"'
check "U18u a reload of nftables reloads tando's rules too" eval 'grep -q "^ReloadPropagatedFrom=nftables.service" "$ROOT/server/tando-agent" && grep -q "^ExecReload=-\$AGENT fw-sync" "$ROOT/server/tando-agent"'
check "U18q a stop of an idle app leaves the governor's count" eval 'sed -n "/^cmd_idle_stopped() {/,/^}/p" "$ROOT/server/tando-agent" | grep -q awake_gone'

echo "core-unit: $n checks, $nf failed"
[ "$nf" = 0 ]
