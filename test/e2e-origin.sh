#!/bin/bash
# End-to-end test of origin mode (docs/COMMANDS.md, "Behind an edge"): a host behind a CDN or edge
# proxy trusts the client address the edge forwards only when the connection comes from the edge's
# ranges. The fake edge is a second container (its address is the "edge range"); the server's own
# address and the docker host are the non-edge visitors that spoof the headers.
#
#   test/e2e-origin.sh [--reset]
#
# Needs Caddy 2.7+ (the default test server); on Caddy 2.6 it only checks that origin mode refuses.
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT. About 4 minutes.
# Output: PASS/FAIL lines (docs/TESTING.md), summary, exit status. bash 3.2 compatible.
set -u
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init origin
W=$E/w
EDGE=$T_NAME-edge OTHER=$T_NAME-other
cleanup() { docker rm -f "$EDGE" "$OTHER" > /dev/null 2>&1; }
trap cleanup EXIT

if [ "${1:-}" = --reset ]; then t_server_up --reset || exit 1; else t_server_up || exit 1; fi
t_host_add test
"$R" host setup test public_port="$T_HTTP_PORT" rate_limit=on conn_limit=5 >&2 || exit 1
srv() { "$SSH" "$@"; }
cv=$(srv 'caddy version' 2> /dev/null | grep -o '[0-9][0-9]*\.[0-9][0-9]*' | head -1)
case $cv in 2.[0-6]|1.*|'') new=0;; *) new=1;; esac

if [ $new = 0 ]; then
  out=$("$R" host setup test origin=cloudflare 2>&1); rc=$?
  check "OR0 Caddy $cv: origin mode is refused, saying which Caddy it needs (rc=$rc)" eval '[ $rc != 0 ] && echo "$out" | grep -q "Caddy 2.7"'
  check "OR0b and nothing was written (host.conf has no origin)" eval '! srv "grep -q ^origin= /opt/tando/host.conf"'
  t_done
fi

# the app: answers with the addresses it was handed; /slow/N holds a connection N seconds
mkdir -p "$W/ori"
cat > "$W/ori/server.js" <<'EOF'
const http = require('http');
http.createServer((q, r) => {
  const m = q.url.match(/^\/slow\/(\d+)/);
  const done = () => r.end(JSON.stringify({ rip: q.headers['x-real-ip'] || '', xff: q.headers['x-forwarded-for'] || '', cf: q.headers['cf-connecting-ip'] || '', tci: q.headers['true-client-ip'] || '' }) + '\n');
  if (m) setTimeout(done, m[1] * 1000); else done();
}).listen(Number(process.env.PORT), '127.0.0.1');
EOF
printf 'app = ori\nrecipe = node\nstart = node server.js\nhealth = /\nmemory = 128M\n' > "$W/ori/tando.conf"
(cd "$W/ori" && "$R" up --yes > "$E/up.log" 2>&1); rc=$?
check "OR1 the app deploys" t_eq "$rc" 0

# the fake edge: another container on the same network (its address is the edge range)
IMG=$(docker inspect -f '{{.Config.Image}}' "$T_NAME")
docker rm -f "$EDGE" > /dev/null 2>&1
docker run -d --name "$EDGE" --label tando.test=1 --entrypoint sleep "$IMG" infinity > /dev/null
docker rm -f "$OTHER" > /dev/null 2>&1
docker run -d --name "$OTHER" --label tando.test=1 --entrypoint sleep "$IMG" infinity > /dev/null
A_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$T_NAME")
B_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$EDGE")
[ -n "$A_IP" ] && [ -n "$B_IP" ] || { echo "FAIL OR0 container addresses"; exit 1; }
echo "server $A_IP, edge $B_IP" >&2
# from the edge container, with extra headers: prints the app's answer
via_edge() { docker exec "$EDGE" curl -s --max-time 10 -H 'Host: ori.localhost' "$@" "http://$A_IP/"; }
# from the server to its own address (not the edge): the connection's address is the server's
via_self() { srv "curl -s --max-time 10 -H 'Host: ori.localhost' $* http://$A_IP/"; }
rip() { sed -n 's/.*"rip":"\([^"]*\)".*/\1/p'; }
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
# n concurrent 2 s requests from the edge container: how many got a 200
burst() { docker exec "$EDGE" sh -c "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do curl -s -o /dev/null -w '%{http_code}\n' --max-time 20 -H 'Host: ori.localhost' http://$A_IP/slow/2 & done; wait" | grep -c '^200$'; }

# ---- without origin mode: the edge's address is the visitor, and the per-client limit hits it ---
check "OR2 origin off: the app is handed the connecting address, the forwarded header is not believed" \
  eval '[ "$(via_edge -H "X-Forwarded-For: 203.0.113.7" -H "CF-Connecting-IP: 203.0.113.7" | rip)" = "$B_IP" ]'
got=$(burst)
check "OR3 origin off, conn_limit 5: 12 at once from one address are not all served (got $got)" eval '[ "$got" -lt 12 ]'

# ---- origin=custom: the edge is B's address ---------------------------------------------------
"$R" host setup test "origin=custom:$B_IP/32" >&2; rc=$?
check "OR4 host setup origin=custom:<range> succeeds" t_eq "$rc" 0
check "OR5 Caddy trusts only that range (global servers block)" eval '
  srv "sudo grep -E \"trusted_proxies static $B_IP/32\" /etc/caddy/Caddyfile" > /dev/null'
check "OR6 a forwarded address from the edge is the visitor (X-Real-IP, X-Forwarded-For header of an edge)" eval '
  [ "$(via_edge -H "X-Forwarded-For: 203.0.113.7" | rip)" = 203.0.113.7 ]'
check "OR7 custom edges are read from X-Forwarded-For only: CF-Connecting-IP is not believed" eval '
  [ "$(via_edge -H "CF-Connecting-IP: 203.0.113.8" | rip)" = "$B_IP" ]'
check "OR8 SPOOF: X-Forwarded-For from a non-edge address (the server itself) is ignored" eval '
  [ "$(via_self -H "\"X-Forwarded-For: 203.0.113.9\"" | rip)" = "$A_IP" ]'
check "OR9 SPOOF: CF-Connecting-IP and X-Real-IP from a non-edge address are ignored" eval '
  [ "$(via_self -H "\"CF-Connecting-IP: 203.0.113.9\"" -H "\"X-Real-IP: 203.0.113.10\"" | rip)" = "$A_IP" ]'
check "OR9b custom mode: CF-Connecting-IP and True-Client-IP never reach the app as the client sent them (from the edge or not)" eval '
  [ -z "$(via_self -H "\"CF-Connecting-IP: 203.0.113.9\"" -H "\"True-Client-IP: 203.0.113.9\"" | field cf)$(via_self -H "\"True-Client-IP: 203.0.113.9\"" | field tci)" ] &&
  [ -z "$(via_edge -H "CF-Connecting-IP: 203.0.113.9" -H "True-Client-IP: 203.0.113.9" | field cf)$(via_edge -H "True-Client-IP: 203.0.113.9" | field tci)" ]'
hostspoof=$(curl -s --max-time 10 -H 'X-Forwarded-For: 203.0.113.11' -H 'CF-Connecting-IP: 203.0.113.11' "$(t_url ori)" | rip)
check "OR10 SPOOF: from the docker host (also not the edge) the header is ignored (got $hostspoof)" eval '
  [ -n "$hostspoof" ] && [ "$hostspoof" != 203.0.113.11 ]'
logged() { srv "sudo grep -Ec 'client_ip.:.203[.]0[.]113[.]7.,' /var/log/tando/ori/access.log"; }
logged_ok() { [ "$(logged)" -gt 0 ]; }
check "OR11 the request log records the forwarded client address (client_ip) of the edge's request" eval 't_until 5 logged_ok'
got=$(burst)
check "OR12 origin on: the edge's address is exempt from the per-client limit, 12 of 12 served (got $got)" t_eq "$got" 12
check "OR13 the per-client rules keep their per-app and per-address limits (rl_conn counter and the edge exemption are both loaded)" eval '
  srv "sudo nft list table inet tando" | grep -q "set edge4" && srv "sudo nft list table inet tando" | grep -q "ip saddr @edge4 accept" &&
  srv "sudo nft list table inet tando" | grep -q "counter name \"rl_conn\""'
check "OR14 origin_lock is off by default: the host answers a non-edge address" eval '
  [ -n "$(curl -s --max-time 5 -H "Host: ori.localhost" "http://127.0.0.1:$T_HTTP_PORT/")" ]'

# ---- origin_lock -------------------------------------------------------------------------------
"$R" host setup test origin_lock=on >&2; rc=$?
check "OR15 host setup origin_lock=on succeeds" t_eq "$rc" 0
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 -H 'Host: ori.localhost' "http://127.0.0.1:$T_HTTP_PORT/")
check "OR16 origin_lock: ports 80/443 from a non-edge address (docker host) get no answer (got $code)" t_eq "$code" 000
ctr() { srv "sudo nft list counter inet tando origin_drop" | sed -n 's/.*packets \([0-9]*\).*/\1/p'; }
settled() { local a b; a=$(ctr); sleep 2; b=$(ctr); [ "$a" = "$b" ]; }   # (TCP retries of the check above still count)
t_until 40 settled
c0=$(ctr)
docker exec "$OTHER" bash -c "echo x > /dev/udp/$A_IP/443; echo x > /dev/udp/$A_IP/80" > /dev/null 2>&1
udp_dropped() { [ "$(ctr)" -ge $((c0 + 2)) ]; }
check "OR16b origin_lock also drops UDP 443 and 80 (HTTP/3) from a non-edge address (counter $c0 -> $(ctr))" t_until 5 udp_dropped
check "OR17 origin_lock: the edge still gets the app" eval '[ "$(via_edge -H "X-Forwarded-For: 203.0.113.7" | rip)" = 203.0.113.7 ]'
check "OR18 origin_lock: the operator's ssh and the server's own loopback are untouched" eval '
  [ "$(srv "curl -s -o /dev/null -w %{http_code} -H Host:ori.localhost http://127.0.0.1/")" = 200 ]'
check "OR19 doctor says the lock is on" eval 'srv "sudo /opt/tando/bin/tando-agent doctor" | grep -i "origin" | grep -q "lock on"'
"$R" host setup test origin_lock=off >&2
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Host: ori.localhost' "http://127.0.0.1:$T_HTTP_PORT/")
check "OR20 origin_lock=off opens it again (got $code)" t_eq "$code" 200
"$R" host setup test origin_lock=on origin=off >&2; rc=$?
check "OR21 origin_lock=on without an origin is refused" eval '[ "$rc" != 0 ]'

# overlapping ranges and a range with host bits: normalised, merged, loaded (nft refuses them as they are)
"$R" host setup test "origin=custom:$B_IP/32,203.0.113.5/24,203.0.113.64/26" >&2; rc=$?
check "OR21b overlapping and host-bit ranges are accepted (rc=$rc), normalised in the ranges file" eval '
  [ $rc = 0 ] && srv "sudo grep -qx 203.0.113.0/24 /opt/tando/origin.ranges" && [ "$(via_edge -H "X-Forwarded-For: 203.0.113.7" | rip)" = 203.0.113.7 ]'
# ---- origin=cloudflare, the updater ------------------------------------------------------------
"$R" host setup test origin=cloudflare >&2; rc=$?
check "OR22 origin=cloudflare succeeds and seeds the built-in ranges" eval '[ $rc = 0 ] && srv "sudo grep -qx 173.245.48.0/20 /opt/tando/origin.ranges" && srv "sudo grep -qx 2606:4700::/32 /opt/tando/origin.ranges"'
check "OR23 cloudflare mode reads CF-Connecting-IP first, and the edge container is not in those ranges: its header is ignored" eval '
  [ "$(via_edge -H "CF-Connecting-IP: 203.0.113.7" | rip)" = "$B_IP" ] &&
  srv "sudo grep -E \"client_ip_headers CF-Connecting-IP X-Forwarded-For\" /etc/caddy/Caddyfile" > /dev/null'
check "OR24 a daily updater timer is installed" eval 'srv "systemctl is-enabled tando-origin.timer" | grep -q enabled'
# a fake "official list" the updater fetches (HTTP only when the test overrides the base)
srv 'mkdir -p ~/lists && cat > ~/lists/srv.js' <<'EOF'
const http = require('http'), fs = require('fs');
http.createServer((q, r) => {
  const f = process.env.HOME + '/lists' + q.url.replace(/[^a-z0-9/-]/g, '');
  if (fs.existsSync(f) && fs.statSync(f).isFile()) { r.end(fs.readFileSync(f)); } else { r.statusCode = 404; r.end(); }
}).listen(8099, '127.0.0.1');
EOF
srv 'pkill -f "[n]ode .*lists/[s]rv"' > /dev/null 2>&1
srv 'nohup node ~/lists/srv.js > /dev/null 2>&1 < /dev/null & disown'
upd() { srv "sudo TANDO_ORIGIN_ALLOW_PRIVATE=1 TANDO_ORIGIN_LIST_BASE=http://127.0.0.1:8099 /opt/tando/bin/tando-agent origin-update $*"; }
upd_strict() { srv "sudo TANDO_ORIGIN_LIST_BASE=http://127.0.0.1:8099 /opt/tando/bin/tando-agent origin-update $*"; }
sums() { srv 'sudo cksum < /opt/tando/origin.ranges'; }
refused() { # <upd command...>: refused, ranges unchanged
  local s0 rc; s0=$(sums); "$@" > "$E/refused.out" 2>&1; rc=$?; [ $rc != 0 ] && [ "$(sums)" = "$s0" ]; }
srv "printf '%s\n' $B_IP/32 192.0.2.0/24 198.51.100.0/24 > ~/lists/ips-v4; printf '%s\n' 2606:4700::/32 > ~/lists/ips-v6"
t_until 10 srv 'curl -sf http://127.0.0.1:8099/ips-v4 > /dev/null'
check "OR24a a list that replaces nearly every range of the last good one is held back without --force" refused upd
v6g='2606:4700::/32'
srv "printf '%s\n' 127.0.0.0/16 10.0.0.0/16 192.168.0.0/16 192.0.2.0/24 > ~/lists/ips-v4; printf '%s\n' $v6g > ~/lists/ips-v6"
check "OR24b loopback, private and reserved ranges are refused (even with --force)" refused upd_strict --force
srv "for o in 20 30 40; do echo \$o.0.0.0/8; done > ~/lists/ips-v4"
check "OR24c ranges wider than the real lists use (a /8) are refused (even with --force)" refused upd --force
srv "i=0; while [ \$i -lt 31 ]; do echo 192.0.2.\$i/32; i=\$((i+1)); done > ~/lists/ips-v4"
check "OR24d far more ranges than the real list has are refused (even with --force)" refused upd --force
srv "printf '%s\n' 192.0.2.0/24 198.51.100.0/24 203.0.113.0/24 > ~/lists/ips-v4; printf '%s\n' 'fc00::/28' > ~/lists/ips-v6"
check "OR24e a non-global IPv6 range is refused (even with --force)" refused upd --force
srv "printf '%s\n' $B_IP/32 192.0.2.0/24 198.51.100.0/24 > ~/lists/ips-v4; printf '%s\n' $v6g > ~/lists/ips-v6"
upd --force > "$E/upd1.out" 2>&1; rc=$?
check "OR25 the updater takes a good list: ranges replaced, Caddy and the firewall follow (rc=$rc)" eval '
  [ $rc = 0 ] && srv "sudo grep -qx $B_IP/32 /opt/tando/origin.ranges" && ! srv "sudo grep -qx 173.245.48.0/20 /opt/tando/origin.ranges" &&
  [ "$(via_edge -H "CF-Connecting-IP: 203.0.113.7" | rip)" = 203.0.113.7 ]'
check "OR26 SPOOF: from a non-edge address CF-Connecting-IP is still ignored in cloudflare mode" eval '
  [ "$(via_self -H "\"CF-Connecting-IP: 203.0.113.9\"" | rip)" = "$A_IP" ]'
check "OR26b cloudflare mode: CF-Connecting-IP the app gets is Caddy's answer (the edge's value from the edge, the connection's address from anyone else); True-Client-IP is removed" eval '
  [ "$(via_self -H "\"CF-Connecting-IP: 203.0.113.9\"" | field cf)" = "$A_IP" ] && [ "$(via_edge -H "CF-Connecting-IP: 203.0.113.7" | field cf)" = 203.0.113.7 ] &&
  [ -z "$(via_edge -H "True-Client-IP: 1.2.3.4" | field tci)" ]'
# shellcheck disable=SC2034 # read inside the eval'd checks below
sum1=$(srv 'sudo cksum < /opt/tando/origin.ranges')
srv "printf '' > ~/lists/ips-v4"
upd > "$E/upd2.out" 2>&1; rc=$?
check "OR27 an empty list is refused: the last good ranges stay (rc=$rc)" eval '[ $rc != 0 ] && [ "$(srv "sudo cksum < /opt/tando/origin.ranges")" = "$sum1" ]'
srv "printf '%s\n' 'not-a-range' 0.0.0.0/0 > ~/lists/ips-v4"
upd > "$E/upd3.out" 2>&1; rc=$?
check "OR28 a list with junk or a catch-all 0.0.0.0/0 is refused too (rc=$rc)" eval '[ $rc != 0 ] && [ "$(srv "sudo cksum < /opt/tando/origin.ranges")" = "$sum1" ]'
check "OR29 the lock's sets still hold the last good list, and the edge still works" eval '
  [ "$(via_edge -H "CF-Connecting-IP: 203.0.113.7" | rip)" = 203.0.113.7 ]'
check "OR30 three failures in a row: doctor warns, and the status file counts them" eval '
  upd > /dev/null 2>&1; srv "sudo grep -q ^fails=3 /opt/tando/origin.status" && srv "sudo /opt/tando/bin/tando-agent doctor" | grep -i origin | grep -qi "fail"'
srv "printf '%s\n' $B_IP/32 192.0.2.0/24 198.51.100.0/24 > ~/lists/ips-v4"
upd > /dev/null 2>&1
check "OR31 a good list after failures clears the count" eval 'srv "sudo grep -q ^fails=0 /opt/tando/origin.status"'
srv "printf '%s\n' $B_IP/32 192.0.2.0/24 198.51.100.0/24 203.0.113.0/24 > ~/lists/ips-v4"
sums0=$(sums)
srv 'sudo install -d -m 700 /run/tando-test; sudo touch /etc/tando-test-server; printf "point=origin.fw\naction=fail\n" | sudo tee /run/tando-test/fault > /dev/null'
upd > "$E/upd-fw.out" 2>&1; rc=$?
check "OR31b a firewall load that fails is a failure: ranges back, counted (rc=$rc), the edge still works" eval '
  [ $rc != 0 ] && [ "$(sums)" = "$sums0" ] && srv "sudo grep -q ^fails=1 /opt/tando/origin.status" &&
  [ "$(via_edge -H "CF-Connecting-IP: 203.0.113.7" | rip)" = 203.0.113.7 ]'
upd > /dev/null 2>&1
check "OR31c the next update applies it, and the lock's sets hold it" eval 'srv "sudo grep -qx 203.0.113.0/24 /opt/tando/origin.ranges" && srv "sudo nft list set inet tando edge4" | grep -q 203.0.113.0/24'
srv 'pkill -f "[n]ode .*lists/[s]rv"' > /dev/null 2>&1

# ---- TLS behind the edge: an origin certificate from files --------------------------------------
CD=$(srv 'mktemp -d')
gen='openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=origin-test.example" -addext "subjectAltName=DNS:*.localhost,DNS:localhost" -keyout oc.key -out oc.pem 2>/dev/null; openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=other" -keyout other.key -out other.pem 2>/dev/null; chmod 644 oc.* other.*'
srv "cd $CD && $gen"
"$R" host setup test origin_cert=$CD/oc.pem origin_key=$CD/other.key > "$E/mismatch.out" 2>&1; rc=$?
check "OR32 a certificate and key that do not match are refused, saying so (rc=$rc)" eval '[ $rc != 0 ] && grep -qi "do not match" "$E/mismatch.out"'
"$R" host setup test origin_cert=$CD/oc.pem >&2 2> "$E/nokey.out"; rc=$?
check "OR33 origin_cert without origin_key is refused (rc=$rc)" eval '[ $rc != 0 ]'
"$R" host setup test tls=auto origin_cert=$CD/oc.pem origin_key=$CD/oc.key >&2; rc=$?
check "OR34 origin_cert/origin_key with tls=auto install and Caddy accepts them (rc=$rc)" eval '[ $rc = 0 ] && srv "sudo test -f /etc/caddy/origin/cert.pem"'
check "OR35 the key is readable by Caddy only (root:caddy 640 or caddy 600)" eval '
  srv "sudo stat -c %a:%G /etc/caddy/origin/key.pem" | grep -Eq "^(640:caddy|600:)"'
check "OR36 the site serves the origin certificate, no certificate is requested from an ACME CA" eval '
  srv "echo | openssl s_client -connect 127.0.0.1:443 -servername ori.localhost 2>/dev/null | openssl x509 -noout -subject" | grep -q origin-test.example'
srv "rm -rf $CD" > /dev/null 2>&1
t_done
