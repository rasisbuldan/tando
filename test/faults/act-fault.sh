#!/bin/bash
# act-fault.sh <id> <fault> <point>: a fault hits the server while a deploy is activating.
#   fault: kill9 (SIGKILL the activation unit) | restart (docker restart) | powerloss (docker kill+start)
#          | reload (systemctl daemon-reload) | sshdrop (the client's connection dies, nft drop 40 s)
#   point: copy | preflight | switch (symlink swapped, old process still stopping) | verify | rollback
# Promise: afterwards the last good release serves (or the new one, verified), state tells the truth
# without any further command, and the next deploy works untouched.
. "$(dirname "$0")/lib-fault.sh"
ID=$1 FAULT=$2 POINT=$3
f_init "$ID" "$FAULT" "$POINT"
A=f$(echo "$ID" | tr -cd 'a-z0-9' | cut -c1-12)
f_fresh $A
want=2 beh=ok; [ "$FAULT" = reload ] && want=3
case $POINT in
  copy) mkdir -p "$W/$A/bulk"; (cd "$W/$A/bulk" && for i in $(seq 1 12000); do echo "$i" > "f$i"; done);;
  preflight) beh=slow@pre:12;;
  switch) deploy $A 2 nosigterm || exit 1; beh=ok; want=2or3;;   # a failed setup deploy is a FAIL
  verify) beh=unhealthy@live; want=2;;
  rollback) beh=unhealthy@live,nosigterm@live; want=2;;
esac
loop_start $A
setv $A 3 "$beh"
(cd "$W/$A" && exec "$R" deploy > "$W/client.out" 2>&1; echo "rc=$?" >> "$W/client.out") &
CL=$!
case $POINT in
  copy) wait_phase $A copy 120;;
  preflight) wait_phase $A preflight 120 && sleep 3;;
  switch) wait_phase $A switch 60 && srv "sudo bash -c 'for i in \$(seq 100); do r=\$(readlink /opt/tando/apps/$A/current); [ \"\${r##*/}\" = \"\$(sed -n s/^target=//p /opt/tando/apps/$A/state)\" ] && exit 0; sleep 0.1; done; exit 1'" && sleep 2;;
  verify) wait_phase $A verify 60 && sleep 3;;
  rollback) wait_phase $A rollback 90 && sleep 3;;
esac
ok "reached phase $POINT" test $? = 0
facts $A > /dev/null 2>&1; log "at the fault: $(tr '\n' ' ' < "$W/facts")"
T0=$(date +%s)
case $FAULT in
  kill9) kill9_act $A;;
  restart) docker_restart;;
  powerloss) docker_powerloss;;
  reload) srv "sudo systemctl daemon-reload";;
  sshdrop) srv "sudo nft add table inet fault; sudo nft 'add chain inet fault in { type filter hook input priority -10; }'; sudo nft add rule inet fault in tcp dport 22 drop" ;
           sleep 40; docker exec "$TANDO_TEST_NAME" nft delete table inet fault;;
esac
# the client must come back on its own (it polls until the activation's result is final)
t=0; while kill -0 $CL 2> /dev/null && [ $t -lt 120 ]; do sleep 1; t=$((t + 1)); done
if kill -0 $CL 2> /dev/null; then
  ok "client ends by itself within 120 s of the fault" false
  kill $CL 2> /dev/null; pkill -f "deploy-status $A" 2> /dev/null
else ok "client ended ($(grep '^rc=' "$W/client.out")) in ${t}s" true; fi
tail -4 "$W/client.out" >&2
# serving again, without any tando command
case $want in 2or3) until_ 60 serves_any $A 2 3;;
  *) until_ 60 serves $A "$want";; esac
rc=$?; ok "serves v$want again within 60 s ($(( $(date +%s) - T0 ))s after the fault)" test $rc = 0
sleep 5
loop_stop
got=$(ver $A); [ "$want" = 2or3 ] && want=$got
# for faults that take the server down, failed requests during the outage are expected
case $FAULT in restart|powerloss) F_NOTES="$F_NOTES; server down for the fault itself";;
  *) ok "no failed request ($F_BAD of $F_N)" test "$F_BAD" = 0;; esac
truth $A "$want"
grep -E "$(cat "$W/facts" | sed -n 's/^scur=//p')" "$W/history.out" | tail -2 >&2
next_deploy $A 4
f_end
