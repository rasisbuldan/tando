#!/bin/bash
# c6: tando backup now while a deploy (app with data) is in pre-flight. Expect: both succeed.
. "$(dirname "$0")/lib-fault.sh"
f_init c6 "backup now during deploy" "preflight"
A=fc6; f_fresh $A "data = data"
loop_start $A
setv $A 3 slow@pre:8; client_bg $A deploy
wait_phase $A preflight 60
(cd "$W/$A" && "$R" backup now > "$W/bk.out" 2>&1; echo "rc=$?" >> "$W/bk.out")
client_wait 120
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
ok "deploy succeeded" test "$(client_rc)" = 0
ok "backup succeeded" grep -q '^rc=0' "$W/bk.out"
truth $A 3
next_deploy $A 4
f_end
