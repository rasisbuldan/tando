#!/bin/bash
# g9: releases/ was emptied by hand (rm -rf releases/*). Expect: doctor notices; next deploy works
# and a failing deploy after that rolls back correctly.
. "$(dirname "$0")/lib-fault.sh"
f_init g9 "releases dir emptied" "deploy"
A=fg9; f_fresh $A
srv "sudo bash -c 'rm -rf /opt/tando/apps/$A/releases/*'"
"$R" doctor > "$W/doc.out" 2>&1
grep -q "app $A" "$W/doc.out" || untruth "doctor says nothing while every release is gone"
"$R" releases -a $A > "$W/rel.out" 2>&1; cat "$W/rel.out" >&2
loop_start $A
deploy $A 3 ok; ok "deploy works" test $DRC = 0
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
truth $A 3
next_deploy $A 4
f_end
