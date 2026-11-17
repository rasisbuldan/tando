#!/bin/bash
# test/install-test.sh: install tando from this checkout and from a release archive into throwaway
# prefixes, then prove the installed tree is complete: every path bin/ and lib/ read under
# $TANDO_HOME exists there, every command's --help works from the installed launcher (plus
# `ci github --help`), and uninstall removes it. No server, no network. One PASS/FAIL line each.
# Usage: test/install-test.sh
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init install
cd "$ROOT" || exit 1

# commands: help.txt sections (not "overview") and plugins without a section
cmds() {
  sed -n 's/^@@ \([a-z-]*\)$/\1/p' lib/help.txt | grep -v '^overview$'
  for f in lib/cmd-*.sh; do
    n=${f##*/cmd-}; n=${n%.sh}
    [ "$n" = logx ] && continue
    grep -q "^@@ $n\$" lib/help.txt || echo "$n"
  done
}

# check_tree <prefix> <label>: the installed tree and its commands
check_tree() {
  local P=$1 L=$2 home=$1/lib/tando missing="" p c bad="" out
  # every $TANDO_HOME/<path> the code reads (first path component) must have been installed;
  # srv/, dist/ and scripts/ are read only in a checkout (where srv/go.mod exists: lib/common.sh)
  for p in $(grep -rhoE 'TANDO_HOME/[A-Za-z_.-]+' bin lib | sed 's|TANDO_HOME/||' | sort -u); do
    case $p in srv|dist|scripts) [ ! -e "$home/srv" ] && continue;; esac
    [ -e "$home/$p" ] || missing="$missing $p"
  done
  check "$L.1 every \$TANDO_HOME path the code uses is installed${missing:+ (missing:$missing)}" test -z "$missing"
  for p in templates/github-deploy.yml templates/pre-push lib/help.txt VERSION; do
    [ -e "$ROOT/$p" ] && { [ -e "$home/$p" ] || missing="$missing $p"; }
  done
  check "$L.2 templates, help.txt and VERSION installed${missing:+ (missing:$missing)}" test -z "$missing"
  # the Go server programs, one static binary per CPU, and not the shell programs they replaced
  missing=""
  for p in $(cd "$ROOT/srv/cmd" && ls); do
    for c in amd64:x86-64 arm64:aarch64; do
      file "$home/server/linux-${c%%:*}/$p" 2> /dev/null | grep -q "ELF 64-bit.*${c#*:}.*statically" &&
        [ -x "$home/server/linux-${c%%:*}/$p" ] || missing="$missing server/linux-${c%%:*}/$p"
    done
    [ -e "$home/server/$p" ] && missing="$missing (and the old server/$p)"
  done
  [ -e "$home/server/legacy" ] && missing="$missing (and server/legacy)"
  check "$L.6 the Go server programs for amd64 and arm64${missing:+ (missing:$missing)}" test -z "$missing"
  for c in $(cmds); do
    out=$(cd "$E" && TANDO_CONFIG_DIR=$E/cfg "$P/bin/tando" "$c" --help 2>&1)
    [ $? = 0 ] && [ -n "$out" ] || bad="$bad $c"
  done
  check "$L.3 '<command> --help' works for every command from the install${bad:+ (failed:$bad)}" test -z "$bad"
  out=$(cd "$E" && TANDO_CONFIG_DIR=$E/cfg "$P/bin/tando" ci github --help 2>&1)
  check "$L.4 'ci github --help' from the install" test $? = 0 -a -n "$out"
  out=$(cd "$E" && TANDO_CONFIG_DIR=$E/cfg "$P/bin/tando" version 2>&1)
  check "$L.5 'version' reports $(cat VERSION) from the install ($out)" \
    eval 'printf "%s" "$out" | grep -qF "$(cat VERSION)"'
}

# the install script travels inside single quotes (lib/common.sh): no single quote may be in it,
# and it must parse; its recovery part is the file shipped as tando-install-recover
TANDO_HOME=$ROOT bash -c '. "$1/lib/common.sh"; install_helpers_script' _ "$ROOT" > "$E/ihs.sh" 2> /dev/null
check "I0 the server-side install script has no single quote and parses (bash -n)" \
  eval '! grep -q "'"'"'" "$E/ihs.sh" && bash -n "$E/ihs.sh" && grep -q "^recover()" "$E/ihs.sh"'
check "I0 tando-install-recover is executable and parses" eval '[ -x server/tando-install-recover ] && bash -n server/tando-install-recover'

P1=$E/p-checkout
/bin/bash install.sh --prefix "$P1" > "$E/i1.out" 2>&1
check "I1 install from the checkout (rc=$?)" test -x "$P1/bin/tando"
check_tree "$P1" I1

# the launcher finds its tree through the symlinks packages make (packaging/): Homebrew (bin/tando
# -> ../Cellar/tando/V/bin/tando -> ../libexec/bin/tando, both relative), Debian (/usr/bin/tando ->
# ../lib/tando/bin/tando), npm (bin/tando -> ../lib/node_modules/tando-cli/bin/tando), and an
# absolute link; run from / so nothing is found by accident in the current directory
v=$(cat VERSION) bad=""
mkdir -p "$E/hb/Cellar/tando/$v/bin" "$E/hb/bin" "$E/deb/usr/bin" "$E/deb/usr/lib" "$E/npm/bin" \
  "$E/npm/lib/node_modules" "$E/abs"
cp -R "$P1/lib/tando" "$E/hb/Cellar/tando/$v/libexec"
ln -s ../libexec/bin/tando "$E/hb/Cellar/tando/$v/bin/tando"
ln -s "../Cellar/tando/$v/bin/tando" "$E/hb/bin/tando"
cp -R "$P1/lib/tando" "$E/deb/usr/lib/tando"
ln -s ../lib/tando/bin/tando "$E/deb/usr/bin/tando"
cp -R "$P1/lib/tando" "$E/npm/lib/node_modules/tando-cli"
ln -s ../lib/node_modules/tando-cli/bin/tando "$E/npm/bin/tando"
ln -s "$E/deb/usr/lib/tando/bin/tando" "$E/abs/tando"
for l in hb/bin/tando deb/usr/bin/tando npm/bin/tando abs/tando; do
  out=$(cd / && TANDO_CONFIG_DIR=$E/cfg "$E/$l" version 2>&1 | head -1)
  [ "$out" = "tando $v" ] || bad="$bad $l"
  out=$(cd / && TANDO_CONFIG_DIR=$E/cfg "$E/$l" host --help 2>&1)
  [ -n "$out" ] || bad="$bad $l(help)"
done
check "I5 the launcher works through Homebrew, Debian, npm and absolute symlinks${bad:+ (failed:$bad)}" test -z "$bad"

/bin/bash scripts/release.sh --out "$E/dist" > "$E/rel.out" 2>&1
v=$(cat VERSION)
check "I2 release archive builds" test -s "$E/dist/tando-$v.tar.gz"
P2=$E/p-archive
/bin/bash install.sh --prefix "$P2" --from "$E/dist/tando-$v.tar.gz" > "$E/i2.out" 2>&1
check "I2 install from the release archive, checksum verified" grep -q 'checksum ok' "$E/i2.out"
check_tree "$P2" I2

(cd "$E" && "$ROOT/install.sh" --prefix "$E/p-rel" --from "dist/tando-$v.tar.gz" > "$E/irel.out" 2>&1); rc=$?
check "I3r install.sh runs by itself (executable) and takes a relative --from path (rc=$rc)" \
  eval '[ $rc = 0 ] && [ "$("$E/p-rel/bin/tando" version 2> /dev/null | head -1)" = "tando $v" ]'
nox=$(for f in install.sh uninstall.sh bin/tando server/tando-*; do [ -x "$ROOT/$f" ] || printf '%s ' "$f"; done)
check "I3x every program is executable in the tree (not: ${nox:-none})" test -z "$nox"
out=$(/bin/bash install.sh --prefix "$E/p-http" --from "http://127.0.0.1:9/tando-$v.tar.gz" 2>&1); rc=$?
check "I4 a plain http:// --from is refused before anything is fetched (rc=$rc)" \
  eval 'test $rc != 0 && printf "%s" "$out" | grep -q "refusing plain http" && [ ! -e "$E/p-http" ]'
/bin/bash uninstall.sh --prefix "$P2" > "$E/u2.out" 2>&1
check "I3 uninstall removes the tree and the launcher" \
  eval '[ ! -e "$P2/lib/tando" ] && [ ! -e "$P2/bin/tando" ] && [ ! -L "$P2/bin/tando" ]'
t_done
