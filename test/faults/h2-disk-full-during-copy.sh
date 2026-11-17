#!/bin/bash
# h2: enough space for the upload, not for the copy into releases/ (a 6 MB release, 4 MB free after
# the upload). Expect: the deploy fails cleanly, partial copy removed, v2 serves, next deploy (after
# freeing) works; no leftover release eating the space.
. "$(dirname "$0")/lib-fault.sh"
f_init h2 "disk full" "during copy to releases/"
A=fh2; f_fresh $A
tmpfs_over /opt/tando/apps/$A 40m >&2
srv "sudo systemctl restart tando-$A"; sleep 1
head -c 6000000 /dev/urandom > "$W/$A/blob.bin"
fill /opt/tando/apps/$A 10500
loop_start $A
setv $A 3 ok; client_bg $A deploy
client_wait 150; ok "client ends within 150 s" test $? = 0
log "deploy rc=$(client_rc): $(grep -iE 'space|tando-agent|failed|copy' "$W/client.out" | head -3 | tr '\n' ' ')"
ok "deploy reports failure" test "$(client_rc)" != 0
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
truth $A 2
srv "sudo du -sh /opt/tando/apps/$A/releases/* /opt/tando/apps/$A/incoming; df -h /opt/tando/apps/$A | tail -1" >&2
rm -f "$W/$A/blob.bin"; unfill /opt/tando/apps/$A
next_deploy $A 4
f_end
