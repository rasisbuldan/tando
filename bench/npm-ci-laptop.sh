#!/bin/bash
# Laptop `npm ci` time for the app (warm npm cache), N runs, in a scratch copy (not app/).
# This is the part of a truly cold tando deploy that tando does not run itself.
cd "$(dirname "$0")" && . ./lib.sh
N=${1:-3} D=$BENCH/.cache/npmci; rm -rf "$D"; mkdir -p "$D"; cp app/package.json app/package-lock.json "$D/"
for i in $(seq 1 "$N"); do rm -rf "$D/node_modules"; t0=$(ms); (cd "$D" && npm ci --no-audit --no-fund >/dev/null 2>&1); t1=$(ms)
  printf 'npm-ci-%s\twall_ms=%s\n' "$i" $((t1 - t0)); done | tee "$RAW/npm-ci-laptop.tsv"
rm -rf "$D"
# Laptop build + stage for one-line changes, ms resolution (tando prints whole seconds).
cd app; for i in $(seq 1 "$N"); do set_version . "lb$i"; t0=$(ms); npm run build >/dev/null 2>&1 && ../tando-next-stage.sh >/dev/null 2>&1; t1=$(ms)
  printf 'laptop-build-stage-%s\twall_ms=%s\n' "$i" $((t1 - t0)); done | tee -a "$RAW/npm-ci-laptop.tsv"
