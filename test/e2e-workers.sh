#!/bin/bash
# End-to-end test of workers (worker.<name> = <command> in tando.conf; docs/CONFIG.md "Workers"):
# long-running processes beside the web one, one unit each (tando-<app>_worker-<name>.service).
# A deploy with one, then two workers (the new release's code, as the app's user, with its env);
# a second deploy replaces them (no process of the old release left; the old worker's stop is
# graceful and ends before the new one starts); a release whose worker crashes at start fails and
# the old workers run again; rollback; stop and start; env set; a removed worker's unit goes; a
# worker that keeps crashing is restarted and reported; its memory cap; logs --worker; names and
# recipes that are refused; destroy leaves nothing.
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT (test/all.sh sets them).
# bash 3.2 compatible.
set -u
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init workers
W=$E/w A=wk
dxs() { docker exec -i "$TANDO_TEST_NAME" bash -c "$1"; }       # root on the test server
D=/opt/tando/apps/$A

t_server_up --reset || exit 1
t_host_add test
"$R" host setup test public_port="$T_HTTP_PORT" >&2 || { fail "0 host setup"; t_done; }

# the app: examples/hello as its web process, and w.js as every worker. A worker writes
# <name>.info into the data directory (its release, uid, version, env value), appends start, term
# and done lines with its pid to <name>.log; on SIGTERM it takes WK_STOP_MS before it exits.
# CRASH_<name> in the release: it exits 1 at start; CRASHLATE_<name>: 6 s after it.
mkdir -p "$W/$A"
cp "$ROOT/examples/hello/server.js" "$W/$A/"; echo 1 > "$W/$A/VERSION"
cat > "$W/$A/w.js" << 'EOF'
const fs = require('fs');
const n = process.env.TANDO_WORKER, d = process.env.TANDO_DATA_DIR;
const log = (s) => fs.appendFileSync(`${d}/${n}.log`, `${s} ${process.pid}\n`);
if (fs.existsSync(`CRASH_${n}`)) { console.error(`worker ${n}: crashing on purpose`); process.exit(1); }
if (fs.existsSync(`CRASHLATE_${n}`)) setTimeout(() => { console.error(`worker ${n}: late crash`); process.exit(1); }, 6000);
log('start');
fs.writeFileSync(`${d}/${n}.info`, `rel=${process.env.TANDO_RELEASE} uid=${process.getuid()} ` +
  `v=${fs.readFileSync('VERSION', 'utf8').trim()} env=${process.env.WKVAL || '-'}\n`);
console.log(`worker ${n} running v${fs.readFileSync('VERSION', 'utf8').trim()}`);
process.on('SIGTERM', () => { log('term'); setTimeout(() => { log('done'); process.exit(0); }, Number(process.env.WK_STOP_MS || 0)); });
setInterval(() => {}, 1000);
EOF
conf() { # extra tando.conf lines
  { printf 'app = %s\nrecipe = node\nstart = node server.js\nhealth = /health\nmemory = 128M\ndata = data\n' "$A"
    printf '%s\n' "$@"; } > "$W/$A/tando.conf"
}
deploy() { (cd "$W/$A" && "$R" "${1:-deploy}" > "$E/out" 2>&1); }
cur() { dxs "readlink $D/current" | sed 's|.*/||'; }
info() { dxs "cat $D/shared/data/$1.info 2> /dev/null"; }
wstate() { dxs "systemctl show -P ActiveState tando-${A}_worker-$1.service"; }
wpid() { dxs "systemctl show -P MainPID tando-${A}_worker-$1.service"; }
# every process of the app's user runs in the release current points at (no older generation left)
one_gen() {
  local c; c=$(cur)
  dxs "for p in \$(pgrep -u tando-$A); do r=\$(readlink /proc/\$p/cwd); echo \${r##*/}; done | sort -u" > "$E/gens"
  [ "$(cat "$E/gens")" = "$c" ] || { echo "  processes run in: $(tr '\n' ' ' < "$E/gens"), current is $c" >&2; return 1; }
}
info_is() { # name want-substring
  local i; i=$(info "$1")
  case $i in *"$2"*) return 0;; esac
  echo "  $1.info: [$i], want [$2]" >&2; return 1
}

# ---- 1. one worker -----------------------------------------------------------------------------
log "1. a deploy with one worker"
conf 'worker.q = node w.js'
if deploy up; then pass "W1 tando up with worker.q"; else fail "W1 tando up with worker.q: $(tail -5 "$E/out")"; fi
R1=$(cur)
uid=$(dxs "id -u tando-$A")
check "W2 worker q runs release $R1 (v1) as the app's user ($uid)" info_is q "rel=$R1 uid=$uid v=1"
t_eq "$(wstate q)" active && pass "W3 its unit tando-${A}_worker-q.service is active" || fail "W3 worker unit not active"
t_eq "$(dxs "systemctl is-enabled tando-${A}_worker-q.service")" enabled &&
  pass "W4 its unit is enabled (it starts at boot)" || fail "W4 worker unit not enabled"
x=$(dxs "for p in User Slice WorkingDirectory; do systemctl show -P \$p tando-${A}_worker-q.service; done | tr '\n' ' '")
t_eq "$x" "tando-$A tando-$A.slice $D/current " && pass "W5 as the app's user, in its slice, in its release: $x" || fail "W5 user, slice, working directory: $x"
x=$(dxs "systemctl cat tando-${A}_worker-q.service" | grep -c 'SocketBindDeny=any')
[ "$x" = 1 ] && pass "W6 the worker has no listening socket (the job sandbox)" || fail "W6 sandbox: SocketBindDeny lines $x"

# ---- 2. two workers, replaced by the next deploy, gracefully -------------------------------------
log "2. two workers; a deploy replaces them (graceful stop)"
(cd "$W/$A" && "$R" env set WK_STOP_MS=5000 > "$E/env.out" 2>&1) || fail "W7 env set WK_STOP_MS: $(tail -3 "$E/env.out")"
lastpid() { dxs "sed -n 's/^start //p' $D/shared/data/$1.log | tail -1"; }
oldq=$(lastpid q)
echo 2 > "$W/$A/VERSION"
conf 'worker.q = node w.js' 'worker.mail = node w.js'
t0=$(date +%s)
if deploy; then pass "W8 deploy with two workers ($(( $(date +%s) - t0 )) s)"; else fail "W8 deploy with two workers: $(tail -5 "$E/out")"; fi
R2=$(cur)
check "W9 worker q runs the new release $R2 (v2)" info_is q "rel=$R2 uid=$uid v=2"
check "W10 worker mail runs the new release $R2 (v2)" info_is mail "rel=$R2 uid=$uid v=2"
check "W11 no process of the older release is left" one_gen
# the old q got TERM, took its 5 s and ended; only then the new one started
dxs "cat $D/shared/data/q.log" > "$E/q.log"
newq=$(lastpid q)
t_eq "$(wpid q)" "$newq" && pass "W12a the worker's command is its unit's main process (no shell between)" || fail "W12a main pid $(wpid q), worker $newq"
lt=$(grep -n "^term $oldq\$" "$E/q.log" | cut -d: -f1) ld=$(grep -n "^done $oldq\$" "$E/q.log" | cut -d: -f1)
ls=$(grep -n "^start $newq\$" "$E/q.log" | cut -d: -f1)
if [ -n "$lt" ] && [ -n "$ld" ] && [ -n "$ls" ] && [ "$lt" -lt "$ld" ] && [ "$ld" -lt "$ls" ]; then
  pass "W12 the old worker had its stop time (term, 5 s, done) and the new one started after it"
else fail "W12 graceful stop: old $oldq new $newq; log: $(tr '\n' ' ' < "$E/q.log")"; fi

# ---- 3. a release whose worker crashes at start ---------------------------------------------------
log "3. a worker that crashes at start fails the deploy"
(cd "$W/$A" && "$R" env set WK_STOP_MS=0 > "$E/env.out" 2>&1)
echo 3 > "$W/$A/VERSION"; touch "$W/$A/CRASH_mail"
if deploy; then fail "W13 a deploy whose worker crashes at start was accepted"
else
  case $(cat "$E/out") in *mail*) pass "W13 the deploy failed and names the worker: $(grep -i 'mail' "$E/out" | head -1 | cut -c1-150)";;
    *) fail "W13 the deploy failed without naming the worker: $(tail -4 "$E/out")";; esac
fi
rm -f "$W/$A/CRASH_mail"
t_eq "$(cur)" "$R2" && pass "W14 back on $R2" || fail "W14 current is $(cur), not $R2"
T_UNTIL_STEP=0.5 t_until 20 info_is mail "rel=$R2 uid=$uid v=2" && T_UNTIL_STEP=0.5 t_until 20 eval '[ "$(wstate mail)" = active ]' &&
  pass "W15 the old workers run again (mail on $R2)" || fail "W15 mail after the failed deploy: $(wstate mail) $(info mail)"
check "W16 no process of the refused release is left" one_gen
x=$(dxs "tail -1 $D/history.tsv" | cut -f4)
t_eq "$x" rolledback && pass "W17 history says rolledback" || fail "W17 history: $x"

# ---- 4. rollback ----------------------------------------------------------------------------------
log "4. rollback to release 1 (one worker)"
if (cd "$W/$A" && "$R" rollback > "$E/rb.out" 2>&1); then pass "W18 tando rollback"; else fail "W18 rollback: $(tail -4 "$E/rb.out")"; fi
check "W19 worker q runs $R1 (v1) again" info_is q "rel=$R1 uid=$uid v=1"
x=$(dxs "test -e /etc/systemd/system/tando-${A}_worker-mail.service && echo file; systemctl show -P ActiveState tando-${A}_worker-mail.service")
t_eq "$x" inactive && pass "W20 release 1 has no worker mail: its unit is gone" || fail "W20 mail after rollback: $x"
check "W21 no process of $R2 is left" one_gen

# ---- 5. stop and start ------------------------------------------------------------------------
log "5. stop and start"
deploy > /dev/null 2>&1   # (back to v3 with both workers, as tando.conf says)
R3=$(cur)
(cd "$W/$A" && "$R" stop > "$E/st.out" 2>&1)
x="$(wstate q) $(wstate mail) $(dxs "systemctl is-enabled tando-${A}_worker-q.service tando-${A}_worker-mail.service | tr '\n' ' '")"
t_eq "$x" "inactive inactive disabled disabled " && pass "W22 tando stop stops and disables the workers" || fail "W22 after stop: $x"
(cd "$W/$A" && "$R" start > "$E/st.out" 2>&1)
x="$(wstate q) $(wstate mail) $(dxs "systemctl is-enabled tando-${A}_worker-q.service tando-${A}_worker-mail.service | tr '\n' ' '")"
t_eq "$x" "active active enabled enabled " && pass "W23 tando start starts and enables them" || fail "W23 after start: $x"
check "W24 they run $R3" info_is q "rel=$R3"

# ---- 6. env set ---------------------------------------------------------------------------------
log "6. env set restarts the workers with the new env"
(cd "$W/$A" && "$R" env set WKVAL=e2 > "$E/env.out" 2>&1)
T_UNTIL_STEP=0.5 t_until 15 info_is q "env=e2" && T_UNTIL_STEP=0.5 t_until 15 info_is mail "env=e2" &&
  pass "W25 both workers run with WKVAL=e2" || fail "W25 env: q [$(info q)] mail [$(info mail)]"

# ---- 7. status, ls, logs ------------------------------------------------------------------------
log "7. status, ls, logs --worker"
(cd "$W/$A" && "$R" status > "$E/status.out" 2>&1)
grep -q 'worker *mail *running' "$E/status.out" && grep -q 'worker *q *running' "$E/status.out" &&
  pass "W26 tando status shows both workers running" || fail "W26 status: $(grep -i worker "$E/status.out" | tr '\n' ' ')"
(cd "$W/$A" && "$R" logs --worker mail -n 50 > "$E/logs.out" 2>&1)
if grep -q 'worker mail running' "$E/logs.out" && ! grep -q 'worker q running' "$E/logs.out" && ! grep -q "hello v" "$E/logs.out"; then
  pass "W27 tando logs --worker mail shows that worker's output only"
else fail "W27 logs --worker: $(head -5 "$E/logs.out" | tr '\n' ' ')"; fi
(cd "$W/$A" && "$R" logs --worker nope > "$E/logs.out" 2>&1) && fail "W28 logs --worker of no worker was accepted" ||
  { grep -q 'no worker nope' "$E/logs.out" && pass "W28 logs --worker nope: $(tail -1 "$E/logs.out")" || fail "W28 logs --worker nope said: $(tail -2 "$E/logs.out")"; }

# ---- 8. memory, removal, a worker that keeps crashing ---------------------------------------------
log "8. memory cap, a removed worker, a worker that keeps crashing"
echo 4 > "$W/$A/VERSION"; touch "$W/$A/CRASHLATE_q"
conf 'worker.q = node w.js' 'worker.q.memory = 96M' 'worker.q.stop_timeout = 7'
deploy || fail "W29 deploy that removes mail: $(tail -4 "$E/out")"
R4=$(cur)
x=$(dxs "systemctl show -P MemoryMax tando-${A}_worker-q.service; systemctl show -P TimeoutStopUSec tando-${A}_worker-q.service" | tr '\n' ' ')
t_eq "$x" "100663296 7s " && pass "W29 worker.q.memory = 96M and stop_timeout = 7 are its unit's MemoryMax and stop time" || fail "W29 limits: $x"
x=$(dxs "sed -n 's/^MemoryMax=//p' '/etc/systemd/system/tando-$A.slice'")
t_eq "$x" "$((128 * 3 + 96))M" && pass "W30 the app's slice counts the worker's cap ($x)" || fail "W30 slice MemoryMax=$x"
x=$(dxs "ls /etc/systemd/system/ | grep -c '^tando-${A}_worker-mail'; systemctl show -P ActiveState tando-${A}_worker-mail.service" | tr '\n' ' ')
t_eq "$x" "0 inactive " && pass "W31 the removed worker mail: no unit file, not running" || fail "W31 removed worker: $x"
# q exits 6 s after each start: systemd restarts it (backoff), the web process is untouched
wr() { [ "$(dxs "systemctl show -P NRestarts tando-${A}_worker-q.service")" -ge 2 ] 2> /dev/null; }
T_UNTIL_STEP=1 t_until 60 wr && pass "W32 the crashing worker is restarted by systemd ($(dxs "systemctl show -P NRestarts tando-${A}_worker-q.service") restarts)" ||
  fail "W32 restarts: $(dxs "systemctl show -P NRestarts,ActiveState,SubState tando-${A}_worker-q.service | tr '\n' ' '")"
x=$(curl -s -m 5 "$(t_url "$A")")
case $x in "hello v4"*) pass "W33 the web process still serves ($x)";; *) fail "W33 web: $x";; esac
(cd "$W/$A" && "$R" status > "$E/status.out" 2>&1)
grep -Eq 'worker +q .*restarts +[1-9]' "$E/status.out" &&
  pass "W34 tando status reports it: $(grep 'worker' "$E/status.out" | tr -s ' ' | head -1)" || fail "W34 status: $(grep -i worker "$E/status.out" | tr '\n' ' ')"
rm -f "$W/$A/CRASHLATE_q"

# ---- 9. refused ---------------------------------------------------------------------------------
log "9. names and recipes that are refused"
refused() { # id text expected-message tando.conf-lines...
  local id=$1 what=$2 want=$3; shift 3
  conf "$@"
  if deploy; then fail "$id $what was accepted"
  elif grep -q "$want" "$E/out"; then pass "$id $what is refused: $(grep "$want" "$E/out" | head -1 | sed 's/^ *//' | cut -c1-120)"
  else fail "$id $what: $(tail -3 "$E/out")"; fi
}
refused W35 "a worker name with capitals" "bad worker name" 'worker.Bad = node w.js'
refused W36 "a worker name of 22 characters" "longer than 21" 'worker.abcdefghijklmnopqrstuv = node w.js'
refused W37 "a worker with a job's name" "name of a job" 'worker.tick = node w.js' 'job.tick = daily | true'
refused W38 "a worker's memory without the worker" "no worker.x" 'worker.x.memory = 64M'
refused W39 "an unknown worker setting" "unknown key" 'worker.q = node w.js' 'worker.q.count = 2'
x=$(printf 'recipe=node\nstart=node server.js\nworker.-x=y\n' | dxs "/opt/tando/bin/tando-agent configure $A" 2>&1)
case $x in *"bad worker name"*) pass "W40 the server refuses a bad worker name too: $x";; *) fail "W40 server: $x";; esac
x=$(printf 'recipe=static\nworker.q=y\n' | dxs "/opt/tando/bin/tando-agent configure $A" 2>&1)
case $x in *"not supported for a static site"*) pass "W41 the server refuses workers for a static site";; *) fail "W41 server static: $x";; esac
mkdir -p "$W/site"; echo hi > "$W/site/index.html"
printf 'app = wksite\nrecipe = static\nworker.q = node w.js\n' > "$W/site/tando.conf"
(cd "$W/site" && "$R" up > "$E/site.out" 2>&1) && fail "W42 a static site with a worker was accepted" ||
  { grep -q 'static site' "$E/site.out" && pass "W42 static: $(grep 'static site' "$E/site.out" | head -1 | cut -c1-110)" || fail "W42 static: $(tail -2 "$E/site.out")"; }
printf 'app = wkbox\nrecipe = container\ncontainer_port = 8080\nworker.q = x\n' > "$W/site/tando.conf"
(cd "$W/site" && "$R" up > "$E/site.out" 2>&1) && fail "W43 a container app with a worker was accepted" ||
  { grep -q 'container' "$E/site.out" && pass "W43 container: $(grep 'container' "$E/site.out" | head -1 | cut -c1-110)" || fail "W43 container: $(tail -2 "$E/site.out")"; }
t_eq "$(cur)" "$R4" && pass "W44 the refused configures left the app on $R4" || fail "W44 current $(cur)"

# ---- 10. destroy --------------------------------------------------------------------------------
log "10. destroy"
conf 'worker.q = node w.js'
(cd "$W/$A" && "$R" destroy --purge --yes > "$E/d.out" 2>&1) || fail "W45 destroy: $(tail -3 "$E/d.out")"
gone() { x=$(dxs "find /etc/systemd/system -name 'tando-${A}[_.-]*' | grep -c .; systemctl list-units --all --plain --no-legend 'tando-${A}_*' | grep -c .; pgrep -c -u $uid" | tr '\n' ' '); [ "$x" = "0 0 0 " ]; }
T_UNTIL_STEP=0.5 t_until 10 gone
dxs "systemctl list-units --all --plain --no-legend 'tando-${A}_*'" >&2
t_eq "$x" "0 0 0 " && pass "W45 destroy leaves no unit file, no unit, no process" || fail "W45 after destroy (files units processes): $x"
t_done
