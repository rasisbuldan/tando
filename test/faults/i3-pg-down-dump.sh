#!/bin/bash
# i3: PostgreSQL is down when a deploy takes its pre-deploy backup (pg_dump), and during `backup now`.
# Needs `tando host setup <host> postgres=yes` (apt, network). Expect: clear failure, v2 serves.
. "$(dirname "$0")/lib-fault.sh"
f_init i3 "Postgres down" "pg_dump (pre-deploy backup, backup now)"
grep -q postgres=yes "$FW/pg-$TANDO_TEST_NAME" 2> /dev/null || { "$R" host setup test public_port="$HP" postgres=yes > "$W/pg.out" 2>&1 && echo postgres=yes > "$FW/pg-$TANDO_TEST_NAME"; } || { tail -3 "$W/pg.out" >&2; echo "SKIP: no postgres" >&2; exit 3; }
A=fi3; f_fresh $A "database = postgres"
srv "sudo systemctl stop postgresql"
loop_start $A
deploy $A 3 ok; log "deploy rc=$DRC: $(grep -iE 'backup|failed' "$W/$A.d3.out" | head -2 | tr '\n' ' ')"
(cd "$W/$A" && "$R" backup now > "$W/bk.out" 2>&1); brc=$?; log "backup now rc=$brc: $(tail -1 "$W/bk.out")"
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
ok "deploy fails clearly" sh -c "[ $DRC != 0 ] && grep -qi backup '$W/$A.d3.out'"
truth $A 2
srv "sudo systemctl start postgresql"; sleep 3
next_deploy $A 4
f_end
