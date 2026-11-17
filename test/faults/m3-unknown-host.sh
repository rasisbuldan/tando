#!/bin/bash
# m3: requests for a host tando does not serve (a typo, a destroyed app). Caddy's stock site
# answers 200 "Caddy works!" for them; host setup replaces exactly that stock site with a 404
# "no app here", and leaves any other catch-all (an adopted server's own) alone. Run it on
# TANDO_TEST_CADDY=ubuntu (Caddy 2.6.2) too.
. "$(dirname "$0")/lib-fault.sh"
f_init m3 "request for an unknown or destroyed host" "Caddy fallback (host setup)"
code() { curl -s -o "$W/body" -w '%{http_code}' -m 5 "$(url "$1")"; }
srv 'sudo cp -p /etc/caddy/Caddyfile /root/Caddyfile.m3-orig'
# a server whose Caddyfile is still the package's (the stock "Caddy works!" site)
srv 'sudo tee /etc/caddy/Caddyfile > /dev/null && sudo systemctl restart caddy' < "$SC/caddyfile-stock"
srv 'sudo install -d /usr/share/caddy && [ -f /usr/share/caddy/index.html ] || echo "Caddy works!" | sudo tee /usr/share/caddy/index.html > /dev/null'
ok "before: the stock site answers 200 for an unknown host" test "$(code nosuch)" = 200
"$R" host setup test public_port="$HP" > "$W/setup1.out" 2>&1
ok "host setup succeeded" sh -c "grep -q '4/[0-9]* *config' '$W/setup1.out' && grep -q 'unknown hosts: 404' '$W/setup1.out'"
ok "an unknown host gets 404 no app here" sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -m 5 $(url nosuch))\" = 404 ] && curl -s -m 5 $(url nosuch) | grep -q 'no app here'"
"$R" host setup test public_port="$HP" > "$W/setup2.out" 2>&1
# (the step's detail may wrap onto the lines below it)
ok "a second host setup changes nothing" sh -c "grep -q 'config.*unchanged' '$W/setup2.out' && grep -q 'unknown hosts: 404' '$W/setup2.out'"
A=fm3; f_fresh $A
ok "the app still answers" serves $A 2
echo "$A" | (cd "$W/$A" && "$R" destroy -a $A --purge > "$W/destroy.out" 2>&1)
ok "after destroy its name gets 404 no app here" sh -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -m 5 $(url $A))\" = 404 ] && curl -s -m 5 $(url $A) | grep -q 'no app here'"
ok "the tando import and admin socket are in place" srv "grep -q '^import /etc/caddy/tando/' /etc/caddy/Caddyfile && grep -q 'admin unix//run/caddy/admin.sock' /etc/caddy/Caddyfile"
# an adopted server's own catch-all is not tando's: kept
srv 'sudo tee /etc/caddy/Caddyfile > /dev/null && sudo systemctl restart caddy' <<'CF'
{
	admin unix//run/caddy/admin.sock
}
:80 {
	respond "their own catch-all" 200
}
import /etc/caddy/tando/*.caddy
CF
"$R" host setup test public_port="$HP" > "$W/setup3.out" 2>&1
ok "a non-stock :80 site is kept" sh -c "grep -q 'config.*unknown hosts: kept (yours)' '$W/setup3.out' && curl -s -m 5 $(url nosuch) | grep -q 'their own catch-all'"
srv 'sudo cp -p /root/Caddyfile.m3-orig /etc/caddy/Caddyfile && sudo systemctl restart caddy'
F_TRUTH=y
f_end
