#!/bin/bash
# b1: laptop Ctrl-C (SIGINT) while the release uploads. Expect: lease given back, v2 serves,
# the next deploy works at once.
. "$(dirname "$0")/lib-fault.sh"
f_init b1 "laptop Ctrl-C" "during upload"
A=fb1; f_fresh $A
cp "$FW/big/blob.bin" "$W/$A/"
loop_start $A
setv $A 3 ok; client_bg $A deploy
wait_rsync; ok "upload running" test $? = 0
client_sig INT
client_wait 30; ok "client exits after Ctrl-C" test $? = 0
tail -3 "$W/client.out" >&2
loop_stop; ok "no failed request" test "$F_BAD" = 0
truth $A 2
facts $A > /dev/null 2>&1; [ "$(fact lease)" = free ] || untruth "upload lease still held after Ctrl-C"
rm -f "$W/$A/blob.bin"; next_deploy $A 4
f_end
