#!/bin/bash
# d4: Caddy is killed (SIGKILL) while a good release is being verified. systemd restarts it?
# Expect: the deploy ends truthfully (live and verified, or rolled back) and the app serves after.
. "$(dirname "$0")/lib-fault.sh"
f_init d4 "Caddy SIGKILL" "verify"
A=fd4; f_fresh $A "health_timeout = 20"
loop_start $A
setv $A 3 slow@live:3; client_bg $A deploy
wait_phase $A verify 60
srv "sudo systemctl kill -s KILL caddy"
client_wait 120; log "deploy rc=$(client_rc): $(grep -E 'live in|rolled|message|answer' "$W/client.out" | head -2 | tr '\n' ' ')"
sleep 5
caddy=$(srv "systemctl is-active caddy"); log "caddy after SIGKILL: $caddy"
ok "Caddy is running again by itself" test "$caddy" = active
loop_stop
v=$(ver $A); ok "app serves (v$v)" test -n "$v"
truth $A "${v:-3}"
srv "sudo systemctl start caddy"
next_deploy $A 4
f_end
