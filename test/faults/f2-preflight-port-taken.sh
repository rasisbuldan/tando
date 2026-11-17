#!/bin/bash
# f2: a stray process listens on the app's pre-flight port. Expect: the deploy refuses with a
# message naming the port; v2 keeps serving; once the stray is gone the next deploy works.
. "$(dirname "$0")/lib-fault.sh"
f_init f2 "pre-flight port occupied by a stray process" "preflight"
A=ff2; f_fresh $A
p=$(app_port $A); stray_start $((p + 100))
loop_start $A
deploy $A 3 ok; log "deploy rc=$DRC: $(grep -E 'pre-flight|in use' "$W/$A.d3.out" | head -1)"
loop_stop; ok "no failed request" test "$F_BAD" = 0
ok "deploy refused" test "$DRC" != 0
ok "message names the port" grep -q "$((p + 100))" "$W/$A.d3.out"
truth $A 2
stray_stop $((p + 100))
next_deploy $A 4
f_end
