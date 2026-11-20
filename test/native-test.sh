#!/bin/bash
# test/native-test.sh: swap_native and guard (lib/build.sh, lib/native.js) on fixture node_modules
# trees, without a server or the network: `npm` is a stub that serves tarballs from a local fake
# registry and records every call. Run by test/ui-test.sh (and on its own); bash 3.2 compatible.
#
#   test/native-test.sh [tando-root]     (default: this checkout)
#
# One line per failed check; the last line is "native: <n> checks, <m> failed".
set -u
here=$(cd "$(dirname "$0")/.." && pwd -P)
LIB=${1:-$here}
T=$(mktemp -d "${TMPDIR:-/tmp}/native-test.XXXXXX") || exit 2
SRVPID=""
trap '[ -z "$SRVPID" ] || { kill "$SRVPID"; wait "$SRVPID"; } 2> /dev/null; rm -rf "$T"' EXIT
n=0 nf=0
ok() { n=$((n + 1)); }
bad() { n=$((n + 1)); nf=$((nf + 1)); echo "FAIL native: $*"; [ -z "${NATIVE_DEBUG:-}" ] || sed "s/^/    /" "${C:-/dev/null}/out" 2> /dev/null; }
check() { local t=$1; shift; if "$@"; then ok; else bad "$t"; fi; }
command -v node > /dev/null || { echo "native: node is needed (skipped)"; echo "native: 0 checks, 0 failed"; exit 0; }

# ---- fixtures ----------------------------------------------------------------------------------
# native files: ELF for aarch64 and x86-64, Mach-O for arm64 (only their headers: `file` reads those)
elf() { printf '\177ELF\002\001\001\000\000\000\000\000\000\000\000\000\003\000%b\000\001\000\000\000' "$2" > "$1"
        head -c 40 /dev/zero >> "$1"; }
macho() { printf '\317\372\355\376\014\000\000\001\000\000\000\000\006\000\000\000' > "$1"; head -c 48 /dev/zero >> "$1"; }
# pkg dir name version os cpu [extra json] [native: elf-arm64|elf-x64|macho|-]
pkg() {
  mkdir -p "$1/lib"
  local os="" cpu=""
  [ "$4" = - ] || os=", \"os\": [\"$4\"]"
  [ "$5" = - ] || cpu=", \"cpu\": [\"$5\"]"
  printf '{ "name": "%s", "version": "%s"%s%s%s }\n' "$2" "$3" "$os" "$cpu" "${6:+, $6}" > "$1/package.json"
  case ${7:--} in
    elf-arm64) elf "$1/lib/native.node" '\267';;
    elf-x64) elf "$1/lib/native.node" '\076';;
    macho) macho "$1/lib/native.node";;
  esac
}
key() { printf '%s' "$1" | tr '@/' '_+'; }
sri() { printf 'sha512-%s' "$(openssl dgst -sha512 -binary < "$1" | openssl base64 -A)"; }
# the fake registry: name version os cpu native [libc]
REG=$T/reg
mkdir -p "$REG"
reg() {
  local d
  d=$T/regsrc/$(key "$1")-$2
  rm -rf "${d:?}"; pkg "$d/package" "$1" "$2" "$3" "$4" "${6:+\"libc\": [\"$6\"]}" "$5"
  (cd "$d" && tar -czf "$REG/$(key "$1")-$2.tgz" package)
}
reg @img/sharp-linux-arm64 0.35.5 linux arm64 elf-arm64 glibc
reg @img/sharp-linux-arm64 0.34.5 linux arm64 elf-arm64 glibc
reg @img/sharp-libvips-linux-arm64 1.3.4 linux arm64 elf-arm64 glibc
reg @img/sharp-linuxmusl-arm64 0.35.5 linux arm64 elf-arm64 musl
reg @next/swc-linux-arm64-gnu 16.4.6 linux arm64 elf-arm64 glibc
reg @img/sharp-linux-x64 0.35.5 linux x64 elf-x64 glibc
reg @parcel/watcher-linux-arm64-glibc 2.6.0 linux arm64 elf-arm64 glibc
reg @tailwindcss/oxide-linux-arm64-gnu 4.3.5 linux arm64 elf-arm64 glibc
reg @msgpackr-extract/msgpackr-extract-linux-arm64 3.0.3 linux arm64 elf-arm64
I535=$(sri "$REG/$(key @img/sharp-linux-arm64)-0.35.5.tgz")
I534=$(sri "$REG/$(key @img/sharp-linux-arm64)-0.34.5.tgz")
IVIPS=$(sri "$REG/$(key @img/sharp-libvips-linux-arm64)-1.3.4.tgz")

# npm: `npm pack ... --pack-destination D -- name@version` copies the tarball from the fake
# registry into D (and prints its file name, as npm does); every call goes into $NPMLOG
mkdir -p "$T/bin"
cat > "$T/bin/npm" <<'STUB'
#!/bin/sh
echo "npm $*" >> "$NPMLOG"
dest="" spec=""
while [ $# -gt 0 ]; do
  case $1 in --pack-destination) dest=$2; shift 2;; --) spec=$2; shift 2;; -*) shift;; *) spec=$1; shift;; esac
done
name=${spec%@*} ver=${spec##*@}
f=$REG/$(printf '%s' "$name" | tr '@/' '_+')-$ver.tgz
[ -f "$f" ] || { echo "npm ERR! 404 Not Found - $spec" >&2; exit 1; }
out=$(printf '%s' "$name" | tr -d '@' | tr '/' '-')-$ver.tgz
cp "$f" "$dest/$out" && echo "$out"
STUB
chmod +x "$T/bin/npm"
export PATH="$T/bin:$PATH" REG

# sharp's optionalDependencies, as sharp 0.35 / 0.34 ship them (the part that matters here)
opt() { # sharp-version libvips-version
  printf '"optionalDependencies": { "@img/sharp-darwin-arm64": "%s", "@img/sharp-linux-arm64": "%s", "@img/sharp-linuxmusl-arm64": "%s", "@img/sharp-linux-x64": "%s", "@img/sharp-libvips-darwin-arm64": "%s", "@img/sharp-libvips-linux-arm64": "%s" }' \
    "$1" "$1" "$1" "$1" "$2" "$2"
}
# a project directory with the staged tree in .tando/stage (as stage() leaves it)
newcase() { C=$T/case-$1; rm -rf "$C"; mkdir -p "$C/.tando/stage/node_modules" "$C/tmp"; S=$C/.tando/stage; : > "$C/npm.log"; }
# lock file entries: package-lock.json v3 with "packages" keys at the paths given
lockv3() { # file [key integrity version]...
  local f=$1 first=1; shift
  { printf '{ "name": "fixture", "lockfileVersion": 3, "requires": true, "packages": {\n    "": { "name": "fixture" }'
    while [ $# -gt 0 ]; do printf ',\n    "%s": { "version": "%s", "integrity": "%s", "optional": true }' "$1" "$3" "$2"; shift 3; done
    printf '\n} }\n'; } > "$f"
  : "$first"
}
# run swap_native then guard in the case's project directory, as a deploy does; runfix also runs
# native_fix between them (what stage() does). RUN_ARCH, RUN_NODE, RUN_GLIBC: what the server is
run() { # [K_libc] [recipe]
  ( cd "$C" || exit 2
    TANDO_HOME=$LIB TANDO_COLOR=never NPMLOG=$C/npm.log
    export NPMLOG
    . "$LIB/lib/ui.sh"; ui_init 100
    . "$LIB/lib/common.sh"; . "$LIB/lib/build.sh"; . "$LIB/lib/deploy.sh"
    STAGE=.tando/stage CACHE=.tando/cache TMPD=$C/tmp K_arch=${RUN_ARCH:-aarch64} K_libc=${1:-glibc} C_recipe=${2:-node} C_out=.
    K_node=${RUN_NODE:-24.1.0} K_glibc=${RUN_GLIBC:-}
    swap_native && { [ -z "${RUN_FIX:-}" ] || native_fix; } && guard && {
      echo "OK swapped=${SWAPPED}"; cat "$TMPD/swaps" 2> /dev/null; cat "$TMPD/native.notes" 2> /dev/null || true; }
  ) > "$C/out" 2>&1
  RC=$?
}
runfix() { RUN_FIX=1 run "$@"; }
has() { grep -q -- "$1" "$C/out"; }
ver_of() { sed -n 's/.*"version": "\([^"]*\)".*/\1/p' "$S/$1/package.json" 2> /dev/null; }
calls() { grep -c . "$C/npm.log" | tr -d ' '; }

# ---- 1. flat: node_modules/@img/sharp-darwin-arm64, verified against package-lock.json ------
newcase flat
pkg "$S/node_modules/sharp" sharp 0.35.5 - - "$(opt 0.35.5 1.3.4)"
pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
lockv3 "$C/package-lock.json" node_modules/@img/sharp-linux-arm64 "$I535" 0.35.5
run
check "1a flat: swapped and the guard passes (rc=$RC: $(tail -3 "$C/out" | tr '\n' ' '))" test "$RC" = 0
check "1b flat: the Linux package is in node_modules/@img, the macOS one is gone" \
  eval '[ "$(ver_of node_modules/@img/sharp-linux-arm64)" = 0.35.5 ] && [ ! -e "$S/node_modules/@img/sharp-darwin-arm64" ]'
check "1c flat: the output says what was swapped and that it was verified" \
  eval 'has "node_modules/@img/sharp-darwin-arm64.@img/sharp-linux-arm64.0.35.5.verified against package-lock.json"'
check "1d flat: npm pack was called once, for the exact version, with -- before it" \
  eval '[ "$(calls)" = 1 ] && grep -q -- "-- @img/sharp-linux-arm64@0.35.5\$" "$C/npm.log" && grep -q -- "--ignore-scripts" "$C/npm.log"'
# the cache: a second deploy does not fetch again; a cached file that changed is fetched again
rm -rf "${S:?}/node_modules/@img/sharp-linux-arm64"
pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
run
check "1e cache: the second swap uses .tando/cache (no npm call; rc=$RC)" eval '[ "$RC" = 0 ] && [ "$(calls)" = 1 ]'
c=$(ls "$C"/.tando/cache/*.tgz 2> /dev/null | head -1)
[ -n "$c" ] && printf 'tampered' >> "$c"
rm -rf "${S:?}/node_modules/@img/sharp-linux-arm64"
pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
run
check "1f cache: a cached tarball that changed is fetched again, and verified (rc=$RC)" \
  eval '[ -n "$c" ] && [ "$RC" = 0 ] && [ "$(calls)" = 2 ] && has "verified against package-lock.json"'

# ---- 2. nested at depth 4: next's own copy of sharp and libvips --------------------------------
newcase nested
pkg "$S/node_modules/next" next 16.4.6 - - '"optionalDependencies": { "sharp": "^0.35.5" }'
pkg "$S/node_modules/next/node_modules/sharp" sharp 0.35.5 - - "$(opt 0.35.5 1.3.4)"
pkg "$S/node_modules/next/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
pkg "$S/node_modules/next/node_modules/@img/sharp-libvips-darwin-arm64" @img/sharp-libvips-darwin-arm64 1.3.4 darwin arm64 "" -
macho "$S/node_modules/next/node_modules/@img/sharp-libvips-darwin-arm64/lib/libvips-cpp.dylib"
lockv3 "$C/package-lock.json" \
  node_modules/next/node_modules/@img/sharp-linux-arm64 "$I535" 0.35.5 \
  node_modules/next/node_modules/@img/sharp-libvips-linux-arm64 "$IVIPS" 1.3.4
run
check "2a nested: swapped at depth 4, guard passes (rc=$RC: $(tail -3 "$C/out" | tr '\n' ' '))" test "$RC" = 0
check "2b nested: each Linux package lands in next's own node_modules" \
  eval '[ "$(ver_of node_modules/next/node_modules/@img/sharp-linux-arm64)" = 0.35.5 ] &&
        [ "$(ver_of node_modules/next/node_modules/@img/sharp-libvips-linux-arm64)" = 1.3.4 ] &&
        [ ! -e "$S/node_modules/@img" ] && ! find "$S" -name "*darwin*" | grep -q .'
check "2c nested: both verified against the nested lockfile entries" \
  eval '[ "$(grep -c "verified against package-lock.json" "$C/out")" = 2 ]'

# ---- 3. two versions at two depths ---------------------------------------------------------------
newcase twover
pkg "$S/node_modules/sharp" sharp 0.34.5 - - "$(opt 0.34.5 1.2.4)"
pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.34.5 darwin arm64 "" macho
pkg "$S/node_modules/next" next 16.4.6 - - '"optionalDependencies": { "sharp": "^0.35.5" }'
pkg "$S/node_modules/next/node_modules/sharp" sharp 0.35.5 - - "$(opt 0.35.5 1.3.4)"
pkg "$S/node_modules/next/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
lockv3 "$C/package-lock.json" node_modules/@img/sharp-linux-arm64 "$I534" 0.34.5 \
  node_modules/next/node_modules/@img/sharp-linux-arm64 "$I535" 0.35.5
run
check "3a two versions: both swapped (rc=$RC: $(tail -3 "$C/out" | tr '\n' ' '))" test "$RC" = 0
check "3b two versions: 0.34.5 at the top, 0.35.5 under next, each at its own place" \
  eval '[ "$(ver_of node_modules/@img/sharp-linux-arm64)" = 0.34.5 ] &&
        [ "$(ver_of node_modules/next/node_modules/@img/sharp-linux-arm64)" = 0.35.5 ]'
check "3c two versions: two fetches, both verified" \
  eval '[ "$(calls)" = 2 ] && [ "$(grep -c "verified against" "$C/out")" = 2 ]'

# ---- 4. hostile versions and names: refused before npm runs ------------------------------------
for h in 'https://example.invalid/x.tgz' '0.35.5 --registry=http://example.invalid' '^0.35.5' 'file:../x' \
         'git+ssh://example.invalid/x' '0.35.5;touch$IFS/tmp/x'; do
  newcase hostile
  pkg "$S/node_modules/sharp" sharp 0.35.5 - - "\"optionalDependencies\": { \"@img/sharp-linux-arm64\": \"$h\" }"
  pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
  run
  check "4a a pin of \"$h\" is refused and npm is never run (rc=$RC, npm calls $(calls))" \
    eval '[ "$RC" != 0 ] && [ "$(calls)" = 0 ] && has "not an exact version"'
done
newcase hostile2   # the package's own version (nothing beside it pins one; the lockfile names it)
pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 '1.0.0 --foo' darwin arm64 "" macho
lockv3 "$C/package-lock.json" node_modules/@img/sharp-linux-arm64 "$I535" '1.0.0 --foo'
run
check "4b a package whose own version is not exact is refused, npm not run (rc=$RC)" \
  eval '[ "$RC" != 0 ] && [ "$(calls)" = 0 ] && has "not an exact version"'
# bash's own checks (what reaches npm whatever lib/native.js says)
v=$( . "$LIB/lib/build.sh"
  for x in 1.2.3 0.35.5 1.0.0-rc.1 10.20.30; do native_ver_ok "$x" || echo "rejected $x"; done
  for x in 1.2 01.2.3 1.2.3.4 '1.2.3 ' '^1.2.3' '1.2.3-a b' '' latest 1.2.3+b 'http://x' '-1.2.3' '1.2.3-$(x)'; do
    native_ver_ok "$x" && echo "accepted [$x]"; done
  for x in sharp @img/sharp-linux-x64 a.b_c-d; do native_name_ok "$x" || echo "rejected $x"; done
  for x in Sharp '@img/' '../x' '@a/b/c' '-x' '.x' 'a b' '@/x' 'a;b'; do native_name_ok "$x" && echo "accepted [$x]"; done
  for x in 'node_modules/a/../../x' '/abs' 'node_modules/a b' 'x/node_modules/a'; do native_path_ok "$x" && echo "accepted [$x]"; done
  true)
check "4c version, name and path checks in bash (${v:-all right})" test -z "$v"

# ---- 5. lockfile mismatch: fail closed ------------------------------------------------------------
newcase mismatch
pkg "$S/node_modules/sharp" sharp 0.35.5 - - "$(opt 0.35.5 1.3.4)"
pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
lockv3 "$C/package-lock.json" node_modules/@img/sharp-linux-arm64 "$I534" 0.35.5
run
check "5a a tarball that does not match the lockfile's sha512 stops the deploy (rc=$RC)" \
  eval '[ "$RC" != 0 ] && has "@img/sharp-linux-arm64@0.35.5 does not match package-lock.json" && has "$I534"'
check "5b ... and is not kept in the cache" eval '! ls "$C"/.tando/cache/*.tgz > /dev/null 2>&1'
# without a lockfile, or a lockfile tando cannot read: swapped, and the output says not verified
newcase nolock
pkg "$S/node_modules/sharp" sharp 0.35.5 - - "$(opt 0.35.5 1.3.4)"
pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
run
check "5c no lockfile: swapped, \"not verified: no lockfile\" (rc=$RC)" eval '[ "$RC" = 0 ] && has "not verified: no lockfile"'
newcase bun
pkg "$S/node_modules/sharp" sharp 0.35.5 - - "$(opt 0.35.5 1.3.4)"
pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
printf 'binary\000lock' > "$C/bun.lockb"
run
check "5d bun.lockb: swapped, says tando cannot read its checksums (rc=$RC)" \
  eval '[ "$RC" = 0 ] && has "not verified: tando cannot read the checksums of bun.lockb"'
newcase notinlock
pkg "$S/node_modules/sharp" sharp 0.35.5 - - "$(opt 0.35.5 1.3.4)"
pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
lockv3 "$C/package-lock.json" node_modules/other "$I534" 1.0.0
run
check "5e a lockfile without the package: swapped, says so (rc=$RC)" \
  eval '[ "$RC" = 0 ] && has "not verified: package-lock.json has no entry for @img/sharp-linux-arm64@0.35.5"'
newcase yarn
pkg "$S/node_modules/sharp" sharp 0.35.5 - - "$(opt 0.35.5 1.3.4)"
pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
printf '# yarn lockfile v1\n\n"@img/sharp-linux-arm64@0.35.5":\n  version "0.35.5"\n  resolved "https://registry.yarnpkg.com/x.tgz"\n  integrity %s\n' "$I535" > "$C/yarn.lock"
run
check "5f yarn.lock (v1): verified against it (rc=$RC)" eval '[ "$RC" = 0 ] && has "verified against yarn.lock"'
printf '# yarn lockfile v1\n\n"@img/sharp-linux-arm64@0.35.5":\n  version "0.35.5"\n  integrity %s\n' "$I534" > "$C/yarn.lock"
rm -rf "${S:?}/node_modules/@img/sharp-linux-arm64" "${C:?}/.tando/cache"
pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
run
check "5g yarn.lock (v1) with another sha512: refused (rc=$RC)" eval '[ "$RC" != 0 ] && has "does not match yarn.lock"'
newcase pnpm
pkg "$S/node_modules/sharp" sharp 0.35.5 - - "$(opt 0.35.5 1.3.4)"
pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
printf "lockfileVersion: '9.0'\n\npackages:\n\n  '@img/sharp-darwin-arm64@0.35.5':\n    resolution: {integrity: %s}\n    cpu: [arm64]\n\n  '@img/sharp-linux-arm64@0.35.5':\n    resolution: {integrity: %s}\n    cpu: [arm64]\n    os: [linux]\n" \
  "$I534" "$I535" > "$C/pnpm-lock.yaml"
run
check "5h pnpm-lock.yaml (v9): verified against it (rc=$RC)" eval '[ "$RC" = 0 ] && has "verified against pnpm-lock.yaml"'

# ---- 6. other families and platforms -------------------------------------------------------------
newcase swc   # next pins its compiler per platform; the Linux one carries a -gnu suffix
pkg "$S/node_modules/next" next 16.4.6 - - '"optionalDependencies": { "@next/swc-darwin-arm64": "16.4.6", "@next/swc-linux-arm64-gnu": "16.4.6", "@next/swc-linux-arm64-musl": "16.4.6" }'
pkg "$S/node_modules/@next/swc-darwin-arm64" @next/swc-darwin-arm64 16.4.6 darwin arm64 "" macho
run
check "6a @next/swc-darwin-arm64 becomes @next/swc-linux-arm64-gnu (rc=$RC)" \
  eval '[ "$RC" = 0 ] && [ "$(ver_of node_modules/@next/swc-linux-arm64-gnu)" = 16.4.6 ]'
newcase musl
pkg "$S/node_modules/sharp" sharp 0.35.5 - - "$(opt 0.35.5 1.3.4)"
pkg "$S/node_modules/@img/sharp-darwin-arm64" @img/sharp-darwin-arm64 0.35.5 darwin arm64 "" macho
run musl
check "6b a musl server gets @img/sharp-linuxmusl-arm64 (rc=$RC)" \
  eval '[ "$RC" = 0 ] && [ "$(ver_of node_modules/@img/sharp-linuxmusl-arm64)" = 0.35.5 ]'
newcase linuxx64   # a Linux x86-64 laptop deploying to an arm64 server
pkg "$S/node_modules/sharp" sharp 0.35.5 - - "$(opt 0.35.5 1.3.4)"
pkg "$S/node_modules/@img/sharp-linux-x64" @img/sharp-linux-x64 0.35.5 linux x64 '"libc": ["glibc"]' elf-x64
run
check "6c a linux-x64 package is swapped for linux-arm64 (rc=$RC)" \
  eval '[ "$RC" = 0 ] && [ "$(ver_of node_modules/@img/sharp-linux-arm64)" = 0.35.5 ] && [ ! -e "$S/node_modules/@img/sharp-linux-x64" ]'
newcase keep   # the server's own package is left alone, nothing is fetched
pkg "$S/node_modules/sharp" sharp 0.35.5 - - "$(opt 0.35.5 1.3.4)"
pkg "$S/node_modules/@img/sharp-linux-arm64" @img/sharp-linux-arm64 0.35.5 linux arm64 '"libc": ["glibc"]' elf-arm64
pkg "$S/node_modules/lightningcss-linux-utils" lightningcss-linux-utils 1.0.0 - - "" -
run
check "6d packages for the server (and names that only look like one) are left alone (rc=$RC)" \
  eval '[ "$RC" = 0 ] && [ "$(calls)" = 0 ] && has "OK swapped=\$"'

# ---- 7. the guard: which files, why, what to do ----------------------------------------------------
newcase guardnode
pkg "$S/node_modules/better-sqlite3" better-sqlite3 12.0.0 - - "" -
mkdir -p "$S/node_modules/better-sqlite3/build/Release"
macho "$S/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
run
check "7a guard: names the file and its kind, says it must be installed on Linux, and where to read more" \
  eval '[ "$RC" != 0 ] && has "native code built for another platform (the server is linux aarch64)" &&
        has "node_modules/better-sqlite3/build/Release/better_sqlite3.node (Mach-O 64-bit" &&
        has "installed on Linux" && has "tando ci github" && has "docs/CROSS-ARCH.md"'
newcase guardnext   # a nested platform package without the metadata to swap it (a traced copy)
pkg "$S/node_modules/next" next 16.4.6 - - "" -
mkdir -p "$S/node_modules/next/node_modules/@img/sharp-libvips-darwin-arm64/lib"
macho "$S/node_modules/next/node_modules/@img/sharp-libvips-darwin-arm64/lib/libvips-cpp.dylib"
macho "$S/node_modules/next/node_modules/@img/sharp-libvips-darwin-arm64/lib/libvips-x.dylib"
run glibc next
check "7b guard (next): every path, the nested copy, unoptimized images, tando ci github" \
  eval '[ "$RC" != 0 ] && has "node_modules/next/node_modules/@img/sharp-libvips-darwin-arm64/lib/libvips-cpp.dylib" &&
        has "libvips-x.dylib" && has "nested copy under node_modules/next/node_modules" &&
        has "images: { unoptimized: true }" && has "@img/sharp-libvips-darwin-arm64" && has "tando ci github"'
newcase guardprisma
mkdir -p "$S/node_modules/.prisma/client"
macho "$S/node_modules/.prisma/client/libquery_engine-darwin-arm64.dylib.node"
run
check "7c guard (prisma): binaryTargets for this server" eval '[ "$RC" != 0 ] && has "linux-arm64-openssl-3.0.x"'

# ---- 8. packages that carry several platforms' binaries (prebuilds/<platform>-<arch>/) ------------
pe() { printf 'MZ\220\000\003\000\000\000' > "$1"; head -c 48 /dev/zero >> "$1"; }
# a node-gyp-build style package: prebuilds for the platforms given (elf-arm64 for the server)
prebuilds_pkg() { # dir name version [extra json]
  pkg "$1" "$2" "$3" - - "\"scripts\": { \"install\": \"node-gyp-build\" }${4:+, $4}" -
  mkdir -p "$1/prebuilds/linux-arm64" "$1/prebuilds/linux-x64" "$1/prebuilds/darwin-arm64" "$1/prebuilds/win32-x64"
  elf "$1/prebuilds/linux-arm64/node.napi.glibc.node" '\267'
  elf "$1/prebuilds/linux-x64/node.napi.glibc.node" '\076'
  macho "$1/prebuilds/darwin-arm64/node.napi.node"
  pe "$1/prebuilds/win32-x64/node.napi.node"
}
newcase prebuilds
prebuilds_pkg "$S/node_modules/bcryptfix" bcryptfix 6.0.0
run
check "8a guard: a package with prebuilds for every platform and the server's own is accepted (rc=$RC: $(tail -3 "$C/out" | tr '\n' ' '))" \
  test "$RC" = 0
newcase prebuilds2
prebuilds_pkg "$S/node_modules/bcryptfix" bcryptfix 6.0.0
runfix
check "8b the other platforms' files are removed, the server's stays, and the line says so (rc=$RC: $(tail -3 "$C/out" | tr '\n' ' '))" \
  eval '[ "$RC" = 0 ] && [ -f "$S/node_modules/bcryptfix/prebuilds/linux-arm64/node.napi.glibc.node" ] &&
        [ ! -e "$S/node_modules/bcryptfix/prebuilds/darwin-arm64" ] && [ ! -e "$S/node_modules/bcryptfix/prebuilds/win32-x64" ] &&
        [ ! -e "$S/node_modules/bcryptfix/prebuilds/linux-x64" ] &&
        has "node_modules/bcryptfix.*already inside the package (prebuilds/linux-arm64/node.napi.glibc.node; 3 files for other platforms removed)" &&
        [ "$(calls)" = 0 ]'
# the loader (node-gyp-build's rule: prebuilds/<platform>-<arch>/*.node, build/ first) still finds it
check "8c the loader finds the server's binary after the removal" \
  eval 'node -e "
    const fs = require(\"fs\"), p = process.argv[1];
    if (fs.existsSync(p + \"/build\")) process.exit(3);
    const f = fs.readdirSync(p + \"/prebuilds/linux-arm64\").filter((x) => /\.node\$/.test(x));
    process.exit(f.length === 1 ? 0 : 4)" "$S/node_modules/bcryptfix"'
# the foreign binary in build/ shadows the prebuilds for node-gyp-build: it is removed too
newcase prebuilds3
prebuilds_pkg "$S/node_modules/bcryptfix" bcryptfix 6.0.0
mkdir -p "$S/node_modules/bcryptfix/build/Release"; macho "$S/node_modules/bcryptfix/build/Release/x.node"
runfix
check "8d a laptop-built build/Release/*.node (it shadows prebuilds/) is removed too (rc=$RC)" \
  eval '[ "$RC" = 0 ] && [ ! -e "$S/node_modules/bcryptfix/build/Release/x.node" ] && [ -f "$S/node_modules/bcryptfix/prebuilds/linux-arm64/node.napi.glibc.node" ]'
# the same for an x86-64 server (the usual one): its file is kept, arm64 and darwin go
newcase prebuilds4
prebuilds_pkg "$S/node_modules/bcryptfix" bcryptfix 6.0.0
RUN_ARCH=x86_64 runfix
check "8e x86-64 server: linux-x64 stays, linux-arm64 and darwin go (rc=$RC)" \
  eval '[ "$RC" = 0 ] && [ -f "$S/node_modules/bcryptfix/prebuilds/linux-x64/node.napi.glibc.node" ] && [ ! -e "$S/node_modules/bcryptfix/prebuilds/linux-arm64" ]'
# the flat layout of better-sqlite3 13: prebuilds/<platform>-<arch>.node
newcase flatprebuilds
pkg "$S/node_modules/bsq" bsq 13.2.0 - - '"gypfile": false' -
mkdir -p "$S/node_modules/bsq/prebuilds"; : > "$S/node_modules/bsq/binding.gyp"
elf "$S/node_modules/bsq/prebuilds/linux-arm64.node" '\267'; macho "$S/node_modules/bsq/prebuilds/darwin-arm64.node"
elf "$S/node_modules/bsq/prebuilds/linuxmusl-arm64.node" '\267'
runfix
check "8f flat prebuilds/<platform>-<arch>.node: kept for linux (glibc and musl ELF), darwin removed (rc=$RC)" \
  eval '[ "$RC" = 0 ] && [ -f "$S/node_modules/bsq/prebuilds/linux-arm64.node" ] && [ ! -e "$S/node_modules/bsq/prebuilds/darwin-arm64.node" ] && has "already inside the package (prebuilds/linux-arm64.node"'

# ---- 9. Next's standalone output pruned a package to the laptop's binary ------------------------
newcase pruned
mkdir -p "$C/node_modules"
pkg "$S/node_modules/bsq" bsq 13.2.0 - - '"gypfile": false' -
mkdir -p "$S/node_modules/bsq/prebuilds"; : > "$S/node_modules/bsq/binding.gyp"; macho "$S/node_modules/bsq/prebuilds/darwin-arm64.node"
pkg "$C/node_modules/bsq" bsq 13.2.0 - - '"gypfile": false' -
mkdir -p "$C/node_modules/bsq/prebuilds"; : > "$C/node_modules/bsq/binding.gyp"
macho "$C/node_modules/bsq/prebuilds/darwin-arm64.node"; elf "$C/node_modules/bsq/prebuilds/linux-arm64.node" '\267'
echo "// the package's code" > "$C/node_modules/bsq/index.js"
runfix glibc next
check "9a a pruned package is restored from the project's node_modules, the foreign file goes (rc=$RC: $(tail -3 "$C/out" | tr '\n' ' '))" \
  eval '[ "$RC" = 0 ] && [ -f "$S/node_modules/bsq/prebuilds/linux-arm64.node" ] && [ -f "$S/node_modules/bsq/index.js" ] &&
        [ ! -e "$S/node_modules/bsq/prebuilds/darwin-arm64.node" ] && has "node_modules/bsq.*restored from node_modules (bsq 13.2.0"'
newcase pruned2   # another version in the project: not the same package, not restored
mkdir -p "$C/node_modules"
pkg "$S/node_modules/bsq" bsq 13.2.0 - - '"gypfile": false' -
mkdir -p "$S/node_modules/bsq/prebuilds"; macho "$S/node_modules/bsq/prebuilds/darwin-arm64.node"
pkg "$C/node_modules/bsq" bsq 13.1.0 - - '"gypfile": false' -
mkdir -p "$C/node_modules/bsq/prebuilds"; elf "$C/node_modules/bsq/prebuilds/linux-arm64.node" '\267'
runfix glibc next
check "9b the project's copy has another version: not restored, the deploy stops naming the package (rc=$RC)" \
  eval '[ "$RC" != 0 ] && has "bsq 13.2.0" && [ ! -e "$S/node_modules/bsq/prebuilds/linux-arm64.node" ]'
newcase pruned3   # a nested stage copy, the project has it at the top (hoisted)
mkdir -p "$C/node_modules"
pkg "$S/node_modules/app/node_modules/bsq" bsq 13.2.0 - - '"gypfile": false' -
mkdir -p "$S/node_modules/app/node_modules/bsq/prebuilds"; macho "$S/node_modules/app/node_modules/bsq/prebuilds/darwin-arm64.node"
pkg "$C/node_modules/bsq" bsq 13.2.0 - - '"gypfile": false' -
mkdir -p "$C/node_modules/bsq/prebuilds"; elf "$C/node_modules/bsq/prebuilds/linux-arm64.node" '\267'
runfix glibc next
check "9c a nested copy is restored from the project's top-level copy of the same version (rc=$RC)" \
  eval '[ "$RC" = 0 ] && [ -f "$S/node_modules/app/node_modules/bsq/prebuilds/linux-arm64.node" ]'

# ---- 10. a binary that is downloaded at install: prebuild-install and node-pre-gyp style ---------
# a stub download server on localhost: files under $T/dl; /redir/* answers 302 to the same file on
# "localhost" (another host name); the paths asked for go to $T/dl.log
mkdir -p "$T/dl"
cat > "$T/dlserver.js" <<'JS'
const http = require("http"), fs = require("fs"), path = require("path");
const root = require("path").resolve(process.argv[2]);
const srv = http.createServer((q, r) => {
  fs.appendFileSync(root + ".log", q.url + "\n");
  if (q.url.startsWith("/redir/")) { r.writeHead(302, { location: "http://localhost:" + srv.address().port + "/" + q.url.slice(7) }); return r.end(); }
  const f = path.join(root, q.url.split("?")[0]);
  if (!f.startsWith(root + "/") || !fs.existsSync(f) || !fs.statSync(f).isFile()) { r.writeHead(404); return r.end(); }
  r.writeHead(200, { "content-type": "application/octet-stream" }); fs.createReadStream(f).pipe(r);
});
srv.listen(0, "127.0.0.1", () => fs.writeFileSync(root + ".port", String(srv.address().port)));
JS
node "$T/dlserver.js" "$T/dl" &
SRVPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$T/dl.port" ] && break; sleep 0.25; done
PORT=$(cat "$T/dl.port" 2> /dev/null)
dlurl() { echo "http://127.0.0.1:$PORT"; }
# tarball: tarball name entry-dir-or-path... built from files made under $T/mk
mktgz() { # name <<< list of "path<TAB>kind" ; kind: elf-arm64|elf-glibc238|macho|text
  local name=$1 p k
  rm -rf "${T:?}/mk"; mkdir -p "$T/mk"
  while IFS=$'\t' read -r p k; do
    [ -n "$p" ] || continue
    mkdir -p "$T/mk/$(dirname "$p")"
    case $k in
      elf-arm64) elf "$T/mk/$p" '\267';;
      elf-glibc238) elf "$T/mk/$p" '\267'; printf 'GLIBC_2.17\0GLIBC_2.38\0' >> "$T/mk/$p";;
      macho) macho "$T/mk/$p";;
      *) echo "x" > "$T/mk/$p";;
    esac
  done
  mkdir -p "$(dirname "$T/dl/$name")"
  (cd "$T/mk" && set -- * && COPYFILE_DISABLE=1 tar -czf "$T/dl/$name" "$@") || return 1
}
printf 'build/Release/node_fake.node\telf-arm64\nbuild/Release/libfoo.so.1\telf-arm64\n' | mktgz dl/fakesqlite-v1.0.0-napi-v6-linux-arm64.tar.gz
# the laptop's own build (what npm install left), and a package.json that declares its host
pi_pkg() { # dir host-json [version] [scripts]
  pkg "$1" fakesqlite "${3:-1.0.0}" - - "\"scripts\": { \"install\": \"${4:-prebuild-install -r napi || node-gyp rebuild}\" }, \"binary\": $2" -
  mkdir -p "$1/build/Release"; macho "$1/build/Release/node_fake.node"; macho "$1/build/Release/libfoo.dylib"
}
BIN='{ "napi_versions": [6], "host": "HOST", "remote_path": "dl", "package_name": "{name}-v{version}-napi-v{napi_build_version}-{platform}{libc}-{arch}.tar.gz" }'
newcase prebuilt
pi_pkg "$S/node_modules/fakesqlite" "${BIN//HOST/$(dlurl)}"
[ -z "${NATIVE_DEBUG:-}" ] || { find "$T/dl" >&2; cat "$T/dl.log" >&2; }
TANDO_NATIVE_TEST_ALLOW_LOCAL=1 runfix
check "10a prebuild-install style: the server's binary is downloaded from the declared host, the laptop's files go (rc=$RC: $(tail -3 "$C/out" | tr '\n' ' '))" \
  eval '[ "$RC" = 0 ] && [ -f "$S/node_modules/fakesqlite/build/Release/node_fake.node" ] && [ ! -e "$S/node_modules/fakesqlite/build/Release/libfoo.dylib" ] &&
        [ "$(node -e "console.log(require(\"fs\").readFileSync(process.argv[1]).slice(18,19)[0])" "$S/node_modules/fakesqlite/build/Release/node_fake.node")" = 183 ]'
check "10b ... the line says not verified by the lockfile and where from; no npm, no script ran" \
  eval 'has "node_modules/fakesqlite.*downloaded prebuilt for linux-arm64 from 127.0.0.1:$PORT (not verified by the lockfile)" && [ "$(calls)" = 0 ]'
check "10c ... only the declared file was asked for" eval '[ "$(cat "$T/dl.log" | tail -1)" = "/dl/fakesqlite-v1.0.0-napi-v6-linux-arm64.tar.gz" ]'
# the swap lines of the deploy box: yellow for what the lockfile does not cover
check "10d swap_lines prints it (the deploy box and --dry-run use it)" \
  eval '( cd "$C"; TANDO_HOME=$LIB TANDO_COLOR=never; . "$LIB/lib/ui.sh"; ui_init 220; . "$LIB/lib/common.sh"; . "$LIB/lib/build.sh"
          TMPD=$C/tmp; ui_box_open t; swap_lines; ui_box_close x ) 2>&1 | tr -s " \n│" " " | grep -q "fakesqlite: downloaded prebuilt for linux-arm64 from 127.0.0.1:$PORT (not verified by the lockfile)"'
# glibc: a binary that needs a newer glibc than the server has
printf 'build/Release/node_fake.node\telf-glibc238\n' | mktgz dl/fakesqlite-v2.0.0-napi-v6-linux-arm64.tar.gz
newcase glibc1
pi_pkg "$S/node_modules/fakesqlite" "${BIN//HOST/$(dlurl)}" 2.0.0
TANDO_NATIVE_TEST_ALLOW_LOCAL=1 runfix
check "10e glibc unknown (agent info does not report it yet): a clear warning, deploy goes on (rc=$RC)" \
  eval '[ "$RC" = 0 ] && has "needs glibc 2.38 or newer: tando cannot read the server.s glibc yet"'
newcase glibc2; pi_pkg "$S/node_modules/fakesqlite" "${BIN//HOST/$(dlurl)}" 2.0.0
RUN_GLIBC=2.36 TANDO_NATIVE_TEST_ALLOW_LOCAL=1 runfix
check "10f glibc 2.36 on the server: refused, naming both (rc=$RC)" \
  eval '[ "$RC" != 0 ] && has "needs glibc 2.38 or newer, the server has 2.36" && has "tando ci github"'
newcase glibc3; pi_pkg "$S/node_modules/fakesqlite" "${BIN//HOST/$(dlurl)}" 2.0.0
RUN_GLIBC=2.39 TANDO_NATIVE_TEST_ALLOW_LOCAL=1 runfix
check "10g glibc 2.39: fine, no warning (rc=$RC)" eval '[ "$RC" = 0 ] && ! has "needs glibc"'
# the URL a package without binary.host gets: its GitHub repository, prebuild-install's file name
newcase url
pkg "$S/node_modules/fakeprebuild" fakeprebuild 2.1.0 - - '"repository": { "url": "git+https://github.com/owner/fakeprebuild.git" }, "scripts": { "install": "prebuild-install || node-gyp rebuild" }' -
u=$(node "$LIB/lib/native.js" url "$S" node_modules/fakeprebuild arm64 glibc 24)
check "10h the default URL: GitHub release of the declared repository, file name by ABI and platform ($u)" \
  test "$u" = "https://github.com/owner/fakeprebuild/releases/download/v2.1.0/fakeprebuild-v2.1.0-node-v137-linux-arm64.tar.gz"
u=$(node "$LIB/lib/native.js" url "$S" node_modules/fakeprebuild x64 musl 22)
check "10i ... musl and another Node: ABI 127, linuxmusl ($u)" \
  test "$u" = "https://github.com/owner/fakeprebuild/releases/download/v2.1.0/fakeprebuild-v2.1.0-node-v127-linuxmusl-x64.tar.gz"
# node-pre-gyp style: host, remote_path, package_name and module_path of the package.json
printf 'napi-v6-linux-glibc-arm64/fake_npg.node\telf-arm64\n' | mktgz fakenpg/v3.0.0/fakenpg-v3.0.0-napi-v6-linux-glibc-arm64.tar.gz
newcase npg
pkg "$S/node_modules/fakenpg" fakenpg 3.0.0 - - "\"scripts\": { \"install\": \"node-pre-gyp install --fallback-to-build\" }, \"binary\": { \"module_name\": \"fakenpg\", \"module_path\": \"./lib/binding/napi-v{napi_build_version}-{platform}-{libc}-{arch}\", \"remote_path\": \"./{name}/v{version}/\", \"package_name\": \"{module_name}-v{version}-napi-v{napi_build_version}-{platform}-{libc}-{arch}.tar.gz\", \"host\": \"$(dlurl)\", \"napi_versions\": [6] }" -
mkdir -p "$S/node_modules/fakenpg/lib/binding/napi-v6-darwin-arm64"; macho "$S/node_modules/fakenpg/lib/binding/napi-v6-darwin-arm64/fake_npg.node"
TANDO_NATIVE_TEST_ALLOW_LOCAL=1 runfix
check "10j node-pre-gyp style: extracted into binary.module_path, the darwin one removed (rc=$RC: $(tail -3 "$C/out" | tr '\n' ' '))" \
  eval '[ "$RC" = 0 ] && [ -f "$S/node_modules/fakenpg/lib/binding/napi-v6-linux-glibc-arm64/fake_npg.node" ] && [ ! -e "$S/node_modules/fakenpg/lib/binding/napi-v6-darwin-arm64/fake_npg.node" ] && has "fakenpg.*downloaded prebuilt"'
# 404: no binary published for the server
newcase none
pi_pkg "$S/node_modules/fakesqlite" "${BIN//HOST/$(dlurl)}" 9.9.9
TANDO_NATIVE_TEST_ALLOW_LOCAL=1 runfix
check "10k no binary published (404): stops before upload naming the module, the URL and the two ways out (rc=$RC)" \
  eval '[ "$RC" != 0 ] && has "cannot be downloaded" && has "fakesqlite" && has "no prebuilt binary is published at" && has "tando ci github" && has "container"'

# ---- 11. hostile declarations: refused, nothing downloaded --------------------------------------
is_macho() { [ "$(head -c1 "$1" | od -An -tu1 | tr -d ' ')" = 207 ]; }
hostile() { # id text binary-json expected-message [env ALLOW=1: the local test host is allowed]
  newcase hostile3
  pi_pkg "$S/node_modules/fakesqlite" "$3"
  : > "$T/dl.log"
  TANDO_NATIVE_TEST_ALLOW_LOCAL=${ALLOW:-1} runfix
  exp=$4
  check "$1 $2 (rc=$RC: $(grep -i 'refused\|redirect\|not ' "$C/out" | head -1 | cut -c1-100))" \
    eval '[ "$RC" != 0 ] && has "$exp" && has "cannot be downloaded" && is_macho "$S/node_modules/fakesqlite/build/Release/node_fake.node"'
}
ALLOW=0 hostile 11a "an http host is refused" "${BIN//HOST/$(dlurl)}" "is not https"
check "11b ... and nothing was requested from it" test ! -s "$T/dl.log"
hostile 11c "an IP address as the host is refused" "${BIN//HOST/https://169.254.169.254}" "is not a public domain name"
hostile 11d "a host with credentials is refused" "${BIN//HOST/https://user:pw@example.org}" "credentials"
hostile 11e "a file name that reaches another host or path is refused" \
  '{ "napi_versions": [6], "host": "https://example.org", "package_name": "@other.example/x-{version}.tar.gz" }' "a part tando does not accept"
hostile 11f "a path that leaves the declared one is refused" \
  '{ "napi_versions": [6], "host": "https://example.org", "remote_path": "../../other", "package_name": "x-{version}.tar.gz" }' "a part tando does not accept"
hostile 11g "a template tando does not know is refused (nothing is evaluated)" \
  '{ "napi_versions": [6], "host": "https://example.org", "package_name": "{evil}-{version}.tar.gz" }' "uses {evil}"
hostile 11h "a spec that is not a tarball is refused" \
  '{ "napi_versions": [6], "host": "https://example.org", "package_name": "x-{version}.sh" }' "is not a .tar.gz"
hostile 11i "a redirect to another host is refused (the declared host answers 302)" \
  "$(b=${BIN//HOST/$(dlurl)}; echo "${b//\"remote_path\": \"dl\"/\"remote_path\": \"redir/dl\"}")" "redirects to"
check "11j ... the redirect was seen by the stub, the target was not asked for" \
  eval 'grep -q "^/redir/" "$T/dl.log" && ! grep -q "^/dl/" "$T/dl.log"'
# archives that try to write elsewhere
python3 - "$T/dl" <<'PY'
import io, sys, tarfile
root = sys.argv[1]
def make(name, entries):
    with tarfile.open(root + "/" + name, "w:gz") as t:
        for n, kind, data in entries:
            i = tarfile.TarInfo(n)
            if kind == "link":
                i.type = tarfile.SYMTYPE; i.linkname = data; t.addfile(i)
            else:
                i.size = len(data); t.addfile(i, io.BytesIO(data))
make("evil1.tar.gz", [("build/Release/../../../escape.node", "file", b"x")])
make("evil2.tar.gz", [("build/Release/ok.node", "file", b"x"), ("build/Release/link.node", "link", "/etc/passwd")])
make("evil3.tar.gz", [("other/dir/x.node", "file", b"x")])
make("evil4.tar.gz", [("/tmp/abs.node", "file", b"x")])
PY
for e in "evil1:an unsafe path" "evil2:not a plain file" "evil3:outside build/" "evil4:an unsafe path"; do
  b=${e%%:*}
  newcase evil
  pi_pkg "$S/node_modules/fakesqlite" '{ "napi_versions": [6], "host": "'"$(dlurl)"'", "package_name": "'"$b"'.tar.gz" }'
  TANDO_NATIVE_TEST_ALLOW_LOCAL=1 runfix
  check "11k a downloaded archive with ${e#*:} is refused, nothing extracted ($b, rc=$RC)" \
    eval '[ "$RC" != 0 ] && has "${e#*:}" && is_macho "$S/node_modules/fakesqlite/build/Release/node_fake.node" && [ ! -e "$S/node_modules/fakesqlite/build/escape.node" ]'
done
# sharp before 0.33 downloads libvips on its own: tando's download would leave it broken
newcase oldsharp
pkg "$S/node_modules/sharp" sharp 0.32.6 - - '"scripts": { "install": "(node install/libvips && node install/dll-copy && prebuild-install) || node-gyp rebuild" }' -
mkdir -p "$S/node_modules/sharp/build/Release"; macho "$S/node_modules/sharp/build/Release/sharp-darwin-arm64.node"
TANDO_NATIVE_TEST_ALLOW_LOCAL=1 runfix
check "11l sharp before 0.33 is refused with the reason (rc=$RC)" eval '[ "$RC" != 0 ] && has "downloads libvips separately" && has "sharp 0.32.6"'

# ---- 12. what only compiles on Linux: stopped before upload ----------------------------------------
newcase pty
pkg "$S/node_modules/node-pty" node-pty 1.1.0 - - '"scripts": { "install": "node scripts/prebuild.js || node-gyp rebuild" }' -
mkdir -p "$S/node_modules/node-pty/prebuilds/darwin-arm64" "$S/node_modules/node-pty/prebuilds/win32-x64"
macho "$S/node_modules/node-pty/prebuilds/darwin-arm64/pty.node"; pe "$S/node_modules/node-pty/prebuilds/win32-x64/pty.node"
runfix
check "12a node-pty (prebuilds for other platforms, compiles on Linux): stopped, naming the module, why, the two ways out (rc=$RC)" \
  eval '[ "$RC" != 0 ] && has "node_modules/node-pty" && has "node-pty 1.1.0" && has "none for linux-arm64" && has "compiled on Linux" &&
        has "tando ci github" && has "Linux container"'
check "12b ... and nothing was fetched or run" eval '[ "$(calls)" = 0 ]'
newcase gyp
pkg "$S/node_modules/plaingyp" plaingyp 1.0.0 - - '"scripts": { "install": "node-gyp rebuild" }' -
: > "$S/node_modules/plaingyp/binding.gyp"
runfix
check "12c a plain node-gyp module without a binary: stopped, says it is compiled when installed (rc=$RC)" \
  eval '[ "$RC" != 0 ] && has "plaingyp 1.0.0" && has "compiled when installed (node-gyp)" && has "tando ci github"'
newcase optgyp   # an optional dependency of another package (ssh2 and cpu-features): not a stop
pkg "$S/node_modules/ssh2like" ssh2like 1.0.0 - - '"optionalDependencies": { "cpufeat": "^1.0.0" }' -
pkg "$S/node_modules/cpufeat" cpufeat 1.0.0 - - '"scripts": { "install": "node-gyp rebuild" }' -
: > "$S/node_modules/cpufeat/binding.gyp"
runfix
check "12d a compile-only optional dependency does not stop the deploy; the block says so (rc=$RC)" \
  eval '[ "$RC" = 0 ] && has "optional dependency"'

# ---- 13. platform packages: more families, a missing server binary -------------------------------
newcase parcel   # @parcel/watcher names the Linux glibc build ...-linux-arm64-glibc
pkg "$S/node_modules/@parcel/watcher" @parcel/watcher 2.6.0 - - '"optionalDependencies": { "@parcel/watcher-darwin-arm64": "2.6.0", "@parcel/watcher-linux-arm64-glibc": "2.6.0", "@parcel/watcher-linux-arm64-musl": "2.6.0" }' -
pkg "$S/node_modules/@parcel/watcher-darwin-arm64" @parcel/watcher-darwin-arm64 2.6.0 darwin arm64 "" macho
runfix
check "13a @parcel/watcher: the -glibc build is the one fetched (rc=$RC: $(tail -2 "$C/out" | tr '\n' ' '))" \
  eval '[ "$RC" = 0 ] && [ "$(ver_of node_modules/@parcel/watcher-linux-arm64-glibc)" = 2.6.0 ] && [ ! -e "$S/node_modules/@parcel/watcher-darwin-arm64" ]'
newcase oxide   # only the WebAssembly fallback is installed: the native build is missing, silently
pkg "$S/node_modules/@tailwindcss/oxide" @tailwindcss/oxide 4.3.5 - - '"optionalDependencies": { "@tailwindcss/oxide-darwin-arm64": "4.3.5", "@tailwindcss/oxide-linux-arm64-gnu": "4.3.5", "@tailwindcss/oxide-wasm32-wasi": "4.3.5" }' -
pkg "$S/node_modules/@tailwindcss/oxide-wasm32-wasi" @tailwindcss/oxide-wasm32-wasi 4.3.5 - wasm32 "" -
runfix
check "13b @tailwindcss/oxide with only its WASM fallback: the server's native build is added, and the line says why (rc=$RC)" \
  eval '[ "$RC" = 0 ] && [ "$(ver_of node_modules/@tailwindcss/oxide-linux-arm64-gnu)" = 4.3.5 ] && has "@tailwindcss/oxide-linux-arm64-gnu.4.3.5.*WebAssembly fallback"'
newcase noswc   # Next lists its compiler per platform but none is installed (standalone): nothing is added
pkg "$S/node_modules/next" next 16.4.6 - - '"optionalDependencies": { "@next/swc-darwin-arm64": "16.4.6", "@next/swc-linux-arm64-gnu": "16.4.6" }' -
runfix
check "13c a family of which nothing is installed is not added (rc=$RC, npm calls $(calls))" eval '[ "$RC" = 0 ] && [ "$(calls)" = 0 ]'
newcase msgpackr   # the binary comes from a platform package beside it: not a module to fix
pkg "$S/node_modules/msgpackr-extract" msgpackr-extract 3.0.3 - - '"scripts": { "install": "node-gyp-build-optional-packages" }, "optionalDependencies": { "@msgpackr-extract/msgpackr-extract-darwin-arm64": "3.0.3", "@msgpackr-extract/msgpackr-extract-linux-arm64": "3.0.3" }' -
pkg "$S/node_modules/@msgpackr-extract/msgpackr-extract-darwin-arm64" @msgpackr-extract/msgpackr-extract-darwin-arm64 3.0.3 darwin arm64 "" macho
runfix
check "13d msgpackr-extract: its Linux package is swapped in and that is enough (rc=$RC: $(tail -2 "$C/out" | tr '\n' ' '))" \
  eval '[ "$RC" = 0 ] && [ "$(ver_of node_modules/@msgpackr-extract/msgpackr-extract-linux-arm64)" = 3.0.3 ]'

# ---- 14. a project .npmrc is never shipped ---------------------------------------------------------
newcase npmrc
printf '//registry.example.org/:_authToken=not-a-real-token\n' > "$S/.npmrc"
run
check "14a guard: a .npmrc in the release is refused (rc=$RC)" eval '[ "$RC" != 0 ] && has "secret files in the release" && has ".npmrc"'
for rcp in node next static; do
  newcase npmrc2
  mkdir -p "$C/out-$rcp/.next/standalone"
  src=$C/proj; mkdir -p "$src/public"
  printf '//registry.example.org/:_authToken=not-a-real-token\n' > "$src/.npmrc"; echo hi > "$src/index.html"; echo hi > "$src/server.js"
  cp "$src/.npmrc" "$src/public/.npmrc"
  ( cd "$src" || exit 2
    TANDO_HOME=$LIB TANDO_COLOR=never
    . "$LIB/lib/ui.sh"; ui_init 100
    . "$LIB/lib/common.sh"; . "$LIB/lib/build.sh"; . "$LIB/lib/deploy.sh"
    STAGE=.tando/stage CACHE=.tando/cache TMPD=$C/tmp K_arch=aarch64 K_libc=glibc C_recipe=$rcp C_out=. C_data=""
    if [ "$rcp" = next ]; then mkdir -p .next/standalone .next/static; cp index.html server.js .next/standalone/; cp .npmrc .next/standalone/; fi
    stage ) > "$C/out" 2>&1
  RC=$?
  check "14b stage ($rcp recipe): .npmrc is not copied into the release, the rest is (rc=$RC)" \
    eval '[ "$RC" = 0 ] && [ ! -e "$src/.tando/stage/.npmrc" ] && [ ! -e "$src/.tando/stage/public/.npmrc" ] && { [ -f "$src/.tando/stage/index.html" ] || [ -f "$src/.tando/stage/server.js" ]; }'
done

# ---- 15. Prisma: one note ------------------------------------------------------------------------------
newcase prisma7
pkg "$S/node_modules/@prisma/client" @prisma/client 7.10.1 - - "" -
runfix
check "15a Prisma 7: one note, with the migrate deploy target (rc=$RC)" \
  eval '[ "$RC" = 0 ] && has "Prisma 7.10.1: nothing to swap" && has "PRISMA_CLI_BINARY_TARGETS=linux-arm64-openssl-3.0.x"'
newcase prisma6
pkg "$S/node_modules/@prisma/client" @prisma/client 6.2.0 - - "" -
runfix
check "15b Prisma 6: the note points at the guard and binaryTargets (rc=$RC)" eval '[ "$RC" = 0 ] && has "Prisma 6.2.0: its query engine is a binary"'
newcase noprisma
pkg "$S/node_modules/left-pad" left-pad 1.0.0 - - "" -
runfix
check "15c no Prisma: no note (rc=$RC)" eval '[ "$RC" = 0 ] && ! has "Prisma"'

echo "native: $n checks, $nf failed"
[ "$nf" = 0 ]
