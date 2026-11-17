#!/bin/bash
# Re-run of the pieces that failed in the first pass of run-rivals.sh (14 Nov): empty-VM C and D
# (Caddy was not started: policy-rc.d, now removed by start_server) and Dokku (a script bug).
cd "$(dirname "$0")" && . ./lib.sh
V=$RAW/v2
for r in 1 2 3; do
  for x in c d; do log "redo round $r: empty VM $x"; mv "$V/bare/$x-$r" "$V/failed-first-pass/bare-$x-$r" 2>/dev/null
    OUT=$V/bare/$x-$r ./run-bare.sh $x > "$V/bare-$x-$r.out" 2>&1; done
  log "redo round $r: E"; mv "$V/e/round$r" "$V/failed-first-pass/e-round$r" 2>/dev/null
  OUT=$V/e/round$r ./run-e-dokku.sh 3 > "$V/e-$r.out" 2>&1; stop_server tando-bench-e
done
log "redo done"
