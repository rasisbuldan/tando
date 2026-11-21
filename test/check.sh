#!/bin/bash
# test/check.sh: the first tier, seconds long: run it after every edit, before anything slower.
# It looks only at the files that changed (test/select.sh says which) and needs no test server.
#
#   test/check.sh                changed against the upstream branch, plus uncommitted/untracked
#   test/check.sh --base REF     changed against REF
#   test/check.sh --files a b    these files
#
#   c1 syntax     bash -n on every changed shell file with /bin/bash (3.2 on macOS); the server
#                 side (server/) also with the bash of the test server's image, when it is built
#   c2 lint       test/lint.sh on the changed files (the tando rules and shellcheck)
#   c3 go         only when srv/ changed: gofmt, go vet and go test (cached) of the changed packages
#   c4 secrets    scripts/secret-scan.sh over the whole tree (keys, tokens, addresses, home paths)
#   c5 map        test/select.sh can map the change to suites (test/suites.map is not stale)
#
# Passing here says little: it finds typos, not behaviour. Next: test/all.sh --tier quick.
# Output: PASS/FAIL/SKIP lines (docs/TESTING.md) and the suites the quick tier would run.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$ROOT" || exit 2
T_SUITE=check
T0=$SECONDS
args=()
while [ $# -gt 0 ]; do
  case $1 in
    --base) args+=(--base "${2:?--base needs a ref}"); shift;;
    --files) args=("$@"); break;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    *) echo "check: unknown argument $1" >&2; exit 2;;
  esac
  shift
done
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
test/select.sh ${args[@]+"${args[@]}"} --list-files > "$tmp/files" 2> "$tmp/err" ||
  { cat "$tmp/err" >&2; echo "check: could not list the changed files" >&2; exit 2; }
# (--files stops option parsing in select.sh, so --list-files went first only without it)
case " ${args[*]+${args[*]}} " in *" --files "*)
  shift_n=0; : > "$tmp/files"
  for a in ${args[@]+"${args[@]}"}; do [ "$shift_n" = 1 ] && printf '%s\n' "$a" >> "$tmp/files"; [ "$a" = --files ] && shift_n=1; done;;
esac
grep -c . "$tmp/files" > /dev/null || { echo "check: nothing changed"; exit 0; }
: > "$tmp/exist"
while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f" >> "$tmp/exist"; done < "$tmp/files"   # (deleted files: nothing to read)

# ---- c1 syntax
is_shell() { # a shell program or fragment: by place, or by its first line
  case $1 in
    *.md|*.txt|*.go|*.py|*.pl|*.js|*.json|*.yml|*.yaml|*.map|*.tsv|*.html|*.css) return 1;;
    *.sh|bin/tando|server/tando-agent|server/tando-adopt|server/tando-install-recover|server/legacy/*) return 0;;
  esac
  head -n 1 "$1" 2> /dev/null | grep -q '^#!.*\(ba\)\{0,1\}sh'
}
# server-side files run under bash 5 on the server, and must also parse under 3.2 (the laptop
# reads them for checks): both, the newer one in the test server's image when Docker is up
srvimg=""
if docker image inspect tando-testvm:latest > /dev/null 2>&1; then srvimg=tando-testvm:latest; fi
bad="" n=0 skipped=""
while IFS= read -r f; do
  is_shell "$f" || continue
  /bin/bash -n "$f" 2>> "$tmp/syn" || bad="$bad $f"; n=$((n + 1))
  case $f in server/*)
    if [ -n "$srvimg" ]; then
      docker run --rm --entrypoint bash -v "$ROOT/server:/s:ro" "$srvimg" -n "/s/${f#server/}" 2>> "$tmp/syn" || bad="$bad $f(bash5)"
    else skipped="$skipped $f"; fi;;
  esac
done < "$tmp/exist"
[ -s "$tmp/syn" ] && cat "$tmp/syn" >&2
check "c1 syntax: bash -n on $n changed shell files${bad:+ (broken:$bad)}" test -z "$bad"
[ -z "$skipped" ] || skip "c1b no test server image (test/server/up.sh builds it): the server's own bash did not parse$skipped"

# ---- c2 lint (the changed files that lint knows)
test/lint.sh --list 2> /dev/null | awk '{ print $NF }' | sort > "$tmp/lintable"
sort "$tmp/exist" | comm -12 - "$tmp/lintable" > "$tmp/tolint"
if [ -s "$tmp/tolint" ]; then
  # shellcheck disable=SC2046  # file names in this tree have no spaces (lint refuses them)
  test/lint.sh $(cat "$tmp/tolint") > "$tmp/lint.out" 2>&1; rc=$?
  [ "$rc" = 0 ] || cat "$tmp/lint.out" >&2
  check "c2 lint: $(wc -l < "$tmp/tolint" | tr -d ' ') changed files (rc=$rc; $(tail -n 1 "$tmp/lint.out" | cut -c1-80))" test "$rc" = 0
else
  skip "c2 lint: no changed file that lint reads"
fi

# ---- c3 go (changed packages only; the test cache is on)
if grep -qE '^srv/(.*\.go|go\.mod)$' "$tmp/exist"; then
  if command -v go > /dev/null 2>&1; then
    # (a fixture under testdata/ is no package of its own: Go skips it; its test's package is the one)
    pk=$(grep '^srv/.*\.go$' "$tmp/exist" | sed 's|^srv/||; s|/[^/]*$||; s|/testdata/.*||; s|/testdata$||' | sort -u | sed 's|^|./|' | tr '\n' ' ')
    grep -q '^srv/go\.mod$' "$tmp/exist" && pk=./...
    gof=$(grep '^srv/.*\.go$' "$tmp/exist" | sed 's|^srv/||' | tr '\n' ' ')
    # shellcheck disable=SC2086  # package and file lists are word lists
    ( cd srv && export GOTOOLCHAIN=local GOFLAGS= &&
      { [ -z "$gof" ] || [ -z "$(gofmt -l $gof 2>&1 | tee "$tmp/gofmt")" ]; } &&
      go vet $pk > "$tmp/go.out" 2>&1 && go test $pk >> "$tmp/go.out" 2>&1 ); rc=$?
    [ "$rc" = 0 ] || { cat "$tmp/gofmt" "$tmp/go.out" 2> /dev/null >&2; }
    check "c3 go: gofmt, vet and test of $pk(rc=$rc)" test "$rc" = 0
  else
    skip "c3 go: Go is not installed, srv/ was not checked"
  fi
else
  skip "c3 go: srv/ did not change"
fi

# ---- c4 secrets
scripts/secret-scan.sh > "$tmp/sec.out" 2>&1; rc=$?
[ "$rc" = 0 ] || cat "$tmp/sec.out" >&2
check "c4 secrets: $(tail -n 1 "$tmp/sec.out" | cut -c1-70)" test "$rc" = 0

# ---- c5 the map knows the change
if sel=$(test/select.sh ${args[@]+"${args[@]}"} 2> "$tmp/sel.err"); then
  pass "c5 map: test/suites.map covers the change"
else
  cat "$tmp/sel.err" >&2; fail "c5 map: test/select.sh failed (a stale test/suites.map?)"; sel="?"
fi
echo "check: $((SECONDS - T0)) s. The quick tier would run: $sel  (test/all.sh --tier quick)"
t_done
