#!/bin/bash
# j3: 50 apps on one 2 GB / 1 CPU host (45 static sites + 5 node apps). Expect: tando-watch's run,
# tando ls, status, doctor stay fast; a deploy under that load drops no request.
. "$(dirname "$0")/lib-fault.sh"
f_init j3 "50 apps" "timers, views, deploy"
for i in $(seq -w 1 45); do
  s=fs$i; mkdir -p "$W/$s"; echo "<h1>$i</h1>" > "$W/$s/index.html"; printf 'app = %s\nrecipe = static\n' $s > "$W/$s/tando.conf"
  (cd "$W/$s" && "$R" up > /dev/null 2>&1) || log "up $s failed"
done
for i in 1 2 3 4; do f_fresh fn$i; done
A=fj3; f_fresh $A
s=$(date +%s); srv "sudo systemctl start tando-watch.service"; log "tando-watch run: $(( $(date +%s) - s ))s"
s=$(date +%s); "$R" ls > "$W/ls.out" 2>&1; t1=$(( $(date +%s) - s ))
s=$(date +%s); "$R" doctor > "$W/doc.out" 2>&1; t2=$(( $(date +%s) - s ))
s=$(date +%s); "$R" status -a $A > "$W/st.out" 2>&1; t3=$(( $(date +%s) - s ))
log "ls ${t1}s, doctor ${t2}s, status ${t3}s; apps listed: $(grep -c '^│ f' "$W/ls.out")"
ok "ls, doctor, status each under 10 s" test $t1 -lt 10 -a $t2 -lt 10 -a $t3 -lt 10
loop_start $A
deploy $A 3 ok; ok "deploy works" test $DRC = 0
loop_stop; ok "no failed request ($F_BAD)" test "$F_BAD" = 0
srv "free -m | head -2; uptime" >&2
truth $A 3
for i in $(seq -w 1 45); do echo fs$i | "$R" destroy -a fs$i --purge > /dev/null 2>&1; done
for i in 1 2 3 4; do echo fn$i | "$R" destroy -a fn$i --purge > /dev/null 2>&1; done
f_end
