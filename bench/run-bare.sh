#!/bin/bash
# Empty VM -> first live app, for the rivals. The server starts from the bare image (Ubuntu 26.04
# with systemd, sshd and a sudo user only: no curl, wget, rsync, Caddy or Node), like tando's own
# test/e2e-bootstrap.sh. Every command a user types is a timed "step"; files written by hand
# before the run (Dockerfile, deploy.yml, unit, quadlet, Caddy site) are listed in steps.tsv as
# "file" lines (no time). Harness work (ext4 disk, ssh key install) is not counted.
# Usage: OUT=raw/v2/bare/b-1 bench/run-bare.sh b|c|d
#   b  Kamal 2 (curl needed for its Docker install, then kamal init + kamal setup)
#   c  build on the server (Caddy + Node + a build script, then push source and build)
#   d  Podman quadlet (podman + Caddy, quadlet + site, image built and pushed on the laptop)
# Dokku's empty-VM path is part of run-e-dokku.sh.
set -u
cd "$(dirname "$0")" && . ./lib.sh
X=$1 O=${OUT:-$RAW/bare/$1}
rm -rf "$O"; mkdir -p "$O"; STEPS=$O/steps.tsv; : > "$STEPS"
step() { local l=$1 t0 t1 rc; shift; t0=$(ms); "$@" >> "$O/steps.log" 2>&1; rc=$?; t1=$(ms)
  printf 'step\t%s\t%s\t%s\n' "$l" $((t1 - t0)) "$rc" | tee -a "$STEPS" >&2; [ $rc = 0 ] || log "step $l failed"; return $rc; }
file() { printf 'file\t%s\t0\t0\n' "$1" >> "$STEPS"; }
live() { local i; for i in $(seq 1 60); do [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' ${2:+-H "Host: $2"} "$1")" = 200 ] && return 0; sleep 1; done; return 1; }
finish() { awk -F'\t' '$1=="step"{s+=$3; n++} $1=="file"{f++} END{printf "empty_vm_to_live_ms\t%d\tcommands\t%d\tfiles\t%d\n", s, n, f}' "$STEPS" | tee -a "$O/notes.txt"; }
cd app; set_version . v1

case $X in
b) C=tando-bench-b
   docker rm -f -v kamal-docker-registry buildx_buildkit_kamal-local-registry-docker-container0 >/dev/null 2>&1
   docker volume rm buildx_buildkit_kamal-local-registry-docker-container0_state >/dev/null 2>&1
   CPUSET=3 start_server $C tando-bench-bare:26.04 2412 8412; disk_setup $C /var/lib/docker /var/lib/containerd
   echo "load $(uptime | sed 's/.*averages*: //')" >> "$O/notes.txt"
   file Dockerfile; file config/deploy.yml
   K=$BENCH/.cache/kamal-init; rm -rf "$K"; mkdir -p "$K"
   step 1-kamal-init docker run --rm -v "$K:/workdir" ghcr.io/basecamp/kamal@sha256:7b5be276aa17bbe122887f6a1ff12865f4848111989699b9786083be95d98415 init
   rm -rf "$K"   # bench/app/config/deploy.yml is the edited result of this template
   step 2-apt-curl bssh 2412 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl'
   step 3-kamal-setup env VERSION=v1 "$BENCH/kamal.sh" setup
   live http://127.0.0.1:8412/api/version && echo "live: $(curl -s http://127.0.0.1:8412/api/version)" >> "$O/notes.txt"
   bssh 2412 'docker version --format "docker {{.Server.Version}}"; id' >> "$O/notes.txt" 2>&1;;
c) C=tando-bench-c
   CPUSET=4 start_server $C tando-bench-bare:26.04 2413 8413; disk_setup $C /srv
   echo "load $(uptime | sed 's/.*averages*: //')" >> "$O/notes.txt"
   file c/server-setup.sh; file c/build-deploy.sh
   step 1-apt bssh 2413 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync curl ca-certificates xz-utils caddy'
   step 2-node bssh 2413 'f=$(curl -fsSL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt | awk "\$2 ~ /linux-arm64.tar.xz\$/ {print \$2}"); curl -fsSL "https://nodejs.org/dist/latest-v24.x/$f" | sudo tar -xJ -C /usr/local --strip-components=1'
   step 3-caddy-import bssh 2413 'sudo mkdir -p /etc/caddy/tando && echo "import /etc/caddy/tando/*.caddy" | sudo tee -a /etc/caddy/Caddyfile'
   step 4-setup-script bssh 2413 'cat > /tmp/s.sh && sudo bash /tmp/s.sh' < "$BENCH/c/server-setup.sh"
   step 5-build-script bssh 2413 'sudo tee /usr/local/bin/bench-build-deploy >/dev/null && sudo chmod 755 /usr/local/bin/bench-build-deploy' < "$BENCH/c/build-deploy.sh"
   RSH="ssh -F /dev/null -i $KEY -p 2413 -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
   step 6-push-source rsync -rlptz --delete -e "$RSH" --exclude=/node_modules --exclude=/.next --exclude=/dist --exclude=/.tando \
     --exclude=/.kamal --exclude=/config --exclude=/Dockerfile --exclude=/.dockerignore --exclude=/tando.conf ./ vmadmin@127.0.0.1:/srv/app/src/
   step 7-build-deploy bssh 2413 /usr/local/bin/bench-build-deploy
   live http://127.0.0.1:8413/api/version bench.localhost && echo "live: $(curl -s -H 'Host: bench.localhost' http://127.0.0.1:8413/api/version)" >> "$O/notes.txt";;
d) C=tando-bench-d REG=tando-bench-registry
   docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
   docker rm -f -v $REG >/dev/null 2>&1; docker run -d --name $REG --label tando.bench=1 --network "$NET" -p 127.0.0.1:5414:5000 registry:3 >/dev/null
   docker buildx rm tando-bench-builder >/dev/null 2>&1; docker buildx create --name tando-bench-builder --driver docker-container >/dev/null
   CPUSET=5 start_server $C tando-bench-bare:26.04 2414 8414; disk_setup $C /var/lib/containers
   echo "load $(uptime | sed 's/.*averages*: //')" >> "$O/notes.txt"
   file Dockerfile; file bench.container; file bench.caddy
   step 1-apt bssh 2414 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq podman nftables caddy curl'
   step 2-registry-conf bssh 2414 "printf '[[registry]]\nlocation = \"$REG:5000\"\ninsecure = true\n' | sudo tee /etc/containers/registries.conf.d/50-bench.conf"
   step 3-build docker buildx build -q --builder tando-bench-builder --platform linux/arm64 --load -t 127.0.0.1:5414/bench:v1 .
   step 4-push docker push -q 127.0.0.1:5414/bench:v1
   step 5-quadlet bssh 2414 "sudo mkdir -p /etc/containers/systemd && printf '[Unit]\nDescription=bench\n\n[Container]\nImage=$REG:5000/bench:v1\nPublishPort=127.0.0.1:3000:3000\n\n[Service]\nRestart=on-failure\n\n[Install]\nWantedBy=multi-user.target\n' | sudo tee /etc/containers/systemd/bench.container"
   step 6-caddy-site bssh 2414 "printf 'http://bench.localhost {\n\treverse_proxy 127.0.0.1:3000\n}\n' | sudo tee -a /etc/caddy/Caddyfile && sudo systemctl reload caddy"
   step 7-start bssh 2414 'sudo systemctl daemon-reload && sudo systemctl start bench.service'
   live http://127.0.0.1:8414/api/version bench.localhost && echo "live: $(curl -s -H 'Host: bench.localhost' http://127.0.0.1:8414/api/version)" >> "$O/notes.txt";;
*) echo "usage: $0 b|c|d" >&2; exit 2;;
esac
finish
docker exec $C bash -c 'cat /sys/fs/cgroup/memory.current; awk "\$1==\"anon\"||\$1==\"shmem\"{s+=\$2} END{print s}" /sys/fs/cgroup/memory.stat' > "$O/mem-after.txt"
cd ..; stop_server $C
[ "$X" = d ] && { docker rm -f -v tando-bench-registry >/dev/null 2>&1; docker buildx rm tando-bench-builder >/dev/null 2>&1; docker image rm 127.0.0.1:5414/bench:v1 >/dev/null 2>&1; }
log "done: $O"
