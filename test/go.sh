#!/bin/bash
# test/go.sh: the Go server programs (srv/, see srv/README.md). No server, no network.
#
#   g1 gofmt -l prints nothing       g4 no shell, one place that starts programs, a closed list of
#   g2 go vet ./...                     programs (srv/tools/srvlint on the syntax trees, after the
#   g3 go test ./...                    regex rules RL15, RL16 of test/lint.pl as a cheap first line)
#   g8 go test -race ./...           g5 the layering (srvlint: cmd -> daemon -> domain -> internal)
#   g7 srv/gate's and internal/lock's Linux-only tests g6 static Linux binaries for amd64 and arm64
#      in a throwaway container (Docker; SKIP without it)
#
# Flags (default: everything, with Go's test cache and g3/g8/g7 overlapped):
#   --quick, GO_QUICK=1       skip g8 (the race detector, the slowest check); prints a SKIP line
#   --no-cache, GO_NOCACHE=1  go test -count=1: nothing served from Go's test cache (full/nightly runs)
#   GO_SERIAL=1               no overlap: g3, then g8, then g7 (for timing and for a loaded machine)
# A cached package result is reused only while the package, its dependencies, the files and
# environment variables its tests read through the os package, and the flags are unchanged; tests
# that depend on the clock, the network or other host state are not tracked by Go: run --no-cache
# before a release.
#
# Output: PASS/FAIL lines (docs/TESTING.md), a summary, the exit status. Needs Go (srv/go.mod).
set -u
quick=${GO_QUICK:-0} nocache=${GO_NOCACHE:-0}
while [ $# -gt 0 ]; do
  case $1 in
    --quick) quick=1;;
    --no-cache) nocache=1;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    *) echo "go.sh: unknown option $1" >&2; exit 2;;
  esac
  shift
done
cnt=""; [ "$nocache" = 0 ] || cnt="-count=1"
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init go
mkdir -p "$E"
cd "$ROOT/srv" || exit 1
export GOTOOLCHAIN=local GOFLAGS=
if ! command -v go > /dev/null 2>&1; then
  skip "g0 Go is not installed: srv/ cannot be checked"
  t_done
fi

gofmt -l . > "$E/gofmt.out" 2>&1
check "g1 gofmt -l prints nothing ($(wc -l < "$E/gofmt.out" | tr -d ' ') files)" test ! -s "$E/gofmt.out"
cat "$E/gofmt.out" >&2

go vet ./... > "$E/vet.out" 2>&1; rc=$?
check "g2 go vet ./... (rc=$rc)" test "$rc" = 0 -a ! -s "$E/vet.out"
cat "$E/vet.out" >&2

# g7 (a Linux container, mostly waiting for Docker) and g8 (the race detector, mostly compiling) do
# not need each other's results: start them now, in the background, and collect them below.
serial=${GO_SERIAL:-0}
g7_run() { # writes $E/g7.* ; the check itself is made in g7 below, in order
  local garch
  garch=$(uname -m); case $garch in arm64|aarch64) garch=arm64;; *) garch=amd64;; esac
  echo "$garch" > "$E/g7.arch"
  if ! docker image inspect ubuntu:24.04 > /dev/null 2>&1; then echo skip > "$E/g7.state"
  elif ! GOOS=linux GOARCH=$garch CGO_ENABLED=0 go test -c -o "$E/gate.test" ./gate > "$E/gate-test-build.out" 2>&1 ||
       ! GOOS=linux GOARCH=$garch CGO_ENABLED=0 go test -c -o "$E/lock.test" ./internal/lock >> "$E/gate-test-build.out" 2>&1; then
    echo build > "$E/g7.state"
  else
    # (internal/lock too: its probe reads /proc/locks, which only Linux has)
    docker run --rm --name "tando-go-unit-$$" -v "$E/gate.test:/gate.test:ro" -v "$E/lock.test:/lock.test:ro" ubuntu:24.04 sh -c \
      'useradd -m u && su u -c "cd /tmp && /gate.test -test.count=1" && cd /tmp && /gate.test -test.count=1 && /lock.test -test.count=1' > "$E/gate-linux.out" 2>&1
    echo "run $?" > "$E/g7.state"
  fi
}
# g8: the race detector over every package (cgo and a C compiler are needed for -race: without
# them the check is skipped with the reason, not failed)
g8_run() {
  if go test -race $cnt -run '^$' ./internal/run > "$E/race-probe.out" 2>&1; then
    go test -race $cnt ./... > "$E/race.out" 2>&1; echo "run $?" > "$E/g8.state"
  else echo noprobe > "$E/g8.state"; fi
}
rm -f "$E"/g7.* "$E"/g8.state
g7pid="" g8pid=""
if [ "$serial" = 0 ]; then
  g7_run & g7pid=$!
  [ "$quick" = 1 ] || { g8_run & g8pid=$!; }
fi

go test $cnt ./... > "$E/test.out" 2>&1; rc=$?
cat "$E/test.out" >&2
check "g3 go test ./... ($(grep -c '^ok' "$E/test.out") packages ok, rc=$rc)" test "$rc" = 0

if [ "$quick" = 1 ]; then
  skip "g8 go test -race: skipped by --quick/GO_QUICK=1 (run without it before pushing)"
else
  [ "$serial" = 0 ] || g8_run
  [ -z "$g8pid" ] || wait "$g8pid"
  read -r st rc < "$E/g8.state"
  if [ "$st" = run ]; then
    cat "$E/race.out" >&2
    check "g8 go test -race ./... ($(grep -c '^ok' "$E/race.out") packages ok, rc=$rc)" test "$rc" = 0
  else
    skip "g8 go test -race: the race detector does not work here ($(head -n 1 "$E/race-probe.out"))"
  fi
fi

# g4: the regex rules first (cheap; they read lines, so an alias or a split literal gets past them),
# then srvlint, which reads the syntax trees: os/exec imported only by srv/internal/run (under any
# name), no os.StartProcess/syscall.Exec/ForkExec, raw syscalls only with the numbers of its list,
# no shell (folded constants, -c/-lc/-ec after one) in a call into run, every program a constant
# and listed in srv/tools/srvlint/programs.txt, no module but the standard library
# shellcheck disable=SC2046 # Go file names have no spaces (gofmt and the go tool refuse them)
(cd "$ROOT" && test/lint.sh --no-shellcheck $(find srv -name '*.go' -not -path 'srv/tools/*')) > "$E/lint.out" 2>&1; rc=$?
cat "$E/lint.out" >&2
go run ./tools/srvlint -checks=noshell ./... > "$E/srvlint.out" 2>&1; rc2=$?
cat "$E/srvlint.out" >&2
check "g4 no shell, os/exec only in srv/internal/run, a closed list of programs (lint RL15/RL16 rc=$rc, srvlint rc=$rc2)" test "$rc" = 0 -a "$rc2" = 0

# g5: internal/* imports no domain package; a domain package imports no other domain package;
# daemon (the composition of tandod) imports the domain packages, and only cmd/* imports daemon
# (daemon/proto: also tando-watch and tando-status); no exceptions (srvlint)
go run ./tools/srvlint -checks=layers ./... > "$E/layers.out" 2>&1; rc=$?
cat "$E/layers.out" >&2
check "g5 layering: cmd -> daemon -> domain -> internal, no domain imports another (rc=$rc)" test "$rc" = 0

"$ROOT/scripts/build-server.sh" -q --out "$E/bin" > "$E/build.out" 2>&1; rc=$?
bad=""
for c in amd64:x86-64 arm64:aarch64; do
  for f in "$E/bin/linux-${c%%:*}"/*; do
    file "$f" | grep -q "ELF 64-bit.*${c#*:}.*statically linked" || bad="$bad ${f#"$E"/bin/}"
  done
done
check "g6 every server program builds static for linux/amd64 and linux/arm64 (rc=$rc${bad:+, not:$bad})" \
  test "$rc" = 0 -a -z "$bad"

# g7: srv/gate's Linux-only tests (fs_linux_test.go: the descriptor walk, a directory swapped for a
# symlink while it is walked, a 000 directory in an upload) and the whole package once more, in a
# throwaway Linux container of this machine's CPU, as a normal user and as root (some tests need
# one, some the other). Needs Docker and the ubuntu:24.04 image (nothing is pulled).
[ "$serial" = 0 ] || g7_run
[ -z "$g7pid" ] || wait "$g7pid"
garch=$(cat "$E/g7.arch"); read -r st rc < "$E/g7.state"
case $st in
  skip) skip "g7 srv/gate Linux tests: no Docker or no ubuntu:24.04 image here (docker pull ubuntu:24.04 enables them)";;
  build) cat "$E/gate-test-build.out" >&2
    fail "g7 srv/gate Linux tests: the test binary does not build for linux/$garch";;
  *) cat "$E/gate-linux.out" >&2
    check "g7 srv/gate (as a user and as root) and internal/lock Linux tests in a linux/$garch container (rc=$rc)" test "$rc" = 0;;
esac
t_done
