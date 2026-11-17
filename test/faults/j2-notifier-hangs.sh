#!/bin/bash
# j2: the webhook notifier's endpoint accepts connections and never answers. An alert fires.
# Expect: each tando-watch run stays bounded (well under its 1-minute period); runs do not pile up.
. "$(dirname "$0")/lib-fault.sh"
f_init j2 "notifier endpoint hangs" "tando-watch delivery"
A=fj2; f_fresh $A
srv "sudo systemd-run --quiet --unit=fault-blackhole node -e \"require('net').createServer(s=>{}).listen(9999,'127.0.0.1')\""
printf 'http://127.0.0.1:9999/hook\n' | "$R" alerts notifier add hang webhook > "$W/n.out" 2>&1; log "notifier add rc=$?: $(tail -1 "$W/n.out")"
(cd "$W/$A" && "$R" stop > /dev/null 2>&1)   # an app-down/stopped alert, and a test message
( time "$R" alerts test hang ) > "$W/test.out" 2>&1; log "alerts test: $(tr '\n' ' ' < "$W/test.out" | cut -c1-200)"
srv "sudo systemctl stop $A 2>/dev/null; sudo systemctl kill -s KILL tando-$A 2>/dev/null"
for i in 1 2 3; do
  s=$(date +%s); srv "sudo systemctl start tando-watch.service" ; d=$(( $(date +%s) - s ))
  log "tando-watch run $i took ${d}s"; [ $d -lt 50 ] || ok "watch run $i bounded (<50 s): ${d}s" false
done
ok "no stuck tando-watch processes" test "$(srv "pgrep -c -f 'tando-watch run'" )" -le 1
(cd "$W/$A" && "$R" start > /dev/null 2>&1)
"$R" alerts notifier rm hang > /dev/null 2>&1; srv "sudo systemctl stop fault-blackhole"
next_deploy $A 4
f_end
