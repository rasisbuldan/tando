#!/bin/bash
# test/e2e-ease.sh: the ease-of-use commands (lib/cmd-go.sh, cmd-next.sh, cmd-link.sh, cmd-open.sh,
# cmd-ssh.sh, cmd-cheat.sh) on two bare servers (TANDO_TEST_BARE=1: systemd, sshd, a sudo user).
#   A (TANDO_TEST_NAME, default tando-ease1, 2274/8374): `tando go user@addr --domain --yes` from
#     the empty VM to a live link on a domain (tls internal, fake resolver), a re-run that changes
#     nothing, next/link/open/ssh/cheat, widths at 80 and 120 columns.
#   B (TANDO_TEST_NAME2, default tando-ease2, 2275/8375): the wizard on a pty (test/top-pty.py):
#     quit (q or Ctrl-C) at every screen leaves nothing on the server or in the project and the
#     next run resumes there; Enter-only answers; arrow keys and numbers pick other options; back
#     changes an earlier answer; DNS not pointing yet; Ctrl-C while waiting for DNS skips the
#     domain; 60 columns, TANDO_ASCII, TERM=dumb. Screens are kept in $E/screens.txt.
# Needs Docker, python3, network on the servers (apt, nodejs.org). bash 3.2 compatible.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
export TANDO_TEST_NAME=${TANDO_TEST_NAME:-tando-ease1} TANDO_TEST_SSH_PORT=${TANDO_TEST_SSH_PORT:-2274}
export TANDO_TEST_HTTP_PORT=${TANDO_TEST_HTTP_PORT:-8374}
t_init e2e-ease
N2=${TANDO_TEST_NAME2:-tando-ease2} P2=${TANDO_TEST_SSH_PORT2:-2275} H2=${TANDO_TEST_HTTP_PORT2:-8375}
PTY=$ROOT/test/top-pty.py
# shellcheck disable=SC2329 # used in check expressions
srvA() { "$SSH" "$@"; }
srvB() { TANDO_TEST_NAME=$N2 TANDO_TEST_SSH_PORT=$P2 "$SSH" "$@"; }
[ -f "$ROOT/lib/cmd-go.sh" ] || { echo "SKIP 0 lib/cmd-go.sh is not installed (docs/ease-integration.patch)"; t_done; }

for n in "$T_NAME" "$N2"; do
  if docker container inspect "$n" > /dev/null 2>&1 && [ "${TANDO_TEST_OWNED:-0}" != 1 ]; then
    echo "SKIP 0 $n exists and is not ours: the bare image needs a fresh container (TANDO_TEST_OWNED=1)"; t_done
  fi
done
for p in "$T_SSH_PORT" "$T_HTTP_PORT" "$P2" "$H2"; do
  docker ps --format '{{.Names}} {{.Ports}}' | grep ":$p->" | grep -qv -e "^$T_NAME " -e "^$N2 " &&
    { echo "SKIP 0 port $p is used by another container"; t_done; }
done
log "starting $T_NAME and $N2 from the bare image"
t0=$(date +%s)
export TANDO_TEST_BARE=1 TANDO_TEST_OWNED=1
"$ROOT/test/server/up.sh" --reset >&2 || exit 1
TANDO_TEST_NAME=$N2 TANDO_TEST_SSH_PORT=$P2 TANDO_TEST_HTTP_PORT=$H2 "$ROOT/test/server/up.sh" --reset >&2 || exit 1
unset TANDO_TEST_BARE
t_up=$(date +%s)
check "0a both servers are bare (no caddy, node, rsync, /opt/tando)" \
  eval 'srvA "! command -v caddy && ! command -v node && ! test -e /opt/tando" &&
        srvB "! command -v caddy && ! test -e /opt/tando"'
check "0b the client runs under macOS /bin/bash 3.2 ($(/bin/bash -c 'echo $BASH_VERSION'))" \
  eval '[ "$(head -1 "$R")" = "#!/bin/bash" ] &&
        case $(/bin/bash -c "echo \$BASH_VERSION") in 3.2.*) true;; *) [ "$(uname)" != Darwin ];; esac'

# ssh that counts its calls (for "one round trip"), and a short path to the test key
KD=$(mktemp -d /tmp/tando-ease.XXXXXX) || exit 1   # a short key path: commands are printed with it
trap 'rm -rf "$KD"' EXIT
mkdir -p "$E/bin"
printf '#!/bin/bash\necho x >> "%s/ssh.count"\nexec /usr/bin/ssh "$@"\n' "$E" > "$E/bin/ssh"; chmod +x "$E/bin/ssh"
cp "$ROOT/test/server/id_test" "$KD/id"; chmod 600 "$KD/id"
export PATH="$E/bin:$PATH"
nssh() { cat "$E/ssh.count" 2> /dev/null | wc -l | tr -d ' '; }

# ---- 1. one command from the empty VM to a live link on a domain (server A) ----------------------
W=$E/w; mkdir -p "$W"
cp -R "$ROOT/examples/hello" "$W/"; rm -f "$W/hello/tando.conf"
cd "$W/hello" || exit 1
export TANDO_TEST_RESOLVE="shop.test=127.0.0.1,www.shop.test=127.0.0.1"
COLUMNS=80 "$R" go vmadmin@127.0.0.1 --port "$T_SSH_PORT" --key "$KD/id" --insecure-test \
  public_port="$T_HTTP_PORT" domain_tls=internal --domain shop.test --yes > "$E/go1.out" 2>&1; rc=$?
t_live=$(date +%s); cat "$E/go1.out" >&2
# shellcheck disable=SC2034 # used in check expressions
ca=/var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt
check "1a go --yes: host add, host setup, init, up, domain add, each printed before it runs (rc=$rc)" \
  eval '[ $rc = 0 ] && [ "$(sed -n "s/^\[[0-9]\/5\] \$ tando \([a-z]*\).*/\1/p" "$E/go1.out" | tr "\n" ,)" = \
        host,host,init,up,domain, ]'
check "1b the app answers on its link and on https://shop.test" \
  eval 'curl -s "$(t_url hello)" | grep -q "hello v" &&
        srvA "sudo curl -s --cacert $ca --resolve shop.test:443:127.0.0.1 https://shop.test/" | grep -q "hello v"'
check "1c the Done screen gives the live link" grep -q "hello is live  https://shop.test" "$E/go1.out"
check "1d every line of go's output fits 80 columns" t_assert_width "$E/go1.out" 80
snap() { srvA 'sudo cksum /etc/caddy/Caddyfile /etc/caddy/tando/*.caddy /opt/tando/host.conf /opt/tando/apps/*/app.conf
  /opt/tando/apps/*/state; systemctl show -P ActiveEnterTimestampMonotonic caddy tando-hello'; }
snap > "$E/snap1"
s0=$(date +%s)
COLUMNS=120 "$R" go vmadmin@127.0.0.1 --port "$T_SSH_PORT" --key "$KD/id" --insecure-test \
  public_port="$T_HTTP_PORT" domain_tls=internal --domain shop.test --yes > "$E/go2.out" 2>&1; rc=$?
s1=$(date +%s); cat "$E/go2.out" >&2; snap > "$E/snap2"
check "1e go again: nothing to run, nothing changed on the server, $((s1 - s0)) s (rc=$rc)" \
  eval '[ $rc = 0 ] && ! grep -q "^\[1/" "$E/go2.out" && cmp -s "$E/snap1" "$E/snap2" && [ $((s1 - s0)) -le 15 ]'
check "1f go's output fits 120 columns" t_assert_width "$E/go2.out" 120
: > "$E/ssh.count"
"$R" next > "$E/next80.out" 2>&1; rc=$?; ns=$(nssh); cat "$E/next80.out" >&2
check "1g next: read-only, one ssh call ($ns), suggests alerts and CI, no domain item (rc=$rc)" \
  eval '[ $rc = 0 ] && [ "$ns" = 1 ] && grep -q "tando alerts notifier add phone ntfy" "$E/next80.out" &&
        grep -q "tando ci setup" "$E/next80.out" && ! grep -q "no domain" "$E/next80.out"'
COLUMNS=120 "$R" next > "$E/next120.out" 2>&1
COLUMNS=80 "$R" cheat > "$E/cheat80.out" 2>&1; COLUMNS=120 "$R" cheat > "$E/cheat120.out" 2>&1
check "1h next and cheat fit 80 and 120 columns" \
  eval 't_assert_width "$E/next80.out" 80 && t_assert_width "$E/next120.out" 120 &&
        t_assert_width "$E/cheat80.out" 80 && t_assert_width "$E/cheat120.out" 120 &&
        [ "$(grep -c "│   tando " "$E/cheat80.out")" = 12 ]'
: > "$E/ssh.count"
l=$("$R" link 2> /dev/null)
# shellcheck disable=SC2034 # used in the check expression
o=$(TANDO_NO_BROWSER=1 "$R" open 2> /dev/null)
ns=$(nssh)
check "1i link prints just the URL ($l), open prints it without a browser, one ssh call each ($ns)" \
  eval '[ "$l" = https://shop.test ] && [ "$o" = https://shop.test ] && [ "$ns" = 2 ]'
"$R" ssh hello < /dev/null > "$E/ssh.out" 2>&1
# shellcheck disable=SC2034 # used in the check expression
who=$("$R" ssh hello -- id -un < /dev/null 2> /dev/null)
# shellcheck disable=SC2034 # used in the check expression
who2=$("$R" ssh -- id -un < /dev/null 2> /dev/null)   # the app of this directory's tando.conf
check "1j ssh <app> -- cmd and ssh -- cmd run as the app's user ($who, $who2); no terminal: the one-shot form" \
  eval '[ "$who" = tando-hello ] && [ "$who2" = tando-hello ] &&
        grep -q "tando: an interactive shell needs a terminal; tando ssh hello -- <command> runs one command" "$E/ssh.out"'
printf 'data = data\nbackup = off\n' >> "$W/hello/tando.conf"
"$R" deploy > /dev/null 2>&1; "$R" next > "$E/next2.out" 2>&1
check "1k next after a second release with data and backup = off: rollback never tried, backups off" \
  eval 'grep -q "tando rollback" "$E/next2.out" && grep -q "has data but backups are off" "$E/next2.out"'
mkdir -p "$W/empty"; (cd "$W/empty" && TANDO_CONFIG_DIR=$E/cfg-none "$R" go --yes) > "$E/noaddr.out" 2>&1; rc=$?
check "1l go --yes without a server says how to give one (rc=$rc)" \
  eval '[ $rc != 0 ] && grep -q "tando go user@address --yes" "$E/noaddr.out"'
unset TANDO_TEST_RESOLVE

# ---- 2. the wizard on a pty (server B) ------------------------------------------------------------
export TANDO_CONFIG_DIR=$E/cfg2
mkdir -p "$E/home/.ssh" "$TANDO_CONFIG_DIR"
cp -R "$ROOT/examples/site" "$W/"; rm -f "$W/site/tando.conf"
cd "$W/site" || exit 1
FL=(--port "$P2" --key "$KD/id" --insecure-test public_port="$H2")
SCR=$E/screens.txt; : > "$SCR"
# pty <name> <cols> <script lines...>: run the wizard on a 24-row pty; output in $E/pty.<name>
pty() {
  local name=$1 cols=$2; shift 2
  printf '%s\n' "$@" > "$E/pty.$name.script"
  HOME=$E/home python3 "$PTY" 24 "$cols" "$E/pty.$name.script" -- \
    "$R" go ${PTARGS[@]+"${PTARGS[@]}"} "${FL[@]}" > "$E/pty.$name" 2>&1
  awk '/^=== /,/^=== end/' "$E/pty.$name" | grep -v '^ *$' >> "$SCR"
}
final() { sed -n 's/^final: exit=\([0-9]*\) cursor=\([a-z]*\) altscreen=\([a-z]*\).*/\1 \2 \3/p' "$E/pty.$1"; }
# shellcheck disable=SC2329 # used in check expressions
untouched() { # nothing registered, written or installed
  [ -z "$(ls "$TANDO_CONFIG_DIR/hosts" 2> /dev/null)" ] && [ ! -e tando.conf ] && [ ! -e .tando ] &&
    srvB '! test -e /opt/tando && ! test -e /etc/caddy'
}
ENTER='send \r' DOWN='send \e[B'
PTARGS=()
pty q1 80 'wait Step 1 of 8' 'dump 1 Server: address' 'send q' 'exit 5'
check "2a quit (q) at Server: terminal restored, nothing anywhere ($(final q1))" \
  eval '[ "$(final q1)" = "0 visible off" ] && untouched'
# (wait for the options, not the title: a frame can arrive in two reads, and a dump between them
# showed the new title over the old Server screen)
pty q2 80 'wait Step 1 of 8' 'send-raw vmadmin@127.0.0.1' "$ENTER" 'wait Install everything 20' 'dump 2 Setup' \
  'send \x03' 'exit 5'
check "2b typed address, Ctrl-C at Setup: nothing anywhere ($(final q2))" \
  eval '[ "$(final q2)" = "130 visible off" ] && untouched && grep -q "Install everything (recommended)" "$E/pty.q2"'
pty q3 80 'wait Step 2 of 8 20' "$ENTER" 'wait Step 3 of 8' 'dump 3 App' 'send q' 'exit 5'
check "2c resumed at Setup, Enter, q at App: nothing anywhere" eval '[ "$(final q3)" = "0 visible off" ] && untouched'
# App: arrow down to the name, type web1; Link: back (left arrow) to App, 2 picks the name: web2
pty q4 80 'wait Step 3 of 8 20' "$DOWN" "$ENTER" 'wait Name \(a-z' 'send-raw web1' 'dump 3b App: name' "$ENTER" \
  'wait Name +web1' "$ENTER" 'wait Step 4 of 8' 'send \e[D' 'wait Name +web1' 'send 2' "$ENTER" 'wait Name \(a-z' \
  'send-raw web2' "$ENTER" 'wait Name +web2' "$ENTER" 'wait Step 4 of 8' 'dump 4 Link' 'send \x03' 'exit 5'
check "2d arrow and number keys pick the name row; back from Link changes web1 to web2; Ctrl-C: nothing" \
  eval '[ "$(final q4)" = "130 visible off" ] && untouched && grep -q "^name=web2$" "$TANDO_CONFIG_DIR"/go/*'
export TANDO_TEST_RESOLVE="shop.test=203.0.113.9"
pty q5 80 'wait Step 4 of 8 20' "$DOWN" "$ENTER" 'wait Your domain' 'send-raw shop.test' 'dump 4b Link: domain' \
  "$ENTER" 'wait And www.shop.test' 'dump 4c Link: www' "$ENTER" 'wait does not point at this server' \
  'dump 4d Link: DNS' "$DOWN" "$DOWN" "$ENTER" 'wait Step 5 of 8' 'dump 5 Extras' \
  "$ENTER" 'wait Step 6 of 8 20' 'dump 6 Review' 'send q' 'exit 5'
check "2e own domain, DNS points elsewhere: the exact record and wait/skip; skip; q at Review: nothing anywhere" \
  eval '[ "$(final q5)" = "0 visible off" ] && untouched &&
        grep -qE "A +shop.test +-> +[0-9.]+ +\(now 203.0.113.9\)" "$E/pty.q5" &&
        grep -q "tando.conf: app = web2" "$E/pty.q5" && ! grep -qE "│ +tando domain add" "$E/pty.q5"'
pty narrow 60 'wait Step 6 of 8 20' 'check' 'dump 6 Review at 60 columns' 'send q' 'exit 5'
check "2f 60 columns: the resumed Review fits, nothing past the edge" \
  eval '[ "$(final narrow)" = "0 visible off" ] && ! grep -q OVERFLOW "$E/pty.narrow" &&
        grep -q "Step 6 of 8" "$E/pty.narrow"'
TANDO_ASCII=1 NO_COLOR=1 pty ascii 80 'wait Step 6 of 8 20' 'dump 6 Review, TANDO_ASCII=1' 'send q' 'exit 5'
check "2g TANDO_ASCII=1 NO_COLOR=1: ASCII borders, no colour" \
  eval 'grep -q "^+- tando go" "$E/pty.ascii" && ! grep -q "╭" "$E/pty.ascii" && untouched'
TOP_TERM=dumb pty dumb 80 'wait Choice \[1\] 20' 'dump 6 Review with TERM=dumb' 'send q\r' 'exit 5'
check "2h TERM=dumb: numbered prompts instead of screens" \
  eval '[ "$(final dumb | cut -d" " -f1)" = 0 ] && untouched &&
        grep -q "Choice \[1\] (1-2, b back, s skip, q quit)" "$E/pty.dumb"'
pty run 80 'wait Step 6 of 8 20' "$ENTER" 'wait Step 8 of 8 420' 'wait tando next: every suggestion 10' 'dump 8 Done' 'exit 30'
check "2i Enter at Review runs it: host add, host setup, init, app = web2, up; live ($(final run))" \
  eval '[ "$(final run | cut -d" " -f1)" = 0 ] && curl -s "http://web2.localhost:$H2/" | grep -qi "<html" &&
        grep -q "^app = web2" tando.conf && grep -q "web2 is live" "$E/pty.run"'
check "2j the Done screen offers the domain that was skipped" grep -q "tando domain add shop.test" "$E/pty.run"
# a domain whose DNS never comes: --wait, Ctrl-C skips it and the run still ends on Done
PTARGS=(--domain late.test --dns wait --yes)
pty wait 80 'wait waiting for DNS 30' 'sleep 1' 'send \x03' 'wait Step 8 of 8 30' 'wait tando next: every suggestion 10' \
  'dump 8b Done after Ctrl-C while waiting for DNS' 'exit 10'
PTARGS=()
check "2k Ctrl-C while waiting for DNS skips the domain; Done says how to add it later ($(final wait))" \
  eval '[ "$(final wait | cut -d" " -f1)" = 0 ] &&
        grep -q "skipped; when DNS is ready: tando domain add late.test" "$E/pty.wait"'
pty again 80 'wait Step 8 of 8 30' 'wait tando next: every suggestion 10' 'exit 10'
check "2l the wizard again after Done: no screens, nothing to run, straight to Done" \
  eval '[ "$(final again | cut -d" " -f1)" = 0 ] && ! grep -q "Step 6 of 8" "$E/pty.again" &&
        ! grep -q "^\[1/" "$E/pty.again"'
unset TANDO_TEST_RESOLVE

# every screen left idle for 3 s first (bash 3.2: a key read that times out must not end the
# wizard); a registered server is preselected; Enter only, from Server to Done
cp -R "$ROOT/examples/site" "$W/idle"; rm -f "$W/idle/tando.conf"; cd "$W/idle" || exit 1
IDLE=('wait Step 1 of 8 20' 'sleep 3' 'dump 1 Server: registered')
for n in 2 3 4 5 6; do IDLE+=("$ENTER" "wait Step $n of 8 30" 'sleep 3'); done
pty idle 80 "${IDLE[@]}" "$ENTER" 'wait Step 8 of 8 120' 'wait tando next: every suggestion 10' 'dump 8c Done after idle screens' 'exit 10'
check "2m each screen idle 3 s under /bin/bash, the registered server preselected, Enter only: live" \
  eval '[ "$(final idle | cut -d" " -f1)" = 0 ] && grep -q "❯ 1  prod .*(recommended)" "$E/pty.idle" &&
        grep -q "idle is live" "$E/pty.idle" && curl -s "http://idle.localhost:$H2/" | grep -qi "<html"'
echo "INFO empty VM to a live link with tando go: $((t_live - t_up)) s (servers started in $((t_up - t0)) s)"
t_done
