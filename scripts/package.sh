#!/bin/bash
# scripts/package.sh: build the client packages from the release archive.
#
#   scripts/package.sh homebrew     dist/homebrew/tando.rb (version and sha256 of the archive)
#   scripts/package.sh npm          dist/npm/ (package.json + the release tree) and dist/tando-cli-<v>.tgz
#   scripts/package.sh deb          dist/tando_<v>_all.deb (needs dpkg-deb: Debian, Ubuntu)
#   scripts/package.sh all          the three, in that order
#   scripts/package.sh --list       the files every package ships (the release archive's list)
#
# Every package is made from dist/tando-<v>.tar.gz (built here by scripts/release.sh when it is
# missing), so all of them ship exactly what scripts/release.sh lists: bin/, lib/, server/ with
# the Go programs in server/linux-{amd64,arm64}/, templates/, completions/ and the top-level files.
# The checksum next to the archive is verified first.
# TANDO_REPO=<owner>/<repo> sets the GitHub URLs (default OWNER/tando, like install.sh);
# TANDO_MAINTAINER sets the deb Maintainer field. Templates: packaging/.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
cd "$ROOT" || exit 2
REPO=${TANDO_REPO:-OWNER/tando}
MAINTAINER=${TANDO_MAINTAINER:-tando maintainers <maintainers@tando.invalid>}

die() { echo "package: $*" >&2; exit 1; }
say() { echo "package: $*"; }

V=$(tr -d ' \n' < VERSION 2> /dev/null)
case $V in [0-9]*.[0-9]*.[0-9]*) ;; *) die "VERSION must be X.Y.Z (got '$V')";; esac
A=$ROOT/dist/tando-$V.tar.gz

sha256() {
  if command -v shasum > /dev/null 2>&1; then shasum -a 256 "$1"
  elif command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"
  else openssl dgst -sha256 -r "$1"
  fi | cut -d' ' -f1
}

# archive: make sure dist/tando-V.tar.gz exists and matches its .sha256; prints the checksum
archive() {
  if [ ! -f "$A" ]; then
    say "building dist/tando-$V.tar.gz (scripts/release.sh)" >&2
    scripts/release.sh > /dev/null || die "scripts/release.sh failed"
  fi
  local want got
  want=$(cut -d' ' -f1 < "$A.sha256" 2> /dev/null) || die "missing $A.sha256"
  got=$(sha256 "$A")
  [ -n "$want" ] && [ "$got" = "$want" ] || die "dist/tando-$V.tar.gz does not match its .sha256: rebuild with scripts/release.sh"
  printf '%s\n' "$got"
}

# unpack <dir>: the release tree in <dir>/tando-V (the archive is the one list of what ships)
unpack() {
  rm -rf "$1" && mkdir -p "$1" || die "cannot create $1"
  tar -xzf "$A" -C "$1" || die "cannot unpack $A"
  [ -x "$1/tando-$V/bin/tando" ] || die "the archive has no executable bin/tando"
}

# license_id: the SPDX id LICENSE names, or nothing
license_id() {
  if grep -q 'PolyForm Noncommercial License 1\.0\.0' LICENSE 2> /dev/null; then echo PolyForm-Noncommercial-1.0.0
  elif grep -q 'MIT License' LICENSE 2> /dev/null; then echo MIT
  elif grep -q 'Apache License' LICENSE 2> /dev/null && grep -q 'Version 2\.0' LICENSE; then echo Apache-2.0
  fi
}

homebrew() {
  local sum lic out=$ROOT/dist/homebrew
  sum=$(archive) || exit 1
  lic=$(license_id); if [ -n "$lic" ]; then lic="\"$lic\""; else lic=":cannot_represent"; fi
  mkdir -p "$out" || die "cannot create $out"
  sed -e "s|@VERSION@|$V|g" -e "s|@SHA256@|$sum|g" -e "s|@REPO@|$REPO|g" -e "s|@LICENSE@|$lic|g" \
    packaging/homebrew/tando.rb > "$out/tando.rb" || die "cannot write $out/tando.rb"
  ! grep -q '@[A-Z0-9]*@' "$out/tando.rb" || die "unfilled placeholder in $out/tando.rb"
  say "dist/homebrew/tando.rb  (tando $V, sha256 $sum, url https://github.com/$REPO/releases/...)"
  case $REPO in OWNER/*) say "note: set TANDO_REPO=<owner>/<repo> before publishing the formula";; esac
}

npm_pkg() {
  command -v node > /dev/null 2>&1 || die "npm: node is needed to write package.json"
  command -v npm > /dev/null 2>&1 || die "npm: npm is needed to pack the package"
  archive > /dev/null || exit 1
  local t=$ROOT/dist/.npm-stage out=$ROOT/dist/npm
  unpack "$t"
  rm -rf "$out" && mv "$t/tando-$V" "$out" && rm -rf "$t" || die "cannot create dist/npm"
  # "files": the release tree's top-level entries, so the package ships what the archive ships
  (cd "$out" && ls -A) > "$ROOT/dist/.npm-files"
  node -e '
    const fs = require("fs");
    const [tpl, out, v, repo, lic, list] = process.argv.slice(1);
    const p = JSON.parse(fs.readFileSync(tpl, "utf8"));
    p.version = v;
    p.files = fs.readFileSync(list, "utf8").split("\n").filter(Boolean)
      .map(f => fs.statSync(out + "/" + f).isDirectory() ? f + "/" : f);
    if (lic) p.license = lic;
    p.homepage = "https://github.com/" + repo;
    p.repository.url = "git+https://github.com/" + repo + ".git";
    if (Object.keys(p.scripts || {}).length) { console.error("package: npm: the template has scripts"); process.exit(1); }
    fs.writeFileSync(out + "/package.json", JSON.stringify(p, null, 2) + "\n");
  ' packaging/npm/package.json "$out" "$V" "$REPO" "$(license_id)" "$ROOT/dist/.npm-files" || die "npm: package.json"
  rm -f "$ROOT/dist/.npm-files"
  # npm keeps its cache and logs inside dist/, not in ~/.npm
  (cd "$ROOT/dist" && npm pack ./npm --silent --cache "$ROOT/dist/.npm-cache" --logs-dir "$ROOT/dist/.npm-cache/_logs" > /dev/null) ||
    die "npm pack failed"
  [ -f "$ROOT/dist/tando-cli-$V.tgz" ] || die "npm pack did not write dist/tando-cli-$V.tgz"
  say "dist/npm/ and dist/tando-cli-$V.tgz  (publish with: npm publish dist/tando-cli-$V.tgz)"
}

deb() {
  command -v dpkg-deb > /dev/null 2>&1 ||
    die "deb: dpkg-deb not found (it comes with dpkg on Debian and Ubuntu); nothing was built"
  archive > /dev/null || exit 1
  local t=$ROOT/dist/.deb-stage r out=$ROOT/dist/tando_${V}_all.deb mtime
  unpack "$t/x"
  r=$t/root
  mkdir -p "$r/DEBIAN" "$r/usr/lib" "$r/usr/bin" "$r/usr/share/bash-completion/completions" \
    "$r/usr/share/zsh/vendor-completions" "$r/usr/share/doc/tando" || die "deb: staging"
  mv "$t/x/tando-$V" "$r/usr/lib/tando" || die "deb: staging"
  ln -s ../lib/tando/bin/tando "$r/usr/bin/tando"
  cp "$r/usr/lib/tando/completions/tando.bash" "$r/usr/share/bash-completion/completions/tando"
  cp "$r/usr/lib/tando/completions/_tando" "$r/usr/share/zsh/vendor-completions/_tando"
  [ -f "$r/usr/lib/tando/LICENSE" ] && cp "$r/usr/lib/tando/LICENSE" "$r/usr/share/doc/tando/copyright"
  sed -e "s|@VERSION@|$V|g" -e "s|@REPO@|$REPO|g" -e "s|@MAINTAINER@|$MAINTAINER|g" \
    packaging/deb/control > "$r/DEBIAN/control" || die "deb: control"
  ! grep -q '@[A-Z0-9]*@' "$r/DEBIAN/control" || die "deb: unfilled placeholder in control"
  printf 'Installed-Size: %s\n' "$(du -sk "$r/usr" | cut -f1)" >> "$r/DEBIAN/control"
  chmod -R u+rwX,go+rX,go-w "$r"
  chmod 755 "$r/DEBIAN"
  # same archive, same package: every file gets release.sh's timestamp (SOURCE_DATE_EPOCH)
  mtime=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2> /dev/null || echo 0)}
  find "$r" -exec touch -h -d "@$mtime" {} + 2> /dev/null || true
  SOURCE_DATE_EPOCH=$mtime dpkg-deb --root-owner-group -Zxz --build "$r" "$out" > /dev/null || die "dpkg-deb failed"
  rm -rf "$t"
  say "dist/tando_${V}_all.deb  ($(wc -c < "$out" | tr -d ' ') bytes; files under /usr/lib/tando, /usr/bin/tando)"
}

case ${1:-} in
  homebrew) homebrew;;
  npm) npm_pkg;;
  deb) deb;;
  all) homebrew && npm_pkg && deb;;
  --list) archive > /dev/null && tar -tzf "$A" | sed "s|^tando-$V/||; /^$/d; /\/$/d" | LC_ALL=C sort;;
  -h|--help|"") sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; [ -n "${1:-}" ];;
  *) die "unknown target $1 (homebrew, npm, deb, all; see --help)";;
esac
