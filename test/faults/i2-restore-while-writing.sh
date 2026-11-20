#!/bin/bash
# i2: restore while the app keeps writing to its data directory. Expect: restored data equals the
# backup (writes during the restore do not mix in), app running after.
. "$(dirname "$0")/lib-fault.sh"
f_init i2 "restore while the app is writing" "backup restore"
A=fi2; f_fresh $A "data = data"
deploy $A 3 writer || exit 1   # a failed setup deploy is a FAIL, not a skip
sleep 2
(cd "$W/$A" && "$R" backup now > "$W/bk.out" 2>&1); id=$(sed -n 's/.*[^0-9]\([0-9]\{8\}-[0-9]\{6\}-manual\).*/\1/p' "$W/bk.out")
[ -n "$id" ] || { echo "i2: no backup id in: $(cat "$W/bk.out")" >&2; exit 2; }   # (setup failed: a FAIL, not a pass)
n0=$(srv "sudo tar -xzOf /var/backups/tando/$A/$id/data.tar.gz ./log.txt | wc -l")
sleep 3
loop_start $A
(cd "$W/$A" && "$R" backup restore "$id" --yes > "$W/rs.out" 2>&1); rrc=$?
loop_stop
log "restore rc=$rrc: $(tail -1 "$W/rs.out"); backup had $n0 lines"
ok "restore succeeds" test $rrc = 0
same=$(srv "sudo bash -c 'tar -xzOf /var/backups/tando/$A/$id/data.tar.gz ./log.txt > /tmp/i2.b; head -$n0 /opt/tando/apps/$A/shared/data/log.txt | cmp -s - /tmp/i2.b && echo same'")
ok "restored data starts with exactly the backup's $n0 lines" test "$same" = same
log "requests during restore: $F_BAD failed of $F_N, longest gap ${F_GAP}s"
truth $A 3
next_deploy $A 4
f_end
