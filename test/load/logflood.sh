#!/bin/bash
# Chatty app: while logflood writes <rounds> x <lines> lines of <size> bytes (in parallel requests),
# time `tando logs -n 100` every few seconds, then read the journal size against log_max (16M in
# examples/logflood) and journald's suppression notices. usage: test/load/logflood.sh <out> <rounds> <lines> <size>
set -u
. "$(dirname "$0")/lib.sh"
out=$1 rounds=$2 lines=$3 size=$4
mkdir -p "$out"
sx "du -sb /var/log/journal/*.tando-logflood 2>/dev/null"
t0=$(ms)
sx "for i in \$(seq 1 $rounds); do curl -s -m 600 -o /dev/null -H 'Host: logflood.localhost' 'http://127.0.0.1/flood/$lines?size=$size' & done; wait; echo flood-done" > "$out/flood.done" 2>&1 &
fp=$!
while kill -0 $fp 2> /dev/null; do
  a=$(ms); "$R" logs -a logflood -n 100 > "$out/logs.out" 2>&1; rc=$?; b=$(ms)
  c=$(curl -s -m 10 -o /dev/null -w '%{http_code}/%{time_total}' "http://logflood.localhost:$TANDO_TEST_HTTP_PORT/health")
  printf '%s\tlogs_ms=%s rc=%s lines=%s\thealth=%s\tjournal=%s\tload1=%s\n' "$(date +%T)" "$((b - a))" "$rc" "$(wc -l < "$out/logs.out" | tr -d ' ')" "$c" \
    "$(sx "du -sb /var/log/journal/*.tando-logflood | cut -f1")" "$(load1)" | tee -a "$out/during.tsv"
  sleep 3
done
t1=$(ms)
printf 'flood %s x %s lines x %s B = %s MB written in %s ms\n' "$rounds" "$lines" "$size" $((rounds * lines * size / 1048576)) $((t1 - t0)) | tee -a "$out/summary.txt"
sx "du -sb /var/log/journal/*.tando-logflood; cat /etc/systemd/journald@tando-logflood.conf; journalctl -u systemd-journald@tando-logflood --no-pager -o cat | grep -i -E 'suppress|rotat|vacuum' | tail -5;
    systemctl show -p CPUUsageNSec,MemoryPeak systemd-journald@tando-logflood" | tee -a "$out/summary.txt"
a=$(ms); "$R" logs -a logflood -n 1000 > "$out/logs1000.out" 2>&1; b=$(ms)
echo "after: tando logs -n 1000: $((b - a)) ms, $(wc -l < "$out/logs1000.out") lines" | tee -a "$out/summary.txt"
