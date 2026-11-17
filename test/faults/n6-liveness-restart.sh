#!/bin/bash
# n6: the app's process stops answering while its unit stays active (here: SIGSTOP; in the load
# test, Next at its memory cap thrashing in GC). systemd sees nothing wrong. Expect: after
# `liveness` (3) failed health checks in a row tando-watch restarts it, says so in its history
# ("restarted by tando-watch"), and the app serves again without anyone touching it.
. "$(dirname "$0")/lib-fault.sh"
f_init n6 "app hangs while its unit runs" "tando-watch liveness"
A=fn6; f_fresh $A
log "waiting out tando-watch's deploy grace (120 s)"; sleep 125
pid=$(srv "systemctl show -P MainPID tando-$A")
srv "sudo kill -STOP $pid"
ok "the app no longer answers" sh -c "! curl -s -m 3 $(url $A) > /dev/null"
# (runs seconds apart stand for minutes: every run counts, not once a minute)
printf 'sample_seconds=0\n' | srv 'sudo /opt/tando/bin/tando-watch set' > /dev/null
for _ in 1 2 3 4; do srv "sudo /opt/tando/bin/tando-watch run" > /dev/null 2>&1; sleep 2; done
printf 'sample_seconds=\n' | srv 'sudo /opt/tando/bin/tando-watch set' > /dev/null
ok "it serves again by itself (restarted)" until_ 60 serves $A 2
ok "with a new process" test "$(srv "systemctl show -P MainPID tando-$A")" != "$pid"
ok "tando-watch says it restarted it" srv "sudo grep -q 'restart.$A.health.*restarted by tando-watch' /var/lib/tando/watch/history.tsv"
truth $A 2
next_deploy $A 3
f_end
