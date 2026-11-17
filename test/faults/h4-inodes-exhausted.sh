#!/bin/bash
# h4: no free inodes on the app's filesystem (blocks free). A release with 300 files.
. "$(dirname "$0")/lib-fault.sh"
f_init h4 "inode exhaustion" "deploy (upload/copy)"
A=fh4; f_fresh $A
tmpfs_over /opt/tando/apps/$A 200m 2000 >&2
srv "sudo systemctl restart tando-$A"; sleep 1
mkdir -p "$W/$A/many"; (cd "$W/$A/many" && for i in $(seq 1 300); do echo $i > f$i; done)
srv "sudo bash -c 'mkdir -p /opt/tando/apps/$A/.ifill; i=0; while [ \$(df -Pi /opt/tando/apps/$A | awk \"NR==2 {print \\\$4}\") -gt 150 ]; do touch /opt/tando/apps/$A/.ifill/\$i; i=\$((i+1)); done; df -i /opt/tando/apps/$A | tail -1'" >&2
loop_start $A
setv $A 3 ok; client_bg $A deploy
client_wait 150; ok "client ends within 150 s" test $? = 0
log "deploy rc=$(client_rc): $(grep -iE 'inode|space|tando-agent|failed|copy|rsync' "$W/client.out" | head -3 | tr '\n' ' ')"
ok "deploy reports failure" test "$(client_rc)" != 0
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
truth $A 2
unfill /opt/tando/apps/$A
next_deploy $A 4
f_end
