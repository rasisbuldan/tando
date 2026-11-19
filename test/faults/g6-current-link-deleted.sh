#!/bin/bash
# g6: the `current` symlink was deleted. Expect: status/doctor notice; after a reboot the app still
# serves (recover repairs the link from state) or the next deploy repairs it.
. "$(dirname "$0")/lib-fault.sh"
f_init g6 "current symlink deleted" "doctor + reboot"
A=fg6; f_fresh $A
# The monitor repairs a lost link by itself within a minute (tando-watch runs recover-all when a
# link disagrees with the state). Doctor's answer counts only when the link was still gone after
# doctor ran; when the repair came first, the step is done again (seen once in two full runs:
# doctor then rightly said nothing, and the scenario called that a lie).
gone=n
for try in 1 2 3 4; do
  srv "sudo rm -f /opt/tando/apps/$A/current"
  "$R" doctor > "$W/doc.out" 2>&1; "$R" status -a $A > "$W/st.out" 2>&1
  if srv "sudo test ! -e /opt/tando/apps/$A/current -a ! -L /opt/tando/apps/$A/current"; then gone=y; break; fi
  log "the monitor repaired the link while doctor ran (try $try): again"
done
ok "the link was still missing when doctor had answered (within 4 tries)" test $gone = y
[ $gone = n ] || grep -q "app $A" "$W/doc.out" || untruth "doctor says nothing while current is missing"
docker_restart
until_ 30 serves $A 2; ok "after a reboot v2 serves again" test $? = 0
log "unit after reboot: $(srv "systemctl is-active tando-$A")"
truth $A 2
next_deploy $A 4
f_end
