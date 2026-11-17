#!/bin/bash
# The read-only agent verbs timed on the server itself, three ways: the shell versions (the
# installed agent without its block that execs tando-status, as test/e2e-status.sh makes it), Go
# answering directly (tandod stopped), and Go with tandod running (status is answered there). For
# each, RUNS runs; per run the wall clock and the CPU of everything involved: the process tree
# (bash's `time`), systemd (PID 1) and tandod (both from /proc/<pid>/schedstat, ns); medians.
# Then the peak RSS of tando-status and the floor (sudo, bash, the agent's bash before its exec,
# a Go program's start, the other programs status includes).
#
#   test/load/status-bench.sh <app> [<deploy id>]     (RUNS=15; the server of TANDO_TEST_*)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
SSH=$ROOT/test/server/ssh.sh
RUNS=${RUNS:-15}
app=${1:?usage: status-bench.sh <app> [deploy id]}
id=${2:-}
sed '/^# >>> tando-status/,/^# <<< tando-status/d' "$ROOT/server/tando-agent" |
  "$SSH" 'sudo install -d -m 755 /var/tmp/tando-status-cmp && sudo tee /var/tmp/tando-status-cmp/agent > /dev/null'
# sudo itself (every client call pays it): as the login user
tmp=$(mktemp)
"$SSH" "RUNS=$RUNS bash -s" > "$tmp" <<'EOF'
TIMEFORMAT='%3R %3U %3S'
for ((i = 0; i < RUNS; i++)); do { time sudo -n true; } 2>&1; done
EOF
mid() { sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'; }
echo "sudo -n true: $(awk '{ print int($1 * 1000) }' "$tmp" | mid) ms wall," \
  "$(awk '{ print int(($2 + $3) * 1000) }' "$tmp" | mid) ms cpu (median)"
rm -f "$tmp"
# shellcheck disable=SC2029
# lint: allow RL04 the arguments are the bench's own words, checked by the agent's grammar
"$SSH" "sudo RUNS=$RUNS APP=$app ID=$id bash -s" <<'EOF'
set -u
SH="bash /var/tmp/tando-status-cmp/agent" GO=/opt/tando/bin/tando-agent
TIMEFORMAT='%3R %3U %3S'
med() { sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'; }
D=0   # tandod's pid (0: not running)
ns() { local x=0; [ "$1" != 0 ] && read -r x _ < "/proc/$1/schedstat" 2> /dev/null; echo "${x:-0}"; }
# one <cmd...>: "wall tree total" in microseconds: total = tree + systemd's + tandod's CPU
one() {
  local p0 d0 p1 d1 t
  read -r p0 _ < /proc/1/schedstat; d0=0; [ "$D" != 0 ] && read -r d0 _ < "/proc/$D/schedstat"
  t=$({ time "$@" > /dev/null 2>&1; } 2>&1)
  read -r p1 _ < /proc/1/schedstat; d1=0; [ "$D" != 0 ] && read -r d1 _ < "/proc/$D/schedstat"
  echo "$t" | awk -v p=$((p1 - p0)) -v d=$((d1 - d0)) '{ w = $1 * 1e6; c = ($2 + $3) * 1e6; printf "%d %d %d\n", w, c, c + (p + d) / 1000 }'
}
runs() { local i; for ((i = 0; i < RUNS; i++)); do one "$@"; done; }   # -> lines of one
m() { cut -d' ' -f"$1" | med; }
daemon() { # on|off
  if [ "$1" = on ]; then systemctl start tandod; for i in $(seq 50); do [ -S /run/tandod/tandod.sock ] && break; sleep 0.1; done
  else systemctl stop tandod; fi
  D=$(systemctl show -P MainPID tandod); D=${D:-0}
}
row() { # label sh direct daemon (files of runs)
  awk -v l="$1" -v sw="$(m 1 < "$2")" -v st="$(m 3 < "$2")" -v gw="$(m 1 < "$3")" -v gt="$(m 3 < "$3")" \
      -v dw="$(m 1 < "$4")" -v dt="$(m 3 < "$4")" 'BEGIN {
    printf "%-22s %6.1f %6.1f | %6.1f %6.1f | %6.1f %6.1f | %5.1fx %5.1fx\n", l, sw / 1000, st / 1000, gw / 1000, gt / 1000,
      dw / 1000, dt / 1000, st / (gt ? gt : 1), st / (dt ? dt : 1) }'
}
bench() { # label args...
  local label=$1; shift
  daemon off; runs $SH "$@" > /tmp/.b.sh; runs $GO "$@" > /tmp/.b.go
  daemon on; runs $GO "$@" > /tmp/.b.gd
  row "$label" /tmp/.b.sh /tmp/.b.go /tmp/.b.gd
}
n=$(ls /opt/tando/apps | wc -l)
echo "apps: $n   runs: $RUNS   ms, medians; cpu = process tree + systemd + tandod"
printf '%-22s %13s | %13s | %13s | %13s\n' "" "shell" "Go direct" "Go + tandod" "cpu ratio"
printf '%-22s %6s %6s | %6s %6s | %6s %6s | %6s %6s\n' verb wall cpu wall cpu wall cpu direct tandod
bench "status" status
bench "status $APP" status "$APP"
[ -n "$ID" ] && bench "deploy-status" deploy-status "$APP" "$ID"
bench "releases $APP" releases "$APP"
bench "history $APP" history "$APP"
bench "history (all)" history
bench "busy $APP" busy "$APP"
bench "info" info
daemon on
# peak RSS of tando-status (getrusage RUSAGE_CHILDREN maxrss after it exits; aarch64 and x86_64)
rss() {
  perl -e 'my $p = fork; if (!$p) { open STDOUT, ">", "/dev/null"; exec @ARGV; exit 127 } waitpid $p, 0;
    my $nr = `uname -m` =~ /aarch64/ ? 165 : 98; my $b = "\0" x 144;
    syscall($nr, -1, $b) == 0 or die "getrusage: $!"; my @f = unpack "q18", $b; print $f[4], "\n"' "$@"
}
r1=$(rss /opt/tando/bin/tando-status status); daemon off; r2=$(rss /opt/tando/bin/tando-status status); daemon on; sleep 1
echo "peak RSS (KB): tando-status status via tandod $r1, direct $r2; tandod $(awk '/VmHWM/ { print $2 }' "/proc/$D/status")"
fl() { runs "$@" | m 3 | awk '{ printf "%.1f", $1 / 1000 }'; }
echo "floor (cpu ms, everything): bash -c : $(fl bash -c :); the agent's bash up to its checks (history x bad: dies there) $(fl $GO history "$APP" x);" \
  "tando-status version $(fl /opt/tando/bin/tando-status version); tando-logs log-stats $(fl /opt/tando/bin/tando-logs log-stats);" \
  "tando-watch brief $(fl /opt/tando/bin/tando-watch brief); tando-metrics read $(fl /opt/tando/bin/tando-metrics read "$APP" 16 60)"
rm -f /tmp/.b.sh /tmp/.b.go /tmp/.b.gd
EOF
