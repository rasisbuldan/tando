#!/bin/bash
# Approach C: build on the server (piku / Dokku / Coolify default style): ship the source with
# rsync, run npm ci + next build inside the 2 GB / 1 CPU server, then switch and restart.
# Server: container tando-bench-c, ssh 127.0.0.1:2413, http 127.0.0.1:8413. Output: bench/raw/c/.
# Usage: bench/run-c-server-build.sh [warm_runs]   (default 3)
set -u
cd "$(dirname "$0")" && . ./lib.sh
N=${1:-3} C=tando-bench-c O=${OUT:-$RAW/c} URL=http://127.0.0.1:8413/api/version H=bench.localhost
rm -rf "$O"; mkdir -p "$O"
served() { curl -s -m 5 -H "Host: $H" "$URL"; }
RSH="ssh -F /dev/null -i $KEY -p 2413 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
deploy() { # push source, build + activate on the server
  local t0 t1 t2; t0=$(ms)
  rsync -rlptz -c --delete --stats -e "$RSH" --exclude=node_modules --exclude=.next --exclude=dist \
    --exclude=.tando --exclude=.kamal --exclude=config --exclude=Dockerfile --exclude=.dockerignore \
    --exclude=tando.conf ./ vmadmin@127.0.0.1:/srv/app/src/ > /tmp/tando-bench-c-rsync.$$ 2>&1 || return 1
  t1=$(ms); grep -E '^Total (sent|bytes sent)' /tmp/tando-bench-c-rsync.$$ | sed 's/^/rsync: /'; rm -f /tmp/tando-bench-c-rsync.$$
  echo "transfer=$(awk -v a=$t0 -v b=$t1 'BEGIN{printf "%.2f",(b-a)/1000}')"
  bssh 2413 /usr/local/bin/bench-build-deploy; local rc=$?
  t2=$(ms); echo "total_wall=$(awk -v a=$t0 -v b=$t2 'BEGIN{printf "%.2f",(b-a)/1000}')"; return $rc; }

log "start server"
CPUSET=4 start_server $C tando-bench-base:latest 2413 8413
disk_setup $C /srv
docker cp c/server-setup.sh $C:/usr/local/sbin/bench-server-setup && docker exec $C bash /usr/local/sbin/bench-server-setup
docker cp c/build-deploy.sh $C:/usr/local/bin/bench-build-deploy
idle_snapshot $C "$O/mem-1-zero-apps.tsv"

cd app
set_version . v1
log "cold deploy (npm ci + next build on the server)"
measured $C "$O" cold deploy
echo "served after cold: $(served)" | tee -a "$O/notes.txt"
idle_snapshot $C "$O/mem-2-one-app.tsv"

log "baseline latency of the running app, no deploy (30 s)"
with_loop "$O" baseline-idle "$URL" "$H" sleep 30
log "warm deploys, quiet"
for i in $(seq 1 "$N"); do set_version . "q$i"; measured $C "$O" "warm-quiet-$i" deploy
  echo "served after warm-quiet-$i: $(served)" >> "$O/notes.txt"; done
set_version . ap1; anon_peak $C "$O" anonpeak-1 deploy
log "warm deploys under the request loop (latency of the running app during the build)"
for i in $(seq 1 "$N"); do set_version . "l$i"; with_loop "$O" "warm-loop-$i" "$URL" "$H" deploy
  echo "served after warm-loop-$i: $(served)" >> "$O/notes.txt"; done
log "dependency change (forces npm ci on the server), under the request loop"
cp package-lock.json /tmp/tando-bench-lock.bak
bssh 2413 'rm -f /srv/app/src/.lock-installed'
set_version . dep1; with_loop "$O" npmci-loop "$URL" "$H" deploy
bssh 2413 'rm -f /srv/app/src/.lock-installed'; set_version . dep2
measured $C "$O" npmci-quiet deploy

log "disk"
docker exec $C bash -c 'cd /srv/app; for d in src/node_modules src/.next src releases/* .npm; do printf "%s\t%s\n" "$d" "$(du -sb "$d" | cut -f1)"; done
  printf "ext4_used_total\t%s\n" "$(df -B1 --output=used /srv/disk | tail -1)"' > "$O/disk.tsv"
docker exec $C bash -c 'cg=/sys/fs/cgroup/system.slice/bench.service; echo "app_current $(cat $cg/memory.current)";
  awk "\$1==\"anon\"||\$1==\"shmem\"||\$1==\"file\"{print \"app_\"\$1, \$2}" $cg/memory.stat' > "$O/app-mem.txt"
cd ..
log "done: $O"
