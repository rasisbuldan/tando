#!/bin/bash
# g6: the `current` symlink was deleted. Expect: status/doctor notice; after a reboot the app still
# serves (recover repairs the link from state) or the next deploy repairs it.
. "$(dirname "$0")/lib-fault.sh"
f_init g6 "current symlink deleted" "doctor + reboot"
A=fg6; f_fresh $A
srv "sudo rm /opt/tando/apps/$A/current"
"$R" doctor > "$W/doc.out" 2>&1; "$R" status -a $A > "$W/st.out" 2>&1
grep -q "app $A" "$W/doc.out" || untruth "doctor says nothing while current is missing"
docker_restart
until_ 30 serves $A 2; ok "after a reboot v2 serves again" test $? = 0
log "unit after reboot: $(srv "systemctl is-active tando-$A")"
truth $A 2
next_deploy $A 4
f_end
