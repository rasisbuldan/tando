#!/bin/bash
# End-to-end test of control plane mode (docs/CONTROL-PLANE.md): the user tando-ctl, admitted by
# the real sshd of the test server only with certificates of a test CA made here; the principal
# decides what a request may do; JSON in, JSON out; request ids make retries safe; the metering
# ledger is read with a cursor. Every refusal has a control check beside it (the same key with a
# good certificate works), so a refusal for another reason does not pass as the one under test.
#
#   test/e2e-ctl.sh [--reset]     --reset: recreate the server first (only one this suite owns)
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT. About 5 minutes.
# Needs ssh-keygen and python3 on the laptop. Output: PASS/FAIL lines (docs/TESTING.md).
set -u
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init ctl
W=$E/w K=$E/keys
mkdir -p "$W" "$K"

if [ "${1:-}" = --reset ]; then t_server_up --reset || exit 1; else t_server_up || exit 1; fi
t_host_add test

# ---- certificates: a test CA, one client key, a certificate per case ------------------------------
ssh-keygen -q -t ed25519 -N '' -C test-ca -f "$K/ca" || exit 1
ssh-keygen -q -t ed25519 -N '' -C other-ca -f "$K/other" || exit 1
ssh-keygen -q -t ed25519 -N '' -C cp -f "$K/cp" || exit 1
# cert <name> <principals> <validity> <serial> [ca]: the client key with a certificate, as $K/<name>
cert() {
  cp "$K/cp" "$K/$1"; cp "$K/cp.pub" "$K/$1.pub"
  ssh-keygen -q -s "$K/${5:-ca}" -I "cp-$1" -n "$2" -V "$3" -z "$4" "$K/$1.pub" || exit 1
}
cert w tando-ctl-write -5m:+30m 1
cert r tando-ctl-read -5m:+30m 2
cert a tando-app-shop -5m:+30m 3
cert n tando-app-nope -5m:+30m 4
cert x tando-ctl-write 20200101:20200102 5           # expired
cert p tando-ctl-admin,root -5m:+30m 6                # principals tando does not know
cert o tando-ctl-write -5m:+30m 7 other              # signed by another CA
cert v tando-ctl-write -5m:+30m 99                   # revoked below

RC=0
KOPTS=(-F /dev/null -p "$T_SSH_PORT" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes
       -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
# ctl <cert> <json> [ssh command]: one request; the response in $E/out, the exit status returned
ctl() {
  local c=$1 j=$2; shift 2
  printf '%s\n' "$j" | ssh "${KOPTS[@]}" -i "$K/$c" -o CertificateFile="$K/$c-cert.pub" tando-ctl@127.0.0.1 "$@" > "$E/out" 2> "$E/err"
  RC=$?; return $RC
}
# plain <json>: the client key with no certificate at all
plain() { printf '%s\n' "$1" | ssh "${KOPTS[@]}" -i "$K/cp" -o CertificateFile=none tando-ctl@127.0.0.1 > "$E/out" 2> "$E/err"; RC=$?; }
# jv <python expression over d>: a value of the response
jv() { python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$E/out" "$1" 2> /dev/null; }
ok() { [ "$(jv 'd["ok"]')" = True ]; }
code() { jv 'd.get("error", {}).get("code", "")'; }
# denied: ssh itself refused the login (exit 255, no response)
denied() { [ "$RC" = 255 ] && [ ! -s "$E/out" ] && grep -q 'Permission denied' "$E/err"; }
INV='{"v":1,"verb":"inventory"}'
# settle: OpenSSH 9.8+ penalises an address after failed logins (PerSourcePenalties: its
# connections are dropped for a while, the admin's too); after the checks of refusals, wait until
# the server takes logins from here again
settle() { T_UNTIL_STEP=2 t_until 300 "$SSH" true 2> /dev/null; }

ctl w "$INV"
check "C0 before control plane mode, tando-ctl does not log in" denied
settle

"$R" host setup test public_port="$T_HTTP_PORT" ctl_ca="$K/ca.pub" > "$E/setup.log" 2>&1
check "C1 host setup ctl_ca=<the CA's .pub> sets control plane mode up" eval 'grep -q "control plane mode on" "$E/setup.log"'
cp -R "$ROOT/examples/hello" "$W/shop"; printf 'app = shop\n' >> "$W/shop/tando.conf"
(cd "$W/shop" && "$R" up --yes > "$E/up.log" 2>&1)
check "C2 the laptop CLI deploys as before (app shop)" eval '[ "$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "$(t_url shop)")" = 200 ]'

# ---- who gets in ---------------------------------------------------------------------------------
ctl w "$INV"
check "C3 a write certificate: inventory answers JSON (node capacity, the app with its caps)" eval '
  ok && [ "$(jv "d[\"result\"][\"node\"][\"mem_total_mb\"] > 0")" = True ] &&
  [ "$(jv "[a[\"alloc_mb\"] for a in d[\"result\"][\"apps\"] if a[\"app\"] == \"shop\"][0]")" = 128 ] &&
  [ "$(jv "d[\"result\"][\"node\"][\"admit_headroom_mb\"] > 0")" = True ]'
settle; ctl x "$INV"
check "C4 an expired certificate is refused by sshd" denied
settle; ctl p "$INV"
check "C5 a certificate without a tando principal is refused (root, tando-ctl-admin)" denied
settle; ctl o "$INV"
check "C6 a certificate of another CA is refused" denied
settle; plain "$INV"
check "C7 the same key without a certificate is refused (no authorized_keys for tando-ctl)" denied
settle; ctl n '{"v":1,"verb":"app.status","app":"nope"}'
check "C8 an app principal for an app that is not on the node is refused" denied
settle

ctl v "$INV"
check "C9 before revocation the certificate with serial 99 works" ok
# by serial (every certificate here certifies the same key: revoking the key would revoke them all)
printf 'serial: 99\n' > "$K/krl.spec"; ssh-keygen -q -k -f "$K/revoked.krl" -s "$K/ca.pub" "$K/krl.spec"
"$R" host setup test public_port="$T_HTTP_PORT" ctl_krl="$K/revoked.krl" > "$E/setup2.log" 2>&1
ctl v "$INV"
check "C10 host setup ctl_krl= revokes it: refused" denied
settle
ctl w "$INV"
check "C11 other certificates of the CA still work" ok
: > "$K/empty.krl"
"$SSH" 'sudo -n /opt/tando/bin/tando-gate admin ctl-krl' < "$K/empty.krl" > /dev/null 2>&1; rc=$?
ctl v "$INV"
check "C12a an empty file does not replace a list with entries unless asked (ctl_krl=empty)" eval '[ $rc != 0 ] && denied'
settle
"$R" host setup test public_port="$T_HTTP_PORT" ctl_krl=empty > "$E/setup2b.log" 2>&1
ctl v "$INV"
check "C12 control: with ctl_krl=empty the same certificate works again (C10 was the list)" ok
"$SSH" 'sudo -n /opt/tando/bin/tando-gate admin ctl-krl' < "$K/revoked.krl" > /dev/null 2>&1
printf 'garbage' > "$K/bad.krl"
"$SSH" 'sudo -n /opt/tando/bin/tando-gate admin ctl-krl' < "$K/bad.krl" > /dev/null 2>&1; rc=$?
ctl w "$INV"
check "C13 a file that is not a revocation list is refused, and the node keeps the last good one" eval '[ $rc != 0 ] && ok'

ctl w "$INV" id
check "C14 a command on the ssh line is refused (no shell; the request goes on stdin)" eval '! ok && ! grep -q uid= "$E/out" "$E/err"'
settle

# ---- what each principal may do ----------------------------------------------------------------
ctl r "$INV"
check "C15 a read certificate reads the inventory" ok
ctl r '{"v":1,"verb":"app.restart","app":"shop","request_id":"read-try-0001"}'
check "C16 a read certificate cannot restart an app (forbidden)" eval '[ "$(code)" = forbidden ]'
ctl a '{"v":1,"verb":"app.status","app":"shop"}'
check "C17 an app certificate reads its own app" eval 'ok && [ "$(jv "d[\"result\"][\"state\"]")" = active ]'
ctl a "$INV"
check "C18 an app certificate cannot read the whole node" eval '[ "$(code)" = forbidden ]'
ctl a '{"v":1,"verb":"app.destroy","app":"shop","request_id":"app-destroy-01","args":{"confirm":"shop"}}'
check "C19 an app certificate cannot destroy its app" eval '[ "$(code)" = forbidden ] && [ "$(curl -s -o /dev/null -w "%{http_code}" --max-time 20 "$(t_url shop)")" = 200 ]'
ctl w '{"v":2,"verb":"inventory"}'
check "C20 an unknown schema version is refused" eval '[ "$(code)" = unsupported_version ]'
ctl w '{"v":1,"verb":"app.restart","app":"shop"}'
check "C21 a mutating request without request_id is refused" eval '[ "$(code)" = bad_request ]'

# ---- request ids ---------------------------------------------------------------------------------
since() { "$SSH" 'systemctl show -P ActiveEnterTimestampMonotonic tando-shop.service'; }
t0=$(since)
ctl a '{"v":1,"verb":"app.restart","app":"shop","request_id":"restart-0001"}'
t1=$(since)
check "C22 an app certificate restarts its app (request_id restart-0001)" eval 'ok && [ "$t1" != "$t0" ] && [ "$(jv "d[\"result\"][\"healthy\"]")" = 1 ]'
ctl a '{"v":1,"verb":"app.restart","app":"shop","request_id":"restart-0001"}'
check "C23 the same request id again: the stored response, nothing restarted" eval 'ok && [ "$(jv "d[\"replayed\"]")" = True ] && [ "$(since)" = "$t1" ]'
ctl w '{"v":1,"verb":"app.stop","app":"shop","request_id":"restart-0001"}'
check "C24 the same id for another request is refused (conflict)" eval '[ "$(code)" = conflict ] && [ "$("$SSH" "systemctl is-active tando-shop.service")" = active ]'
audits() { "$SSH" 'sudo grep -c "env-set" /var/log/tando/audit.log' 2> /dev/null || echo 0; }
n0=$(audits)
J='{"v":1,"verb":"app.env.set","app":"shop","request_id":"env-par-0001","args":{"vars":{"GREETING":"hi there"}}}'
ctl w "$J" & ctl2() { printf '%s\n' "$J" | ssh "${KOPTS[@]}" -i "$K/w" -o CertificateFile="$K/w-cert.pub" tando-ctl@127.0.0.1 > "$E/out2" 2> /dev/null; }
ctl2; wait
n1=$(audits)
once() {
  [ $((n1 - n0)) = 1 ] && grep -q '"ok":true' "$E/out" && grep -q '"ok":true' "$E/out2" &&
    [ "$(cat "$E/out" "$E/out2" | grep -c '"replayed":true')" = 1 ]
}
check "C25 two sessions with one request id at once: one env change, two equal answers, one replayed" once
check "C26 the value reached the app's env" "$SSH" 'sudo grep -q "^GREETING=\"hi there\"" /opt/tando/apps/shop/env'
check "C27 the request store keeps no env value" eval '! "$SSH" "sudo grep -rq \"hi there\" /var/lib/tando/ctl"'
check "C28 the journal has one line per request: principal, serial, key id, request id, result" \
  "$SSH" 'sudo journalctl -t tando-gate --no-pager -o cat | grep -q "ctl app:shop serial=3 key=cp-a verb=app.restart app=shop request_id=restart-0001 result=ok"'

# ---- metering ------------------------------------------------------------------------------------
rows() { ctl r '{"v":1,"verb":"usage","args":{"since":0}}' && [ "$(jv "len([r for r in d[\"result\"][\"rows\"] if r[\"app\"] == \"shop\" and r[\"awake_s\"] > 0])")" -gt 0 ]; }
check "C29 usage: per-minute rows with the app's allocation and awake seconds (within 2 min)" t_until 150 rows
check "C30 a row carries alloc_mb = the app's memory cap" eval '[ "$(jv "[r[\"alloc_mb\"] for r in d[\"result\"][\"rows\"] if r[\"app\"] == \"shop\"][0]")" = 128 ]'
nx=$(jv 'd["result"]["next"]')
ctl r "{\"v\":1,\"verb\":\"usage\",\"args\":{\"since\":$nx}}"
check "C31 from the cursor: only newer rows" eval 'ok && [ "$(jv "all(r[\"seq\"] > $nx for r in d[\"result\"][\"rows\"])")" = True ]'
"$SSH" 'sudo systemctl restart tandod' > /dev/null 2>&1
more() { ctl r "{\"v\":1,\"verb\":\"usage\",\"args\":{\"since\":$nx}}" && [ "$(jv "len(d[\"result\"][\"rows\"])")" -gt 0 ] &&
  [ "$(jv "min(r[\"seq\"] for r in d[\"result\"][\"rows\"]) == $nx + 1")" = True ]; }
check "C32 after a restart of tandod the ledger goes on from the same cursor (no gap, no reuse)" t_until 150 more

# ---- destroy, then off ---------------------------------------------------------------------------
ctl w '{"v":1,"verb":"app.destroy","app":"shop","request_id":"destroy-0001","args":{"confirm":"shp"}}'
check "C33 destroy needs args.confirm = the app's name" eval '[ "$(code)" = bad_request ]'
ctl w '{"v":1,"verb":"app.destroy","app":"shop","request_id":"destroy-0002","args":{"confirm":"shop","purge":true}}'
check "C34 a write certificate destroys the app" eval 'ok && ! "$SSH" "test -e /opt/tando/apps/shop"'
ctl a '{"v":1,"verb":"app.status","app":"shop"}'
check "C35 the app's principal no longer logs in once the app is gone" denied
settle
"$R" host setup test public_port="$T_HTTP_PORT" ctl_ca=off > "$E/setup3.log" 2>&1
ctl w "$INV"
check "C36 host setup ctl_ca=off: the write certificate no longer logs in" denied
t_done
