#!/bin/bash
# Same-conditions comparison: one round each of Kamal (B), Podman quadlet (D) and tando (A),
# back to back, so warm deploy times share the host load. tando runs with health = /api/version
# (as the rivals) and QUICK=1. Output: raw/v2/same/{b,d,a}. Usage: bench/run-same-load.sh <snapshot>
cd "$(dirname "$0")" && . ./lib.sh
S=${1:?snapshot dir}; V=$RAW/v2/same; mkdir -p "$V"
[ -n "$(docker images -q tando-bench-docker:latest)" ] || ./server/build-images.sh > "$V/images.log" 2>&1
log "same-load: B";  OUT=$V/b/round1 ./run-b-kamal.sh 3 > "$V/b.out" 2>&1; stop_server tando-bench-b
log "same-load: D";  OUT=$V/d/round1 ./run-d-podman.sh 3 > "$V/d.out" 2>&1; stop_server tando-bench-d
docker rm -f -v tando-bench-registry >/dev/null 2>&1
log "same-load: A";  OUT_BASE=$V/a HEALTH=/api/version QUICK=1 ./run-a-tando.sh "$S" 1 3 > "$V/a.out" 2>&1
log "same-load done"
