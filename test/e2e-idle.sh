#!/bin/bash
# End-to-end test of scale to zero (idle_stop = <time> in tando.conf): the app stops after that
# long without a connection, the next request starts it (Caddy -> the app's wake socket ->
# systemd-socket-proxyd -> the app), the monitor neither wakes it nor calls it down, a deploy of an
# idle app goes live, and destroy removes the wake units.
#
#   test/e2e-idle.sh [--reset]     --reset: recreate the server first (only one this suite owns)
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT. About 3 minutes.
# Output: PASS/FAIL lines (docs/TESTING.md), summary, exit status. Cold starts go to $E/numbers.
set -u
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init idle
W=$E/w

if [ "${1:-}" = --reset ]; then t_server_up --reset || exit 1; else t_server_up || exit 1; fi
t_host_add test
"$R" host setup test public_port="$T_HTTP_PORT" >&2 || exit 1
mkdir -p "$W"; cp -R "$ROOT/examples/hello" "$W/zz"
printf 'app = zz\nidle_stop = 15s\nworker.tick = node w.js\n' >> "$W/zz/tando.conf"
echo 'setInterval(() => {}, 1000);' > "$W/zz/w.js"

state() { "$SSH" 'systemctl show -P ActiveState tando-zz.service' 2> /dev/null; }
# idle: the unit exists (a file, loaded) and is not running, while its wake socket listens
is_idle() { [ "$(state)" = inactive ] && "$SSH" 'test -f /etc/systemd/system/tando-zz.service && systemctl -q is-active tando-zz_wake.socket'; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$(t_url zz)"; }
# cold: one request to the idle app; prints its HTTP code and seconds
cold() { curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 30 "$(t_url zz)"; }

(cd "$W/zz" && "$R" up --yes > "$E/up1.log" 2>&1); rc=$?
check "I1 an app with idle_stop deploys and answers" eval '[ $rc = 0 ] && [ "$(code)" = 200 ]'
check "I2 its unit is not started at boot (no multi-user link), its wake socket is enabled" eval '
  "$SSH" "systemctl is-enabled tando-zz_wake.socket" | grep -qx enabled &&
  ! "$SSH" "test -e /etc/systemd/system/multi-user.target.wants/tando-zz.service"'
check "I3 Caddy proxies to the wake socket" "$SSH" 'sudo grep -q "reverse_proxy unix//run/tando-wake/zz.sock" /etc/caddy/tando/zz.caddy'

# ---- idle ----------------------------------------------------------------------------------------
check "I4 without requests it stops (within idle_stop + 60 s)" t_until 75 is_idle
check "I4b only the web process stops: its worker runs on" "$SSH" 'systemctl -q is-active tando-zz_worker-tick.service'
check "I5 ls says idle, not down" eval '"$R" ls -H test 2> /dev/null | grep -w zz | grep -qw idle'
# a monitor run and recovery (both run every minute) leave it idle and raise no down alert
"$SSH" 'sudo systemctl start tando-watch.service; sudo /opt/tando/bin/tando-agent recover-all' > /dev/null 2>&1
check "I6 the monitor and recover-all do not wake it" is_idle
check "I7 no down or health alert for an idle app" eval '[ -z "$("$SSH" "sudo grep -E \"^zz\\.(down|health)\\.st=(pending|firing)\" /var/lib/tando/watch/state")" ]'

# ---- wake ----------------------------------------------------------------------------------------
: > "$E/numbers"
r=$(cold); echo "cold start (Node hello) 1: $r" >> "$E/numbers"
check "I8 the first request to an idle app is answered (200) and starts it" eval '[ "${r%% *}" = 200 ] && [ "$(state)" = active ]'
check "I9 the next requests are answered too" eval '[ "$(code)$(code)$(code)" = 200200200 ]'

# ---- deploy while idle ---------------------------------------------------------------------------
t_until 75 is_idle > /dev/null
echo 2 > "$W/zz/VERSION"
(cd "$W/zz" && "$R" up --yes > "$E/up2.log" 2>&1); rc=$?
check "I10 a deploy of an idle app goes live (the new version answers)" eval '[ $rc = 0 ] && curl -s --max-time 30 "$(t_url zz)" | grep -q "hello v2"'
check "I11 and the app goes idle again afterwards" t_until 75 is_idle

# ---- not for a static site, and destroy ----------------------------------------------------------
cp -R "$ROOT/examples/site" "$W/st"; printf 'app = zst\nidle_stop = 10m\n' >> "$W/st/tando.conf"
(cd "$W/st" && "$R" up --yes > "$E/up3.log" 2>&1); rc=$?
check "I12 idle_stop on a static site is refused, with why" eval '[ $rc != 0 ] && grep -q "not for a static site" "$E/up3.log"'
had=0; "$SSH" 'test -S /run/tando-wake/zz.sock' && had=1
"$R" destroy -a zz -H test --yes > "$E/destroy.log" 2>&1
check "I13 destroy removes the wake socket and its units" eval '[ $had = 1 ] && ! "$SSH" "test -e /run/tando-wake/zz.sock || ls /etc/systemd/system/ | grep -q zz_wake || ls /etc/systemd/system/sockets.target.wants/ | grep -q zz_wake"'

cat "$E/numbers" >&2
t_done
