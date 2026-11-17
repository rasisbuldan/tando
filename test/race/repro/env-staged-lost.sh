#!/bin/bash
# repro/env-staged-lost.sh [rounds]: two `env set` of an app that does not exist yet (staged in
# /opt/tando/staged/<app>/env) at once, each a different key. env_staged takes no lock: both load
# the file, add their key and save, so one key is lost although both report changed=1 staged=1.
set -u
. "$(cd "$(dirname "$0")/.." && pwd -P)/lib.sh"
lost=0 N=${1:-20}
for i in $(seq 1 "$N"); do
  ( rA env set -a ghost$i "KA=a" > /dev/null 2>&1 ) & ( rB env set -a ghost$i "KB=b" > /dev/null 2>&1 ) & wait
  e=$(srv "sudo cat /opt/tando/staged/ghost$i/env" 2> /dev/null)
  case $e in *KA=*) ;; *) lost=$((lost + 1)); echo "round $i: KA lost: $(echo $e)";; esac
  case $e in *KB=*) ;; *) lost=$((lost + 1)); echo "round $i: KB lost: $(echo $e)";; esac
  srv "sudo rm -rf /opt/tando/staged/ghost$i"
done
echo "lost $lost keys in $N rounds"
