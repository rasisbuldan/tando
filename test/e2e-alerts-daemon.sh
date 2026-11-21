#!/bin/bash
# End-to-end test of tando alerts, the part about tandod (test/e2e-alerts.sh has the bulk): 29,
# tandod running after setup, killed in the middle of a run, stopped and panicking (the timer's
# fallback takes over within two minutes: the real timer), an upgrade from a timer-only host;
# then 27h and 27i, the dead man's check in a local time zone, on what those leave behind.
# One PASS/FAIL line per check; exits non-zero on any failure. Takes about 5 minutes.
# Helpers, fixtures and environment variables: test/alerts-lib.sh.
#
# Usage: test/e2e-alerts-daemon.sh [--no-reset]
#   server by default: tando-test-alerts-daemon, ssh 2306, http 8306
#   TANDO_TEST_NO_DAEMON=1   section 29 is skipped (27h and 27i run on the one-shot path)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
. "$ROOT/test/alerts-lib.sh"
alerts_server tando-test-alerts-daemon 2306 8306 2
t_init e2e-alerts-daemon
alerts_setup "$@"
alerts_fixtures_ok || { echo "FAIL fixtures (the timer or the notifiers: e2e-alerts 1a and 1b check them)"; exit 1; }

# The settings section 29 always ran with (what e2e-alerts has set when it gets there):
# load=off: in a container /proc/loadavg is the whole VM's (other containers' work, on 1 pinned CPU)
# sample_seconds=0: each run below stands for a minute (a run counts once a minute otherwise)
# deploy_grace=0: the apps were deployed a moment ago; boot_grace=0: so was the server (there it
# had been up for longer than the default 180 s)
srv 'sudo systemctl stop tando-watch.timer'
aset load=off sample_seconds=0 deploy_grace=0 boot_grace=0
wruns 2

# ---- 29. tandod: running after setup, killed in the middle of a run, stopped, an upgrade ----
if [ "${TANDO_TEST_NO_DAEMON:-}" = 1 ]; then
  echo "SKIP 29 tandod: TANDO_TEST_NO_DAEMON=1"
else
check "29a tandod runs after host setup; its socket is root 600 in a root 700 directory" \
  srv 'systemctl -q is-active tandod && [ "$(sudo stat -c "%a %U" /run/tandod /run/tandod/tandod.sock | tr "\n" " ")" = "700 root 600 root " ]'
check "29b a user that is not root cannot reach the socket; tando-watch brief works without it" \
  srv '! ls /run/tandod > /dev/null 2>&1 && /opt/tando/bin/tando-watch brief > /dev/null'
# an older tando's unit (MemoryMax=64M, where tandod's page cache was evicted every minute):
# host setup rewrites it, reloads systemd and restarts tandod
srv 'sudo sed -i "s/^MemoryMax=.*/MemoryMax=64M/" /etc/systemd/system/tandod.service && sudo systemctl daemon-reload &&
  sudo systemctl restart tandod'
p64=$(srv 'systemctl show -P MainPID tandod')
"$R" host setup t > "$E/memmax.out" 2>&1 || cat "$E/memmax.out" >&2
check "29p host setup raises an older tandod unit's MemoryMax=64M to 160M (unit file, systemd, a new process)" \
  srv 'grep -qx MemoryMax=160M /etc/systemd/system/tandod.service && [ "$(systemctl show -P MemoryMax tandod)" = 167772160 ] &&
    systemctl -q is-active tandod && [ "$(systemctl show -P MainPID tandod)" != '"$p64"' ]'
srv 'sudo systemctl stop tando-watch.timer'; until_ 60 idle
# kill -9 in the middle of a run: hog/health fires in one run; "hook" answers at once, "slowd" never
# (the run waits for it, 15 s), and tandod is killed while it waits
printf 'http://127.0.0.1:9999/slowd/S3CR3Tslowd\n' | "$R" alerts notifier add slowd webhook > /dev/null 2>&1
srv 'curl -s http://127.0.0.1:9999/ctl/fail/slowd > /dev/null'
aset hog.health_fails=1; wrun; mark
get hog /sick > /dev/null
p0=$(srv 'systemctl show -P MainPID tandod')
# (kept: 6 s into the run tandod is waiting for slowd, 15 s: the kill lands in the middle of it)
srv 'sudo systemctl start --no-block tando-watch.service'; sleep 6
srv 'sudo systemctl kill -s KILL tandod'
newpid() { [ "$(srv 'systemctl show -P MainPID tandod')" != "$p0" ] && srv 'systemctl -q is-active tandod'; }
until_ 30 newpid
check "29c killed with SIGKILL in the middle of a run: systemd restarts tandod" srv 'systemctl -q is-active tandod && sudo test -S /run/tandod/tandod.sock'
srv 'curl -s http://127.0.0.1:9999/ctl/ok/slowd > /dev/null'
wruns 2
slowd() { srv "sudo tail -n +$((MARK + 1)) /root/recv.log | grep '\"path\":\"/slowd/' | grep -c '\"firing hog health\"'"; }
check "29d no notification repeated or lost: hook got the firing once, slowd at least once (it had it but never answered)" \
  eq "$(nev firing hog health)/$(slowd | sed 's/^[1-9][0-9]*$/n/')" 1/n
get hog /well > /dev/null; wruns 3; aset hog.health_fails=
"$R" alerts notifier rm slowd > /dev/null 2>&1
# stopped: the timer's fallback runs the checks within 2 minutes
srv 'sudo systemctl stop tandod; sudo systemctl start tando-watch.timer'
f0=$(srv 'systemctl show -P ExecMainStartTimestampMonotonic tando-watch-fallback.service')
check "29e tandod stopped: its socket and its active mark are gone" srv '! sudo test -e /run/tandod/tandod.sock && ! sudo test -e /run/tandod/active'
# (kept, the wait under test: the real timer starts the fallback at its next minute)
T_UNTIL_STEP=5 until_ 130 eval '[ "$(srv "systemctl show -P ExecMainStartTimestampMonotonic tando-watch-fallback.service")" != "$f0" ]'
check "29f ... and the timer's fallback ran the checks within 2 minutes" \
  sh -c "[ \"\$($SSHX 'systemctl show -P ExecMainStartTimestampMonotonic tando-watch-fallback.service')\" != '$f0' ]"
"$R" doctor > "$E/doctor-nod.out" 2>&1
check "29g doctor: tandod not running is a warning, the checks still run" \
  sh -c "grep -q 'tandod .*not running' '$E/doctor-nod.out' && grep -q 'alerts .*checks ran' '$E/doctor-nod.out'"
# a run of the checks that panics: a tandod built with -tags tandotest (the test suites' build,
# never shipped) panics in every tick with TANDOD_TEST_PANIC=1. It must keep running, hand the
# checks to the timer's fallback within 2 minutes, say so in doctor and through the notifiers
c=$(srv 'uname -m'); case $c in x86_64) c=amd64;; *) c=arm64;; esac
(cd "$ROOT/srv" && CGO_ENABLED=0 GOOS=linux GOARCH=$c GOTOOLCHAIN=local go build -tags tandotest -o "$E/tandod-test" ./cmd/tandod) ||
  fail "29k (could not build the test tandod)"
srv 'sudo install -m 755 /dev/stdin /opt/tando/bin/tandod.test' < "$E/tandod-test"
mark   # (before the panic: the fallback may run in the very minute of it and send the notice then)
srv 'sudo mkdir -p /run/systemd/system/tandod.service.d && printf "[Service]\nExecStart=\nExecStart=/opt/tando/bin/tandod.test\nEnvironment=TANDOD_TEST_PANIC=1\n" |
  sudo tee /run/systemd/system/tandod.service.d/zz-test-panic.conf > /dev/null && sudo systemctl daemon-reload && sudo systemctl start tandod'
# (kept, both waits under test: tandod's own tick at the minute panics, then the real timer's
# fallback takes over at the next one)
until_ 60 eval '[ "$(srv "systemctl show -P StatusText tandod" | grep -c "1 panics")" = 1 ]'   # the first tick of the minute
f1=$(srv 'systemctl show -P ExecMainStartTimestampMonotonic tando-watch-fallback.service')
T_UNTIL_STEP=5 until_ 130 eval '[ "$(srv "systemctl show -P ExecMainStartTimestampMonotonic tando-watch-fallback.service")" != "$f1" ]'
check "29k a tick that panics: tandod keeps running, the timer's fallback runs the checks within 2 minutes" \
  sh -c "$SSHX 'systemctl -q is-active tandod && ! sudo test -e /run/tandod/active' &&
    [ \"\$($SSHX 'systemctl show -P ExecMainStartTimestampMonotonic tando-watch-fallback.service')\" != '$f1' ]"
until_ 60 idle
"$R" doctor > "$E/doctor-panic.out" 2>&1
# (doctor's detail wraps: each piece on its own)
check "29l doctor warns: tandod had a panic and handed the checks to the timer" \
  sh -c "grep -q 'tandod .*warn .*problems: 1 panics' '$E/doctor-panic.out' && grep -q 'handed the checks to the timer' '$E/doctor-panic.out'"
check "29m ... and the owner was told through the notifiers: the monitor alert fires (FIRING host/monitor ... panic)" \
  sh -c "$SSHX \"sudo tail -n +$((MARK + 1)) /root/recv.log\" | grep '\"path\":\"/hook/' | grep -q 'FIRING host/monitor: tandod handed the checks to the timer .* (panic: tandod test panic'"
srv 'sudo rm -f /run/systemd/system/tandod.service.d/zz-test-panic.conf /opt/tando/bin/tandod.test; sudo systemctl daemon-reload; sudo systemctl restart tandod'
# an upgrade from a host with the timer only (the shell version's units, no tandod): a firing alert
# stays firing and is not sent again; history and settings are kept
srv 'sudo systemctl stop tando-watch.timer'; until_ 60 idle
aset disk_pct=1; wruns 2
srv 'sudo tee /root/tando-watch.legacy > /dev/null' < "$ROOT/server/legacy/tando-watch"
srv 'sudo systemctl disable -q --now tandod; sudo rm -f /etc/systemd/system/tandod.service /opt/tando/bin/tandod
  sudo bash /root/tando-watch.legacy install > /dev/null; sudo systemctl stop tando-watch.timer; sudo bash /root/tando-watch.legacy run'
hlines() { srv 'sudo cat /var/lib/tando/watch/history.tsv | wc -l'; }
h0=$(hlines); mark
check "29h (the shell version's units: no tandod, ExecStartPre in tando-watch.service)" \
  srv '! systemctl cat tandod > /dev/null 2>&1 && systemctl cat tando-watch.service | grep -q ExecStartPre'
"$R" host setup t > "$E/upgrade.out" 2>&1 || cat "$E/upgrade.out" >&2
srv 'sudo systemctl stop tando-watch.timer'; wruns 2
# lint: allow RL02 shasum first (macOS); sha256sum only where there is no shasum
sum256() { { shasum -a 256 "$1" 2> /dev/null || sha256sum "$1"; } | cut -d' ' -f1; }
c29n() { [ "$(srv 'sudo sha256sum /proc/$(systemctl show -P MainPID tandod)/exe' | cut -d' ' -f1)" = "$(sum256 "$ROOT/dist/server/linux-$c/tandod")" ]; }
check "29n upgraded: the tandod running is the binary host setup installed (the tree's, for this CPU)" c29n
p1=$(srv 'systemctl show -P MainPID tandod'); "$R" host setup t > /dev/null 2>&1
check "29o host setup again, nothing changed: tandod is not restarted" test "$(srv 'systemctl show -P MainPID tandod')" = "$p1"
check "29i upgraded: tandod runs, the timer starts the fallback unit" \
  srv 'systemctl -q is-active tandod && systemctl cat tando-watch.timer | grep -q "^Unit=tando-watch-fallback.service"'
check "29j ... the firing alert is still firing and was not sent again; history kept" \
  eq "$(st _host.disk.st)/$(nev firing host disk)/$(hlines | awk -v h="$h0" '{ print ($1 >= h) }')" firing/0/1
aset disk_pct=; wruns 2
srv 'sudo systemctl start tando-watch.timer'
fi

srv 'sudo systemctl start tando-watch.timer'
# a run on record, as the timer starts it (an event, not a wait for the minute: 27i is about
# reading its age; that the timer starts it within two minutes is 29f and 29k)
srv 'sudo systemctl start tando-watch-fallback.service'
sleep 2; until_ 60 idle   # (a run that is starting has no ExecMainStartTimestamp yet)
# (the timer's: tando-watch.service, referenced by nothing now, is unloaded after a run)
check "27h systemd prints its timestamps in a local zone here (TZ=WIB-7)" \
  srv 'TZ=WIB-7 systemctl show -P ActiveEnterTimestamp tando-watch.timer | grep -q WIB'
# (the daemon tests above leave tandod just restarted and degraded, with no run on record yet;
# should the run started above have been skipped, the timer's fallback runs within two minutes)
until_ 150 srv '/opt/tando/bin/tando-watch doctor | grep -q "checks ran"'
srv 'TZ=WIB-7 /opt/tando/bin/tando-watch doctor; systemctl show -p StatusText,ActiveState tandod; systemctl show -p ActiveState,Result,ExecMainStartTimestampMonotonic tando-watch.service tando-watch-fallback.service; cat /proc/uptime' >&2
check "27i the dead man's check still reads the last run's age under that zone" \
  srv 'TZ=WIB-7 /opt/tando/bin/tando-watch doctor | grep -q "checks ran"'
alerts_done
