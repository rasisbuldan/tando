#!/bin/bash
# c5: env set while a deploy is in pre-flight. Expect: env set waits; the env value reaches the
# process that ends up serving; deploy succeeds.
. "$(dirname "$0")/lib-fault.sh"
f_init c5 "env set during deploy" "preflight"
A=fc5; f_fresh $A
loop_start $A
setv $A 3 slow@pre:8; client_bg $A deploy
wait_phase $A preflight 60
(cd "$W/$A" && "$R" env set FAULTVAR=yes > "$W/env.out" 2>&1; echo "rc=$?" >> "$W/env.out")
client_wait 120
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
log "deploy rc=$(client_rc); env: $(tail -2 "$W/env.out" | tr '\n' ' ')"
ok "deploy succeeded" test "$(client_rc)" = 0
ok "env set succeeded" grep -q '^rc=0' "$W/env.out"
pid=$(srv "systemctl show -P MainPID tando-$A")
ok "serving process has FAULTVAR" sh -c "$SSH 'sudo cat /proc/$pid/environ' | tr '\\0' '\\n' | grep -qx FAULTVAR=yes"
truth $A 3
next_deploy $A 4
f_end
