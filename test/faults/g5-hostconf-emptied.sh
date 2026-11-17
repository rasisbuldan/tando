#!/bin/bash
# g5: host.conf is empty. Expect: deploy refuses clearly or works; doctor reports it.
. "$(dirname "$0")/lib-fault.sh"
f_init g5 "host.conf emptied" "deploy + doctor"
A=fg5; f_fresh $A
srv "sudo cp -p /opt/tando/host.conf /root/host.conf.g5 && sudo truncate -s 0 /opt/tando/host.conf"
loop_start $A
deploy $A 3 ok; log "deploy rc=$DRC: $(grep -E 'tando-agent|live in|rolled|failed' "$W/$A.d3.out" | head -2 | tr '\n' ' ')"
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
"$R" doctor > "$W/doc.out" 2>&1; grep host.conf "$W/doc.out" >&2
grep -q "host.conf" "$W/doc.out" || untruth "doctor does not report host.conf ($(grep -m1 unbound "$W/doc.out"))"
grep "host.conf" "$W/doc.out" | grep -q "● ok" && untruth "doctor says host.conf ok while it is empty"
v=$(ver $A); truth $A "$v"
srv "sudo mv /root/host.conf.g5 /opt/tando/host.conf"
next_deploy $A 4
f_end
