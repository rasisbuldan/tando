#!/bin/bash
# d2: the main Caddyfile was broken by hand (Caddy still runs its old config). Then: deploy,
# tando stop, tando start, env set. Expect: each either works or fails cleanly, and state never
# claims what Caddy does not do (e.g. "stopped" while Caddy still serves the app).
. "$(dirname "$0")/lib-fault.sh"
f_init d2 "Caddyfile broken by hand" "deploy / stop / start / env"
A=fd2; f_fresh $A
srv "sudo cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.fault && echo 'this is { not valid' | sudo tee -a /etc/caddy/Caddyfile > /dev/null"
loop_start $A
deploy $A 3 ok; log "deploy rc=$DRC"
ok "deploy works (site unchanged, no reload needed)" test "$DRC" = 0
(cd "$W/$A" && "$R" stop > "$W/stop.out" 2>&1); src=$?
log "stop rc=$src: $(tail -2 "$W/stop.out" | tr '\n' ' ')"
st=$(srv "sudo sed -n 's/^stopped=//p' /opt/tando/apps/$A/state")
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$(url $A)")
"$R" status -a $A > "$W/st.out" 2>&1
log "after stop: state stopped=[$st], Caddy answers $code, unit $(srv "systemctl is-active tando-$A")"
if [ "$st" = 1 ] && [ "$code" = 200 ]; then untruth "state says stopped (status: $(grep -o 'stopped\|inactive\|running\|active' "$W/st.out" | head -1)) but Caddy still serves the app"; fi
ok "stop fails with a message naming Caddy" sh -c "[ $src != 0 ] && grep -qi caddy '$W/stop.out'"
(cd "$W/$A" && "$R" start > "$W/start.out" 2>&1); log "start rc=$?: $(tail -1 "$W/start.out")"
(cd "$W/$A" && "$R" env set X=1 > "$W/env.out" 2>&1); log "env set rc=$?: $(tail -1 "$W/env.out")"
loop_stop
srv "sudo mv /etc/caddy/Caddyfile.fault /etc/caddy/Caddyfile && sudo systemctl reload caddy"
truth $A 3
next_deploy $A 4
f_end
