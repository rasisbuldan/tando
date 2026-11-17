#!/bin/bash
# k2: `tando host setup` was interrupted: the new agent is installed but tando-logs, tando-watch and
# the recover unit are missing. Expect: deploys keep working; doctor says what is missing; a reboot
# with an interrupted activation still recovers (or doctor says it cannot).
. "$(dirname "$0")/lib-fault.sh"
f_init k2 "host setup interrupted (partial install)" "deploy + doctor"
A=fk2; f_fresh $A
srv "sudo bash -c 'mv /opt/tando/bin/tando-logs /root/; mv /opt/tando/bin/tando-watch /root/; systemctl disable -q tando-recover.service'"
loop_start $A
deploy $A 3 ok; ok "deploy works without tando-logs" test $DRC = 0; grep tando-agent "$W/$A.d3.out" >&2
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
"$R" doctor > "$W/doc.out" 2>&1
ok "doctor says tando-logs is missing" grep -qE 'logs.*not installed' "$W/doc.out"
ok "doctor says the recover unit is not enabled" grep -q 'recover unit.*not enabled' "$W/doc.out"
truth $A 3
"$R" host setup test public_port="$HP" > "$W/setup.out" 2>&1 || { F_RECOVER=n; F_NOTES="$F_NOTES; host setup again failed"; tail -3 "$W/setup.out" >&2; }
next_deploy $A 4
f_end
