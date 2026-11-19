# shellcheck shell=bash
# test/alerts-lib.sh: what the three alerts suites share (e2e-alerts.sh, e2e-alerts-timer.sh,
# e2e-alerts-daemon.sh): the helpers, the notification receiver, the apps and the notifiers.
# bash 3.2 compatible; safe under set -u. Each suite runs on a server of its own, so test/all.sh
# runs the three side by side:
#
#   ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
#   . "$ROOT/test/alerts-lib.sh"
#   alerts_server tando-test-alerts 2303 8303 0   # default name and ports (by hand), pinned CPU
#   t_init e2e-alerts                             # test/lib.sh: work dir E, config dir
#   alerts_setup "$@"                             # server, receiver, apps hello/hog/site, notifiers
#   ... checks ...
#   alerts_done
#
# Notifications go to a receiver inside the container (Node, 127.0.0.1:9999); nothing leaves this
# machine. Most checks stop the timer and start the check run by hand (`systemctl start
# tando-watch.service`, exactly what the timer does) so each sample is deterministic.
#
#   TANDO_TREE=<dir with bin/ lib/ server/>   the tando to test (default: this repository)
#   TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT   which test container. It is
#     reset (and, in e2e-alerts-timer, restarted) only when it is the suite's default, does not
#     exist yet, or TANDO_TEST_OWNED=1; otherwise the suite reuses it and only removes its own apps.
#   T_WORK=<dir>   work directory (default test/.<suite>-<server>)
#   TANDO_TEST_NO_DAEMON=1   tandod stopped and disabled after every host setup: the checks run as
#     the one-shot (the fallback path of a host without the daemon)
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib.sh"   # t_init, t_until (pass/fail/check: below)

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
# nodaemon: with TANDO_TEST_NO_DAEMON=1, tandod off (host setup enables and starts it every time)
nodaemon() { [ "${TANDO_TEST_NO_DAEMON:-}" = 1 ] && srv 'sudo systemctl disable -q --now tandod'; true; }
# a crash loop from outside the app: every start fails (tando env set refuses an env the app
# crashes with, since its pre-check: it can no longer make one). A runtime drop-in, gone at reboot
crash_on() { srv "sudo sh -c 'mkdir -p /run/systemd/system/tando-$1.service.d &&
  printf \"[Service]\\nExecStartPre=/bin/sh -c \\\"exit 3\\\"\\n\" > /run/systemd/system/tando-$1.service.d/zz-test-crash.conf &&
  systemctl daemon-reload && systemctl restart tando-$1'" > /dev/null 2>&1; true; }
crash_off() { srv "sudo sh -c 'rm -f /run/systemd/system/tando-$1.service.d/zz-test-crash.conf; systemctl daemon-reload;
  systemctl reset-failed tando-$1; systemctl restart tando-$1'" > /dev/null 2>&1; true; }

# alerts_server <default name> <default ssh port> <default http port> <cpu>: the suite's server
# when the environment names none (a run by hand), and the CPU its container is pinned to (each
# alerts suite its own, so the three do not share one core when they run side by side). Before t_init.
alerts_server() {
  A_DEFAULT_NAME=$1 A_CPU=$4
  export TANDO_TEST_NAME=${TANDO_TEST_NAME:-$1}
  export TANDO_TEST_SSH_PORT=${TANDO_TEST_SSH_PORT:-$2} TANDO_TEST_HTTP_PORT=${TANDO_TEST_HTTP_PORT:-$3}
}

# alerts_setup [--no-reset]: after t_init. The server (1 CPU, 2 GB), the receiver and a fake
# sendmail in it, host add + host setup, the apps hello, hog and site, alerts enable, the six
# notifiers and the heartbeat, "broken" answering 500. Leaves for the suite's own checks:
# $E/setup.out, $E/alerts-empty.out (tando alerts before any notifier), $E/notifiers.out.
# Sets TREE, R, W, HP, SSHX, OWNED. Exits when the fixtures cannot be made.
alerts_setup() {
  local a ncpu
  TREE=${TANDO_TREE:-$ROOT}
  R=$TREE/bin/tando W=$E/w HP=$TANDO_TEST_HTTP_PORT SSHX=$ROOT/test/server/ssh.sh
  export COLUMNS=100
  OWNED=0
  if [ "${TANDO_TEST_OWNED:-}" = 1 ] || [ "$TANDO_TEST_NAME" = "$A_DEFAULT_NAME" ] ||
     ! docker container inspect "$TANDO_TEST_NAME" > /dev/null 2>&1; then OWNED=1; fi
  if [ "${1:-}" != --no-reset ] && [ $OWNED = 1 ]; then
    ncpu=$(docker info --format '{{.NCPU}}' 2> /dev/null); case $ncpu in ""|*[!0-9]*|0) ncpu=1;; esac
    log "resetting test server $TANDO_TEST_NAME (1 CPU, 2 GB like the real VPS; CPU $((A_CPU % ncpu)))"
    TANDO_TEST_DOCKER_ARGS="--cpus 1 --cpuset-cpus $((A_CPU % ncpu)) --memory 2g" "$ROOT/test/server/up.sh" --reset >&2 || exit 1
  else
    log "reusing test server $TANDO_TEST_NAME (not ours to reset)"
    "$ROOT/test/server/up.sh" >&2 || exit 1
  fi
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
  # ---- setup installs the timer; apps; notifiers (secrets on stdin) ----
  "$R" host add t vmadmin@127.0.0.1 --port "$TANDO_TEST_SSH_PORT" --key "$ROOT/test/server/id_test" --yes > /dev/null 2>&1 ||
    { echo "FAIL host add (the normal path: host key shown and trusted with --yes)"; exit 1; }
  "$R" host setup t public_port=$HP > "$E/setup.out" 2>&1 || { cat "$E/setup.out"; echo "FAIL host setup"; exit 1; }
  nodaemon
  if [ $OWNED = 0 ]; then   # a reused server: start from none of our apps and no alert state
    for a in hello hog site; do echo $a | "$R" destroy --purge -a $a > /dev/null 2>&1; done
    srv 'sudo rm -rf /var/lib/tando/watch /opt/tando/alerts.d /opt/tando/alerts.conf; sudo truncate -s0 /root/recv.log 2>/dev/null; true'
  fi
  (cd "$W/hello" && "$R" up > "$E/up-hello.out" 2>&1) && (cd "$W/hog" && "$R" up > "$E/up-hog.out" 2>&1) &&
    (cd "$W/site" && "$R" up > "$E/up-site.out" 2>&1) ||
    { tail -5 "$E"/up-*.out; echo "FAIL up"; exit 1; }
  "$R" alerts enable > /dev/null 2>&1    # idempotent; a host set up before alerts existed needs it
  "$R" alerts > "$E/alerts-empty.out" 2>&1
  {
    printf 'http://127.0.0.1:9999/hook/S3CR3Thook1\n' | "$R" alerts notifier add hook webhook
    printf 'http://127.0.0.1:9999/slack/S3CR3Tslack1\n' | "$R" alerts notifier add sl slack
    printf 'S3CR3Ttg:abc\n-100123\n' | "$R" alerts notifier add tg telegram api=http://127.0.0.1:9999/tg
    printf 'http://127.0.0.1:9999/ntfy/S3CR3Tntfy1\nS3CR3Tntfytok\n' | "$R" alerts notifier add nt ntfy
    printf 'ops@example.com\n' | "$R" alerts notifier add mail email
    printf 'http://127.0.0.1:9999/broken/S3CR3Tbroken1\n' | "$R" alerts notifier add broken webhook
    printf 'http://127.0.0.1:9999/hb/S3CR3Thb1\n' | "$R" alerts heartbeat
  } > "$E/notifiers.out" 2>&1
  srv 'curl -s http://127.0.0.1:9999/ctl/fail/broken > /dev/null'
}

# alerts_fixtures_ok: what e2e-alerts checks as 1a and 1b, for the suites that only build on it:
# the timer is on and every notifier was added (a suite without them would pass or fail for the
# wrong reason)
alerts_fixtures_ok() {
  [ "$(srv 'systemctl is-enabled tando-watch.timer; systemctl is-active tando-watch.timer' | tr '\n' ' ')" = "enabled active " ] &&
    [ "$(grep -c '^added notifier' "$E/notifiers.out")" = 6 ]
}

# alerts_done: what is firing at the end and the measured times (stderr), the summary, the exit status
alerts_done() {
  "$R" alerts > "$E/alerts-final.out" 2>&1; cat "$E/alerts-final.out" >&2
  [ -f "$E/numbers" ] && cat "$E/numbers" >&2
  echo
  if [ $FAILS -eq 0 ]; then echo "ALL PASS"; else echo "$FAILS FAILED"; fi
  [ $FAILS -eq 0 ]
  exit
}
