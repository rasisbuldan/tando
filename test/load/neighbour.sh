#!/bin/bash
# Neighbour isolation: measure app B at <rps> (loadgen) for 20 s quiet, then 30 s while app A is
# flooded (wrk <conns> keep-alive on <pathA>); prints both windows. usage: neighbour.sh <A> <pathA> <conns> <B> <pathB> <rps> <out>
set -u
. "$(dirname "$0")/lib.sh"
A=$1 PA=$2 C=$3 B=$4 PB=$5 RPS=$6 OUT=$7
docker cp "$LROOT/test/load/loadgen.js" "$GEN:/root/loadgen.js"
docker exec -d "$GEN" bash -c "node /root/loadgen.js http://127.0.0.1$PB $B.localhost $RPS 2000 55 ka > /root/nb.tsv"
sleep 22
w=$(gx "ulimit -n 100000; wrk -t1 -c$C -d30s --timeout 10s -H 'Host: $A.localhost' http://127.0.0.1:80$PA | grep -E 'Requests/sec|Non-2xx|Socket errors' | tr '\n' ' '")
sleep 6; docker cp "$GEN:/root/nb.tsv" "$OUT.tl"
python3 - "$OUT.tl" <<'PY' | sed "s|^|$B while $A flooded ($C conns): |" | tee -a "$OUT"
import sys
r=[l.split('\t') for l in open(sys.argv[1]) if l[0].isdigit()]
t0=int(r[0][0])
def w(a,b):
  x=[l for l in r if a<=int(l[0])-t0<b]; s=sum(int(l[1]) for l in x); o=sum(int(l[2]) for l in x)
  p=max([float(l[6]) for l in x if l[6]!='-'] or [0]); m=max([float(l[5]) for l in x if l[5]!='-'] or [0])
  e=[l[3]+'/'+l[4] for l in x if l[3]!='-' or l[4]!='-']
  return "sent=%d ok=%d worst_sec_p50_ms=%.0f worst_sec_p99_ms=%.0f errs=%s"%(s,o,m,p,(e[:3] or '-'))
print("quiet[2-20s]: "+w(2,20)+" | flood[24-50s]: "+w(24,50))
PY
echo "  flood on $A: $w" | tee -a "$OUT"
