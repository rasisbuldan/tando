#!/bin/bash
# test/menubar-test.sh: the macOS menu bar app (macos/menubar, lib/cmd-menubar.sh) without a server
# and without touching the user's ~/Applications or LaunchAgents: HOME is a temp directory and
# launchctl is never called. Run by test/ui-test.sh (and on its own); bash 3.2 compatible.
#
#   test/menubar-test.sh [tando-root]     (default: this checkout; install-test passes an installed tree)
#
# - `ls --all --json` lists the alerts (a stub ssh answers the agent's status with canned rows)
# - the app compiles with swiftc, is a signed LSUIElement bundle (tando menubar build)
# - the badge and notification logic on canned JSON (test/menubar-model.swift, test/fixtures/menubar)
# - the dashboard window's logic (test/menubar-dash-model.swift): dash.lock, stale lock, the launch
#   decision tree, the address policy, the shared cache's freshness
# - tando-dash's ls-all.json cache is used when fresh, not when old (--once "source:" line)
# - "Open dashboard" without the window (--dash-url): not installed; starts the real tando-dash,
#   gets a one-time link that works once; reuses the running one (new link, same pid); a crashed
#   one (stale lock) is replaced
# - the app's --once mode against the real CLI and the stub ssh: badge, rows, link probes
# - install --dry-run changes nothing; install, status, uninstall in the temp HOME
# One line per check (PASS/FAIL/SKIP); the last line is "menubar: <n> checks, <m> failed".
# shellcheck disable=SC2034  # APP, grey, dry, PL, st: read by the eval'd checks
set -u
here=$(cd "$(dirname "$0")/.." && pwd -P)
R=${1:-$here}
T=$(mktemp -d "${TMPDIR:-/tmp}/menubar-test.XXXXXX") || exit 2
SRVPID=""
dashkill() { # stop a tando-dash this test started (its pid is in the temp dash.lock)
  local p; p=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$T/cfg/dash.lock" 2> /dev/null | head -1)
  [ -z "$p" ] || kill "$p" 2> /dev/null
}
trap 'dashkill; [ -z "$SRVPID" ] || { kill "$SRVPID"; wait "$SRVPID"; } 2> /dev/null; rm -rf "$T"' EXIT
n=0 nf=0
ok() { n=$((n + 1)); echo "PASS menubar $1"; }
bad() { n=$((n + 1)); nf=$((nf + 1)); echo "FAIL menubar $1"; }
check() { local t=$1; shift; if "$@"; then ok "$t"; else bad "$t"; fi; }
finish() { echo "menubar: $n checks, $nf failed"; exit 0; }

export HOME=$T/home TANDO_CONFIG_DIR=$T/cfg TANDO_MENUBAR_NO_LAUNCHCTL=1 TANDO_NO_BROWSER=1 NO_COLOR=1
mkdir -p "$HOME" "$TANDO_CONFIG_DIR/hosts" "$T/bin"

# ---- ls --all --json with alerts: a stub ssh answers `tando-agent status` -----------------------
# app rows: r a state port rel rst mem max cpu rs up link recipe bk last db lb lcap lines hourly doms lcpu ltasks lconns lreq lx
PORT=1   # replaced below when a local web server runs
stub() {
  cat > "$T/bin/ssh" << EOF
#!/bin/bash
case "\$*" in
  *" -O "*|*" -O"*) exit 0;;
  *"tando-agent status"*)
    printf 'app\tweb\tactive\t3000\t20261120-101010\tverified\t1000\t0\t0\t0\t100\thttp://127.0.0.1:$PORT/\tnode\toff\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\n'
    printf 'app\tapi\tinactive\t3001\t20261120-101010\tverified\t0\t0\t0\t3\t0\thttp://127.0.0.1:1/\tnode\toff\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\n'
    printf 'app\tdead\tactive\t3002\t20261120-101010\tverified\t0\t0\t0\t0\t9\thttp://127.0.0.1:1/\tnode\toff\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\n'
    printf 'alert\tapi\tdown\tfiring\t1795000000\texited\n'
    printf 'alert\thost\tdisk\tpending\t1795000000\t85%% used\n'
    exit 0;;
esac
echo "ssh: connect to host 127.0.0.1 port 9: Connection refused" >&2; exit 255
EOF
  chmod +x "$T/bin/ssh"
}
stub
printf 'target=nobody@127.0.0.1\nport=9\nkey=\ninsecure=1\nkind=admin\n' > "$TANDO_CONFIG_DIR/hosts/vps"
out=$(PATH=$T/bin:$PATH "$R/bin/tando" ls --all --json 2> "$T/ls.err")
check "L1 ls --all --json lists the host's alerts (firing and pending)" \
  eval 'printf "%s" "$out" | grep -q "\"alerts\":\[{\"app\":\"api\",\"check\":\"down\",\"state\":\"firing\",\"since\":1795000000,\"detail\":\"exited\"},{\"app\":\"host\",\"check\":\"disk\",\"state\":\"pending\""'
check "L2 ls --all --json is one JSON object" \
  eval 'printf "%s" "$out" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d[\"hosts\"][0][\"apps\"][1][\"state\"] == \"down\""'
[ -z "$out" ] && sed 's/^/    /' "$T/ls.err"

# ---- the app: build, logic, --once --------------------------------------------------------------
if [ "$(uname)" != Darwin ]; then echo "SKIP menubar the app is macOS only"; finish; fi
if ! command -v swiftc > /dev/null 2>&1; then echo "SKIP menubar swiftc not found (xcode-select --install)"; finish; fi

"$R/bin/tando" menubar build --out "$T/out" > "$T/build.log" 2>&1
APP=$T/out/tando.app BIN=$T/out/tando.app/Contents/MacOS/tando-menubar
check "B1 tando menubar build compiles the app with swiftc" test -x "$BIN"
# (the Terminal items open a live view: a one-shot print went stale while the window stayed open)
check "B1b the menu's Terminal commands are live views (ls --all and status, status now followed)" eval \
  'grep -q "\"ls\", \"--all\", \"--watch\", \"5\"" "$R/macos/menubar/main.swift" &&
   grep -q "\"status\", a.name, \"-H\", h.name, \"--follow\"" "$R/macos/menubar/main.swift"'
[ -x "$BIN" ] || sed 's/^/    /' "$T/build.log"
check "B2 the bundle is a menu bar app (LSUIElement, no Dock icon) with a valid Info.plist" \
  eval 'plutil -lint "$APP/Contents/Info.plist" > /dev/null && grep -A0 "<key>LSUIElement</key><true/>" "$APP/Contents/Info.plist" > /dev/null'
check "B3 the bundle is signed ad hoc" eval 'codesign -v "$APP" 2> /dev/null && codesign -dv "$APP" 2>&1 | grep -q "Signature=adhoc"'

mkdir -p "$T/mt"
cp "$here/test/menubar-model.swift" "$T/mt/main.swift"
if swiftc -swift-version 5 -o "$T/mt/model-test" "$R/macos/menubar/Model.swift" "$T/mt/main.swift" > "$T/mt/err" 2>&1; then
  "$T/mt/model-test" "$here/test/fixtures/menubar" > "$T/mt/out" 2>&1
  while IFS= read -r l; do
    case $l in PASS\ *) ok "${l#PASS }";; FAIL\ *) bad "${l#FAIL }";; esac
  done < "$T/mt/out"
  grep -q '^model: 0 failed$' "$T/mt/out" || grep -q '^FAIL' "$T/mt/out" || bad "M0 the model test did not finish: $(tail -2 "$T/mt/out")"
else
  bad "M0 the model test does not compile"; sed 's/^/    /' "$T/mt/err" | head -20
fi

mkdir -p "$T/dm"
cp "$here/test/menubar-dash-model.swift" "$T/dm/main.swift"
if swiftc -swift-version 5 -o "$T/dm/dash-model-test" "$R/macos/menubar/DashModel.swift" "$T/dm/main.swift" > "$T/dm/err" 2>&1; then
  "$T/dm/dash-model-test" > "$T/dm/out" 2>&1
  while IFS= read -r l; do
    case $l in PASS\ *) ok "${l#PASS }";; FAIL\ *) bad "${l#FAIL }";; esac
  done < "$T/dm/out"
  grep -q '^dash model: 0 failed$' "$T/dm/out" || grep -q '^FAIL' "$T/dm/out" || bad "M0d the dashboard model test did not finish: $(tail -2 "$T/dm/out")"
else
  bad "M0d the dashboard model test does not compile"; sed 's/^/    /' "$T/dm/err" | head -20
fi

# a local web server for the link that answers (the others point at a closed port)
if command -v python3 > /dev/null 2>&1; then
  mkdir -p "$T/www" && echo hi > "$T/www/index.html"
  python3 -I -c 'import http.server,socketserver,sys,os
os.chdir(sys.argv[1])
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
s = socketserver.TCPServer(("127.0.0.1", 0), Q)
open(sys.argv[2] + ".tmp", "w").write(str(s.server_address[1])); os.rename(sys.argv[2] + ".tmp", sys.argv[2])
s.serve_forever()' "$T/www" "$T/port" &
  SRVPID=$!
  i=0; while [ ! -s "$T/port" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$T/port" ] && PORT=$(cat "$T/port") && stub
fi
once=$(PATH=$T/bin:/usr/bin:/bin "$BIN" --once --checks 2 --tando "$R/bin/tando" 2>&1); rc=$?
printf '%s\n' "$once" > "$T/once"
check "O1 --once runs the installed tando and exits 0 (rc=$rc)" test "$rc" = 0
check "O2 badge counts the down app (api, with its firing alert) and the app whose link fails (dead): 2" \
  grep -qx 'badge: 2' "$T/once"
check "O3 the menu lists the host and each app with its state" \
  eval 'grep -q "^host vps$" "$T/once" && grep -q "^  api  down  PROBLEM: down" "$T/once" && grep -q "^  dead  running  PROBLEM: link fails" "$T/once"'
if [ "$PORT" != 1 ]; then
  check "O4 the app whose link answers has no problem" grep -q "^  web  running  http://127.0.0.1:$PORT/" "$T/once"
else echo "SKIP menubar O4 no python3 for a local web server"; fi
check "O5 the firing alert is listed, the pending one is not" \
  eval 'grep -q "^alert vps: api down (exited)" "$T/once" && ! grep -q "disk" "$T/once"'
check "O6 notifications: the down app and its alert at once, the failing link on the second check" \
  eval 'grep -q "^notify: tando: problem: vps: api is down" "$T/once" && grep -q "^notify: tando: problem: vps: dead does not answer" "$T/once"'
[ "$nf" = 0 ] || sed 's/^/    /' "$T/once"

grey=$(PATH=/usr/bin:/bin "$BIN" --once --tando "$T/nope" 2>&1); rc=$?
check "O7 no tando to run: grey, says so, exits 1" eval 'test $rc = 1 && printf "%s" "$grey" | grep -q "^badge: grey (tando not found"'
printf '#!/bin/bash\nexec sleep 30\n' > "$T/slow"; chmod +x "$T/slow"
s0=$SECONDS
grey=$("$BIN" --once --tando "$T/slow" --timeout 5 2>&1); rc=$?
check "O8 a tando that hangs is stopped at the timeout: grey (took $((SECONDS - s0)) s)" \
  eval 'test $rc = 1 && test $((SECONDS - s0)) -lt 15 && printf "%s" "$grey" | grep -q "did not answer within 5 s"'

# ---- the shared cache: fresh is used, old is not -------------------------------------------------
mkdir -p "$TANDO_CONFIG_DIR/cache"
printf '{"hosts":[{"host":"cachehost","apps":[{"app":"cachedapp","state":"running","link":null}],"alerts":[]}],"source":"tando-dash"}\n' > "$TANDO_CONFIG_DIR/cache/ls-all.json"
c1=$(PATH=$T/bin:/usr/bin:/bin "$BIN" --once --interval 60 --tando "$R/bin/tando" 2>&1)
check "C1 a fresh ls-all.json is used instead of tando ls: source cache, its host and app listed" \
  eval 'printf "%s" "$c1" | grep -qx "source: cache" && printf "%s" "$c1" | grep -q "^host cachehost$" && printf "%s" "$c1" | grep -q "^  cachedapp  running" && ! printf "%s" "$c1" | grep -q "^host vps$"'
touch -t 202001010000 "$TANDO_CONFIG_DIR/cache/ls-all.json"
c2=$(PATH=$T/bin:/usr/bin:/bin "$BIN" --once --interval 60 --tando "$R/bin/tando" 2>&1)
check "C2 an old ls-all.json is not used: tando ls runs (source tando, host vps)" \
  eval 'printf "%s" "$c2" | grep -qx "source: tando" && printf "%s" "$c2" | grep -q "^host vps$"'
printf 'not json' > "$TANDO_CONFIG_DIR/cache/ls-all.json"
c3=$(PATH=$T/bin:/usr/bin:/bin "$BIN" --once --interval 60 --tando "$R/bin/tando" 2>&1)
check "C3 a fresh but broken ls-all.json falls back to tando ls" eval 'printf "%s" "$c3" | grep -q "^host vps$"'
rm -f "$TANDO_CONFIG_DIR/cache/ls-all.json"

# ---- Open dashboard without the window (--dash-url) ------------------------------------------------
if [ -e /usr/local/bin/tando-dash ] || [ -e /opt/homebrew/bin/tando-dash ]; then
  echo "SKIP menubar W1 a tando-dash is installed in /usr/local/bin or /opt/homebrew/bin"
else
  w=$(PATH=/usr/bin:/bin "$BIN" --dash-url --tando "$R/bin/tando" 2>&1); rc=$?
  check "W1 add-on not installed: says so with the one command, exit 1" \
    eval 'test $rc = 1 && printf "%s" "$w" | grep -qx "dash: not installed (tando addon install dashboard)"'
fi
if ! command -v go > /dev/null 2>&1; then echo "SKIP menubar W2 Go is not installed: no tando-dash to start"
else
  mkdir -p "$HOME/.local/bin"
  (cd "$R/addons/dashboard/server" && GOTOOLCHAIN=local go build -trimpath -o "$HOME/.local/bin/tando-dash" . ) > "$T/godash.log" 2>&1
  if [ ! -x "$HOME/.local/bin/tando-dash" ]; then bad "W2 tando-dash did not build"; sed 's/^/    /' "$T/godash.log" | head
  else
    w1=$(PATH=/usr/bin:/bin "$BIN" --dash-url --tando "$R/bin/tando" 2>&1); rc=$?
    u1=$(printf '%s\n' "$w1" | sed -n 's/^dash: open //p')
    p1=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$TANDO_CONFIG_DIR/dash.lock" | head -1)
    check "W2 no tando-dash running: it is started and a one-time link is printed (rc=$rc)" \
      eval 'test $rc = 0 && case $u1 in http://127.0.0.1:*/open\?code=*) true;; *) false;; esac && test -n "$p1" && kill -0 "$p1"'
    code1=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u1")
    code1b=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u1")
    check "W3 the link works once: 303 the first time, refused the second ($code1, $code1b)" eval 'test "$code1" = 303 && test "$code1b" != 303'
    w2=$(PATH=/usr/bin:/bin "$BIN" --dash-url --tando "$R/bin/tando" 2>&1)
    u2=$(printf '%s\n' "$w2" | sed -n 's/^dash: open //p')
    p2=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$TANDO_CONFIG_DIR/dash.lock" | head -1)
    code2=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u2")
    check "W4 one runs: it is asked for a fresh link (same pid, new link that works: $code2)" \
      eval 'test -n "$u2" && test "$p2" = "$p1" && test "$u2" != "$u1" && test "$code2" = 303'
    kill -9 "$p1" 2> /dev/null
    t_wait=0; while kill -0 "$p1" 2> /dev/null && [ $t_wait -lt 50 ]; do sleep 0.1; t_wait=$((t_wait + 1)); done
    check "W5 the crashed tando-dash left its lock behind (a stale lock)" test -s "$TANDO_CONFIG_DIR/dash.lock"
    w3=$(PATH=/usr/bin:/bin "$BIN" --dash-url --tando "$R/bin/tando" 2>&1)
    u3=$(printf '%s\n' "$w3" | sed -n 's/^dash: open //p')
    p3=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$TANDO_CONFIG_DIR/dash.lock" | head -1)
    code3=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$u3")
    check "W6 a stale lock (dead pid) is not asked: a new tando-dash starts (pid $p1 -> $p3) and its link works ($code3)" \
      eval 'test -n "$u3" && test -n "$p3" && test "$p3" != "$p1" && kill -0 "$p3" && test "$code3" = 303'
    dashkill
  fi
fi

# ---- install, status, uninstall in the temp HOME (launchctl not called) -------------------------
dry=$("$R/bin/tando" menubar install --dry-run 2>&1); rc=$?
check "I1 install --dry-run prints the app, the settings and the LaunchAgent it would create" \
  eval 'test $rc = 0 && printf "%s" "$dry" | grep -q "create  $HOME/Applications/tando.app" &&
        printf "%s" "$dry" | grep -q "LaunchAgents/local.tando.menubar.plist" && printf "%s" "$dry" | grep -q "Nothing was changed"'
check "I2 install --dry-run creates nothing" \
  eval 'test ! -e "$HOME/Applications/tando.app" && test ! -e "$HOME/Library/LaunchAgents/local.tando.menubar.plist" && test ! -e "$TANDO_CONFIG_DIR/menubar.conf"'
"$R/bin/tando" menubar install > "$T/inst.log" 2>&1; rc=$?
PL=$HOME/Library/LaunchAgents/local.tando.menubar.plist
check "I3 install builds ~/Applications/tando.app and a RunAtLoad LaunchAgent (rc=$rc)" \
  eval 'test -x "$HOME/Applications/tando.app/Contents/MacOS/tando-menubar" && plutil -lint "$PL" > /dev/null &&
        grep -q "<key>RunAtLoad</key><true/>" "$PL"'
check "I4 install records the tando launcher the app runs" grep -qx "tando=$R/bin/tando" "$TANDO_CONFIG_DIR/menubar.conf"
st=$("$R/bin/tando" menubar status 2>&1)
check "I5 status shows the app and its settings" eval 'printf "%s" "$st" | grep -q "every *60 s, timeout 45 s"'
printf 'interval=120\n' >> "$TANDO_CONFIG_DIR/menubar.conf"
"$R/bin/tando" menubar install > /dev/null 2>&1
check "I6 a second install keeps the user's settings" eval 'grep -qx "interval=120" "$TANDO_CONFIG_DIR/menubar.conf" && test "$(grep -c "^tando=" "$TANDO_CONFIG_DIR/menubar.conf")" = 1'
"$R/bin/tando" menubar uninstall > "$T/un.log" 2>&1
check "I7 uninstall removes the app, the LaunchAgent and the settings" \
  eval 'test ! -e "$HOME/Applications/tando.app" && test ! -e "$PL" && test ! -e "$TANDO_CONFIG_DIR/menubar.conf"'
finish
