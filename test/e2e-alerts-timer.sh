#!/bin/bash
# End-to-end test of tando alerts, the part that waits for real time (test/e2e-alerts.sh has the
# bulk, with check runs started by hand): a restart of the whole host (22: the timer and tandod
# come back, boot_grace, one notice and no storm) and the real once-a-minute timer with the
# production defaults (21: the time to detect a dead app and to announce its recovery).
# One PASS/FAIL line per check; exits non-zero on any failure. Takes about 10 minutes, nearly all
# of it the waits under test. Helpers, fixtures and environment variables: test/alerts-lib.sh.
#
# 22 runs before 21: 21 needs the production boot_grace (180 s) to be over, and it is when 22 ends.
# Neither starts runs by hand where the timer is what is tested; see the comments at each wait.
#
# Usage: test/e2e-alerts-timer.sh [--no-reset]
#   server by default: tando-test-alerts-timer, ssh 2305, http 8305 (restarted in 22 when it is
#   ours: see TANDO_TEST_OWNED in test/alerts-lib.sh)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
. "$ROOT/test/alerts-lib.sh"
alerts_server tando-test-alerts-timer 2305 8305 1
t_init e2e-alerts-timer
alerts_setup "$@"
alerts_fixtures_ok || { echo "FAIL fixtures (the timer or the notifiers: e2e-alerts 1a and 1b check them)"; exit 1; }

# The settings these sections always ran with: production defaults, except
# load=off: in a container /proc/loadavg is the whole VM's (other containers' work, on 1 pinned CPU)
# sample_seconds=0: a run started by hand counts as a sample (only used to get an alert firing in 22)
aset load=off sample_seconds=0
srv 'sudo systemctl start tando-watch.timer'
# boot_age: seconds since the server's systemd started (what boot_grace is measured from)
boot_age() { srv 'awk -v up="$(cut -d" " -f1 /proc/uptime)" "{ sub(/.*\\) /, \"\"); print int(up - \$20 / 100) }" /proc/1/stat'; }

# ---- 22. whole host restart: the timer survives, state survives, no alert storm ----
if [ $OWNED = 0 ]; then
  echo "SKIP 22 whole host restart: $TANDO_TEST_NAME is not ours to restart"
else
# an alert that fires before the restart: an event, so a run is started by hand until it does.
# (This waited for "_host.disk" without its ".st", a key the state file does not have: always the
# full 120 s, by when the timer's own runs had fired it)
aset disk_pct=1; until_ 120 wrun_and firing _host.disk.st
# the server has been up for a while, like any host that restarts (it is new here): tando-watch
# takes a boot time that moved by less than 60 s for the same boot, and sends no notice then
until_ 120 eval '[ "$(boot_age)" -ge 90 ]'
until_ 60 idle; mark   # that run has delivered its notification
log "docker restart $TANDO_TEST_NAME"
docker restart "$TANDO_TEST_NAME" > /dev/null
until_ 60 srv true || { # (why the server does not answer after its restart, for the log)
  docker inspect -f 'state {{.State.Status}} exit {{.State.ExitCode}} restarts {{.RestartCount}}' "$TANDO_TEST_NAME" >&2
  docker exec "$TANDO_TEST_NAME" sh -c 'systemctl is-system-running; systemctl list-jobs --no-pager | head -20; ls -la /run/nologin;
    systemctl --failed --no-pager --no-legend; systemctl status ssh ssh.socket --no-pager | head -30; journalctl -b -p warning --no-pager | tail -40' >&2
  "$ROOT/test/server/ssh.sh" -v true 2>&1 | tail -15 >&2
  docker exec "$TANDO_TEST_NAME" sh -c 'ip -4 addr show scope global; ss -ltn | head -12' >&2
  # Seen with other test containers starting and stopping beside this one (Docker on OrbStack):
  # the container is up, systemd runs and ssh.socket listens, but the published ports reach
  # nothing (ssh and http alike, no connection arrives inside). A second restart brings them back.
  log "the server's published ports do not answer after the restart: restarting it once more"
  docker restart "$TANDO_TEST_NAME" > /dev/null
  until_ 60 srv true
}
until_ 30 test "$(curl -s -o /dev/null -w '%{http_code}' "http://hog.localhost:$HP/health")" = 200
check "22a the timer is active again after the restart" test "$(srv 'systemctl is-active tando-watch.timer')" = active
[ "${TANDO_TEST_NO_DAEMON:-}" = 1 ] ||
  check "22e tandod runs again after the restart, with its socket and its active mark" \
    srv 'systemctl -q is-active tandod && sudo test -S /run/tandod/tandod.sock && sudo test -e /run/tandod/active'
# watch the notifications until the timer has run twice with the app checks back on: the first
# run after the restart sends the reboot notice and boot_grace (180 s) holds the app checks, so a
# storm would come after it. Runs are counted from the journal, not guessed with a sleep.
boot=$(srv 'date +%s')
# (tandod runs the checks: two runs after boot_grace are a tick 60 s after the first one possible)
truns() { if [ "$(dtick)" -ge $((boot + 240)) ]; then echo 2; else
  srv "journalctl -u tando-watch.service -u tando-watch-fallback.service --since @$((boot + 180)) --no-pager -o cat | grep -c '^Finished'"; fi; }
# (kept, the wait under test: the real boot_grace of 180 s, then two real runs a minute apart)
log "watching notifications until the timer ran twice after boot_grace"
T_UNTIL_STEP=10 until_ 400 eval '[ "$(truns)" -ge 2 ]'; until_ 60 idle
c22b() { [ "$(dtick)" -gt "$boot" ] || srv 'test -n "$(systemctl show -P ExecMainStartTimestamp tando-watch-fallback.service)"'; }
check "22b the checks ran after the restart (tandod, or the timer's fallback)" c22b
srv "sudo tail -n +$((MARK + 1)) /root/recv.log | grep '\"path\":\"/hook/'" > "$E/after-restart.log"
check "22c after the restart: exactly one notification (host restarted), no storm" \
  eq "$(grep -c . "$E/after-restart.log")/$(grep -c '"reboot host reboot"' "$E/after-restart.log")" 1/1
check "22d the alert firing before the restart is still firing and was not sent again" \
  eq "$(st _host.disk.st)/$(nev firing host disk)" firing/0
fi
aset disk_pct=; wrun   # (host disk resolves now, not in the middle of 21)

# ---- 21. production defaults with the real timer: time to detect a dead app ----
aset oom_quiet= restarts_window= deploy_grace= boot_grace= mem_for= heartbeat_every=
srv 'sudo systemctl start tando-watch.timer'
# boot_grace (180 s by default) must be over, as it always was here: it is after 22; this waits
# only when 22 was skipped on a server that has just started
until_ 200 eval '[ "$(boot_age)" -ge 180 ]'
until_ 60 idle; mark   # the timer's first run (if any) is over: its messages are not counted
t0=$(date +%s)
crash_on hello
# (kept, the wait under test: the real timer's ticks, deploy_grace and down_after as shipped)
until_ 300 seen firing hello down
t1=$(date +%s)
echo "time to detect a dead app with the real timer and production defaults: $((t1 - t0)) s" >> "$E/numbers"
# worst case by design: the first tick that sees the activation (up to 60 s after t0) starts
# deploy_grace (120 s), and down_after needs 2 samples a minute apart: 60 + 120 + 60 = 240 s.
# Measured 142-194 s over six runs; the earlier 180 s bound failed about one run in three.
check "21a dead app detected by the timer within 4 minutes ($((t1 - t0)) s)" test $((t1 - t0)) -le 240
crash_off hello
# (kept, the wait under test: the real timer announces the recovery)
until_ 300 seen resolved hello down
t2=$(date +%s)
echo "time to announce recovery: $((t2 - t1)) s" >> "$E/numbers"
check "21b recovery announced within 3 minutes ($((t2 - t1)) s)" test $((t2 - t1)) -le 180

alerts_done
