#!/bin/bash
# g2: the state file lost its last bytes (no newline at the end), then a good deploy and a rollback.
. "$(dirname "$0")/lib-fault.sh"
f_init g2 "state file truncated mid-line" "deploy + rollback"
A=fg2; f_fresh $A
srv "sudo bash -c 'f=/opt/tando/apps/$A/state; s=\$(stat -c %s \$f); truncate -s \$((s - 5)) \$f; cat \$f'" >&2
loop_start $A
deploy $A 3 ok; ok "deploy works" test $DRC = 0
(cd "$W/$A" && "$R" rollback > "$W/rb.out" 2>&1); rrc=$?
log "rollback rc=$rrc: $(tail -2 "$W/rb.out" | tr '\n' ' ')"
ok "rollback goes back to v2" sh -c "[ $rrc = 0 ] && [ \"\$(curl -s -m 3 $(url $A))\" = v2 ]"
loop_stop; ok "no failed request" test "$F_BAD" = 0
truth $A "$(ver $A)"
next_deploy $A 4
f_end
