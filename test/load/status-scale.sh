#!/bin/bash
# status at 3, 20, 100 apps: grow the server's apps to each count (hello copies a001..; from
# NODE_MAX on, static sites, to stay inside 2 GB), then time the read-only verbs on the server
# (test/load/status-bench.sh) and `tando ls` / `tando status` from this laptop end to end, with
# tando-status (Go) and without it (the agent's shell fallback).
#
#   test/load/status-scale.sh <outdir> [counts...]     (default 3 20 100; NODE_MAX=50, RUNS=11)
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT, a test server set up for
# tando (host setup) and registered as host "scale" in TANDO_CONFIG_DIR.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
R=$ROOT/bin/tando SSH=$ROOT/test/server/ssh.sh
out=${1:?usage: status-scale.sh <outdir> [counts...]}; shift
[ $# -gt 0 ] || set -- 3 20 100
NODE_MAX=${NODE_MAX:-50} RUNS=${RUNS:-11}
export TANDO_SOAK=${TANDO_SOAK:-2} TANDO_WAIT=1 TANDO_COLOR=never
mkdir -p "$out/apps"
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
med() { sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'; }
e2e() { # cmd...: median wall (ms) of RUNS runs from the laptop
  local i t0 t1
  for ((i = 0; i < RUNS; i++)); do t0=$(ms); "$@" > /dev/null 2>&1; t1=$(ms); echo $((t1 - t0)); done | med
}
have=0
for n in "$@"; do
  while [ $have -lt "$n" ]; do
    have=$((have + 1)); a=$(printf 'a%03d' $have); d=$out/apps/$a
    if [ ! -d "$d" ]; then
      mkdir -p "$d"
      if [ $have -gt "$NODE_MAX" ]; then
        mkdir -p "$d/public"; echo "<h1>$a</h1>" > "$d/public/index.html"
        printf 'app = %s\nrecipe = static\nout = public\nhost = scale\n' "$a" > "$d/tando.conf"
      else
        cp "$ROOT/examples/hello/server.js" "$ROOT/examples/hello/VERSION" "$d/"
        printf 'app = %s\nrecipe = node\nstart = node server.js\nhealth = /health\nmemory = 64M\nhost = scale\n' "$a" > "$d/tando.conf"
      fi
    fi
    (cd "$d" && "$R" up > "$out/up-$a.out" 2>&1) || echo "up $a failed" >&2
  done
  {
    echo "== $n apps ($(( n < NODE_MAX ? n : NODE_MAX )) node, the rest static)"
    "$ROOT/test/load/status-bench.sh" a001
    st_go=$(e2e "$R" status -a a001 -H scale); ls_go=$(e2e "$R" ls -H scale)
    "$SSH" 'sudo mv /opt/tando/bin/tando-status /opt/tando/bin/tando-status.off'
    st_sh=$(e2e "$R" status -a a001 -H scale); ls_sh=$(e2e "$R" ls -H scale)
    "$SSH" 'sudo mv /opt/tando/bin/tando-status.off /opt/tando/bin/tando-status'
    echo "laptop end to end (ms, median of $RUNS): tando ls  sh $ls_sh  go $ls_go;  tando status -a a001  sh $st_sh  go $st_go"
  } 2>&1 | tee -a "$out/scale.txt"
done
