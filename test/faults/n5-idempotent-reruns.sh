#!/bin/bash
# n5: every mutating command run again with nothing to change, and re-runs after an interruption.
# Expect: the same state, exit 0 (or a clear "already"), no rewritten file, no restart of the app
# and no reload of Caddy when nothing changed; an interrupted first `up` and an interrupted
# destroy are finished by running them again.
. "$(dirname "$0")/lib-fault.sh"
f_init n5 "re-runs: setup, deploy, env, domain, stop/start, destroy, up" "idempotency"
# the long soak, for f_fresh too: "deploy of an unchanged tree" below is "already live" only when
# its settings (the soak among them) are those of the live release, so f_fresh must deploy with
# the soak the scenario's own deploy sends (seen failing with FAULT_SETUP_SOAK=2)
FAULT_SETUP_SOAK=${TANDO_SOAK:-}
A=fn5; f_fresh $A
snap() { srv "sudo bash -s" <<'SH'
for f in /etc/caddy/Caddyfile /etc/caddy/tando/* /etc/systemd/system/tando* /opt/tando/host.conf /opt/tando/firewall.nft \
  /opt/tando/apps/*/app.conf /opt/tando/apps/*/env /etc/fstab /etc/tmpfiles.d/tando*; do
  [ -f "$f" ] && echo "$(md5sum < "$f" | cut -c1-8) $(stat -c %Y "$f") $f"
done
echo "caddy $(systemctl show -P MainPID caddy) $(journalctl -u caddy -o cat --no-pager | grep -c 'load complete\|config is unchanged')"
for u in $(systemctl list-units --plain --no-legend 'tando-fn5*.service' | awk '{print $1}'); do echo "$u $(systemctl show -P MainPID $u)"; done
echo "releases $(ls /opt/tando/apps/fn5/releases | tr '\n' ' ')"
# (the rules only: the client-limit sets and counters change with every request)
echo "nft $(nft list chain inet tando output | md5sum | cut -c1-8)"
SH
}
# (domain_tls=internal: the domain below gets Caddy's local CA, nothing asks a real ACME server)
"$R" host setup test public_port="$HP" domain_tls=internal > /dev/null 2>&1
s0=$(snap)
"$R" host setup test public_port="$HP" domain_tls=internal > "$W/setup2.out" 2>&1; rc=$?
ok "host setup again: rc 0 ($rc)" test $rc = 0
ok "host setup again changes no file, reloads nothing" test "$s0" = "$(snap)"
[ "$s0" = "$(snap)" ] || diff <(echo "$s0") <(snap) >&2
(cd "$W/$A" && "$R" deploy > "$W/same.out" 2>&1); rc=$?
ok "deploy of an unchanged tree: rc 0, says it is already live" sh -c "[ $rc = 0 ] && grep -q 'already live' '$W/same.out'"
ok "and makes no release and restarts nothing" test "$s0" = "$(snap)"
(cd "$W/$A" && "$R" env set K=v > /dev/null 2>&1); s1=$(snap)
(cd "$W/$A" && "$R" env set K=v > "$W/env2.out" 2>&1); rc=$?
ok "env set of the same value: rc 0, no restart" sh -c "[ $rc = 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$s1" "$(snap)"
(cd "$W/$A" && "$R" domain add n5.race.test --force --www off > /dev/null 2>&1); s1=$(snap)
(cd "$W/$A" && "$R" domain add n5.race.test --force --www off > "$W/dom2.out" 2>&1); rc=$?
s2=$(snap); [ "$s1" = "$s2" ] || diff <(echo "$s1") <(echo "$s2") >&2
ok "domain add of the same domain again: rc 0, Caddy not reloaded" sh -c "[ $rc = 0 ] && [ \"\$1\" = \"\$2\" ]" _ "$s1" "$s2"
(cd "$W/$A" && "$R" domain rm n5.race.test > /dev/null 2>&1)
for c in stop stop start start; do (cd "$W/$A" && "$R" $c > "$W/$c.out" 2>&1) || ok "$c rc 0" false; done
ok "stop twice says already stopped; start twice says already running" \
  sh -c "grep -q 'already stopped' '$W/stop.out' && grep -q 'already running' '$W/start.out'"
ok "serves v2 after stop/start" serves $A 2
# an interrupted first up: the user exists, the directory has only the marker
srv "sudo bash -c 'useradd --system --user-group --no-create-home -s /usr/sbin/nologin tando-fn5x && install -d /opt/tando/apps/fn5x && touch /opt/tando/apps/fn5x/.creating'"
f_app fn5x; deploy fn5x 1 ok up
ok "up after an interrupted first up works (rc=$DRC)" sh -c "[ $DRC = 0 ] && [ \"\$(curl -s -m 5 $(url fn5x))\" = v1 ]"
echo fn5x | (cd "$W" && "$R" destroy -a fn5x --purge > "$W/destroy1.out" 2>&1); rc=$?
ok "destroy works (rc=$rc)" test $rc = 0
echo fn5x | (cd "$W" && "$R" destroy -a fn5x --purge > "$W/destroy2.out" 2>&1); rc=$?
log "destroy again: rc=$rc: $(tr '\n' ' ' < "$W/destroy2.out")"
ok "destroy again says there is no such app" grep -q 'no app "fn5x"\|no such app' "$W/destroy2.out"
ok "no user, group or directory is left" srv "! id tando-fn5x 2> /dev/null && ! getent group tando-m-fn5x && ! test -e /opt/tando/apps/fn5x"
ok "the retired uid is listed once" srv "[ \$(sort /opt/tando/retired-uids | uniq -d | wc -l) = 0 ]"
# an incomplete directory (no app.conf, no marker): destroy removes it
srv "sudo install -d /opt/tando/apps/fn5y/releases"
echo fn5y | (cd "$W" && "$R" destroy -a fn5y --purge > "$W/destroy3.out" 2>&1); rc=$?
ok "destroy of an incomplete app directory removes it (rc=$rc)" sh -c "[ $rc = 0 ] && ! $SSH test -e /opt/tando/apps/fn5y"
f_app fn5x; deploy fn5x 2 ok up
ok "up with the destroyed name works again (rc=$DRC)" sh -c "[ $DRC = 0 ] && [ \"\$(curl -s -m 5 $(url fn5x))\" = v2 ]"
echo fn5x | (cd "$W" && "$R" destroy -a fn5x --purge > /dev/null 2>&1)
truth $A 2
next_deploy $A 3
f_end
