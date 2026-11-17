#!/bin/bash
# repro/firewall-torn.sh [rounds] [n]: n `up` of n new apps at once, then n destroys at once.
# Every configure/destroy runs fw_sync, which writes the fixed temp file firewall.nft.tmp with no
# lock: concurrent runs interleave or steal each other's temp file, so nft loads a torn file
# ("syntax error, unexpected end of file") or mv fails; counts those, and checks the loaded table
# afterwards has one accept rule per app.
set -u
. "$(cd "$(dirname "$0")/.." && pwd -P)/lib.sh"
race_init repro-fw
N=${2:-6} torn=0 miss=0
for i in $(seq 1 "${1:-5}"); do
  for k in $(seq 1 "$N"); do mkproj F$k f$k 1 > /dev/null; rm -rf "${E:?}/proj/F$k/f$k/.tando"
    ( cd "$E/proj/F$k/f$k" && rA up --force --yes > "$LOG/$i.$k.out" 2>&1 ) & done; wait
  c=$(cat "$LOG/$i".*.out | grep -cE 'firewall.nft|could not load the loopback')
  torn=$((torn + c))
  have=$(srv "sudo nft list table inet tando" | grep -c 'skuid.*accept')
  apps=$(srv "ls /opt/tando/apps | wc -l")
  [ "$have" = "$apps" ] || { miss=$((miss + 1)); echo "round $i: $have accept rules for $apps apps"; }
  for k in $(seq 1 "$N"); do ( rB destroy f$k --purge --yes > "$LOG/$i.d$k.out" 2>&1 ) & done; wait
  c=$(cat "$LOG/$i".d*.out | grep -cE 'firewall.nft|could not load the loopback'); torn=$((torn + c))
  echo "round $i: fw errors so far $torn"
done
echo "firewall errors: $torn, rounds with missing rules: $miss"
