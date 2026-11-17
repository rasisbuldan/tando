#!/bin/bash
# h1: the disk holding /opt/tando/apps/<app> is 100% full when a deploy starts (a 2 GB VPS has
# one disk: releases, state, incoming and history all live on it). Expect: the deploy fails with a
# message about space, the client does not hang, v2 serves, state truthful; after space is freed
# the next deploy works untouched.
. "$(dirname "$0")/lib-fault.sh"
f_init h1 "disk full (app dir, 100%)" "deploy start (upload)"
A=fh1; f_fresh $A
tmpfs_over /opt/tando/apps/$A 30m >&2
srv "sudo systemctl restart tando-$A"; sleep 1
fill /opt/tando/apps/$A 0
loop_start $A
setv $A 3 ok; client_bg $A deploy
client_wait 150; ok "client ends within 150 s" test $? = 0
kill $CL 2> /dev/null; log "deploy rc=$(client_rc): $(grep -iE 'space|tando-agent|failed|error' "$W/client.out" | head -3 | tr '\n' ' ')"
ok "deploy reports failure" test "$(client_rc)" != 0
grep -qi 'space\|full' "$W/client.out" || F_NOTES="$F_NOTES; message does not say the disk is full"
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
truth $A 2
unfill /opt/tando/apps/$A
facts $A > /dev/null; log "after freeing: $(tr '\n' ' ' < "$W/facts")"
next_deploy $A 4
f_end
