#!/bin/bash
# b5: network drops for 30 s while the client polls the activation. Expect: client reconnects and
# reports the real result; activation unaffected.
. "$(dirname "$0")/lib-fault.sh"
f_init b5 "ssh connection dropped (30 s)" "during activation (polling)"
A=fb5; f_fresh $A
loop_start $A
setv $A 3 slow@pre:6; client_bg $A deploy
wait_phase $A preflight 60; ok "activation in preflight" test $? = 0
docker exec "$TANDO_TEST_NAME" sh -c "nft add table inet fault; nft 'add chain inet fault in { type filter hook input priority -10; }'; nft add rule inet fault in tcp dport 22 drop"
sleep 30; docker exec "$TANDO_TEST_NAME" nft delete table inet fault
client_wait 120; ok "client ends" test $? = 0
tail -3 "$W/client.out" >&2
ok "client reports success (rc=$(client_rc))" test "$(client_rc)" = 0
loop_stop; ok "no failed request" test "$F_BAD" = 0
truth $A 3
next_deploy $A 4
f_end
