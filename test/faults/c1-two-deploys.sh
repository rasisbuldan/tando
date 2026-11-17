#!/bin/bash
# c1: two deploys of the same app at once from two terminals. Expect: one wins, the other is
# refused with a clear message (or queued), nothing half-done; next deploy works.
. "$(dirname "$0")/lib-fault.sh"
f_init c1 "two deploys at once" "upload/activation"
A=fc1; f_fresh $A
cp -R "$W/$A" "$W/${A}b"; setv ${A}b 5 ok
loop_start $A
setv $A 3 slow@pre:3
(cd "$W/$A" && "$R" deploy > "$W/t1.out" 2>&1; echo "rc=$?" >> "$W/t1.out") &
p1=$!
(cd "$W/${A}b" && "$R" deploy > "$W/t2.out" 2>&1; echo "rc=$?" >> "$W/t2.out") &
p2=$!
wait $p1 $p2
loop_stop; ok "no failed request" test "$F_BAD" = 0
r1=$(sed -n 's/^rc=//p' "$W/t1.out") r2=$(sed -n 's/^rc=//p' "$W/t2.out")
log "terminal 1 rc=$r1: $(grep -E 'tando-agent|live in|another' "$W/t1.out" | head -1)"
log "terminal 2 rc=$r2: $(grep -E 'tando-agent|live in|another' "$W/t2.out" | head -1)"
v=$(ver $A)
ok "served version ($v) is the one whose deploy succeeded" sh -c "{ [ $r1 = 0 ] && [ $v = 3 ]; } || { [ $r2 = 0 ] && [ $v = 5 ]; }"
ok "at least one deploy succeeded" sh -c "[ $r1 = 0 ] || [ $r2 = 0 ]"
truth $A "$v"
next_deploy $A 6
f_end
