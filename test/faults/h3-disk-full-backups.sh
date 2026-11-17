#!/bin/bash
# h3: /var/backups/tando is full; an app with data deploys (pre-deploy backup) and `backup now` runs.
# Expect: clear failures, no half-written backup left, v2 serves, state truthful; after freeing
# space both work.
. "$(dirname "$0")/lib-fault.sh"
f_init h3 "disk full (backups)" "pre-deploy backup + backup now"
A=fh3; f_fresh $A "data = data"
srv "sudo runuser -u tando-$A -- sh -c 'head -c 3000000 /dev/urandom > /opt/tando/apps/$A/shared/data/blob'"
srv "sudo install -d -m 700 /var/backups/tando"; tmpfs_over /var/backups/tando 20m >&2
fill /var/backups/tando 1000
loop_start $A
deploy $A 3 ok; log "deploy rc=$DRC: $(grep -iE 'backup|tando-agent|failed' "$W/$A.d3.out" | head -2 | tr '\n' ' ')"
ok "deploy fails (no pre-deploy backup possible)" test $DRC != 0
(cd "$W/$A" && "$R" backup now > "$W/bk.out" 2>&1); brc=$?; log "backup now rc=$brc: $(tail -1 "$W/bk.out")"
ok "backup now fails" test $brc != 0
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
left=$(srv "sudo ls -A /var/backups/tando/$A | grep tmp")
ok "no half-written backup left [$left]" test -z "$left"
truth $A 2
unfill /var/backups/tando
(cd "$W/$A" && "$R" backup now > "$W/bk2.out" 2>&1) || { F_RECOVER=n; F_NOTES="$F_NOTES; backup now after freeing failed"; }
next_deploy $A 4
srv "sudo umount /var/backups/tando"
f_end
