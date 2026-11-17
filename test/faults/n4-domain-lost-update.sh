#!/bin/bash
# n4: two `domain add` of one app at the same moment, and a domain add during a deploy's configure
# (the read-before-lock race of docs/STATUS.md). Expect: every add that reported success is in
# app.conf and in the Caddy site; one domain is never given to two apps.
. "$(dirname "$0")/lib-fault.sh"
f_init n4 "concurrent domain add / configure" "domain add"
A=fn4 B=fn4b; f_fresh $A
AG=/opt/tando/bin/tando-agent
lost=0
for i in 1 2 3 4 5 6; do
  srv "sudo $AG domain-add $A p$i.race.test off" > /dev/null 2>&1 & p1=$!
  srv "sudo $AG domain-add $A q$i.race.test off" > /dev/null 2>&1 & p2=$!
  wait $p1; r1=$?; wait $p2; r2=$?
  conf=$(srv "sudo cat /opt/tando/apps/$A/app.conf /etc/caddy/tando/$A.caddy")
  for d in p q; do
    r=$r1; [ $d = q ] && r=$r2
    [ "$r" = 0 ] || { log "round $i: add $d$i failed (rc=$r)"; continue; }
    [ "$(printf '%s\n' "$conf" | grep -c "$d$i.race.test")" -ge 2 ] || { lost=$((lost + 1)); log "round $i: $d$i.race.test lost"; }
  done
done
ok "no domain add that reported success was lost ($lost lost)" test $lost = 0
# configure (what every deploy does first) beside a domain add
for i in 1 2 3; do
  setv $A $((i + 2)) ok
  (cd "$W/$A" && "$R" deploy > /dev/null 2>&1) & p1=$!
  sleep 0.$((RANDOM % 9)); srv "sudo $AG domain-add $A c$i.race.test off" > /dev/null 2>&1; r=$?
  wait $p1
  [ $r = 0 ] && ! srv "sudo grep -q 'c$i.race.test' /opt/tando/apps/$A/app.conf" && { lost=$((lost + 1)); log "c$i lost beside a deploy"; }
done
ok "no domain added beside a deploy was lost ($lost lost)" test $lost = 0
# two apps claim one domain at once: at most one gets it
f_app $B; deploy $B 1 ok up
srv "sudo $AG domain-add $A both.race.test off" > /dev/null 2>&1 &
srv "sudo $AG domain-add $B both.race.test off" > /dev/null 2>&1
wait
n=$(srv "sudo grep -l 'both.race.test' /opt/tando/apps/$A/app.conf /opt/tando/apps/$B/app.conf" | wc -l | tr -d ' ')
ok "one domain claimed by two apps at once ends with one of them ($n)" test "$n" = 1
truth $A "$(ver $A)"
echo $B | (cd "$W" && "$R" destroy -a $B --purge > /dev/null 2>&1)
f_end
