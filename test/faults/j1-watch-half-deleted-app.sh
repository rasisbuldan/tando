#!/bin/bash
# j1: an app directory is half-deleted (an interrupted destroy, or rm by hand): app.conf left but no
# state/releases, and another with no app.conf at all. Expect: tando-watch's timer run, tando ls,
# status and doctor keep working for the other apps and say something sensible about the broken one.
. "$(dirname "$0")/lib-fault.sh"
f_init j1 "app dir half-deleted" "tando-watch timer, ls, doctor"
A=fj1; f_fresh $A
B=fj1b; f_fresh $B
srv "sudo bash -c 'rm -rf /opt/tando/apps/$A/state /opt/tando/apps/$A/releases /opt/tando/apps/$A/current; rm -f /opt/tando/apps/$B/app.conf'"
srv "sudo systemctl start tando-watch.service; systemctl show -P Result,ExecMainStatus tando-watch.service" > "$W/watch.out" 2>&1
log "tando-watch run: $(tr '\n' ' ' < "$W/watch.out")"
ok "tando-watch run succeeds" grep -q '^success' "$W/watch.out"
srv "sudo journalctl -u tando-watch.service -n 5 --no-pager -o cat" >&2
"$R" ls > "$W/ls.out" 2>&1; ok "tando ls works" test $? = 0
"$R" doctor > "$W/doc.out" 2>&1; ok "tando doctor works" test $? -le 1
grep -E "$A|$B" "$W/ls.out" "$W/doc.out" >&2
grep -q "app $A" "$W/doc.out" || untruth "doctor says nothing about $A (no state, no releases)"
"$R" status -a $A > "$W/st.out" 2>&1; log "status $A rc=$?: $(grep -iE 'tando|error|unbound' "$W/st.out" | head -2)"
# a deploy of the half-deleted app
deploy $A 3 ok; log "deploy of $A rc=$DRC: $(grep -iE 'tando-agent|live in|failed' "$W/$A.d3.out" | head -1)"
ok "deploy of the half-deleted app works or says what to do" sh -c "[ $DRC = 0 ] || grep -qiE 'tando destroy|tando up' '$W/$A.d3.out'"
srv "sudo rm -rf /opt/tando/apps/$B"
echo $A | "$R" destroy -a $A --purge > /dev/null 2>&1
f_end
