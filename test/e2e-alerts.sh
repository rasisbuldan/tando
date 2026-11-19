#!/bin/bash
# End-to-end test of tando alerts (server/tando-watch, lib/cmd-alerts.sh) against a clean test
# container. One PASS/FAIL line per check; exits non-zero on any failure. Takes about 10 minutes
# (three of them the two quiet periods it waits out, sections 9 and 10; section 31 installs
# PostgreSQL from the network).
#
# This is the bulk: every check, notifier, setting and verb, with the check runs started by hand
# (one run stands for a minute). Two parts that need a server of their own run beside it:
#   test/e2e-alerts-timer.sh    the real once-a-minute timer and a restart of the host (21, 22)
#   test/e2e-alerts-daemon.sh   tandod killed, stopped, panicking, an upgrade (29, 27h, 27i)
# The helpers and fixtures of all three are in test/alerts-lib.sh (the environment variables too).
#
# Usage: test/e2e-alerts.sh [--no-reset]
#   server by default: tando-test-alerts, ssh 2303, http 8303
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
. "$ROOT/test/alerts-lib.sh"
alerts_server tando-test-alerts 2303 8303 0
t_init e2e-alerts
alerts_setup "$@"

# ---- 1. setup installs the timer; apps; notifiers (secrets on stdin): done by alerts_setup ----
check "1a host setup + alerts enable: tando-watch.timer enabled and active" \
  test "$(srv 'systemctl is-enabled tando-watch.timer; systemctl is-active tando-watch.timer' | tr '\n' ' ')" = "enabled active "
check "1c no notifier yet: tando alerts says the checks run and gives one line per notifier type, ntfy first" \
  sh -c "grep -q 'already watching every app' '$E/alerts-empty.out' &&
    grep -n 'notifier add' '$E/alerts-empty.out' | head -1 | grep -q 'phone ntfy'"
check "1b five notifier types and a heartbeat added (secrets on stdin)" test "$(grep -c '^added notifier' "$E/notifiers.out")" = 6

# ---- 2. alerts test: per-notifier result; a failing one does not stop the others ----
"$R" alerts test > "$E/test.out" 2>&1
cat "$E/test.out" >&2
check "2a alerts test: 5 delivered, broken reported failed with its HTTP status" \
  grep -q '5 delivered, 1 failed' "$E/test.out"
check "2b alerts test: broken shows HTTP 500" grep -q 'broken .*failed.*HTTP 500' "$E/test.out"
check "2d alerts test: shows what was sent and each receiver's answer (HTTP 200)" \
  sh -c "grep -q 'sent .*tando .*test' '$E/test.out' && grep -q 'hook .*delivered.*HTTP 200' '$E/test.out'"
check "2c email went through the local sendmail" srv 'sudo sh -c "grep -q ^To:.ops@example.com /var/lib/testmail/mail.*"'

# test settings: shorter windows so the suite finishes; production defaults are in docs/MONITORING.md
srv 'sudo systemctl stop tando-watch.timer'
# load=off: in a container /proc/loadavg is the whole VM's (other containers' work, on 1 pinned CPU)
# sample_seconds=0: each run below stands for a minute (a run counts once a minute otherwise)
aset oom_quiet=1 restarts_window=2 deploy_grace=5 boot_grace=0 mem_for=3 heartbeat_every=1 load=off sample_seconds=0
wruns 2

# ---- 3. baseline: nothing fires on a healthy host ----
mark; wruns 3
check "3a healthy host (two node apps, one static app without a unit): no alerts, no notifications" eq "$(nmsg)" 0
check "3b the static app is watched, and Caddy serves it" srv "sudo grep -q '^site.nr=' /var/lib/tando/watch/state && curl -s -o /dev/null -w '%{http_code}' -H 'Host: site.localhost' http://127.0.0.1/ | grep -q 200"

# ---- 4. health: fires after 3 failed probes, one notification each way ----
mark
get hog /sick > /dev/null
wruns 2
check "4a health: 2 failed probes are only pending, no notification" eq "$(st hog.health.st)/$(nmsg)" pending/0
wrun
check "4b health: the 3rd failed probe fires, exactly one notification" eq "$(nev firing hog health)/$(nmsg)" 1/1
wruns 3
check "4c health: no repeat while it keeps failing" eq "$(nmsg)" 1
get hog /well > /dev/null
wruns 3
check "4d health: resolves with exactly one notification" eq "$(nev resolved hog health)/$(nmsg)" 1/2
"$R" alerts history > "$E/hist.out" 2>&1
check "4e tando alerts history lists the fired and the resolved alert" \
  eval 'grep -q "fired.*hog.*health" "$E/hist.out" && grep -q "resolved.*hog.*health" "$E/hist.out"'
for n in slack tg ntfy; do
  c=$(srv "sudo tail -n +$((MARK + 1)) /root/recv.log | grep -c '\"path\":\"/$n/'")
  check "4e notifier $n got the same 2 messages" eq "$c" 2
done
check "4f ntfy got a title and priority header path, token as Bearer" \
  srv "sudo tail -n +$((MARK + 1)) /root/recv.log | grep '\"path\":\"/ntfy/' | grep -q '\"auth\":\"Bearer <S>\"'"
check "4g email got both messages" test "$(srv 'sudo ls /var/lib/testmail | grep -c mail')" -ge 3

# ---- 5. one transient failure: no notification ----
mark
get hog /sick > /dev/null; wrun; get hog /well > /dev/null; wruns 3
check "5 a single failed health probe: no notification" eq "$(nmsg)" 0

# ---- 6. dead app (crash loop): "down" fires once, health/restarts stay quiet ----
# (crash_on, crash_off: test/alerts-lib.sh)
mark
crash_on hello
# down needs two samples of a unit that keeps failing: run checks until it fires (at most 60 s)
T_UNTIL_STEP=2 until_ 60 wrun_and seen firing hello down
check "6a crash loop: down fires once" eq "$(nev firing hello down)" 1
check "6b crash loop: no separate health or restarts alert" eq "$(nev firing hello health)$(nev firing hello restarts)" 00
crash_off hello
wruns 3
check "6c recovered: down resolves once" eq "$(nev resolved hello down)" 1
wruns 2
check "6d after recovery nothing else fires" eq "$(nmsg)" 2

# ---- 7. tando stop is not an outage ----
mark
(cd "$W/hello" && "$R" stop > /dev/null 2>&1); wruns 3
check "7a a stopped app (tando stop) raises no alert" eq "$(nmsg)/$(st hello.down.st | grep -c 'pending\|firing')" 0/0
(cd "$W/hello" && "$R" start > /dev/null 2>&1); wruns 2
check "7b started again: still nothing" eq "$(nmsg)" 0
(cd "$W/site" && "$R" stop > /dev/null 2>&1); wruns 4
check "7c a stopped static app (Caddy answers 503 stopped) raises no alert" eq "$(nmsg)" 0
(cd "$W/site" && "$R" start > /dev/null 2>&1); wruns 2
check "7d static app started again: still nothing" eq "$(nmsg)" 0

# ---- 8. memory above 90% of the cap, sustained (mem_for=3 here, 5 in production) ----
mark
# to about 89 MB of 96 with the app itself: above 90% of the cap, below it (no swap). What the app
# takes by itself differs by machine (about 14 MB on arm64, less on x86-64), so it is measured
base=$(srv "sudo awk '/^(anon|shmem) / { s += \$2 } END { print int(s / 1048576) }' /sys/fs/cgroup\$(systemctl show tando-hog -p ControlGroup --value)/memory.stat 2> /dev/null")
case $base in ""|*[!0-9]*) base=14;; esac
get hog "/grow?mb=$((89 - base))" > /dev/null
wruns 2
check "8a memory: 2 samples above the threshold are pending" eq "$(st hog.memory.st)/$(nmsg)" pending/0
[ "$(st hog.memory.st)" = pending ] || {   # what the server saw, for a failure on another machine
  echo "  8a: base=$base MB"; srv "systemctl show tando-hog -p MemoryMax -p MemoryCurrent -p MemorySwapMax -p ControlGroup | tr '\n' ' '; echo
    cg=/sys/fs/cgroup\$(systemctl show tando-hog -p ControlGroup --value); sudo grep -E '^(anon|shmem|file) ' \$cg/memory.stat | tr '\n' ' '; cat \$cg/memory.swap.current 2>&1; sudo grep hog /var/lib/tando/watch/state | tr '\n' ' '" 2>&1 | sed 's/^/  8a: /'; }
wrun
check "8b memory: the 3rd sample fires once" eq "$(nev firing hog memory)" 1
get hog /free > /dev/null; until_ 30 wrun_and seen resolved hog memory
check "8c memory: resolves once after the app frees it" eq "$(nev resolved hog memory)" 1

# ---- 9. OOM kill: the kill is recovered by systemd at once, the alert still fires ----
mark
srv 'sudo systemctl set-property --runtime tando-hog MemorySwapMax=0'   # the container has swap
n0=$(nrestarts hog)
get hog '/grow?mb=150' > /dev/null
until_ 30 restarted hog "$n0"   # the OOM kill happened and systemd brought hog back
wrun
check "9a OOM kill: fires once" eq "$(nev firing hog oom)" 1
check "9b OOM kill: detail names the kernel OOM killer" srv 'sudo grep -q "OOM killer" /var/lib/tando/watch/state'
srv 'sudo systemctl revert tando-hog > /dev/null 2>&1; sudo systemctl daemon-reload'
# (kept: the quiet period itself, a real minute without a new kill; runs are started meanwhile)
log "waiting for oom_quiet (1 min in this test, 30 in production)"
T_UNTIL_STEP=5 until_ 120 wrun_and seen resolved hog oom
check "9c OOM: resolves once after oom_quiet without new kills" eq "$(nev resolved hog oom)" 1
check "9d one OOM restart is not a restarts alert" eq "$(nev firing hog restarts)" 0

# ---- 10. restarts: 3 automatic restarts within the window ----
mark
for i in 1 2 3; do n0=$(nrestarts hog); get hog /exit > /dev/null; until_ 30 restarted hog "$n0"; wrun; done
check "10a 3 restarts within restarts_window: fires once" eq "$(nev firing hog restarts)" 1
check "10b ... and no down alert (the app is up between restarts)" eq "$(nev firing hog down)" 0
# (kept: the window itself, two real minutes; the alert must not resolve on a run started sooner)
log "waiting for the restart window to pass (2 min here, 15 in production)"
T_UNTIL_STEP=5 until_ 200 wrun_and seen resolved hog restarts
check "10c restarts: resolves once" eq "$(nev resolved hog restarts)" 1

# ---- 11. host checks, driven by thresholds (filling the disk or memory of a shared VM is not safe) ----
mark
aset disk_pct=1 inode_pct=1 load= load_pct=0 load_for=2 mem_avail_pct=100 host_for=2 swap_pct=0
wruns 2
HC="disk inodes load memory swap"
if srv 'df --output=ipcent / | tail -1' | grep -q -- -; then
  HC="disk load memory swap"; echo "SKIP 11 host inodes: this filesystem ($(srv 'df --output=fstype / | tail -1' | tr -d ' ')) reports no inode counts"
fi
# (a server without swap has nothing to judge: GitHub's runners come with and without)
[ "$(srv "awk '/^SwapTotal/ { print \$2 }' /proc/meminfo")" = 0 ] && { HC=${HC% swap}; echo "SKIP 11 host swap: this server has no swap"; }
for c in $HC; do
  check "11a host $c fires once when over its threshold" eq "$(nev firing host $c)" 1
done
aset disk_pct= inode_pct= load_pct= load_for= mem_avail_pct= host_for= swap_pct= load=off
wruns 2
for c in $HC; do
  check "11b host $c resolves once (load: by being turned off)" eq "$(nev resolved host $c)" 1
done
check "11c host transitions are batched: 2 messages fire (1 and 2 samples), 2 resolve (load: turned off)" eq "$(nmsg)" 4

# ---- 12. backup age (absent field tolerated; an old one fires; a new backup resolves) ----
mark
wruns 2
check "12a no last_backup yet on a new app: no alert" eq "$(nev firing hog backup)" 0
srv "sudo sed -i 's/^last_backup=.*//' /opt/tando/apps/hog/state; echo last_backup=\$((\$(date +%s) - 3 * 86400)) | sudo tee -a /opt/tando/apps/hog/state > /dev/null"
wrun
check "12b a 3-day-old backup fires once" eq "$(nev firing hog backup)" 1
(cd "$W/hog" && "$R" backup now > /dev/null 2>&1); wruns 2
check "12c tando backup now resolves it" eq "$(nev resolved hog backup)" 1

# ---- 13. deploys: silent while activating; a failed deploy (rolled back) raises nothing ----
mark
(cd "$W/hello" && "$R" env set SLOW_START=3 UNHEALTHY_VERSION=3@4100 > /dev/null 2>&1)
wruns 2; mark
echo 2 > "$W/hello/VERSION"
( while [ ! -f "$E/stop.loop" ]; do wrun; sleep 0.3; done ) &
LP=$!
(cd "$W/hello" && "$R" deploy > "$E/d2.out" 2>&1)
echo 3 > "$W/hello/VERSION"; (cd "$W/hello" && "$R" deploy > "$E/d3.out" 2>&1)
# (kept: the runs go on until deploy_grace, 5 s here, is over after the rollback: quiet then too)
sleep 6; touch "$E/stop.loop"; wait $LP; rm -f "$E/stop.loop"
(cd "$W/hello" && "$R" env unset SLOW_START UNHEALTHY_VERSION > /dev/null 2>&1)
wruns 3
check "13a deploy + failed deploy with rollback, checks running throughout: no notification" eq "$(nmsg)" 0
check "13b (the failed deploy did roll back)" grep -q 'rolled back\|rolledback\|rolled-back' "$E/d3.out"

# ---- 14. activation stuck (stuck_min=0 here so a 6-second pre-flight counts) ----
mark
aset stuck_min=0 deploy_grace=0
echo 4 > "$W/hello/VERSION"
(cd "$W/hello" && "$R" env set SLOW_START=6 > /dev/null 2>&1)
(cd "$W/hello" && "$R" deploy > "$E/d4.out" 2>&1) &
DP=$!
until_ 20 srv 'sudo grep -q "^phase=preflight" /opt/tando/apps/hello/state'
until_ 5 wrun_and seen firing hello stuck   # SLOW_START=6: the pre-flight lasts long enough
check "14a an activation running longer than stuck_min fires once" eq "$(nev firing hello stuck)" 1
wait $DP; wruns 2
check "14b the activation finished: stuck resolves once" eq "$(nev resolved hello stuck)" 1
aset stuck_min= deploy_grace=5
(cd "$W/hello" && "$R" env unset SLOW_START > /dev/null 2>&1); wruns 2

# ---- 15. silence ----
mark
"$R" alerts silence hog 10m > /dev/null 2>&1
get hog /sick > /dev/null; wruns 3
check "15a silenced: the check fires but nothing is sent" eq "$(st hog.health.st)/$(nmsg)" firing/0
"$R" alerts > "$E/alerts-silenced.out" 2>&1
check "15b tando alerts shows it as firing and silenced" grep -q 'hog .*health .*firing silenced' "$E/alerts-silenced.out"
get hog /well > /dev/null; wruns 2
check "15c resolved while silenced: nothing sent" eq "$(nmsg)" 0
get hog /sick > /dev/null; wruns 3
"$R" alerts silence hog off > /dev/null 2>&1; wrun
check "15d silence lifted while firing: one notification then" eq "$(nev firing hog health)/$(nmsg)" 1/1
get hog /well > /dev/null; wruns 2
check "15e ... and one when it resolves" eq "$(nev resolved hog health)" 1
"$R" alerts silence all 5m > /dev/null 2>&1
get hog /sick > /dev/null; wruns 3
check "15f silence all" eq "$(nmsg)" 2
get hog /well > /dev/null; wruns 2; "$R" alerts silence all off > /dev/null 2>&1; wruns 2
check "15g fired and resolved inside a silence: nothing owed afterwards" eq "$(nmsg)" 2

# ---- 16. flapping ----
# hog/health already fired twice above; forget those firings as if the flap window had passed
srv "sudo sed -i '/^hog.health.fl=/d' /var/lib/tando/watch/state"
mark
aset hog.health_fails=1 hog.resolve_after=1
for i in 1 2 3 4; do get hog /sick > /dev/null; wrun; get hog /well > /dev/null; wrun; done
check "16a flapping: 2 firings + 2 resolves, then one flapping notice, then quiet" \
  eq "$(nev firing hog health)/$(nev resolved hog health)/$(nev flap hog health)/$(nmsg)" 2/2/1/5
aset hog.health_fails= hog.resolve_after=
"$R" alerts > "$E/alerts-flap.out" 2>&1

# ---- 17. reminder while an alert keeps firing (clock simulated: last notice 7 h ago) ----
mark
aset disk_pct=1; wrun
srv "sudo sed -i 's/^_host.disk.nt=.*/_host.disk.nt=$(( $(date +%s) - 25200 ))/' /var/lib/tando/watch/state"
wruns 2
check "17 a reminder after remind_hours, then not again" eq "$(nev firing host disk)/$(nev 'still firing' host disk)" 1/1

# ---- 18. failing notifiers: backoff, others unaffected, queued delivery after recovery ----
"$R" alerts > "$E/alerts-broken.out" 2>&1
check "18a tando alerts shows broken as failing with queued messages" grep -q 'broken .*failing' "$E/alerts-broken.out"
srv 'curl -s http://127.0.0.1:9999/ctl/fail/slow > /dev/null'
printf 'http://127.0.0.1:9999/slow/S3CR3Tslow1\n' | "$R" alerts notifier add slow webhook > /dev/null 2>&1
mark
aset disk_pct=; t0=$(date +%s); wruns 2; t1=$(date +%s)
check "18b a notifier that never answers costs at most its 15 s timeout per run ($((t1 - t0)) s for 2 runs)" test $((t1 - t0)) -le 40
check "18c the others still delivered" eq "$(nev resolved host disk)" 1
srv 'curl -s http://127.0.0.1:9999/ctl/ok/broken > /dev/null'
"$R" alerts test broken > "$E/test-broken.out" 2>&1    # a successful test ends the backoff
wrun
check "18d broken recovers: its queued messages arrive in one combined delivery" \
  srv "sudo tail -n +$((MARK + 1)) /root/recv.log | grep '\"path\":\"/broken/' | grep -q '\"status\":200.*firing hog health'"
"$R" alerts notifier rm slow > /dev/null 2>&1

# ---- 19. secrets ----
srv 'sudo /opt/tando/bin/tando-watch test > /dev/null & sudo /opt/tando/bin/tando-watch run & for i in $(seq 1 60); do ps -eo args; sleep 0.05; done; wait' > "$E/ps.out" 2>&1
check "19a no secret in any process argument during a run with deliveries" not grep -q S3CR3T "$E/ps.out"
check "19b no secret in the journal" not srv 'sudo journalctl --no-pager -o cat | grep -q "S3CR3[T]"'
check "19c no secret in unit files" not srv 'sudo grep -rqs "S3CR3[T]" /etc/systemd /run/systemd/transient'
check "19d no secret in a world-readable file" \
  not srv 'sudo find /opt/tando /var/lib/tando /etc /run /tmp /var/tmp /home /root -xdev -type f -perm -o+r 2>/dev/null | sudo xargs -r grep -ls "S3CR3[T]" 2>/dev/null | grep .'
# lint: allow RL02 stat runs on the server (GNU coreutils), not on the laptop
modes=$(srv 'sudo stat -c "%a %U" /opt/tando/alerts.d /opt/tando/alerts.d/notify-hook /opt/tando/alerts.d/heartbeat' | tr '\n' ' ')
check "19e secret files are root 600 in a root 700 directory" test "$modes" = "700 root 600 root 600 root "
check "19f no secret on the laptop (config dir, command output)" \
  not grep -rqs S3CR3T "$TANDO_CONFIG_DIR" "$E"/*.out
check "19g heartbeat pinged with the secret URL" srv 'sudo grep -q "\"path\":\"/hb/<S>\"" /root/recv.log'

# ---- 20. dead man's check ----
srv 'sudo systemctl start tando-watch.timer'
"$R" doctor > "$E/doctor.out" 2>&1
check "20a doctor shows the watch as running" grep -q 'alerts .*ok.*checks ran' "$E/doctor.out"
srv 'sudo systemctl stop tando-watch.timer'
"$R" doctor > "$E/doctor2.out" 2>&1; "$R" alerts > "$E/alerts-dead.out" 2>&1
check "20b timer stopped: doctor fails it" grep -q 'alerts .*fail.*not running' "$E/doctor2.out"
check "20c timer stopped: tando alerts says NOT RUNNING" grep -q 'NOT RUNNING' "$E/alerts-dead.out"

# ---- 21, 22 (the real timer, a restart of the host): test/e2e-alerts-timer.sh ----
# From here on the production defaults of these settings, as section 21 leaves them (23-28 set
# what they need themselves)
aset oom_quiet= restarts_window= deploy_grace= boot_grace= mem_for= heartbeat_every=

# ---- 23. certificate check, with Caddy's internal CA (public certificates need a real domain) ----
mark
"$R" host setup t tls=internal > /dev/null 2>&1; nodaemon
srv 'sudo systemctl stop tando-watch.timer'
aset tls_every=0 boot_grace=0; wrun
check "23a tls=internal: a fresh certificate is fine" eq "$(nev firing hog tls)" 0
aset tls_pct=101; wrun
check "23b a certificate inside the renewal threshold fires once (dates read from the served certificate)" \
  eq "$(nev firing hog tls)" 1
srv 'sudo grep -q "hog.tls.det=certificate for hog.localhost expires in" /var/lib/tando/watch/state'; check "23c detail says when it expires" test $? = 0
aset tls_pct=; wruns 2
check "23d tls resolves once" eq "$(nev resolved hog tls)" 1
aset tls_every= boot_grace=
"$R" host setup t tls=off > /dev/null 2>&1; nodaemon

# ---- 24. Caddy down (fault review d1, d4): one alert, the apps' health is held, one recovery ----
srv 'sudo systemctl stop tando-watch.timer'
aset deploy_grace=0; wruns 2; mark
srv 'sudo systemctl stop caddy'
wruns 3
check "24a Caddy stopped: fires after one sample, exactly one notification" eq "$(nev firing host caddy)/$(nmsg)" 1/1
check "24b ... and no health alert for the apps behind it" eq "$(nev firing hog health)$(nev firing hello health)$(nev firing site health)" 000
srv 'sudo systemctl start caddy'; wruns 2
check "24c Caddy started: resolves once" eq "$(nev resolved host caddy)/$(nmsg)" 1/2
wruns 3
check "24d no app alert after Caddy is back" eq "$(nmsg)" 2
if srv 'systemctl show -P Restart caddy' | grep -q on-failure; then
  mark
  n0=$(srv 'systemctl show -P NRestarts caddy')
  srv 'sudo systemctl kill -s KILL caddy'
  until_ 30 eval '[ "$(srv "systemctl show -P NRestarts caddy")" -gt "$n0" ] && srv "systemctl -q is-active caddy"'
  wruns 2
  check "24e Caddy SIGKILL with Restart=on-failure: restarted by systemd, no alert" eq "$(nmsg)/$(srv 'systemctl is-active caddy')" 0/active
else
  echo "SKIP 24e Caddy SIGKILL: caddy.service has no Restart=on-failure drop-in on this host (tando-agent setup adds it)"
  srv 'sudo systemctl start caddy'
fi

# ---- 25. Caddy config broken by hand (d2): validated only after a change ----
mark
aset caddy_every=0; wrun
srv 'sudo cp -p /etc/caddy/Caddyfile /root/Caddyfile.good && echo "this is { not caddy" | sudo tee -a /etc/caddy/Caddyfile > /dev/null'
wrun
check "25a an invalid Caddyfile on disk fires once" eq "$(nev firing host caddy_config)" 1
check "25b ... the running Caddy (old config) keeps serving: no app alert" eq "$(nev firing hog health)/$(nmsg)" 0/1
vt() { srv 'sudo sed -n "s/^caddy_t=//p" /run/tando-watch/vstate'; }
t0=$(vt); sleep 1; wruns 2   # (kept: caddy_t is in seconds, a new validation must show as another one)
check "25c no new validation while nothing under /etc/caddy changed" eq "$(vt)" "$t0"
srv 'sudo cp -p /root/Caddyfile.good /etc/caddy/Caddyfile && sudo touch /etc/caddy/Caddyfile'; wruns 2
check "25d config fixed: resolves once" eq "$(nev resolved host caddy_config)" 1
aset caddy_every=

# ---- 26. activation that died (a1-a5): tando-watch's run recovers it before the checks ----
mark
srv "sudo sed -i 's/^phase=idle\$/phase=verify/' /opt/tando/apps/hog/state"
wrun
check "26a dead activation: the next check run recovers it (phase idle)" \
  srv 'sudo grep -qx phase=idle /opt/tando/apps/hog/state'
check "26b ... before the checks see it: no stuck alert, no message" eq "$(st hog.stuck.st)/$(nmsg)" /0
mark
echo 5 > "$W/hello/VERSION"
(cd "$W/hello" && "$R" env set SLOW_START=8 > /dev/null 2>&1)
(cd "$W/hello" && "$R" deploy > "$E/d5.out" 2>&1) &
DP=$!
until_ 30 srv 'sudo grep -q "^phase=preflight" /opt/tando/apps/hello/state'
srv 'sudo systemctl kill -s KILL "tando-hello-act-*"'
until_ 30 srv '! systemctl list-units --plain --no-legend "tando-hello-act-*" | grep -q " active "' 
kill $DP 2> /dev/null; wait $DP 2> /dev/null
wruns 2
# (the agent may be recovering it itself at this very moment: a run leaves an app alone while its
# lock is held, so the state is read when the lock is free, an event; no further run is started)
until_ 15 srv 'sudo flock -n /opt/tando/apps/hello/lock true'
if srv 'sudo grep -q "^phase=idle" /opt/tando/apps/hello/state'; then
  check "26d SIGKILL of a real activation: the agent recovered it itself, nothing to report" eq "$(nev firing hello stuck)" 0
else
  check "26d SIGKILL of a real activation: reported as stuck within two runs" eq "$(nev firing hello stuck)" 1
fi
srv "sudo /opt/tando/bin/tando-agent recover hello > /dev/null"
(cd "$W/hello" && "$R" env unset SLOW_START > /dev/null 2>&1); wruns 2
aset deploy_grace=

# ---- 27. review fixes (docs/CODE-REVIEW.md B3, B4, B6, S-B1, S-B2, S-B5) ----
srv 'sudo systemctl stop tando-watch.timer'; wruns 2
"$R" host add dead vmadmin@127.0.0.1 --port 1 --key "$ROOT/test/server/id_test" --no-check > /dev/null
"$R" alerts heartbeat off -H dead > "$E/dead1.out" 2>&1; rc1=$?
printf 'http://127.0.0.1:9999/x\n' | "$R" alerts notifier add x webhook -H dead > "$E/dead2.out" 2>&1; rc2=$?
"$R" alerts set disk_pct=80 -H dead > "$E/dead3.out" 2>&1; rc3=$?
check "27a unreachable host: heartbeat, notifier add and set fail (rc $rc1 $rc2 $rc3) and claim no success" \
  test $rc1 != 0 -a $rc2 != 0 -a $rc3 != 0 -a "$(cat "$E"/dead[123].out | grep -c 'removed\|added notifier\|alerts: set')" = 0
rm -f "$TANDO_CONFIG_DIR/hosts/dead"   # back to one host: the commands below need no -H
mark
# shmem cannot be grown from the app (its /dev/shm is a small private tmpfs), so run the installed
# memstat on a memory.stat in the kernel's field order: anon, file, ..., shmem (review S-B1)
# (a Go tando-watch: the same memory.stat is its unit test, srv/watch TestMemstat)
c27b() {
  if srv 'head -c 2 /opt/tando/bin/tando-watch' | grep -q '^#!'; then
    srv 'd=$(mktemp -d); printf "anon 100000000\nfile 5000\nkernel 1\nshmem 400000000\nfile_mapped 3\n" > $d/memory.stat
       eval "$(sed -n "/^memstat() {/,/^}/p" /opt/tando/bin/tando-watch)"; memstat $d; rm -rf $d; [ "$MEM" = 500000000 ]'
  else
    (cd "$ROOT/srv" && GOTOOLCHAIN=local go test -count=1 -run '^TestMemstat$' ./watch/ > /dev/null 2>&1)
  fi
}
check "27b memory counts shmem (anon 100 MB + shmem 400 MB = 500 MB, shmem listed after file)" c27b
# section 16 left hog/health flapping (notifications paused for an hour): forget that, as there
srv "sudo sed -i '/^hog.health.fl=/d; /^hog.health.flap=/d' /var/lib/tando/watch/state"
mark
aset hog.health_fails=02
check "27d a leading zero is stored as a decimal number (02 -> 2)" srv 'grep -qx "hog.health_fails=2" /opt/tando/alerts.conf'
srv 'echo hog.resolve_after=08 | sudo tee -a /opt/tando/alerts.conf > /dev/null'   # written by hand
get hog /sick > /dev/null; wruns 2
check "27e health_fails=02: fires after 2 failed probes (not turned off by an octal error)" eq "$(nev firing hog health)" 1
get hog /well > /dev/null; wruns 7
check "27f resolve_after=08 written by hand: not resolved after 7 good runs" eq "$(nev resolved hog health)" 0
wrun
check "27g ... resolved after the 8th" eq "$(nev resolved hog health)" 1
aset hog.health_fails= hog.resolve_after=
"$R" alerts show > "$E/show.out" 2>&1
check "27j tando alerts show is the default view" grep -q 'active (' "$E/show.out"
printf 'http://127.0.0.1:9999/eq/S3CR3Teq?k=\n' | "$R" alerts notifier add eq webhook > /dev/null 2>&1
mark; "$R" alerts test eq > /dev/null 2>&1
check "27k a webhook URL ending in = keeps it (stored and called as ...?k=)" \
  srv "sudo tail -n +$((MARK + 1)) /root/recv.log | grep -q '\"path\":\"/eq/<S>?k=\"'"
"$R" alerts notifier rm eq > /dev/null 2>&1

# ---- 28. app errors and health classes (tando-logs watch-scan, tando health, tando errors) ----
log "app errors and health classes"
mkdir -p "$W/boom"
cat > "$W/boom/server.js" <<'EOF'
// boom: errors, stack traces and health answers on demand (see test/e2e-alerts.sh section 28)
const http = require('http');
let health = 200, body = 'ok', delay = 0;
http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x'), p = u.pathname;
  const done = (c, t) => { res.writeHead(c, { 'content-type': 'text/plain' }); res.end((t || 'ok') + '\n'); };
  if (p === '/health') return setTimeout(() => done(health, body), delay);
  if (p.startsWith('/ctl/health/')) { const x = p.split('/'); health = Number(x[3]); body = decodeURIComponent(x[4] || 'ok'); return done(200); }
  if (p.startsWith('/ctl/delay/')) { delay = Number(p.split('/')[3]); return done(200); }
  if (p === '/err/node') { try { null.foo(); } catch (e) { console.error(e); } return done(500, 'boom'); }
  if (p === '/err/py') { console.log('Traceback (most recent call last):\n  File "/srv/app/views.py", line 41, in checkout\n    total = cart["total"]\nKeyError: \'total\''); return done(500); }
  if (p === '/err/go') { console.error('panic: runtime error: index out of range [5] with length 3\n\ngoroutine 1 [running]:\nmain.handler(0xc000012345)\n\t/home/dev/app/main.go:42 +0x1d\nexit status 2'); return done(500); }
  if (p === '/err/secret') { console.error('Error: login failed for password=S3CR3Tpw1'); return done(500); }
  if (p === '/err/plain') { for (let i = 0; i < Number(u.searchParams.get('n') || 1); i++) console.error('ERROR db timeout after ' + (100 + i) + ' ms'); return done(500); }
  if (p.startsWith('/api/fail')) return done(500, 'fail');
  if (p === '/flood') { for (let i = 0; i < Number(u.searchParams.get('n') || 1000); i++) console.log('flood ' + i + ' ' + 'x'.repeat(80)); return done(200); }
  if (p === '/say') { console.log('said ' + (u.searchParams.get('w') || '')); return done(200); }
  if (p === '/crash') { console.error('fatal: crashing on purpose S3CR3Tcrash'); setTimeout(() => process.exit(3), 50); return done(200); }
  done(200, 'boom');
}).listen(Number(process.env.PORT), '127.0.0.1');
process.on('SIGTERM', () => process.exit(0));
EOF
printf 'app = boom\nrecipe = node\nstart = node server.js\nhealth = /health\nmemory = 96M\nhealth_expect = 200 ok\nhealth_fails = 2\nhealth_recover = 3\nlog_rate = 200/10s\n' > "$W/boom/tando.conf"
(cd "$W/boom" && "$R" up > "$E/up-boom.out" 2>&1) || { tail -5 "$E/up-boom.out" >&2; fail "28 up boom"; }
check "28a tando.conf health_expect/health_fails/health_recover reach app.conf" \
  srv 'sudo grep -qx "health_expect=200 ok" /opt/tando/apps/boom/app.conf && sudo grep -qx health_fails=2 /opt/tando/apps/boom/app.conf'
aset deploy_grace=0
wruns 2
breq() { curl -s -o /dev/null --connect-to "boom.localhost:80:127.0.0.1:$HP" "http://boom.localhost$1"; }   # Host without a port: logged
mark
get boom /ctl/health/200/nope > /dev/null; wrun
check "28b health_fails=2 (tando.conf): one failed probe is pending" eq "$(st boom.health.st)" pending
wrun
c28c() { [ "$(nev firing boom health)" = 1 ] && srv "sudo grep -q 'boom.health.det=unhealthy: answered HTTP 200 without .ok.' /var/lib/tando/watch/state"; }
check "28c ... the 2nd fires: unhealthy, the text is missing" c28c
get boom /ctl/health/200/ok > /dev/null; wruns 2
check "28d health_recover=3 (tando.conf): not resolved after 2 good probes" eq "$(nev resolved boom health)" 0
wrun
check "28e ... resolved after the 3rd" eq "$(nev resolved boom health)" 1
# (an alert keeps the detail it fired with: each class is checked from a resolved state)
healthy() { get boom /ctl/delay/0 > /dev/null; get boom /ctl/health/200/ok > /dev/null; wruns 3; }
get boom "/ctl/health/503/boom%20is%20busy:%20too%20many%20requests" > /dev/null; wruns 2
check "28f a 503 busy answer is classed as saturated" srv "sudo grep -q 'boom.health.det=saturated: ' /var/lib/tando/watch/state"
healthy; get boom /ctl/health/500/x > /dev/null; wruns 2
check "28g a 500 answer is unhealthy, expected 200" srv "sudo grep -q 'boom.health.det=unhealthy: answered HTTP 500, expected 200' /var/lib/tando/watch/state"
healthy; aset health_timeout=2
get boom /ctl/delay/4000 > /dev/null; wruns 2
check "28h no answer within health_timeout is slow" srv "sudo grep -q 'boom.health.det=slow: no answer within 2 s' /var/lib/tando/watch/state"
aset health_timeout=; healthy
check "28i back to ok" eq "$(st boom.health.st)" ok

# HTTP 5xx of real requests (the request log), with the failing paths named
wrun; mark
for i in 1 2 3 4 5 6 7 8; do breq "/api/fail/$i"; done
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do breq "/page/$i"; done
wrun
check "28j 8 of 20 requests answered 5xx (40%): http fires once" eq "$(nev firing boom http)" 1
check "28k ... naming the failing path, ids folded" \
  srv "sudo grep -q 'boom.http.det=[0-9]* of [0-9]* requests answered 5xx ([0-9]*%) in 5 min; top: [0-9]*x 500 GET /api/fail/:n' /var/lib/tando/watch/state"
for i in $(seq 1 120); do breq "/page/$i"; done
wruns 2
check "28l diluted below http_pct: resolves once" eq "$(nev resolved boom http)" 1

# errors in the app's log: grouped; a new type after a deploy is reported once, naming the release
echo "// v2" >> "$W/boom/server.js"
(cd "$W/boom" && "$R" deploy > "$E/deploy-boom.out" 2>&1)
rel=$(srv 'sudo sed -n "s/^current=//p" /opt/tando/apps/boom/state')
wruns 2; mark
breq /err/node; breq /err/node; breq /err/py; breq /err/go; breq /err/secret
wrun
since_mark > "$E/newerr.json"
c28m() { [ "$(grep -o "NEW ERROR boom: new error after release $rel" "$E/newerr.json" | wc -l | tr -d ' ')" = 3 ] &&
  grep -q "NEW ERROR boom: and 1 more new error types after release $rel" "$E/newerr.json"; }
check "28m new error types right after a deploy: one notice each for 3, then how many more, naming the release" c28m
check "28n the notice names type and frame, suggests rollback" \
  sh -c "grep -Eq 'TypeError at Server|KeyError at /srv/app/views.py:checkout|Go panic at main.handler' '$E/newerr.json' &&
    grep -q 'tando rollback -a boom' '$E/newerr.json'"
c28o() { python3 -c 'import json,sys; b=[json.loads(l)["body"] for l in open(sys.argv[1]) if l.strip()]; sys.exit(not b or any("<S>" in x or "Cannot read properties" in x for x in b))' "$E/newerr.json"; }
check "28o no raw log line in a notification by default (message text, secrets)" c28o
mark; breq /err/node; wrun
check "28p the same error again: no second notice" eq "$(nmsg)" 0
COLUMNS=80 "$R" errors -a boom > "$E/errors.out" 2>&1; cat "$E/errors.out" >&2
check "28q tando errors: Node, Python and Go traces grouped by type and frame" \
  sh -c "grep -q 'TypeError at Server.<anonymous> (server.js)' '$E/errors.out' && grep -q 'KeyError at /srv/app/views.py:checkout' '$E/errors.out' &&
    grep -q 'Go panic at main.handler' '$E/errors.out' && grep -q '^│ *3 ' '$E/errors.out'"
check "28r tando errors: TIME (GMT) columns, the release, a sample with its stack, 80 columns" \
  sh -c "grep -q 'LAST (GMT)' '$E/errors.out' && grep -q '$rel' '$E/errors.out' && grep -q 'at Server.<anonymous>' '$E/errors.out' &&
    perl -CSD -ne 'exit 1 if length(\$_) - 1 > 80' '$E/errors.out'"
"$R" errors -a boom --json > "$E/errors.json" 2>&1
check "28s tando errors --json is valid JSON with the groups" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert len(d["errors"]) >= 4' "$E/errors.json"
aset err_spike=8; mark
breq "/err/plain?n=12"; wrun
check "28t error spike: 12 error events within 5 min fire errors once" eq "$(nev firing boom errors)" 1
aset err_spike=

# lines journald dropped (log_rate 200/10s in tando.conf): a low-severity alert, and a note in logs
# (kept: journald reports what it dropped when the app logs again after its interval, 10 s here)
mark; breq "/flood?n=3000"; sleep 11; breq "/say?w=after"; sleep 1; wrun
c28u() { [ "$(nev firing boom logs)" = 1 ] && since_mark | grep -q 'FIRING boom/logs (low): journald dropped'; }
check "28u journald dropped lines: logs fires, marked low severity" c28u
"$R" logs -a boom -n 3 > "$E/logs-note.out" 2>&1
check "28v tando logs ends with a note on the dropped lines" grep -q '^# note: journald dropped [0-9]* lines' "$E/logs-note.out"

# a crash loop: the exit status and the last lines (kept on the server, not sent by default)
mark
# (the restart count is read before the crash, as in section 10: read after it, the wait for a
# restart "since then" never ended before its 20 s were over)
for i in 1 2 3; do n0=$(nrestarts boom); breq /crash; until_ 20 restarted boom "$n0"; wrun; done
srv 'sudo grep "^boom.restarts.det=" /var/lib/tando/watch/state' > "$E/crash.det"
check "28w restarts: the detail names the exit status" grep -q 'last: exit status 3' "$E/crash.det"
c28x() { since_mark | grep -q 'restarts' && ! since_mark | grep -q 'crashing on purpose'; }
check "28x ... and the notification carries no log line (include_log_lines=off)" c28x
COLUMNS=80 "$R" health boom > "$E/health-boom.out" 2>&1; cat "$E/health-boom.out" >&2
check "28y tando health <app>: uptime, incidents with START (GMT) and the last lines before the crash" \
  sh -c "grep -q 'uptime 24h' '$E/health-boom.out' && grep -q 'START (GMT)' '$E/health-boom.out' &&
    grep -q 'restarts' '$E/health-boom.out' && grep -q 'crashing on purpose' '$E/health-boom.out'"
COLUMNS=80 "$R" health > "$E/health.out" 2>&1; "$R" health --json > "$E/health.json" 2>&1
check "28z tando health: every app, 80 columns; --json valid" \
  sh -c "grep -q 'UP 24H' '$E/health.out' && grep -q '^│ boom ' '$E/health.out' &&
    perl -CSD -ne 'exit 1 if length(\$_) - 1 > 80' '$E/health.out' &&
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"apps\"]' '$E/health.json'"
aset include_log_lines=on
mark; srv "sudo sed -i -e '/^boom.restarts.ns=/d' -e '/^boom.restarts.nt=/d' /var/lib/tando/watch/state"; wrun
c28za() { since_mark | grep -q 'crashing on purpose'; }
check "28za include_log_lines=on: the crash notification carries the app's last lines" c28za
aset include_log_lines=
# a failing notifier is reported by doctor
srv 'curl -s http://127.0.0.1:9999/ctl/fail/broken > /dev/null'
# a message waiting for it (one queued by hand: what is firing now was sent long ago)
srv "printf 'firing\tboom\thealth\tqueued for the doctor check\t1\n' | sudo tee /var/lib/tando/watch/out/broken/1.1 > /dev/null"
doc_warns() { srv "sudo sed -i '/^_nf.broken.next=/d' /var/lib/tando/watch/state"; wrun
  "$R" doctor > "$E/doctor.out" 2>&1; grep -q 'notifier broken.*failing' "$E/doctor.out"; }
T_UNTIL_STEP=2 until_ 60 doc_warns   # (a message must be queued for it and fail to go out first)
check "28zb doctor names the failing notifier" grep -q 'notifier broken.*failing' "$E/doctor.out"
get boom /ctl/health/200/ok > /dev/null; wruns 3
# cost of a run with the scan: five apps here (hello, hog, site, boom + Caddy), CPU of the unit
# (with tandod the run is its tick: its CPU counter before and after, plus the one-shot that asked)
dcpu() { srv 'systemctl show -P CPUUsageNSec tandod' | grep -x '[0-9]*' || echo 0; }
cpu=0; for i in 1 2 3 4 5; do d0=$(dcpu); wrun; c=$(srv 'systemctl show -P CPUUsageNSec tando-watch.service' | grep -x '[0-9]*' || echo 0)
  cpu=$((cpu + (c + $(dcpu) - d0) / 1000000)); done
echo "watch run CPU (5 runs, average): $((cpu / 5)) ms" >> "$E/numbers"
check "28zc a check run costs under 0.5 s of CPU on average ($((cpu / 5)) ms)" test $((cpu / 5)) -lt 500

# ---- 30. scheduled jobs that fail (srv/watch check_jobs.go): one message per failed run ----
# ops: hello with two jobs whose exit status the test sets (a file in shared/); "yearly" so that no
# timer starts one meanwhile: runs are started as the timer does (systemctl start) or by hand
cp -R "$TREE/examples/hello" "$W/ops"
printf '#!/bin/sh\n# exits with the status the suite wrote (0 without one)\nexit "$(cat /opt/tando/apps/ops/shared/code 2> /dev/null || echo 0)"\n' > "$W/ops/job.sh"
printf 'app = ops\nrecipe = node\nstart = node server.js\nhealth = /health\nmemory = 128M\njob.flaky = yearly | sh job.sh\njob.gone = yearly | sh job.sh\n' > "$W/ops/tando.conf"
(cd "$W/ops" && "$R" up > "$E/up-ops.out" 2>&1) || { tail -5 "$E/up-ops.out" >&2; fail "30 up ops (an app with two jobs)"; }
jcode() { srv "echo $1 | sudo tee /opt/tando/apps/ops/shared/code > /dev/null"; }
jtimer() { srv "sudo systemctl start tando-ops-job-$1.service" > /dev/null 2>&1; true; }   # what its timer does
jdet() { since_mark | grep -q "$1"; }
mark; wruns 2
check "30a jobs scheduled that never ran: no alert, no state" \
  eq "$(srv 'systemctl is-active tando-ops-job-flaky.timer tando-ops-job-gone.timer' | tr '\n' ' ')$(nev firing ops job.flaky)/$(st ops.job.flaky.st)" "active active 0/"
jcode 3; (cd "$W/ops" && "$R" jobs run flaky > "$E/jobrun1.out" 2>&1); rc=$?
check "30b tando jobs run of a failing job exits with its status (rc=$rc)" eq "$rc" 3
wrun
check "30c a job that exits 3 (run by hand): one notification naming the job" eq "$(nev firing ops job.flaky)/$(st ops.job.flaky.st)" 1/firing
check "30d its detail: the job, when, the exit status, what to run" jdet 'job flaky failed at [0-9-]* [0-9:]* UTC: exit status 3; tando jobs run flaky -a ops'
wruns 3
check "30e the same failed run is not told again" eq "$(nev firing ops job.flaky)" 1
"$R" alerts > "$E/alerts-job.out" 2>&1
check "30f tando alerts lists it as ops job.flaky" grep -q 'ops.*job\.flaky.*exit status 3' "$E/alerts-job.out"
jcode 4; jtimer flaky; wrun
check "30g the next run fails too (started as its timer does): a second notification, with its status" \
  eval '[ "$(nev firing ops job.flaky)" = 2 ] && jdet "job flaky failed at .* UTC: exit status 4"'
wruns 2
check "30h and only that one" eq "$(nev firing ops job.flaky)/$(nev resolved ops job.flaky)" 2/0
jcode 0; (cd "$W/ops" && "$R" jobs run flaky > "$E/jobrun2.out" 2>&1); rc=$?
wrun
check "30i a successful run by hand (rc=$rc) resolves it at once, one notification" \
  eq "$rc/$(nev resolved ops job.flaky)/$(st ops.job.flaky.st)" 0/1/ok
# a job that fails and is then removed from tando.conf: its alert goes with it
jcode 7; jtimer gone; jcode 0; wrun
check "30j the second job fails: its own alert" eq "$(nev firing ops job.gone)/$(st ops.job.gone.st)" 1/firing
grep -v '^job.gone' "$W/ops/tando.conf" > "$W/ops/tando.conf.new" && mv "$W/ops/tando.conf.new" "$W/ops/tando.conf"
(cd "$W/ops" && "$R" up > "$E/up-ops2.out" 2>&1) || tail -5 "$E/up-ops2.out" >&2
wrun
check "30k the job is removed from tando.conf and deployed: its alert resolves (no longer scheduled) and is dropped" \
  eval '[ "$(nev resolved ops job.gone)" = 1 ] && jdet "the job is no longer scheduled" && [ "$(st ops.job.gone.st)" != firing ] &&
        [ -z "$(st ops.job.gone.det)$(st ops.job.gone.run)" ] && srv "! test -e /etc/systemd/system/tando-ops-job-gone.service"'
wruns 2
check "30l nothing more about either job" eq "$(nev firing ops job.flaky)/$(nev firing ops job.gone)/$(nev resolved ops job.gone)" 2/1/1

# ---- 31. PostgreSQL (srv/watch check_postgres.go): connections of an app's role, the server down ----
printf 'database = postgres\n' >> "$W/ops/tando.conf"
(cd "$W/ops" && "$R" up > "$E/up-ops-db.out" 2>&1) || tail -5 "$E/up-ops-db.out" >&2
check "31a up with database = postgres: PostgreSQL accepts connections (it is installed from the network when missing)" \
  srv 'pg_isready -q -h 127.0.0.1'
# sessions of ops's role, held open by real psql clients in a unit of their own until pgfree
srv 'sudo tee /root/pghold.sh > /dev/null' <<'PGHOLD'
#!/bin/sh
# pghold.sh N: N idle sessions of the role of app ops, open until this unit is stopped
url=$(/opt/tando/bin/tando-agent db-url ops | sed -n 's/^url=//p')
i=0
while [ "$i" -lt "$1" ]; do sleep 900 | psql -q "$url" & i=$((i + 1)); done
wait
PGHOLD
pgconns() { srv "sudo -u postgres psql -At -c \"SELECT count(*) FROM pg_stat_activity WHERE usename = 'tando_ops'\"" 2> /dev/null; }
pghas() { [ "$(pgconns)" = "$1" ]; }
pghold() { srv "sudo systemd-run -q --collect --unit=pghold /bin/sh /root/pghold.sh $1"; until_ 30 pghas "$1"; }
pgfree() { srv 'sudo systemctl stop pghold.service' 2> /dev/null; until_ 30 pghas 0; }
aset db_conn_for=2
mark; wruns 2
"$R" status -a ops > "$E/status-ops.out" 2>&1; "$R" health ops > "$E/health-ops.out" 2>&1
"$R" status -a ops --json > "$E/status-ops.json" 2>&1
check "31b tando status and tando health show the database's size and its role's connections against the server's limit" \
  eval 'grep -Eq "database +postgres +[0-9.]+ MB, 0 of 10 connections" "$E/status-ops.out" &&
        grep -Eq "database +[0-9.]+ MB, 0 of 10 connections" "$E/health-ops.out" &&
        grep -Eq "\"database\":\{\"bytes\":[0-9]+,\"connections\":0,\"connection_limit\":10\}" "$E/status-ops.json"'
pghold 7; wruns 3
check "31c 7 of the role's 10 connections held open (below 80%): no alert" eq "$(pgconns)/$(st ops.db_conns.st)/$(nev firing ops db_conns)" 7//0
pgfree; pghold 8; wrun
check "31d 8 of 10 held: one sample is pending, nothing sent (db_conn_for=2 here, 5 in production)" \
  eq "$(pgconns)/$(st ops.db_conns.st)/$(nev firing ops db_conns)" 8/pending/0
wrun
check "31e the second sample fires, one notification" eq "$(st ops.db_conns.st)/$(nev firing ops db_conns)" firing/1
check "31f its detail: 8 of 10, the limit read from the server" jdet '8 of 10 database connections in use (the limit of its role tando_ops'
"$R" status -a ops > "$E/status-ops2.out" 2>&1
check "31g tando status shows the connections and the alert" \
  eval 'grep -Eq "database +postgres +[0-9.]+ MB, 8 of 10 connections" "$E/status-ops2.out" && grep -q "db_conns" "$E/status-ops2.out"'
wruns 2
check "31h no repeat while they stay open" eq "$(nev firing ops db_conns)/$(nev resolved ops db_conns)" 1/0
pgfree; wruns 2
check "31i released: resolved, one notification" eq "$(pgconns)/$(st ops.db_conns.st)/$(nev resolved ops db_conns)" 0/ok/1
# PostgreSQL stopped while an app has a database: one host alert (down_after=2 samples)
pgdown() { ! srv 'pg_isready -q -h 127.0.0.1'; }
srv 'sudo systemctl stop postgresql'; until_ 30 pgdown
wrun
check "31j PostgreSQL stopped: one failed question is pending" eq "$(st _host.postgres.st)/$(nev firing host postgres)" pending/0
wrun
check "31k the second fires host/postgres once, naming the app that needs it; no alert of the app's connections" \
  eval '[ "$(nev firing host postgres)" = 1 ] && jdet "PostgreSQL does not answer (.*); used by ops: sudo systemctl status postgresql" &&
        [ "$(nev firing ops db_conns)" = 1 ]'
wruns 2
check "31l no repeat while it is down, and the run still ends (the question has a timeout)" eq "$(nev firing host postgres)" 1
srv 'sudo systemctl start postgresql'; until_ 30 srv 'pg_isready -q -h 127.0.0.1'
wruns 2
check "31m started again: resolved once" eq "$(st _host.postgres.st)/$(nev resolved host postgres)" ok/1
aset db_conn_for=

# ---- 29 (tandod), 27h, 27i (the dead man's check in a local time zone): test/e2e-alerts-daemon.sh ----
srv 'sudo systemctl start tando-watch.timer'
alerts_done
