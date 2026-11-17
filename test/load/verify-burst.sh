#!/bin/bash
# Burst repro + recovery watch: one wrk run (keep-alive) of <conns> through Caddy, then every 5 s for
# <watch> seconds: direct and Caddy answer, app anon MB, restarts, unit state.
# usage: test/load/verify-burst.sh <app> <port> <path> <conns> <secs> <watch> <out.tsv>
set -u
. "$(dirname "$0")/lib.sh"
APP=$1 PORT=$2 P=$3 C=$4 S=$5 W=$6 OUT=$7
TARGETS=${VT:-caddy} REST=0 /bin/bash "$LROOT/test/load/http-steps.sh" "$APP" "$PORT" "$P" "$OUT" 1 "$S" "$C" ka
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt "$W" ]; do
  sx "printf '%s\t+%ss\tdirect=%s\tcaddy=%s\tanon=%sMB\trestarts=%s\tstate=%s\tcaddy_anon=%sMB\n' \"\$(date +%T)\" $(( $(date +%s) - t0 )) \
    \"\$(curl -s -m 5 -o /dev/null -w '%{http_code}/%{time_total}' 127.0.0.1:$PORT$P)\" \
    \"\$(curl -s -m 5 -o /dev/null -w '%{http_code}/%{time_total}' -H 'Host: $APP.localhost' 127.0.0.1$P)\" \
    \$(( \$(awk '\$1==\"anon\"{print \$2}' /sys/fs/cgroup\$(systemctl show -P ControlGroup tando-$APP)/memory.stat 2>/dev/null || echo 0) / 1048576 )) \
    \$(systemctl show -P NRestarts tando-$APP) \$(systemctl is-active tando-$APP) \
    \$(( \$(awk '\$1==\"anon\"{print \$2}' /sys/fs/cgroup/system.slice/caddy.service/memory.stat) / 1048576 ))" | tee -a "${OUT%.tsv}.watch"
  sleep 5
done
sx "journalctl -u tando-$APP -u tando-watch --since '-$((W + S + 30))s' --no-pager -o cat | grep -i -E 'oom|restart|liveness|heap|Failed|killed' | sort | uniq -c | head -15" | tee -a "${OUT%.tsv}.journal"
