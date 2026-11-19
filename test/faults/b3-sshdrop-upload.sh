#!/bin/bash
# b3: the network drops during the upload (all packets to ssh dropped for 45 s, so the client's
# `end` cannot reach the server either). Expect: the next deploy after the network is back works.
. "$(dirname "$0")/lib-fault.sh"
f_init b3 "ssh connection dropped (45 s)" "during upload"
A=fb3; f_fresh $A
f_big; cp "$FW/big/blob.bin" "$W/$A/"
loop_start $A
setv $A 3 ok; client_bg $A deploy
wait_rsync; ok "upload running" test $? = 0
docker exec "$TANDO_TEST_NAME" sh -c "nft add table inet fault; nft 'add chain inet fault in { type filter hook input priority -10; }'; nft add rule inet fault in tcp dport 22 drop"
client_wait 60; ok "client gives up within 60 s" test $? = 0
sleep 3; docker exec "$TANDO_TEST_NAME" nft delete table inet fault
client_wait 30; tail -4 "$W/client.out" >&2
loop_stop; ok "no failed request" test "$F_BAD" = 0
truth $A 2
facts $A > /dev/null 2>&1; log "lease after the drop: $(fact lease)"
rm -f "$W/$A/blob.bin"; next_deploy $A 4
f_end
