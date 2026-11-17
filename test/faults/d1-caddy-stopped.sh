#!/bin/bash
# d1: Caddy is stopped (crashed, or stopped by hand) and a deploy runs. Expect: the deploy refuses
# or fails cleanly with a message naming Caddy, leaves state truthful, and once Caddy is back the
# app serves its last good release and the next deploy works.
. "$(dirname "$0")/lib-fault.sh"
f_init d1 "Caddy stopped" "deploy (verify through Caddy)"
A=fd1; f_fresh $A
srv "sudo systemctl stop caddy"
deploy $A 3 ok; log "deploy rc=$DRC: $(grep -E 'rolled|failed|caddy|Caddy|answer' "$W/$A.d3.out" | head -3 | tr '\n' ' ')"
ok "deploy reports failure while Caddy is down" test "$DRC" != 0
ok "message mentions Caddy" grep -qi caddy "$W/$A.d3.out"
"$R" doctor > "$W/doctor1.out" 2>&1; ok "doctor reports caddy not running" grep -q 'caddy.*not running' "$W/doctor1.out"
srv "sudo systemctl start caddy"; sleep 2
loop_start $A; sleep 3; loop_stop
truth $A 2
next_deploy $A 4
f_end
