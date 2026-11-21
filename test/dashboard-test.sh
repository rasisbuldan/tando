#!/bin/bash
# test/dashboard-test.sh: the dashboard add-on (addons/dashboard): its local server tando-dash.
# No server, no network: the Go tests run a fake tando CLI (the test binary itself).
#
#   d1 gofmt -l prints nothing          d4 the main release archive (scripts/release.sh) holds
#   d2 go vet ./...                        nothing of addons/ (the add-on ships on its own)
#   d3 go test -race ./... (with the    d5 tando-dash builds (stripped) and prints its version
#      2-minute soak; the quick tier
#      passes -short and skips it)      d6 addons/dashboard/VERSION is tando's VERSION (the add-on
#                                          release must match the CLI it is installed for)
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
if ! command -v go > /dev/null 2>&1; then
  skip "d0 Go is not installed: addons/dashboard/server cannot be checked"
  t_done
fi
cd "$D" || exit 1

gofmt -l . > "$E/gofmt.out" 2>&1
check "d1 gofmt -l prints nothing ($(wc -l < "$E/gofmt.out" | tr -d ' ') files)" test ! -s "$E/gofmt.out"
cat "$E/gofmt.out" >&2

go vet ./... > "$E/vet.out" 2>&1; rc=$?
check "d2 go vet ./... (rc=$rc)" test "$rc" = 0 -a ! -s "$E/vet.out"
cat "$E/vet.out" >&2

short=""; [ "$quick" = 1 ] && short=-short
go test -race -count=1 $short ./... > "$E/test.out" 2>&1; rc=$?
[ "$rc" = 0 ] || cat "$E/test.out" >&2
grep -E '^(ok|FAIL|---)' "$E/test.out" >&2
check "d3 go test -race ./...${short:+ (-short: no soak)} (rc=$rc)" test "$rc" = 0

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
t_done
