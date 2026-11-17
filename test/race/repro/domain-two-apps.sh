#!/bin/bash
# repro/domain-two-apps.sh [rounds] [appA] [appB]: two apps add the SAME domain at once.
# domain_owner is checked before the per-app lock, and the two apps hold different locks, so both
# may pass the check. Caddy validation of the whole Caddyfile may catch the duplicate site (then one
# fails cleanly) - or both app.conf files claim the domain. Counts rounds where both own it or the
# Caddyfile defines it twice.
set -u
. "$(cd "$(dirname "$0")/.." && pwd -P)/lib.sh"
N=${1:-20} A1=${2:-pr} A2=${3:-dd} bad=0
for i in $(seq 1 "$N"); do
  d=same$i.race.test
  ( sroot /opt/tando/bin/tando-agent domain-add "$A1" "$d" off > "$E/da.1" 2>&1; echo $? > "$E/da.1.rc" ) &
  ( jitter 150; sroot /opt/tando/bin/tando-agent domain-add "$A2" "$d" off > "$E/da.2" 2>&1; echo $? > "$E/da.2.rc" ) &
  wait
  n=$(srv "sudo grep -l '$d|' /opt/tando/apps/$A1/app.conf /opt/tando/apps/$A2/app.conf" | wc -l | tr -d ' ')
  c=$(srv "sudo grep -l '$d' /etc/caddy/tando/$A1.caddy /etc/caddy/tando/$A2.caddy" | wc -l | tr -d ' ')
  if [ "$n" != 1 ] || [ "$c" != 1 ]; then bad=$((bad + 1)); echo "round $i: $d in $n app.conf, $c caddy files (rc $(cat "$E/da.1.rc") $(cat "$E/da.2.rc")): $(cat "$E/da.1" "$E/da.2" | tr '\n' ' ' | cut -c1-200)"; fi
  sroot /opt/tando/bin/tando-agent domain-rm "$A1" "$d" > /dev/null 2>&1; sroot /opt/tando/bin/tando-agent domain-rm "$A2" "$d" > /dev/null 2>&1
done
echo "bad rounds: $bad of $N"
