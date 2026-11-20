#!/bin/bash
# test/e2e-upgrade.sh: a server set up and deployed to by tando 0.1.1 (the last release), then
# `tando host setup` with this tree, then every app used with this client.
#   U1  0.1.1 sets up the host (postgres) and deploys: a node app with two releases, one with a
#       database, one with a job, a static site, a stopped one, one whose last deploy failed
#   U2  this client against the 0.1.1 server: refuses before anything changes, says what to run
#   U3  host setup with this tree: every app serves the same version during and after (no
#       request fails), the stopped one stays stopped, no app restarted, doctor, ls, status
#   U4  this client on each app: deploy (new state files), rollback to a 0.1.1 release (its
#       snapshot lacks the new keys), env set, stop/start, jobs, backup and restore
#   U5  a deploy by the 0.1.1 agent stopped in its pre-flight, the new agent installed, then the
#       activation killed: the new agent's recovery leaves a coherent app (the matrix's checker)
#   U6  the 0.1.1 client against the new server
# The old client is `git archive` of TANDO_UPGRADE_FROM (default v0.1.1) from this checkout.
# Usage: test/e2e-upgrade.sh   (server: TANDO_TEST_NAME, TANDO_TEST_SSH_PORT, TANDO_TEST_HTTP_PORT)
# bash 3.2 compatible.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-upgrade
srv() { "$SSH" "$@" < /dev/null; }
FROM=${TANDO_UPGRADE_FROM:-v0.1.1}
O=$E/old; mkdir -p "$O"
git -C "$ROOT" archive "$FROM" | tar -x -C "$O" || { echo "FAIL U0 cannot extract $FROM from git"; exit 1; }
RO=$O/bin/tando
t_server_up --reset || exit 1
t_host_add test
W=$E/w; mkdir -p "$W"
HP=$T_HTTP_PORT AP=/opt/tando/apps
export TANDO_WAIT=1

# app <name> <version> [extra tando.conf lines...]: the work dir of a hello app at that version
app() {
  local a=$1 v=$2 l; shift 2
  mkdir -p "$W/$a"; cp "$ROOT/examples/hello/server.js" "$W/$a/"; echo "$v" > "$W/$a/VERSION"
  { printf 'app = %s\nrecipe = node\nstart = node server.js\nhealth = /health\nmemory = 128M\nhealth_timeout = 15\n' "$a"
    for l in "$@"; do printf '%s\n' "$l"; done; } > "$W/$a/tando.conf"
}
site() { mkdir -p "$W/usite/public"; echo "site v$1" > "$W/usite/public/index.html"
  printf 'app = usite\nrecipe = static\nout = public\nmemory = 64M\n' > "$W/usite/tando.conf"; }
# old/new <app> <out> <args...>: the 0.1.1 client or this one, in the app's work dir; rc in RC
old() { local a=$1 o=$2; shift 2; [ "$1" = deploy ] && set -- up; (cd "$W/$a" && "$RO" "$@" < /dev/null > "$E/$o" 2>&1); RC=$?; cat "$E/$o" >&2; }
new() { local a=$1 o=$2; shift 2; (cd "$W/$a" && "$R" "$@" < /dev/null > "$E/$o" 2>&1); RC=$?; cat "$E/$o" >&2; }
served() { curl -s -m 10 "$(t_url "$1")" | head -c 120 | tr -d '\r\n'; }
code() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$(t_url "$1")"; }
mpid() { srv "systemctl show -P MainPID tando-$1.service"; }
st() { srv "sudo sed -n 's/^$2=//p' $AP/$1/state" | head -1; }
conf_of() { srv "sudo cat $AP/$1/app.conf" | grep -E "^($2)=" | sort; }
# dserved <domain>: what the server answers for one of an app's own domains (domain_tls=off)
dserved() { curl -s -m 10 --connect-to "$1:80:127.0.0.1:$HP" "http://$1/" | head -c 120 | tr -d '\r\n'; }
# dbset <app>: the database role's settings (its limits), sorted
dbset() { srv "sudo -u postgres psql -X -At -c \"select c from pg_roles, unnest(rolconfig) c where rolname = 'tando_$1'\"" | sort | tr '\n' ' ' | sed 's/ $//'; }
NODE="ua udb ujob ufail"
# the fault matrix's app and checker (U5): ukill, kind node, without assets (0.1.1 has none)
. "$ROOT/test/faults/lib-matrix.sh"
A=ukill KIND=node
# (every version with the same settings: 0.1.1 records only start and health per release, so a
# rollback to one of its releases cannot know its memory or max_conns)
MX_SAMECONF=1
mx_has_assets() { return 1; }
kv_ver() { mx_version "$@"; sed -i.bak '/^assets = /d' "$W/$A/tando.conf"; }
# (TANDO_TEST_RESOLVE: 0.1.1's client adds the domain of tando.conf only when its DNS is right)
kold() { kv_ver "$1" "${2:-ok}"; TANDO_TEST_RESOLVE=mx.test=127.0.0.1 old ukill "k$1.out" deploy; mx_note_id "$(mx_rid "$E/k$1.out")" "$1"; }

# ---- U1. 0.1.1 sets up the host and deploys ---------------------------------------------------
"$RO" host setup test public_port="$HP" postgres=yes domain_tls=off > "$E/setup-old.out" 2>&1; rc=$?; cat "$E/setup-old.out" >&2
check "U1a 0.1.1 host setup with postgres (rc=$rc)" t_eq "$rc" 0
app ua 1; old ua ua1.out deploy; r1=$RC
app ua 2; old ua ua2.out deploy; r2=$RC
check "U1b 0.1.1: ua deployed twice (rc=$r1/$r2), serves v2" t_eq "$(served ua)" "hello v2 greeting="
app udb 1 'database = postgres' 'domain = udb.test' 'www = off'; TANDO_TEST_RESOLVE=udb.test=127.0.0.1 old udb udb1.out deploy
check "U1c 0.1.1: udb with a database and a domain (rc=$RC)" eval \
  '[ "$(served udb)" = "hello v1 greeting=" ] && [ "$(conf_of udb domains)" = "domains=udb.test|off" ]'
app ujob 1 'job.tick = *:0/10 | true'; old ujob ujob1.out deploy
check "U1d 0.1.1: ujob with a job (rc=$RC), its timer is there" eval \
  '[ "$(served ujob)" = "hello v1 greeting=" ] && srv "test -e /etc/systemd/system/tando-ujob-job-tick.timer"'
site 1; old usite usite1.out deploy
check "U1e 0.1.1: a static site (rc=$RC)" t_eq "$(served usite)" "site v1"
app ustop 1; old ustop ustop1.out deploy; old ustop ustop-stop.out stop
check "U1f 0.1.1: ustop deployed and stopped (rc=$RC, $(code ustop))" eval '[ "$(code ustop)" = 503 ] && [ -n "$(st ustop stopped)" ]'
app ufail 1; old ufail ufail1.out deploy
app ufail 2; sed -i.bak 's/^start = .*/start = node missing.js/' "$W/ufail/tando.conf"; old ufail ufail2.out deploy
check "U1g 0.1.1: ufail's second deploy failed (rc=$RC) and v1 serves" eval \
  '[ "$RC" != 0 ] && [ "$(served ufail)" = "hello v1 greeting=" ]'
sed -i.bak 's/^start = .*/start = node server.js/' "$W/ufail/tando.conf"
kold 1; kold 2
check "U1h 0.1.1: ukill (the matrix's app) deployed twice, v2 serves" t_eq "$(served ukill)" "v2 env=-"
for a in $NODE ustop; do eval "CONF0_$a=\$(conf_of $a 'start|health|memory|health_timeout|port')"; done

# ---- U2. this client against the 0.1.1 server: stops before it changes anything ----------------
snap() { srv "sudo bash -c 'cd $AP && ls -R ua usite | md5sum; cat ua/state usite/state | md5sum'"; }
# shellcheck disable=SC2034 # (read in the eval of U2b)
s0=$(snap)
app ua 3; new ua mixed-deploy.out deploy
check "U2a this client's deploy to a 0.1.1 server refuses: it says to run host setup (rc=$RC)" eval \
  '[ "$RC" != 0 ] && grep -q "the server.s tando is older than this client: run tando host setup test" "$E/mixed-deploy.out"'
site 2; new usite mixed-site.out deploy
check "U2b and a static site's deploy too (rc=$RC); nothing changed on the server, v2 and site v1 serve" eval \
  '[ "$RC" != 0 ] && [ "$(snap)" = "$s0" ] && [ "$(served ua)" = "hello v2 greeting=" ] && [ "$(served usite)" = "site v1" ]'

# ---- U5 (first half). 0.1.1's agent activates ukill v3, which stays in its pre-flight ------------
mx_facts; MX_OLD=$(fv s_current) MX_H0=$(fv hist_n) MX_DATA0=$(fv data_sum) MX_DB0=$(fv db_rows)
kv_ver 3 slow@pre; sed -i.bak 's/^health_timeout = .*/health_timeout = 120/' "$W/ukill/tando.conf"
(cd "$W/ukill" && "$RO" up < /dev/null > "$E/k3.out" 2>&1) & KPID=$!
inpre() { [ "$(st ukill phase)" = preflight ]; }
check "U5a 0.1.1's activation of v3 is in its pre-flight" t_until 90 inpre
# (frozen: from here it does nothing, as if killed; its unit's ExecStopPost runs when it ends)
dxs "systemctl kill -s STOP 'tando-ukill-act-*'"
MX_NEW=$(srv "sudo ls $AP/ukill/releases" | tail -1); mx_note_id "$MX_NEW" 3

# ---- U3. host setup with this tree -----------------------------------------------------------
for a in $NODE; do eval "PID0_$a=\$(mpid $a)"; done
for a in ua udb ujob usite ufail; do t_loop_start "$a" "$(t_url "$a")" 0.2; done
# (setup installs the programs first, then updates every app under its lock: it waits for ukill's
# activation; that is killed there, so its unit's ExecStopPost runs the new agent's recover)
"$R" host setup test public_port="$HP" > "$E/setup-new.out" 2>&1 & SPID=$!
waitlock() { srv "sudo sh -c 'ls $AP/ukill/lock.wait.* > /dev/null 2>&1'"; }
check "U5b host setup installs the new agent, then waits for ukill's 0.1.1 activation" t_until 240 waitlock
dxs "systemctl kill -s KILL 'tando-ukill-act-*'"
wait "$SPID"; rc=$?; cat "$E/setup-new.out" >&2
check "U3a host setup with this tree over 0.1.1 (rc=$rc)" t_eq "$rc" 0
bad=""
for a in ua udb ujob usite ufail; do
  t_loop_stop "$a"; [ "$T_LOOP_BAD" = 0 ] && [ "$T_LOOP_N" -gt 5 ] || bad="$bad $a:$T_LOOP_BAD/$T_LOOP_N"
done
check "U3b no request failed during the setup, on any app:${bad:- none}" test -z "$bad"
check "U3c every app serves the version it served before" eval \
  '[ "$(served ua)" = "hello v2 greeting=" ] && [ "$(served udb)" = "hello v1 greeting=" ] &&
   [ "$(served ujob)" = "hello v1 greeting=" ] && [ "$(served ufail)" = "hello v1 greeting=" ] && [ "$(served usite)" = "site v1" ]'
check "U3d the stopped app stays stopped ($(code ustop), unit $(srv 'systemctl is-active tando-ustop.service'))" eval \
  '[ "$(code ustop)" = 503 ] && [ "$(srv "systemctl is-active tando-ustop.service")" != active ]'
bad=""; for a in $NODE; do eval "p0=\$PID0_$a"; [ "$(mpid "$a")" = "$p0" ] || bad="$bad $a"; done
check "U3e no app was restarted by the setup (main PID unchanged):${bad:- all same}" test -z "$bad"
# ---- U5 (second half): the new agent recovered the killed activation -----------------
wait "$KPID" 2> /dev/null
mx_wait_settled 120; mx_watcher; mx_wait_settled 60
MX_OP=deploy MX_WANT=any MX_RUN=running MX_ENVW="" MX_LOOPOK=0
check "U5c after the kill, the new agent's recovery leaves ukill coherent (the matrix's invariants)" mx_inv
(cd "$W/ukill" && kv_ver 4 && "$R" deploy < /dev/null > "$E/k4.out" 2>&1); rc=$?; cat "$E/k4.out" >&2
check "U5d and the next deploy of ukill works (rc=$rc)" t_eq "$(served ukill)" "v4 env=-"
"$R" doctor > "$E/doctor.out" 2>&1; rc=$?; cat "$E/doctor.out" >&2
check "U3f tando doctor after the upgrade: nothing failed (rc=$rc)" eval '[ "$rc" = 0 ] && grep -q "0 failed" "$E/doctor.out"'
check "U3f2 and no warning about an app (the stopped one is stopped on purpose)" eval '! grep -E "│ app " "$E/doctor.out" | grep -q warn'
COLUMNS=200 "$R" ls > "$E/ls.out" 2>&1; cat "$E/ls.out" >&2
lsrow() { grep -E "^[│ ]+$1 " "$E/ls.out"; }
bad=""; for a in ua udb ujob usite ufail ukill; do lsrow "$a" | grep -qE 'running|static' || bad="$bad $a"; done
lsrow ustop | grep -q stopped || bad="$bad ustop"
check "U3g tando ls lists every app, ustop as stopped and only it:${bad:- ok}" test -z "$bad"
bad=""
for a in ua udb ujob usite ufail ustop; do
  new "$a" "status-$a.out" status || :
  [ "$RC" = 0 ] || bad="$bad $a:rc$RC"
  grep -qi 'unknown\|error\|no such' "$E/status-$a.out" && bad="$bad $a:text"
done
grep -qi stopped "$E/status-ustop.out" || bad="$bad ustop:notstopped"
check "U3h tando status works for every app:${bad:- ok}" test -z "$bad"
(cd "$W/ujob" && "$R" jobs > "$E/jobs0.out" 2>&1); cat "$E/jobs0.out" >&2
check "U3i tando jobs shows 0.1.1's job before the next deploy" grep -q tick "$E/jobs0.out"

# ---- U4. this client on every app --------------------------------------------------------------
app ua 3; new ua ua3.out deploy
# shellcheck disable=SC2034 # (read in the eval of U4a)
ua3=$(st ua current)
check "U4a deploy of ua with this client (rc=$RC): v3 serves, its settings are staged (confs/, start/)" eval \
  '[ "$RC" = 0 ] && [ "$(served ua)" = "hello v3 greeting=" ] && srv "sudo test -s $AP/ua/start/$ua3"'
new ua ua-rb.out rollback
check "U4b rollback to v2, deployed by 0.1.1 (rc=$RC): v2 serves" t_eq "$(served ua)" "hello v2 greeting="
check "U4c and app.conf has v2's settings, none blank" t_eq "$(conf_of ua 'start|health|memory|health_timeout|port' | grep -v '^port=')" \
  "$(echo "$CONF0_ua" | grep -v '^port=')"
new ua ua-env.out env set GREETING=hi
check "U4d env set (rc=$RC)" t_eq "$(served ua)" "hello v2 greeting=hi"
new ustop ustop-start.out start
check "U4e start of 0.1.1's stopped app (rc=$RC)" t_eq "$(served ustop)" "hello v1 greeting="
new ustop ustop-stop2.out stop
check "U4f and stop again (rc=$RC)" t_eq "$(code ustop)" 503
app ujob 2 'job.tick = *:0/10 | true'; new ujob ujob2.out deploy
(cd "$W/ujob" && "$R" jobs > "$E/jobs1.out" 2>&1); cat "$E/jobs1.out" >&2
check "U4g deploy of the app with 0.1.1's job (rc=$RC): v2, the job listed, its 0.1.1 units replaced by the new ones" eval \
  '[ "$RC" = 0 ] && [ "$(served ujob)" = "hello v2 greeting=" ] && grep -q tick "$E/jobs1.out" &&
   srv "test -e /etc/systemd/system/tando-ujob_job-tick.timer && ! test -e /etc/systemd/system/tando-ujob-job-tick.timer &&
        systemctl is-active -q tando-ujob_job-tick.timer && grep -q job-begin /etc/systemd/system/tando-ujob_job-tick.service"'
new ujob ujob-run.out jobs run tick
check "U4h the job runs after the deploy (rc=$RC)" t_eq "$RC" 0
new udb udb-bk.out backup now; bk=$(sed -n 's/^backed up [a-z0-9-]*: \([^ ]*\).*/\1/p' "$E/udb-bk.out" | head -1)
check "U4i backup now of 0.1.1's database app (rc=$RC): $bk" eval '[ "$RC" = 0 ] && [ -n "$bk" ]'
new udb udb-rs.out backup restore "$bk" --yes
check "U4j restore it (rc=$RC), the app serves" eval '[ "$RC" = 0 ] && [ "$(served udb)" = "hello v1 greeting=" ]'
# a rollback to 0.1.1's release (its record has no domains, no role limits): the app keeps both
app udb 2 'database = postgres' 'domain = udb.test' 'www = off' 'db_statement_timeout = 30s'; new udb udb2.out deploy
lim0=$(dbset udb)
check "U4j2 deploy of udb with this client (rc=$RC): v2, its role limit set ($lim0)" eval \
  '[ "$RC" = 0 ] && [ "$(served udb)" = "hello v2 greeting=" ] && case " $lim0 " in *" statement_timeout=30s "*) true;; *) false;; esac'
new udb udb-rb.out rollback
check "U4j3 rollback of udb to 0.1.1's v1 (rc=$RC): v1 serves" t_eq "$(served udb)" "hello v1 greeting="
check "U4j4 and udb keeps its domain: app.conf ($(conf_of udb domains)), Caddy answers for udb.test ($(dserved udb.test))" eval \
  '[ "$(conf_of udb domains)" = "domains=udb.test|off" ] && [ "$(dserved udb.test)" = "hello v1 greeting=" ]'
check "U4j5 and its role limits are unchanged ($(dbset udb))" t_eq "$(dbset udb)" "$lim0"
app ufail 3; new ufail ufail3.out deploy
check "U4k deploy of the app whose 0.1.1 deploy failed (rc=$RC)" t_eq "$(served ufail)" "hello v3 greeting="
site 3; new usite usite3.out deploy
check "U4l deploy of the static site (rc=$RC)" t_eq "$(served usite)" "site v3"
new usite usite-rb.out rollback
check "U4m rollback of the static site to 0.1.1's release (rc=$RC)" t_eq "$(served usite)" "site v1"

# ---- U6. the 0.1.1 client against the new server ------------------------------------------------
app ua 4; old ua old-on-new.out deploy
check "U6a the 0.1.1 client deploys to the upgraded server (rc=$RC), or refuses before a change" eval \
  '{ [ "$RC" = 0 ] && [ "$(served ua)" = "hello v4 greeting=hi" ]; } ||
   { [ "$RC" != 0 ] && [ "$(served ua)" = "hello v2 greeting=hi" ] && grep -q "host setup" "$E/old-on-new.out"; }'
old ua old-ls.out ls
check "U6b the 0.1.1 client lists the apps (rc=$RC)" eval '[ "$RC" = 0 ] && grep -q ukill "$E/old-ls.out"'

t_done
