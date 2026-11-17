#!/bin/bash
# Approach D: Podman 5 + systemd quadlet, scripted by hand (no deploy tool exists for this; this is
# the minimal flow a user would script): image built on the laptop (same Dockerfile as B, plain
# `docker build`), pushed to a registry container (tando-bench-registry, 127.0.0.1:5414 on the
# laptop, tando-bench-registry:5000 on the bench network), pulled by the server with podman, the
# quadlet's Image= line changed, systemd daemon-reload + restart. Caddy proxies to 127.0.0.1:3000.
# No pre-switch health gate (quadlet has none): a broken image goes live. Output: bench/raw/d/.
# Server: tando-bench-d (2 GB, 1 CPU), ssh 127.0.0.1:2414, http 127.0.0.1:8414.
set -u
cd "$(dirname "$0")" && . ./lib.sh
N=${1:-3} C=tando-bench-d O=${OUT:-$RAW/d} URL=http://127.0.0.1:8414/api/version H=bench.localhost REG=tando-bench-registry
rm -rf "$O"; mkdir -p "$O"
served() { curl -s -m 5 -H "Host: $H" "$URL"; }
deploy() { # tag [app]: build, push, pull, switch quadlet, restart, wait for health through Caddy
  local tag=$1 app=${2:-bench} t0 t1 t2 t3 t4; t0=$(ms)
  docker buildx build -q --builder tando-bench-builder --platform linux/arm64 --load -t "127.0.0.1:5414/bench:$tag" . >/dev/null || return 1; t1=$(ms)
  docker push -q "127.0.0.1:5414/bench:$tag" >/dev/null || return 1; t2=$(ms)
  bssh 2414 "sudo -n podman pull -q $REG:5000/bench:$tag >/dev/null" || return 1; t3=$(ms)
  bssh 2414 "sudo -n sed -i 's|^Image=.*|Image=$REG:5000/bench:$tag|' /etc/containers/systemd/$app.container &&
    sudo -n systemctl daemon-reload && sudo -n systemctl restart $app.service &&
    for i in \$(seq 1 120); do [ \"\$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: $app.localhost' http://127.0.0.1/api/version)\" = 200 ] && exit 0; sleep 0.25; done; exit 1"
  local rc=$?; t4=$(ms)
  awk -v a=$t0 -v b=$t1 -v c=$t2 -v d=$t3 -v e=$t4 'BEGIN{printf "build=%.2f\npush=%.2f\npull=%.2f\nactivate=%.2f\ntotal=%.2f\n",(b-a)/1000,(c-b)/1000,(d-c)/1000,(e-d)/1000,(e-a)/1000}'
  return $rc; }
quadlet() { # app port tag
  printf '[Unit]\nDescription=bench app %s (podman quadlet)\n\n[Container]\nImage=%s:5000/bench:%s\nPublishPort=127.0.0.1:%s:3000\nEnvironment=NEXT_TELEMETRY_DISABLED=1\n\n[Service]\nRestart=on-failure\n\n[Install]\nWantedBy=multi-user.target\n' "$1" "$REG" "$3" "$2" |
    bssh 2414 "sudo -n tee /etc/containers/systemd/$1.container >/dev/null"
  printf 'http://%s.localhost {\n\treverse_proxy 127.0.0.1:%s\n}\n' "$1" "$2" | bssh 2414 "sudo -n tee /etc/caddy/tando/$1.caddy >/dev/null"
}

log "registry and server"
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
docker rm -f $REG >/dev/null 2>&1; docker run -d --name $REG --label tando.bench=1 --network "$NET" -p 127.0.0.1:5414:5000 registry:3 >/dev/null
docker buildx rm tando-bench-builder >/dev/null 2>&1; docker buildx create --name tando-bench-builder --driver docker-container >/dev/null
CPUSET=5 start_server $C tando-bench-podman:latest 2414 8414
disk_setup $C /var/lib/containers
idle_snapshot $C "$O/mem-1-zero-apps.tsv"           # Caddy, no podman process resident

cd app
set_version . v1
docker image rm -f $(docker image ls -q '127.0.0.1:5414/bench') >/dev/null 2>&1 || true
log "cold deploy"
quadlet bench 3000 v1
bssh 2414 "sudo -n systemctl reload caddy"
measured $C "$O" cold deploy v1
echo "served after cold: $(served)" | tee -a "$O/notes.txt"
idle_snapshot $C "$O/mem-2-one-app.tsv"
for i in $(seq 1 "$N"); do set_version . "q$i"; measured $C "$O" "warm-quiet-$i" deploy "q$i"; echo "served after q$i: $(served)" >> "$O/notes.txt"; done
set_version . ap1; anon_peak $C "$O" anonpeak-1 deploy ap1
for i in $(seq 1 "$N"); do set_version . "l$i"; with_loop "$O" "warm-loop-$i" "$URL" "$H" deploy "l$i"; echo "served after l$i: $(served)" >> "$O/notes.txt"; done
log "rollback = point the quadlet at the previous tag (still in local storage) and restart"
rb() { bssh 2414 "sudo -n sed -i 's|^Image=.*|Image=$REG:5000/bench:$1|' /etc/containers/systemd/bench.container && sudo -n systemctl daemon-reload && sudo -n systemctl restart bench.service &&
  for i in \$(seq 1 120); do [ \"\$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: bench.localhost' http://127.0.0.1/api/version)\" = 200 ] && exit 0; sleep 0.25; done; exit 1"; }
measured $C "$O" rollback-quiet-1 rb "l$((N - 1))"
with_loop "$O" rollback-loop-1 "$URL" "$H" rb "l$N"
log "broken release (no health gate)"
set_version . broken1; with_loop "$O" broken "$URL" "$H" deploy broken1
echo "served after broken: $(served)" >> "$O/notes.txt"
set_version . fixed; measured $C "$O" fixed deploy fixed

log "status query cost"
for i in 1 2 3; do measured $C "$O" "podmanps-$i" bssh 2414 sudo -n podman ps; done
for i in 1 2 3; do measured $C "$O" "podmanstats-$i" bssh 2414 sudo -n podman stats --no-stream; done
log "disk, per-app memory, 3 copies"
docker exec $C bash -c 'printf "pkg_podman_kb\t%s\n" "$(dpkg-query -W -f="\${Installed-Size}" podman)"
  for p in crun conmon netavark aardvark-dns fuse-overlayfs; do printf "pkg_%s_kb\t%s\n" $p "$(dpkg-query -W -f="\${Installed-Size}" $p)"; done
  printf "var_lib_containers\t%s\n" "$(du -sb /var/lib/containers | cut -f1)"
  printf "ext4_used_total\t%s\n" "$(df -B1 --output=used /srv/disk | tail -1)"; podman image ls; podman system df' > "$O/disk.txt" 2>&1
docker exec $C bash -c 'for cg in $(find /sys/fs/cgroup -name "libpod-*.scope" -o -name "bench*.service" | grep -v "/container$"); do
    printf "cgroup %s current %s anon+shmem %s\n" "${cg#/sys/fs/cgroup/}" "$(cat $cg/memory.current)" "$(awk "\$1==\"anon\"||\$1==\"shmem\"{s+=\$2} END{print s}" $cg/memory.stat)"; done
  for p in $(pgrep -f "conmon|node server"); do echo "proc $p $(cat /proc/$p/comm) rss_kb $(awk "/^VmRSS/{print \$2}" /proc/$p/status) pss_kb $(awk "/^Pss:/{print \$2}" /proc/$p/smaps_rollup) cgroup $(cut -d: -f3 /proc/$p/cgroup)"; done' > "$O/app-mem.txt"
for a in bench2:3001 bench3:3002; do quadlet "${a%:*}" "${a#*:}" fixed; done
bssh 2414 'sudo -n systemctl daemon-reload && sudo -n systemctl start bench2.service bench3.service && sudo -n systemctl reload caddy'
idle_snapshot $C "$O/mem-3-three-apps.tsv"
cd ..
log "done: $O"
