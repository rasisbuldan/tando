#!/bin/bash
# Approach E: Dokku (official bootstrap, latest release) on a BARE Ubuntu 24.04 server (Dokku's
# documented LTS; systemd + sshd + sudo user only), 2 GB / 1 CPU, ssh 127.0.0.1:2415, http :8415.
# Builds on the server: `git push` -> Dokku's Dockerfile builder (same Dockerfile as Kamal) ->
# app.json health check (/api/version) -> nginx switch; the old container retires after 60 s.
# One run = empty VM to first live app (every user command timed and counted), then the same
# metrics as the other approaches. The app is pushed from a throwaway git repo outside the tando
# repo ($DOKKU_WORK, default $TMPDIR/tando-bench-dokku-app).
# Usage: OUT=raw/v2/e/round1 bench/run-e-dokku.sh [warm_runs]   (default 3)
set -u
cd "$(dirname "$0")" && . ./lib.sh
N=${1:-3} C=tando-bench-e O=${OUT:-$RAW/e} URL=http://127.0.0.1:8415/api/version H=bench.localhost
W=${DOKKU_WORK:-${TMPDIR:-/tmp}/tando-bench-dokku-app}
rm -rf "$O"; mkdir -p "$O"
export GIT_SSH_COMMAND="ssh -F /dev/null -i $KEY -p 2415 -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
served() { curl -s -m 5 -H "Host: ${1:-$H}" "$URL"; }
g() { git -C "$W" -c user.email=bench@localhost -c user.name=bench "$@"; }
commit() { set_version "$W" "$1"; g commit -qam "$1"; }
push() { g push -f "${2:-dokku}" "${1:-HEAD}:refs/heads/main"; }
STEPS=$O/steps.tsv; : > "$STEPS"
step() { # label cmd... : one user command of the empty-VM path, timed
  local l=$1 t0 t1 rc; shift; t0=$(ms); "$@" >> "$O/steps.log" 2>&1; rc=$?; t1=$(ms)
  printf '%s\t%s\t%s\n' "$l" $((t1 - t0)) "$rc" | tee -a "$STEPS" >&2; return $rc; }

log "fresh app repo"
rm -rf "$W"; mkdir -p "$W"
(cd app && tar -cf - --exclude=node_modules --exclude=.next --exclude=dist --exclude=.tando --exclude=.kamal \
  --exclude=config --exclude=tando.conf .) | (cd "$W" && tar -xf -)
printf '{ "healthchecks": { "web": [ { "type": "startup", "name": "web check", "path": "/api/version", "attempts": 30, "wait": 1, "timeout": 5 } ] } }\n' > "$W/app.json"
printf 'node_modules\n.next\n' > "$W/.gitignore"
g init -q -b main && set_version "$W" v1 && g add -A && g commit -qm v1

log "bare server (Ubuntu 24.04)"
CPUSET=6 start_server $C tando-bench-bare:24.04 2415 8415
disk_setup $C /var/lib/docker /var/lib/containerd      # harness: ext4 for Docker, not a user step
echo "load $(uptime | sed 's/.*averages*: //')" >> "$O/notes.txt"

log "empty VM -> Dokku installed"
step 1-apt-wget   bssh 2415 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wget'
step 2-wget-bootstrap bssh 2415 'wget -q -O bootstrap.sh https://dokku.com/bootstrap.sh'
step 3-bootstrap  bssh 2415 'sudo DOKKU_TAG=$(grep -m1 -oE "v0\.[0-9]+\.[0-9]+" bootstrap.sh) bash bootstrap.sh'
step 4-ssh-key    bssh 2415 'sudo dokku ssh-keys:add admin' < "$KEY.pub"
bssh 2415 'dokku version' >> "$O/notes.txt" 2>&1
SETTLE=30 idle_snapshot $C "$O/mem-1-zero-apps.tsv"    # not part of the empty-VM time
step 5-apps-create bssh 2415 'sudo dokku apps:create bench'
step 6-domains-set bssh 2415 'sudo dokku domains:set bench bench.localhost'
step 7-ports-set   bssh 2415 'sudo dokku ports:set bench http:80:3000'
step 8-git-remote  g remote add dokku dokku@127.0.0.1:bench
log "cold deploy (git push, first build on the server)"
measured $C "$O" cold push
printf '9-git-push\t%s\t0\n' "$(awk -F'\t' '$1=="cold"{sub("wall_ms=","",$3); print $3}' "$O/measured.tsv")" >> "$STEPS"
echo "served after cold: $(served)" | tee -a "$O/notes.txt"
awk -F'\t' '{s+=$2} END{printf "empty_vm_to_live_ms\t%d\tcommands\t%d\n", s, NR}' "$STEPS" | tee -a "$O/notes.txt"
SETTLE=75 idle_snapshot $C "$O/mem-2-one-app.tsv"       # old containers retire after 60 s

for i in $(seq 1 "$N"); do commit "q$i"; measured $C "$O" "warm-quiet-$i" push; echo "served after q$i: $(served)" >> "$O/notes.txt"; done
commit ap1; anon_peak $C "$O" anonpeak-1 push
for i in $(seq 1 "$N"); do commit "l$i"; with_loop "$O" "warm-loop-$i" "$URL" "$H" push; echo "served after l$i: $(served)" >> "$O/notes.txt"; done
log "rollback = push the previous commit again (Dokku rebuilds it; layer cache)"
measured $C "$O" rollback-quiet-1 push HEAD~1; echo "after rollback-quiet-1: $(served)" >> "$O/notes.txt"
with_loop "$O" rollback-loop-1 "$URL" "$H" push HEAD; echo "after rollback-loop-1: $(served)" >> "$O/notes.txt"
commit fixed; push > "$O/fixed.log" 2>&1   # (broken-release test dropped: reduced metric set)
log "status query cost"
for i in 1 2 3; do measured $C "$O" "dokkups-$i" bssh 2415 sudo dokku ps:report bench; done
for i in 1 2 3; do measured $C "$O" "dokkulist-$i" bssh 2415 sudo dokku apps:list; done
log "disk, per-app memory"
docker exec $C bash -c 'for p in dokku docker-ce containerd.io docker-ce-cli docker-buildx-plugin nginx herokuish; do printf "pkg_%s_kb\t%s\n" $p "$(dpkg-query -W -f="\${Installed-Size}" $p 2>/dev/null)"; done
  printf "var_lib_docker\t%s\n" "$(du -sb /var/lib/docker | cut -f1)"; printf "var_lib_containerd\t%s\n" "$(du -sb /var/lib/containerd | cut -f1)"
  printf "home_dokku\t%s\n" "$(du -sb /home/dokku | cut -f1)"; printf "ext4_used_total\t%s\n" "$(df -B1 --output=used /srv/disk | tail -1)"
  docker image ls; docker system df' > "$O/disk.txt" 2>&1
docker exec $C bash -c 'for p in $(pgrep -f "containerd-shim|docker-proxy|dockerd|^containerd|nginx"); do
    echo "proc $p $(cat /proc/$p/comm) rss_kb $(awk "/^VmRSS/{print \$2}" /proc/$p/status) pss_kb $(awk "/^Pss:/{print \$2}" /proc/$p/smaps_rollup) cgroup $(cut -d: -f3 /proc/$p/cgroup)"; done' > "$O/app-mem.txt"
log "3 copies"
for a in bench2 bench3; do
  bssh 2415 "sudo dokku apps:create $a && sudo dokku domains:set $a $a.localhost && sudo dokku ports:set $a http:80:3000" >> "$O/copies.log" 2>&1
  g remote add "$a" "dokku@127.0.0.1:$a"; push HEAD "$a" >> "$O/copies.log" 2>&1 || log "push $a failed"
  echo "$a: $(served $a.localhost)" >> "$O/notes.txt"; done
echo "load at end $(uptime | sed "s/.*averages*: //")" >> "$O/notes.txt"
SETTLE=75 idle_snapshot $C "$O/mem-3-three-apps.tsv"
log "done: $O"
