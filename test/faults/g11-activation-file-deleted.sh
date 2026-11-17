#!/bin/bash
# g11: the activation progress file and the lease file hold garbage. Expect: deploy works.
. "$(dirname "$0")/lib-fault.sh"
f_init g11 "activation + upload lease files corrupted" "deploy"
A=fg11; f_fresh $A
srv "sudo bash -c 'head -c 300 /dev/urandom > /opt/tando/apps/$A/activation; printf \"token=\\nwho=x\\nstarted=abc\\n\" > /opt/tando/apps/$A/upload'"
"$R" status -a $A > "$W/st.out" 2>&1 || untruth "tando status fails with a corrupted activation file"
loop_start $A
deploy $A 3 ok; ok "deploy works" test $DRC = 0; tail -3 "$W/$A.d3.out" >&2
loop_stop
truth $A 3
next_deploy $A 4
f_end
