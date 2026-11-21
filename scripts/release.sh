#!/bin/bash
# scripts/release.sh: build the client release archive and its checksum, reproducibly.
#
#   scripts/release.sh                 version from VERSION; writes dist/tando-<v>.tar.gz(.sha256)
#   scripts/release.sh --check         build twice in two directories and compare the bytes
#   scripts/release.sh --out DIR       write elsewhere
#
# Same input, same bytes: the archive is written by perl's Archive::Tar from a sorted file list,
# with every entry's mtime set to SOURCE_DATE_EPOCH (default: the newest commit time, else 0),
# uid/gid 0, no user or group names, mode 0755 for executables and 0644 for the rest; gzip
# is IO::Compress::Gzip with no file name and a zero timestamp. Only the files listed below
# ship (no tests, examples or benchmarks).
#
# Contents: tando-<v>/{bin/tando, lib/*.sh, lib/*.js, lib/help.txt, lib/help-conf.txt, server/*, templates/*, completions/*,
# macos/menubar/*.swift, install.sh, uninstall.sh,
# VERSION, README.md, CHANGELOG.md, LICENSE if present}, and the Go server programs for both CPUs as
# server/linux-{amd64,arm64}/<name>, built here by scripts/build-server.sh (Go needed; same Go
# version, same bytes). server/legacy/ does not ship. dist/SHA256SUMS lists the archive.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
cd "$ROOT" || exit 2
out=$ROOT/dist check=0
while [ $# -gt 0 ]; do
  case $1 in
    --out) out=${2:?--out needs a directory}; shift;;
    --check) check=1;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    *) echo "release: unknown argument $1" >&2; exit 2;;
  esac
  shift
done

V=$(tr -d ' \n' < VERSION 2> /dev/null)
case $V in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "release: VERSION must be X.Y.Z (got '$V')" >&2; exit 2;; esac
if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
  SOURCE_DATE_EPOCH=$(git log -1 --format=%ct 2> /dev/null || echo 0)
  [ -n "$SOURCE_DATE_EPOCH" ] || SOURCE_DATE_EPOCH=0
fi
export SOURCE_DATE_EPOCH

# files <gobin>: what ships, "archive path TAB source path" sorted by archive path; the Go programs
# come from <gobin>/linux-<cpu>/ (scripts/build-server.sh --out <gobin>)
files() {
  local f c
  {
    for f in bin/tando lib/*.sh lib/*.js lib/help.txt lib/help-conf.txt server/* templates/* completions/* macos/menubar/*.swift install.sh uninstall.sh VERSION \
             README.md CHANGELOG.md LICENSE; do
      [ -f "$f" ] && printf '%s\t%s\n' "$f" "$f"
    done
    for f in srv/cmd/*/; do
      f=${f%/}; f=${f##*/}
      for c in amd64 arm64; do printf 'server/linux-%s/%s\t%s\n' "$c" "$f" "$1/linux-$c/$f"; done
    done
  } | LC_ALL=C sort -u
}

# build <dir> <gobin>: dir/tando-V.tar.gz, dir/tando-V.tar.gz.sha256, dir/SHA256SUMS
build() {
  local d=$1 a
  mkdir -p "$d" || return 1
  a=$d/tando-$V.tar.gz
  scripts/build-server.sh -q --out "$2" || return 1
  files "$2" | perl -MArchive::Tar -MIO::Compress::Gzip=gzip,\$GzipError -e '
    my ($prefix, $outf, $mtime) = @ARGV;
    my $t = Archive::Tar->new;
    my %dirs;
    while (my $l = <STDIN>) {
      chomp $l;
      my ($f, $src) = split /\t/, $l;
      my @p = split m{/}, $f; pop @p;
      for my $i (0 .. $#p) { $dirs{ join("/", @p[0 .. $i]) } = 1 }
      open my $fh, "<:raw", $src or die "release: $src: $!\n";
      local $/; my $data = <$fh>; close $fh;
      push @{ $main::entries }, [$f, $data, (-x $src ? 0755 : 0644)];
    }
    for my $dir (sort keys %dirs) {
      $t->add_data("$prefix/$dir", "", { type => Archive::Tar::Constant::DIR(), mode => 0755,
        mtime => $mtime, uid => 0, gid => 0, uname => "", gname => "" });
    }
    for my $e (@{ $main::entries }) {
      $t->add_data("$prefix/$e->[0]", $e->[1], { mode => $e->[2], mtime => $mtime,
        uid => 0, gid => 0, uname => "", gname => "" });
    }
    my $tar = $t->write;    # in memory
    gzip(\$tar => $outf, Minimal => 1, Time => 0, Level => 9)
      or die "release: gzip: $GzipError\n";
  ' "tando-$V" "$a" "$SOURCE_DATE_EPOCH" || return 1
  ( cd "$d" && sha256 "tando-$V.tar.gz" > "tando-$V.tar.gz.sha256" && cp "tando-$V.tar.gz.sha256" SHA256SUMS )
}

# sha256 <file>: "<hex>  <file>" with whatever this system has
sha256() {
  if command -v shasum > /dev/null 2>&1; then shasum -a 256 "$1"
  elif command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"
  else openssl dgst -sha256 -r "$1" | sed 's/ \*/  /'
  fi
}

if [ "$check" = 1 ]; then
  t=$(mktemp -d "${TMPDIR:-/tmp}/tando-release.XXXXXX") || exit 2
  trap 'rm -rf "$t"' EXIT
  # the second build compiles from nothing (its own Go cache): the binaries must come out the same
  build "$t/a" "$t/go-a" && sleep 1 && GOCACHE=$t/gocache build "$t/b" "$t/go-b" || exit 1
  if cmp -s "$t/a/tando-$V.tar.gz" "$t/b/tando-$V.tar.gz"; then
    echo "release: reproducible: $(cut -d' ' -f1 < "$t/a/tando-$V.tar.gz.sha256")  tando-$V.tar.gz"
  else
    echo "release: NOT reproducible: two builds differ" >&2; exit 1
  fi
  exit 0
fi

build "$out" "$ROOT/dist/server" || exit 1
echo "release: $(files "$ROOT/dist/server" | wc -l | tr -d ' ') files, SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
echo "  ${out#"$ROOT"/}/tando-$V.tar.gz  $(wc -c < "$out/tando-$V.tar.gz" | tr -d ' ') bytes"
echo "  $(cat "$out/tando-$V.tar.gz.sha256")"
