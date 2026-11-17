#!/bin/bash
# End-to-end test of the next recipe (examples/next) against the test container. Needs npm and
# network access for `npm ci` and for the server-platform sharp packages. Starts from a clean
# `test/server/up.sh --reset`. One PASS/FAIL line per check; exits non-zero on any failure.
# Usage: test/e2e-next.sh [--no-reset]
set -u
# Server: TANDO_TEST_NAME, TANDO_TEST_SSH_PORT, TANDO_TEST_HTTP_PORT (default tando-testvm, 2222,
# 8080). The server is reset first when run by hand on the default one, or when TANDO_TEST_OWNED=1.
TN=${TANDO_TEST_NAME:-tando-testvm} SP=${TANDO_TEST_SSH_PORT:-2222} HP=${TANDO_TEST_HTTP_PORT:-8080}
export TANDO_TEST_NAME=$TN TANDO_TEST_SSH_PORT=$SP TANDO_TEST_HTTP_PORT=$HP
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
. "$ROOT/test/lib.sh"   # t_until (this suite keeps its own pass/fail/check, defined below)
E=${T_WORK:-$ROOT/test/.e2e-next-$TN}   # one work dir per test server
W=$E/next R=$ROOT/bin/tando SSH=$ROOT/test/server/ssh.sh
AGENT=/opt/tando/bin/tando-agent
A=/opt/tando/apps/nextdemo
export TANDO_CONFIG_DIR=$E/cfg TANDO_COLOR=never
export TANDO_SOAK=${TANDO_SOAK:-2} TANDO_WAIT=1   # a short soak (30 s by default) keeps the suite fast
FAILS=0

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local n=$1; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
log() { echo "---- $*" >&2; }
url() { echo "http://nextdemo.localhost:$HP$1"; }
version() { curl -s -m 5 "$(url /demo/api/version)" | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'; }
visit() { curl -s -m 5 -X POST "$(url /demo/api/visits)" | sed -n 's/.*"n":\([0-9]*\).*/\1/p'; }
srv() { "$SSH" "$@"; }
phase() { sed -n "s/.*[✓✗] [0-9]\/7  $2 *\([0-9.]*s\).*/\1/p" "$1"; }

if [ "${1:-}" != --no-reset ] && { [ "$TN" = tando-testvm ] || [ "${TANDO_TEST_OWNED:-}" = 1 ]; }; then
  log "resetting test server"
  "$ROOT/test/server/up.sh" --reset >&2 || exit 1
fi
rm -rf "${E:?}"
mkdir -p "$W"
rsync -a --exclude node_modules --exclude .next --exclude .tando "$ROOT/examples/next/" "$W/"

# N1. init detects Next.js, reads basePath, and warns when standalone output is missing
mkdir -p "$E/plain"
printf '{ "dependencies": { "next": "16.4.6" } }\n' > "$E/plain/package.json"
printf "export default { basePath: '/shop' };\n" > "$E/plain/next.config.mjs"
(cd "$E/plain" && "$R" init) > "$E/init1.out" 2>&1
check "N1a init without standalone output says what to add (no terminal: it does not edit)" \
  grep -q 'needs  output: "standalone"  in next.config.mjs' "$E/init1.out"
# create-next-app's next.config.ts: init --yes adds the line itself
mkdir -p "$E/cna"
printf '{ "dependencies": { "next": "16.4.6" } }\n' > "$E/cna/package.json"
printf 'import type { NextConfig } from "next";\n\nconst nextConfig: NextConfig = {\n  /* config options here */\n};\n\nexport default nextConfig;\n' \
  > "$E/cna/next.config.ts"
(cd "$E/cna" && "$R" init --yes) > "$E/init3.out" 2>&1; rc=$?
check "N1d init --yes adds output: \"standalone\" to a create-next-app config (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -q "^  output: \"standalone\",\$" "$E/cna/next.config.ts" &&
        grep -q "added  output" "$E/init3.out"'
check "N1b init picks the next recipe and the basePath" \
  eval 'grep -q "recipe = next" "$E/plain/tando.conf" && grep -q "path = /shop" "$E/plain/tando.conf"'
mv "$W/tando.conf" "$E/tando.conf.example"
(cd "$W" && "$R" init) > "$E/init2.out" 2>&1
check "N1c init on examples/next: no warning, build and start set" \
  eval '! grep -q standalone "$E/init2.out" && grep -q "build = npm run build" "$W/tando.conf" &&
        grep -q "start = node server.js" "$W/tando.conf" && grep -q "path = /demo" "$W/tando.conf"'
mv "$E/tando.conf.example" "$W/tando.conf"

# N2. first deploy: build, swap sharp to the server platform, serve under the base path
cd "$W"
log "npm ci"
npm ci --no-audit --no-fund > "$E/npm.out" 2>&1 || { cat "$E/npm.out" >&2; exit 1; }
"$R" host add test vmadmin@127.0.0.1 --port $SP --key "$ROOT/test/server/id_test" --yes >&2
"$R" host setup test public_port=$HP >&2
"$R" up > "$E/up1.out" 2>&1; rc=$?; cat "$E/up1.out" >&2
check "N2a up: /demo/api/version answers 1 (rc=$rc)" test $rc = 0 -a "$(version)" = 1
check "N2b the page renders under the base path" eval 'curl -s "$(url /demo)" | grep -q "tando next example v"'
loc=$(curl -s -o /dev/null -w '%{redirect_url}' "$(url /)")
check "N2c / redirects to the base path ($loc)" test "$loc" = "$(url /demo)"
check "N2d the link honours the path" grep -q "nextdemo.localhost:$HP/demo" "$E/up1.out"

# N3. native modules: sharp for the server's platform, image optimisation works there
arch=$(srv uname -m); case $arch in aarch64) cpu=arm64;; x86_64) cpu=x64;; *) cpu=$arch;; esac
check "N3a stage has sharp for linux-$cpu and nothing for darwin" eval \
  '[ -d .tando/stage/node_modules/@img/sharp-linux-$cpu ] &&
   ! ls -d .tando/stage/node_modules/@img/*darwin* 2> /dev/null'
img=$(curl -s "$(url /demo)" | grep -o '/demo/_next/image?url=[^" ]*' | head -1 | sed 's/&amp;/\&/g')
ct=$(curl -s -o /dev/null -w '%{http_code} %{content_type}' -H 'Accept: image/webp,*/*' "$(url "$img")")
check "N3b next/image optimised on the server ($img: $ct)" test "$ct" = "200 image/webp"

# N7. regenerated pages (ISR) are written into the release's own writable copy
stamp() { grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z' | head -1; }
isr() { curl -s -m 10 "$(url /demo/isr)" | stamp; }
isr_disk() { srv "sudo cat $A/current/.next/server/app/isr.html" | stamp; }
t1=$(isr); shipped=$(isr_disk)
# a request after the revalidate window starts a regeneration; a later one gets the new page
regenerated() { t2=$(isr); [ -n "$t2" ] && [ "$t2" != "$t1" ]; }
t2=""; T_UNTIL_STEP=2 t_until 60 regenerated
check "N7a the ISR page regenerates ($t1 -> $t2)" test -n "$t1" -a -n "$t2" -a "$t1" != "$t2"
check "N7a2 the shipped page ($shipped) is the build's, not the regenerated one" test -n "$shipped" -a "$shipped" != "$t2"
P=$(srv "readlink -f $A/current")
hit=$(srv "sudo grep -rl '$t2' $P/.next/server/route-cache $P/.next/server/app 2> /dev/null | head -1")
own=$(srv "sudo stat -c %U '$hit'" 2> /dev/null)
check "N7b the regenerated page is written into the release ($hit, $own)" \
  test -n "$hit" -a "$own" = tando-nextdemo
check "N7c other release files stay root-owned" \
  test "$(srv "sudo stat -c %U $A/current/server.js")" = root

# N4. data directory survives a release; one-line change uploads only what changed; no request
#     fails during the deploy
n1=$(visit); n2=$(visit)
echo "export const VERSION = '2';" > version.js
(
  while [ ! -f "$E/loop.stop" ]; do
    curl -s -o /dev/null -m 30 -w '%{http_code} %{time_total}\n' "$(url /demo/api/version)"
    sleep 0.1
  done
) > "$E/loop" &
loop=$!
sleep 0.5
"$R" deploy > "$E/d2.out" 2>&1; rc=$?; cat "$E/d2.out" >&2
sleep 0.5; touch "$E/loop.stop"; wait $loop
nreq=$(grep -c . "$E/loop"); bad=$(awk '$1 != 200' "$E/loop" | wc -l | tr -d ' ')
max=$(awk '$2 > m { m = $2 } END { printf "%.3f", m }' "$E/loop")
check "N8 deploy under load: $nreq requests, $bad failed, longest ${max}s" test "$bad" = 0 -a "$nreq" -gt 5
P2=$(srv "readlink -f $A/current")
left=$(srv "sudo grep -rl '$t2' $P2/.next/server/route-cache $P2/.next/server/app 2> /dev/null | wc -l")
check "N7d a new release starts from its shipped pages, without the regenerated one ($left files)" \
  test "$P2" != "$P" -a "$left" = 0
check "N4a one-line change deployed: version 2 (rc=$rc)" test $rc = 0 -a "$(version)" = 2
n3=$(visit)
check "N4b data written before the deploy survives it (visits $n1 $n2 $n3)" test "$n1 $n2 $n3" = "1 2 3"
lnk=$(srv "sudo readlink $A/current/data; sudo readlink $A/current/.next/cache" | tr '\n' ' ')
check "N4c data and .next/cache map into shared/ ($lnk)" test "$lnk" = "$A/shared/data $A/shared/next-cache "
own=$(srv "sudo stat -c %U $A/shared/data/visits.json")
check "N4d data files are owned by the app user ($own)" test "$own" = tando-nextdemo
files=$(sed -n 's/.* \([0-9][0-9]*\) files changed.*/\1/p' "$E/d2.out")
sent=$(sed -n 's/.*changed, \([0-9.]* [KMG]*B\) sent.*/\1/p' "$E/d2.out")
total=$(sed -n 's/.*live in \([0-9.ms ]*\)  .*/\1/p' "$E/d2.out")
check "N4e one-line change sent $sent in $files files (release ~12 MB), live in $total" \
  eval 'echo "$sent" | grep -qE "^[0-9.]+ (B|KB)$"'
log "one-line change: build $(phase "$E/d2.out" build) stage $(phase "$E/d2.out" stage)" \
  "upload $(phase "$E/d2.out" upload) copy $(phase "$E/d2.out" copy) preflight $(phase "$E/d2.out" preflight)" \
  "switch $(phase "$E/d2.out" switch) verify $(phase "$E/d2.out" verify), total $total, $sent sent"
b=$(srv "sudo tail -1 $A/history.tsv" | cut -f6)
check "N4f history records the build seconds ($b)" awk -v b="${b:-0}" 'BEGIN { exit !(b >= 1) }'

# N5. the server refuses a release that ships the data directory
tok=$(srv "sudo $AGENT begin nextdemo e2e" | sed -n 's/^token=//p')
srv "mkdir -p $A/incoming/data && echo x > $A/incoming/data/x"
id=$(srv "sudo $AGENT activate nextdemo $tok 0 0" | sed -n 's/^id=//p')
finished() { r=$(srv "sudo $AGENT deploy-status nextdemo $id" | sed -n 's/^result=//p'); [ -n "$r" ] && [ "$r" != running ]; }
T_UNTIL_STEP=0.5 t_until 60 finished
msg=$(srv "sudo $AGENT deploy-status nextdemo $id" | sed -n 's/^message=//p')
check "N5 release shipping data/ refused ($msg), still version 2" \
  eval 'echo "$msg" | grep -q "data directory .data. ships in the release" && [ "$(version)" = 2 ]'
srv "rm -rf $A/incoming/data"

# N6. boxed views show the path
COLUMNS=120 "$R" ls > "$E/ls.out" 2>&1; cat "$E/ls.out" >&2
check "N6 ls shows the link with its path" grep -q "nextdemo.localhost:$HP/demo" "$E/ls.out"

echo "$FAILS failed"
[ $FAILS -eq 0 ]
