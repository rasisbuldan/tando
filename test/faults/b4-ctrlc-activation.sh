#!/bin/bash
# b4: Ctrl-C while the client follows the activation. Expect: activation continues on the server
# and finishes (v3 verified); the next deploy works.
. "$(dirname "$0")/lib-fault.sh"
f_init b4 "laptop Ctrl-C" "during activation (polling)"
A=fb4; f_fresh $A
loop_start $A
setv $A 3 slow@pre:6; client_bg $A deploy
wait_phase $A preflight 60; ok "activation in preflight" test $? = 0
client_sig INT
client_wait 20; ok "client detaches" test $? = 0; tail -2 "$W/client.out" >&2
until_ 60 serves $A 3; ok "activation finished on its own: v3 serves" test $? = 0
sleep 2; loop_stop; ok "no failed request" test "$F_BAD" = 0
truth $A 3
next_deploy $A 4
f_end
