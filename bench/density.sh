#!/bin/bash
# Density at scale (not part of the test tiers): N apps with idle_stop on one Docker test server.
#
#   bench/density.sh [N] [P]        N apps (default 150), P `tando up` at once (default 4)
#
# Measures, at every 50 apps: `systemctl daemon-reload` (3 runs), PID 1 RSS, units loaded; then
# with every app idle: running journald namespace instances and their RSS; then the creation of
# 3 more apps (wall time and the daemon-reloads it caused); then the PID 1 question of the squeeze
# audit (it grew to 535 MB once after wake sockets were driven into systemd's trigger limit):
# STORM_APPS apps (default 5) made to fail at start, STORM_CYCLES rounds (default 4) of 80 s
# with a request a second to each (start limit, then the socket's trigger limit), recovery
# (reset-failed and start the socket) and a daemon-reload, PID 1 RSS after each round.
# OLD=<another tando checkout>: also creates 3 apps with that checkout's agent (host setup with
# it first, back to this one afterwards), for a before/after.
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT (as the suites; a name and
# ports of your own). Output: lines on stdout, also in test/.density-<server>/results. Takes
# about 1 minute per 10 apps on a laptop.
set -u
# lint: allow RL03 the suites' own test/lib.sh
. "$(cd "$(dirname "$0")/.." && pwd -P)/test/lib.sh"
t_init density
N=${1:-150} P=${2:-4} K=${STORM_APPS:-5} C=${STORM_CYCLES:-4}
OUT=$E/results W=$E/w
say() { echo "$*" | tee -a "$OUT"; }
t_server_up || exit 1
t_host_add test
"$R" host setup test public_port="$T_HTTP_PORT" > "$E/setup.log" 2>&1 || { echo "host setup failed: $E/setup.log" >&2; exit 1; }
mkdir -p "$W"

# the app: Node, no dependencies; it exits at start while /etc/tando-bench-crash-<app> exists
mkapp() { # name dir
  mkdir -p "$2"
  cat > "$2/server.js" << 'EOF'
const fs = require('fs'), http = require('http'), me = require('os').userInfo().username;
if (fs.existsSync('/etc/tando-bench-crash-' + me.replace(/^tando-/, ''))) { console.error('crash on purpose'); process.exit(1); }
http.createServer((q, s) => s.end('ok\n')).listen(process.env.PORT, '127.0.0.1');
EOF
  printf 'app = %s\nrecipe = node\nstart = node server.js\nmemory = 64M\nidle_stop = 30s\nhealth_timeout = 15\n' "$1" > "$2/tando.conf"
}
up() { # name -> "<name> <rc> <seconds>"
  local t0=$SECONDS rc
  (cd "$W/$1" && "$R" up --yes > "$W/$1.log" 2>&1); rc=$?
  echo "$1 $rc $((SECONDS - t0))"
}
srv() { "$SSH" "$@" 2> /dev/null; }
pid1() { srv 'ps -o rss= -p 1' | tr -d ' '; }
reload3() { srv 'for i in 1 2 3; do s=$(date +%s%N); sudo systemctl daemon-reload; echo $(( ($(date +%s%N) - s) / 1000000 )); done' | tr '\n' ' '; }
units() { srv 'systemctl list-units --all --no-legend --plain | wc -l' | tr -d ' '; }
reloads_since() { srv "journalctl _PID=1 --since @$1 --no-pager -o cat" | grep -c '^Reloading finished'; }
mark() { local t; t=$(srv 'date +%s'); sleep 1; echo "$t"; }

say "density: $N apps with idle_stop = 30s, $P at once, server $T_NAME"
say "apps reload_ms(3) pid1_rss_kb units fails"
i=1 fails=0
while [ $i -le "$N" ]; do
  j=0
  while [ $j -lt "$P" ] && [ $i -le "$N" ]; do
    n=$(printf 'd%03d' $i); mkapp "$n" "$W/$n"
    up "$n" >> "$E/up.tsv" &
    i=$((i + 1)) j=$((j + 1))
  done
  wait
  if [ $(((i - 1) % 50)) = 0 ] || [ $i -gt "$N" ]; then
    fails=$(awk '$2 != 0' "$E/up.tsv" | wc -l | tr -d ' ')
    say "$((i - 1)) $(reload3)$(pid1) $(units) $fails"
  fi
done
awk '$2 != 0 { print "failed: " $1 " (log: '"$W"'/" $1 ".log)" }' "$E/up.tsv" | tee -a "$OUT"
say "up seconds per app (P at once): $(awk '{ s += $3; n++ } END { if (n) printf "%.1f", s / n }' "$E/up.tsv")"

# every app idle: their journald instances
idle_all() { [ "$(srv "systemctl list-units --state=active --no-legend --plain 'tando-d*.service' | grep -c '^tando-d[0-9]*\\.service'")" = 0 ]; }
t_until 300 idle_all || say "not every app went idle within 300 s"
jn() { srv "systemctl list-units --state=active --no-legend --plain 'systemd-journald@tando-d*.service' | wc -l" | tr -d ' '; }
jr() { srv "ps -C systemd-journald -o rss=,args= | awk '/tando-d/ { s += \$1 } END { print s + 0 }'"; }
settled() { [ "$(jn)" = 0 ]; }
t_until 120 settled
say "idle: journald instances running $(jn) of $N, their RSS $(jr) kB, PID 1 RSS $(pid1) kB"

# creating an app now: wall time and the daemon-reloads it caused
create3() { # label tando-cli prefix
  local k t0 r
  for k in 1 2 3; do
    mkapp "$3$k" "$W/$3$k"; t0=$(mark)
    r=$(R=$2 up "$3$k")
    say "$1: new app $r s, daemon-reloads $(reloads_since "$t0")"
  done
}
create3 "this checkout" "$R" n
if [ -n "${OLD:-}" ]; then
  "$OLD/bin/tando" host setup test public_port="$T_HTTP_PORT" > "$E/setup-old.log" 2>&1 &&
    create3 "OLD ($OLD)" "$OLD/bin/tando" o
  "$R" host setup test public_port="$T_HTTP_PORT" > "$E/setup-back.log" 2>&1
fi

# PID 1 and wake sockets in their trigger limit, again and again
say "storm: $K apps failing at start, $C rounds; PID 1 RSS (kB) before: $(pid1)"
s=1; while [ $s -le "$K" ]; do srv "sudo touch /etc/tando-bench-crash-$(printf 'd%03d' $s)"; s=$((s + 1)); done
c=1; line=""
while [ $c -le "$C" ]; do
  # a request a second to each for 80 s: 5 failed starts in 60 s (the app's start limit), then
  # the wake socket's trigger limit (systemd fails the socket)
  end=$((SECONDS + 80))
  while [ $SECONDS -lt $end ]; do
    s=1
    while [ $s -le "$K" ]; do curl -s -o /dev/null --max-time 2 "$(t_url "$(printf 'd%03d' $s)")" & s=$((s + 1)); done
    sleep 1
  done
  wait
  failed=$(srv "systemctl list-units --state=failed --no-legend --plain 'tando-d*_wake.socket' | wc -l" | tr -d ' ')
  # recovery (as recover-all does it for a socket that failed), then a reload as a deploy would
  s=1
  while [ $s -le "$K" ]; do
    n=$(printf 'd%03d' $s)
    srv "sudo systemctl reset-failed tando-$n.service tando-${n}_wake.service tando-${n}_wake.socket; sudo systemctl start tando-${n}_wake.socket"
    s=$((s + 1))
  done
  srv 'sudo systemctl daemon-reload'
  line="$line $(pid1)/$failed"
  c=$((c + 1))
done
say "storm: PID 1 RSS kB/failed sockets per round:$line"
s=1; while [ $s -le "$K" ]; do srv "sudo rm -f /etc/tando-bench-crash-$(printf 'd%03d' $s)"; s=$((s + 1)); done
srv 'sudo /opt/tando/bin/tando-agent recover-all > /dev/null 2>&1'
say "after: PID 1 RSS $(pid1) kB; d001 answers: $(curl -s --max-time 20 "$(t_url d001)")"
