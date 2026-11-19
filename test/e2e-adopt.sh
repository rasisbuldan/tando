#!/bin/bash
# test/e2e-adopt.sh: `tando adopt` end to end (lib/cmd-adopt.sh, server/tando-adopt;
# docs/MIGRATION.md) on a throwaway test server, against a synthetic hand-deployed app.
#
# The app ("bakery", every name here is made up) is what an owner would have set up by hand:
#   /opt/bakery/releases/<id> with /opt/bakery/current -> it, run by /etc/systemd/system/bakery.service
#   as its own user with an env file (/etc/bakery.env) and a data directory (/var/lib/bakery); a
#   hand-written Caddy site with one plain `reverse_proxy` line that also serves the static files
#   from the release path; a nightly backup script in /etc/cron.d with one archive made.
# It is a small Node HTTP server in the layout adopt takes (a Next.js standalone release:
# server.js and .next/), not a Next.js build: nothing is installed from the network. Like a real
# app it needs a moment before it listens (1.5 s), so a restart without a request hold is always
# visible to the request loop, and a restart with one has something to hold.
#
#   A0  the fixture answers through Caddy; host setup beside it changes nothing for visitors
#   A1  plan: read-only, names only for the env file, and loud about the missing request hold
#   A2  apply refuses to start without the hold (client and server), nothing changed
#   A3  site shapes adopt site does not edit (no reverse_proxy to the port, two of them): reported
#       as manual with the lines to add, nothing edited; the plan and apply say the same
#   A4  an edit Caddy rejects, and an edit Caddy cannot load: the previous Caddyfile stays
#   A5  adopt site --apply before adoption: the hold only, a copy kept, reload not restart
#   A6  apply under a request loop: zero failed requests; the app is tando's, same data and env
#   A7  tando deploy of a new version, then rollback: zero failed requests each
#   A8  adopt site --apply after adoption adds the request log; tando requests sees requests
#   A9  undo: the hand-written unit again, the state as recorded (with the hold), still answering
#   A10 the control: without the hold, apply --accept-502 adopts, and requests fail with 502
# Not covered here: timers that become tando jobs (the handoff), a real Next.js build, TLS.
# Also not covered, on purpose: a request Caddy sends on a kept-alive connection that the stopping
# app has just closed. lb_try_duration holds a request that cannot connect; Caddy 2.6.2 (the
# distribution's package, used here with TANDO_TEST_CADDY=ubuntu) answers 502 for one whose
# connection broke (its tryAgain never retries a non-dial error without lb_retry_match). With
# keep-alive on, this suite saw that in about 1 run of 9 (2 requests during apply, 1 during
# rollback), so the stand-in app closes every connection and "zero failed" below is about
# requests that arrive while the app is not listening.
# bash 3.2.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-adopt
srv() { "$SSH" "$@"; }
# root cmd args...: as root on the server, every argument passed as it is (spaces and all)
root() { local a q=""; for a; do q="$q $(printf '%q' "$a")"; done; "$SSH" "sudo$q"; }
t_server_up --reset || exit 1
W=$E/bakery            # the owner's source directory on the laptop
CF=/etc/caddy/Caddyfile
URL=$(t_url bakery)
ver() { curl -s -m 5 "$(t_url bakery /api/version)"; }
cf_sha() { srv "sudo sha256sum < $CF | cut -c1-16"; }
caddy_pid() { srv 'systemctl show -P MainPID caddy'; }
# cf_put: the Caddyfile on disk becomes stdin. Caddy is not reloaded: it keeps serving what it has.
cf_put() { srv "sudo tee $CF > /dev/null"; }
# loop_end name: stop the loop; when a request failed, show which and what Caddy said about it
loop_end() {
  t_loop_stop "$1"
  [ "$T_LOOP_BAD" = 0 ] && return 0
  { grep -n -v '^200 ' "$E/loop.$1" | head -5
    srv 'sudo journalctl -u caddy --since -90s --no-pager -o cat | grep -E "\"level\":\"(error|warn)\"" | tail -6 | cut -c1-700'; } >&2
}
# loop_ok name: stop the loop; true when it made requests and none failed
loop_ok() { loop_end "$1"; [ "$T_LOOP_N" -ge 5 ] && [ "$T_LOOP_BAD" = 0 ]; }
# flat file: a boxed output as one line (borders and line breaks removed), so a sentence the box
# wrapped can be looked for
flat() { tr '\n' ' ' < "$1" | sed 's/│//g' | tr -s ' '; }
has() { flat "$1" | grep -q -- "$2"; }
order() { curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "$(t_url bakery "/api/order?$1")"; }

# ---- the fixture: a hand-deployed app ----------------------------------------------------------
log "building the hand-deployed app"
mkdir -p "$W/src"
cat > "$W/src/server.js" <<'EOF'
// bakery: a stand-in for a hand-deployed app. It warms up before it listens, as a real one does.
const http = require('http'), fs = require('fs');
const VERSION = '__VERSION__', data = process.env.BAKERY_DATA_DIR || '/nonexistent';
const page = '<html><head><link rel="stylesheet" href="/_next/static/app.css"></head>' +
  '<body><h1>bakery ' + VERSION + '</h1></body></html>\n';
const server = http.createServer((req, res) => {
  // one connection per request: Caddy then has no idle connection to this app that could break as
  // the app stops. That case is outside what the hold covers on Caddy 2.6 (see the header).
  res.setHeader('Connection', 'close');
  const say = (code, body) => { res.writeHead(code, { 'Content-Type': 'text/plain' }); res.end(body); };
  const path = req.url.split('?')[0];
  if (path === '/api/version') return say(200, VERSION);
  if (path === '/api/greeting') return say(200, process.env.BAKERY_GREETING || '');
  if (path === '/api/order' && req.method === 'POST') {
    try { fs.appendFileSync(data + '/orders.log', (req.url.split('?')[1] || '') + '\n'); return say(200, 'stored'); }
    catch (e) { return say(500, String(e.code)); }
  }
  if (path === '/' || path === '/order/new') { res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end(page); }
  say(404, 'not found');
});
setTimeout(() => server.listen(Number(process.env.PORT), process.env.HOSTNAME || '127.0.0.1'), 1500);
// a clean stop: answers in flight are finished, idle connections closed
process.on('SIGTERM', () => { server.close(() => process.exit(0)); server.closeIdleConnections(); });
EOF
printf 'body { font-family: sans-serif }\n' > "$W/src/app.css"
cat > "$W/build.sh" <<'EOF'
#!/bin/sh
# the layout of a Next.js standalone build, made by hand: .next/standalone (the server) and .next/static
set -e
rm -rf .next
mkdir -p .next/standalone/.next/server/app .next/static
sed "s/__VERSION__/$(cat VERSION)/" src/server.js > .next/standalone/server.js
printf '{ "config": { "basePath": "" } }\n' > .next/standalone/.next/required-server-files.json
printf 'page\n' > .next/standalone/.next/server/app/index.html
cp src/app.css .next/static/app.css
echo "built bakery $(cat VERSION)"
EOF
# what tando deploy asks of a Next.js project (it ships .next/standalone)
printf 'export default { output: "standalone" };\n' > "$W/next.config.mjs"
printf '{ "name": "bakery", "private": true }\n' > "$W/package.json"
echo v1 > "$W/VERSION"
(cd "$W" && sh build.sh > /dev/null) || { fail "A0 fixture: build"; t_done; }
REL0=/opt/bakery/releases/20260101-000000
mkdir -p "$E/rel"
rsync -a "$W/.next/standalone/" "$E/rel/" && rsync -a "$W/.next/static/" "$E/rel/.next/static/"
tar -C "$E/rel" -cf - . | srv "sudo install -d -m 755 $REL0 && sudo tar -C $REL0 -xf - --no-same-owner &&
  sudo chown -R root:root /opt/bakery && sudo chmod -R u=rwX,go=rX /opt/bakery &&
  sudo ln -sfn $REL0 /opt/bakery/current" || { fail "A0 fixture: release"; t_done; }
srv 'sudo bash -s' <<'EOF' || { fail "A0 fixture: unit, env file, data, backup, site"; t_done; }
set -e
useradd --system --no-create-home --shell /usr/sbin/nologin bakery
install -d -m 750 -o bakery -g bakery /var/lib/bakery
printf 'opened\n' > /var/lib/bakery/orders.log; chown bakery:bakery /var/lib/bakery/orders.log
printf 'BAKERY_DATA_DIR=/var/lib/bakery\nBAKERY_GREETING=fresh-bread-daily\n' > /etc/bakery.env
chmod 600 /etc/bakery.env
cat > /etc/systemd/system/bakery.service <<'UNIT'
[Unit]
Description=bakery (deployed by hand)
After=network.target

[Service]
User=bakery
WorkingDirectory=/opt/bakery/current
Environment=PORT=3100 HOSTNAME=127.0.0.1
EnvironmentFile=/etc/bakery.env
ExecStart=/usr/local/bin/node /opt/bakery/current/server.js
Restart=always
MemoryMax=300M
ProtectSystem=strict
ReadWritePaths=/var/lib/bakery

[Install]
WantedBy=multi-user.target
UNIT
cat > /usr/local/bin/bakery-backup <<'SCRIPT'
#!/bin/sh
# nightly copy of the order file
mkdir -p /var/backups/bakery
tar -czf "/var/backups/bakery/bakery-$(date +%F).tar.gz" -C /var/lib bakery
SCRIPT
chmod 755 /usr/local/bin/bakery-backup
printf '30 2 * * * root /usr/local/bin/bakery-backup\n' > /etc/cron.d/bakery-backup
/usr/local/bin/bakery-backup
cat >> /etc/caddy/Caddyfile <<'SITE'

# bakery, written by hand
http://bakery.localhost {
	encode gzip
	handle_path /_next/static/* {
		root * /opt/bakery/current/.next/static
		file_server
	}
	reverse_proxy 127.0.0.1:3100
}
SITE
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null 2>&1
systemctl daemon-reload
systemctl enable -q --now bakery
systemctl reload caddy
EOF
t_until 30 eval '[ "$(ver)" = v1 ]'
check "A0a the hand-deployed app answers through its own Caddy site, as user bakery" eval \
  '[ "$(ver)" = v1 ] && [ "$(srv "systemctl show -P User bakery")" = bakery ] &&
   [ "$(curl -s -o /dev/null -w "%{http_code}" "$(t_url bakery /_next/static/app.css)")" = 200 ]'
check "A0b an order is stored in the data directory" eval \
  '[ "$(order before-tando)" = 200 ] && root grep -qx before-tando /var/lib/bakery/orders.log'

t_host_add test
t_loop_start setup "$URL"
"$R" host setup test "public_port=$T_HTTP_PORT" > "$E/setup.out" 2>&1; rc=$?; tail -5 "$E/setup.out" >&2
check "A0c host setup beside the hand-written site: no request failed (rc=$rc)" eval '[ $rc = 0 ] && loop_ok setup'
root cp -p "$CF" /root/Caddyfile.hand   # the hand-written file as host setup left it: no hold
# shellcheck disable=SC2034 # read inside the eval'd checks below
SHA0=$(cf_sha)
cd "$W" || exit 1

# ---- A1 plan -----------------------------------------------------------------------------------
"$R" adopt plan bakery -H test > "$E/plan1.out" 2>&1; rc=$?; cat "$E/plan1.out" >&2
check "A1a plan: port, user, data directory, the owner's backup, healthy now (rc=$rc)" eval \
  '[ $rc = 0 ] && has "$E/plan1.out" "port 3100" && has "$E/plan1.out" "user bakery" &&
   has "$E/plan1.out" "data /var/lib/bakery" && has "$E/plan1.out" "bakery-backup (/etc/cron.d/bakery-backup) still covers /var/lib/bakery" &&
   has "$E/plan1.out" "healthy through Caddy"'
check "A1b plan shows the env file's variable names and never a value" eval \
  'grep -q "BAKERY_GREETING" "$E/plan1.out" && ! grep -q "fresh-bread-daily" "$E/plan1.out"'
check "A1c plan is loud about the missing hold: what it costs (502, the 36 requests)" eval \
  'grep -q "request hold: missing" "$E/plan1.out" &&
   has "$E/plan1.out" "fails with 502" && has "$E/plan1.out" "36 requests did"'
check "A1d plan gives the exact command that adds the hold, and the one that accepts the 502s, each on a line" eval \
  'grep -q "^│ *tando adopt site bakery -H test --apply *│$" "$E/plan1.out" &&
   grep -q "^│ *tando adopt apply bakery -H test --accept-502 *│$" "$E/plan1.out" &&
   tail -1 "$E/plan1.out" | grep -q "first: tando adopt site bakery -H test --apply"'
check "A1e plan changed nothing" eval \
  '[ "$(cf_sha)" = "$SHA0" ] && ! root test -e /opt/tando/apps/bakery && ! root test -e /opt/tando/adopt/bakery'

# ---- A2 apply without the hold -----------------------------------------------------------------
"$R" adopt apply bakery -H test --yes > "$E/apply0.out" 2>&1; rc=$?; cat "$E/apply0.out" >&2
check "A2a apply refuses to start without the hold and says what to run (rc=$rc)" eval \
  '[ $rc != 0 ] && grep -q "refused: the site has no request hold" "$E/apply0.out" &&
   grep -q "^Add the hold first: tando adopt site bakery -H test --apply$" "$E/apply0.out" &&
   grep -q "tando adopt apply bakery -H test --accept-502$" "$E/apply0.out"'
srv 'sudo /opt/tando/bin/tando-agent adopt-apply bakery' > "$E/apply0s.out" 2>&1; rc=$?; cat "$E/apply0s.out" >&2
check "A2b the server refuses it too, whatever the client is (rc=$rc)" eval \
  '[ $rc != 0 ] && grep -q "does not hold requests" "$E/apply0s.out"'
check "A2c nothing was changed: no tando app, no record, bakery.service still serving" eval \
  '! root test -e /opt/tando/apps/bakery && ! root test -e /opt/tando/adopt/bakery/record &&
   [ "$(srv "systemctl is-active bakery")" = active ] && [ "$(cf_sha)" = "$SHA0" ] && [ "$(ver)" = v1 ]'

# ---- A3, A4: sites adopt site must not or cannot edit (Caddy keeps serving the loaded one) -------
t_loop_start site "$URL"
# no reverse_proxy to the port in the Caddyfile
root cat /root/Caddyfile.hand | sed 's/reverse_proxy 127.0.0.1:3100/reverse_proxy 127.0.0.1:3999/' | cf_put
s=$(cf_sha)
"$R" adopt site bakery -H test --apply > "$E/site-none.out" 2>&1; rc=$?; cat "$E/site-none.out" >&2
check "A3a no reverse_proxy to the port: reported as manual with the lines to add, nothing edited (rc=$rc)" eval \
  'has "$E/site-none.out" "no reverse_proxy to port 3100" && has "$E/site-none.out" "add lb_try_duration 15s and lb_try_interval 100ms to it" &&
   grep -q "nothing to add" "$E/site-none.out" && [ "$(cf_sha)" = "$s" ]'
# two of them
root cat /root/Caddyfile.hand | awk '/^\treverse_proxy 127.0.0.1:3100$/ { print "\thandle /api/* {\n\t\treverse_proxy 127.0.0.1:3100\n\t}" } { print }' | cf_put
s=$(cf_sha)
"$R" adopt site bakery -H test --apply > "$E/site-two.out" 2>&1; rc=$?; cat "$E/site-two.out" >&2
check "A3b two reverse_proxy lines to the port: reported as manual, nothing edited (rc=$rc)" eval \
  'has "$E/site-two.out" "more than one reverse_proxy to port 3100" && has "$E/site-two.out" "add lb_try_duration 15s and lb_try_interval 100ms to each" &&
   grep -q "nothing to add" "$E/site-two.out" && [ "$(cf_sha)" = "$s" ]'
"$R" adopt plan bakery -H test > "$E/plan-two.out" 2>&1
"$R" adopt apply bakery -H test --yes > "$E/apply-two.out" 2>&1; rc=$?; tail -4 "$E/apply-two.out" >&2
check "A3c with such a site the plan gives the lines to add by hand, and apply still needs the flag (rc=$rc)" eval \
  'has "$E/plan-two.out" "cannot add it to this site itself" && has "$E/plan-two.out" "more than one reverse_proxy to port 3100" &&
   has "$E/plan-two.out" "add lb_try_duration 15s and lb_try_interval 100ms to each" &&
   [ $rc != 0 ] && grep -q "by hand" "$E/apply-two.out" && grep -q -- "--accept-502" "$E/apply-two.out" &&
   ! root test -e /opt/tando/apps/bakery'
# a shape the edit gets wrong (the upstreams continue on the next line): valid before, not after
root cat /root/Caddyfile.hand | sed 's/^\(.*\)reverse_proxy 127.0.0.1:3100$/\1reverse_proxy 127.0.0.1:3100 \\\
\1	127.0.0.1:3100/' | cf_put
s=$(cf_sha)
"$R" adopt site bakery -H test --apply > "$E/site-bad.out" 2>&1; rc=$?; cat "$E/site-bad.out" >&2
check "A4a the file is valid as it is (so only the edit can be what Caddy rejects)" eval \
  'root grep -q "127.0.0.1:3100 .$" "$CF" && root caddy validate --config "$CF" --adapter caddyfile > /dev/null 2>&1'
check "A4b an edit Caddy rejects: refused, the Caddyfile as it was, no temporary file left (rc=$rc)" eval \
  '[ $rc != 0 ] && has "$E/site-bad.out" "Caddy rejects the edited file" && [ "$(cf_sha)" = "$s" ] &&
   [ -z "$(srv "sudo find /etc/caddy -name .Caddyfile.tando.\*")" ]'
# an edit Caddy accepts but cannot load (a second site wants the port the app listens on)
{ root cat /root/Caddyfile.hand; printf 'http://clash.test:3100 {\n\tbind 127.0.0.1\n\trespond "clash"\n}\n'; } | cf_put
# shellcheck disable=SC2034 # read inside the eval'd checks below
s=$(cf_sha) p=$(caddy_pid)
"$R" adopt site bakery -H test --apply > "$E/site-clash.out" 2>&1; rc=$?; cat "$E/site-clash.out" >&2
check "A4c an edit Caddy cannot load: the previous Caddyfile is put back and said so (rc=$rc)" eval \
  '[ $rc != 0 ] && has "$E/site-clash.out" "the previous Caddyfile is back" && [ "$(cf_sha)" = "$s" ] &&
   ! root grep -q lb_try_duration "$CF" && [ "$(caddy_pid)" = "$p" ]'
root cp -p /root/Caddyfile.hand "$CF"
check "A4d through all of it the site kept answering: no request failed" loop_ok site

# ---- A5 the hold, before adoption ----------------------------------------------------------------
"$R" adopt site bakery -H test > "$E/site-pre0.out" 2>&1; rc=$?; cat "$E/site-pre0.out" >&2
check "A5a adopt site on the unit, without --apply: reports the hold, edits nothing (rc=$rc)" eval \
  '[ $rc = 0 ] && has "$E/site-pre0.out" "not adopted yet" && has "$E/site-pre0.out" "lb_try_duration 15s" &&
   [ "$(cf_sha)" = "$SHA0" ]'
p=$(caddy_pid)
t_loop_start hold "$URL"
"$R" adopt site bakery -H test --apply > "$E/site-pre.out" 2>&1; rc=$?; cat "$E/site-pre.out" >&2
check "A5b adopt site --apply before adoption adds the hold (rc=$rc)" eval \
  '[ $rc = 0 ] && grep -q "added and reloaded" "$E/site-pre.out" &&
   [ "$(root grep -c "lb_try_duration 15s" "$CF")" = 1 ] && [ "$(root grep -c "lb_try_interval 100ms" "$CF")" = 1 ] &&
   root caddy validate --config "$CF" --adapter caddyfile > /dev/null 2>&1'
check "A5c only the hold: the request log is said to come after adoption, and none was added" eval \
  'has "$E/site-pre.out" "log after adoption" && ! root grep -q "/var/log/tando" "$CF" &&
   ! root test -e /opt/tando/apps/bakery'
KEPT=$(flat "$E/site-pre.out" | sed -n 's/.*\(\/opt\/tando\/adopt\/bakery\/Caddyfile\.[0-9-]*\).*/\1/p')
check "A5d the previous Caddyfile is kept in /opt/tando/adopt/bakery, root only (${KEPT:-no path printed})" eval \
  '[ -n "$KEPT" ] && [ "$(srv "sudo cat $KEPT | sha256sum | cut -c1-16")" = "$SHA0" ] &&
   [ "$(root stat -c %U:%a /opt/tando/adopt/bakery)" = root:700 ]'
check "A5e Caddy was reloaded, not restarted, and no request failed" eval '[ "$(caddy_pid)" = "$p" ] && loop_ok hold'
check "A5f the output names the next step" has "$E/site-pre.out" "next tando adopt apply bakery -H test"
"$R" adopt site bakery -H test --apply > "$E/site-pre2.out" 2>&1; rc=$?
check "A5g a second --apply finds nothing to add (rc=$rc)" eval \
  '[ $rc = 0 ] && grep -q "nothing to add" "$E/site-pre2.out" && [ "$(root grep -c "lb_try_duration" "$CF")" = 1 ]'
# shellcheck disable=SC2034 # read inside the eval'd checks below
SHA1=$(cf_sha)
"$R" adopt plan bakery -H test > "$E/plan2.out" 2>&1; rc=$?; cat "$E/plan2.out" >&2
check "A5h plan now: no missing hold, requests are held, next is apply (rc=$rc)" eval \
  '[ $rc = 0 ] && ! grep -q "request hold" "$E/plan2.out" && has "$E/plan2.out" "Caddy holds requests" &&
   tail -1 "$E/plan2.out" | grep -q "tando adopt apply bakery -H test"'

# ---- A6 apply ------------------------------------------------------------------------------------
t_loop_start adopt "$URL"
"$R" adopt apply bakery -H test --yes > "$E/apply.out" 2>&1; rc=$?; cat "$E/apply.out" >&2
loop_end adopt
check "A6a apply adopts the app (rc=$rc)" eval '[ $rc = 0 ] && grep -q "adopted: tando deploy" "$E/apply.out"'
check "A6b zero failed requests during the adoption ($T_LOOP_BAD of $T_LOOP_N, longest stall ${T_LOOP_STALL}s)" \
  eval '[ "$T_LOOP_N" -ge 20 ] && [ "$T_LOOP_BAD" = 0 ]'
# (the restart was in the loop: a request waited for the app's 1.5 s start instead of failing)
check "A6c the restart happened under the loop: one request was held for it (slowest ${T_LOOP_MAX}s)" \
  awk -v m="$T_LOOP_MAX" 'BEGIN { exit !(m >= 1.0) }'
check "A6d tando-bakery runs as bakery; bakery.service is stopped and disabled, its file kept" eval \
  '[ "$(srv "systemctl is-active tando-bakery")" = active ] && [ "$(srv "systemctl show -P User tando-bakery")" = bakery ] &&
   [ "$(srv "systemctl is-active bakery")" = inactive ] && [ "$(srv "systemctl is-enabled bakery")" = disabled ] &&
   root test -f /etc/systemd/system/bakery.service'
check "A6e same code, same env value, static files through Caddy from tando's release" eval \
  '[ "$(ver)" = v1 ] && [ "$(curl -s "$(t_url bakery /api/greeting)")" = fresh-bread-daily ] &&
   [ "$(curl -s -o /dev/null -w "%{http_code}" "$(t_url bakery /_next/static/app.css)")" = 200 ] &&
   [ "$(srv "readlink /opt/bakery/current")" = /opt/tando/apps/bakery/current ]'
check "A6f the data directory is the same one and still writable" eval \
  '[ "$(order under-tando)" = 200 ] && root grep -qx before-tando /var/lib/bakery/orders.log &&
   root grep -qx under-tando /var/lib/bakery/orders.log'
check "A6g apply did not touch the Caddyfile, and tando.conf was written here" eval \
  '[ "$(cf_sha)" = "$SHA1" ] && grep -q "^app = bakery" tando.conf && grep -q "^recipe = next" tando.conf'
check "A6h apply ends with what the site still lacks: the request log" eval \
  'grep -q "your Caddy site" "$E/apply.out" && has "$E/apply.out" "a request log to /var/log/tando/bakery/access.log" &&
   has "$E/apply.out" "requests wait while the app restarts (lb_try_duration"'
ID0=$(srv 'readlink /opt/tando/apps/bakery/current'); ID0=${ID0##*/}

# ---- A7 deploy and rollback ------------------------------------------------------------------------
sed 's/^build = .*/build = sh build.sh/' tando.conf > tando.conf.new && mv tando.conf.new tando.conf
echo v2 > VERSION
t_loop_start deploy "$URL"
"$R" deploy > "$E/deploy.out" 2>&1; rc=$?; cat "$E/deploy.out" >&2
loop_end deploy
check "A7a tando deploy ships version 2 of the adopted app (rc=$rc)" eval '[ $rc = 0 ] && [ "$(ver)" = v2 ]'
check "A7b zero failed requests during the deploy ($T_LOOP_BAD of $T_LOOP_N, slowest ${T_LOOP_MAX}s)" \
  eval '[ "$T_LOOP_N" -ge 20 ] && [ "$T_LOOP_BAD" = 0 ]'
check "A7c the new release's static files are served by the hand-written site" eval \
  '[ "$(curl -s -o /dev/null -w "%{http_code}" "$(t_url bakery /_next/static/app.css)")" = 200 ]'
t_loop_start rollback "$URL"
"$R" rollback > "$E/rollback.out" 2>&1; rc=$?; cat "$E/rollback.out" >&2
loop_end rollback
check "A7d rollback returns to the adopted release (rc=$rc)" eval \
  '[ $rc = 0 ] && [ "$(ver)" = v1 ] && [ "$(srv "readlink /opt/tando/apps/bakery/current")" = "releases/$ID0" ]'
check "A7e zero failed requests during the rollback ($T_LOOP_BAD of $T_LOOP_N)" \
  eval '[ "$T_LOOP_N" -ge 5 ] && [ "$T_LOOP_BAD" = 0 ]'

# ---- A8 the request log, after adoption -----------------------------------------------------------
# shellcheck disable=SC2034 # read inside the eval'd checks below
p=$(caddy_pid)
t_loop_start log "$URL"
"$R" adopt site bakery -H test --apply > "$E/site-post.out" 2>&1; rc=$?; cat "$E/site-post.out" >&2
check "A8a adopt site --apply after adoption adds the request log; the hold is there already (rc=$rc)" eval \
  '[ $rc = 0 ] && grep -q "added and reloaded" "$E/site-post.out" && root grep -q "/var/log/tando/bakery/" "$CF" &&
   [ "$(root grep -c "lb_try_duration" "$CF")" = 1 ] && has "$E/site-post.out" "requests wait while the app restarts (lb_try_duration"'
check "A8b this copy of the Caddyfile is beside the app's backups; reload, no failed request" eval \
  'has "$E/site-post.out" "/var/backups/tando/bakery/Caddyfile\." && [ "$(caddy_pid)" = "$p" ] && loop_ok log'
# (asked for as a visitor would: the site's name without a port. Caddy 2.6 finds a site's log by
# the Host header as sent, and the test server's published port would be part of it)
# Asked again until the log has them: right after a reload the old configuration can still accept
# a connection, and all requests of one curl go over one connection.
reqs() { srv 'sudo /opt/tando/bin/tando-agent req-summary bakery 300' | sed -n 's/^total=//p'; }
ask30() {
  curl -s -o /dev/null --connect-to "bakery.localhost:80:127.0.0.1:$T_HTTP_PORT" "http://bakery.localhost/api/version?[1-30]"
  [ "$(reqs)" -ge 30 ] 2> /dev/null
}
t_until 30 ask30
"$R" requests -a bakery -H test --last 15m > "$E/requests.out" 2>&1; rc=$?; cat "$E/requests.out" >&2
check "A8c tando requests sees the requests ($(reqs) in the log; rc=$rc)" eval \
  '[ $rc = 0 ] && [ "$(reqs)" -ge 30 ] && grep -q "/api/version" "$E/requests.out"'
# shellcheck disable=SC2034 # read inside the eval'd checks below
SHA2=$(cf_sha)

# ---- A9 undo ---------------------------------------------------------------------------------------
t_loop_start undo "$URL"
"$R" adopt undo bakery -H test --yes > "$E/undo.out" 2>&1; rc=$?; cat "$E/undo.out" >&2
loop_end undo
srv 'sudo /opt/tando/bin/tando-agent adopt-status bakery' > "$E/undo.status" 2>&1; cat "$E/undo.status" >&2
check "A9a undo returns to the hand-managed unit and finds the state as recorded (rc=$rc)" eval \
  '[ $rc = 0 ] && grep -q "back to the hand-managed bakery.service" "$E/undo.out" && grep -q "^result=ok" "$E/undo.status" &&
   grep -q "unit, env file, Caddyfile, link, timers, cron, data owner as recorded" "$E/undo.status"'
check "A9b bakery.service runs and is enabled; tando's unit, app directory and link are gone" eval \
  '[ "$(srv "systemctl is-active bakery")" = active ] && [ "$(srv "systemctl is-enabled bakery")" = enabled ] &&
   ! root test -e /etc/systemd/system/tando-bakery.service && ! root test -e /opt/tando/apps/bakery &&
   [ "$(srv "readlink /opt/bakery/current")" = "$REL0" ]'
check "A9c the Caddyfile is the owner's as it was when undo started: the hold stays" eval \
  '[ "$(cf_sha)" = "$SHA2" ] && root grep -q "lb_try_duration 15s" "$CF"'
check "A9d the app still answers, with every order (before, under and after tando)" eval \
  '[ "$(ver)" = v1 ] && [ "$(order after-undo)" = 200 ] &&
   [ "$(root grep -c -x -e before-tando -e under-tando -e after-undo /var/lib/bakery/orders.log)" = 3 ]'
check "A9e zero failed requests during the undo, with the hold ($T_LOOP_BAD of $T_LOOP_N)" \
  eval '[ "$T_LOOP_N" -ge 5 ] && [ "$T_LOOP_BAD" = 0 ]'

# ---- A10 the control: the same adoption without the hold --------------------------------------------
# The owner's Caddyfile without the hold again (as host setup left it). The app needs 1.5 s to
# listen and the loop asks ten times a second, so requests fall into the restart every time.
root cp -p /root/Caddyfile.hand "$CF" && root systemctl reload caddy
"$R" adopt apply bakery -H test --yes > "$E/apply-c0.out" 2>&1; rc=$?
check "A10a without the hold apply refuses again (rc=$rc)" eval \
  '[ $rc != 0 ] && grep -q "refused: the site has no request hold" "$E/apply-c0.out" && [ "$(srv "systemctl is-active bakery")" = active ]'
t_loop_start control "$URL"
"$R" adopt apply bakery -H test --yes --accept-502 > "$E/apply-c.out" 2>&1; rc=$?; cat "$E/apply-c.out" >&2
loop_end control
check "A10b --accept-502 adopts without the hold (rc=$rc)" eval \
  '[ $rc = 0 ] && [ "$(srv "systemctl is-active tando-bakery")" = active ] && [ "$(ver)" = v1 ] &&
   ! root grep -q lb_try_duration "$CF"'
codes=$(awk '$1 != 200 { print $1 }' "$E/loop.control" | sort | uniq -c | tr -s ' \n' ' ')
check "A10c the hold matters: without it requests failed with 502 during the adoption ($T_LOOP_BAD of $T_LOOP_N:$codes)" \
  eval '[ "$T_LOOP_BAD" -ge 1 ] && [ -z "$(awk "\$1 != 200 && \$1 != 502" "$E/loop.control")" ]'
check "A10d the adopted app's site list names the hold as missing" eval \
  '"$R" adopt site bakery -H test > "$E/site-c.out" 2>&1; has "$E/site-c.out" "+ hold line" &&
   has "$E/site-c.out" "tando adopt site bakery -H test --apply"'
t_done
