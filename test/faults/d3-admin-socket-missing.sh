#!/bin/bash
# d3: Caddy's admin socket is gone (deleted /run/caddy/admin.sock; Caddy keeps serving), so every
# reload fails. Then: tando stop, start, a crash loop (tando-down@), and a deploy.
. "$(dirname "$0")/lib-fault.sh"
f_init d3 "Caddy admin socket missing (reload fails)" "stop / start / deploy"
A=fd3; f_fresh $A
srv "sudo rm -f /run/caddy/admin.sock"
(cd "$W/$A" && "$R" stop > "$W/stop.out" 2>&1); src=$?
st=$(srv "sudo sed -n 's/^stopped=//p' /opt/tando/apps/$A/state")
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$(url $A)")
log "stop rc=$src, state stopped=[$st], Caddy answers $code: $(tail -1 "$W/stop.out")"
if [ "$st" = 1 ] && [ "$code" = 200 ]; then untruth "state says stopped but Caddy still serves the app"; fi
if [ "$src" = 0 ] && [ "$code" = 200 ]; then untruth "tando stop reported success but the app still serves"; fi
(cd "$W/$A" && "$R" start > "$W/start.out" 2>&1); log "start rc=$?"
loop_start $A
deploy $A 3 ok; log "deploy rc=$DRC"; ok "deploy works without a reload" test $DRC = 0
loop_stop; ok "no failed request" test "$F_BAD" = 0
"$R" doctor > "$W/doctor1.out" 2>&1
grep -qi "admin" "$W/doctor1.out" && log "doctor: $(grep -i admin "$W/doctor1.out")"
srv "sudo systemctl restart caddy"; sleep 2
truth $A 3
next_deploy $A 4
f_end
