#!/bin/bash
# m2: a second deploy starts while the first release still soaks (CODE-REVIEW R2). Expect: it
# says, in the deploy box, that it supersedes that release's soak, and deploys without waiting the
# soak out; the superseded release is recorded as such (live, not verified); nothing is lost.
. "$(dirname "$0")/lib-fault.sh"
f_init m2 "deploy while the previous release soaks" "configure (supersede)"
# (soak = 25 in tando.conf wins over TANDO_SOAK and FAULT_SETUP_SOAK: every deploy here, f_fresh's
# and next_deploy's too, soaks 25 s. Kept: the soak the second deploy supersedes is what m2 is about.)
A=fm2; f_fresh $A "soak = 25"
lg0=$(srv "sudo sed -n 's/^last_good=//p' /opt/tando/apps/$A/state")
loop_start $A
TANDO_WAIT="" deploy $A 3 ok          # returns once live; the server soaks it 25 s more
id3=$(rid "$W/$A.d3.out")
T0=$(date +%s)
TANDO_WAIT="" deploy $A 4 ok
T1=$(date +%s)
id4=$(rid "$W/$A.d4.out")
loop_stop
sed 's/^/    | /' "$W/$A.d4.out" >&2
w=$(grep 'supersedes' "$W/$A.d4.out" | head -1)
ok "the first deploy returned live" test "$(grep -c 'live in' "$W/$A.d3.out")" = 1
ok "the second deploy succeeded (rc=$DRC, $((T1 - T0)) s)" sh -c "[ $DRC = 0 ] && grep -q 'live in' '$W/$A.d4.out'"
ok "it said it supersedes release $id3's soak" sh -c "printf '%s' \"\$1\" | grep -q 'release $id3 is soaking: this deploy supersedes it'" _ "$w"
ok "inside the deploy box" sh -c "printf '%s' \"\$1\" | grep -q '^[│|]'" _ "$w"
ok "it did not wait the soak out (no waiting line)" sh -c "! grep -q 'waiting for the soak' '$W/$A.d4.out'"
# the server's record: v3 superseded (its verify field: the seconds it soaked, under the 25 of its
# soak), v4 the last good once its own soak ends; v3 was never last_good
srv "sudo /opt/tando/bin/tando-agent history $A 5" > "$W/hist.rows" 2> /dev/null
h3=$(awk -F '\t' -v id="$id3" '$4 == id { print $6 " verify " $13 " s: " $14 }' "$W/hist.rows" | tail -1)
log "v3 history: $h3"
ok "history says $id3 was superseded" sh -c "awk -F '\t' '\$4 == \"$id3\" && \$6 == \"superseded\"' '$W/hist.rows' | grep -q 'superseded by a newer deploy [0-9]* s into its soak of 25 s'"
ok "$id3 soaked less than its 25 s" sh -c "awk -F '\t' '\$4 == \"$id3\" && \$6 == \"superseded\" { exit !(\$13 + 0 < 20) }' '$W/hist.rows'"
ok "$id3's status is superseded, not verified" sh -c "[ \"\$($SSH \"sudo sed -n 's/^status_$id3=//p' /opt/tando/apps/$A/state\")\" = superseded ]"
lg=$(srv "sudo sed -n 's/^last_good=//p' /opt/tando/apps/$A/state")
ok "last_good was never $id3 (it is $lg; before: $lg0)" sh -c "[ '$lg' = '$lg0' ] || [ '$lg' = '$id4' ]"
ok "no failed request ($F_BAD of $F_N)" test "$F_BAD" = 0
# an idle app: no waiting line
TANDO_WAIT="" deploy $A 5 ok
# the end of v5's soak is the event (state idle, the activation's unit gone), then 2 s as before
wait_phase $A idle 60; until_ 20 act_gone $A; sleep 2
next_deploy $A 6
ok "no waiting line when nothing holds the app" sh -c "! grep -q 'waiting for' '$W/$A.d6.out'"
truth $A 6
f_end
