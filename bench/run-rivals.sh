#!/bin/bash
# All rival measurements, 3 rounds, strictly one server at a time: per round the empty-VM runs
# (run-bare.sh b, c, d), then the full runs B (Kamal), C (build on server), D (Podman quadlet),
# E (Dokku, which starts from a bare VM itself). Output: raw/v2/<x>/round<r>/, raw/v2/bare/<x>-<r>/.
# Usage: bench/run-rivals.sh [rounds] [warm_runs_per_round]   (default 3 3)
cd "$(dirname "$0")" && . ./lib.sh
R=${1:-3} N=${2:-3} V=$RAW/v2
mkdir -p "$V"
for r in $(seq 1 "$R"); do
  for x in b c d; do log "round $r: empty VM $x"; OUT=$V/bare/$x-$r ./run-bare.sh $x > "$V/bare-$x-$r.out" 2>&1; done
  log "round $r: B";  OUT=$V/b/round$r ./run-b-kamal.sh "$N"      > "$V/b-$r.out" 2>&1; stop_server tando-bench-b
  log "round $r: C";  OUT=$V/c/round$r ./run-c-server-build.sh "$N" > "$V/c-$r.out" 2>&1; stop_server tando-bench-c
  log "round $r: D";  OUT=$V/d/round$r ./run-d-podman.sh "$N"     > "$V/d-$r.out" 2>&1; stop_server tando-bench-d
  docker rm -f -v tando-bench-registry >/dev/null 2>&1
  log "round $r: E";  OUT=$V/e/round$r ./run-e-dokku.sh "$N"      > "$V/e-$r.out" 2>&1; stop_server tando-bench-e
done
log "rivals done"
