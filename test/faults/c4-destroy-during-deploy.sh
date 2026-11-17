#!/bin/bash
# c4: destroy while a deploy is in pre-flight. Expect: destroy waits or refuses; afterwards no unit,
# site, transient unit, user or directory is left; the deploying client ends with a clear message;
# `tando up` recreates the app.
. "$(dirname "$0")/lib-fault.sh"
f_init c4 "destroy during deploy" "preflight"
A=fc4; f_fresh $A
setv $A 3 slow@pre:8; client_bg $A deploy
wait_phase $A preflight 60
echo $A | (cd "$W/$A" && "$R" destroy --purge > "$W/destroy.out" 2>&1); drc=$?
log "destroy rc=$drc: $(tail -2 "$W/destroy.out" | tr '\n' ' ')"
client_wait 150; ok "deploying client ends within 150 s" test $? = 0
log "client: $(tail -3 "$W/client.out" | tr '\n' ' ')"
left=$(srv "sudo bash -c 'ls -d /opt/tando/apps/$A /etc/caddy/tando/$A.caddy /etc/systemd/system/tando-$A* 2>/dev/null; id tando-$A 2>/dev/null; systemctl list-units --all --plain --no-legend \"tando-$A*\" | grep -v not-found'")
[ $drc = 0 ] && ok "nothing left after destroy: [$left]" test -z "$left"
case $(curl -s -o /dev/null -w '%{http_code}' -m 5 "$(url $A)") in 200) [ $drc = 0 ] && ok "destroyed app no longer served" false;; esac
rm -f "$W/$A/VERSION"; f_app $A
if deploy $A 7 ok up && serves $A 7; then echo "  ok   tando up recreates it" >&2; else F_RECOVER=n; F_NOTES="$F_NOTES; tando up after destroy failed"; tail -5 "$W/$A.d7.out" >&2; fi
f_end
