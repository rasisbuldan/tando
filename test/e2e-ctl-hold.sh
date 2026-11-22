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
  ctl "$1" "{\"v\":1,\"verb\":\"$2\",\"app\":\"${APP:-shop}\",\"request_id\":\"hold-test-$N-$$\"${3:+,\"args\":$3}}"
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

# ---- an app with idle_stop: its wake socket goes too (no request starts it) -----------------------
cp -R "$ROOT/examples/hello" "$W/nap"; printf 'app = nap\nidle_stop = 5m\n' >> "$W/nap/tando.conf"
(cd "$W/nap" && "$R" up --yes > "$E/up-nap.log" 2>&1)
napc() { curl -s -o "$E/body" -w '%{http_code}' --max-time 20 "$(t_url nap)"; }
sock() { "$SSH" "systemctl is-active tando-nap_wake.socket"; }
check "H21 control: the idle app answers through its wake socket" eval '[ "$(napc)" = 200 ] && [ "$(sock)" = active ]'
APP=nap req w app.hold '{"reason":"pause"}'
"$SSH" 'sudo systemctl daemon-reload && sudo /opt/tando/bin/tando-agent recover-all' > /dev/null 2>&1
check "H22 a held idle app: its wake socket is off (also after a recovery); a request gets the page, not the app" eval '
  [ "$(sock)" != active ] && [ "$(napc)" = 503 ] && body | grep -q "nap is paused" &&
  [ "$("$SSH" "systemctl is-active tando-nap.service")" != active ]'
APP=nap req w app.release
check "H23 released, the idle app answers again (socket back)" eval 'ok && [ "$(napc)" = 200 ] && [ "$(sock)" = active ]'

# ---- previews: held with their parent (the same code on another link) ----------------------------
(cd "$W/shop" && "$R" preview up --branch pv1 > "$E/pv.log" 2>&1)
pvc() { curl -s -o "$E/body" -w '%{http_code}' --max-time 20 "$(t_url shop-pv1)"; }
check "H24 control: shop's preview shop-pv1 serves (200)" eval '[ "$(pvc)" = 200 ]'
req w app.hold '{"reason":"suspend"}'
check "H25 suspending the app suspends its preview too (503 suspended, unit stopped)" eval '
  ok && [ "$(pvc)" = 503 ] && body | grep -q "shop-pv1 is suspended" &&
  [ "$("$SSH" "systemctl is-active tando-shop-pv1.service")" != active ]'
# what the gate runs for the app's deploy key (tando preview up in CI): the agent's preview-up
"$SSH" 'sudo /opt/tando/bin/tando-agent preview-up shop shop-pv2' > "$E/pv2.log" 2>&1; rc=$?
check "H26 no new preview while the app is held (the deploy key's preview-up is refused)" eval '
  [ $rc != 0 ] && grep -q "is held" "$E/pv2.log" && ! "$SSH" "test -e /opt/tando/apps/shop-pv2"'
(cd "$W/shop" && "$R" preview up --branch pv1 > "$E/pv3.log" 2>&1); rc=$?
check "H27 nor a deploy to an existing preview" eval '[ $rc != 0 ] && [ "$(pvc)" = 503 ]'
"$SSH" 'sudo /opt/tando/bin/tando-agent release shop-pv1' > "$E/pv4.log" 2>&1; rc=$?
check "H28 the preview is not released on its own while its app is held" eval '[ $rc != 0 ] && [ "$(pvc)" = 503 ]'
req w app.release
check "H29 releasing the app releases its preview (200 again)" eval 'ok && [ "$(http)" = 200 ] && t_until 30 sh -c "[ \"\$(curl -s -o /dev/null -w %{http_code} --max-time 10 $(t_url shop-pv1))\" = 200 ]"'

# ---- a preview that its app's hold could not hold: sent again, or recovery, holds it ---------------
fault() { "$SSH" "sudo install -d -m 700 /run/tando-test; sudo touch /etc/tando-test-server; printf 'point=hold.preview\naction=fail\nverb=hold\napp=shop\n' | sudo tee /run/tando-test/fault > /dev/null"; }
fault
req w app.hold '{"reason":"pause"}'
check "H30 a preview the hold could not hold: the hold fails and names it (previews_failed); the preview still serves" eval '
  [ "$(code)" = failed ] && msg | grep -q "shop-pv1" && [ "$(http)" = 503 ] && [ "$(pvc)" = 200 ]'
req w app.hold '{"reason":"pause"}'
check "H31 the hold sent again holds the preview (the already-held branch retries it)" eval 'ok && [ "$(pvc)" = 503 ] && body | grep -q "shop-pv1 is paused"'
req w app.release
fault
req w app.hold '{"reason":"pause"}'
"$SSH" 'sudo /opt/tando/bin/tando-agent recover-all' > /dev/null 2>&1
check "H32 recovery holds a preview its app's hold could not" eval '[ "$(pvc)" = 503 ] && body | grep -q "shop-pv1 is paused"'
req w app.release
check "H33 control: released, both serve" eval 'ok && [ "$(http)" = 200 ] && t_until 30 sh -c "[ \"\$(curl -s -o /dev/null -w %{http_code} --max-time 10 $(t_url shop-pv1))\" = 200 ]"'
"$SSH" 'sudo rm -f /run/tando-test/fault'

req w app.destroy '{"confirm":"shop","purge":true}'
check "H20 destroy removes the app's evidence" eval 'ok && ! "$SSH" "sudo test -e /var/lib/tando/ctl/evidence/shop"'
"$R" host setup test public_port="$T_HTTP_PORT" ctl_ca=off > /dev/null 2>&1
t_done
