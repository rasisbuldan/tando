#!/bin/bash
# scripts/release-dashboard.sh: build the dashboard add-on's release assets, reproducibly.
#
#   scripts/release-dashboard.sh                  web app + tando-dash for every platform, into dist/
#   scripts/release-dashboard.sh --out DIR        write elsewhere
#   scripts/release-dashboard.sh --only P[,P]     only these: darwin-universal, linux-amd64, linux-arm64
#   scripts/release-dashboard.sh --skip-web       do not build the web app (the placeholder page is embedded; tests)
#   scripts/release-dashboard.sh --check          build twice (second time with an empty Go cache), compare the bytes
#
# Writes dist/tando-dash-<v>-<platform>.tar.gz and .sha256 (<v> is addons/dashboard/VERSION, which
# is tando's VERSION). Each archive holds one directory, tando-dash-<v>-<platform>/, with
# `tando-dash` (0755), VERSION and LICENSE (when present). darwin-universal is arm64 and amd64
# joined with lipo (macOS only: needs the Command Line Tools). Go builds use CGO_ENABLED=0,
# -trimpath and -ldflags "-s -w -X main.version=<v>".
# Same input, same bytes, as scripts/release.sh: perl's Archive::Tar from a sorted list, every mtime
# SOURCE_DATE_EPOCH (default: the newest commit time, else 0), uid/gid 0, no names, fixed modes;
# gzip with no file name and a zero timestamp. The web app is built by `npm ci && npm run build`
# in addons/dashboard/web (its output is embedded by go:embed; the placeholder is put back after).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
cd "$ROOT" || exit 2
out=$ROOT/dist check=0 only="darwin-universal linux-amd64 linux-arm64" web=1
while [ $# -gt 0 ]; do
  case $1 in
    --out) out=${2:?--out needs a directory}; shift;;
    --only) only=$(printf '%s' "${2:?--only needs a platform list}" | tr ',' ' '); shift;;
    --skip-web) web=0;;
    --check) check=1;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    *) echo "release-dashboard: unknown argument $1" >&2; exit 2;;
  esac
  shift
done
for p in $only; do
  case $p in darwin-universal|linux-amd64|linux-arm64) ;; *) echo "release-dashboard: unknown platform $p" >&2; exit 2;; esac
done
command -v go > /dev/null 2>&1 || { echo "release-dashboard: Go is needed" >&2; exit 2; }
V=$(tr -d ' \n' < addons/dashboard/VERSION 2> /dev/null)
case $V in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "release-dashboard: addons/dashboard/VERSION must be X.Y.Z (got '$V')" >&2; exit 2;; esac
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  SOURCE_DATE_EPOCH=$(git log -1 --format=%ct 2> /dev/null || echo 0)
  [ -n "$SOURCE_DATE_EPOCH" ] || SOURCE_DATE_EPOCH=0
fi
export SOURCE_DATE_EPOCH GOTOOLCHAIN=${GOTOOLCHAIN:-local} GOFLAGS=

sha256() {
  if command -v shasum > /dev/null 2>&1; then shasum -a 256 "$1"
  elif command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"
  else openssl dgst -sha256 -r "$1" | sed 's/ \*/  /'
  fi
}

# gobuild <goos> <goarch> <file>
gobuild() {
  ( cd addons/dashboard/server && CGO_ENABLED=0 GOOS=$1 GOARCH=$2 go build -trimpath -buildvcs=false \
      -ldflags "-s -w -X main.version=$V" -o "$3" . )
}

# binary <platform> <file>: the tando-dash program of a platform
binary() {
  case $1 in
    linux-amd64) gobuild linux amd64 "$2";;
    linux-arm64) gobuild linux arm64 "$2";;
    darwin-universal)
      command -v lipo > /dev/null 2>&1 || { echo "release-dashboard: lipo not found (macOS Command Line Tools): cannot build darwin-universal" >&2; return 1; }
      gobuild darwin arm64 "$2.arm64" && gobuild darwin amd64 "$2.amd64" &&
        lipo -create -output "$2" "$2.arm64" "$2.amd64" && rm -f "$2.arm64" "$2.amd64";;
  esac
}

# pack <dir-name> <out.tar.gz> <file>...: "name TAB source" lines on stdin are the entries
pack() {
  perl -MArchive::Tar -MIO::Compress::Gzip=gzip,\$GzipError -e '
    my ($prefix, $outf, $mtime) = @ARGV;
    my $t = Archive::Tar->new;
    $t->add_data($prefix, "", { type => Archive::Tar::Constant::DIR(), mode => 0755,
      mtime => $mtime, uid => 0, gid => 0, uname => "", gname => "" });
    while (my $l = <STDIN>) {
      chomp $l;
      my ($name, $src) = split /\t/, $l;
      open my $fh, "<:raw", $src or die "release-dashboard: $src: $!\n";
      local $/; my $data = <$fh>; close $fh;
      $t->add_data("$prefix/$name", $data, { mode => (-x $src ? 0755 : 0644), mtime => $mtime,
        uid => 0, gid => 0, uname => "", gname => "" });
    }
    my $tar = $t->write;
    gzip(\$tar => $outf, Minimal => 1, Time => 0, Level => 9) or die "release-dashboard: gzip: $GzipError\n";
  ' "$1" "$2" "$SOURCE_DATE_EPOCH"
}

# build <dir>: dir/tando-dash-V-<platform>.tar.gz(.sha256) for every platform asked for
build() {
  local d=$1 p bin a
  mkdir -p "$d/bin" || return 1
  for p in $only; do
    bin=$d/bin/$p
    binary "$p" "$bin" || return 1
    a=tando-dash-$V-$p.tar.gz
    { printf 'tando-dash\t%s\n' "$bin"; printf 'VERSION\t%s\n' "$ROOT/addons/dashboard/VERSION"
      [ -f LICENSE ] && printf 'LICENSE\t%s\n' "$ROOT/LICENSE"; true; } | LC_ALL=C sort |
      pack "tando-dash-$V-$p" "$d/$a" || return 1
    ( cd "$d" && sha256 "$a" > "$a.sha256" )
  done
}

webbuild() {
  [ "$web" = 1 ] || return 0
  command -v npm > /dev/null 2>&1 || { echo "release-dashboard: npm is needed for the web app (or --skip-web)" >&2; return 1; }
  ( cd addons/dashboard/web && npm ci --no-audit --no-fund > /dev/null && npm run build > /dev/null ) || return 1
}
# the build output is not committed: put the placeholder page back
restore_placeholder() {
  [ "$web" = 1 ] || return 0
  if git ls-files --error-unmatch addons/dashboard/server/webdist/dist/index.html > /dev/null 2>&1; then
    rm -rf addons/dashboard/server/webdist/dist/assets
    git checkout -- addons/dashboard/server/webdist/dist 2> /dev/null
  fi
}

webbuild || { restore_placeholder; exit 1; }
trap restore_placeholder EXIT

if [ "$check" = 1 ]; then
  t=$(mktemp -d "${TMPDIR:-/tmp}/tando-dash-release.XXXXXX") || exit 2
  trap 'rm -rf "$t"; restore_placeholder' EXIT
  build "$t/a" && GOCACHE=$t/gocache build "$t/b" || exit 1
  rc=0
  for p in $only; do
    f=tando-dash-$V-$p.tar.gz
    if cmp -s "$t/a/$f" "$t/b/$f"; then echo "release-dashboard: reproducible: $(cut -d' ' -f1 < "$t/a/$f.sha256")  $f"
    else echo "release-dashboard: NOT reproducible: $f differs between two builds" >&2; rc=1; fi
  done
  exit $rc
fi

mkdir -p "$out" || exit 1
t=$(mktemp -d "${TMPDIR:-/tmp}/tando-dash-release.XXXXXX") || exit 2
trap 'rm -rf "$t"; restore_placeholder' EXIT
build "$t" || exit 1
echo "release-dashboard: tando-dash $V, SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
for p in $only; do
  f=tando-dash-$V-$p.tar.gz
  cp "$t/$f" "$t/$f.sha256" "$out/" || exit 1
  echo "  ${out#"$ROOT"/}/$f  $(wc -c < "$out/$f" | tr -d ' ') bytes"
  echo "  $(cat "$out/$f.sha256")"
done
