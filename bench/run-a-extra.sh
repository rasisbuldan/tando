#!/bin/bash
# tando newcomer checks (bench/raw/a-extra/): what `tando init` + `tando up` do with a plain
# Next.js app, unit exit status on restart, memory once the ssh ControlPersist session is gone,
# and the app's memory with MALLOC_ARENA_MAX=2 (glibc arenas vs the Alpine image in B/D).
set -u
cd "$(dirname "$0")" && . ./lib.sh
C=tando-bench-a O=$RAW/a-extra
export TANDO_CONFIG_DIR=$BENCH/.rc PATH=$BENCH/snapshot/bin:$PATH NO_COLOR=1 COLUMNS=100
rm -rf "$O" "$TANDO_CONFIG_DIR"; mkdir -p "$O"
CPUSET=2 start_server $C tando-bench-base:latest 2311 8311
disk_setup $C /opt/tando
tando host add bencha vmadmin@127.0.0.1 --port 2311 --key "$KEY" --insecure-test >/dev/null
tando host setup bencha apps_domain=localhost tls=off public_port=8311 >/dev/null 2>&1
# 1. newcomer: copy of the app without tando.conf, init, up
N=$BENCH/.cache/newcomer; rm -rf "$N"; mkdir -p "$N"
rsync -a --exclude=/tando.conf --exclude=/.tando --exclude=/dist --exclude=/.next --exclude=/.kamal --exclude=/config app/ "$N/nextapp/"
(cd "$N/nextapp" && { echo '$ tando init'; tando init; echo "rc=$?"; echo '$ cat tando.conf'; cat tando.conf; echo '$ tando up'; tando up; echo "rc=$?"; }) > "$O/newcomer.log" 2>&1
du -sh "$N/nextapp/node_modules" >> "$O/newcomer.log"
rm -rf "$N"
# 2. normal deploy, two warm deploys, unit journal around a restart
cd app; set_version . e1; tando up > "$O/up.log" 2>&1; set_version . e2; tando deploy > "$O/deploy.log" 2>&1
docker exec $C journalctl -u tando-bench -n 12 --no-pager -o cat > "$O/unit-journal.log"
tando status > "$O/status.log" 2>&1
# 3. memory after the ControlPersist master (60 s) has exited
ssh -O exit -o ControlPath="$TANDO_CONFIG_DIR/cm/%C" -p 2311 vmadmin@127.0.0.1 2>/dev/null
SETTLE=75 idle_snapshot $C "$O/mem-one-app-no-ssh.tsv"
# 4. MALLOC_ARENA_MAX=2
tando env set MALLOC_ARENA_MAX=2 > "$O/env.log" 2>&1
SETTLE=40 idle_snapshot $C "$O/mem-one-app-arena2.tsv"
cd ..
