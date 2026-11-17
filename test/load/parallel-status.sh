#!/bin/bash
# N parallel `tando status <app>` (and `tando ls`) through one ControlMaster; counts failures and
# collects the distinct error lines. usage: test/load/parallel-status.sh <n> <app> <outdir> [cmd]
set -u
. "$(dirname "$0")/lib.sh"
n=$1 app=$2 out=$3 cmd=${4:-status}
mkdir -p "$out/p$n-$cmd"
"$R" ls > /dev/null 2>&1        # open the master first
t0=$(ms)
for i in $(seq 1 "$n"); do
  ( if [ "$cmd" = status ]; then "$R" status -a "$app"; else "$R" "$cmd"; fi > "$out/p$n-$cmd/$i.out" 2>&1; echo $? > "$out/p$n-$cmd/$i.rc" ) &
done
wait
t1=$(ms)
bad=$(cat "$out/p$n-$cmd"/*.rc | grep -vc '^0$')
printf '%s\tparallel=%s\tcmd=%s\twall_ms=%s\tfailed=%s\tload1=%s\terrors=%s\n' "$(date +%H:%M:%S)" "$n" "$cmd" "$((t1 - t0))" "$bad" "$(load1)" \
  "$(for i in $(seq 1 "$n"); do [ "$(cat "$out/p$n-$cmd/$i.rc")" = 0 ] || grep -v '^\s*$' "$out/p$n-$cmd/$i.out" | head -2; done | sort | uniq -c | sort -rn | head -4 | tr -s ' ' | tr '\n' '|')" | tee -a "$out/parallel.tsv"
