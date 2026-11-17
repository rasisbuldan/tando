#!/bin/bash
# g1: the state file is empty (power loss after a rename without fsync, or a slip by hand), then a
# deploy of a release that fails after the switch. Expect: the app keeps serving v2.
. "$(dirname "$0")/lib-fault.sh"
f_init g1 "state file emptied" "failing deploy (verify)"
A=fg1; f_fresh $A
srv "sudo truncate -s 0 /opt/tando/apps/$A/state"
"$R" status -a $A > "$W/st0.out" 2>&1; "$R" doctor > "$W/doc0.out" 2>&1
grep -q "app $A" "$W/doc0.out" || untruth "doctor says nothing while the state file is empty: $(grep -i "$A" "$W/doc0.out")"
loop_start $A
deploy $A 3 unhealthy@live; log "deploy rc=$DRC: $(grep -E 'back on|rolled|after the switch' "$W/$A.d3.out" | head -2 | tr '\n' ' ')"
sleep 3; loop_stop
ok "no failed request ($F_BAD of $F_N)" test "$F_BAD" = 0
truth $A 2
next_deploy $A 4
f_end
