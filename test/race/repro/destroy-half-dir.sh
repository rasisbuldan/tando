#!/bin/bash
# repro/destroy-half-dir.sh [tries]: `up` of an existing app and `destroy` of it at once, until the
# app directory is left without app.conf (an activation that waited on the app lock goes on after
# destroy removed the directory; on agent 1fa337be jobs_snap's install -d recreates it).
set -u
. "$(cd "$(dirname "$0")/.." && pwd -P)/lib.sh"
race_init repro-destroy
p=$(mkproj A dh 1); n=${1:-10}
for t in $(seq 1 "$n"); do
  (cd "$p" && rA up --force --yes > /dev/null 2>&1)
  ( jitter 1500; cd "$p" && rA up --force --yes > "$LOG/a.out" 2>&1 ) & ( jitter 1500; rB destroy dh --purge --yes > "$LOG/b.out" 2>&1 ) & wait
  sleep 2
  if srv "sudo test -d /opt/tando/apps/dh -a ! -f /opt/tando/apps/dh/app.conf"; then
    echo "half app directory after try $t:"; srv "sudo ls -la /opt/tando/apps/dh"; rB destroy dh --purge --yes > /dev/null 2>&1; exit 1
  fi
  rB destroy dh --purge --yes > /dev/null 2>&1
done
echo "no half directory in $n tries"
