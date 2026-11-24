#!/bin/bash
# End-to-end test of skew protection (skew_window, docs/ARCHITECTURE.md "Skew protection"): after a
# switch, a page of the older release still gets its fingerprinted files, for skew_window after
# it stopped serving. A Vite-like static site (assets/index-<hash>.js) and a Next-like app (recipe
# next with a stand-in standalone server: .next/static/<build>/..., .next/static/chunks/...).
#   (1) v1's hashed files answer 200 with v1's bytes and the immutable header after v2 went live;
#       v2's are v2's; a name in both with other bytes is the live release's
#   (2) a path in neither: 404 for the static site, the app's own answer for the next app
#   (3) traversal (../, encoded) never reaches anything outside the shared directory, and the
#       shared directory holds nothing but the releases' asset trees; one app's site never answers
#       another app's files
#   (4) the window only extends what prune keeps: a pruned release's files stay for the window, a
#       kept release's whatever its window; the sweep (tando-assetsweep.timer) ends a pruned one's
#       window, skew_window = off is the old behaviour (kept releases only); a URL prefix no record
#       names leaves the site; at most 20 pruned releases
#   (5) after a rollback the newer release's files stay reachable
#
#   test/e2e-skew.sh [--reset]     --reset: recreate the server first (only one this suite owns)
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT. About 3 minutes.
# Output: PASS/FAIL lines (docs/TESTING.md), summary, exit status.
set -u
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init skew
W=$E/w AGENT=/opt/tando/bin/tando-agent

if [ "${1:-}" = --reset ]; then t_server_up --reset || exit 1; else t_server_up || exit 1; fi
t_host_add test
"$R" host setup test public_port="$T_HTTP_PORT" >&2 || exit 1

code() { curl -s -o /dev/null -w '%{http_code}' -m 10 "$(t_url "$1" "$2")"; }
body() { curl -s -m 10 "$(t_url "$1" "$2")"; }
hdrs() { curl -s -m 10 -D - -o /dev/null "$(t_url "$1" "$2")" | tr -d '\r'; }
immutable() { hdrs "$1" "$2" | grep -qi '^cache-control: public, max-age=31536000, immutable'; }
cur() { "$SSH" "sudo sed -n 's/^current=//p' /opt/tando/apps/$1/state"; }
site_has() { "$SSH" "sudo grep -qF '$1' /etc/caddy/tando/sv.caddy"; }   # (a fixed string in the static site's Caddy file)
deploy() { # app dir log
  (cd "$2" && "$R" deploy > "$E/$3.log" 2>&1)
}

# ---- the static site: release n has assets/index-R<n>... and a chunk whose name stays ----------
SV=$W/sv
sv_release() { # n [dir]: a Vite-like build, its files under <dir> (default assets)
  local d=${2:-assets}
  rm -rf "${SV:?}/assets" "${SV:?}/_astro"; mkdir -p "$SV/$d"
  { echo "console.log('sv release $1');"; head -c 2000 /dev/zero | tr '\0' ' '; } > "$SV/$d/index-R${1}abcdef.js"
  echo "sv const of release $1" > "$SV/$d/chunk-Const123.js"
  printf '<!doctype html><script src=/%s/index-R%sabcdef.js></script><h1>sv %s</h1>\n' "$d" "$1" "$1" > "$SV/index.html"
  cp "$SV/$d/index-R${1}abcdef.js" "$E/sv$1.js"
}
mkdir -p "$SV"; printf 'app = sv\nrecipe = static\n' > "$SV/tando.conf"
sv_release 1
(cd "$SV" && "$R" up --yes > "$E/sv1.log" 2>&1); rc=$?
SV1=$(cur sv)
sv_release 2; deploy sv "$SV" sv2; rc2=$?
SV2=$(cur sv)
check "K0 the static site deploys v1 and v2 (rc=$rc/$rc2; $SV1, $SV2)" \
  eval '[ $rc = 0 ] && [ $rc2 = 0 ] && [ -n "$SV1" ] && [ "$SV1" != "$SV2" ] && body sv / | grep -q "<h1>sv 2"'
check "K1 v1's hashed file answers 200 after v2 went live, with v1's bytes and the immutable header" \
  eval '[ "$(code sv /assets/index-R1abcdef.js)" = 200 ] && [ "$(body sv /assets/index-R1abcdef.js | cksum)" = "$(cksum < "$E/sv1.js")" ] &&
        immutable sv /assets/index-R1abcdef.js'
check "K1b v2's hashed file is v2's bytes, immutable" \
  eval '[ "$(body sv /assets/index-R2abcdef.js | cksum)" = "$(cksum < "$E/sv2.js")" ] && immutable sv /assets/index-R2abcdef.js'
check "K1c a name both releases have, with other bytes, is the live release's" \
  eval '[ "$(body sv /assets/chunk-Const123.js)" = "sv const of release 2" ]'
check "K2 a hashed path in neither release is a 404 without the immutable header" \
  eval '[ "$(code sv /assets/index-R9abcdef.js)" = 404 ] && ! immutable sv /assets/index-R9abcdef.js'
check "K2b the old release's window is open: its record has an .end, the live one's has none" \
  "$SSH" "sudo test -f /opt/tando/apps/sv/assetlog/$SV1.end -a ! -e /opt/tando/apps/sv/assetlog/$SV2.end"

# ---- (5) rollback: the newer release's files stay ----------------------------------------------
(cd "$SV" && "$R" rollback > "$E/svrb.log" 2>&1); rc=$?
check "K3 after a rollback to v1 (rc=$rc) the page is v1's and v2's hashed file still answers with its bytes, immutable" \
  eval '[ $rc = 0 ] && [ "$(cur sv)" = "$SV1" ] && body sv / | grep -q "<h1>sv 1" &&
        [ "$(body sv /assets/index-R2abcdef.js | cksum)" = "$(cksum < "$E/sv2.js")" ] && immutable sv /assets/index-R2abcdef.js'
check "K3b the live release wins again: the shared name is v1's bytes; v2's window runs, v1's record has no .end" \
  eval '[ "$(body sv /assets/chunk-Const123.js)" = "sv const of release 1" ] &&
        "$SSH" "sudo test -f /opt/tando/apps/sv/assetlog/$SV2.end -a ! -e /opt/tando/apps/sv/assetlog/$SV1.end"'

# ---- the next-like app: a stand-in standalone server that serves .next/static as Next does ----
NX=$W/nx
mkdir -p "$NX/.next/standalone/.next/server"
cat > "$NX/.next/standalone/server.js" <<'JS'
const http = require("http"), fs = require("fs"), path = require("path");
const B = fs.readFileSync(path.join(__dirname, ".next", "BUILD_ID"), "utf8").trim();
const S = path.join(__dirname, ".next", "static");
http.createServer((q, r) => {
  let u; try { u = decodeURIComponent(q.url.split("?")[0]); } catch (e) { r.statusCode = 400; return r.end("bad"); }
  if (u.startsWith("/_next/static/")) {
    const f = path.join(S, u.slice("/_next/static/".length));
    if (!f.startsWith(S + path.sep) || !fs.existsSync(f) || !fs.statSync(f).isFile()) { r.statusCode = 404; return r.end("next-404"); }
    r.setHeader("Cache-Control", "public, max-age=31536000, immutable");
    return r.end(fs.readFileSync(f));
  }
  r.end("nx build " + B);
}).listen(process.env.PORT, "127.0.0.1");
JS
echo 'module.exports = "SERVERSIDE-SECRET-7731";' > "$NX/.next/standalone/.next/server/secret.js"
printf 'app = nx\nrecipe = next\nstart = node server.js\nmemory = 128M\n' > "$NX/tando.conf"
nx_release() { # n: build id B<n>, a chunk main-<n>...
  rm -rf "${NX:?}/.next/static"; mkdir -p "$NX/.next/static/build$1x" "$NX/.next/static/chunks"
  echo "build${1}x" > "$NX/.next/standalone/.next/BUILD_ID"
  echo "self.__BUILD_MANIFEST={b:$1}" > "$NX/.next/static/build$1x/_buildManifest.js"
  echo "nx chunk of release $1" > "$NX/.next/static/chunks/main-N${1}c0ffee.js"
}
nx_release 1
(cd "$NX" && "$R" up --yes > "$E/nx1.log" 2>&1); rc=$?
nx_release 2; deploy nx "$NX" nx2; rc2=$?
check "K10 the next-like app deploys v1 and v2 (rc=$rc/$rc2)" eval '[ $rc = 0 ] && [ $rc2 = 0 ] && [ "$(body nx /)" = "nx build build2x" ]'
check "K11 v1's build manifest and chunk answer 200 with v1's bytes after v2 went live, immutable" \
  eval '[ "$(body nx /_next/static/build1x/_buildManifest.js)" = "self.__BUILD_MANIFEST={b:1}" ] &&
        [ "$(body nx /_next/static/chunks/main-N1c0ffee.js)" = "nx chunk of release 1" ] && immutable nx /_next/static/chunks/main-N1c0ffee.js'
check "K11b v2's chunk is v2's" eval '[ "$(body nx /_next/static/chunks/main-N2c0ffee.js)" = "nx chunk of release 2" ]'
check "K12 a path in neither release goes to the app (its own 404)" \
  eval '[ "$(code nx /_next/static/chunks/none-N9c0ffee.js)" = 404 ] && [ "$(body nx /_next/static/chunks/none-N9c0ffee.js)" = next-404 ]'

# ---- (3) confinement -------------------------------------------------------------------------
check "K13 the shared directories hold only the asset trees: no server file, no file outside the prefixes" \
  eval '[ -z "$("$SSH" "sudo find /opt/tando/apps/nx/assets -type f ! -path /opt/tando/apps/nx/assets/_next/static/\*")" ] &&
        [ -z "$("$SSH" "sudo find /opt/tando/apps/sv/assets -type f ! -path /opt/tando/apps/sv/assets/assets/\*")" ] &&
        [ -z "$("$SSH" "sudo grep -rl SERVERSIDE-SECRET /opt/tando/apps/nx/assets /opt/tando/apps/sv/assets")" ]'
bad=""
for p in '/_next/static/../../.next/server/secret.js' '/_next/static/..%2f..%2f.next%2fserver%2fsecret.js' \
         '/_next/static/%2e%2e/%2e%2e/.next/server/secret.js' '/_next/static/chunks/../../../../app.conf' \
         '/_next/static/%2e%2e%2f%2e%2e%2f%2e%2e%2fapp.conf' '/_next/static/..%5c..%5capp.conf' \
         '/_next/static/%252e%252e/%252e%252e/state' '/_next/static/....//....//app.conf' \
         '/_next/static/chunks/%2e%2e/%2e%2e/%2e%2e/releases/'; do
  b=$(curl -s -m 10 --path-as-is "$(t_url nx)${p#/}")
  case $b in *SERVERSIDE-SECRET*|*recipe=*|*current=*|*port=*) bad="$bad nx:$p";; esac
done
for p in '/assets/../../app.conf' '/assets/..%2f..%2fapp.conf' '/assets/%2e%2e/%2e%2e/state' '/assets/%2e%2e%2f%2e%2e%2fassetlog/' \
         '/assets/....//....//app.conf' '/assets/..%5c..%5capp.conf' '/assets/%252e%252e/%252e%252e/app.conf' \
         '/assets/../../../nx/releases/'; do
  b=$(curl -s -m 10 --path-as-is "$(t_url sv)${p#/}")
  case $b in *SERVERSIDE-SECRET*|*recipe=*|*current=*|*port=*|*$SV1*) bad="$bad sv:$p";; esac
done
check "K14 traversal attempts (../, %2e%2e, %2f, %5c, double encoding) reach nothing outside the shared directory${bad:+:$bad}" test -z "$bad"
check "K15 one app's site never answers another's shared files" \
  eval '[ "$(code sv /_next/static/chunks/main-N1c0ffee.js)" = 404 ] && ! body nx /assets/index-R1abcdef.js | grep -q "sv release"'

# ---- (4) the window ends ---------------------------------------------------------------------
check "K20 host setup installed the sweep timer" "$SSH" 'systemctl is-enabled -q tando-assetsweep.timer && systemctl is-active -q tando-assetsweep.timer'
# v3 puts its files under _astro/: once v1's and v2's records go, /assets/ leaves the site
sv_release 3 _astro; deploy sv "$SV" sv3; rc=$?
SV3=$(cur sv)
check "K21 v3 (files under _astro/) is live; v1's and v2's files still answer, the site mounts both prefixes (rc=$rc)" \
  eval '[ $rc = 0 ] && [ "$(code sv /_astro/index-R3abcdef.js)" = 200 ] && [ "$(code sv /assets/index-R1abcdef.js)" = 200 ] &&
        [ "$(code sv /assets/index-R2abcdef.js)" = 200 ] && site_has "/assets/*" && site_has "/_astro/*"'
# five more releases: prune (5 kept) takes v1 and v2 away; their window keeps their files
for n in 4 5 6 7 8; do sv_release $n _astro; deploy sv "$SV" sv$n; [ $n = 4 ] && SV4=$(cur sv); done
check "K21b v1 and v2 were pruned (kept: $("$SSH" "sudo ls /opt/tando/apps/sv/releases | wc -l" | tr -d ' ')), but in their window their files answer with their bytes" \
  eval '! "$SSH" "sudo test -e /opt/tando/apps/sv/releases/$SV1 -o -e /opt/tando/apps/sv/releases/$SV2" &&
        [ "$(body sv /assets/index-R1abcdef.js | cksum)" = "$(cksum < "$E/sv1.js")" ] &&
        [ "$(body sv /assets/index-R2abcdef.js | cksum)" = "$(cksum < "$E/sv2.js")" ]'
out=$("$SSH" "sudo $AGENT assets-sweep" 2>&1)
check "K22 a sweep inside the window changes nothing ($(echo $out))" \
  eval '[ "$(code sv /assets/index-R1abcdef.js)" = 200 ] && echo "$out" | grep -q "^failed=0"'
# the window only adds: a release still kept whose window ended two days ago keeps its files
"$SSH" "sudo sh -c 'echo \$((\$(date +%s) - 172800)) > /opt/tando/apps/sv/assetlog/$SV4.end'"
"$SSH" "sudo $AGENT assets-sweep" > /dev/null 2>&1
check "K22b a kept release ($SV4, v4) older than the window still serves its files after a sweep" \
  eval '"$SSH" "sudo test -d /opt/tando/apps/sv/releases/$SV4 -a -f /opt/tando/apps/sv/assetlog/$SV4" &&
        [ "$(body sv /_astro/index-R4abcdef.js | cksum)" = "$(cksum < "$E/sv4.js")" ]'
# the window of the pruned v1 and v2 ended two days ago
"$SSH" "sudo sh -c 'for i in $SV1 $SV2; do echo \$((\$(date +%s) - 172800)) > /opt/tando/apps/sv/assetlog/\$i.end; done'"
out=$("$SSH" "sudo $AGENT assets-sweep" 2>&1)
check "K23 after the window the sweep takes the pruned v1's and v2's files: 404, gone from disk ($(echo $out))" \
  eval '[ "$(code sv /assets/index-R1abcdef.js)" = 404 ] && [ "$(code sv /assets/index-R2abcdef.js)" = 404 ] &&
        [ -z "$("$SSH" "sudo find /opt/tando/apps/sv/assets /opt/tando/apps/sv/assetlog -name \*R1abcdef\* -o -name \*R2abcdef\* -o -name $SV1\* -o -name $SV2\*")" ] &&
        [ "$(body sv /_astro/index-R8abcdef.js | cksum)" = "$(cksum < "$E/sv8.js")" ]'
check "K23b the /assets/ prefix no record names left the site; Caddy accepts it" \
  eval '! site_has "/assets/*" && site_has "/_astro/*" &&
        "$SSH" "sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile" > /dev/null 2>&1'
# at most SKEW_MAX (20) pruned releases: 22 records of releases that are gone, ended 1 to 22 s ago
"$SSH" "sudo bash -c 'L=/opt/tando/apps/sv/assetlog; t=\$(date +%s); for k in \$(seq 1 22); do i=20200101-0000\$(printf %02d \$k);
  : > \$L/\$i; cp \$L/$SV3.spec \$L/\$i.spec; echo \$((t - k)) > \$L/\$i.end; done'"
"$SSH" "sudo $AGENT assets-sweep" > /dev/null 2>&1
left=$("$SSH" "sudo ls /opt/tando/apps/sv/assetlog | grep -c '^20200101-0000[0-9]*\$'")
nkept=$("$SSH" "sudo ls /opt/tando/apps/sv/releases | wc -l" | tr -d ' ')
nrec=$("$SSH" "sudo ls /opt/tando/apps/sv/assetlog | grep -v '[.]' | grep -vc '^20200101-'")
check "K24 at most 20 pruned releases keep their files: of 22 the two oldest go ($left left); the kept releases' records all stay ($nrec of $nkept)" \
  eval '[ "$left" = 20 ] && ! "$SSH" "sudo test -e /opt/tando/apps/sv/assetlog/20200101-000021 -o -e /opt/tando/apps/sv/assetlog/20200101-000022" &&
        [ "$nrec" = "$nkept" ]'
"$SSH" "sudo rm -f /opt/tando/apps/sv/assetlog/20200101-*"
# skew_window = off: the behaviour from before the window: the kept releases' files, no more
nx_release 3; printf 'skew_window = off\n' >> "$NX/tando.conf"; deploy nx "$NX" nx3; rc=$?
check "K25 skew_window = off never shortens: v1 and v2 are still kept, their files still answer (rc=$rc)" \
  eval '[ $rc = 0 ] && [ "$(body nx /_next/static/chunks/main-N1c0ffee.js)" = "nx chunk of release 1" ] &&
        [ "$(body nx /_next/static/build2x/_buildManifest.js)" = "self.__BUILD_MANIFEST={b:2}" ] &&
        [ "$(body nx /_next/static/chunks/main-N3c0ffee.js)" = "nx chunk of release 3" ] && immutable nx /_next/static/chunks/main-N3c0ffee.js'
for n in 4 5 6 7 8; do nx_release $n; deploy nx "$NX" nx$n; done
# (the deploy's prune runs after its result is written: the client may be back before it ends)
nx_old_gone() { [ "$(body nx /_next/static/chunks/main-N1c0ffee.js)" = next-404 ] && [ "$(body nx /_next/static/build2x/_buildManifest.js)" = next-404 ]; }
nx_recs() { [ "$("$SSH" "sudo ls /opt/tando/apps/nx/assetlog | grep -v '[.]' | sort")" = "$("$SSH" "sudo ls /opt/tando/apps/nx/releases | sort")" ]; }
check "K25b skew_window = off: once v1 and v2 are pruned their files are the app's (404 from v8), v8's answer" \
  eval 't_until 30 nx_old_gone && [ "$(body nx /_next/static/chunks/main-N8c0ffee.js)" = "nx chunk of release 8" ]'
check "K25c skew_window = off: the records are exactly the kept releases'" t_until 30 nx_recs
# a bad value: the client refuses it before anything is built
printf 'app = sv\nrecipe = static\nskew_window = 2x\n' > "$E/bad.conf"
out=$(cd "$SV" && cp tando.conf "$E/good.conf" && cp "$E/bad.conf" tando.conf && "$R" deploy 2>&1; cp "$E/good.conf" tando.conf)
check "K26 skew_window = 2x is refused with what it takes" eval 'echo "$out" | grep -q "skew_window is a time like 24h"'

for a in sv nx; do "$R" destroy "$a" --purge --yes > /dev/null 2>&1; done
t_done
