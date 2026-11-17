#!/bin/bash
# HTTP load steps against one deployed app, through Caddy and straight to the app's port, from the
# load generator container (same network namespace as the server, own CPU).
# usage: test/load/http-steps.sh <app> <port> <path> <out.tsv> [reps] [secs] [conc list] [modes]
#   modes: ka (keep-alive) and close (Connection: close, a new TCP connection per request)
# Each run: one TSV line: when, laptop load, target, mode, conns, wrk RESULT fields, CPU seconds of the
# app unit / caddy / whole server, peak anon MB of app / caddy / whole server, app restarts.
set -u
. "$(dirname "$0")/lib.sh"
APP=$1 PORT=$2 P=$3 OUT=$4 REPS=${5:-3} SECS=${6:-15} CONCS=${7:-"50 200 1000 5000"} MODES=${8:-"ka close"}
TARGETS=${TARGETS:-"caddy direct"}
docker cp "$LROOT/test/load/wrk-report.lua" "$GEN:/root/r.lua"
docker cp "$LROOT/test/load/sampler.sh" "$L:/root/sampler.sh"
ACG=$(sx "systemctl show -P ControlGroup tando-$APP" | sed "s|^/||"); [ -n "$ACG" ] || ACG=system.slice/tando-$APP.service
CGS="$ACG system.slice/caddy.service"
[ -s "$OUT" ] || printf 'time\tload1\ttarget\tmode\tconns\trep\tresult\tcpu_app_s\tcpu_caddy_s\tcpu_total_s\tpeak_app_mb\tpeak_caddy_mb\tpeak_total_mb\trestarts\n' > "$OUT"
for rep in $(seq 1 "$REPS"); do
 for tgt in $TARGETS; do
  for mode in $MODES; do
   for c in $CONCS; do
    if [ "$tgt" = caddy ]; then url=http://127.0.0.1:80$P host=$APP.localhost; else url=http://127.0.0.1:$PORT$P host=""; fi
    close=0; [ "$mode" = close ] && close=1
    n0=$(sx "systemctl show -P NRestarts tando-$APP")
    sx "rm -f /run/samp-stop; nohup /root/sampler.sh /run/samp /run/samp-stop '' $CGS >/dev/null 2>&1 &"
    l=$(load1); t=$(date +%H:%M:%S)
    th=2; [ "$c" -lt 2 ] && th=1
    res=$(gx "ulimit -n 1000000; cd /root; WRK_HOST=$host WRK_CLOSE=$close timeout $((SECS + 60)) wrk -t$th -c$c -d${SECS}s --timeout 10s -s r.lua $url 2>&1" | grep RESULT | sed 's/^RESULT //')
    sx "touch /run/samp-stop"; sleep 1.2
    n1=$(sx "systemctl show -P NRestarts tando-$APP")
    stats=$(docker exec "$L" cat /run/samp | python3 -c '
import sys
rows=[l.rstrip("\n").split("\t") for l in sys.stdin if l.strip()]
by={}
for t,c,cpu,anon,cur,tasks in rows: by.setdefault(c,[]).append((float(t),int(cpu or 0),int(anon or 0)))
def g(c):
  r=by.get(c,[])
  if len(r)<2: return ("-","-")
  return ("%.1f"%((r[-1][1]-r[0][1])/1e6), "%.0f"%(max(x[2] for x in r)/1048576))
a=g(sys.argv[1]); b=g(sys.argv[2]); t=g("TOTAL")
print("\t".join([a[0],b[0],t[0],a[1],b[1],t[1]]))' "$ACG" system.slice/caddy.service)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$t" "$l" "$tgt" "$mode" "$c" "$rep" "${res:-NO-RESULT}" "$stats" "$((n1 - n0))" | tee -a "$OUT" >&2
    sleep "${REST:-5}"
   done
  done
 done
done
