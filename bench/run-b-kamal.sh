#!/bin/bash
# Approach B: real Kamal 2.12 (from its Docker image, bench/kamal.sh): image built on the laptop
# with Kamal's own buildx builder, pushed to Kamal's local registry (127.0.0.1:5412 on the laptop),
# pulled by the server through Kamal's ssh reverse tunnel, container started, health-checked by
# kamal-proxy, traffic switched. Server: Docker Engine 29 in container tando-bench-b (2 GB, 1 CPU),
# ssh 127.0.0.1:2412, http 127.0.0.1:8412 (kamal-proxy :80). Output: bench/raw/b/.
# Usage: bench/run-b-kamal.sh [warm_runs]   (default 5)
set -u
cd "$(dirname "$0")" && . ./lib.sh
N=${1:-5} C=tando-bench-b O=${OUT:-$RAW/b} URL=http://127.0.0.1:8412/api/version
rm -rf "$O"; mkdir -p "$O"
K() { VERSION=$1 "$BENCH/kamal.sh" "${@:2}"; }
served() { curl -s -m 5 "$URL"; }
rs() { bssh 2412 "$@"; }

log "cold laptop side: remove Kamal's builder (its build cache) and local registry container"
docker rm -f buildx_buildkit_kamal-local-registry-docker-container0 >/dev/null 2>&1 || true
docker volume rm buildx_buildkit_kamal-local-registry-docker-container0_state >/dev/null 2>&1 || true
docker rm -f -v kamal-docker-registry >/dev/null 2>&1 || true
rm -rf app/.kamal/apps

log "start server"
CPUSET=3 start_server $C tando-bench-docker:latest 2412 8412
docker exec $C systemctl stop docker.socket docker containerd
disk_setup $C /var/lib/docker /var/lib/containerd
docker exec $C systemctl start containerd docker
idle_snapshot $C "$O/mem-1-docker-zero-apps.tsv"       # dockerd + containerd, no proxy, no app

cd app
set_version . v1; rm -rf .next dist
log "cold deploy (kamal setup)"
measured $C "$O" cold K v1 setup
echo "served after cold: $(served)" | tee -a "$O/notes.txt"
idle_snapshot $C "$O/mem-2-one-app.tsv"

log "warm deploys, quiet"
for i in $(seq 1 "$N"); do set_version . "q$i"; measured $C "$O" "warm-quiet-$i" K "q$i" deploy
  echo "served after warm-quiet-$i: $(served)" >> "$O/notes.txt"; done
set_version . ap1; anon_peak $C "$O" anonpeak-1 K ap1 deploy
log "warm deploys under the request loop"
for i in $(seq 1 "$N"); do set_version . "l$i"; with_loop "$O" "warm-loop-$i" "$URL" - K "l$i" deploy
  echo "served after warm-loop-$i: $(served)" >> "$O/notes.txt"; done

log "rollback"

for i in 1 2 3; do v=l$((N - i)); measured $C "$O" "rollback-quiet-$i" K "" rollback "$v"; echo "after rollback-quiet-$i (to $v): $(served)" >> "$O/notes.txt"; done
for v in l1 l$N; do with_loop "$O" "rollback-loop-$v" "$URL" - K "" rollback "$v"; echo "after rollback-loop to $v: $(served)" >> "$O/notes.txt"; done
set_version . back; measured $C "$O" redeploy K back deploy

log "broken release"
set_version . broken1
with_loop "$O" broken "$URL" - K broken1 deploy
echo "served after broken: $(served)" >> "$O/notes.txt"
set_version . fixed; measured $C "$O" fixed K fixed deploy

log "status query cost"
for i in 1 2 3; do measured $C "$O" "details-$i" K "" details; done
for i in $(seq 1 5); do measured $C "$O" "dockerps-$i" rs docker ps; done
for i in $(seq 1 5); do measured $C "$O" "dockerstats-$i" rs docker stats --no-stream; done

log "disk and per-app memory"
docker exec $C bash -c '
  for p in docker.io containerd runc; do printf "pkg_%s_kb\t%s\n" $p "$(dpkg-query -W -f="\${Installed-Size}" $p 2>/dev/null)"; done
  printf "var_lib_docker\t%s\n" "$(du -sb /var/lib/docker | cut -f1)"
  printf "var_lib_containerd\t%s\n" "$(du -sb /var/lib/containerd | cut -f1)"
  printf "ext4_used_total\t%s\n" "$(df -B1 --output=used /srv/disk | tail -1)"
  docker image ls --format "image\t{{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}"
  docker ps -a --format "container\t{{.Names}}\t{{.Status}}\t{{.Size}}"
  docker system df -v' > "$O/disk.txt" 2>&1
docker exec $C bash -c '
  for cg in /sys/fs/cgroup/system.slice/docker-*.scope; do id=${cg##*/docker-}; id=${id%.scope}
    name=$(docker inspect -f "{{.Name}}" $id 2>/dev/null)
    printf "scope %s current %s anon+shmem %s\n" "$name" "$(cat $cg/memory.current)" "$(awk "\$1==\"anon\"||\$1==\"shmem\"{s+=\$2} END{print s}" $cg/memory.stat)"; done
  for p in $(pgrep -f "containerd-shim|docker-proxy|dockerd|^containerd"); do
    echo "proc $p $(cat /proc/$p/comm) rss_kb $(awk "/^VmRSS/{print \$2}" /proc/$p/status) pss_kb $(awk "/^Pss:/{print \$2}" /proc/$p/smaps_rollup) cgroup $(cut -d: -f3 /proc/$p/cgroup)"; done' > "$O/app-mem.txt"

log "3 copies (three Kamal services, one image each)"
cd ..; ./run-b-copies.sh; cd app
idle_snapshot $C "$O/mem-4-proxy-zero-apps.tsv"        # dockerd + containerd + kamal-proxy, no app
docker exec $C bash -c 'printf "after_app_remove_ext4_used\t%s\n" "$(df -B1 --output=used /srv/disk | tail -1)"; docker image ls' >> "$O/disk.txt"
cd ..
log "done: $O"
