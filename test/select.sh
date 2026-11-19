#!/bin/bash
# test/select.sh: the suites that the changed files can break, from test/suites.map.
#
#   test/select.sh                 files changed against the upstream branch (or HEAD when there
#                                  is none), plus uncommitted and untracked ones
#   test/select.sh --base REF      changed against REF instead
#   test/select.sh --files a b c   these paths, whatever git says
#   test/select.sh --why           also say, on stderr, which file selected which suites
#   test/select.sh --list-files    only print the changed files it would look at
#
# Prints the suite names on one line, or ALL (a core file changed, or a file no rule knows), or
# NONE (nothing changed). A suite the map names that has no test/<suite>.sh is an error: the map
# is stale. Suites of the form test/e2e-<name>.sh whose own file changed are added without a rule.
# bash 3.2 compatible.
set -u
set -f   # no pathname expansion: the map's patterns are matched by case, never by the shell
ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 2
cd "$ROOT" || exit 2
MAP=$ROOT/test/suites.map
base="" why=0 files="" listf=0
while [ $# -gt 0 ]; do
  case $1 in
    --base) base=${2:?--base needs a ref}; shift;;
    --why) why=1;;
    --list-files) listf=1;;
    --files) shift; files=$(printf '%s\n' "$@"); set --; break;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0;;
    *) echo "select: unknown argument $1" >&2; exit 2;;
  esac
  shift
done
if [ -z "$files" ]; then
  if [ -z "$base" ]; then
    base=$(git rev-parse -q --verify '@{upstream}' 2> /dev/null) || base=HEAD
  fi
  git rev-parse -q --verify "$base^{commit}" > /dev/null 2>&1 || { echo "select: no such ref: $base" >&2; exit 2; }
  mb=$(git merge-base "$base" HEAD 2> /dev/null) || mb=$base
  files=$( { git diff --name-only "$mb" --; git ls-files --others --exclude-standard; } | sort -u)
fi
if [ "$listf" = 1 ]; then [ -z "$files" ] || printf '%s\n' "$files"; exit 0; fi
[ -n "$files" ] || { echo NONE; exit 0; }

# groups and rules from the map
groups="" rules=""
while IFS= read -r line; do
  case $line in ""|\#*) continue;; esac
  case $line in
    @*=*) g=${line%%=*}; g=${g%% *}; groups="$groups$g=$(echo "${line#*=}" | tr -s ' ' ' ');"$'\n';;
    *) rules="$rules$line"$'\n';;
  esac
done < "$MAP"
expand() { # words -> suites, groups replaced
  local w out="" g
  for w in "$@"; do
    case $w in
      @*) g=$(printf '%s' "$groups" | sed -n "s/^$w=\(.*\);\$/\1/p")
          [ -n "$g" ] || { echo "select: unknown group $w in test/suites.map" >&2; exit 2; }
          out="$out $g";;
      *) out="$out $w";;
    esac
  done
  printf '%s' "$out"
}

sel=" " all=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  hit=0 got=""
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    # shellcheck disable=SC2086  # the rule is split into its pattern and its suites on purpose
    set -- $r
    pat=$1; shift
    # shellcheck disable=SC2254  # the pattern is meant to be a pattern
    case $f in $pat) hit=1; got="$got $(expand "$@")" || exit 2;; esac
  done <<EOF2
$rules
EOF2
  # a suite's own file selects that suite
  case $f in test/e2e*.sh|test/ui-test.sh|test/lint.sh|test/go.sh|test/install-test.sh)
    s=${f#test/}; got="$got ${s%.sh}"; hit=1;; esac
  if [ "$hit" = 0 ]; then
    all=1; [ "$why" = 1 ] && echo "select: $f: no rule, so ALL" >&2
    continue
  fi
  [ "$why" = 1 ] && echo "select: $f:$got" >&2
  for s in $got; do
    [ "$s" = ALL ] && { all=1; continue; }
    [ -f "test/$s.sh" ] || { echo "select: test/suites.map names $s (for $f), but there is no test/$s.sh" >&2; exit 2; }
    case $sel in *" $s "*) ;; *) sel="$sel$s ";; esac
  done
done <<EOF2
$files
EOF2
if [ "$all" = 1 ]; then echo ALL; else echo "${sel# }" | sed 's/ $//'; fi
