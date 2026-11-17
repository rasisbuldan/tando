#!/bin/bash
# test/e2e-faults.sh: the fault-injection scenarios of docs/FAULT-REVIEW.md (test/faults/*.sh) on
# a 2 GB, 1-CPU test server. Each scenario exits 0 when tando held (served the right release, told
# the truth, and the next deploy worked untouched): a PASS here. By default the 27 scenarios that
# failed in the review plus the baseline, and m1-m6 (soak rollback alert, deploy behind a soak,
# unknown hosts, static pages, env before up/during a soak and job-run, failure hints), n1-n5 (jobs follow
# the verified release, env revert, same-user lease, domain lost update, idempotent re-runs, liveness
# restart, load limits); --all runs
# every scenario (about an hour: the restarts and power losses are slow); --only a1,b3 runs those.
# bash 3.2 compatible.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-faults
all=0 only=""
case ${1:-} in --all) all=1;; --only) only=$(printf '%s' "${2:-}" | tr ',' ' ');; esac
export FAULT_WORK=$E
export TANDO_SOAK=25 TANDO_WAIT=1    # the scenarios need a real soak (e4 crashes 20 s after going live)
export TANDO_TEST_DOCKER_ARGS="--memory 2g --cpus 1"
t_server_up --reset || exit 1
unset TANDO_TEST_DOCKER_ARGS
list="s00 a1 a2 a3 a4 a5 b2 b3 d1 d2 d3 d4 e4 e5 e10 f3 g1 g3 g5 g6 g7 g8 g9 g10 h2 h5 j1 l1 m1 m2 m3 m4 m5 m6 n1 n2 n3 n4 n5 n6 n7"
[ -n "$only" ] && list=$only
if [ $all = 1 ]; then
  list=$(cd "$ROOT/test/faults" && ls [a-z]*[0-9]-*.sh | sed 's/-.*//' | sort -t. -k1,1 | tr '\n' ' ')
fi
for id in $list; do
  f=$(ls "$ROOT/test/faults/$id"-*.sh 2> /dev/null | head -1)
  [ -n "$f" ] || { echo "SKIP $id no such scenario"; continue; }
  t0=$(date +%s)
  perl -e 'alarm shift; exec @ARGV' 900 bash "$f" > "$E/$id.log" 2>&1; rc=$?
  r=$(grep '^RESULT' "$E/$id.log" | tail -1 | cut -f2- | tr '\t' ' ')
  case $rc in
    0) pass "$id ${f##*/} ($(( $(date +%s) - t0 )) s) $r";;
    # exit 2 (could not run) is a failure unless skips are accepted: a broken deploy must not hide here
    2) if [ "${TANDO_ALLOW_SKIP:-0}" = 1 ]; then skip "$id ${f##*/} could not run: $(tail -2 "$E/$id.log" | tr '\n' ' ')"
       else fail "$id ${f##*/} could not run (TANDO_ALLOW_SKIP=1 accepts that): $(tail -2 "$E/$id.log" | tr '\n' ' ')"; fi;;
    *) grep -E '^  (FAIL|LIE)' "$E/$id.log" | sed 's/^/  /' >&2; fail "$id ${f##*/} ${r:-exit $rc}";;
  esac
done
t_done
