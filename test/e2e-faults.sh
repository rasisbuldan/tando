#!/bin/bash
# test/e2e-faults.sh: the fault-injection scenarios of docs/FAULT-REVIEW.md (test/faults/*.sh) on
# a 2 GB, 1-CPU test server. Each scenario exits 0 when tando held (served the right release, told
# the truth, and the next deploy worked untouched): a PASS here. By default the 27 scenarios that
# failed in the review plus the baseline, and m1-m6 (soak rollback alert, deploy behind a soak,
# unknown hosts, static pages, env before up/during a soak and job-run, failure hints), a21 (the
# activation killed while the release command of tando.conf runs), n1-n7 (jobs follow
# the verified release, env revert, same-user lease, domain lost update, idempotent re-runs, liveness
# restart, load limits); --all runs
# every scenario (the restarts and power losses are slow); --only a1,b3 runs those.
#
#   test/e2e-faults.sh                       the whole list, in order, on one server
#   test/e2e-faults.sh --shard 2/4           the 2nd of 4 chunks of the list (s00 first in each): run
#                                            the K shards at once, each on its own server
#   test/e2e-faults.sh --shard 1/2 --rotate 7     rotate the list by 7 before cutting it into chunks
#   test/e2e-faults.sh --shard 1/2 --rotate auto  ... by the day of the year (see rotate_auto)
#   test/e2e-faults.sh [--shard i/K ...] --plan   print the chunks and what they should take; run nothing
# test/e2e-faults-q1.sh .. q4.sh are --shard i/4, test/e2e-faults-h1.sh and h2.sh --shard i/2
# --rotate auto: suites of their own for test/all.sh.
#
# The soak: the deploy a scenario makes as the thing under test soaks TANDO_SOAK=25 s (e4 crashes
# 20 s after going live); the deploys that only prepare or close a scenario (f_fresh, next_deploy:
# test/faults/lib-fault.sh) soak FAULT_SETUP_SOAK s (default 2). FAULT_SETUP_SOAK=25 is the
# unmodified run: every deploy soaks 25 s, as before there was a setup soak.
# bash 3.2 compatible.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
FD=$(cd "$(dirname "$0")" && pwd -P)/faults
all=0 only="" shard="" rotate="" plan=0
while [ $# -gt 0 ]; do
  case $1 in
    --all) all=1;;
    --only) only=$(printf '%s' "${2:-}" | tr ',' ' '); [ $# -gt 1 ] && shift;;
    --shard) shard=${2:-}; [ $# -gt 1 ] && shift;;
    --rotate) rotate=${2:-}; [ $# -gt 1 ] && shift;;
    --plan) plan=1;;
    *) echo "e2e-faults: unknown argument \"$1\" (--all, --only a1,b3, --shard i/K, --rotate N|auto, --plan)" >&2; exit 2;;
  esac
  shift
done
SI=0 SK=0
case $shard in
  "") ;;
  *[!0-9/]*|*/*/*|/*|*/) echo "e2e-faults: --shard is i/K, e.g. 2/4 (got \"$shard\")" >&2; exit 2;;
  */*) SI=$((10#${shard%/*})) SK=$((10#${shard#*/}))
       { [ "$SI" -ge 1 ] && [ "$SI" -le "$SK" ]; } || { echo "e2e-faults: --shard $shard: i is 1..K" >&2; exit 2; };;
  *) echo "e2e-faults: --shard is i/K, e.g. 2/4 (got \"$shard\")" >&2; exit 2;;
esac
case $rotate in
  ""|auto) ;;
  *[!0-9]*) echo "e2e-faults: --rotate is a number or auto (got \"$rotate\")" >&2; exit 2;;
esac
[ -z "$rotate" ] || [ "$SK" != 0 ] || { echo "e2e-faults: --rotate needs --shard i/K" >&2; exit 2; }

# ---- the list, and its chunks ---------------------------------------------------------------------

# Seconds a scenario takes with FAULT_SETUP_SOAK=2 (measured 2026-11-19 with four shards at once,
# each on a 1-CPU server; s00 without the first host setup of a server, which every shard pays
# once); a scenario not listed counts as DUR_DEFAULT. Only the cut of the list
# into chunks of about equal time reads these: a stale number costs balance, nothing else.
DUR_DEFAULT=90
DUR=" s00=60 a1=40 a2=65 a3=230 a4=50 a5=70 a21=45 b2=35 b3=75 d1=30 d2=75 d3=60 d4=70 e4=105 e5=105
 e10=170 f3=70 g1=45 g3=70 g5=20 g6=25 g7=50 g8=55 g9=65 g10=120 h2=30 h5=55 j1=55 l1=105 m1=145
 m2=195 m3=70 m4=6 m5=130 m6=2 n1=105 n2=75 n3=90 n4=190 n5=320 n6=85 n7=75 "
dur_of() {
  local d
  case $DUR in
    *[[:space:]]"$1="*) d=${DUR##*[[:space:]]"$1"=}; echo "${d%%[[:space:]]*}";;
    *) echo "$DUR_DEFAULT";;
  esac
}
secs_of() { local id t=0; for id; do t=$((t + $(dur_of "$id"))); done; echo "$t"; }

# rotated <n> <ids...>: the ids, starting n places further (the first n moved to the end)
rotated() {
  local n=$1 i=0 id head="" tail=""
  shift
  [ $# -gt 0 ] || return 0
  n=$((n % $#))
  for id; do
    if [ $i -lt "$n" ]; then tail="$tail $id"; else head="$head $id"; fi
    i=$((i + 1))
  done
  echo $head $tail
}

# rotate_auto: the day of the year (1-366). Every shard of one run must cut the same list, and the
# shards of a nightly run can start on both sides of midnight (test/all.sh starts a suite when a
# server is free), so the number is kept in test/.e2e-faults-rotate with the time it was taken and
# used again by any shard that starts within 12 hours of it.
rotate_auto() {
  local f=$FD/../.e2e-faults-rotate n="" t="" now
  now=$(date +%s)
  if [ -f "$f" ]; then read -r n t < "$f" || true; fi
  case $n:$t in *[!0-9:]*|:*|*:) n="";; esac
  if [ -n "$n" ] && [ $((now - t)) -ge 0 ] && [ $((now - t)) -lt 43200 ]; then echo "$n"; return 0; fi
  n=$(date +%j); n=$((10#$n))
  if [ "$plan" = 1 ]; then echo "$n"; return 0; fi      # --plan leaves no trace
  echo "$n $now" > "$f.$$" && mv -f "$f.$$" "$f"
  read -r n t < "$f"; echo "$n"                          # (what is there now: another shard may have written it)
}

# chunks <K> <ids...>: K lines, the ids of each chunk. The chunks are contiguous pieces of the
# list, in its order; among all such cuts the one whose longest chunk is shortest (by dur_of), and
# among those the most even one (least sum of squares). No chunk is empty unless there are fewer
# ids than chunks.
chunks() {
  local k=$1 id
  shift
  for id; do echo "$id $(dur_of "$id")"; done | awk -v K="$k" '
    { id[NR] = $1; pre[NR] = pre[NR - 1] + $2 }
    END {
      n = NR; k = (K < n) ? K : n            # k chunks hold something
      for (j = 1; j <= n; j++) { mx[1, j] = pre[j]; sq[1, j] = pre[j] * pre[j] }
      for (c = 2; c <= k; c++) for (j = c; j <= n; j++) {
        mx[c, j] = -1
        for (i = c - 1; i < j; i++) {        # chunk c is i+1..j, the c-1 before it are 1..i
          s = pre[j] - pre[i]; m = (mx[c - 1, i] > s) ? mx[c - 1, i] : s; q = sq[c - 1, i] + s * s
          if (mx[c, j] < 0 || m < mx[c, j] || (m == mx[c, j] && q < sq[c, j])) { mx[c, j] = m; sq[c, j] = q; cut[c, j] = i }
        }
      }
      j = n
      for (c = k; c >= 1; c--) {
        i = (c > 1) ? cut[c, j] : 0; line[c] = ""
        for (x = i + 1; x <= j; x++) line[c] = line[c] (x > i + 1 ? " " : "") id[x]
        j = i
      }
      for (c = 1; c <= K; c++) print line[c]
    }'
}
chunk_n() { chunks "$SK" $2 | sed -n "$1p"; }       # chunk_n <i> "<ids>"

list="s00 a1 a2 a3 a4 a5 a21 b2 b3 d1 d2 d3 d4 e4 e5 e10 f3 g1 g3 g5 g6 g7 g8 g9 g10 h2 h5 j1 l1 m1 m2 m3 m4 m5 m6 n1 n2 n3 n4 n5 n6 n7"
[ -n "$only" ] && list=$only
if [ $all = 1 ]; then
  list=$(cd "$FD" && ls [a-z]*[0-9]-*.sh | sed 's/-.*//' | sort -t. -k1,1 | tr '\n' ' ')
fi
file_of() { ls "$FD/$1"-*.sh 2> /dev/null | head -1; }

# self-check, before anything runs: every id of the list is a scenario, once; and with --shard the
# K chunks together are the list (without s00, which every shard runs first), each id once
SELF=""
for id in $list; do
  [ -n "$(file_of "$id")" ] || SELF="$SELF; \"$id\" is in the list but test/faults/$id-*.sh does not exist"
done
dup=$(printf '%s\n' $list | sort | uniq -d | tr '\n' ' ')
[ -z "$dup" ] || [ "$SK" = 0 ] || SELF="$SELF; in the list more than once: $dup"
ROT=0 run=$list
if [ "$SK" != 0 ]; then
  rest=$(for id in $list; do [ "$id" = s00 ] || printf '%s ' "$id"; done)
  case $rotate in "") ;; auto) ROT=$(rotate_auto);; *) ROT=$((10#$rotate));; esac
  rest=$(rotated "$ROT" $rest)
  i=1 union=""
  while [ $i -le "$SK" ]; do union="$union $(chunk_n $i "$rest")"; i=$((i + 1)); done
  want=$(printf '%s\n' $rest | sort | tr '\n' ' ') got=$(printf '%s\n' $union | sort | tr '\n' ' ')
  if [ "$want" != "$got" ]; then
    SELF="$SELF; the $SK shards together are not the list: in no shard [$(printf '%s\n' $rest | grep -vxF "$(printf '%s\n' $union)" | tr '\n' ' ')], more than once or not in the list [$(printf '%s\n' $union | sort | uniq -d | tr '\n' ' ')$(printf '%s\n' $union | grep -vxF "$(printf '%s\n' $rest)" | tr '\n' ' ')]"
  fi
  run="s00 $(chunk_n "$SI" "$rest")"
fi
SELF=${SELF#; }

if [ $plan = 1 ]; then
  if [ "$SK" = 0 ]; then echo "whole list (about $(secs_of $list) s): $list"
  else
    i=1
    while [ $i -le "$SK" ]; do
      c="s00 $(chunk_n $i "$rest")"
      echo "shard $i/$SK rotate $ROT (about $(secs_of $c) s): $c"
      i=$((i + 1))
    done
  fi
  [ -z "$SELF" ] || { echo "e2e-faults: self-check FAILED: $SELF" >&2; exit 1; }
  exit 0
fi

# ---- run ------------------------------------------------------------------------------------------

# one work dir per shard (test/.<suite>-<server>, or T_WORK from test/all.sh, which is per suite
# file): the results TSV, the client config, the 200 MB upload file and the scenarios' work files
# all live under it (FAULT_WORK), so shards running at once on different servers share nothing
suite=${FAULT_SUITE:-e2e-faults}
[ "$SK" = 0 ] || suite=${FAULT_SUITE:-e2e-faults-${SI}of$SK}
t_init "$suite"
if [ -n "$SELF" ]; then
  echo "e2e-faults: self-check FAILED: $SELF" >&2
  fail "0 self-check of the scenario list: $SELF"
  t_done
fi
export FAULT_WORK=$E
export TANDO_SOAK=25 TANDO_WAIT=1    # the scenarios need a real soak (e4 crashes 20 s after going live)
export FAULT_SETUP_SOAK=${FAULT_SETUP_SOAK:-2}   # ... but not the deploys around them (lib-fault.sh)
if [ "$SK" = 0 ]; then log "$suite: the whole list, setup soak $FAULT_SETUP_SOAK s (about $(secs_of $run) s at 2): $run"
else log "$suite: shard $SI/$SK rotate $ROT, setup soak $FAULT_SETUP_SOAK s (about $(secs_of $run) s at 2): $run"; fi
export TANDO_TEST_DOCKER_ARGS="--memory 2g --cpus 1"
t_server_up --reset || exit 1
unset TANDO_TEST_DOCKER_ARGS
T_START=$(date +%s)
for id in $run; do
  f=$(file_of "$id")
  t0=$(date +%s)
  perl -e 'alarm shift; exec @ARGV' 900 bash "$f" > "$E/$id.log" 2>&1; rc=$?
  r=$(grep '^RESULT' "$E/$id.log" | tail -1 | cut -f2- | tr '\t' ' ')
  log "$id: exit $rc after $(( $(date +%s) - t0 )) s"
  case $rc in
    0) pass "$id ${f##*/} ($(( $(date +%s) - t0 )) s) $r";;
    # exit 2 (could not run) is a failure unless skips are accepted: a broken deploy must not hide here
    2) if [ "${TANDO_ALLOW_SKIP:-0}" = 1 ]; then skip "$id ${f##*/} could not run: $(tail -2 "$E/$id.log" | tr '\n' ' ')"
       else fail "$id ${f##*/} could not run (TANDO_ALLOW_SKIP=1 accepts that): $(tail -2 "$E/$id.log" | tr '\n' ' ')"; fi;;
    *) grep -E '^  (FAIL|LIE)' "$E/$id.log" | sed 's/^/  /' >&2; fail "$id ${f##*/} ${r:-exit $rc}";;
  esac
done
log "$suite: the scenarios took $(( $(date +%s) - T_START )) s"
t_done
