#!/bin/bash
# End-to-end test of holding an app over the control plane (docs/CONTROL-PLANE.md, "Hold"):
# app.hold pause / suspend and app.release with certificates of a test CA made here, against the
# test server's real sshd, Caddy and systemd. Held: Caddy answers 503 with the reason, the units and
# job timers are off and disabled, deploy / start / restart / rollback are refused, a recovery (as
# at boot) keeps it held; an app's principal may pause and release a pause, never a suspend; a
# suspend freezes evidence; release brings back what ran before (a stopped app stays stopped).
#
#   test/e2e-ctl-hold.sh [--reset]     --reset: recreate the server first (only one this suite owns)
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT. About 4 minutes.
# Needs ssh-keygen and python3 on the laptop. Output: PASS/FAIL lines (docs/TESTING.md).
set -u
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init ctl-hold
W=$E/w K=$E/keys
mkdir -p "$W" "$K"

if [ "${1:-}" = --reset ]; then t_server_up --reset || exit 1; else t_server_up || exit 1; fi
t_host_add test

ssh-keygen -q -t ed25519 -N '' -C test-ca -f "$K/ca" || exit 1
ssh-keygen -q -t ed25519 -N '' -C cp -f "$K/cp" || exit 1
cert() { # name principals serial
  cp "$K/cp" "$K/$1"; cp "$K/cp.pub" "$K/$1.pub"
  ssh-keygen -q -s "$K/ca" -I "cp-$1" -n "$2" -V -5m:+60m -z "$3" "$K/$1.pub" || exit 1
}
cert w tando-ctl-write 1
cert a tando-app-shop 2
KOPTS=(-F /dev/null -p "$T_SSH_PORT" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes
       -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
RC=0
ctl() { printf '%s\n' "$2" | ssh "${KOPTS[@]}" -i "$K/$1" -o CertificateFile="$K/$1-cert.pub" tando-ctl@127.0.0.1 > "$E/out" 2> "$E/err"; RC=$?; return $RC; }
jv() { python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$E/out" "$1" 2> /dev/null; }
ok() { [ "$(jv 'd["ok"]')" = True ]; }
code() { jv 'd.get("error", {}).get("code", "")'; }
msg() { jv 'd.get("error", {}).get("message", "")'; }
N=0
# req <cert> <verb> [args]: one mutating request with a fresh request id
req() {
  N=$((N + 1))
  ctl "$1" "{\"v\":1,\"verb\":\"$2\",\"app\":\"shop\",\"request_id\":\"hold-test-$N-$$\"${3:+,\"args\":$3}}"
}
http() { curl -s -o "$E/body" -w '%{http_code}' --max-time 20 "$(t_url shop)"; }
body() { cat "$E/body" 2> /dev/null; }
unit() { "$SSH" "systemctl is-active tando-shop.service"; }
enabled() { "$SSH" "systemctl is-enabled tando-shop.service" 2> /dev/null; }
timer() { "$SSH" "systemctl is-active tando-shop_job-tick.timer"; }

"$R" host setup test public_port="$T_HTTP_PORT" ctl_ca="$K/ca.pub" > "$E/setup.log" 2>&1
cp -R "$ROOT/examples/hello" "$W/shop"; printf 'app = shop\njob.tick = yearly | true\n' >> "$W/shop/tando.conf"
(cd "$W/shop" && "$R" up --yes > "$E/up.log" 2>&1)
check "H0 the app runs (200) with its job timer" eval '[ "$(http)" = 200 ] && [ "$(timer)" = active ]'

# ---- pause -------------------------------------------------------------------------------------
req a app.hold '{"reason":"suspend"}'
check "H1 an app's principal cannot suspend its app (forbidden; it still serves)" eval '[ "$(code)" = forbidden ] && [ "$(http)" = 200 ]'
req a app.hold '{"reason":"pause","message":"{env.HOME}"}'
check "H2 a message with a placeholder brace is refused (bad_request)" eval '[ "$(code)" = bad_request ] && [ "$(http)" = 200 ]'
req a app.hold '{"reason":"pause","message":"Back on Monday."}'
check "H3 an app's principal pauses it: 503 \"shop is paused. Back on Monday.\"" eval '
  ok && [ "$(http)" = 503 ] && [ "$(body)" = "shop is paused. Back on Monday." ]'
check "H4 held: the web unit is stopped and disabled, the job timer is off" eval '
  [ "$(unit)" != active ] && [ "$(enabled)" != enabled ] && [ "$(timer)" != active ]'
ctl w '{"v":1,"verb":"app.status","app":"shop"}'
check "H5 app.status shows hold = pause and hold_since" eval '
  [ "$(jv "d[\"result\"][\"hold\"]")" = pause ] && [ "$(jv "d[\"result\"][\"hold_since\"] > 0")" = True ] && [ "$(jv "d[\"result\"][\"stopped\"]")" = True ]'
req w app.restart
check "H6 restart while held is refused: held (pause): release it first" eval '[ "$(code)" = failed ] && msg | grep -q "held (pause): release it first" && [ "$(unit)" != active ]'
req w app.start
check "H7 start while held is refused" eval '[ "$(code)" = failed ] && msg | grep -q "release it first" && [ "$(http)" = 503 ]'
(cd "$W/shop" && "$R" up --yes > "$E/up2.log" 2>&1); rc=$?
check "H8 a deploy while held is refused, the app stays held" eval '[ $rc != 0 ] && grep -q "release it first" "$E/up2.log" && [ "$(http)" = 503 ] && [ "$(unit)" != active ]'
# as at boot: systemd reloaded, then tando's recovery of every app
"$SSH" 'sudo systemctl daemon-reload && sudo /opt/tando/bin/tando-agent recover-all' > /dev/null 2>&1
check "H9 after a reload and a recovery of every app (as at boot) it is still held" eval '
  [ "$(http)" = 503 ] && [ "$(unit)" != active ] && [ "$(enabled)" != enabled ] && [ "$(timer)" != active ] && body | grep -q "is paused"'
req a app.release
check "H10 an app's principal releases a pause: 200 again, job timer back" eval '
  ok && [ "$(jv "d[\"result\"][\"healthy\"]")" = 1 ] && [ "$(http)" = 200 ] && [ "$(timer)" = active ] && [ "$(enabled)" = enabled ]'

# ---- suspend -----------------------------------------------------------------------------------
req w app.hold '{"reason":"suspend"}'
check "H11 the write principal suspends it: 503 \"shop is suspended\"" eval 'ok && [ "$(http)" = 503 ] && [ "$(body)" = "shop is suspended" ]'
# shellcheck disable=SC2034  # (read by the eval strings of the checks below)
ev=$(jv 'd["result"].get("evidence", "")')
check "H12 suspend froze evidence: root 700, journal, release id and sums, SHA256SUMS that verify" eval '
  case "$ev" in /var/lib/tando/ctl/evidence/shop/*) ;; *) false;; esac &&
  "$SSH" "test \"\$(sudo stat -c %U:%a $ev)\" = root:700 && sudo test -s $ev/journal.export && sudo test -s $ev/release.sums &&
    sudo grep -q ^release=2 $ev/info && sudo sh -c \"cd $ev && sha256sum -c --quiet SHA256SUMS\"" ||
  { "$SSH" "sudo ls -la $ev; sudo cat $ev/info" >&2; false; }'
req a app.release
check "H13 an app's principal cannot release a suspend (forbidden; still 503)" eval '[ "$(code)" = forbidden ] && [ "$(http)" = 503 ]'
req a app.hold '{"reason":"pause"}'
check "H14 nor soften it to a pause" eval '[ "$(code)" = forbidden ] && body | grep -q suspended'
req a app.rollback
check "H15 a rollback while held is refused" eval 'msg | grep -q "release it first" && [ "$(http)" = 503 ]'
req w app.release
check "H16 the write principal releases it: 200; the evidence stays" eval 'ok && [ "$(http)" = 200 ] && "$SSH" "sudo test -s $ev/SHA256SUMS"'

# ---- a stopped app stays stopped -----------------------------------------------------------------
req w app.stop
req w app.hold '{"reason":"pause"}'
check "H17 a stopped app can be held (the paused page)" eval 'ok && [ "$(http)" = 503 ] && body | grep -q paused'
req w app.release
check "H18 released, an app stopped before the hold stays stopped (the stopped page)" eval '
  ok && [ "$(jv "d[\"result\"][\"stopped\"]")" = 1 ] && [ "$(http)" = 503 ] && [ "$(body)" = "shop is stopped" ] && [ "$(unit)" != active ]'
req w app.start
check "H19 control: start works again once released" eval 'ok && [ "$(http)" = 200 ]'

req w app.destroy '{"confirm":"shop","purge":true}'
check "H20 destroy removes the app's evidence" eval 'ok && ! "$SSH" "sudo test -e /var/lib/tando/ctl/evidence/shop"'
"$R" host setup test public_port="$T_HTTP_PORT" ctl_ca=off > /dev/null 2>&1
t_done
