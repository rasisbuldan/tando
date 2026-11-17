#!/bin/bash
# c3: rollback typed while a deploy is in pre-flight. Expect: rollback waits, then rolls back the
# freshly deployed release (or refuses clearly); state consistent.
. "$(dirname "$0")/lib-fault.sh"
f_init c3 "rollback during deploy" "preflight"
A=fc3; f_fresh $A
loop_start $A
setv $A 3 slow@pre:8; client_bg $A deploy
wait_phase $A preflight 60
(cd "$W/$A" && "$R" rollback > "$W/rb.out" 2>&1; echo "rc=$?" >> "$W/rb.out")
client_wait 120
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
log "deploy rc=$(client_rc); rollback: $(tail -3 "$W/rb.out" | tr '\n' ' ')"
v=$(ver $A)
if grep -q '^rc=0' "$W/rb.out"; then ok "rollback after deploy: v2 serves" test "$v" = 2; else ok "rollback refused, deploy live: v3" test "$v" = 3; fi
truth $A "$v"
next_deploy $A 4
f_end
