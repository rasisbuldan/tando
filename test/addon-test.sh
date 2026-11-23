#!/bin/bash
# test/addon-test.sh: `tando addon` (lib/cmd-addon.sh), `tando dashboard` (lib/cmd-dashboard.sh) and
# scripts/release-dashboard.sh. No server, no network, nothing outside the work directory: HOME is
# a temp directory, the archive is built here (--skip-web: the placeholder page is embedded) and
# installed with --from.
#
#   a0 the add-on archive builds for this platform, with its .sha256     a1 same bytes twice (--check)
#   i1 install: <v>/tando-dash, the current link, ~/.local/bin link      i2 the installed binary runs --version
#   i3 status: installed, same version, not running                      i4 `tando dashboard` runs it
#   q1 the quarantine attribute is removed from the verified files only  (a stub xattr logs its calls)
#   r1 checksum mismatch refused, nothing installed, nothing de-quarantined
#   r2 no checksum refused; --sha256 accepts; a wrong --sha256 refused   r3 unsafe paths refused
#   r4 --version that the archive does not hold refused                  r5 a foreign ~/.local/bin/tando-dash is left alone
#   d1 file:// URL download with its .sha256                             u1 uninstall stops a running tando-dash and leaves nothing
# One PASS/FAIL/SKIP line per check. Needs Go and perl (SKIP without Go).
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init addon-test
if ! command -v go > /dev/null 2>&1; then skip "a0 Go is not installed: the add-on archive cannot be built"; t_done; fi
V=$(tr -d ' \n' < "$ROOT/addons/dashboard/VERSION")
case $(uname -s) in
  Darwin) PLAT=darwin-universal;;
  *) case $(uname -m) in aarch64|arm64) PLAT=linux-arm64;; *) PLAT=linux-amd64;; esac;;
esac
ASSET=tando-dash-$V-$PLAT.tar.gz
export GOTOOLCHAIN=local TANDO_NO_BROWSER=1
H=$E/home STUB=$E/stub A=$E/dist
mkdir -p "$H" "$STUB" "$A"
export HOME=$H

# ---- the archive -------------------------------------------------------------------------------
"$ROOT/scripts/release-dashboard.sh" --skip-web --only "$PLAT" --out "$A" > "$E/rel.out" 2>&1; rc=$?
[ "$rc" = 0 ] || cat "$E/rel.out" >&2
check "a0 release-dashboard.sh builds $ASSET and its .sha256 (rc=$rc, $(wc -c < "$A/$ASSET" 2> /dev/null | tr -d ' ') bytes)" \
  eval 'test "$rc" = 0 && test -s "$A/$ASSET" && test -s "$A/$ASSET.sha256" && grep -q "$ASSET\$" "$A/$ASSET.sha256"'
[ -s "$A/$ASSET" ] || t_done
tar -tzf "$A/$ASSET" > "$E/list" 2>&1
check "a0b the archive holds one directory with tando-dash, VERSION (sorted, nothing else of the repo)" \
  eval 'grep -qx "tando-dash-$V-$PLAT/tando-dash" "$E/list" && grep -qx "tando-dash-$V-$PLAT/VERSION" "$E/list" && ! grep -q "addons\|\\.go" "$E/list"'
tar -tvzf "$A/$ASSET" 2> /dev/null | awk '{print $1, $3, $4}' > "$E/modes"
check "a0c fixed modes and owners: tando-dash 0755, VERSION 0644, uid/gid 0" \
  eval 'grep -q "^-rwxr-xr-x 0 0\$" "$E/modes" && grep -q "^-rw-r--r-- 0 0\$" "$E/modes"'
# reproducible: two builds, the second from an empty Go cache, same bytes (one platform: the linux build is the quick one)
RP=linux-arm64; [ "$PLAT" = linux-arm64 ] && RP=linux-amd64
if "$ROOT/scripts/release-dashboard.sh" --skip-web --check --only "$RP" > "$E/repro.out" 2>&1; then
  pass "a1 two builds of tando-dash-$V-$RP.tar.gz are the same bytes ($(sed -n 's/.*reproducible: \([0-9a-f]\{12\}\).*/\1/p' "$E/repro.out")...)"
else fail "a1 two builds differ"; cat "$E/repro.out" >&2; fi

# ---- install -----------------------------------------------------------------------------------
cat > "$STUB/xattr" << EOF2
#!/bin/bash
echo "\$*" >> "$E/xattr.log"
exit 0
EOF2
chmod +x "$STUB/xattr"
export PATH=$STUB:$PATH
: > "$E/xattr.log"
r() { "$R" "$@"; }
r addon status > "$E/st0" 2>&1
check "i0 status before: not installed, the command to install it" eval 'grep -q "not installed (tando addon install dashboard)" "$E/st0" && grep -q "running *no" "$E/st0"'
r addon install dashboard --from "$A/$ASSET" > "$E/i1.out" 2>&1; rc=$?
LIB=$H/.local/lib/tando-dash
check "i1 install --from the archive (rc=$rc): $V/tando-dash, the current link, ~/.local/bin/tando-dash" \
  eval 'test "$rc" = 0 && test -x "$LIB/$V/tando-dash" && test "$(readlink "$LIB/current")" = "$V" && test -L "$H/.local/bin/tando-dash" && grep -q "checksum ok" "$E/i1.out"'
[ "$rc" = 0 ] || cat "$E/i1.out" >&2
out=$("$H/.local/bin/tando-dash" --version 2>&1)
check "i2 the installed tando-dash runs: '$out'" t_eq "$out" "tando-dash $V"
r addon status > "$E/st1" 2>&1
check "i3 status: installed version, same as the client, not running" \
  eval 'grep -q "dashboard *$V" "$E/st1" && grep -q "same version" "$E/st1" && grep -q "running *no" "$E/st1"'
out=$(r dashboard --version 2>&1)
check "i4 'tando dashboard' runs tando-dash ('$out')" t_eq "$out" "tando-dash $V"
if [ "$(uname -s)" = Darwin ]; then
  # shellcheck disable=SC2034  # bad: read by the eval below
  bad=$(grep -v "^-d com.apple.quarantine $LIB/$V/" "$E/xattr.log")
  check "q1 the quarantine attribute is removed from the files of the verified archive and from nothing else ($(wc -l < "$E/xattr.log" | tr -d ' ') calls)" \
    eval 'test -s "$E/xattr.log" && test -z "$bad" && grep -q "^-d com.apple.quarantine $LIB/$V/tando-dash\$" "$E/xattr.log"'
else skip "q1 quarantine: macOS only"; fi
r addon install dashboard --from "$A/$ASSET" > "$E/i1b.out" 2>&1
check "i5 installing again is fine and leaves one version directory" \
  eval 'test "$(ls "$LIB" | grep -vc current)" = 1 && test -x "$LIB/$V/tando-dash"'
r addon install > "$E/n1.out" 2>&1; rc=$?
r addon install nope > "$E/n2.out" 2>&1; rc2=$?
check "i6 'addon install' without a name, or with an unknown one, says what exists (rc=$rc,$rc2)" \
  eval 'test $rc != 0 && test $rc2 != 0 && grep -q "which add-on" "$E/n1.out" && grep -q "there is: dashboard" "$E/n2.out"'

# ---- refusals: each in a fresh HOME so "nothing installed" is a fact ---------------------------
fresh() { rm -rf "${E:?}/h2"; mkdir -p "$E/h2"; HOME=$E/h2; export HOME; : > "$E/xattr.log"; }
untouched() { [ ! -e "$E/h2/.local" ] && [ ! -s "$E/xattr.log" ]; }
fresh
cp "$A/$ASSET" "$E/bad.tar.gz"; cp "$A/$ASSET.sha256" "$E/bad.tar.gz.sha256"; printf 'x' >> "$E/bad.tar.gz"
r addon install dashboard --from "$E/bad.tar.gz" > "$E/r1.out" 2>&1; rc=$?
check "r1 a changed archive (checksum mismatch) is refused: nothing installed, nothing de-quarantined (rc=$rc)" \
  eval 'test $rc != 0 && grep -q "checksum mismatch" "$E/r1.out" && untouched'
cp "$A/$ASSET" "$E/nosum.tar.gz"
r addon install dashboard --from "$E/nosum.tar.gz" > "$E/r2.out" 2>&1; rc=$?
check "r2 no checksum (no .sha256, no --sha256) is refused, nothing installed (rc=$rc)" \
  eval 'test $rc != 0 && grep -q "no checksum" "$E/r2.out" && untouched'
sum=$(cut -d' ' -f1 < "$A/$ASSET.sha256")
r addon install dashboard --from "$E/nosum.tar.gz" --sha256 0000000000000000000000000000000000000000000000000000000000000000 > "$E/r2b.out" 2>&1; rc=$?
check "r2b a wrong --sha256 is refused (rc=$rc)" eval 'test $rc != 0 && grep -q "checksum mismatch" "$E/r2b.out" && untouched'
r addon install dashboard --from "$A/$ASSET" --sha256 0000000000000000000000000000000000000000000000000000000000000000 > "$E/r2c.out" 2>&1; rc=$?
check "r2c --sha256 wins over the .sha256 next to the archive (rc=$rc)" eval 'test $rc != 0 && grep -q "checksum mismatch" "$E/r2c.out" && untouched'
r addon install dashboard --from "$E/nosum.tar.gz" --sha256 "$sum" > "$E/r2d.out" 2>&1; rc=$?
check "r2d the right --sha256 installs an archive without a .sha256 file (rc=$rc)" eval 'test $rc = 0 && test -x "$E/h2/.local/lib/tando-dash/$V/tando-dash"'
fresh
# an archive whose checksum is right but whose names escape: refused before unpacking
python3 -I - "$E/evil.tar.gz" << 'PY'
import sys, tarfile, io
t = tarfile.open(sys.argv[1], "w:gz")
d = b"x"
i = tarfile.TarInfo("../evil"); i.size = len(d); t.addfile(i, io.BytesIO(d))
t.close()
PY
r addon install dashboard --from "$E/evil.tar.gz" --sha256 "$(shasum -a 256 "$E/evil.tar.gz" | cut -d' ' -f1)" > "$E/r3.out" 2>&1; rc=$?
check "r3 a verified archive with a path outside its directory is refused (rc=$rc)" eval 'test $rc != 0 && grep -q "unsafe paths" "$E/r3.out" && untouched && test ! -e "$E/evil"'
r addon install dashboard --from "$A/$ASSET" --version 9.9.9 > "$E/r4.out" 2>&1; rc=$?
check "r4 --version that the archive does not hold is refused (rc=$rc)" eval 'test $rc != 0 && grep -q "not 9.9.9" "$E/r4.out" && untouched'
mkdir -p "$E/h2/.local/bin"; echo mine > "$E/h2/.local/bin/tando-dash"
r addon install dashboard --from "$A/$ASSET" > "$E/r5.out" 2>&1; rc=$?
check "r5 a tando-dash of its own in ~/.local/bin is not overwritten (rc=$rc)" \
  eval 'test $rc != 0 && test "$(cat "$E/h2/.local/bin/tando-dash")" = mine && test ! -e "$E/h2/.local/lib/tando-dash/$V"'
fresh
r addon install dashboard --from "file://$A/$ASSET" > "$E/d1.out" 2>&1; rc=$?
check "d1 --from file:// downloads the archive and its .sha256 (rc=$rc)" eval 'test $rc = 0 && grep -q "checksum ok" "$E/d1.out" && test -x "$E/h2/.local/lib/tando-dash/$V/tando-dash"'
rm -f "$E/gone.tar.gz"; cp "$A/$ASSET" "$E/gone.tar.gz"
r addon install dashboard --from "file://$E/gone.tar.gz" > "$E/d2.out" 2>&1; rc=$?
check "d2 a URL without a .sha256 next to it is refused (rc=$rc)" eval 'test $rc != 0 && grep -q "no checksum" "$E/d2.out"'

# ---- uninstall: stops a running tando-dash, leaves nothing ------------------------------------
HOME=$H; export HOME
mkdir -p "$TANDO_CONFIG_DIR/hosts" "$TANDO_CONFIG_DIR/cache"
echo keep > "$TANDO_CONFIG_DIR/cache/apps.vps"
r dashboard --no-open > "$E/dash.out" 2>&1 &
dpid=$!
t_until 20 test -s "$TANDO_CONFIG_DIR/dash.lock"
echo '{"hosts":[]}' > "$TANDO_CONFIG_DIR/cache/ls-all.json"
r addon status > "$E/st2" 2>&1
check "u0 status while it runs: running yes with its pid and port" eval 'grep -Eq "running *yes \(pid [0-9]+, http://127.0.0.1:[0-9]+/\)" "$E/st2"'
lp=$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "$TANDO_CONFIG_DIR/dash.lock" | head -1)
r addon uninstall dashboard > "$E/u1.out" 2>&1; rc=$?
wait "$dpid" 2> /dev/null
left=$(find "$H/.local" \( -type f -o -type l \) 2> /dev/null)
check "u1 uninstall stops the running tando-dash (pid $lp) and removes the binary, links, lock and cache (rc=$rc${left:+; left: $left})" \
  eval 'test $rc = 0 && test -n "$lp" && ! kill -0 "$lp" 2> /dev/null && test -z "$left" &&
        test ! -s "$TANDO_CONFIG_DIR/dash.lock" && test ! -e "$TANDO_CONFIG_DIR/cache/ls-all.json" && test ! -e "$TANDO_CONFIG_DIR/cache/dash-port"'
check "u2 uninstall leaves the user's other files (cache/apps.vps, hosts/)" eval 'test "$(cat "$TANDO_CONFIG_DIR/cache/apps.vps")" = keep && test -d "$TANDO_CONFIG_DIR/hosts"'
r addon uninstall dashboard > "$E/u3.out" 2>&1; rc=$?
check "u3 uninstall again says it is not installed (rc=$rc)" eval 'test $rc = 0 && grep -q "not installed" "$E/u3.out"'
# (not installed means not on the PATH either: a tando-dash of the machine this runs on, found by
# `command -v`, would be started and serve for ever. And a hang here must fail, not wait)
npath=; oldifs=$IFS; IFS=:
for d in $PATH; do [ -x "$d/tando-dash" ] || npath=${npath:+$npath:}$d; done
IFS=$oldifs
out=$(PATH=$npath perl -e 'alarm 30; exec @ARGV' "$R" dashboard 2>&1)
check "u4 'tando dashboard' without the add-on says how to install it" eval 'printf "%s" "$out" | grep -q "tando addon install dashboard"'
t_done
