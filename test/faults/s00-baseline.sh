#!/bin/bash
# s00: no fault. A normal deploy under load: harness check.
. "$(dirname "$0")/lib-fault.sh"
f_init s00 "none (baseline)" "normal deploy"
A=f00; f_fresh $A
loop_start $A
deploy $A 3 ok; ok "deploy v3 succeeds" test $DRC = 0
loop_stop
ok "no failed request" test "$F_BAD" = 0
truth $A 3
next_deploy $A 4
f_end
