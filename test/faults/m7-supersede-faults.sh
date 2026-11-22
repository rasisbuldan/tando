#!/bin/bash
# m7: a deploy supersedes the soak of the release before it, with a fault at each step of the
# overlap. Expect: the superseded release is recorded once, as superseded (live, never verified,
# never last_good); a failure of the newer deploy goes back to the last VERIFIED release, never to
# the superseded one; a kill at any step is finished by recovery; no request fails meanwhile.
#   1 the soaking activation is killed the moment it decides to end its soak (fin.supersede)
#   2 it is killed after its superseded end is committed, before its history line (deploy.hist)
#   3 the newer deploy fails after its switch: back to the last verified release
#   4 the newer deploy is killed in its pre-flight: the superseded release keeps serving
. "$(dirname "$0")/lib-fault.sh"
f_init m7 "deploy supersedes a soak, faults in the overlap" "soak/configure/activation"
A=fm7; f_fresh $A
SOAK=25
T=/run/tando-test
dxs() { docker exec -i "$TANDO_TEST_NAME" bash -c "$1"; }
# fault_arm <point> <action> <verb>: one fault for this app (server/tando-agent: fp), as the matrix does
fault_arm() {
  dxs "install -m 644 -o root -g root /dev/null /etc/tando-test-server && install -d -m 700 -o root -g root $T &&
       rm -f $T/fired && printf 'point=%s\naction=%s\nverb=%s\napp=%s\n' $1 $2 $3 $A > $T/.spec && mv -f $T/.spec $T/fault"
}
fault_fired() { dxs "grep -qx 'point=$1' $T/fired"; }
fault_clear() { dxs "rm -f $T/fault $T/fired $T/next"; }
st() { srv "sudo sed -n 's/^$1=//p' /opt/tando/apps/$A/state"; }
hist_rows() { srv "sudo /opt/tando/bin/tando-agent history $A 40" 2> /dev/null; }
# hist_of <id>: the results of its history lines, space-separated (one line each: "superseded ")
hist_of() { hist_rows | awk -F '\t' -v id="$1" '$4 == id { printf "%s ", $6 }'; }
soaking() { srv "sudo grep -qx phase=soak /opt/tando/apps/$A/activation"; }
# a release goes live and soaks SOAK s on the server; the client returns at live
soak_deploy() { TANDO_SOAK=$SOAK TANDO_WAIT="" deploy "$@"; }
lg0=$(st last_good)

# 1 ---------------------------------------------------------------------------------------------
loop_start $A
soak_deploy $A 3 ok; id3=$(rid "$W/$A.d3.out")
ok "1 v3 ($id3) is live and soaking" soaking
fault_arm fin.supersede kill run-activation
soak_deploy $A 4 ok; id4=$(rid "$W/$A.d4.out")
ok "1 the soaking activation was killed as it decided to end its soak" fault_fired fin.supersede
fault_clear
ok "1 the newer deploy went live (rc=$DRC)" sh -c "[ $DRC = 0 ] && grep -q 'live in' '$W/$A.d4.out'"
ok "1 serves v4" until_ 30 serves $A 4
ok "1 $id3 is recorded once, as superseded ($(hist_of "$id3"))" test "$(hist_of "$id3")" = "superseded "
ok "1 $id3's status is superseded" test "$(st "status_$id3")" = superseded
ok "1 last_good is still $lg0 ($(st last_good))" test "$(st last_good)" = "$lg0"

# 2 ---------------------------------------------------------------------------------------------
until_ 30 soaking
fault_arm deploy.hist kill run-activation
soak_deploy $A 5 ok; id5=$(rid "$W/$A.d5.out")
ok "2 the soaking activation was killed after its end was committed, before its history line" fault_fired deploy.hist
fault_clear
ok "2 the newer deploy went live (rc=$DRC)" sh -c "[ $DRC = 0 ] && grep -q 'live in' '$W/$A.d5.out'"
ok "2 serves v5" until_ 30 serves $A 5
ok "2 $id4 is recorded once, as superseded ($(hist_of "$id4"))" test "$(hist_of "$id4")" = "superseded "
ok "2 last_good is still $lg0 ($(st last_good))" test "$(st last_good)" = "$lg0"
loop_stop
ok "1-2 no failed request ($F_BAD of $F_N)" test "$F_BAD" = 0

# 3 ---------------------------------------------------------------------------------------------
until_ 30 soaking
soak_deploy $A 6 exit@live; id6=$(rid "$W/$A.d6.out")
ok "3 the bad deploy failed (rc=$DRC)" test "$DRC" != 0
ok "3 $id6 is recorded as rolled back or failed ($(hist_of "$id6"))" sh -c "case '$(hist_of "$id6")' in 'rolledback '|'failed ') exit 0;; esac; exit 1"
ok "3 serves v2, the last verified release (never the superseded v5)" until_ 30 serves $A 2
ok "3 $id5 is recorded once, as superseded ($(hist_of "$id5"))" test "$(hist_of "$id5")" = "superseded "
ok "3 current is $lg0 and verified" sh -c "[ '$(st current)' = '$lg0' ] && [ '$(st "status_$lg0")' = verified ]"

# 4 ---------------------------------------------------------------------------------------------
soak_deploy $A 7 ok; id7=$(rid "$W/$A.d7.out")
ok "4 v7 ($id7) is live and soaking" soaking
loop_start $A
setv $A 8 slow@pre:12
(cd "$W/$A" && TANDO_SOAK=$SOAK TANDO_WAIT="" "$R" deploy > "$W/$A.d8.out" 2>&1; echo "rc=$?" >> "$W/$A.d8.out") &
CL=$!
ok "4 the newer deploy reached its pre-flight" wait_phase $A preflight 90
kill9_act $A
t=0; while kill -0 $CL 2> /dev/null && [ $t -lt 120 ]; do sleep 1; t=$((t + 1)); done
ok "4 the client ended by itself ($(grep '^rc=' "$W/$A.d8.out"))" sh -c "! kill -0 $CL 2> /dev/null"
ok "4 serves v7, the superseded release (current untouched)" until_ 30 serves $A 7
sleep 3   # kept: 3 s more of requests after the fault (none may fail)
loop_stop
ok "4 no failed request ($F_BAD of $F_N)" test "$F_BAD" = 0
ok "4 $id7 is recorded once, as superseded ($(hist_of "$id7"))" test "$(hist_of "$id7")" = "superseded "
ok "4 state idle, current $id7 (superseded), last_good $lg0" sh -c \
  "[ '$(st phase)' = idle ] && [ '$(st current)' = '$id7' ] && [ '$(st "status_$id7")' = superseded ] && [ '$(st last_good)' = '$lg0' ]"
hist_rows | tail -8 | cut -f3-6,13- | sed 's/^/    /' >&2
next_deploy $A 9
truth $A 9
f_end
