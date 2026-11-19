#!/bin/bash
# f3: while the app is stopped, a stray process (say a copy started by hand for debugging) takes
# the app's own port and answers 200. Then: tando start, tando deploy. Expect: tando notices that
# its process cannot bind and does not report the stray's answers as the app being healthy.
. "$(dirname "$0")/lib-fault.sh"
f_init f3 "app port occupied by a stray process" "start / deploy"
A=ff3; f_fresh $A
p=$(app_port $A)
(cd "$W/$A" && "$R" stop > /dev/null 2>&1)
stray_start $p
(cd "$W/$A" && "$R" start > "$W/start.out" 2>&1); src=$?
sleep 6   # kept: time for the unit to try (and fail) to bind while the stray holds the port
u=$(srv "systemctl is-active tando-$A; systemctl show -P NRestarts tando-$A" | tr '\n' ' ')
log "start rc=$src ($(tail -1 "$W/start.out")); unit: $u; Caddy answers: $(curl -s -m 3 "$(url $A)")"
[ "$src" = 0 ] && untruth "tando start reported healthy while its process cannot bind (unit: $u); the stray answers"
deploy $A 3 ok; log "deploy rc=$DRC: $(grep -E 'live in|rolled|failed' "$W/$A.d3.out" | head -1)"
sleep 5   # kept: a deploy that reported live must still be answered by the app, not the stray, 5 s on
u=$(srv "systemctl is-active tando-$A; systemctl show -P NRestarts tando-$A" | tr '\n' ' ')
body=$(curl -s -m 3 "$(url $A)"); log "after deploy: unit $u, Caddy answers [$body]"
[ "$DRC" = 0 ] && [ "$body" = stray ] && untruth "deploy v3 reported live and verified, but a stray process answers and tando-$A is $u"
stray_stop $p
# tando refused to start it while the stray held the port (the app stays stopped, as it was);
# with the port free, a start works
(cd "$W/$A" && "$R" start > "$W/start2.out" 2>&1); ok "start once the port is free" test $? = 0
[ "$src" = 0 ] || grep -q "held by another process" "$W/start.out" || untruth "the refused start did not say why"
truth $A "$(ver $A)"
next_deploy $A 4
f_end
