#!/bin/bash
# repro/domain-lost-update.sh [rounds] [app]: two `domain add` of one app at once (agent verbs,
# no deploy). Each round both report success; then both must be in app.conf. Also deploy-vs-domain:
# RACE_WITH_DEPLOY=1 runs a configure (what every deploy does first) beside one domain add.
set -u
. "$(cd "$(dirname "$0")/.." && pwd -P)/lib.sh"
N=${1:-20} APP=${2:-pr} lost=0
for i in $(seq 1 "$N"); do
  if [ "${RACE_WITH_DEPLOY:-0}" = 1 ]; then
    ( cd "$E/proj/A/$APP" && rA deploy --force --yes > /dev/null 2>&1 ) &
    ( jitter 1200; sroot /opt/tando/bin/tando-agent domain-add "$APP" "p$i.race.test" off > /dev/null 2>&1 ) &
    wait; want="p$i.race.test"
  else
    ( sroot /opt/tando/bin/tando-agent domain-add "$APP" "p$i.race.test" off > /dev/null 2>&1 ) &
    ( jitter 200; sroot /opt/tando/bin/tando-agent domain-add "$APP" "q$i.race.test" off > /dev/null 2>&1 ) &
    wait; want="p$i.race.test q$i.race.test"
  fi
  conf=$(srv "sudo grep ^domains= /opt/tando/apps/$APP/app.conf")
  for d in $want; do case $conf in *"$d|"*) ;; *) lost=$((lost + 1)); echo "round $i: $d lost ($conf)";; esac; done
  for d in $want; do sroot /opt/tando/bin/tando-agent domain-rm "$APP" "$d" > /dev/null 2>&1; done
done
echo "lost $lost of $N rounds"
