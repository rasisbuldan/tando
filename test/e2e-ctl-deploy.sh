#!/bin/bash
# End-to-end test of the control plane's artifact deploys (docs/CONTROL-PLANE.md, "Artifacts"):
# app.deploy fetches an artifact over https from a server in the test container (a test CA that
# only this node trusts, through /opt/tando/ctl/fetch-ca.pem), checks it and deploys it through
# the laptop deploy's own path. Refusals: a loopback address without the operator's allowlist, a
# wrong sha256, a redirect to http, an archive whose link leaves release/, a manifest that sets
# the app spec's settings. Each refusal leaves the live release serving.
#
#   test/e2e-ctl-deploy.sh [--reset]
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT. About 4 minutes.
# Needs ssh-keygen and python3 on the laptop. Output: PASS/FAIL lines (docs/TESTING.md).
set -u
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init ctl-deploy
W=$E/w K=$E/keys A=$E/art
mkdir -p "$W" "$K" "$A"

if [ "${1:-}" = --reset ]; then t_server_up --reset || exit 1; else t_server_up || exit 1; fi
t_host_add test

ssh-keygen -q -t ed25519 -N '' -C test-ca -f "$K/ca" || exit 1
ssh-keygen -q -t ed25519 -N '' -C cp -f "$K/cp" || exit 1
cert() {
  cp "$K/cp" "$K/$1"; cp "$K/cp.pub" "$K/$1.pub"
  ssh-keygen -q -s "$K/ca" -I "cp-$1" -n "$2" -V -5m:+60m -z "$3" "$K/$1.pub" || exit 1
}
cert w tando-ctl-write 1
cert a tando-app-web 2

RC=0
KOPTS=(-F /dev/null -p "$T_SSH_PORT" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes
       -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
ctl() {
  printf '%s\n' "$2" | ssh "${KOPTS[@]}" -i "$K/$1" -o CertificateFile="$K/$1-cert.pub" tando-ctl@127.0.0.1 > "$E/out" 2> "$E/err"
  RC=$?; return $RC
}
jv() { python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$E/out" "$1" 2> /dev/null; }
ok() { [ "$(jv 'd["ok"]')" = True ]; }
code() { jv 'd.get("error", {}).get("code", "")'; }
msg() { jv 'd.get("error", {}).get("message", "")'; }
body() { curl -s --max-time 20 "$(t_url web)"; }

# ---- the artifacts: tar.gz of tando-artifact.json + release/, made with python's tarfile --------
# mkart <name> <version text> [kind]: $A/<name>.tar.gz; kind: escape (a link out of release/),
# spec (the manifest sets memory), crash (the app exits at once)
mkart() {
  python3 -I - "$A/$1.tar.gz" "$2" "${3:-}" << 'EOF'
import io, json, sys, tarfile
out, ver, kind = sys.argv[1], sys.argv[2], sys.argv[3]
srv = "const http = require('http'); const fs = require('fs');\n"
srv += "const v = fs.readFileSync(__dirname + '/VERSION', 'utf8').trim();\n"
if kind == "crash":
    srv += "process.exit(3);\n"
srv += "http.createServer((q, s) => s.end(q.url === '/health' ? 'ok' : v)).listen(process.env.PORT, '127.0.0.1');\n"
settings = {"recipe": "node", "start": "node server.js", "health": "/health"}
if kind == "spec":
    settings["memory"] = "4G"
man = json.dumps({"v": 1, "settings": settings, "source": "test " + ver}).encode()
def add(t, name, data=None, typ=tarfile.REGTYPE, link="", mode=0o644):
    i = tarfile.TarInfo(name); i.type = typ; i.mode = mode; i.linkname = link
    if data is None:
        t.addfile(i)
    else:
        i.size = len(data); t.addfile(i, io.BytesIO(data))
with tarfile.open(out, "w:gz", format=tarfile.PAX_FORMAT) as t:
    add(t, "tando-artifact.json", man)
    add(t, "release", typ=tarfile.DIRTYPE, mode=0o755)
    add(t, "release/server.js", srv.encode())
    add(t, "release/VERSION", (ver + "\n").encode())
    if kind == "escape":
        add(t, "release/passwd", typ=tarfile.SYMTYPE, link="../../../../etc/passwd")
EOF
}
mkart v1 version-one; mkart v2 version-two; mkart v3 version-three; mkart esc evil escape
mkart spec spec spec; mkart crash crash crash
shaof() { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
sizeof() { wc -c < "$1" | tr -d ' '; }
# req <verb args json> for <name>: {"url": ..., "sha256": ..., "size": ...}
art() { printf '{"url":"https://127.0.0.1:9443/%s.tar.gz","sha256":"%s","size":%s}' "$1" "${2:-$(shaof "$A/$1.tar.gz")}" "$(sizeof "$A/$1.tar.gz")"; }
dep() { ctl "$1" "{\"v\":1,\"verb\":\"app.deploy\",\"app\":\"web\",\"request_id\":\"$2\",\"args\":$3}"; local rc=$?; log "$2: $(head -c 600 "$E/out")"; return $rc; }

# ---- the artifact server: node over https on the server's loopback, a test CA -----------------
"$R" host setup test public_port="$T_HTTP_PORT" ctl_ca="$K/ca.pub" > "$E/setup.log" 2>&1
# (runtimes are the operator's: the node installs none for an artifact)
"$SSH" 'sudo /opt/tando/bin/tando-agent runtime node < /dev/null' > "$E/runtime.log" 2>&1
check "D0 control plane mode set up, node installed" eval 'grep -q "control plane mode on" "$E/setup.log" && "$SSH" "command -v node" > /dev/null'
"$SSH" 'sudo sh -c "rm -rf /srv/tvart && mkdir -p /srv/tvart/files && cd /srv/tvart &&
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=test-ca -keyout ca.key -out ca.pem &&
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -subj /CN=127.0.0.1 -keyout srv.key -out srv.csr &&
  echo subjectAltName=IP:127.0.0.1 > ext &&
  openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -extfile ext -out srv.pem" 2> /dev/null' ||
  { echo "could not make the test CA" >&2; exit 1; }
for f in "$A"/*.tar.gz; do "$SSH" "sudo tee /srv/tvart/files/${f##*/} > /dev/null" < "$f"; done
"$SSH" 'sudo tee /srv/tvart/server.js > /dev/null' << 'EOF'
const https = require('https'), fs = require('fs'), path = require('path');
const o = { key: fs.readFileSync('/srv/tvart/srv.key'), cert: fs.readFileSync('/srv/tvart/srv.pem') };
https.createServer(o, (q, s) => {
  if (q.url === '/redir.tar.gz') { s.writeHead(302, { Location: 'http://127.0.0.1:9080/v3.tar.gz' }); return s.end(); }
  const f = path.join('/srv/tvart/files', path.basename(q.url));
  fs.readFile(f, (e, b) => { if (e) { s.writeHead(404); return s.end(); } s.writeHead(200, { 'Content-Length': b.length }); s.end(b); });
}).listen(9443, '127.0.0.1');
EOF
"$SSH" 'sudo systemctl stop tv-art 2> /dev/null; sudo systemd-run --quiet --unit tv-art --collect "$(command -v node)" /srv/tvart/server.js'
t_until 30 "$SSH" 'curl -sfk -o /dev/null https://127.0.0.1:9443/v1.tar.gz' ||
  { "$SSH" 'sudo journalctl -u tv-art -n 20 --no-pager' >&2; echo "the artifact server did not start" >&2; exit 1; }

# ---- the guard: loopback is refused until the operator allows it --------------------------------
dep w dep-0001 "$(art v1)"
check "D1 a fetch from a loopback address is refused without the operator's allowlist (nothing created)" eval '
  [ "$(code)" = failed ] && msg | grep -q "address not allowed" && ! "$SSH" "test -e /opt/tando/apps/web"'
"$SSH" 'printf "127.0.0.1/32\n" | sudo tee /opt/tando/ctl/fetch-allow > /dev/null && sudo cp /srv/tvart/ca.pem /opt/tando/ctl/fetch-ca.pem && sudo chmod 644 /opt/tando/ctl/fetch-allow /opt/tando/ctl/fetch-ca.pem'
"$SSH" 'sudo chmod 666 /opt/tando/ctl/fetch-allow'
dep w dep-0002 "$(art v1)"
check "D2 an allowlist another user can write is not used" eval '[ "$(code)" = internal ] && msg | grep -q "only root can write"'
"$SSH" 'sudo chmod 644 /opt/tando/ctl/fetch-allow'

dep w dep-0003 "$(art v1)"
check "D3 the write principal deploys a new app from an artifact: verified, it serves the artifact's release" eval '
  ok && [ "$(jv "d[\"result\"][\"result\"]")" = verified ] && [ "$(body)" = version-one ]'
check "D4 nothing of the artifact is left in the request store" eval '[ -z "$("$SSH" "sudo ls -A /var/lib/tando/ctl/art")" ]'
# shellcheck disable=SC2034  # (read in the check's eval)
inc_owner=$("$SSH" 'stat -c %U /opt/tando/apps/web/incoming')
check "D5 the control plane's app: incoming/ is root's (never tando-ctl's)" eval '[ "$inc_owner" = root ]'

dep w dep-0004 "$(art v2 0000000000000000000000000000000000000000000000000000000000000000)"
check "D6 a wrong sha256 is refused; the live release still serves" eval '
  [ "$(code)" = failed ] && msg | grep -q "sha256 mismatch" && [ "$(body)" = version-one ]'
dep w dep-0005 "$(printf '{"url":"https://127.0.0.1:9443/redir.tar.gz","sha256":"%s","size":%s}' "$(shaof "$A/v3.tar.gz")" "$(sizeof "$A/v3.tar.gz")")"
check "D7 a redirect to http is refused" eval '[ "$(code)" = failed ] && msg | grep -q "not https" && [ "$(body)" = version-one ]'
dep w dep-0006 "$(art esc)"
check "D8 an archive with a symbolic link out of release/ is refused" eval '[ "$(code)" = failed ] && msg | grep -q "leaves release/" && [ "$(body)" = version-one ]'
dep w dep-0007 "$(art spec)"
check "D9 a manifest that sets the app spec (memory) is refused" eval '[ "$(code)" = failed ] && msg | grep -q "app spec" && [ "$(body)" = version-one ]'
dep w dep-0008 '{"url":"http://127.0.0.1:9443/v2.tar.gz","sha256":"00","size":1}'
check "D10 bad arguments are refused before anything is fetched (http URL)" eval '[ "$(code)" = bad_request ]'

# ---- the app's own principal; the spec kept; replay; a failing release ----------------------------
# the write principal's allowlist is not the apps': an app's principal does not reach the loopback
dep a dep-0020 "$(art v2)"
check "D18 an app's principal does not reach an address opened for the write principal only; the error tells nothing of the server" eval '
  [ "$(code)" = failed ] && msg | grep -q "address is not one" && ! msg | grep -q "127.0.0.1" && [ "$(body)" = version-one ]'
"$SSH" 'printf "127.0.0.1/32\n" | sudo tee /opt/tando/ctl/fetch-allow-apps > /dev/null'
dep a dep-0022 "$(art v2 1111111111111111111111111111111111111111111111111111111111111111)"
check "D19 with fetch-allow-apps: a wrong sha256 is refused without the digest of what was fetched" eval '
  [ "$(code)" = failed ] && msg | grep -q "sha256 mismatch" && ! msg | grep -q "$(shaof "$A/v2.tar.gz")"'
"$SSH" 'sudo sed -i "/^memory=/d" /opt/tando/apps/web/app.conf && echo memory=192M | sudo tee -a /opt/tando/apps/web/app.conf > /dev/null'
dep a dep-0009 "$(art v2)"
check "D11 the app's principal deploys its own app; the app's memory (spec) is kept" eval '
  ok && [ "$(body)" = version-two ] && "$SSH" "sudo grep -qx memory=192M /opt/tando/apps/web/app.conf"'
# shellcheck disable=SC2034  # (read in the check's eval)
n_rel=$("$SSH" 'ls /opt/tando/apps/web/releases | wc -l')
dep a dep-0009 "$(art v2)"
check "D12 the same request id again: the stored answer, no new release" eval '
  ok && [ "$(jv "d[\"replayed\"]")" = True ] && [ "$("$SSH" "ls /opt/tando/apps/web/releases | wc -l")" = "$n_rel" ]'
dep w dep-0010 "$(art crash)"
check "D13 an artifact whose app does not start fails its pre-flight; the live release keeps serving" eval '
  [ "$(code)" = failed ] && [ "$(body)" = version-two ]'
check "D14 the journal has the request" "$SSH" 'sudo journalctl -t tando-gate --no-pager -o cat | grep -q "verb=app.deploy app=web request_id=dep-0009 result=ok"'
check "D15 the deploy is audited as tando-ctl's" "$SSH" 'sudo grep -q "tando-ctl.*artifact-put.*web" /var/log/tando/audit.log'
if "$SSH" 'command -v zstd' > /dev/null 2>&1; then
  python3 -I - "$A/v3.tar.gz" "$A/v3z.tar" << 'EOF'
import gzip, sys
open(sys.argv[2], "wb").write(gzip.open(sys.argv[1]).read())
EOF
  "$SSH" 'cat > /tmp/v3z.tar && zstd -q -f /tmp/v3z.tar -o /tmp/v3z.tar.zst && sudo cp /tmp/v3z.tar.zst /srv/tvart/files/' < "$A/v3z.tar"
  "$SSH" 'cat /tmp/v3z.tar.zst' > "$A/v3z.tar.zst"
  dep w dep-0011 "$(printf '{"url":"https://127.0.0.1:9443/v3z.tar.zst","sha256":"%s","size":%s}' "$(shaof "$A/v3z.tar.zst")" "$(sizeof "$A/v3z.tar.zst")")"
  check "D16 a tar.zst artifact deploys" eval 'ok && [ "$(body)" = version-three ]'
else
  skip "D16 a tar.zst artifact deploys (no zstd on the test server)"
fi
# ---- apply (a generation), export, import, drain --------------------------------------------------
# req verb app id args: a request of the write principal; an answer that never came (empty, or
# "interrupted": the session ended first) is asked for again with the same id, as a control plane
# does (the store answers it), and the first try is logged with ssh's status and stderr
req() {
  local j="{\"v\":1,\"verb\":\"$1\",\"app\":\"$2\",\"request_id\":\"$3\",\"args\":$4}" rc
  ctl w "$j"; rc=$?
  log "$3: rc=$rc $(head -c 600 "$E/out") $(head -c 300 "$E/err")"
  if [ ! -s "$E/out" ] || [ "$(code)" = interrupted ]; then
    ctl w "$j"; rc=$?; log "$3 (again): rc=$rc $(head -c 600 "$E/out")"
  fi
  return $rc
}
req apply web apply-0001 "{\"generation\":1,\"settings\":{\"memory\":\"160M\"},\"env\":{\"set\":{\"GREETING\":\"hello from the spec\"}},\"artifact\":$(art v1)}"
check "A1 apply generation 1 (spec memory, an env value, the artifact): done; the app serves it with that memory" eval '
  ok && [ "$(body)" = version-one ] && "$SSH" "sudo grep -qx memory=160M /opt/tando/apps/web/app.conf" &&
  "$SSH" "sudo grep -q ^GREETING= /opt/tando/apps/web/env"'
req apply web apply-0002 "{\"generation\":1,\"env\":{\"set\":{\"GREETING\":\"again\"}}}"
check "A2 the same generation again (a new request id) is refused: conflict" eval '[ "$(code)" = conflict ] && "$SSH" "sudo grep -q hello /opt/tando/apps/web/env"'
req apply web apply-0003 "{\"generation\":3,\"artifact\":$(art v2 1111111111111111111111111111111111111111111111111111111111111111)}"
check "A3 a failing step is named; the app keeps serving what it served" eval '[ "$(code)" = failed ] && msg | grep -q "step deploy failed" && [ "$(body)" = version-one ]'
req apply web apply-0004 "{\"generation\":2,\"artifact\":$(art v2)}"
check "A4 an older generation than one sent (2 after 3) is refused" eval '[ "$(code)" = conflict ] && [ "$(body)" = version-one ]'
req apply web apply-0005 "{\"generation\":3,\"artifact\":$(art v2)}"
check "A5 the failed generation sent again with a new request id applies" eval 'ok && [ "$(body)" = version-two ]'
ctl w '{"v":1,"verb":"app.export","app":"web","args":{"values":true}}'; cp "$E/out" "$E/export.json"
check "A6 app.export: spec, env values for the write principal, the artifact applied" eval '
  ok && [ "$(jv "d[\"result\"][\"env\"][\"GREETING\"]")" = "hello from the spec" ] && [ "$(jv "d[\"result\"][\"settings\"][\"memory\"]")" = 160M ] &&
  [ "$(jv "d[\"result\"][\"artifact\"][\"sha256\"]")" = "$(shaof "$A/v2.tar.gz")" ]'
check "A7 no env value is left under the request store" eval '! "$SSH" "sudo grep -rq \"hello from the spec\" /var/lib/tando/ctl"'
imp=$(python3 -I -c 'import json, sys; r = json.load(open(sys.argv[1]))["result"]
print(json.dumps({"generation": 1, "settings": r["settings"], "env": {"set": r["env"]}, "artifact": r["artifact"]}))' "$E/export.json")
req app.import web2 import-0001 "$imp"
check "A8 app.import of the export as another app: it serves the same release with the same env and memory" eval '
  ok && [ "$(curl -s --max-time 20 "$(t_url web2)")" = version-two ] && "$SSH" "sudo grep -q \"^GREETING=\\\"hello from the spec\" /opt/tando/apps/web2/env" &&
  "$SSH" "sudo grep -qx memory=160M /opt/tando/apps/web2/app.conf"'
ctl w '{"v":1,"verb":"node.drain","request_id":"drain-0001"}'
ctl w '{"v":1,"verb":"inventory"}'
check "N1 node.drain: the inventory says draining" eval 'ok && [ "$(jv "d[\"result\"][\"node\"][\"draining\"]")" = True ]'
req app.import web3 import-0002 "$imp"
check "N2 a draining node takes no new app (import refused); its apps keep serving" eval '[ "$(code)" = forbidden ] && [ "$(body)" = version-two ]'
cp -R "$ROOT/examples/hello" "$W/web4"; printf 'app = web4\n' >> "$W/web4/tando.conf"
(cd "$W/web4" && "$R" deploy --yes > "$E/web4.log" 2>&1)
check "N3 nor from the laptop CLI" eval 'grep -q draining "$E/web4.log" && ! "$SSH" "test -e /opt/tando/apps/web4"'
ctl w '{"v":1,"verb":"node.drain","request_id":"drain-0002","args":{"stop_apps":true,"stop_order":["web2"]}}'
check "N4 drain with stop_apps stops the apps in the order given" eval '
  ok && [ "$(jv "d[\"result\"][\"stopped\"][0]")" = web2 ] && [ "$("$SSH" "systemctl is-active tando-web.service")" != active ]'
ctl w '{"v":1,"verb":"node.drain","request_id":"drain-0003","args":{"off":true}}'
ctl w '{"v":1,"verb":"app.start","app":"web","request_id":"start-0001"}'
check "N5 drain off; app.start brings an app back" eval 'ok && [ "$(body)" = version-two ]'
(cd "$W" && cp -R "$ROOT/examples/hello" web && printf 'app = web\n' >> web/tando.conf && cd web && "$R" deploy --yes > "$E/laptop.log" 2>&1)
check "D17 a laptop deploy of the same app works after artifact deploys" eval 'case "$(body)" in ""|version-*) false;; esac'
inc1=$("$SSH" 'stat -c %U /opt/tando/apps/web/incoming')
dep w dep-0030 "$(art v3)"
check "D20 after a laptop deploy, an artifact deploy leaves incoming/ its owner's ($inc1), with no root file in it" eval '
  ok && [ "$inc1" != root ] && [ "$("$SSH" "stat -c %U /opt/tando/apps/web/incoming")" = "$inc1" ] &&
  [ -z "$("$SSH" "sudo find /opt/tando/apps/web/incoming -user root -print -quit")" ]'
"$R" host setup test public_port="$T_HTTP_PORT" ctl_artifact_max_mb=1 > "$E/setup-cap.log" 2>&1
dep w dep-0031 '{"url":"https://127.0.0.1:9443/v3.tar.gz","sha256":"'"$(shaof "$A/v3.tar.gz")"'","size":2000000}'
check "D21 ctl_artifact_max_mb: an artifact over it is refused before anything is fetched" eval '[ "$(code)" = failed ] && msg | grep -q ctl_artifact_max_mb'
ctl w '{"v":1,"verb":"app.destroy","app":"web2","request_id":"destroy-w2-01","args":{"confirm":"web2","purge":true}}'
req app.import web2 import-0003 "$imp"
check "D22 the spec goes with the app: a new web2 imports from generation 1 again" eval 'ok'
"$SSH" 'sudo systemctl stop tv-art' > /dev/null 2>&1
t_done
