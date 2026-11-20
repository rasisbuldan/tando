#!/bin/bash
# n1: a deploy adds a scheduled job, and its release fails; then a good release; then a rollback.
# Expect: jobs take effect only with a verified release and go back with it: no timer after the
# failed release, the timer after the good one, none again after rolling back to a release
# without it; the job units are not rewritten (and systemd not reloaded) when nothing changed.
. "$(dirname "$0")/lib-fault.sh"
f_init n1 "jobs of a failed release, rollback" "deploy, rollback"
A=fn1; f_fresh $A
timer() { srv "test -f /etc/systemd/system/tando-${A}_job-tick.timer && systemctl -q is-active tando-${A}_job-tick.timer"; }
notimer() { ! timer; }
echo 'job.tick = hourly | echo tick' >> "$W/$A/tando.conf"
deploy $A 3 exit
ok "the release with the job fails (rc=$DRC)" test "$DRC" != 0
ok "no job timer after the failed release" notimer
deploy $A 4 ok
ok "the next release (verified) has the job timer" timer
m0=$(srv "stat -c %Y /etc/systemd/system/tando-${A}_job-tick.service /etc/systemd/system/tando-${A}_job-tick.timer")
sleep 1.1; deploy $A 5 ok
ok "a deploy with the same job does not rewrite its units" test "$m0" = "$(srv "stat -c %Y /etc/systemd/system/tando-${A}_job-tick.service /etc/systemd/system/tando-${A}_job-tick.timer")"
rel2=$(srv "sudo awk -F'\t' '\$3 == \"deploy\" && \$4 == \"ok\" { print \$2 }' /opt/tando/apps/$A/history.tsv" | sed -n 2p)
(cd "$W/$A" && "$R" rollback "$rel2" > "$W/rb.out" 2>&1); rc=$?
ok "rollback to v2 (before the job) works (rc=$rc)" sh -c "[ $rc = 0 ] && [ \"\$(curl -s -m 5 $(url $A))\" = v2 ]"
ok "the job timer went back with the release" notimer
truth $A 2
next_deploy $A 6
ok "and comes back with the next verified release" timer
f_end
