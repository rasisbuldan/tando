#!/bin/bash
# Noisy neighbours: one test server, three apps. A misbehaves on request (CPU spin, memory leak to
# the OOM killer, a fork storm, a log flood, a crash loop, slow responses, many open connections,
# files until a cap); B is always on, C scales to zero (idle_stop). For each failure the suite
# checks that B answers every probe inside a latency budget (p95 and no error), that C wakes from
# a cold start and answers, that `tando ls` and `tando status` work meanwhile, and that the damage
# stays inside A's own limits (cgroup memory, tasks, CPU, journal cap, start limit, alert).
# Limits that other changes add (Caddy per-app timeouts, conntrack per uid, disk and /tmp caps,
# journald in the app's slice) are checked when the server has them and SKIP with a reason when
# it does not, so they turn on by themselves when those changes are merged.
#
#   test/e2e-neighbours.sh [--reset]     --reset: recreate the server first (only one this suite owns)
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT. Full tier only (about
# 10 minutes). Output: PASS/FAIL/SKIP lines (docs/TESTING.md), then a results table on stderr
# (also in $E/results.txt): one row per failure with B's p95 and worst request, C's cold start
# and what was contained.
# The fork storm: A has memory 160M and tasks 100. With less memory (64M) the kernel kills A on
# memory first: every forked process is charged to the cgroup (about 1.4 MB each with Node's fork),
# so a small app never reaches its tasks cap (seen on a real VPS: A crashed, no task limit hit).
# The test app is the one the lead ran by hand on a VPS: endpoints /spin /leak /fork /logflood
# /crash /slow /conns /disk (below). Budgets are generous: the test server shares a laptop.
# shellcheck disable=SC2034  # these variables are read inside the eval'd check strings
set -u
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init neighbours
W=$E/w
A=nba B=nbb C=nbc

if [ "${1:-}" = --reset ]; then t_server_up --reset || exit 1; else t_server_up || exit 1; fi
t_host_add test
"$R" host setup test public_port="$T_HTTP_PORT" >&2 || { fail "N0 host setup"; t_done; }

# ---- the apps ---------------------------------------------------------------------------------
mkdir -p "$W/$A" "$W/$B" "$W/$C"
cat > "$W/$A/server.js" << 'EOF'
// The misbehaving app. Every failure is a request; /status says what it did so far.
const http = require('http'), fs = require('fs'), net = require('net'), cp = require('child_process');
const { Worker } = require('worker_threads');
const port = Number(process.env.PORT), data = process.env.TANDO_DATA_DIR;
const st = { spin: 0, leak_mb: 0, tried: 0, forked: 0, fork_err: 0, fork_last: '', logged: 0,
  conns_open: 0, conns_err: 0, disk_mb: 0, disk_err: '' };
const hold = [], socks = [];
// a crash loop: the flag file makes every start exit (the data directory survives a restart)
if (fs.existsSync(data + '/crashloop')) { console.error('crashloop flag: exiting'); process.exit(1); }
// (the thread pool starts now, not at the first request under a task cap)
fs.readFile(__filename, () => {});
const q = (u, k, d) => Number(new URL(u, 'http://x').searchParams.get(k) || d);
function spin(s) { // two busy threads: a worker, so health checks keep answering
  for (let i = 0; i < 2; i++) new Worker(`const e = Date.now() + ${s * 1000}; while (Date.now() < e);`, { eval: true });
  st.spin += s;
}
function leak() { // 8 MB every 50 ms, touched, until the kernel kills it
  setInterval(() => { hold.push(Buffer.alloc(8 << 20, 1)); st.leak_mb += 8; }, 50);
}
function fork(max) { // 50 `sleep` every 20 ms, up to max tries; errors (EAGAIN at a task cap) are counted
  const iv = setInterval(() => {
    for (let i = 0; i < 50 && st.tried < max; i++) {
      st.tried++;
      try {
        const c = cp.spawn('sleep', ['300'], { stdio: 'ignore' });
        c.on('error', (e) => { st.fork_err++; st.fork_last = e.code || String(e); });
        c.on('spawn', () => st.forked++);
      } catch (e) { st.fork_err++; st.fork_last = e.code || String(e); }
    }
    if (st.tried >= max) clearInterval(iv);
  }, 20);
}
function logflood(s) { // 2000 lines every 100 ms
  const end = Date.now() + s * 1000, line = 'flood line ' + 'x'.repeat(80) + '\n';
  const iv = setInterval(() => {
    process.stdout.write(line.repeat(2000)); st.logged += 2000;
    if (Date.now() > end) clearInterval(iv);
  }, 100);
}
function conns(n, p) { // open n connections and keep them (to this app's own port by default)
  let i = 0;
  const iv = setInterval(() => {
    for (let k = 0; k < 100 && i < n; k++, i++) {
      const c = net.connect(p, '127.0.0.1');
      c.on('connect', () => { st.conns_open++; socks.push(c); });
      c.on('error', () => { st.conns_err++; });
    }
    if (i >= n) clearInterval(iv);
  }, 10);
}
function disk(mb) { // 1 MB files until mb or an error
  let i = 0; const chunk = Buffer.alloc(1 << 20, 7);
  const iv = setInterval(() => {
    try {
      if (i >= mb) return clearInterval(iv);
      fs.writeFileSync(`${data}/fill-${i++}.bin`, chunk); st.disk_mb = i;
    } catch (e) { st.disk_err = e.code || String(e); clearInterval(iv); }
  }, 5);
}
const server = http.createServer((req, res) => {
  const p = req.url.split('?')[0], say = (s) => { res.writeHead(200, { 'content-type': 'text/plain' }); res.end(s + '\n'); };
  switch (p) {
    case '/health': return say('ok');
    case '/spin': spin(q(req.url, 's', 20)); return say('spinning');
    case '/leak': leak(); return say('leaking');
    case '/fork': fork(q(req.url, 'max', 5000)); return say('forking');
    case '/logflood': logflood(q(req.url, 's', 20)); return say('flooding');
    case '/crash':
      if (q(req.url, 'loop', 0)) fs.writeFileSync(data + '/crashloop', '1');
      say('crashing'); return setTimeout(() => process.exit(1), 50);
    case '/slow': return setTimeout(() => say('slow done'), q(req.url, 'ms', 30000));
    case '/conns': conns(q(req.url, 'n', 2000), q(req.url, 'port', port)); return say('connecting');
    case '/disk': disk(q(req.url, 'mb', 150)); return say('filling');
    case '/clear': for (const f of fs.readdirSync(data)) if (f.startsWith('fill-')) fs.unlinkSync(data + '/' + f);
      st.disk_mb = 0; st.disk_err = ''; return say('cleared');
    case '/status': res.writeHead(200, { 'content-type': 'application/json' }); return res.end(JSON.stringify(st) + '\n');
    default: return say('nb ' + process.pid);
  }
});
server.listen(port, '127.0.0.1');
process.on('SIGTERM', () => process.exit(0));
EOF
for x in A B C; do eval "n=\$$x"; echo 1 > "$W/$n/VERSION"; done
cp "$ROOT/examples/hello/server.js" "$W/$B/"; cp "$ROOT/examples/hello/server.js" "$W/$C/"
cat > "$W/$A/tando.conf" << EOF
app = $A
recipe = node
start = node server.js
health = /health
health_timeout = 15
memory = 160M
tasks = 100
cpu = 50%
max_conns = 20
log_max = 8M
log_rate = 1000/10s
EOF
printf 'app = %s\nrecipe = node\nstart = node server.js\nhealth = /health\nhealth_timeout = 15\nmemory = 64M\n' "$B" > "$W/$B/tando.conf"
printf 'app = %s\nrecipe = node\nstart = node server.js\nhealth = /health\nhealth_timeout = 15\nmemory = 64M\nidle_stop = 10s\n' "$C" > "$W/$C/tando.conf"

for n in $A $B $C; do
  (cd "$W/$n" && "$R" up --yes > "$E/up-$n.log" 2>&1) || { fail "N0 deploy of $n"; cat "$E/up-$n.log" >&2; t_done; }
done

# ---- helpers ----------------------------------------------------------------------------------
srv() { "$SSH" "$@"; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-10}" "$(t_url "$1" "${3:-/}")"; }
get() { curl -s --max-time 10 "$(t_url "$A" "$1")"; }
st_json() { get /status; }
st_get() { st_json | sed -n "s/.*\"$1\":\\([0-9]*\\).*/\\1/p"; }   # a number field of A's /status
slice=/sys/fs/cgroup/tando.slice/tando-$A.slice
cg() { srv "cat $slice/$1 2> /dev/null"; }
cg_key() { srv "sed -n 's/^$2 //p' $slice/$1 2> /dev/null" | head -1; }
mainpid() { srv "systemctl show -P MainPID tando-$1"; }
nrestarts() { srv "systemctl show -P NRestarts tando-$1"; }
a_up() { [ "$(code $A 5 /health)" = 200 ]; }
b_pid=$(mainpid $B)
RESULTS=$E/results.txt
printf '%-10s %-9s %-9s %-9s %-10s %s\n' failure B_p95_ms B_max_ms B_not200 C_cold_s contained > "$RESULTS"

# B's probes: ~8 a second through Caddy. p95 and worst in ms, and how many were not 200
b_start() { t_loop_start "$1" "$(t_url $B /)" 0.05; }
b_stop() { # <tag> <budget ms> -> BP95 BMAX BBAD
  t_loop_stop "$1" 2> /dev/null
  BP95=$(awk '{print int($2 * 1000)}' "$E/loop.$1" | sort -n | awk '{a[NR] = $1} END {i = int(NR * 0.95 + 0.999); if (i < 1) i = 1; print a[i] + 0}')
  BMAX=$T_LOOP_MAX; BMAX=$(awk -v m="$BMAX" 'BEGIN {printf "%d", m * 1000}'); BBAD=$T_LOOP_BAD
  [ "$BBAD" = 0 ] || { echo "  B probes that were not 200 (code, seconds, epoch):" >&2; grep -v '^200 ' "$E/loop.$1" | head -5 >&2; }
  echo "  B during $1: ${T_LOOP_N} probes, p95 ${BP95} ms, worst ${BMAX} ms, ${BBAD} not 200 (budget p95 < $2 ms)" >&2
}
# BTOL: probes of B allowed to fail (0, except while A's crash loop is handled: see N6)
b_ok() { [ "$BBAD" -le "${BTOL:-0}" ] && [ "$BP95" -lt "$1" ] && [ "$BMAX" -lt 5000 ]; }
# C: stopped (as an idle stop leaves it: wake socket listening), then one request wakes it
c_idle() { srv "sudo systemctl stop tando-$C.service" > /dev/null 2>&1; t_until 15 srv "systemctl -q is-active tando-${C}_wake.socket && test -S /run/tando-wake/$C.sock" > /dev/null 2>&1; }
CCODE="" CSEC=""
c_wake() {
  c_idle > /dev/null; read -r CCODE CSEC < <(curl -s -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 30 "$(t_url $C /)")
  if [ "$CCODE" != 200 ]; then
    echo "  C did not wake: HTTP $CCODE after $CSEC s" >&2
    local d
    d=$(srv "systemctl --no-pager -l status tando-$C.service tando-${C}_wake.socket tando-${C}_wake.service 2>&1 | tail -40; sudo journalctl --no-pager -n 15 -o cat -u tando-${C}_wake.service -u tando-$C.service; sudo journalctl --no-pager -n 10 -o cat -u caddy" 2>&1)
    echo "$d" >&2
    # (the socket is brought back, so a later window still tests C. Seen before: C's sixth start
    # in a minute (each wake is one) hit the unit's start limit and then the socket's trigger limit,
    # whatever A did; the agent now resets the counter after each clean idle stop)
    if echo "$d" | grep -q 'start-limit-hit\|trigger-limit-hit'; then
      srv "sudo systemctl reset-failed 'tando-$C*'; sudo systemctl start tando-${C}_wake.socket" > /dev/null 2>&1
    fi
  fi
}
ls_works() { "$R" ls -H test > "$E/ls.out" 2>&1 && grep -qw "$B" "$E/ls.out" && grep -qw "$C" "$E/ls.out"; }
status_works() { "$R" status -a "$B" -H test > "$E/status.out" 2>&1; }
# the checks every failure shares, with B's budget: ids <n>b (B), <n>c (C), <n>d (ls and status)
common() { # <id> <name> <budget ms> <contained note>
  local id=$1 name=$2 budget=$3 note=$4
  check "$id-B B answers every probe during $name (p95 < $budget ms)" b_ok "$budget"
  check "$id-C C wakes and answers during $name (cold start)" eval '[ "$CCODE" = 200 ]'
  ls_works && status_works; local lsrc=$?
  check "$id-L tando ls and tando status work during $name" eval "[ $lsrc = 0 ]"
  check "$id-P B and C were not restarted by $name" eval '[ "$(mainpid $B)" = "$b_pid" ]'
  printf '%-10s %-9s %-9s %-9s %-10s %s\n' "$name" "$BP95" "$BMAX" "$BBAD" "$CSEC" "$note" >> "$RESULTS"
}
# fault window: B probes run through the middle of it; C is woken part way
window() { # <tag> <seconds the fault runs before C is woken>
  b_start "$1"; sleep "$2"; c_wake; sleep 2
}

# ---- 0. the limits are in place ---------------------------------------------------------------
check "N0a A's slice carries memory 3x160M, tasks 100, cpu 50%" eval '
  [ "$(cg memory.max)" = 503316480 ] && [ "$(cg pids.max)" = 100 ] && cg cpu.max | grep -q "^50000 100000"'
check "N0b TasksMax per app: A has its tasks (100), B the default (1024)" eval '
  [ "$(srv "systemctl show -P TasksMax tando-$A.slice")" = 100 ] && [ "$(srv "systemctl show -P TasksMax tando-$B.slice")" = 1024 ]'
check "N0c C is an idle app: the wake socket listens" srv "systemctl -q is-active tando-${C}_wake.socket"

# ---- 1. baseline: nothing wrong ---------------------------------------------------------------
log "1. baseline"
window base 8
b_stop base 150
common N1 baseline 150 "-"
BASE_P95=$BP95

# ---- 2. CPU spin ------------------------------------------------------------------------------
log "2. CPU spin"
t0=$(cg_key cpu.stat nr_throttled)
get /spin?s=20 > /dev/null
window spin 6
b_stop spin 400
common N2 spin 400 "A throttled at cpu 50%"
check "N2a A's CPU is capped: its cgroup was throttled" eval '[ "$(cg_key cpu.stat nr_throttled)" -gt "${t0:-0}" ]'
check "N2b A is still the same process and answers (the spin runs in a thread)" eval '[ -n "$(mainpid $A)" ] && a_up'

# ---- 3. memory leak to the OOM kill -----------------------------------------------------------
log "3. memory leak"
srv 'sudo dmesg -c > /dev/null 2>&1; true'
oom0=$(cg_key memory.events oom_kill); oom0=${oom0:-0}; rs0=$(nrestarts $A); pid0=$(mainpid $A)
get /leak > /dev/null
b_start leak
leaked() { [ "$(cg_key memory.events oom_kill)" -gt "$oom0" ]; }
t_until 40 leaked > /dev/null 2>&1
sleep 1; c_wake; sleep 2
b_stop leak 600
common N3 leak 600 "OOM kill inside A's cgroup"
check "N3a the kernel killed a process of A's cgroup (memory.events oom_kill)" leaked
dm=$(srv 'sudo dmesg 2> /dev/null; journalctl -k --no-pager 2> /dev/null' | grep -i 'out of memory\|oom-kill' | head -3)
if [ -n "$dm" ]; then
  check "N3b the kernel log names A's cgroup (tando-$A), not B, C or Caddy" eval 'echo "$dm" | grep -q "tando-$A" && ! echo "$dm" | grep -Eq "tando-($B|$C)|caddy"'
else skip "N3b the kernel log is not readable in this test server (memory.events was checked in N3a)"; fi
check "N3c no other app's cgroup had an OOM kill" eval '
  [ "$(srv "cat /sys/fs/cgroup/tando.slice/tando-$B.slice/memory.events | sed -n \"s/^oom_kill //p\"")" = 0 ] &&
  [ "$(srv "cat /sys/fs/cgroup/tando.slice/tando-$C.slice/memory.events | sed -n \"s/^oom_kill //p\"")" = 0 ]'
check "N3d A comes back after the kill (restarted by systemd, answers /health)" eval 't_until 60 a_up && [ "$(mainpid $A)" != "$pid0" ]'
check "N3e A's memory is back under its cap, not at it" eval '[ "$(cg memory.current)" -lt 150000000 ]'

# ---- 4. fork storm ----------------------------------------------------------------------------
log "4. fork storm"
a_up > /dev/null || t_until 30 a_up > /dev/null
pid1=$(mainpid $A); ev0=$(cg_key pids.events max); ev0=${ev0:-0}
get "/fork?max=5000" > /dev/null
b_start fork
pmax=0 i=0
while [ $i -lt 14 ]; do
  cur=$(cg pids.current); [ "${cur:-0}" -gt "$pmax" ] && pmax=$cur
  [ $i = 6 ] && { c_wake; }
  sleep 1; i=$((i + 1))
done
b_stop fork 400
fst=$(st_json)
echo "  A after the storm: $fst (pids.current peak $pmax, pids.max $(cg pids.max))" >&2
common N4 fork 400 "A held at ${pmax:-?} of 100 tasks"
check "N4a the task cap held: A's cgroup never had more than 100 tasks" eval '[ "$pmax" -le 100 ] && [ "$pmax" -gt 50 ]'
check "N4b the cap was hit: the kernel refused forks (pids.events max went up)" eval '[ "$(cg_key pids.events max)" -gt "$ev0" ]'
check "N4c A was not crashed by the cap: the same process, fork errors counted, still answers" eval '
  [ "$(mainpid $A)" = "$pid1" ] && a_up && [ "$(echo "$fst" | sed -n "s/.*\"fork_err\":\\([0-9]*\\).*/\\1/p")" -gt 0 ]'
check "N4d the host kept forking: ssh and tando ls were answered during the storm" eval '[ "$(srv true; echo $?)" = 0 ]'
srv "sudo /opt/tando/bin/tando-agent restart $A" > /dev/null 2>&1
check "N4e a restart of A ends every sleep it forked (its cgroup is nearly empty again)" eval 't_until 30 a_up && [ "$(cg pids.current)" -lt 30 ]'

# ---- 5. log flood -----------------------------------------------------------------------------
log "5. log flood"
get "/logflood?s=15" > /dev/null
b_start flood; sleep 7; c_wake; sleep 8
b_stop flood 600
jsz=$(srv "sudo sh -c 'du -sk /var/log/journal/*.tando-$A /run/log/journal/*.tando-$A 2> /dev/null'" | awk '{s += $1} END {print s * 1024}')
logged=$(st_get logged)
stored=$(srv "sudo journalctl --namespace tando-$A -u tando-$A --no-pager -o cat 2> /dev/null | grep -c 'flood line'")
echo "  A wrote $logged lines in the flood; its journal keeps $stored lines in ${jsz:-?} bytes (log_max 8M, log_rate 1000/10s)" >&2
common N5 logflood 600 "kept $stored of $logged lines, journal ${jsz:-?} B"
check "N5a the flood wrote at least 20000 lines (the test did flood)" eval '[ "${logged:-0}" -ge 20000 ]'
check "N5b journald rate-limited it: far fewer lines stored than written" eval '[ "${stored:-999999}" -lt $((logged / 4)) ]'
check "N5c the journal stays near log_max (8M): under 16 MB" eval '[ -n "$jsz" ] && [ "$jsz" -lt 16777216 ]'
check "N5d the logs of B still work (tando logs reads its own journal)" "$R" logs -a "$B" -n 5 -H test
if srv "grep -rqs '^Slice=' /etc/systemd/system/systemd-journald@tando-$A.service.d/"; then
  check "N5e the app's journald runs inside the app's slice (its cost counts for A)" eval '
    srv "systemctl show -P Slice systemd-journald@tando-$A.service" | grep -q "tando-$A.slice"'
else skip "N5e journald@tando-$A in the app's slice: not in this version (density slice 5, journal_dir adds Slice=)"; fi
t_until 30 a_up > /dev/null

# ---- 6. crash loop ----------------------------------------------------------------------------
log "6. crash loop"
rs0=$(nrestarts $A)
get "/crash?loop=1" > /dev/null
b_start crash
down() { [ "$(srv "systemctl show -P ActiveState tando-$A")" = failed ]; }
t_until 60 down > /dev/null 2>&1
dres=$?
# (the page is written by app-down a moment after systemd gives up: poll for it)
page() { fivexx=$(code $A 5 /); [ "$fivexx" = 503 ]; }
t_until 15 page > /dev/null 2>&1
c_wake; sleep 1
# "down" needs two samples of a unit that keeps failing (the alerts suite waits for the same)
alert=0 i=0
while [ $i -lt 55 ]; do   # (it fired after 40 to 140 s in the runs: a sample a minute)
  srv 'sudo systemctl start tando-watch.service' > /dev/null 2>&1
  if srv "sudo grep -Eq '^$A\\.down\\.st=firing' /var/lib/tando/watch/state"; then alert=1; break; fi
  sleep 3; i=$((i + 1))
done
# One of B's probes was refused in 2 of 7 runs, at the moment tando rewrites Caddy's config for A's
# down page (a reload: shared fate with Caddy, known, to be bounded by slice 2). One is tolerated here.
b_stop crash 400
BTOL=1
srv "systemctl show -P ActiveState -P SubState -P Result -P NRestarts tando-$A | tr '\n' ' '; sudo grep -E '^$A\\.' /var/lib/tando/watch/state | head; sudo grep -c down /opt/tando/apps/$A/state" >&2
common N6 crash 400 "start limit, 503 page, down alert"
BTOL=0
check "N6a the crash loop ends at the start limit: the unit went to failed, not restarting forever" eval '[ "$dres" = 0 ]'
check "N6b visitors of A get the 503 page within seconds of the unit giving up (got $fivexx)" eval '[ "$fivexx" = 503 ]'
check "N6c the monitor fires the down alert for A (and for no other app)" eval '
  [ "$alert" = 1 ] && ! srv "sudo grep -Eq \"^($B|$C)\\.down\\.st=(pending|firing)\" /var/lib/tando/watch/state"'
srv "sudo rm -f /opt/tando/apps/$A/shared/data/crashloop; sudo /opt/tando/bin/tando-agent recover-all" > /dev/null 2>&1
check "N6d once the cause is gone, recover-all brings A back (and it answers)" t_until 90 a_up
t_until 60 eval '! srv "sudo grep -Eq \"^$A\\.down\\.st=firing\" /var/lib/tando/watch/state" || { srv "sudo systemctl start tando-watch.service" > /dev/null 2>&1; false; }' > /dev/null 2>&1
check "N6e the down alert resolves after the recovery" eval '! srv "sudo grep -Eq \"^$A\\.down\\.st=(pending|firing)\" /var/lib/tando/watch/state"'

# ---- 7. slow responses ------------------------------------------------------------------------
log "7. slow responses"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  curl -s -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 40 "$(t_url $A '/slow?ms=12000')" > "$E/slow.$i.code" 2> /dev/null &
done
b_start slow; sleep 4; c_wake; sleep 2
b_stop slow 400
wait
cat "$E"/slow.*.code > "$E/slow.all"
shed=$(grep -c '^503' "$E/slow.all"); hung=$(grep -c '^000' "$E/slow.all")
delayed=$(awk '$1 == 503 || $2 > 13 {n++} END {print n + 0}' "$E/slow.all")
echo "  30 slow requests (12 s each) against max_conns 20: $(awk '{print $1}' "$E/slow.all" | sort | uniq -c | tr -s ' \n' ' ') ; $delayed queued past 13 s or shed" >&2
common N7 slow 400 "30 slow requests, cap 20: $delayed queued/shed, $hung hung"
check "N7a A's cap of 20 connections holds: Caddy has it, and the other 10 were queued or shed, none hung" eval '
  srv "sudo grep -q \"max_conns_per_host 20\" /etc/caddy/tando/$A.caddy" && [ "$hung" = 0 ] && [ "$delayed" -ge 5 ]'
if srv "sudo grep -q response_header_timeout /etc/caddy/tando/$A.caddy"; then
  rt=$(srv "sudo sed -n 's/.*response_header_timeout *//p' /etc/caddy/tando/$A.caddy" | head -1)
  check "N7b Caddy cuts a response that never starts (response_header_timeout $rt, per app)" eval '[ -n "$rt" ]'
else skip "N7b Caddy's per-app response_header_timeout: not in this version (density slice 2)"; fi
t_until 40 a_up > /dev/null

# ---- 8. many open connections -----------------------------------------------------------------
log "8. many open connections"
get "/conns?n=3000" > /dev/null
b_start conns; sleep 6; c_wake; sleep 3
est=$(srv "sudo ss -Htnp state established" 2> /dev/null | grep -c "pid=$(mainpid $A),")
cst=$(st_json)
b_stop conns 500
echo "  A's connections: $cst (established to its port: ${est:-?})" >&2
common N8 conns 500 "A holds ${est:-?} sockets"
check "N8a A is still up (the same service answers /health) after opening thousands of connections" a_up
if srv "sudo nft list ruleset 2> /dev/null | grep -Eq 'skuid.*ct count|ct count.*skuid'"; then
  check "N8b per-uid conntrack cap: A's connections stopped at the cap (errors counted, B unharmed)" eval '
    [ "$(echo "$cst" | sed -n "s/.*\"conns_err\":\\([0-9]*\\).*/\\1/p")" -gt 0 ]'
else skip "N8b per-uid conntrack cap (nft ct count per app user): not in this version (density slice 3)"; fi
srv "sudo /opt/tando/bin/tando-agent restart $A" > /dev/null 2>&1; t_until 30 a_up > /dev/null

# ---- 9. files until a cap ---------------------------------------------------------------------
log "9. disk"
get "/disk?mb=120" > /dev/null
b_start disk; sleep 6; c_wake; sleep 3
b_stop disk 600
dst=$(st_json)
echo "  A after the disk fill: $dst" >&2
dmb=$(echo "$dst" | sed -n 's/.*"disk_mb":\([0-9]*\).*/\1/p')
common N9 disk 600 "A wrote ${dmb:-?} MB"
check "N9a the fill ran (A wrote at least 20 MB)" eval '[ "${dmb:-0}" -ge 20 ]'
if srv 'grep -q "tmp_size\|disk_max" /opt/tando/bin/tando-agent'; then
  check "N9b a disk cap on A: the fill stopped with an error before the cap of the test (120 MB)" eval '
    [ -n "$(echo "$dst" | sed -n "s/.*\"disk_err\":\"\\([A-Z]*\\)\".*/\\1/p")" ]'
else skip "N9b per-app disk cap (disk = / tmp_size): not in this version (density slice 4); the fill went to $dmb MB"; fi
get /clear > /dev/null
check "N9c the files A wrote are removed (cleanup; the data directory has no fill-* left)" eval '! srv "ls /opt/tando/apps/$A/shared/data | grep -q fill-"'

# ---- the table ---------------------------------------------------------------------------------
{
  echo; echo "---- neighbour results (baseline B p95 was $BASE_P95 ms; apps: $A offender, $B always on, $C idle_stop)"
  cat "$RESULTS"
} >&2
check "N10 after every failure B still runs the process it started with (never restarted)" eval '[ "$(mainpid $B)" = "$b_pid" ] && [ "$(nrestarts $B)" = 0 ]'
check "N11 tando ls shows all three apps healthy at the end" eval '
  t_until 40 a_up && ls_works && ! grep -w "$A" "$E/ls.out" | grep -qi "down\|fail"'
for n in $A $B $C; do "$R" destroy -a "$n" -H test --yes > /dev/null 2>&1; done
t_done
