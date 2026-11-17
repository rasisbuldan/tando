#!/bin/bash
# g7: the current release directory was deleted by hand (freeing disk). Expect: doctor notices;
# a restart or reboot does not leave the app down without a word; the next deploy works.
. "$(dirname "$0")/lib-fault.sh"
f_init g7 "current release dir deleted" "doctor + restart"
A=fg7; f_fresh $A
cur=$(srv "sudo sed -n 's/^current=//p' /opt/tando/apps/$A/state")
srv "sudo rm -rf /opt/tando/apps/$A/releases/$cur"
"$R" doctor > "$W/doc.out" 2>&1
grep -q "app $A" "$W/doc.out" || untruth "doctor says nothing while the current release is missing"
(cd "$W/$A" && "$R" restart > "$W/rs.out" 2>&1); log "restart rc=$?: $(tail -1 "$W/rs.out")"
sleep 3; log "Caddy answers $(curl -s -o /dev/null -w '%{http_code}' -m 20 "$(url $A)") after restart; unit $(srv "systemctl is-active tando-$A")"
next_deploy $A 4
truth $A 4
f_end
