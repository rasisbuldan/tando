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
trap 'rm -rf "$T"' EXIT
n=0 nf=0
ok() { n=$((n + 1)); }
bad() { n=$((n + 1)); nf=$((nf + 1)); echo "FAIL native: $*"; }
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
# run swap_native then guard in the case's project directory, as a deploy does
run() { # [K_libc] [recipe]
  ( cd "$C" || exit 2
    TANDO_HOME=$LIB TANDO_COLOR=never NPMLOG=$C/npm.log
    export NPMLOG
    . "$LIB/lib/ui.sh"; ui_init 100
    . "$LIB/lib/common.sh"; . "$LIB/lib/build.sh"; . "$LIB/lib/deploy.sh"
    STAGE=.tando/stage CACHE=.tando/cache TMPD=$C/tmp K_arch=aarch64 K_libc=${1:-glibc} C_recipe=${2:-node} C_out=.
    swap_native && guard && { echo "OK swapped=${SWAPPED}"; cat "$TMPD/swaps" 2> /dev/null; }
  ) > "$C/out" 2>&1
  RC=$?
}
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

echo "native: $n checks, $nf failed"
[ "$nf" = 0 ]
