#!/bin/bash
# s1-deploy-deploy.sh <n parallel> <iterations> [same|diff] [app]
# N deploys of one app at once from N project dirs on laptops A/B/C (round robin), random jitter.
# After each round: invariants; served version is one of the versions whose deploy reported live;
# history.tsv grew by exactly the number of releases the clients were given.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
N=${1:-2} IT=${2:-20} MODE=${3:-diff} APP=${4:-dd}
race_init "s1-deploy-deploy-$N-$MODE"
pick() { case $(( $1 % 3 )) in 0) echo A;; 1) echo B;; *) echo C;; esac; }
for k in $(seq 1 "$N"); do mkproj "$(pick "$k")$k" "$APP" 1 > /dev/null; done
p=$(mkproj A1 "$APP"); (cd "$p" && rA up --force --yes > "$LOG/init.out" 2>&1) || { cat "$LOG/init.out"; exit 1; }
for i in $(seq 1 "$IT"); do
  h0=$(srv "sudo cat /opt/tando/apps/$APP/history.tsv" | wc -l | tr -d " ")
  for k in $(seq 1 "$N"); do
    v=$((i * 100 + k)); [ "$MODE" = same ] && v=$((i * 100))
    c=$(pick "$k")
    setv "$c$k" "$APP" "$v"
    # a marker naming the same version, and a bulky file, so a mixed upload shows and rsync takes a while
    echo "$v" > "$E/proj/$c$k/$APP/marker"
    [ "$MODE" = diff ] && head -c $(( (RANDOM % 3 + 1) * 1000000 )) /dev/urandom > "$E/proj/$c$k/$APP/blob.bin"
    ( jitter 400; cd "$E/proj/$c$k/$APP" && rX "$c" deploy --force --yes > "$LOG/$i.$k.out" 2>&1; echo $? > "$LOG/$i.$k.rc" ) &
  done
  wait
  settle "$APP" || echo "[$T_SUITE $i] settle timed out" >&2
  ok=""; rel=0
  for k in $(seq 1 "$N"); do
    v=$((i * 100 + k)); [ "$MODE" = same ] && v=$((i * 100))
    [ "$(cat "$LOG/$i.$k.rc")" = 0 ] && ok="$ok $v"
    grep -q '│ *release 2' "$LOG/$i.$k.out" && rel=$((rel + 1))
    if bad_output "$LOG/$i.$k.out" > /dev/null; then
      echo "[$T_SUITE $i] VIOL client $k shell error: $(bad_output "$LOG/$i.$k.out" | head -2)" | tee -a "$LOG/violations" >&2
      RACE_V=$((RACE_V + 1))
    fi
  done
  h1=$(srv "sudo cat /opt/tando/apps/$APP/history.tsv" | wc -l | tr -d " ")
  if [ $((h1 - h0)) != "$rel" ]; then
    echo "[$T_SUITE $i] VIOL history grew by $((h1 - h0)), $rel releases were activated" | tee -a "$LOG/violations" >&2
    RACE_V=$((RACE_V + 1))
  fi
  cm=$(srv "sudo cat /opt/tando/apps/$APP/current/VERSION /opt/tando/apps/$APP/current/marker" | tr '\n' ' ')
  set -- $cm
  if [ "${1:-x}" != "${2:-y}" ]; then
    echo "[$T_SUITE $i] VIOL mixed release: VERSION=${1:-} marker=${2:-}" | tee -a "$LOG/violations" >&2
    RACE_V=$((RACE_V + 1))
  fi
  [ -n "$ok" ] || ok="*"
  inv "$i" "$APP" "${ok# }"
  echo "round $i: ok=[$ok] releases=$rel history+$((h1 - h0)) v=$RACE_V" >&2
done
doctor_ok A
race_result "$T_SUITE" "$IT"
