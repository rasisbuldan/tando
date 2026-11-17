#!/bin/bash
# End-to-end test of tando alerts (server/tando-watch, lib/cmd-alerts.sh) against a clean test
# container. One PASS/FAIL line per check; exits non-zero on any failure. Takes about 15 minutes
# (two parts wait for the real once-a-minute timer and one restarts the container).
#
# Notifications go to a receiver inside the container (Node, 127.0.0.1:9999); nothing leaves
# this machine. Most checks stop the timer and start the check run by hand (`systemctl start
# tando-watch.service`, exactly what the timer does) so each sample is deterministic; the timer
# itself is tested for detection time and for surviving a restart.
#
# Usage: test/e2e-alerts.sh [--no-reset]
#   TANDO_TREE=<dir with bin/ lib/ server/>   the tando to test (default: this repository)
#   TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT   which test container
#     (defaults tando-test-alerts, 2303, 8303). The container is reset (and, in check 22,
#     restarted) only when it is that default, does not exist yet, or TANDO_TEST_OWNED=1;
#     otherwise the suite reuses it and only removes its own apps (hello, hog).
#   T_WORK=<dir>   work directory (default test/.e2e-alerts-<server>)
#   TANDO_TEST_NO_DAEMON=1   tandod stopped and disabled after every host setup: the checks run as
#     the one-shot (the fallback path of a host without the daemon); section 29 is skipped
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
. "$ROOT/test/lib.sh"   # t_until (this suite keeps its own pass/fail/check, defined below)
TREE=${TANDO_TREE:-$ROOT}
export TANDO_TEST_NAME=${TANDO_TEST_NAME:-tando-test-alerts}
export TANDO_TEST_SSH_PORT=${TANDO_TEST_SSH_PORT:-2303} TANDO_TEST_HTTP_PORT=${TANDO_TEST_HTTP_PORT:-8303}
E=${T_WORK:-$ROOT/test/.e2e-alerts-$TANDO_TEST_NAME} R=$TREE/bin/tando
W=$E/w
OWNED=0
if [ "${TANDO_TEST_OWNED:-}" = 1 ] || [ "$TANDO_TEST_NAME" = tando-test-alerts ] ||
   ! docker container inspect "$TANDO_TEST_NAME" > /dev/null 2>&1; then OWNED=1; fi
export TANDO_CONFIG_DIR=$E/cfg TANDO_COLOR=never COLUMNS=100
export TANDO_SOAK=${TANDO_SOAK:-2} TANDO_WAIT=1   # a short soak (30 s by default) keeps the suite fast
HP=$TANDO_TEST_HTTP_PORT
SSHX=$ROOT/test/server/ssh.sh
FAILS=0

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local n=$1; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
not() { ! "$@"; }
log() { echo "---- $*" >&2; }
srv() { "$SSHX" "$@"; }
get() { curl -s -m 5 "http://$1.localhost:$HP$2"; }
wrun() { srv 'sudo systemctl start tando-watch.service'; }              # one check run, as the timer does
wruns() { local i; for ((i = 0; i < $1; i++)); do wrun; done; }
st() { srv "sudo sed -n 's/^$1=//p' /var/lib/tando/watch/state"; }      # state of <app>.<check>.st
aset() { "$R" alerts set "$@" > /dev/null 2>&1 || fail "tando alerts set $*"; }
# notification counting, from the webhook notifier "hook" (the others are compared at the end)
MARK=0
mark() { MARK=$(srv 'sudo cat /root/recv.log 2>/dev/null | wc -l' | tr -d ' '); }
since_mark() { srv "sudo tail -n +$((MARK + 1)) /root/recv.log | grep '\"path\":\"/hook/'"; }
nev() { since_mark | grep -o "\"$1 $2 $3\"" | wc -l | tr -d ' '; }      # state app check
nmsg() { since_mark | grep -c . | tr -d ' '; }                          # messages to hook
eq() { [ "$1" = "$2" ] || { echo "     expected $2, got $1" >&2; return 1; }; }
until_() { t_until "$@"; }
wrun_and() { wrun; "$@"; }                                               # one run, then a condition
# no run going on: neither the one-shot units nor a tick of tandod (its status text says "ticking")
idle() { [ "$(srv 'systemctl show -P ActiveState tando-watch.service tando-watch-fallback.service; systemctl show -P StatusText tandod' |
  grep -c 'activating\|ticking')" = 0 ]; }
# dtick: the epoch of tandod's last tick (0: none, or tandod not running)
dtick() { srv 'systemctl show -P StatusText tandod' | sed -n 's/.*last tick \([0-9]*\).*/\1/p' | grep . || echo 0; }
nrestarts() { srv "systemctl show -P NRestarts tando-$1"; }
# restarted <app> <count before>: systemd restarted the app since then and it answers its health again
restarted() { [ "$(nrestarts "$1")" -gt "$2" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 "http://$1.localhost:$HP/health")" = 200 ]; }
firing() { [ "$(st "$1")" = firing ]; }
seen() { [ "$(nev "$1" "$2" "$3")" = "${4:-1}" ]; }                       # for until_

if [ "${1:-}" != --no-reset ] && [ $OWNED = 1 ]; then
  log "resetting test server $TANDO_TEST_NAME (1 CPU, 2 GB like the real VPS)"
  TANDO_TEST_DOCKER_ARGS="--cpus 1 --cpuset-cpus 0 --memory 2g" "$ROOT/test/server/up.sh" --reset >&2 || exit 1
else
  log "reusing test server $TANDO_TEST_NAME (not ours to reset)"
  "$ROOT/test/server/up.sh" >&2 || exit 1
fi
case $E in /?*/?*) rm -rf "${E:?}";; *) echo "refusing work dir $E" >&2; exit 2;; esac
mkdir -p "$W"
cp -R "$TREE/examples/hello" "$TREE/examples/site" "$W/"

# ---- fixtures: the receiver (+ a fake sendmail) in the container, and the "hog" test app ----
cat > "$E/recv.js" <<'EOF'
// local notification receiver; logs one JSON line per request to /root/recv.log (root 600),
// with secret markers redacted. /ctl/fail/<word>, /ctl/ok/<word>: requests whose path contains
// <word> answer 500 (or never, when the word starts with "slow").
const http = require('http'), fs = require('fs');
const bad = new Set();
const mk = new RegExp('S3' + 'CR3T[A-Za-z0-9_-]*', 'g');   // no marker in this file
const red = s => s.replace(mk, '<S>');
http.createServer((req, res) => {
  let body = '';
  req.on('data', d => body += d);
  req.on('end', () => {
    const m = req.url.match(/^\/ctl\/(fail|ok)\/(.+)$/);
    if (m) { m[1] === 'fail' ? bad.add(m[2]) : bad.delete(m[2]); res.end('ok\n'); return; }
    const hit = [...bad].find(w => req.url.includes(w));
    const rec = { t: Date.now() / 1000, path: red(req.url), had_secret: req.url.includes('S3' + 'CR3T'),
      title: req.headers['title'] || '', auth: red(req.headers['authorization'] || ''),
      status: hit ? (hit.startsWith('slow') ? 'hang' : 500) : 200, body: red(body) };
    try { const j = JSON.parse(body); if (j.events) rec.ev = j.events.map(e => `${e.state} ${e.app} ${e.check}`); } catch (e) {}
    fs.appendFileSync('/root/recv.log', JSON.stringify(rec) + '\n', { mode: 0o600 });
    if (hit && hit.startsWith('slow')) return;
    res.writeHead(hit ? 500 : 200, { 'content-type': 'application/json' });
    res.end(hit ? '{"ok":false}' : '{"ok":true}');
  });
}).listen(9999, '127.0.0.1');
EOF
mkdir -p "$W/hog"
cat > "$W/hog/server.js" <<'EOF'
// hog: test app. /health is 200 unless /sick was called (until /well). /grow?mb=N keeps N MB
// more allocated; /free drops it; /exit exits with status 1.
const http = require('http');
let sick = false, keep = [];
http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  const say = (c, t) => { res.writeHead(c, { 'content-type': 'text/plain' }); res.end(t + '\n'); };
  switch (u.pathname) {
    case '/health': return say(sick ? 500 : 200, sick ? 'sick' : 'ok');
    case '/sick': sick = true; return say(200, 'now sick');
    case '/well': sick = false; return say(200, 'now well');
    case '/grow': { const n = Number(u.searchParams.get('mb') || 10);
      for (let i = 0; i < n; i++) keep.push(Buffer.alloc(1048576, 1));
      return say(200, 'kept ' + keep.length + ' MB'); }
    case '/free': keep = []; if (global.gc) global.gc(); return say(200, 'freed');
    case '/exit': say(200, 'bye'); return setTimeout(() => process.exit(1), 50);
    case '/shm': { const fs = require('fs'), mb = Buffer.alloc(1048576, 1);   // 1 MB at a time
      fs.writeFileSync('/dev/shm/hog', '');
      for (let i = 0; i < Number(u.searchParams.get('mb') || 10); i++) fs.appendFileSync('/dev/shm/hog', mb);
      return say(200, 'shm written'); }
    case '/shm-free': try { require('fs').unlinkSync('/dev/shm/hog'); } catch (e) {} return say(200, 'shm freed');
    default: return say(200, 'hog');
  }
}).listen(Number(process.env.PORT), '127.0.0.1');
process.on('SIGTERM', () => process.exit(0));
EOF
printf 'app = hog\nrecipe = node\nstart = node --expose-gc server.js\nhealth = /health\nmemory = 96M\nhealth_timeout = 15\ndata = data\n' > "$W/hog/tando.conf"
srv 'sudo tee /root/recv.js > /dev/null && printf "[Unit]\nDescription=alerts test receiver\n[Service]\nExecStart=/usr/local/bin/node /root/recv.js\nUMask=0077\n[Install]\nWantedBy=multi-user.target\n" | sudo tee /etc/systemd/system/testrecv.service > /dev/null &&
  sudo install -d -m 700 /var/lib/testmail && printf "#!/bin/sh\ncat > /var/lib/testmail/mail.\$\$\n" | sudo tee /usr/sbin/sendmail > /dev/null && sudo chmod 755 /usr/sbin/sendmail &&
  sudo systemctl daemon-reload && sudo systemctl enable -q --now testrecv' < "$E/recv.js" || { echo "FAIL fixtures"; exit 1; }

# ---- 1. setup installs the timer; apps; notifiers (secrets on stdin) ----
"$R" host add t vmadmin@127.0.0.1 --port "$TANDO_TEST_SSH_PORT" --key "$ROOT/test/server/id_test" --yes > /dev/null 2>&1 ||
  { echo "FAIL host add (the normal path: host key shown and trusted with --yes)"; exit 1; }
"$R" host setup t public_port=$HP > "$E/setup.out" 2>&1 || { cat "$E/setup.out"; echo "FAIL host setup"; exit 1; }
# nodaemon: with TANDO_TEST_NO_DAEMON=1, tandod off (host setup enables and starts it every time)
nodaemon() { [ "${TANDO_TEST_NO_DAEMON:-}" = 1 ] && srv 'sudo systemctl disable -q --now tandod'; true; }
nodaemon
if [ $OWNED = 0 ]; then   # a reused server: start from none of our apps and no alert state
  for a in hello hog site; do echo $a | "$R" destroy --purge -a $a > /dev/null 2>&1; done
  srv 'sudo rm -rf /var/lib/tando/watch /opt/tando/alerts.d /opt/tando/alerts.conf; sudo truncate -s0 /root/recv.log 2>/dev/null; true'
fi
(cd "$W/hello" && "$R" up > "$E/up-hello.out" 2>&1) && (cd "$W/hog" && "$R" up > "$E/up-hog.out" 2>&1) &&
  (cd "$W/site" && "$R" up > "$E/up-site.out" 2>&1) ||
  { tail -5 "$E"/up-*.out; echo "FAIL up"; exit 1; }
"$R" alerts enable > /dev/null 2>&1    # idempotent; a host set up before alerts existed needs it
check "1a host setup + alerts enable: tando-watch.timer enabled and active" \
  test "$(srv 'systemctl is-enabled tando-watch.timer; systemctl is-active tando-watch.timer' | tr '\n' ' ')" = "enabled active "
"$R" alerts > "$E/alerts-empty.out" 2>&1
check "1c no notifier yet: tando alerts says the checks run and gives one line per notifier type, ntfy first" \
  sh -c "grep -q 'already watching every app' '$E/alerts-empty.out' &&
    grep -n 'notifier add' '$E/alerts-empty.out' | head -1 | grep -q 'phone ntfy'"
{
  printf 'http://127.0.0.1:9999/hook/S3CR3Thook1\n' | "$R" alerts notifier add hook webhook
  printf 'http://127.0.0.1:9999/slack/S3CR3Tslack1\n' | "$R" alerts notifier add sl slack
  printf 'S3CR3Ttg:abc\n-100123\n' | "$R" alerts notifier add tg telegram api=http://127.0.0.1:9999/tg
  printf 'http://127.0.0.1:9999/ntfy/S3CR3Tntfy1\nS3CR3Tntfytok\n' | "$R" alerts notifier add nt ntfy
  printf 'ops@example.com\n' | "$R" alerts notifier add mail email
  printf 'http://127.0.0.1:9999/broken/S3CR3Tbroken1\n' | "$R" alerts notifier add broken webhook
  printf 'http://127.0.0.1:9999/hb/S3CR3Thb1\n' | "$R" alerts heartbeat
} > "$E/notifiers.out" 2>&1
check "1b five notifier types and a heartbeat added (secrets on stdin)" test "$(grep -c '^added notifier' "$E/notifiers.out")" = 6
srv 'curl -s http://127.0.0.1:9999/ctl/fail/broken > /dev/null'

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
# a crash loop from outside the app: every start fails (tando env set refuses an env the app
# crashes with, since its pre-check: it can no longer make one). A runtime drop-in, gone at reboot
crash_on() { srv "sudo sh -c 'mkdir -p /run/systemd/system/tando-$1.service.d &&
  printf \"[Service]\\nExecStartPre=/bin/sh -c \\\"exit 3\\\"\\n\" > /run/systemd/system/tando-$1.service.d/zz-test-crash.conf &&
  systemctl daemon-reload && systemctl restart tando-$1'" > /dev/null 2>&1; true; }
crash_off() { srv "sudo sh -c 'rm -f /run/systemd/system/tando-$1.service.d/zz-test-crash.conf; systemctl daemon-reload;
  systemctl reset-failed tando-$1; systemctl restart tando-$1'" > /dev/null 2>&1; true; }
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
base=$(srv "sudo awk '/^(anon|shmem) / { s += \$2 } END { print int(s / 1048576) }' /sys/fs/cgroup/tando.slice/tando-hog.slice/tando-hog.service/memory.stat /sys/fs/cgroup/system.slice/tando-hog.service/memory.stat 2> /dev/null")
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
log "waiting for oom_quiet (1 min in this test, 30 in production)"
T_UNTIL_STEP=5 until_ 120 wrun_and seen resolved hog oom
check "9c OOM: resolves once after oom_quiet without new kills" eq "$(nev resolved hog oom)" 1
check "9d one OOM restart is not a restarts alert" eq "$(nev firing hog restarts)" 0

# ---- 10. restarts: 3 automatic restarts within the window ----
mark
for i in 1 2 3; do n0=$(nrestarts hog); get hog /exit > /dev/null; until_ 30 restarted hog "$n0"; wrun; done
check "10a 3 restarts within restarts_window: fires once" eq "$(nev firing hog restarts)" 1
check "10b ... and no down alert (the app is up between restarts)" eq "$(nev firing hog down)" 0
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

# ---- 21. production defaults with the real timer: time to detect a dead app ----
aset oom_quiet= restarts_window= deploy_grace= boot_grace= mem_for= heartbeat_every=
srv 'sudo systemctl start tando-watch.timer'
until_ 60 idle; mark   # the timer's first run (if any) is over: its messages are not counted
t0=$(date +%s)
crash_on hello
until_ 300 seen firing hello down
t1=$(date +%s)
echo "time to detect a dead app with the real timer and production defaults: $((t1 - t0)) s" >> "$E/numbers"
# worst case by design: the first tick that sees the activation (up to 60 s after t0) starts
# deploy_grace (120 s), and down_after needs 2 samples a minute apart: 60 + 120 + 60 = 240 s.
# Measured 142-194 s over six runs; the earlier 180 s bound failed about one run in three.
check "21a dead app detected by the timer within 4 minutes ($((t1 - t0)) s)" test $((t1 - t0)) -le 240
crash_off hello
until_ 300 seen resolved hello down
t2=$(date +%s)
echo "time to announce recovery: $((t2 - t1)) s" >> "$E/numbers"
check "21b recovery announced within 3 minutes ($((t2 - t1)) s)" test $((t2 - t1)) -le 180

# ---- 22. whole host restart: the timer survives, state survives, no alert storm ----
if [ $OWNED = 0 ]; then
  echo "SKIP 22 whole host restart: $TANDO_TEST_NAME is not ours to restart"
else
aset disk_pct=1; until_ 120 firing _host.disk
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
aset disk_pct=

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
t0=$(vt); sleep 1; wruns 2
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
mark; breq "/flood?n=3000"; sleep 11; breq "/say?w=after"; sleep 1; wrun
c28u() { [ "$(nev firing boom logs)" = 1 ] && since_mark | grep -q 'FIRING boom/logs (low): journald dropped'; }
check "28u journald dropped lines: logs fires, marked low severity" c28u
"$R" logs -a boom -n 3 > "$E/logs-note.out" 2>&1
check "28v tando logs ends with a note on the dropped lines" grep -q '^# note: journald dropped [0-9]* lines' "$E/logs-note.out"

# a crash loop: the exit status and the last lines (kept on the server, not sent by default)
mark
for i in 1 2 3; do breq /crash; sleep 2; t_until 20 restarted boom "$(nrestarts boom)" 2> /dev/null; wrun; done
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

# ---- 29. tandod: running after setup, killed in the middle of a run, stopped, an upgrade ----
if [ "${TANDO_TEST_NO_DAEMON:-}" = 1 ]; then
  echo "SKIP 29 tandod: TANDO_TEST_NO_DAEMON=1"
else
check "29a tandod runs after host setup; its socket is root 600 in a root 700 directory" \
  srv 'systemctl -q is-active tandod && [ "$(sudo stat -c "%a %U" /run/tandod /run/tandod/tandod.sock | tr "\n" " ")" = "700 root 600 root " ]'
check "29b a user that is not root cannot reach the socket; tando-watch brief works without it" \
  srv '! ls /run/tandod > /dev/null 2>&1 && /opt/tando/bin/tando-watch brief > /dev/null'
srv 'sudo systemctl stop tando-watch.timer'; until_ 60 idle
# kill -9 in the middle of a run: hog/health fires in one run; "hook" answers at once, "slowd" never
# (the run waits for it, 15 s), and tandod is killed while it waits
printf 'http://127.0.0.1:9999/slowd/S3CR3Tslowd\n' | "$R" alerts notifier add slowd webhook > /dev/null 2>&1
srv 'curl -s http://127.0.0.1:9999/ctl/fail/slowd > /dev/null'
aset hog.health_fails=1; wrun; mark
get hog /sick > /dev/null
p0=$(srv 'systemctl show -P MainPID tandod')
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
sleep 2; until_ 60 idle   # (a run that is starting has no ExecMainStartTimestamp yet)
# (the timer's: tando-watch.service, referenced by nothing now, is unloaded after a run)
check "27h systemd prints its timestamps in a local zone here (TZ=WIB-7)" \
  srv 'TZ=WIB-7 systemctl show -P ActiveEnterTimestamp tando-watch.timer | grep -q WIB'
# (the daemon tests above leave tandod just restarted and degraded, with no run on record yet:
# the timer's fallback runs within two minutes)
until_ 150 srv '/opt/tando/bin/tando-watch doctor | grep -q "checks ran"'
srv 'TZ=WIB-7 /opt/tando/bin/tando-watch doctor; systemctl show -p StatusText,ActiveState tandod; systemctl show -p ActiveState,Result,ExecMainStartTimestampMonotonic tando-watch.service tando-watch-fallback.service; cat /proc/uptime' >&2
check "27i the dead man's check still reads the last run's age under that zone" \
  srv 'TZ=WIB-7 /opt/tando/bin/tando-watch doctor | grep -q "checks ran"'
"$R" alerts > "$E/alerts-final.out" 2>&1; cat "$E/alerts-final.out" >&2
[ -f "$E/numbers" ] && cat "$E/numbers" >&2

echo
if [ $FAILS -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILED"; fi
[ $FAILS -eq 0 ]
