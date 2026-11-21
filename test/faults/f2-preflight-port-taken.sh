#!/bin/bash
# f2: a stray process listens on the app's pre-flight port. Expect: the deploy refuses with a
# message naming the port; v2 keeps serving; once the stray is gone the next deploy works.
. "$(dirname "$0")/lib-fault.sh"
f_init f2 "pre-flight port occupied by a stray process" "preflight"
A=ff2; f_fresh $A
pp=$(app_preflight_port $A); stray_start "$pp"
loop_start $A
deploy $A 3 ok; log "deploy rc=$DRC: $(grep -E 'pre-flight|in use' "$W/$A.d3.out" | head -1)"
loop_stop; ok "no failed request" test "$F_BAD" = 0
ok "deploy refused" test "$DRC" != 0
ok "message names the port" grep -q "$pp" "$W/$A.d3.out"
truth $A 2
stray_stop "$pp"
next_deploy $A 4
f_end
