#!/bin/bash
# f1: the host's port range is exhausted when a new app is created. Expect: a clear error and
# nothing half-created (no user, no directory, no unit), and `tando up` works once ports are free.
. "$(dirname "$0")/lib-fault.sh"
f_init f1 "port range exhausted" "tando up (new app)"
A=ff1; f_fresh $A
p=$(app_port $A)
srv "sudo cp -p /opt/tando/host.conf /root/host.conf.f1 && sudo sed -i 's/^port_min=.*/port_min=$p/; s/^port_max=.*/port_max=$p/' /opt/tando/host.conf"
B=ff1new; srv "sudo test -d /opt/tando/apps/$B" && { echo $B | "$R" destroy -a $B --purge > /dev/null 2>&1; }
f_app $B
deploy $B 1 ok up; log "up rc=$DRC: $(grep -E 'tando-agent' "$W/$B.d1.out" | head -1)"
ok "up fails" test "$DRC" != 0
ok "error names the port range" grep -q 'no free port' "$W/$B.d1.out"
left=$(srv "sudo bash -c 'ls -d /opt/tando/apps/$B 2>/dev/null; id tando-$B 2>/dev/null; ls /etc/systemd/system/tando-$B* /etc/caddy/tando/$B.caddy 2>/dev/null'")
ok "nothing half-created: [$left]" test -z "$left"
srv "sudo mv /root/host.conf.f1 /opt/tando/host.conf"
deploy $B 1 ok up; ok "tando up works once ports are free" serves $B 1
[ "$DRC" = 0 ] || { F_RECOVER=n; tail -3 "$W/$B.d1.out" >&2; }
echo $B | "$R" destroy -a $B --purge > /dev/null 2>&1
f_end
