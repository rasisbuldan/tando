#!/bin/bash
# Server under stress from outside tando: a hog unit (not a tando app) pins CPU, eats memory, or the
# tando disk is filled; meanwhile a light request loop (200 rps) measures the live app, and a deploy
# (version bump) + status run. usage: test/load/stress.sh <cpu|mem|disk> <app-dir> <app> <outdir>
set -u
. "$(dirname "$0")/lib.sh"
mode=$1 dir=$2 app=$3 out=$4/$1
mkdir -p "$out"
docker cp "$LROOT/test/load/loadgen.js" "$GEN:/root/loadgen.js"
docker exec "$GEN" pkill -f '^node /root/loadgen'
start_load() { docker exec -d "$GEN" bash -c "node /root/loadgen.js http://127.0.0.1/ $app.localhost 200 200 $1 ka > /root/st-$2.tsv"; }
fetch_load() { docker exec "$GEN" pkill -f '^node /root/loadgen'; sleep 11; docker cp "$GEN:/root/st-$1.tsv" "$out/$1.tl"
  awk -F'\t' '/^[0-9]/{s+=$2; o+=$3; if($5!="-")e++; if($7!="-"&&$7>m)m=$7} END{printf "sent=%d ok=%d secs_with_errors=%d worst_sec_p99_ms=%s\n",s,o,e,m}' "$out/$1.tl"; }
deploy() { local t0 t1 rc; cd "$dir" || return; echo $(( $(cat VERSION) + 1 )) > VERSION
  t0=$(ms); TANDO_SOAK=5 "$R" up > "$out/deploy-$1.out" 2>&1; rc=$?; t1=$(ms)
  echo "deploy rc=$rc $((t1 - t0)) ms: $(grep -E 'live in|failed|✗|error|space|disk' "$out/deploy-$1.out" | tr -s ' ' | head -3 | tr '\n' ' ')"; }
st() { local t0 t1; t0=$(ms); "$R" status -a "$app" > "$out/status-$1.out" 2>&1; t1=$(ms); echo "status rc=$? $((t1 - t0)) ms"; }
{
echo "== $mode $(date +%T) load1=$(load1)"
start_load 600 base; sleep 15; echo "baseline: $(fetch_load base)"
case $mode in
  cpu)  sx "for i in 1 2 3 4; do systemd-run --quiet --unit=loadtest-hog\$i bash -c 'while :; do :; done'; done";;
  mem)  sx "systemd-run --quiet --unit=loadtest-memhog -p MemorySwapMax=0 node -e 'const a=[]; setInterval(()=>{ if (a.length < ${MEMHOG_MB:-1500}/10) a.push(Buffer.alloc(10*1048576, 1)); }, 50)'"; sleep 20
        sx "free -m | head -2; cat /sys/fs/cgroup/memory.current";;
  disk) sx "df -k /opt/tando | tail -1; avail=\$(df -k --output=avail /opt/tando | tail -1); fallocate -l \$(( (avail - ${DISK_LEFT_KB:-20000}) * 1024 )) /opt/tando/loadtest-fill; df -h /opt/tando | tail -1";;
esac
sleep 5
start_load 600 stress; sleep 15
echo "$(st stress)"
echo "$(deploy stress)"
sleep 10
echo "under $mode: $(fetch_load stress)"
case $mode in
  mem) sx "journalctl -k --since -3min --no-pager | grep -i -E 'killed process|oom' | tail -5; systemctl show -p NRestarts,ActiveState tando-$app caddy loadtest-memhog";;
esac
sx "systemctl stop 'loadtest-hog*' loadtest-memhog 2>/dev/null; rm -f /opt/tando/loadtest-fill"
start_load 600 after; sleep 10; echo "after: $(fetch_load after)"
echo "$(deploy after)"
} 2>&1 | tee -a "$out/summary.txt"
