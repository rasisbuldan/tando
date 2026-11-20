#!/bin/bash
# test/e2e-bootstrap.sh: from an empty VM to live apps on their own domains, with nothing done by
# hand on the server. The server is the bare test image (TANDO_TEST_BARE=1: systemd, sshd and a
# sudo user; no Caddy, Node, rsync or curl). Then: host add, host setup (installs everything),
# up of a static site (no Node gets installed), of hello (Node is installed on demand) and of the
# Next.js example from a fresh copy without node_modules; domain add with tls internal and a fake
# resolver (TANDO_TEST_RESOLVE); a DNS mismatch refused with the exact records; a broken Caddy
# config never going live; host setup again changing nothing; doctor all green.
# Needs network (apt and nodejs.org on the server, npm here). bash 3.2 compatible.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-bootstrap   # work dir: test/.<suite>-<server>, or $T_WORK (all.sh)
HP=$T_HTTP_PORT
W=$E/w
srv() { "$SSH" "$@"; }
mkdir -p "$W"

if docker container inspect "$T_NAME" > /dev/null 2>&1 && [ "${TANDO_TEST_OWNED:-0}" != 1 ]; then
  echo "SKIP 0 $T_NAME exists and is not ours: the bare image needs a fresh container (TANDO_TEST_OWNED=1)"
  t_done
fi
log "starting $T_NAME from the bare image"
t0=$(date +%s)
export TANDO_TEST_BARE=1
t_server_up --reset || exit 1
unset TANDO_TEST_BARE
t_up=$(date +%s)
check "0a the server is bare: no caddy, node, rsync or curl" \
  srv '! command -v caddy && ! command -v node && ! command -v rsync && ! command -v curl'

# ---- 1. host add, host setup -------------------------------------------------------------------
"$R" host add prod vmadmin@127.0.0.1 --port "$T_SSH_PORT" --key "$ROOT/test/server/id_test" \
  --yes > "$E/add.out" 2>&1; rc=$?; cat "$E/add.out" >&2
check "1a host add connects and trusts the server's host key (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -qx insecure=0 "$TANDO_CONFIG_DIR/hosts/prod" &&
        grep -qF "$(srv "cut -d\" \" -f2 /etc/ssh/ssh_host_ed25519_key.pub")" "$TANDO_CONFIG_DIR/known_hosts"'
"$R" host setup prod public_port="$HP" domain_tls=internal > "$E/setup.out" 2>&1; rc=$?; cat "$E/setup.out" >&2
check "1b host setup on the bare server (rc=$rc): Caddy installed and running, agent and checks timer in place" \
  eval '[ $rc = 0 ] && srv "command -v caddy && systemctl -q is-active caddy && test -x /opt/tando/bin/tando-agent &&
        systemctl -q is-enabled tando-watch.timer" > /dev/null'
check "1c Caddy is the distribution's package, with tando's import and the admin socket" \
  srv 'caddy version | grep -q "^v\{0,1\}2\." && grep -q "^import /etc/caddy/tando/\*\.caddy" /etc/caddy/Caddyfile &&
       sudo grep -q "admin unix//run/caddy/admin.sock" /etc/caddy/Caddyfile && systemctl -q is-active caddy'
check "1d rsync, curl and the firewall unit are there; no Node yet" \
  srv 'command -v rsync && command -v curl && systemctl -q is-enabled tando-firewall && ! command -v node'
t_setup=$(date +%s)

# ---- 2. apps: static (no Node), hello (Node on demand, from init), Next.js from a fresh copy ----
cp -R "$ROOT/examples/site" "$ROOT/examples/hello" "$W/"
rm -f "$W/hello/tando.conf"
(cd "$W/site" && "$R" up) > "$E/site.out" 2>&1; rc=$?; cat "$E/site.out" >&2
check "2a a static site goes live (rc=$rc)" \
  eval '[ $rc = 0 ] && curl -s "$(t_url site)" | grep -qi "<html"'
check "2b a static-only server has no Node" srv '! command -v node'
(cd "$W/hello" && "$R" up) > "$E/hello.out" 2>&1; rc=$?; cat "$E/hello.out" >&2
t_live=$(date +%s)
check "2c hello: init + up installs Node on demand and goes live (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -q "installing node 24 on prod" "$E/hello.out" && curl -s "$(t_url hello)" | grep -q "hello v"'
check "2d init wrote host = prod into tando.conf" grep -q '^host = prod$' "$W/hello/tando.conf"
mkdir -p "$W/nextdemo"
(cd "$ROOT/examples/next" && tar -cf - --exclude=node_modules --exclude=.next --exclude=.tando .) | (cd "$W/nextdemo" && tar -xf -)
(cd "$W/nextdemo" && "$R" up) > "$E/next.out" 2>&1; rc=$?; cat "$E/next.out" >&2
check "2e Next.js from a copy without node_modules: dependencies installed, live (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -q "installed dependencies: npm ci" "$E/next.out" &&
        curl -s "$(t_url nextdemo /demo/api/version)" | grep -q .'
# python3 there but not python3-venv (Ubuntu's own python3 on a fresh VM): `import venv` works,
# a venv cannot be built without ensurepip; up must install python3-venv first
srv 'sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends python3' \
  > /dev/null 2>&1
# shellcheck disable=SC2034 # pre is read inside the eval'd check
pre=$(srv 'python3 -c "import venv" && ! python3 -c "import ensurepip" 2> /dev/null && echo bare-python')
cp -R "$ROOT/examples/python" "$W/"
(cd "$W/python" && "$R" up) > "$E/python.out" 2>&1; rc=$?; cat "$E/python.out" >&2
check "2f python app on a server with python3 but no python3-venv: venv support installed, live (rc=$rc)" \
  eval '[ "$pre" = bare-python ] && [ $rc = 0 ] && grep -q "installing python on prod" "$E/python.out" &&
        curl -s -o /dev/null -w "%{http_code}" "$(t_url pyapp /health)" | grep -qx 200'

# ---- 3. domains ---------------------------------------------------------------------------------
cd "$W/hello" || exit 1
TANDO_TEST_RESOLVE="shop.test=203.0.113.9" "$R" domain add shop.test > "$E/dns-bad.out" 2>&1; rc=$?
cat "$E/dns-bad.out" >&2
check "3a DNS pointing elsewhere: refused with the exact records, nothing changed (rc=$rc)" \
  eval '[ $rc = 1 ] && grep -qE "^  A +shop.test +-> +[0-9.]+ +\(now 203.0.113.9\)" "$E/dns-bad.out" &&
        grep -qE "^  A +www.shop.test +-> +[0-9.]+" "$E/dns-bad.out" && ! srv "grep -q shop.test /etc/caddy/tando/hello.caddy"'
export TANDO_TEST_RESOLVE="shop.test=127.0.0.1,www.shop.test=127.0.0.1,b.test=127.0.0.1"
"$R" domain add shop.test > "$E/dom.out" 2>&1; rc=$?; cat "$E/dom.out" >&2
ca=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
body=$(srv "sudo curl -s --cacert $ca --resolve shop.test:443:127.0.0.1 https://shop.test/")
redir=$(srv "sudo curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --cacert $ca --resolve www.shop.test:443:127.0.0.1 https://www.shop.test/a")
check "3b domain add: https://shop.test is live with a certificate ($body)" \
  eval '[ $rc = 0 ] && grep -q "https://shop.test is live (certificate until" "$E/dom.out" && echo "$body" | grep -q "hello v"'
check "3c www.shop.test redirects to the domain ($redir)" t_eq "$redir" "301 https://shop.test/a"
"$R" domain add b.test --www off > "$E/dom2.out" 2>&1; rc=$?
"$R" status > "$E/status.out" 2>&1; "$R" ls > "$E/ls.out" 2>&1; cat "$E/status.out" "$E/ls.out" >&2
check "3d a second domain; status shows both with their certificate dates" \
  eval '[ $rc = 0 ] && [ "$(grep -c "^│ domain .*certificate until" "$E/status.out")" = 2 ]'
check "3e ls shows the app's domain" grep -q 'shop.test +1' "$E/ls.out"
check "3f status --json carries the domains" \
  eval '"$R" status --json | grep -q "\"domains\":\"shop.test,b.test\""'
# a Caddy config that does not validate never goes live: the site stays as it was
srv 'echo "this is { not caddy" | sudo tee /etc/caddy/tando/zz-broken.caddy > /dev/null'
sum0=$(srv 'sudo cksum < /etc/caddy/tando/hello.caddy')
TANDO_TEST_RESOLVE="c.test=127.0.0.1" "$R" domain add c.test --www off > "$E/dom3.out" 2>&1; rc=$?; cat "$E/dom3.out" >&2
sum1=$(srv 'sudo cksum < /etc/caddy/tando/hello.caddy')
check "3g a config Caddy rejects is rolled back; Caddy keeps serving (rc=$rc)" \
  eval '[ $rc != 0 ] && grep -qi "caddy rejected" "$E/dom3.out" && [ "$sum0" = "$sum1" ] &&
        srv "systemctl -q is-active caddy" && curl -s "$(t_url hello)" | grep -q "hello v"'
srv 'sudo rm -f /etc/caddy/tando/zz-broken.caddy'
"$R" domain rm b.test > /dev/null 2>&1
# positive form: an ssh failure (255) must not read as "b.test is gone"
check "3h domain rm: Caddy no longer answers for b.test" \
  srv 'test -s /etc/caddy/tando/hello.caddy && ! grep -q b.test /etc/caddy/tando/hello.caddy'
# tando.conf: domain = ... at up
printf 'domain = c.test\nwww = off\n' >> "$W/hello/tando.conf"
TANDO_TEST_RESOLVE="c.test=127.0.0.1" "$R" deploy > "$E/dom4.out" 2>&1; rc=$?; cat "$E/dom4.out" >&2
check "3i domain = in tando.conf: deploy adds it and reports it live (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -q "https://c.test is live" "$E/dom4.out"'
unset TANDO_TEST_RESOLVE

# ---- 4. setup again changes nothing; doctor is green ---------------------------------------------
snap() {
  srv 'sudo cksum /etc/caddy/Caddyfile /etc/caddy/tando/*.caddy /etc/systemd/system/tando-*.service \
         /opt/tando/host.conf /opt/tando/firewall.nft 2> /dev/null; systemctl show -P MainPID caddy;
       systemctl show -P ActiveEnterTimestampMonotonic caddy'
}
snap > "$E/snap1"
"$R" host setup prod > "$E/setup2.out" 2>&1; rc=$?; cat "$E/setup2.out" >&2
snap > "$E/snap2"
check "4a host setup again: nothing changed, Caddy not restarted (rc=$rc; $(diff "$E/snap1" "$E/snap2" | grep -c '^[<>]') lines differ)" \
  eval '[ $rc = 0 ] && cmp -s "$E/snap1" "$E/snap2" && grep -q "config .*unchanged" "$E/setup2.out"'
srv 'sudo systemctl start tando-watch.service'   # one run of the checks now, not at the next minute
"$R" doctor > "$E/doctor.out" 2>&1; rc=$?; cat "$E/doctor.out" >&2
grep -q "0 failed" "$E/doctor.out" ||
  srv 'systemctl status tando-watch.service tando-watch.timer --no-pager; sudo journalctl -u tando-watch -n 30 --no-pager' >&2
# (one warning is expected here: Caddy 2.6.2 with public_port, a test-only setting, logs no request;
# and one is wanted: a server with an app and no outside heartbeat says so, without failing)
check "4b doctor: all green but for the missing heartbeat, which is a warning with its command (rc=$rc)" eval '[ $rc = 0 ] && grep -q "0 failed" "$E/doctor.out" &&
  [ "$(grep "● warn" "$E/doctor.out" | grep -vc "caddy log\|^│ heartbeat ")" = 0 ] && grep -q "^│ heartbeat .*● warn" "$E/doctor.out" &&
  tr -d "│\n" < "$E/doctor.out" | tr -s " " | grep -q "tando alerts heartbeat"'

echo "INFO empty VM to a live link: $((t_live - t0)) s (VM start $((t_up - t0)) s, host setup $((t_setup - t_up)) s, first up with Node $((t_live - t_setup)) s)"
t_done
