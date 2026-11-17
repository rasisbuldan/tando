#!/bin/bash
# tando go (the one-command path) from the bare image: `tando go user@host --yes` in a fresh app
# copy (no node_modules, .next or tando.conf), timed to the first live link. Same server and
# snapshot rules as run-a-tando.sh. Usage: bench/run-a-go.sh <snapshot-dir> [runs]
set -u
SNAP=$(cd "${1:?usage: run-a-go.sh <snapshot-dir> [runs]}" && pwd -P); RUNS=${2:-1}
[ -d "$SNAP/.git" ] && { echo "refusing a git checkout" >&2; exit 2; }
cd "$(dirname "$0")" && . ./lib.sh
C=tando-bench-a W=$BENCH/.cache/go-work
export PATH=$SNAP/bin:$PATH NO_COLOR=1 COLUMNS=100 TERM=dumb
for r in $(seq 1 "$RUNS"); do
  O=$RAW/v2/a-go/run$r; rm -rf "$O" "$W"; mkdir -p "$O" "$W"
  export TANDO_CONFIG_DIR=$BENCH/.rcgo; rm -rf "$TANDO_CONFIG_DIR"
  CPUSET=2 start_server $C tando-bench-bare:26.04 2411 8411; disk_setup $C /opt/tando
  echo "load $(uptime | sed 's/.*averages*: //')" >> "$O/notes.txt"
  (cd app && tar -cf - --exclude=./node_modules --exclude=./.next --exclude=./dist --exclude=./.tando \
    --exclude=./.kamal --exclude=./config --exclude=./Dockerfile --exclude=./.dockerignore --exclude=./tando.conf .) |
    (mkdir -p "$W/bench" && cd "$W/bench" && tar -xf -)
  cd "$W/bench"; set_version . v1
  t0=$(ms)
  tando go vmadmin@127.0.0.1 --port 2411 --key "$KEY" --insecure-test public_port=8411 domain_tls=internal --yes < /dev/null > "$O/go.log" 2>&1; rc=$?
  t1=$(ms); body=$(curl -s -m 5 -H 'Host: bench.localhost' http://127.0.0.1:8411/api/version)
  printf 'go\trc=%s\twall_ms=%s\tcommands=1\tserved=%s\n' "$rc" $((t1 - t0)) "$body" | tee -a "$O/notes.txt"
  cd "$BENCH"; stop_server $C
done
rm -rf "$W" "$BENCH/.rcgo"
