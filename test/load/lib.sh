# shellcheck shell=bash
# test/load/lib.sh: helpers for the load tests (test/load/*.sh). Source it. bash 3.2 compatible.
# Server: tando-load (ssh 2441, http 8441), 2 GB / 1 CPU like the owner's VPS, /opt/tando on a
# 3 GB ext4 loop disk (so "disk full" fills the loop file, never the laptop).
# Load generator: container tando-load-gen in the server's network namespace (it reaches the
# server's 127.0.0.1), with its own CPU limit so it does not eat the server's CPU.
LROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
R=$LROOT/bin/tando
export TANDO_TEST_NAME=${TANDO_TEST_NAME:-tando-load} TANDO_TEST_SSH_PORT=${TANDO_TEST_SSH_PORT:-2441}
export TANDO_TEST_HTTP_PORT=${TANDO_TEST_HTTP_PORT:-8441} TANDO_TEST_CADDY=${TANDO_TEST_CADDY:-ubuntu}
L=$TANDO_TEST_NAME GEN=$TANDO_TEST_NAME-gen
LW=$LROOT/test/.load-$L                       # work dir (git-ignored)
export TANDO_CONFIG_DIR=$LW/cfg TANDO_COLOR=never TANDO_WAIT=1
RAWL=$LROOT/bench/raw/load
SRV_CPUSET=${SRV_CPUSET:-9} GEN_CPUSET=${GEN_CPUSET:-8} GEN_CPUS=${GEN_CPUS:-1}
mkdir -p "$LW/cfg" "$RAWL"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time*1000'; }
load1() { uptime | sed 's/.*load averages*: *//; s/,//g' | awk '{print $1}'; }   # laptop 1-min load
lssh() { "$LROOT/test/server/ssh.sh" "$@"; }
sx() { docker exec "$L" bash -c "$*"; }          # root shell on the server
gx() { docker exec "$GEN" bash -c "$*"; }        # shell in the load generator

server_up() {
  TANDO_TEST_DOCKER_ARGS="--memory 2g --memory-swap 2g --cpus 1 --cpuset-cpus $SRV_CPUSET --label tando.load=1" \
    "$LROOT/test/server/up.sh" --reset >&2
  docker exec "$L" rm -f /usr/sbin/policy-rc.d
  # /opt/tando on a 3 GB sparse ext4 loop file
  docker exec "$L" bash -c 'set -e; truncate -s 3G /var/load-disk.img
    dev=$(losetup -f --show /var/load-disk.img); mkfs.ext4 -q -F "$dev"; echo "$dev" > /run/load-loop
    mkdir -p /opt/tando; mount "$dev" /opt/tando'
  "$R" host add load vmadmin@127.0.0.1 --port "$TANDO_TEST_SSH_PORT" --key "$LROOT/test/server/id_test" --yes >&2
  "$R" host setup load public_port="$TANDO_TEST_HTTP_PORT" "$@" >&2
}
gen_up() {
  docker rm -f "$GEN" > /dev/null 2>&1
  docker run -d --name "$GEN" --label tando.load=1 --network "container:$L" --cpus "$GEN_CPUS" \
    --cpuset-cpus "$GEN_CPUSET" --memory 1g --entrypoint sleep tando-testvm:caddy-ubuntu infinity > /dev/null
  gx 'apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wrk apache2-utils hey >/dev/null 2>&1;
      command -v wrk ab hey'
}
server_down() {
  docker rm -f "$GEN" > /dev/null 2>&1
  docker exec "$L" bash -c 'umount -l /opt/tando 2>/dev/null; [ -f /run/load-loop ] && losetup -d "$(cat /run/load-loop)"; true' 2> /dev/null
  docker rm -f "$L" > /dev/null 2>&1
}

# cgroup readings inside the server (paths relative to the container's cgroup root)
cg_cpu() { sx "sed -n 's/^usage_usec //p' /sys/fs/cgroup/$1/cpu.stat 2>/dev/null || echo 0"; }
cg_anon() { sx "awk '\$1==\"anon\"||\$1==\"shmem\"{s+=\$2} END{print s+0}' /sys/fs/cgroup/$1/memory.stat 2>/dev/null"; }
# snapshot of cpu usec and anon bytes of the given units (system.slice/<unit>) and the whole box
snap() { # units...
  local u; for u in "" "$@"; do
    local p=${u:+system.slice/$u}
    printf '%s\t%s\t%s\n' "${u:-TOTAL}" "$(cg_cpu "$p")" "$(cg_anon "$p")"
  done; }
