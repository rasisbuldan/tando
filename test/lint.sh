#!/bin/bash
# test/lint.sh: shellcheck plus tando-specific checks (test/lint.pl) on every shell file, and the
# no-shell rule on the Go server programs (srv/**/*.go: RL15, RL16), compared with a baseline of
# known findings so that only new findings fail.
#
#   test/lint.sh                     list new findings; exit 1 when there is a new error
#   test/lint.sh --all               also list baseline, info (RL08 etc.) and stale baseline entries
#   test/lint.sh --strict            new warnings fail too
#   test/lint.sh --update-baseline   record every current finding as known (whole tree only)
#   test/lint.sh --list              print the files that would be linted, with their side
#   test/lint.sh --no-shellcheck     only the tando checks (no shellcheck, no Docker)
#   test/lint.sh [options] file...   lint these files only
#
# The shellcheck binary is $SHELLCHECK, else `shellcheck` on PATH, else the Docker image
# $SHELLCHECK_IMAGE (default koalaman/shellcheck:stable). Configuration: .shellcheckrc.
# Severities: shellcheck error and warning -> error; info and style -> info. The tando checks
# (RL01-RL11) are described in docs/TESTING.md. Silence one line with a comment on it or above
# it: `# lint: allow RL05 <reason>` (shellcheck codes: shellcheck's own disable directive).
# A whole-tree run also runs scripts/secret-scan.sh: any finding fails (it has no baseline).
# Exit: 0 clean, 1 new errors (or new warnings with --strict) or a secret-scan finding, 2 the
# linter itself failed.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
cd "$ROOT" || exit 2
BASELINE=${LINT_BASELINE:-test/lint-baseline.txt}
IMG=${SHELLCHECK_IMAGE:-koalaman/shellcheck:stable}
mode=show sc=1 list=0 all=0 strict=0
files=()

while [ $# -gt 0 ]; do
  case $1 in
    --all) all=1;;
    --strict) strict=1;;
    --update-baseline) mode=update;;
    --no-shellcheck) sc=0;;
    --list) list=1;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    -*) echo "lint: unknown option $1" >&2; exit 2;;
    *) files+=("$1");;
  esac
  shift
done

# kind <file>: bash | zsh | go | "" (none of these)
kind() {
  local first=""
  case $1 in
    srv/tools/*) return;;   # srv/tools/srvlint checks itself and the rest (test/go.sh g4)
    srv/*.go) echo go; return;;
    *.zsh|completions/_*) echo zsh; return;;
    *.sh|*.bash) echo bash; return;;
    *.py|*.pl|*.md|*.js|*.json|*.txt|*.conf|*.service|*.timer|*.caddy|Caddyfile) return;;
  esac
  [ -f "$1" ] || return 0
  IFS= read -r first < "$1" || true
  case $first in
    '#!'*zsh*) echo zsh;;
    '#!'*bash*|'#!'*/sh|'#!'*/sh' '*|'#!'*' sh') echo bash;;
  esac
}

side() {
  case $1 in
    server/*|srv/*|test/server/files/*|test/replica/files/*) echo server;;
    *) if grep -q '^#[[:space:]]*lint:[[:space:]]*side=\(server\|linux\)' "$1" 2> /dev/null; then echo linux
       else echo laptop; fi;;
  esac
}

all_files() {
  local f
  {
    for f in bin/* lib/* server/* install.sh uninstall.sh completions/* scripts/*; do
      [ -f "$f" ] && echo "$f"
    done
    find test -name '.*' -prune -o -name node_modules -prune -o -type f -print
    [ -d srv ] && find srv -name '*.go' -type f
  } | sort -u | while IFS= read -r f; do
    case $f in test/lint.pl|*/id_test*) continue;; esac
    [ -n "$(kind "$f")" ] && echo "$f"
  done
}

if [ ${#files[@]} -eq 0 ]; then
  partial=0
  while IFS= read -r f; do files+=("$f"); done < <(all_files)
else
  partial=1
  [ "$mode" = update ] && { echo "lint: --update-baseline needs the whole tree (no file arguments)" >&2; exit 2; }
fi

if [ "$list" = 1 ]; then
  for f in ${files[@]+"${files[@]}"}; do printf '%-7s %-5s %s\n' "$(side "$f")" "$(kind "$f")" "$f"; done
  exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tando-lint.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

frag=() prog=() zshf=() gof=()
for f in ${files[@]+"${files[@]}"}; do
  case $(kind "$f") in
    go) gof+=("$f");;
    zsh) zshf+=("$f");;
    bash)
      case $f in
        # sourced fragments of one program: globals defined in one file are used in another
        lib/*.sh|test/lib.sh) frag+=("$f");;
        *) prog+=("$f");;
      esac;;
  esac
done

run_shellcheck() { # [shellcheck options] -- files...
  if [ -n "${SHELLCHECK:-}" ]; then "$SHELLCHECK" -f gcc "$@"
  elif command -v shellcheck > /dev/null 2>&1; then shellcheck -f gcc "$@"
  else docker run --rm -v "$ROOT:/mnt:ro" -w /mnt "$IMG" -f gcc "$@"
  fi
}

: > "$tmp/found"
if [ "$sc" = 1 ] && [ $((${#frag[@]} + ${#prog[@]})) -gt 0 ]; then
  if [ -z "${SHELLCHECK:-}" ] && ! command -v shellcheck > /dev/null 2>&1 &&
     ! docker image inspect "$IMG" > /dev/null 2>&1 && ! docker pull -q "$IMG" > /dev/null 2>&1; then
    echo "lint: no shellcheck (install it, or start Docker; --no-shellcheck skips it)" >&2
    exit 2
  fi
  # one shellcheck per file, LINT_JOBS at a time (a Docker run costs seconds; files are independent)
  i=0
  for f in ${frag[@]+"${frag[@]}"} ${prog[@]+"${prog[@]}"}; do
    while [ "$(jobs -pr | wc -l)" -ge "${LINT_JOBS:-8}" ]; do sleep 0.2; done
    case $f in
      lib/*.sh|test/lib.sh) run_shellcheck -e SC2034 "$f";;
      *) run_shellcheck "$f";;
    esac > "$tmp/sc.$i" 2> "$tmp/sc.err.$i" &
    i=$((i + 1))
  done
  wait
  cat "$tmp"/sc.[0-9]* > "$tmp/sc" 2> /dev/null
  cat "$tmp"/sc.err.* > "$tmp/sc.err" 2> /dev/null
  if [ -s "$tmp/sc.err" ]; then
    echo "lint: shellcheck failed:" >&2; head -5 "$tmp/sc.err" >&2; exit 2
  fi
  # file:line:col: severity: message [SCnnnn]  ->  file TAB line TAB col TAB sev TAB code TAB message
  perl -ne 'next unless /^(.+?):(\d+):(\d+): (\w+): (.*) \[(SC\d+)\]$/;
    my %s = (error => "error", warning => "error", note => "info");
    print join("\t", $1, $2, $3, $s{$4} // "info", $6, $5), "\n"' "$tmp/sc" >> "$tmp/found"
fi

if [ ${#zshf[@]} -gt 0 ]; then
  if command -v zsh > /dev/null 2>&1; then
    for f in ${zshf[@]+"${zshf[@]}"}; do
      zsh -n "$f" 2> "$tmp/zsh" ||
        printf '%s\t1\t1\terror\tZSH\tzsh -n: %s\n' "$f" "$(head -1 "$tmp/zsh")" >> "$tmp/found"
    done
  else
    echo "lint: zsh not installed: skipped ${zshf[*]+${zshf[*]}}" >&2
  fi
fi

# generated completions must match the command list (whole-tree runs only)
if [ "$partial" = 0 ] && [ -x completions/gen.sh ] && ! completions/gen.sh --check > /dev/null 2>&1; then
  printf 'completions/tando.bash\t1\t1\terror\tRL12\t%s\n' \
    'completions are out of date with the command list: run completions/gen.sh' \
    >> "$tmp/found"
fi

[ ${#frag[@]} -eq 0 ] && [ ${#prog[@]} -eq 0 ] ||
  perl "$ROOT/test/lint.pl" rules ${frag[@]+"${frag[@]}"} ${prog[@]+"${prog[@]}"} >> "$tmp/found" || exit 2
[ ${#gof[@]} -eq 0 ] || perl "$ROOT/test/lint.pl" gorules ${gof[@]+"${gof[@]}"} >> "$tmp/found" || exit 2

echo "lint: ${#files[@]} files ($((${#frag[@]} + ${#prog[@]})) bash, ${#zshf[@]} zsh, ${#gof[@]} go)," \
  "shellcheck $([ "$sc" = 1 ] && echo on || echo off)"
[ "$all" = 1 ] && mode=$mode,all
[ "$strict" = 1 ] && mode=$mode,strict
LINT_PARTIAL=$partial perl "$ROOT/test/lint.pl" report "$BASELINE" "$mode" < "$tmp/found"
rc=$?
# credentials and private details in what git would commit (whole-tree runs only). Not part of the
# baseline on purpose: --update-baseline must never be a way to accept a secret.
if [ "$partial" = 0 ] && [ "$list" = 0 ]; then
  if ! "$ROOT/test/secret-scan-test.sh" > "$tmp/secrets-test" 2>&1; then
    echo "lint: the secret scanner fails its own test (test/secret-scan-test.sh):"
    grep '^FAIL' "$tmp/secrets-test" | sed 's/^/lint: /'
    [ "$rc" = 0 ] && rc=1
  fi
  "$ROOT/scripts/secret-scan.sh" > "$tmp/secrets" 2>&1 || { [ "$rc" = 0 ] && rc=1; }
  sed 's/^/lint: /' "$tmp/secrets"
fi
exit "$rc"
