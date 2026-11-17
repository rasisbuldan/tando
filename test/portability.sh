#!/bin/bash
# test/portability.sh: prove the laptop side on the shells and tools it will meet.
#
#   test/portability.sh               every part below that can run here
#   test/portability.sh mac debian    only these parts (mac, debian, linux, busybox)
#   --keep                            leave the test server running
#
#   mac      macOS /bin/bash 3.2: `bash -n` on every laptop-side file, test/ui-test.sh, and the
#            local commands (help, init on each example, host add/ls) under /bin/bash.
#   debian   debian:stable-slim (bash 5.2, mawk, GNU coreutils, perl-base without Time::HiRes):
#            `bash -n`, test/ui-test.sh, local commands, the clock/since helpers.
#   linux    a Linux client (the test server image: bash 5.3, GNU tools, rsync 3.4, OpenSSH):
#            host setup, a full deploy of examples/hello and a redeploy against a test server,
#            then every read-only command. This is what a GitHub Linux runner does.
#   busybox  the same client with BusyBox 1.37 (from alpine:3.22) in front of the GNU tools and
#            perl removed, as on Alpine; bash, ssh, rsync and curl stay (tando needs them).
#
# Each client command runs with an xtrace on fd 9, so an error printed by a tool ("illegal option",
# "invalid option", "not found", "unbound variable", ...) is reported with the file:line of the tando
# code that ran it: "INCOMPAT <part> <file>:<line> <command>: <error>".
# The server is ${TANDO_PORTA_NAME:-tando-test-q3} on ${TANDO_PORTA_SSH:-2313}/${TANDO_PORTA_HTTP:-8313}
# (or TANDO_TEST_NAME / _SSH_PORT / _HTTP_PORT when test/all.sh sets them); the Linux clients
# reach it on the Docker network, by its container address.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
cd "$ROOT" || exit 2
NAME=${TANDO_TEST_NAME:-${TANDO_PORTA_NAME:-tando-test-q3}}
SSHP=${TANDO_TEST_SSH_PORT:-${TANDO_PORTA_SSH:-2313}}
HTTPP=${TANDO_TEST_HTTP_PORT:-${TANDO_PORTA_HTTP:-8313}}
DEBIAN_IMG=${TANDO_PORTA_DEBIAN:-debian:stable-slim}
ALPINE_IMG=${TANDO_PORTA_ALPINE:-alpine:3.22}
CLIENT_IMG=${TANDO_PORTA_CLIENT:-tando-testvm:latest}
PASSN=0 FAILN=0 INCOMPAT=0 keep=0 parts=""

for a in "$@"; do
  case $a in
    --keep) keep=1;;
    mac|debian|linux|busybox) parts="$parts $a";;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    *) echo "portability: unknown argument $a" >&2; exit 2;;
  esac
done
[ -n "$parts" ] || parts=" mac debian linux busybox"
want() { case " $parts " in *" $1 "*) return 0;; esac; return 1; }

E=${T_WORK:-$ROOT/test/.portability}
rm -rf "${E:?}"
mkdir -p "$E"
pass() { PASSN=$((PASSN + 1)); echo "PASS $*"; }
fail() { FAILN=$((FAILN + 1)); echo "FAIL $*"; }
check() { local n=$1; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
log() { echo "---- $*" >&2; }
# the test server (mac's host add and the Linux clients use it); created=1 when this run made it
created=0 server_ready=0
server_up() {
  [ "$server_ready" = 1 ] && return 0
  log "test server $NAME ($SSHP/$HTTPP)"
  docker container inspect "$NAME" > /dev/null 2>&1 || created=1
  TANDO_TEST_NAME=$NAME TANDO_TEST_SSH_PORT=$SSHP TANDO_TEST_HTTP_PORT=$HTTPP \
    "$ROOT/test/server/up.sh" > "$E/up.out" 2>&1 || { cat "$E/up.out"; exit 2; }
  server_ready=1
}

laptop_files() { /bin/bash "$ROOT/test/lint.sh" --list | awk '$1 == "laptop" && $2 == "bash" { print $3 }'; }
laptop_files > "$E/files"

# collect INCOMPAT lines from a part's output
incompat() { # file
  local n
  n=$(grep -c '^INCOMPAT' "$1")
  INCOMPAT=$((INCOMPAT + n))
  grep '^INCOMPAT' "$1"
  return 0
}

# ---- mac ----------------------------------------------------------------------------------------

if want mac; then
  if [ "$(uname)" != Darwin ]; then
    echo "SKIP mac: not macOS"
  else
    log "macOS $(sw_vers -productVersion 2> /dev/null), /bin/bash $(/bin/bash -c 'echo $BASH_VERSION')"
    bad=""
    while IFS= read -r f; do
      /bin/bash -n "$f" 2> "$E/n.err" || { bad="$bad $f"; sed 's/^/INCOMPAT mac /' "$E/n.err"; }
    done < "$E/files"
    check "M1 /bin/bash -n on $(wc -l < "$E/files" | tr -d ' ') laptop-side files${bad:+ (failed:$bad)}" test -z "$bad"
    BASH_BIN=/bin/bash /bin/bash test/ui-test.sh > "$E/ui-mac.out" 2>&1
    check "M2 test/ui-test.sh under /bin/bash 3.2 ($(tail -1 "$E/ui-mac.out"))" test $? = 0
    # local commands: help, init on every example; host add (logs in to the test server)
    # (no Docker, as on GitHub's macOS runners: no test server, so host add is skipped)
    have_srv=0
    if docker info > /dev/null 2>&1; then server_up; have_srv=1; else echo "SKIP M3 host add: no Docker here"; fi
    (
      export TANDO_CONFIG_DIR=$E/mac-cfg TANDO_COLOR=never
      /bin/bash bin/tando help > "$E/help.out" 2>&1 || exit 1
      for ex in hello site next notes; do
        [ -d "examples/$ex" ] || continue
        mkdir -p "$E/mac/$ex"
        (cd "examples/$ex" && tar --exclude=node_modules --exclude=.next -cf - .) | tar -xf - -C "$E/mac/$ex"
        rm -f "$E/mac/$ex/tando.conf"
        # init either writes tando.conf or refuses with its own message; both platforms must agree
        (cd "$E/mac/$ex" && /bin/bash "$ROOT/bin/tando" init) > "$E/init-$ex.out" 2>&1
        { echo "rc=$?"; cat "$E/mac/$ex/tando.conf" 2> /dev/null; } > "$E/init-$ex.mac"
      done
      [ "$have_srv" = 1 ] || exit 0
      /bin/bash bin/tando host add t vmadmin@127.0.0.1 --port "$SSHP" --key "$ROOT/test/server/id_test" \
        --yes > /dev/null 2>&1 || exit 1   # the real path: host key shown and trusted
      [ -f "$E/mac-cfg/hosts/t" ] && [ -s "$E/mac-cfg/known_hosts" ]
    ) 2> "$E/mac-local.err"
    check "M3 help, init on every example (written or refused), host add under /bin/bash" test $? = 0
    grep -hiE 'illegal option|invalid option|unbound variable|bad substitution|command not found|syntax error' \
      "$E"/*.out "$E/mac-local.err" 2> /dev/null | sed 's/^/INCOMPAT mac /'
  fi
fi

# ---- debian -------------------------------------------------------------------------------------

if want debian; then
  log "debian: $DEBIAN_IMG"
  docker image inspect "$DEBIAN_IMG" > /dev/null 2>&1 || docker pull -q "$DEBIAN_IMG" > /dev/null
  docker run --rm -v "$ROOT:/tando:ro" -v "$E:/e:ro" -e LC_ALL=C.UTF-8 "$DEBIAN_IMG" bash -c 'set -u
    cd /tando
    echo "bash $BASH_VERSION, awk $(readlink -f "$(command -v awk)")"
    bad=""
    while IFS= read -r f; do
      bash -n "$f" 2>/tmp/e || { bad="$bad $f"; sed "s/^/INCOMPAT debian /" /tmp/e; }
    done < /e/files
    [ -z "$bad" ] && echo "PASS D1 bash -n on every laptop-side file" || echo "FAIL D1 bash -n:$bad"
    if BASH_BIN=bash bash test/ui-test.sh > /tmp/ui.out 2>&1; then echo "PASS D2 ui-test.sh ($(tail -1 /tmp/ui.out))"
    else echo "FAIL D2 ui-test.sh"; grep -m5 FAIL /tmp/ui.out; fi
    export TANDO_CONFIG_DIR=/tmp/cfg TANDO_COLOR=never
    bash bin/tando help > /tmp/h 2>&1 && echo "PASS D3 tando help" || { echo "FAIL D3 tando help"; head -3 /tmp/h; }
    for ex in hello site next notes; do
      [ -d examples/$ex ] || continue
      mkdir -p /tmp/w/$ex
      (cd examples/$ex && tar --exclude=node_modules --exclude=.next -cf - .) | tar -xf - -C /tmp/w/$ex
      rm -f /tmp/w/$ex/tando.conf
      (cd /tmp/w/$ex && bash /tando/bin/tando init) > /tmp/init 2>&1
      { echo "rc=$?"; cat /tmp/w/$ex/tando.conf 2> /dev/null; } | sed "s/^/INIT $ex /"
    done
    # clock/since from lib/common.sh: tenths of a second via perl Time::HiRes, else whole seconds
    out=$(bash -c ". lib/ui.sh; . lib/common.sh; t=\$(clock); since \"\$t\"" 2>&1)
    case $out in [0-9]*.[0-9]) echo "PASS D5 clock/since give seconds ($out)";;
      *) echo "FAIL D5 clock/since: [$(echo "$out" | head -1 | cut -c1-60)]"
         l=$(grep -n "clock() { perl" lib/common.sh | cut -d: -f1)
         echo "INCOMPAT debian lib/common.sh:$l clock(): perl without Time::HiRes (perl-base):" \
           "$(echo "$out" | head -1 | cut -c1-60)";;
    esac' > "$E/debian.out" 2>&1
  grep -E '^(PASS|FAIL|SKIP|bash )' "$E/debian.out" | while IFS= read -r l; do
    case $l in PASS*) echo "$l";; FAIL*) echo "$l";; *) log "$l";; esac
  done
  diff_init=""
  for ex in hello site next notes; do
    [ -f "$E/init-$ex.mac" ] || continue
    sed -n "s/^INIT $ex //p" "$E/debian.out" > "$E/init-$ex.debian"
    if ! cmp -s "$E/init-$ex.mac" "$E/init-$ex.debian"; then
      diff_init="$diff_init $ex"
      echo "INCOMPAT debian init($ex): result differs from macOS: $(diff "$E/init-$ex.mac" "$E/init-$ex.debian" |
        grep '^[<>]' | tr '\n' ' ')" >> "$E/debian.out"
    fi
  done
  if [ -f "$E/init-hello.mac" ]; then
    if [ -z "$diff_init" ]; then echo "PASS D4 init gives the same tando.conf (or refusal) as on macOS"
    else echo "FAIL D4 init differs from macOS:$diff_init"; fi >> "$E/debian.out"
    tail -1 "$E/debian.out"
  fi
  PASSN=$((PASSN + $(grep -c '^PASS' "$E/debian.out"))) FAILN=$((FAILN + $(grep -c '^FAIL' "$E/debian.out")))
  incompat "$E/debian.out"
fi

# ---- linux + busybox: a Linux client against a test server ---------------------------------------

# client <part> <app>: run the client flow inside a throwaway client container; prints PASS/FAIL/INCOMPAT
client() {
  local part=$1 app=$2 ip bbdir="" bbmount=()
  ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$NAME")
  if [ "$part" = busybox ]; then
    bbdir=$E/bb
    mkdir -p "$bbdir"
    docker image inspect "$ALPINE_IMG" > /dev/null 2>&1 || docker pull -q "$ALPINE_IMG" > /dev/null
    cid=$(docker create "$ALPINE_IMG" true)
    docker cp -L "$cid:/bin/busybox" "$bbdir/busybox" > /dev/null
    docker cp -L "$cid:/lib/$(docker run --rm "$ALPINE_IMG" sh -c 'cd /lib && ls ld-musl-*')" "$bbdir/" > /dev/null
    docker rm "$cid" > /dev/null
    bbmount=(-v "$bbdir:/bb:ro")
  fi
  # the script comes from the mount, not stdin: ssh in the script would read the rest of it
  docker run --rm --entrypoint bash -v "$ROOT:/tando:ro" ${bbmount[@]+"${bbmount[@]}"} \
    -e PART="$part" -e APP="$app" -e IP="$ip" "$CLIENT_IMG" /tando/test/portability-client.sh < /dev/null 2>&1
}

if want linux || want busybox; then
  [ -f "$ROOT/test/portability-client.sh" ] || { echo "portability: test/portability-client.sh missing" >&2; exit 2; }
  server_up
  for p in linux busybox; do
    want $p || continue
    log "client: $p"
    client $p "porta-$p" > "$E/$p.out"
    grep -E '^(PASS|FAIL|SKIP) ' "$E/$p.out"
    PASSN=$((PASSN + $(grep -c '^PASS' "$E/$p.out"))) FAILN=$((FAILN + $(grep -c '^FAIL' "$E/$p.out")))
    incompat "$E/$p.out"
  done
fi
if [ "$created" = 1 ] && [ "$keep" = 0 ]; then
  TANDO_TEST_NAME=$NAME "$ROOT/test/server/down.sh"
fi

echo "portability: $PASSN passed, $FAILN failed, $INCOMPAT incompatibilities (details in $E)"
[ "$FAILN" = 0 ] && [ "$INCOMPAT" = 0 ]
