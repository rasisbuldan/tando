#!/bin/bash
# m2: a second deploy starts while the first release still soaks (CODE-REVIEW R2). Expect: it
# says what it waits for and about how long, in the deploy box, then deploys; nothing is lost.
. "$(dirname "$0")/lib-fault.sh"
f_init m2 "deploy while the previous release soaks" "configure (wait)"
# (soak = 25 in tando.conf wins over TANDO_SOAK and FAULT_SETUP_SOAK: every deploy here, f_fresh's
# and next_deploy's too, soaks 25 s. Kept: the soak another deploy waits behind is what m2 is about.)
A=fm2; f_fresh $A "soak = 25"
loop_start $A
TANDO_WAIT="" deploy $A 3 ok          # returns once live; the server soaks it 25 s more
id3=$(rid "$W/$A.d3.out")
T0=$(date +%s)
TANDO_WAIT="" deploy $A 4 ok
T1=$(date +%s)
loop_stop
sed 's/^/    | /' "$W/$A.d4.out" >&2
w=$(grep 'waiting for' "$W/$A.d4.out" | head -1)
ok "the first deploy returned live" test "$(grep -c 'live in' "$W/$A.d3.out")" = 1
ok "the second deploy succeeded (rc=$DRC, $((T1 - T0)) s)" sh -c "[ $DRC = 0 ] && grep -q 'live in' '$W/$A.d4.out'"
ok "it said it waits for release $id3's soak" sh -c "printf '%s' \"\$1\" | grep -q 'waiting for the soak of release $id3'" _ "$w"
n=$(printf '%s' "$w" | sed -n 's/.*: about \([0-9][0-9]*\)s more.*/\1/p')
ok "with about how long (${n:-none} s of 25)" sh -c "[ -n '$n' ] && [ '$n' -ge 1 ] && [ '$n' -le 25 ]"
ok "inside the deploy box" sh -c "printf '%s' \"\$1\" | grep -q '^[│|]'" _ "$w"
ok "then how long it waited" grep -q 'waited [0-9]* *s; deploying' "$W/$A.d4.out"
ok "no failed request ($F_BAD of $F_N)" test "$F_BAD" = 0
# an idle app: no waiting line
TANDO_WAIT="" deploy $A 5 ok
# the end of v5's soak is the event (state idle, the activation's unit gone), then 2 s as before
wait_phase $A idle 60; until_ 20 act_gone $A; sleep 2
next_deploy $A 6
ok "no waiting line when nothing holds the app" sh -c "! grep -q 'waiting for' '$W/$A.d6.out'"
truth $A 6
f_end
