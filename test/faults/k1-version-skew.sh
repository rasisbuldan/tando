#!/bin/bash
# k1: the server's agent differs from the client's (another laptop ran host setup with another
# version). Expect: deploy says so in one line and works; doctor warns.
. "$(dirname "$0")/lib-fault.sh"
f_init k1 "agent version differs from the client" "deploy + doctor"
A=fk1; f_fresh $A
srv "sudo bash -c 'echo 0.0.9 > /opt/tando/VERSION; echo \"# older build\" >> /opt/tando/bin/tando-agent'"
deploy $A 3 ok; ok "deploy works" test $DRC = 0
ok "deploy mentions the version difference" grep -q '0.0.9' "$W/$A.d3.out"
"$R" doctor > "$W/doc.out" 2>&1; ok "doctor warns about the agent" grep -q 'agent.*differs' "$W/doc.out"
truth $A 3
"$R" host setup test public_port="$HP" > /dev/null 2>&1
next_deploy $A 4
f_end
