#!/bin/bash
# h5: the disk fills up (another process, logs) while a failing release is being verified, so the
# rollback has to work on a full disk. Expect: v2 serves; state and history tell the truth; after
# freeing, the next deploy works untouched.
. "$(dirname "$0")/lib-fault.sh"
f_init h5 "disk fills up" "during verify -> rollback"
A=fh5; f_fresh $A
tmpfs_over /opt/tando/apps/$A 30m >&2
srv "sudo systemctl restart tando-$A"; sleep 1
loop_start $A
setv $A 3 unhealthy@live; client_bg $A deploy
wait_phase $A verify 60; ok "in verify" test $? = 0
fill /opt/tando/apps/$A 0
client_wait 150; ok "client ends within 150 s" test $? = 0
kill $CL 2> /dev/null; log "deploy rc=$(client_rc): $(tail -2 "$W/client.out" | tr '\n' ' ')"
sleep 3; loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
truth $A 2
unfill /opt/tando/apps/$A
facts $A > /dev/null; log "after freeing: $(tr '\n' ' ' < "$W/facts")"
next_deploy $A 4
f_end
