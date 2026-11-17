#!/bin/bash
# test/go.sh: the Go server programs (srv/, see srv/README.md). No server, no network.
#
#   g1 gofmt -l prints nothing       g4 no shell, one place that starts programs, a closed list of
#   g2 go vet ./...                     programs (srv/tools/srvlint on the syntax trees, after the
#   g3 go test ./...                    regex rules RL15, RL16 of test/lint.pl as a cheap first line)
#   g8 go test -race ./...           g5 the layering (srvlint: cmd -> daemon -> domain -> internal)
#   g7 srv/gate's Linux-only tests   g6 static Linux binaries for amd64 and arm64
#      in a throwaway container (Docker; SKIP without it)
#
# Output: PASS/FAIL lines (docs/TESTING.md), a summary, the exit status. Needs Go (srv/go.mod).
set -u
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

go test -count=1 ./... > "$E/test.out" 2>&1; rc=$?
cat "$E/test.out" >&2
check "g3 go test ./... ($(grep -c '^ok' "$E/test.out") packages ok, rc=$rc)" test "$rc" = 0

# g8: the race detector over every package (cgo and a C compiler are needed for -race: without
# them the check is skipped with the reason, not failed)
if go test -race -count=1 -run '^$' ./internal/run > "$E/race-probe.out" 2>&1; then
  go test -race -count=1 ./... > "$E/race.out" 2>&1; rc=$?
  cat "$E/race.out" >&2
  check "g8 go test -race ./... ($(grep -c '^ok' "$E/race.out") packages ok, rc=$rc)" test "$rc" = 0
else
  skip "g8 go test -race: the race detector does not work here ($(head -n 1 "$E/race-probe.out"))"
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
garch=$(uname -m); case $garch in arm64|aarch64) garch=arm64;; *) garch=amd64;; esac
if ! docker image inspect ubuntu:24.04 > /dev/null 2>&1; then
  skip "g7 srv/gate Linux tests: no Docker or no ubuntu:24.04 image here (docker pull ubuntu:24.04 enables them)"
elif ! GOOS=linux GOARCH=$garch CGO_ENABLED=0 go test -c -o "$E/gate.test" ./gate > "$E/gate-test-build.out" 2>&1; then
  cat "$E/gate-test-build.out" >&2
  fail "g7 srv/gate Linux tests: the test binary does not build for linux/$garch"
else
  docker run --rm --name "tando-go-unit-$$" -v "$E/gate.test:/gate.test:ro" ubuntu:24.04 sh -c \
    'useradd -m u && su u -c "cd /tmp && /gate.test -test.count=1" && cd /tmp && /gate.test -test.count=1' > "$E/gate-linux.out" 2>&1; rc=$?
  cat "$E/gate-linux.out" >&2
  check "g7 srv/gate Linux tests in a linux/$garch container, as a user and as root (rc=$rc)" test "$rc" = 0
fi
t_done
