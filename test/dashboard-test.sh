#!/bin/bash
# test/dashboard-test.sh: the dashboard add-on (addons/dashboard): its local server tando-dash.
# No server, no network: the Go tests run a fake tando CLI (the test binary itself).
#
#   d1 gofmt -l prints nothing          d4 the main release archive (scripts/release.sh) holds
#   d2 go vet ./...                        nothing of addons/ (the add-on ships on its own)
#   d3 go test -race ./... (with the    d5 tando-dash builds (stripped) and prints its version
#      2-minute soaks; the quick tier
#      passes -short and skips them;
#      the tests run in DASH_SHARDS
#      groups at once, default 4)        d6 addons/dashboard/VERSION is tando's VERSION (the add-on
#                                          release must match the CLI it is installed for)
#   w1 npm ci (SKIP without node)       w3 npm run build writes server/webdist/dist, and tando-dash
#   w2 vitest run                          builds with it embedded (index.html in the binary)
#                                       w4 bundle budgets (scripts/check-size.mjs) and the design rules
#                                          (scripts/check-rules.mjs): first route <= 150 KB gz, CSS <= 15 KB
#
# Flags: --quick, GO_QUICK=1 (what test/all.sh --tier quick sets): -short, no soak.
# TANDO_DASH_SOAK=30m runs the long soak instead of the 2-minute one. Needs Go (SKIP without it).
set -u
quick=${GO_QUICK:-0}
while [ $# -gt 0 ]; do
  case $1 in
    --quick) quick=1;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    *) echo "dashboard-test.sh: unknown option $1" >&2; exit 2;;
  esac
  shift
done
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init dashboard-test
mkdir -p "$E"
D=$ROOT/addons/dashboard/server
export GOTOOLCHAIN=local GOFLAGS=
web_checks() {
W=$ROOT/addons/dashboard/web
if ! command -v node > /dev/null 2>&1 || ! command -v npm > /dev/null 2>&1; then
  skip "w0 node/npm is not installed: addons/dashboard/web (vitest, build, bundle budgets) was not checked"
  return 0
fi
cd "$W" || exit 1
npm ci --no-audit --no-fund > "$E/npm-ci.out" 2>&1; rc=$?
[ "$rc" = 0 ] || tail -20 "$E/npm-ci.out" >&2
check "w1 npm ci (rc=$rc)" test "$rc" = 0
if [ "$rc" = 0 ]; then
  npx vitest run > "$E/vitest.out" 2>&1; rc=$?
  [ "$rc" = 0 ] || tail -40 "$E/vitest.out" >&2
  check "w2 vitest: $(grep -E '^ +Tests ' "$E/vitest.out" | sed 's/^ *//') (rc=$rc)" test "$rc" = 0
  npm run build > "$E/webbuild.out" 2>&1; rc=$?
  [ "$rc" = 0 ] || tail -20 "$E/webbuild.out" >&2
  check "w3 npm run build writes server/webdist/dist (rc=$rc)" test "$rc" = 0 -a -s "$D/webdist/dist/index.html"
  if [ "$rc" = 0 ]; then
    (cd "$D" && go build -trimpath -o "$E/tando-dash-web" . > "$E/embed.out" 2>&1)
    asset=$(grep -o 'assets/index-[^"]*\.js' "$D/webdist/dist/index.html" | head -1)
    check "w3b tando-dash embeds the build ($asset is inside the binary)" test -n "$asset" -a -s "$E/tando-dash-web" && grep -aq "$asset" "$E/tando-dash-web"
    node scripts/check-size.mjs > "$E/size.out" 2>&1; rc=$?
    cat "$E/size.out" >&2
    check "w4 bundle budgets (rc=$rc)" test "$rc" = 0
    node scripts/check-rules.mjs > "$E/rules.out" 2>&1; rc=$?
    [ "$rc" = 0 ] || cat "$E/rules.out" >&2
    check "w5 design rules: no colour literal outside tokens.css, no style prop, <= 24 icons (rc=$rc)" test "$rc" = 0
    # the build output is not committed (only the placeholder is): put the placeholder back
    if git -C "$ROOT" ls-files --error-unmatch addons/dashboard/server/webdist/dist/index.html > /dev/null 2>&1; then
      rm -rf "${D:?}/webdist/dist/assets"
      git -C "$ROOT" checkout -- addons/dashboard/server/webdist/dist
    fi
  fi
fi
}
if ! command -v go > /dev/null 2>&1; then
  skip "d0 Go is not installed: addons/dashboard/server cannot be checked"
  web_checks
  t_done
fi
cd "$D" || exit 1

gofmt -l . > "$E/gofmt.out" 2>&1
check "d1 gofmt -l prints nothing ($(wc -l < "$E/gofmt.out" | tr -d ' ') files)" test ! -s "$E/gofmt.out"
cat "$E/gofmt.out" >&2

go vet ./... > "$E/vet.out" 2>&1; rc=$?
check "d2 go vet ./... (rc=$rc)" test "$rc" = 0 -a ! -s "$E/vet.out"
cat "$E/vet.out" >&2

# d3: the tests mostly wait (fake CLIs, timeouts, the soaks), one after the other they took 3 to 7
# minutes. So each package's -race test binary is built once, its tests are cut into DASH_SHARDS
# groups (default 4, by turns; every soak a group of its own) and the groups run at once, each in
# its own process: the same tests, flags and timeouts. A listed test that no group ran fails d3.
short=""; [ "$quick" = 1 ] && short=-test.short
nsh=${DASH_SHARDS:-4}
case $nsh in ""|*[!0-9]*|0) nsh=4;; esac
: > "$E/test.out"
rc=0 k=0 ntests=0 ngroups=0 missing=""
pkgs=$(go list -f '{{if or .TestGoFiles .XTestGoFiles}}{{.ImportPath}}={{.Dir}}{{end}}' ./... 2>> "$E/test.out") || rc=1
for p in $pkgs; do
  k=$((k + 1)) bin=$E/pkg$k.test dir=${p#*=}
  if ! go test -race -c -o "$bin" "${p%%=*}" >> "$E/test.out" 2>&1; then rc=1; continue; fi
  (cd "$dir" && "$bin" -test.list '.*') 2>> "$E/test.out" | grep '^Test' > "$E/pkg$k.list" || rc=1
  awk -v n="$nsh" '{ if ($1 ~ /Soak$/) print "s" (++s), $1; else print "g" (i++ % n), $1 }' "$E/pkg$k.list" > "$E/pkg$k.groups"
  for g in $(awk '{ print $1 }' "$E/pkg$k.groups" | sort -u); do
    re=$(awk -v g="$g" '$1 == g { printf "%s%s", (c++ ? "|" : ""), $2 }' "$E/pkg$k.groups")
    ngroups=$((ngroups + 1))
    # shellcheck disable=SC2086  # $short is one flag or nothing
    ( cd "$dir" && "$bin" -test.run "^($re)\$" -test.v -test.timeout=10m $short > "$E/pkg$k.$g.out" 2>&1
      echo $? > "$E/pkg$k.$g.rc" ) &
  done
done
wait
k=0
for p in $pkgs; do
  k=$((k + 1))
  for f in "$E"/pkg$k.*.rc; do
    [ -f "$f" ] || continue
    g=${f%.rc}; read -r grc < "$f"
    if [ "$grc" != 0 ]; then rc=1; cat "$g.out" >&2; fi
    grep -E '^(--- |ok|FAIL|PASS$)' "$g.out" | grep -v '^--- PASS' >&2
  done
  while read -r t; do
    ntests=$((ntests + 1))
    cat "$E"/pkg$k.*.out 2> /dev/null | grep -qE "^--- (PASS|SKIP): $t \\(" || missing="$missing $t"
  done < "$E/pkg$k.list"
done
[ -z "$missing" ] || { rc=1; echo "d3: these tests did not run or did not pass:$missing" >&2; }
check "d3 go test -race ./... ($ntests tests in $ngroups groups at once${short:+, -short: no soak}) (rc=$rc)" \
  test "$rc" = 0 -a "$ntests" -gt 0

# d4: the release archive is built in a scratch directory; nothing under addons/ may be in it
if scripts_out=$("$ROOT/scripts/release.sh" --out "$E/rel" 2>&1); then
  tar tzf "$E"/rel/tando-*.tar.gz > "$E/rel.list" 2>&1
  n=$(grep -c '/addons/' "$E/rel.list")
  tot=$(wc -l < "$E/rel.list" | tr -d ' ')
  check "d4 the main release archive has nothing of addons/ ($n entries, of $tot)" test "$n" = 0 -a -s "$E/rel.list"
else
  echo "$scripts_out" >&2
  fail "d4 scripts/release.sh failed: the archive could not be checked"
fi

v=$(tr -d ' \n' < "$ROOT/addons/dashboard/VERSION")
go build -trimpath -ldflags "-s -w -X main.version=$v" -o "$E/tando-dash" . > "$E/build.out" 2>&1; rc=$?
cat "$E/build.out" >&2
out=$("$E/tando-dash" --version 2>&1)
check "d5 tando-dash builds ($(wc -c < "$E/tando-dash" 2> /dev/null | tr -d ' ') bytes) and says $out" \
  test "$rc" = 0 -a "$out" = "tando-dash $v"
check "d6 addons/dashboard/VERSION ($v) is tando's VERSION" t_eq "$v" "$(tr -d ' \n' < "$ROOT/VERSION")"
web_checks
t_done
