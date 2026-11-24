#!/bin/bash
# install.sh: install the tando client as a self-contained tree with a `tando` command on PATH.
#
#   ./install.sh                         from this checkout (or an unpacked release) into ~/.local
#   ./install.sh --prefix DIR            into DIR (DIR/bin/tando, DIR/lib/tando/...)
#   ./install.sh --system                into /usr/local, using sudo when it is not writable
#   ./install.sh --from FILE|URL         from a release archive (.tar.gz): a path, file://, https://
#   ./install.sh --version 0.2.0         from the GitHub release v0.2.0 of $TANDO_REPO
#   --sha256 HEX                         expected checksum of the archive; without it the archive's
#                                        <url>.sha256 is fetched from the same place
#   --insecure                           allow a plain http:// --from (refused otherwise: the archive
#                                        and its .sha256 could both be swapped on the way)
#   --no-completions                     skip the bash and zsh completion files
#
# Needs only what tando needs: /bin/bash (3.2 or newer), ssh, rsync, and curl for downloads.
# Layout: PREFIX/lib/tando/ holds bin/, lib/, server/ (with the Go programs in server/linux-<cpu>/),
# templates/, completions/, macos/ (the menu bar app's source: tando menubar install), VERSION, .manifest;
# PREFIX/bin/tando is a symlink to it; completions go to PREFIX/share/bash-completion/completions/tando
# and PREFIX/share/zsh/site-functions/_tando. An update replaces the tree in one rename.
# uninstall.sh removes exactly what .manifest lists. Settings in ~/.config/tando are never touched.
set -u
REPO=${TANDO_REPO:-rasisbuldan/tando}
prefix=$HOME/.local system=0 from="" version="" sum="" comps=1 SUDO="" insecure=0 proto="=https,file"

die() { echo "install: $*" >&2; exit 1; }
say() { echo "install: $*"; }
while [ $# -gt 0 ]; do
  case $1 in
    --prefix) prefix=${2:-}; shift;;
    --system) system=1; prefix=/usr/local;;
    --from) from=${2:-}; shift;;
    --version) version=${2:-}; shift;;
    --sha256) sum=${2:-}; shift;;
    --no-completions) comps=0;;
    --insecure) insecure=1;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    *) die "unknown argument: $1 (see --help)";;
  esac
  shift
done
case $prefix in /*) ;; "") die "--prefix needs a directory";; *) prefix=$PWD/$prefix;; esac
case $prefix in *[[:space:]]*) die "prefix paths with spaces are not supported: $prefix";; esac
prefix=${prefix%/}

# ---- requirements ------------------------------------------------------------------------------

[ -x /bin/bash ] || die "/bin/bash is missing: tando scripts start with #!/bin/bash"
for t in ssh rsync; do
  command -v $t > /dev/null 2>&1 || echo "install: warning: $t not found (tando needs it to talk to servers)" >&2
done

sha256() {
  if command -v shasum > /dev/null 2>&1; then shasum -a 256 "$1"
  elif command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"
  elif command -v openssl > /dev/null 2>&1; then openssl dgst -sha256 -r "$1"
  else die "no shasum, sha256sum or openssl to verify the download"
  fi | cut -d' ' -f1
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tando-install.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT

# ---- source tree -------------------------------------------------------------------------------

if [ -n "$version" ]; then
  case $version in v*) version=${version#v};; esac
  case $version in *[!0-9.]*|"") die "bad version: $version";; esac
  case $REPO in OWNER/*) die "set TANDO_REPO=<owner>/<repo> (this install.sh has no default)";; esac
  from=https://github.com/$REPO/releases/download/v$version/tando-$version.tar.gz
fi

if [ -n "$from" ]; then
  command -v curl > /dev/null 2>&1 || case $from in /*) ;; *) die "curl is needed to download $from";; esac
  case $from in
    http://*)
      [ "$insecure" = 1 ] || die "refusing plain http: $from (the archive and its .sha256 could both be
  swapped on the way). Use https://, a file path, or --insecure with --sha256 HEX from a trusted place"
      proto="=https,file,http";;
  esac
  # a relative path (dist/tando-0.2.2.tar.gz) is a path too
  case $from in /*|file://*|http://*|https://*) ;; *) [ ! -f "$from" ] || from=$PWD/$from;; esac
  case $from in
    /*) cp "$from" "$tmp/a.tgz" || die "cannot read $from"
        [ -n "$sum" ] || [ ! -f "$from.sha256" ] || sum=$(cut -d' ' -f1 < "$from.sha256");;
    file://*|http://*|https://*)
      say "downloading $from"
      curl -fsSL --proto "$proto" --proto-redir "$proto" -o "$tmp/a.tgz" "$from" || die "download failed: $from"
      if [ -z "$sum" ]; then
        curl -fsSL --proto "$proto" --proto-redir "$proto" -o "$tmp/a.sha256" "$from.sha256" ||
          die "no checksum: $from.sha256 not found (pass --sha256 HEX)"
        sum=$(cut -d' ' -f1 < "$tmp/a.sha256")
      fi;;
    *) die "--from takes a path, a file:// or an https:// URL";;
  esac
  [ -n "$sum" ] || die "no checksum for $from (pass --sha256 HEX, or put $from.sha256 next to it)"
  case $sum in *[!0-9a-fA-F]*) die "bad checksum: $sum";; esac
  got=$(sha256 "$tmp/a.tgz")
  [ "$got" = "$(printf '%s' "$sum" | tr 'A-F' 'a-f')" ] || die "checksum mismatch: expected $sum, got $got"
  say "checksum ok ($got)"
  # refuse absolute names and ".." before unpacking
  tar -tzf "$tmp/a.tgz" > "$tmp/list" || die "not a tar.gz archive"
  if grep -qE '^/|(^|/)\.\.(/|$)' "$tmp/list"; then die "archive has unsafe paths"; fi
  mkdir "$tmp/x" || die "mktemp dir vanished"
  tar -xzf "$tmp/a.tgz" -C "$tmp/x" || die "cannot unpack the archive"
  src=$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ "$(find "$tmp/x" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1 ] || die "archive must hold one directory"
else
  src=$(cd "$(dirname "$0")" && pwd -P)
fi
[ -f "$src/bin/tando" ] && [ -f "$src/lib/common.sh" ] && [ -d "$src/server" ] ||
  die "$src does not look like tando (bin/tando, lib/common.sh, server/)"
ver=$(tr -d ' \n' < "$src/VERSION" 2> /dev/null)
[ -n "$ver" ] || ver=unknown

# ---- install -----------------------------------------------------------------------------------

mkdir -p "$prefix" 2> /dev/null
if [ ! -w "$prefix" ] || { [ -d "$prefix/lib" ] && [ ! -w "$prefix/lib" ]; }; then
  [ "$system" = 1 ] || die "$prefix is not writable (use --system for /usr/local with sudo, or --prefix)"
  SUDO="sudo"
  say "using sudo for $prefix"
fi
run() { $SUDO "$@"; }

dest=$prefix/lib/tando
run mkdir -p "$prefix/lib" "$prefix/bin" || die "cannot create $prefix/lib and $prefix/bin"
new=$(run mktemp -d "$prefix/lib/.tando-new.XXXXXX") || die "cannot write to $prefix/lib"
for d in bin lib server templates completions macos; do   # what tando reads from $TANDO_HOME
  [ -d "$src/$d" ] && { run cp -R "$src/$d" "$new/" || die "copy failed"; }
done
for f in VERSION README.md CHANGELOG.md LICENSE install.sh uninstall.sh; do
  [ -f "$src/$f" ] && { run cp "$src/$f" "$new/" || die "copy failed"; }
done
# BUILD: "+<short sha>[-dirty]" when this is a git checkout that is not exactly its release tag
# (tando --version and the server's VERSION show 0.2.2+abc1234; versions are compared without it).
# A release archive has no .git: no BUILD file, the version is plain.
rm -f "$new/BUILD"
if [ -e "$src/.git" ] && command -v git > /dev/null 2>&1 && bsha=$(git -C "$src" rev-parse --short=7 HEAD 2> /dev/null) && [ -n "$bsha" ]; then
  bd=""; [ -z "$(git -C "$src" status --porcelain --untracked-files=no 2> /dev/null)" ] || bd=-dirty
  if git -C "$src" describe --exact-match --tags --match "v$ver" HEAD > /dev/null 2>&1 && [ -z "$bd" ]; then :
  else printf '+%s%s\n' "$bsha" "$bd" | run tee "$new/BUILD" > /dev/null || die "copy failed"; fi
fi
# the Go server programs: a release has them in server/linux-<cpu>/ (copied above); a checkout
# builds them into dist/server/linux-<cpu>/ (scripts/build-server.sh, which needs Go) and keeps
# the shell programs they replaced in server/legacy/, which are not installed
if [ -f "$src/srv/go.mod" ]; then
  run rm -rf "${new:?}/server/legacy"
  if command -v go > /dev/null 2>&1; then
    "$src/scripts/build-server.sh" -q || die "could not build the server programs (scripts/build-server.sh)"
  fi
  for c in amd64 arm64; do
    run mkdir -p "$new/server/linux-$c" || die "copy failed"
    for d in "$src"/srv/cmd/*/; do
      n=${d%/}; n=${n##*/}
      [ -f "$src/dist/server/linux-$c/$n" ] ||
        die "missing dist/server/linux-$c/$n: build it with scripts/build-server.sh (needs Go)"
      run cp "$src/dist/server/linux-$c/$n" "$new/server/linux-$c/" || die "copy failed"
    done
  done
fi
run chmod -R u+rwX,go+rX,go-w "$new"
run chmod 755 "$new/bin/tando"
# the manifest lists every path outside the tree that uninstall.sh may remove
{
  echo "# tando $ver installed $(date -u +%Y-%m-%dT%H:%M:%SZ) from ${from:-$src}"
  echo "$prefix/bin/tando"
  if [ "$comps" = 1 ]; then
    [ -f "$src/completions/tando.bash" ] && echo "$prefix/share/bash-completion/completions/tando"
    [ -f "$src/completions/_tando" ] && echo "$prefix/share/zsh/site-functions/_tando"
  fi
} > "$tmp/manifest"
run cp "$tmp/manifest" "$new/.manifest"

# swap the trees: one rename makes the new version live; the old one is removed afterwards
old=""
if [ -e "$dest" ]; then
  old=$prefix/lib/.tando-old.$(date +%s)
  run mv "$dest" "$old" || die "cannot move the old install aside"
fi
run mv "$new" "$dest" || { [ -n "$old" ] && run mv "$old" "$dest"; die "cannot put the new install in place"; }
[ -n "$old" ] && run rm -rf "${old:?}"

run ln -sfn ../lib/tando/bin/tando "$prefix/bin/tando" || die "cannot link $prefix/bin/tando"
if [ "$comps" = 1 ]; then
  if [ -f "$dest/completions/tando.bash" ]; then
    run mkdir -p "$prefix/share/bash-completion/completions" &&
      run cp "$dest/completions/tando.bash" "$prefix/share/bash-completion/completions/tando"
  fi
  if [ -f "$dest/completions/_tando" ]; then
    run mkdir -p "$prefix/share/zsh/site-functions" &&
      run cp "$dest/completions/_tando" "$prefix/share/zsh/site-functions/_tando"
  fi
fi

"$prefix/bin/tando" help > /dev/null 2>&1 || die "installed, but $prefix/bin/tando help fails"
say "tando $ver installed: $prefix/bin/tando -> $dest"
case ":$PATH:" in
  *":$prefix/bin:"*) ;;
  *) say "add $prefix/bin to PATH, e.g.  echo 'export PATH=\"$prefix/bin:\$PATH\"' >> ~/.zshrc";;
esac
if [ "$comps" = 1 ] && [ -f "$dest/completions/_tando" ]; then
  say "zsh completion: add  fpath=($prefix/share/zsh/site-functions \$fpath)  before compinit"
fi
