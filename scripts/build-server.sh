#!/bin/bash
# scripts/build-server.sh: build the Go server programs (srv/cmd/*) for Linux, both CPU types.
#
#   scripts/build-server.sh              dist/server/linux-amd64/<name>, dist/server/linux-arm64/<name>
#   scripts/build-server.sh --out DIR    DIR/linux-<arch>/<name> instead
#   scripts/build-server.sh -q           no output unless something fails
#
# Static (CGO_ENABLED=0) and reproducible: -trimpath, no build id, no VCS stamp, the default CPU
# levels (GOAMD64=v1, GOARM64=v8.0) whatever the environment says, the version from VERSION
# (`<name> version` prints it). Same source and Go version, same bytes; a binary whose bytes did
# not change is not rewritten. Needs Go (see srv/go.mod); nothing is downloaded (GOTOOLCHAIN=local,
# no dependencies). Run by `tando host setup` from a checkout, and by scripts/release.sh.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
out=$ROOT/dist/server quiet=0
while [ $# -gt 0 ]; do
  case $1 in
    --out) out=${2:?--out needs a directory}; shift;;
    -q) quiet=1;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    *) echo "build-server: unknown argument $1" >&2; exit 2;;
  esac
  shift
done
command -v go > /dev/null 2>&1 || { echo "build-server: Go is not installed (https://go.dev/dl/)" >&2; exit 1; }
V=$(tr -d ' \n' < "$ROOT/VERSION" 2> /dev/null)
case $V in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "build-server: VERSION must be X.Y.Z (got '$V')" >&2; exit 2;; esac
cd "$ROOT/srv" || exit 2

for arch in amd64 arm64; do
  mkdir -p "$out/linux-$arch" || exit 1
  for d in cmd/*/; do
    n=${d#cmd/}; n=${n%/}
    f=$out/linux-$arch/$n
    env CGO_ENABLED=0 GOOS=linux GOARCH=$arch GOAMD64=v1 GOARM64=v8.0 GOFLAGS= GOTOOLCHAIN=local \
      go build -trimpath -buildvcs=false -ldflags "-s -w -buildid= -X tando/srv/internal/buildinfo.Version=$V" \
      -o "$f.new.$$" "./$d" || { rm -f "$f.new.$$"; echo "build-server: $n for linux/$arch failed" >&2; exit 1; }
    if cmp -s "$f.new.$$" "$f"; then rm -f "$f.new.$$"; else mv -f "$f.new.$$" "$f" || exit 1; fi
    [ "$quiet" = 1 ] || printf 'build-server: %-34s %s bytes\n' "${f#"$ROOT"/}" "$(wc -c < "$f" | tr -d ' ')"
  done
done
[ "$quiet" = 1 ] || echo "build-server: $(go version | cut -d' ' -f3-), version $V"
