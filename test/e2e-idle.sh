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

# a second idle app, without a worker: created with no daemon-reload (with 200 apps one costs PID 1
# 4.5-8 s), and its journald stops while it is idle (a worker keeps zz's: it logs there)
cp -R "$ROOT/examples/hello" "$W/zy"; printf 'app = zy\nidle_stop = 15s\n' >> "$W/zy/tando.conf"
reloads() { "$SSH" "journalctl _PID=1 --since @$1 --no-pager -o cat" 2> /dev/null | grep -c '^Reloading finished'; }
t0=$("$SSH" 'date +%s'); sleep 1
(cd "$W/zy" && "$R" up --yes > "$E/up-zy.log" 2>&1); rc=$?
nr=$(reloads "$t0")
check "I20 a new app is created and deployed without a daemon-reload of systemd ($nr)" eval '[ $rc = 0 ] && [ "$nr" = 0 ] && [ "$(curl -s -o /dev/null -w "%{http_code}" --max-time 30 "$(t_url zy)")" = 200 ]'
jd() { "$SSH" "systemctl show -P ActiveState systemd-journald@tando-$1.service" 2> /dev/null; }

# ---- idle ----------------------------------------------------------------------------------------
check "I4 without requests it stops (within idle_stop + 60 s)" t_until 75 is_idle
check "I4b only the web process stops: its worker runs on" "$SSH" 'systemctl -q is-active tando-zz_worker-tick.service'
zy_quiet() { [ "$("$SSH" 'systemctl show -P ActiveState tando-zy.service')" = inactive ] && [ "$(jd zy)" = inactive ]; }
check "I21 an idle app without a worker: its journald stops too (a minute after the app)" t_until 150 zy_quiet
check "I22 an idle app with a worker keeps its journald (the worker logs to it)" eval '[ "$(jd zz)" = active ]'
starts() { "$R" logs -a zy -H test -n 1000 --grep 'hello v1 on' 2> /dev/null | grep -c 'hello v1 on'; }
n0=$(starts)
r=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$(t_url zy)")
woke_logged() { [ "$(jd zy)" = active ] && [ "$(starts)" -gt "$n0" ]; }
check "I23 the first request wakes it, its journald starts again and has the app's start line" eval '[ "$r" = 200 ] && t_until 10 woke_logged'
# every wake is a start of the unit, and its start limit (5 in 60 s, for crash loops) counted
# them: the sixth wake in a minute was refused (start-limit-hit, then the wake socket's trigger
# limit: 502 and the down page). Seven idle stops and wakes in a row (stopped as an idle stop
# stops it), each right after the last
settled_zy() { [ "$("$SSH" "systemctl show -P ActiveState tando-zy.service")" = inactive ]; }
wakes="" k=0
while [ $k -lt 7 ]; do
  k=$((k + 1))
  "$SSH" 'sudo systemctl stop tando-zy.service' > /dev/null 2>&1; t_until 15 settled_zy > /dev/null
  wakes="$wakes$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$(t_url zy)") "
done
check "I24 an idle app woken 7 times within a minute answers every time (got $wakes)" eval '[ "$wakes" = "200 200 200 200 200 200 200 " ]'

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

# ---- a wake socket that is gone (it failed after starts that failed) comes back -----------------
"$SSH" 'sudo systemctl stop tando-zz_wake.socket' > /dev/null 2>&1
sock_up() { "$SSH" 'systemctl -q is-active tando-zz_wake.socket && test -S /run/tando-wake/zz.sock'; }
"$SSH" 'sudo systemctl start tando-watch.service' > /dev/null 2>&1
check "I14 the monitor's run starts a wake socket that is gone again, and the app answers" eval 't_until 30 sock_up && [ "$(code)" = 200 ]'

# ---- cold_timeout: a visitor waits at most that long for a slow start, then gets a 503 -----------
cp -R "$ROOT/examples/hello" "$W/zc"
printf 'app = zc\nidle_stop = 5s\ncold_timeout = 2\n' >> "$W/zc/tando.conf"
(cd "$W/zc" && "$R" up --yes > "$E/up-zc.log" 2>&1 && "$R" env set SLOW_START=6 > "$E/env-zc.log" 2>&1); rc=$?
zc_idle() { [ "$("$SSH" 'systemctl show -P ActiveState tando-zc.service' 2> /dev/null)" = inactive ]; }
check "I15 an idle app that starts in 6 s (cold_timeout = 2) deploys and goes idle" eval '[ $rc = 0 ] && t_until 75 zc_idle'
r=$(curl -s -D "$E/zc.h" -o "$E/zc.body" -w '%{http_code} %{time_total}' --max-time 30 "$(t_url zc)")
echo "cold start over cold_timeout 2 s: $r" >> "$E/numbers"
check "I16 its first request gets a 503 \"waking up\" with Retry-After within about cold_timeout, not after its start" eval '
  [ "${r%% *}" = 503 ] && awk -v t="${r#* }" "BEGIN { exit !(t < 5) }" && grep -qi "^retry-after: 5" "$E/zc.h" && grep -q "zc is waking up" "$E/zc.body"'
zc_ok() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$(t_url zc)")" = 200 ]; }
check "I17 and the app goes on starting: a later request is answered" t_until 20 zc_ok

# ---- not for a static site, and destroy ----------------------------------------------------------
cp -R "$ROOT/examples/site" "$W/st"; printf 'app = zst\nidle_stop = 10m\n' >> "$W/st/tando.conf"
(cd "$W/st" && "$R" up --yes > "$E/up3.log" 2>&1); rc=$?
check "I12 idle_stop on a static site is refused, with why" eval '[ $rc != 0 ] && grep -q "not for a static site" "$E/up3.log"'
# (the socket was there before: a destroy that found nothing proves nothing)
gone() { ! "$SSH" 'test -e /run/tando-wake/zz.sock || ls /etc/systemd/system/ /etc/systemd/system/sockets.target.wants/ | grep -q zz_wake'; }
if gone; then fail "I13 destroy removes the wake socket and its units (there was none to remove)"
else
  "$R" destroy -a zz -H test --yes > "$E/destroy.log" 2>&1
  check "I13 destroy removes the wake socket and its units" gone
fi

cat "$E/numbers" >&2
t_done
