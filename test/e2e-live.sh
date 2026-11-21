#!/bin/bash
# End-to-end test of the live views: tandod's 5 s loop (srv/live), `tando-agent status-follow`
# (tando-status follow: status frames pushed every 5 s) and `tando status|ls --follow` on the
# laptop (one ssh session; polling as --watch 5 when the server has no live view), and the budget
# of the fast loop on a server with 25 apps.
#
#   test/e2e-live.sh [--reset]     --reset: recreate the server first (only one this suite owns)
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT. Apps: web (examples/hello,
# deployed) and a01..a24, units written by hand that only sleep (25 loaded app units, cgroups
# and all, without 24 deploys). TANDO_LIVE_BUDGET_S: the budget window (default 300 s).
# Output: PASS/FAIL lines (docs/TESTING.md), summary, exit status.
set -u
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init live
W=$E/w
WINDOW=${TANDO_LIVE_BUDGET_S:-300}

setup() {
  if [ "${1:-}" = --reset ]; then t_server_up --reset || exit 1; else t_server_up || exit 1; fi
  t_host_add test
  "$R" host setup test public_port="$T_HTTP_PORT" >&2 || exit 1
  mkdir -p "$W"; cp -R "$ROOT/examples/hello" "$W/web"
  printf 'app = web\n' >> "$W/web/tando.conf"
  (cd "$W/web" && "$R" up >&2) || exit 1
  "$SSH" 'sudo bash -s' <<'EOF'
set -e
for i in $(seq -w 1 24); do
  a=a$i
  install -d -m 751 /opt/tando/apps/$a
  printf 'port=%s\nrecipe=node\n' $((4100 + 10#$i)) > /opt/tando/apps/$a/app.conf
  printf '[Unit]\nDescription=live test %s\n[Service]\nExecStart=/bin/sleep infinity\n' $a > /etc/systemd/system/tando-$a.service
done
systemctl daemon-reload
for i in $(seq -w 1 24); do systemctl start tando-a$i; done
EOF
}

# ask <live|ring> [app]: tandod's answer (tando-status live|ring asks its socket, as root)
ask() { "$SSH" "sudo /opt/tando/bin/tando-status $*"; }
# cg_usec <cgroup dir under /sys/fs/cgroup>: its CPU so far, in microseconds
cg_usec() { "$SSH" "awk '\$1 == \"usage_usec\" { print \$2 }' /sys/fs/cgroup/$1/cpu.stat"; }
tandod_cg() { "$SSH" 'systemctl show -P ControlGroup tandod' | sed 's,^/,,'; }
# cminflt: the minor faults of tandod's children it waited for (field 11 of /proc/<pid>/stat):
# any program it starts and reaps adds hundreds, so an unchanged count means none was started
cminflt() { "$SSH" 'sudo awk "{ print \$11 }" /proc/$(systemctl show -P MainPID tandod)/stat'; }
frames_in() { local n; n=$(grep -c "${2:-^@end}" "$1" 2> /dev/null); echo "${n:-0}"; }

# an ssh that counts its sessions (the laptop side of --follow: one for the whole view)
mkdir -p "$E/shim"
cat > "$E/shim/ssh" <<EOF
#!/bin/bash
echo "\$*" >> "$E/ssh.log"
exec $(command -v ssh) "\$@"
EOF
chmod +x "$E/shim/ssh"
sessions() { local n; n=$(grep -c 'status' "$E/ssh.log" 2> /dev/null); echo "${n:-0}"; }
# follow_run <out> <args...>: tando <args> --follow in the background with the counting ssh
follow_run() {
  local o=$1; shift
  : > "$E/ssh.log"
  PATH="$E/shim:$PATH" "$R" "$@" --follow > "$o" 2>&1 &
  FPID=$!
}
follow_stop() { kill "$FPID" 2> /dev/null; pkill -P "$FPID" 2> /dev/null; wait "$FPID" 2> /dev/null; }

setup "${1:-}"
"$SSH" 'sudo systemctl is-active -q tandod' || "$SSH" 'sudo systemctl start tandod'
T_UNTIL_STEP=0.2 t_until 20 "$SSH" 'sudo test -S /run/tandod/tandod.sock'
if ! "$SSH" 'test -f /sys/fs/cgroup/cgroup.controllers'; then
  skip "L0 the test server has no cgroup v2: no fast loop to test"; t_done
fi

# ---- the fast loop on the socket ----------------------------------------------------------------
points() { ask "ring web" | grep -c '^rapp	web	'; }   # (the points that have web)
check "L1 tandod keeps a point every 5 s (two within 12 s)" t_until 12 eval '[ "$(points)" -ge 2 ]'
ask live > "$E/live.rows"
check "L2 live: a host row and the 25 app rows (web active and running, a CPU per mille)" eval '
  [ "$(grep -c "^lapp	" "$E/live.rows")" = 25 ] && grep -q "^lhost	[0-9]*	[0-9.]*	[0-9]*	[0-9]*	[0-9]*	" "$E/live.rows" &&
  grep -Eq "^lapp	web	[0-9]+	active	running	[0-9]+	[1-9][0-9]*	[1-9][0-9]*	[0-9]+	[1-9]" "$E/live.rows"'

# ---- status-follow: frames on one connection ----------------------------------------------------
"$SSH" 'sudo timeout 12 /opt/tando/bin/tando-agent status-follow web' > "$E/agent.frames" 2> "$E/agent.err"
check "L3 tando-agent status-follow web: a frame every 5 s, status rows with the live rows (12 s: 3 frames)" eval '
  [ "$(frames_in "$E/agent.frames")" -ge 2 ] && grep -q "^app	web	active	" "$E/agent.frames" &&
  grep -q "^lapp	web	" "$E/agent.frames" && grep -q "^host	" "$E/agent.frames"'

# ---- the laptop: tando status --follow, tando ls --follow ---------------------------------------
follow_run "$E/st.out" status -a web
check "L4 tando status -a web --follow paints a live frame every 5 s" t_until 30 eval '[ "$(frames_in "$E/st.out" "live . updated")" -ge 3 ]'
n0=$(sessions)
pkill -x ssh -P "$FPID"   # (the session ends under it: a new one, frames again, no busy loop)
# shellcheck disable=SC2034 # (read in the eval below)
f0=$(frames_in "$E/st.out" "live . updated")
check "L4a ... a session that ends is opened again and the frames go on" \
  t_until 30 eval '[ "$(sessions)" -gt "$n0" ] && [ "$(frames_in "$E/st.out" "live . updated")" -ge $((f0 + 2)) ]'
cpu=$(ps -o time= -p "$FPID" | awk -F '[:.]' '{ print $1 * 60 + $2 }')
check "L4c ... and the client stays idle between frames (${cpu}s of CPU so far)" test "${cpu:-99}" -lt 5
follow_stop
check "L4b ... each frame the one app once (no frame left in the next)" eval '[ "$(grep -c "^. release  " "$E/st.out")" = "$(frames_in "$E/st.out" "Ctrl-C stops")" ]'
check "L5 ... over one ssh session until it ended ($n0 for the first 3 frames)" t_eq "$n0" 1
grep -q 'cpu .*last 5 s' "$E/st.out"; check "L6 status --follow says the cpu is over the last 5 s" test $? = 0

follow_run "$E/ls.out" ls
t_until 30 eval '[ "$(frames_in "$E/ls.out" "live . updated")" -ge 1 ]'
"$SSH" 'sudo systemctl stop tando-web'; stopped=$SECONDS   # (it died: not tando stop)
check "L7 tando ls --follow: an app that went down shows in the next frames (within 12 s)" \
  t_until 12 eval 'tail -30 "$E/ls.out" | grep -Eq "web +. down"'
log "web shown down $((SECONDS - stopped)) s after it stopped"
follow_stop
"$SSH" 'sudo systemctl start tando-web'

# ---- snapshot --follow (the dashboard's live view): a JSON line every 5 s ------------------------
"$R" snapshot --json --follow -H test > "$E/snap.out" 2> "$E/snap.err" &
SP=$!
check "L11 snapshot --json --follow: a line every 5 s (two within 15 s)" t_until 15 eval '[ "$(grep -c "^{" "$E/snap.out")" -ge 2 ]'
kill "$SP" 2> /dev/null; pkill -P "$SP" 2> /dev/null; wait "$SP" 2> /dev/null
check "L12 ... each line the snapshot: 25 apps, the server clock, its load averages" python3 -c '
import json, sys
ls = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert len(ls) >= 2 and all(len(d["apps"]) == 25 and d["server_now"] > 0 and d["reachable"] for d in ls), ls[-1]' "$E/snap.out"

# ---- fallback: no live view (tandod stopped): polled every 5 s ----------------------------------
"$SSH" 'sudo systemctl stop tandod'
follow_run "$E/poll.out" status -a web
check "L8 without tandod, --follow polls every 5 s (as --watch 5)" t_until 30 eval '[ "$(frames_in "$E/poll.out" "every 5s")" -ge 2 ]'
follow_stop
check "L9 ... one ssh session per refresh ($(sessions))" eval '[ "$(sessions)" -ge 3 ]'
"$R" snapshot --json --follow -H test > "$E/snap0.out" 2>&1 &
SP=$!
t_until 15 eval '! kill -0 "$SP" 2> /dev/null'
wait "$SP"; src=$?
check "L13 ... and snapshot --follow exits 3 at once, printing nothing (the dashboard polls) (exit $src)" eval '[ "$src" = 3 ] && [ ! -s "$E/snap0.out" ]'
"$SSH" 'sudo systemctl start tandod'
T_UNTIL_STEP=0.2 t_until 20 "$SSH" 'sudo test -S /run/tandod/tandod.sock'

# ---- tando top: live frames (one status-follow per server), the views' extras every 10 s ---------
cat > "$E/top.steps" <<'EOF2'
wait apps · test 30
wait · live 20
sleep 16
dump live
send q
exit 10
EOF2
: > "$E/ssh.log"
PATH="$E/shim:$PATH" python3 "$ROOT/test/top-pty.py" 30 100 "$E/top.steps" -- "$R" top > "$E/top.out" 2>&1
# shellcheck disable=SC2034 # (read in the check's eval)
top_rc=$?
nf=$(grep -c 'status-follow' "$E/ssh.log"); ns=$(sessions)
check "L10 tando top follows the server: \"live\" in its title, one status-follow ($nf), $ns sessions in ~20 s (2 s polling: about 10)" \
  eval '[ "$top_rc" = 0 ] && [ "$nf" = 1 ] && [ "$ns" -le 5 ] && sed -n "/^=== live/,/^=== end/p" "$E/top.out" | grep -q "apps 25"'

# ---- budget: 25 apps, the fast loop running, the minute ticks too -------------------------------
cg=$(tandod_cg)
t_until 15 eval '[ "$(points)" -ge 1 ]'
t0=$SECONDS; u0=$(cg_usec "$cg"); s0=$(cg_usec init.scope)
log "budget window: $WINDOW s"
sleep "$WINDOW"   # (a measured window: nothing to wait for)
u1=$(cg_usec "$cg"); s1=$(cg_usec init.scope); dt=$((SECONDS - t0))
pm=$(( (u1 - u0) / dt / 1000 )); spm=$(( (s1 - s0) / dt / 1000 ))   # per mille of one core
log "tandod: $(( (u1 - u0) / 1000 )) ms CPU in $dt s = $((pm / 10)).$((pm % 10))%; systemd (init.scope): $(( (s1 - s0) / 1000 )) ms = $((spm / 10)).$((spm % 10))%"
check "B1 tandod's CPU with 25 apps, averaged over $dt s, is under 1% of a core ($((pm / 10)).$((pm % 10))%)" test "$pm" -lt 10
anon=$("$SSH" "awk '\$1 == \"anon\" { print \$2 }' /sys/fs/cgroup/$cg/memory.stat")
log "tandod anon: $((anon / 1024)) KB"
check "B2 tandod's anonymous memory is under 20 MB ($((anon / 1048576)) MB)" test "$anon" -lt $((20 << 20))
pts=$(points)
check "B3 the ring holds the window's points (one every 5 s: $pts)" test "$pts" -ge $((WINDOW / 5 - 2))

# the fast loop alone (the minute ticks paused: tando-watch.timer stopped): no program started
"$SSH" 'sudo systemctl stop tando-watch.timer'
p0=$(points); c0=$(cminflt); u0=$(cg_usec "$cg"); t0=$SECONDS
sleep 30   # (a measured window: six fast-loop points)
c1=$(cminflt); u1=$(cg_usec "$cg"); dt=$((SECONDS - t0)); p1=$(points)
"$SSH" 'sudo systemctl start tando-watch.timer'
log "fast loop alone: $(( (u1 - u0) / 1000 )) ms CPU in $dt s, $((p1 - p0)) points, children's faults $c0 -> $c1"
check "B4 the fast loop starts no program (tandod reaped no child in $dt s, $((p1 - p0)) points)" eval '[ "$c1" = "$c0" ] && [ $((p1 - p0)) -ge 4 ]'

t_done
