#!/bin/bash
# m1: the release crashes during the soak, after the client has returned ("live"). Expect: the
# server rolls back, and tando-watch sends exactly one alert naming the app, the release and why.
. "$(dirname "$0")/lib-fault.sh"
f_init m1 "app crashes in the soak, client gone" "soak (alert)"
A=fm1; f_fresh $A "soak = 25"
# a webhook receiver in the container (root, 127.0.0.1:9998): one line per request body
srv 'sudo tee /root/m1-recv.js' > /dev/null <<'JS'
require('http').createServer((q, s) => {
  let b = ''; q.on('data', (d) => b += d);
  q.on('end', () => { require('fs').appendFileSync('/root/recv.log', b.replace(/\n/g, ' ') + '\n'); s.end('ok'); });
}).listen(9998, '127.0.0.1');
JS
srv "sudo systemctl stop fault-recv 2> /dev/null; sudo rm -f /root/recv.log; sudo systemd-run --quiet --unit=fault-recv node /root/m1-recv.js"
sleep 1
printf 'http://127.0.0.1:9998/m1hook\n' | (cd "$W/$A" && "$R" alerts notifier add m1hook webhook) > "$W/notifier.out" 2>&1
ok "webhook notifier added" grep -q 'added notifier' "$W/notifier.out"
srv "sudo systemctl start tando-watch.service" 2> /dev/null   # an earlier backlog goes out now
n0=$(srv "sudo cat /root/recv.log 2> /dev/null | grep -c 'ROLLED BACK $A'")
# v3 crashes 20 s after it starts; the deploy returns once it is live (no --wait)
TANDO_WAIT="" deploy $A 3 crash20@live
id=$(rid "$W/$A.d3.out")
log "deploy rc=$DRC release $id: $(grep -E 'live in|rolled|in the background' "$W/$A.d3.out" | head -2 | tr '\n' ' ')"
ok "the deploy returned live before the soak ended" sh -c "[ $DRC = 0 ] && grep -q 'live in' '$W/$A.d3.out'"
ok "the server rolled back to v2" until_ 60 serves $A 2
alerted() { [ "$(srv "sudo cat /root/recv.log 2> /dev/null | grep -c 'ROLLED BACK $A'")" -gt "$n0" ]; }
ok "an alert arrived within 90 s of the rollback" until_ 90 alerted
srv "sudo cat /root/recv.log" > "$W/recv.log" 2> /dev/null
line=$(grep "ROLLED BACK $A" "$W/recv.log" | tail -1)
log "alert: $(printf '%s' "$line" | cut -c1-400)"
has() { printf '%s' "$line" | grep -q "$1"; }
ok "the alert names the app, the release ($id) and the reason" \
  has "ROLLED BACK $A: release $id rolled back to [0-9-]*: it exited with status 1, [0-9]* s after going live"
ok "the alert's title says rolled back" has '"title":"tando [^"]*: 1 rolled back"'
ok "the alert's events carry state rollback" has "\"state\":\"rollback\",\"app\":\"$A\""
# the reason is in the history the agent keeps (tando history NOTE; the hist row's note field)
srv "sudo /opt/tando/bin/tando-agent history $A 5" > "$W/hist.rows" 2> /dev/null
ok "the history note of $id says why it was rolled back" \
  sh -c "awk -F '\t' '\$4 == \"$id\" && \$6 == \"rolledback\"' '$W/hist.rows' | grep -q 'it exited with status 1, [0-9]* s after going live'"
(cd "$W/$A" && "$R" history --json > "$W/history.out" 2>&1)
ok "tando history --json carries it" grep -q 'exited with status 1' "$W/history.out"
# once: more runs of the watcher send nothing more about it
srv "sudo systemctl start tando-watch.service; sudo systemctl start tando-watch.service" 2> /dev/null
n1=$(srv "sudo cat /root/recv.log | grep -c 'ROLLED BACK $A'")
ok "exactly one alert for the rollback ($((n1 - n0)))" test $((n1 - n0)) = 1
ok "the notice spool is empty" sh -c "[ -z \"\$($SSH 'sudo ls -A /var/lib/tando/watch/inbox')\" ]"
ok "the rollback is in the alert history" sh -c "$SSH 'sudo grep -q \"rollback.$A.deploy.release $id\" /var/lib/tando/watch/history.tsv'"
# a deploy that fails in its own verify (the client sees it) sends no rollback alert
TANDO_WAIT="" deploy $A 5 exit@live
srv "sudo systemctl start tando-watch.service" 2> /dev/null
n2=$(srv "sudo cat /root/recv.log | grep -c 'ROLLED BACK $A'")
ok "a failed deploy the client reported sends no rollback alert (rc=$DRC)" sh -c "[ $DRC != 0 ] && [ $n2 = $n1 ]"
(cd "$W/$A" && "$R" alerts notifier rm m1hook > /dev/null 2>&1)
srv "sudo systemctl stop fault-recv" 2> /dev/null
truth $A 2
next_deploy $A 4
f_end
