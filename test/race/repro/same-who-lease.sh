#!/bin/bash
# repro/same-who-lease.sh [rounds] [app]: two deploys of one app at once by the same user on the
# same laptop (two project dirs, two terminals). cmd_begin drops a live lease when `who` (user@host)
# matches, without checking that an rsync is still writing incoming/, so the second upload writes
# into incoming/ while the first is activated: a release mixing both uploads goes live (VERSION and
# marker differ), or the deploy that reports "live" is not the one served.
set -u
. "$(cd "$(dirname "$0")/.." && pwd -P)/lib.sh"
N=${1:-20} APP=${2:-sw} bad=0
p1=$(mkproj W1 "$APP" 0); p2=$(mkproj W2 "$APP" 0)
(cd "$p1" && rA up --force --yes > /dev/null 2>&1) || { echo "up failed"; exit 1; }
for i in $(seq 1 "$N"); do
  for k in 1 2; do p=$E/proj/W$k/$APP; echo "$i$k" > "$p/VERSION"; echo "$i$k" > "$p/marker"
    head -c $(( k == 1 ? 8000000 : 300000 )) /dev/urandom > "$p/blob.bin"; done
  ( cd "$p1" && rA deploy --force --yes > "$E/sw.1" 2>&1; echo $? > "$E/sw.1.rc" ) &
  ( sleep 0.3; jitter 500; cd "$p2" && rB deploy --force --yes > "$E/sw.2" 2>&1; echo $? > "$E/sw.2.rc" ) &   # rB: other config dir, same user@host
  wait; settle "$APP"
  set -- $(srv "sudo cat /opt/tando/apps/$APP/current/VERSION /opt/tando/apps/$APP/current/marker" | tr '\n' ' ')
  live=""; [ "$(cat "$E/sw.1.rc")" = 0 ] && live="$live ${i}1"; [ "$(cat "$E/sw.2.rc")" = 0 ] && live="$live ${i}2"
  if [ "$1" != "$2" ]; then bad=$((bad + 1)); echo "round $i: MIXED release live: VERSION=$1 marker=$2 (reported live:$live)"
  else case " $live " in *" $1 "*) ;; *) [ -n "$live" ] && { bad=$((bad + 1)); echo "round $i: serves $1, but the deploy that reported live was$live"; };; esac; fi
done
echo "bad rounds: $bad of $N"
