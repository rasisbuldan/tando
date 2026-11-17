#!/bin/bash
# g8: the last good (= current) release directory was deleted by hand (the process keeps running), then a deploy fails after the switch.
# Expect: tando does not switch to a missing release; the app keeps serving something.
. "$(dirname "$0")/lib-fault.sh"
f_init g8 "last-good release dir deleted" "failing deploy (rollback target missing)"
A=fg8; f_fresh $A
lg=$(srv "sudo sed -n 's/^last_good=//p' /opt/tando/apps/$A/state")
srv "sudo rm -rf /opt/tando/apps/$A/releases/$lg"
loop_start $A
deploy $A 3 unhealthy@live; log "deploy rc=$DRC: $(grep -E 'back on|after the switch' "$W/$A.d3.out" | head -1)"
sleep 10; loop_stop
log "Caddy answers $(curl -s -o /dev/null -w '%{http_code}' -m 20 "$(url $A)"); unit $(srv "systemctl is-active tando-$A")"
ok "the app still answers 200 ($F_BAD failed)" test "$(curl -s -o /dev/null -w '%{http_code}' -m 20 "$(url $A)")" = 200
truth $A "$(ver $A)"
next_deploy $A 4
f_end
