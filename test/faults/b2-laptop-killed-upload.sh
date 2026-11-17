#!/bin/bash
# b2: the laptop dies during the upload (SIGKILL of the client: lid closed, battery, terminal
# closed hard). Expect: the next deploy from the same laptop works without `tando unlock`.
. "$(dirname "$0")/lib-fault.sh"
f_init b2 "laptop killed (SIGKILL)" "during upload"
A=fb2; f_fresh $A
cp "$FW/big/blob.bin" "$W/$A/"
loop_start $A
setv $A 3 ok; client_bg $A deploy
wait_rsync; ok "upload running" test $? = 0
client_sig KILL
client_wait 10
loop_stop; ok "no failed request" test "$F_BAD" = 0
sleep 5
truth $A 2
facts $A > /dev/null 2>&1; log "lease after the kill: $(fact lease)"
rm -f "$W/$A/blob.bin"; next_deploy $A 4
f_end
