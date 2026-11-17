#!/bin/bash
# Operations under load: while loadgen.js sends <rps> requests/s through Caddy to an app, run
# deploy, a failing deploy, rollback, restart, env set, stop/start; per operation count failed and
# slow requests in its window (start .. end + 3 s), and record what tando said.
# usage: test/load/ops-under-load.sh <app-dir> <app> <path> <rps> <max-inflight> <outdir> [ka|close]
set -u
. "$(dirname "$0")/lib.sh"
DIR=$1 APP=$2 P=$3 RPS=$4 MAXIN=$5 OUT=$6 MODE=${7:-ka}
OPS=${OPS:-"deploy faildeploy rollback restart envset stopstart"}
mkdir -p "$OUT"
docker cp "$LROOT/test/load/loadgen.js" "$GEN:/root/loadgen.js"
cd "$DIR" || exit 1
ev() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$OUT/ops.tsv"; }
: > "$OUT/ops.tsv"
docker exec "$GEN" pkill -f '^node /root/loadgen'; rm -f "$OUT/timeline.tsv"
docker exec -d "$GEN" bash -c "node /root/loadgen.js http://127.0.0.1$P $APP.localhost $RPS $MAXIN ${LOADSECS:-600} $MODE > /root/tl.tsv 2>/root/tl.err"
# EXTRA_WRK=<conns>: also saturate the server with wrk keep-alive (near collapse); loadgen measures
if [ -n "${EXTRA_WRK:-}" ]; then docker exec "$GEN" pkill -x wrk
  docker exec -d "$GEN" bash -c "ulimit -n 100000; wrk -t1 -c$EXTRA_WRK -d${LOADSECS:-600}s --timeout 10s -H 'Host: $APP.localhost' http://127.0.0.1:80$P > /root/wrk-extra.out 2>&1"; fi
log "load $RPS rps (max $MAXIN in flight, $MODE) on $APP; laptop load $(load1)"
sleep 15
ver=$(cat VERSION 2>/dev/null || echo 1)
for op in $OPS; do
  t0=$(date +%s); l=$(load1)
  case $op in
    deploy)     ver=$((ver + 1)); echo "$ver" > VERSION; "$R" up > "$OUT/$op.out" 2>&1; rc=$?;;
    faildeploy) cp server.js server.js.good; { echo 'process.exit(3);'; cat server.js.good; } > server.js
                echo $((ver + 1)) > VERSION; "$R" up > "$OUT/$op.out" 2>&1; rc=$?
                mv server.js.good server.js; echo "$ver" > VERSION;;
    rollback)   "$R" rollback > "$OUT/$op.out" 2>&1; rc=$?;;
    restart)    "$R" restart > "$OUT/$op.out" 2>&1; rc=$?;;
    envset)     "$R" env set "GREETING=g$t0" > "$OUT/$op.out" 2>&1; rc=$?;;
    stopstart)  "$R" stop > "$OUT/$op.out" 2>&1; rc=$?; sleep 3; "$R" start >> "$OUT/$op.out" 2>&1; rc=$((rc + $?));;
    slowdeploy) "$R" env set SLOW_START="${SLOW:-20}" > "$OUT/$op.envout" 2>&1
                ver=$((ver + 1)); echo "$ver" > VERSION; "$R" up > "$OUT/$op.out" 2>&1; rc=$?;;
  esac
  t1=$(date +%s)
  ev "$op" "$t0" "$t1" "rc=$rc load1=$l"
  log "$op rc=$rc $((t1 - t0)) s: $(grep -E 'live in|failed|rolled|kept|error|✗' "$OUT/$op.out" | tail -2 | tr -s ' ' | tr '\n' ' ')"
  sleep "${GAP:-10}"
done
docker exec "$GEN" pkill -f '^node /root/loadgen'; docker exec "$GEN" pkill -INT -x wrk; sleep 12; docker cp "$GEN:/root/wrk-extra.out" "$OUT/" 2>/dev/null
docker cp "$GEN:/root/tl.tsv" "$OUT/timeline.tsv"
"$R" history > "$OUT/history.out" 2>&1
python3 - "$OUT/timeline.tsv" "$OUT/ops.tsv" <<'PY' | tee "$OUT/summary.txt"
import sys
tl=[l.rstrip("\n").split("\t") for l in open(sys.argv[1]) if l[0].isdigit()]
ops=[l.rstrip("\n").split("\t") for l in open(sys.argv[2])]
def win(a,b):
  sent=ok=bad=capped=0; mx=0; p99=0; kinds={}
  for r in tl:
    t=int(r[0])
    if a<=t<=b:
      sent+=int(r[1]); ok+=int(r[2]); capped+=int(r[8])
      for f in (r[3],r[4]):
        if f!='-':
          for kv in f.split(','):
            k,v=kv.rsplit(':',1); kinds[k]=kinds.get(k,0)+int(v); bad+=int(v)
      if r[7]!='-': mx=max(mx,float(r[7]))
      if r[6]!='-': p99=max(p99,float(r[6]))
  return sent,ok,bad,capped,mx,p99,kinds
first=int(tl[0][0]); s=win(first+2, int(ops[0][1])-1)
print("baseline        secs=%d sent=%d ok=%d failed=%d capped=%d worst_sec_p99_ms=%.0f max_ms=%.0f kinds=%s"%(int(ops[0][1])-1-first-2,s[0],s[1],s[2],s[3],s[5],s[4],s[6]))
for op,a,b,note in ops:
  a=int(a); b=int(b); s=win(a,b+3)
  print("%-14s %3ds sent=%d ok=%d failed=%d capped=%d worst_sec_p99_ms=%.0f max_ms=%.0f kinds=%s %s"%(op,b-a,s[0],s[1],s[2],s[3],s[5],s[4],s[6],note))
PY
