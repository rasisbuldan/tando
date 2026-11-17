#!/bin/bash
# n2: env set of a value it already has; env unset of a variable the app needs to start.
# Expect: the same value again changes nothing and does not restart the app; a change the app does
# not start with is refused after a pre-flight with the new env (the live app is never restarted
# with it), and the command exits non-zero saying so.
. "$(dirname "$0")/lib-fault.sh"
f_init n2 "env set same value; env change that breaks the app" "env set/unset"
A=fn2; f_fresh $A
(cd "$W/$A" && "$R" env set NEED=1 > /dev/null 2>&1)
deploy $A 3 needenv
ok "v3 (needs NEED) is live" serves $A 3
pid() { srv "systemctl show -P MainPID tando-$A"; }
p0=$(pid)
(cd "$W/$A" && "$R" env set NEED=1 > "$W/same.out" 2>&1); rc=$?
ok "env set of the same value: rc 0, nothing changed (rc=$rc: $(tr '\n' ' ' < "$W/same.out"))" sh -c "[ $rc = 0 ] && grep -q 'nothing changed' '$W/same.out'"
ok "and the app was not restarted" test "$p0" = "$(pid)"
loop_start $A
(cd "$W/$A" && "$R" env unset NEED > "$W/break.out" 2>&1); rc=$?
loop_stop
ok "no failed request while the change was tried and refused ($F_BAD of $F_N)" test "$F_BAD" = 0
log "env unset NEED: rc=$rc: $(tr '\n' ' ' < "$W/break.out")"
ok "env unset that breaks the app exits non-zero" test "$rc" != 0
# (the new env is tried on the pre-flight port first and refused; the put-back is the second net)
ok "and says nothing was changed (refused in pre-flight, or the previous env put back)" \
  grep -q 'does not start with the new env.*nothing was changed\|previous env was put back' "$W/break.out"
ok "NEED is in the env again" srv "sudo grep -q '^NEED=' /opt/tando/apps/$A/env"
ok "the app serves v3 again" serves $A 3
(cd "$W/$A" && "$R" env set OTHER=x > "$W/ok.out" 2>&1); rc=$?
ok "a harmless env set afterwards works (rc=$rc)" sh -c "[ $rc = 0 ] && grep -q restarted '$W/ok.out'"
ok "no 'waiting for' line when nothing else holds the app" sh -c "! grep -q 'waiting for' '$W/ok.out' '$W/same.out' '$W/break.out'"
truth $A 3
next_deploy $A 4
f_end
