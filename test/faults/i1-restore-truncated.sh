#!/bin/bash
# i1: restore of a backup whose data.tar.gz is truncated. Expect: restore fails, data before the
# restore untouched, app running again, state truthful.
. "$(dirname "$0")/lib-fault.sh"
f_init i1 "restore of a truncated archive" "backup restore"
A=fi1; f_fresh $A "data = data"
srv "sudo runuser -u tando-$A -- sh -c 'head -c 2000000 /dev/urandom > /opt/tando/apps/$A/shared/data/blob; echo original > /opt/tando/apps/$A/shared/data/marker'"
(cd "$W/$A" && "$R" backup now > "$W/bk.out" 2>&1); id=$(sed -n 's/.*backup \([0-9-]*-manual\).*/\1/p' "$W/bk.out")
log "backup $id"
srv "sudo runuser -u tando-$A -- sh -c 'echo changed > /opt/tando/apps/$A/shared/data/marker'"
srv "sudo bash -c 'f=/var/backups/tando/$A/$id/data.tar.gz; truncate -s \$((\$(stat -c %s \$f) / 2)) \$f'"
loop_start $A
(cd "$W/$A" && "$R" backup restore "$id" > "$W/rs.out" 2>&1); rrc=$?
log "restore rc=$rrc: $(tail -2 "$W/rs.out" | tr '\n' ' ')"
sleep 2; loop_stop
ok "restore reports failure" test $rrc != 0
ok "data untouched (marker = changed)" test "$(srv "sudo cat /opt/tando/apps/$A/shared/data/marker")" = changed
ok "no restore leftovers in shared/" test -z "$(srv "sudo ls -A /opt/tando/apps/$A/shared | grep -E 'restore|replaced'")"
log "requests during restore: $F_BAD failed of $F_N (the app is stopped while restoring)"
truth $A 2
next_deploy $A 4
f_end
