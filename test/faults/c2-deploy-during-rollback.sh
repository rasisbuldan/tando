#!/bin/bash
# c2: a deploy starts while a rollback is restarting the app (slow stop: old process ignores
# SIGTERM). Expect: the deploy waits for the rollback and then goes live; history in order.
. "$(dirname "$0")/lib-fault.sh"
f_init c2 "deploy during rollback" "rollback switch"
A=fc2; f_fresh $A
deploy $A 3 nosigterm || exit 1   # a failed setup deploy is a FAIL, not a skip
loop_start $A
(cd "$W/$A" && "$R" rollback > "$W/rb.out" 2>&1; echo "rc=$?" >> "$W/rb.out") & prb=$!
wait_phase $A rollback 30; sleep 1
setv $A 4 ok; client_bg $A deploy
wait $prb; client_wait 120
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
log "rollback: $(tail -3 "$W/rb.out" | tr '\n' ' ')"
log "deploy rc=$(client_rc): $(grep -E 'tando-agent|live in' "$W/client.out" | head -1)"
ok "rollback succeeded" grep -q '^rc=0' "$W/rb.out"
ok "deploy succeeded" test "$(client_rc)" = 0
truth $A 4
next_deploy $A 5
f_end
