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

# help_bad <prefix> <tag>: the commands whose `--help` fails (rc != 0 or no output) from this
# install, space-separated in command order. Each runs in its own process, INSTALL_JOBS (8) at a
# time; every result goes to its own file, so the answer does not depend on who finished first.
help_bad() {
  local P=$1 d=$E/help.$2 c i=0 n=${INSTALL_JOBS:-8} bad="" f pids="" p live
  rm -rf "${d:?}"; mkdir -p "$d"
  for c in $(cmds); do
    while :; do   # count only our own jobs (the release build runs in the background too)
      live=0; for p in $pids; do kill -0 "$p" 2> /dev/null && live=$((live + 1)); done
      [ "$live" -lt "$n" ] && break; sleep 0.05
    done
    (
      out=$(cd "$E" && TANDO_CONFIG_DIR=$E/cfg "$P/bin/tando" "$c" --help 2>&1)
      [ $? = 0 ] && [ -n "$out" ] || echo "$c" > "$d/$(printf %04d "$i")"
    ) &
    pids="$pids $!"; i=$((i + 1))
  done
  for p in $pids; do wait "$p"; done
  for f in "$d"/*; do [ -f "$f" ] && bad="$bad $(cat "$f")"; done
  printf '%s' "$bad"
}

# check_tree <prefix> <label>: the installed tree and its commands
check_tree() {
  local P=$1 L=$2 home=$1/lib/tando missing="" p c bad="" out
  # every $TANDO_HOME/<path> the code reads (first path component) must have been installed;
  # srv/, dist/ and scripts/ are read only in a checkout (where srv/go.mod exists: lib/common.sh)
  for p in $(grep -rhoE 'TANDO_HOME/[A-Za-z_.-]+' bin lib | sed 's|TANDO_HOME/||' | sort -u); do
    case $p in srv|dist|scripts) [ ! -e "$home/srv" ] && continue;; esac
    [ "$p" = BUILD ] && continue   # (+<sha> of a git checkout: install.sh writes it only for one)
    [ -e "$home/$p" ] || missing="$missing $p"
  done
  check "$L.1 every \$TANDO_HOME path the code uses is installed${missing:+ (missing:$missing)}" test -z "$missing"
  # and every whole file path the code names there (the first component alone let a missing
  # lib/native.js through: tando 0.2.0's archive lacked it and every Node.js deploy failed at stage)
  missing=""
  for p in $(grep -rhoE 'TANDO_HOME/[A-Za-z0-9_./-]+' bin lib | sed 's|TANDO_HOME/||' | sort -u); do
    case $p in srv/*|dist/*|scripts/*|*/) continue;; esac
    [ -f "$ROOT/$p" ] || continue   # (a prefix such as lib/cmd- or server/linux- is not a file)
    [ -e "$home/$p" ] || missing="$missing $p"
  done
  check "$L.1b every file the code names under \$TANDO_HOME is installed${missing:+ (missing:$missing)}" test -z "$missing"
  for p in templates/github-deploy.yml templates/pre-push lib/help.txt lib/help-conf.txt VERSION; do
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
  bad=$(help_bad "$P" "$L")
  check "$L.3 '<command> --help' works for every command from the install${bad:+ (failed:$bad)}" test -z "$bad"
  out=$(cd "$E" && TANDO_CONFIG_DIR=$E/cfg "$P/bin/tando" ci github --help 2>&1)
  check "$L.4 'ci github --help' from the install" test $? = 0 -a -n "$out"
  # the menu bar app builds from the installed tree alone (its Swift source must ship)
  if [ "$(uname)" = Darwin ] && command -v swiftc > /dev/null 2>&1; then
    out=$(cd "$E" && HOME=$E/home-$L TANDO_CONFIG_DIR=$E/cfg "$P/bin/tando" menubar build --out "$E/mb-$L" 2>&1)
    check "$L.7 'menubar build' compiles the app from the install" \
      eval 'test -x "$E/mb-$L/tando.app/Contents/MacOS/tando-menubar" || { printf "%s\n" "$out" | tail -5 >&2; false; }'
  else skip "$L.7 'menubar build' needs macOS and swiftc"; fi
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

# the release archive (about 30 s, reads only the checkout) is built while the first install and its
# checks run; I2 waits for it
rm -rf "${E:?}/dist"
/bin/bash scripts/release.sh --out "$E/dist" > "$E/rel.out" 2>&1 &
relpid=$!

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
  case $out in "tando $v"|"tando $v+"*) ;; *) bad="$bad $l";; esac   # (a checkout's version has +<sha>)
  out=$(cd / && TANDO_CONFIG_DIR=$E/cfg "$E/$l" host --help 2>&1)
  [ -n "$out" ] || bad="$bad $l(help)"
done
check "I5 the launcher works through Homebrew, Debian, npm and absolute symlinks${bad:+ (failed:$bad)}" test -z "$bad"

wait "$relpid"
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
