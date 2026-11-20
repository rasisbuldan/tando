#!/bin/bash
# g10: the clock jumped backwards (here: the existing releases carry ids from the future, which is
# what a clock that was ahead and got corrected leaves). Expect: deploy, rollback and prune still
# pick the right releases (by deploy order, not by name); the same for backups: pre-deploy backups
# named from the future (taken while the clock was ahead) never push the new ones out.
. "$(dirname "$0")/lib-fault.sh"
f_init g10 "clock jump backwards (release ids in the future)" "deploy + rollback + prune"
A=fg10; f_fresh $A "data = data"
srv "sudo bash -s $A" <<'SH'
A=$1 D=/opt/tando/apps/$1
systemctl stop tando-$A
for r in $(ls $D/releases); do n=2099${r:4}; mv $D/releases/$r $D/releases/$n; sed -i "s/$r/$n/g" $D/state $D/history.tsv; done
c=$(sed -n 's/^current=//p' $D/state); ln -sfn releases/$c $D/current.tmp && mv -T $D/current.tmp $D/current
systemctl start tando-$A
SH
sleep 2
loop_start $A
deploy $A 3 ok; ok "deploy v3 works" test $DRC = 0
(cd "$W/$A" && "$R" rollback > "$W/rb.out" 2>&1); rrc=$?
log "rollback rc=$rrc: $(tail -3 "$W/rb.out" | tr '\n' ' ')"
ok "rollback goes back to the previous deploy (v2)" sh -c "[ $rrc = 0 ] && [ \"\$(curl -s -m 3 $(url $A))\" = v2 ]"
# (six releases only to have more than are kept: which ones prune and rollback pick depends on the
# order of the deploys, not on how long each soaked: the setup soak)
# five pre-deploy backups from the future, as a clock that was ahead left them (meta of an agent
# before backups had a seq)
srv "sudo bash -s $A" <<'SH'
B=/var/backups/tando/$1
for n in 1 2 3 4 5; do d=$B/2099010$n-000000-predeploy; mkdir -p $d; printf 'kind=predeploy\ncreated=4070908800\n' > $d/meta; done
SH
for v in 4 5 6 7 8 9; do setup_deploy $A $v ok > /dev/null; done
real_pre() { srv "sudo ls /var/backups/tando/$A" | grep -- '-predeploy$' | grep -vc '^2099'; }
ok "the 5 newest real pre-deploy backups are kept, not the 5 named from the future ($(real_pre) kept)" test "$(real_pre)" = 5
ok "after 6 more deploys v9 serves" serves $A 9
(cd "$W/$A" && "$R" rollback > "$W/rb2.out" 2>&1); rrc=$?
log "rollback 2 rc=$rrc: $(tail -3 "$W/rb2.out" | tr '\n' ' ')"
ok "rollback from v9 goes to v8" serves $A 8
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
truth $A "$(ver $A)"
next_deploy $A 10
f_end
