#!/bin/bash
# s2-multi.sh <n apps> <iterations>: per round, n `up` of n NEW apps at once (port/uid allocation,
# Caddy reload storm, firewall.nft, host.conf), invariants; n deploys of the n apps at once,
# invariants; then n destroys at once, invariants (no leftover user, caddy file, nft rule).
# RACE_KEEP=1 keeps the apps of the last round.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
N=${1:-10} IT=${2:-5}
race_init "s2-multi-$N"
pick() { case $(( $1 % 3 )) in 0) echo A;; 1) echo B;; *) echo C;; esac; }
ups=0 upfail=0
for i in $(seq 1 "$IT"); do
  apps=""
  for k in $(seq 1 "$N"); do apps="$apps m$k"; mkproj "M$k" "m$k" "$i" > /dev/null; done
  # 1. n new apps at once
  for k in $(seq 1 "$N"); do
    ( jitter 500; cd "$E/proj/M$k/m$k" && rX "$(pick "$k")" up --force --yes > "$LOG/$i.up.$k.out" 2>&1; echo $? > "$LOG/$i.up.$k.rc" ) &
  done
  wait
  exp=""
  for k in $(seq 1 "$N"); do
    ups=$((ups + 1))
    if [ "$(cat "$LOG/$i.up.$k.rc")" != 0 ]; then
      upfail=$((upfail + 1))
      echo "[$T_SUITE $i] VIOL up of new app m$k failed: $(grep tando: "$LOG/$i.up.$k.out" | head -2 | tr '\n' ' ')" | tee -a "$LOG/violations" >&2
      RACE_V=$((RACE_V + 1))
    else exp="$exp m$k $i"; fi
    bad_output "$LOG/$i.up.$k.out" > /dev/null && { echo "[$T_SUITE $i] VIOL shell error up m$k" | tee -a "$LOG/violations" >&2; RACE_V=$((RACE_V + 1)); }
  done
  settle $apps
  inv "$i.up" $exp || true
  # 2. n deploys at once
  for k in $(seq 1 "$N"); do
    setv "M$k" "m$k" "$i.5"
    ( jitter 500; cd "$E/proj/M$k/m$k" && rX "$(pick "$k")" deploy --force --yes > "$LOG/$i.dep.$k.out" 2>&1; echo $? > "$LOG/$i.dep.$k.rc" ) &
  done
  wait
  exp=""
  for k in $(seq 1 "$N"); do
    [ "$(cat "$LOG/$i.dep.$k.rc")" = 0 ] && exp="$exp m$k $i.5" || {
      echo "[$T_SUITE $i] VIOL deploy m$k failed: $(grep tando: "$LOG/$i.dep.$k.out" | head -2 | tr '\n' ' ')" | tee -a "$LOG/violations" >&2; RACE_V=$((RACE_V + 1)); }
  done
  settle $apps
  inv "$i.deploy" $exp || true
  [ "$i" = "$IT" ] && [ "${RACE_KEEP:-0}" = 1 ] && break
  # 3. n destroys at once
  for k in $(seq 1 "$N"); do
    ( jitter 500; rX "$(pick "$k")" destroy "m$k" --purge --yes > "$LOG/$i.des.$k.out" 2>&1; echo $? > "$LOG/$i.des.$k.rc" ) &
  done
  wait
  for k in $(seq 1 "$N"); do
    [ "$(cat "$LOG/$i.des.$k.rc")" = 0 ] || {
      echo "[$T_SUITE $i] VIOL destroy m$k failed: $(grep -i 'tando\|warn' "$LOG/$i.des.$k.out" | head -2 | tr '\n' ' ')" | tee -a "$LOG/violations" >&2; RACE_V=$((RACE_V + 1)); }
  done
  inv "$i.destroy" || true
  rm -rf "${E:?}/proj/M"*   # fresh projects (no origin, no .tando) next round
  echo "round $i: v=$RACE_V" >&2
done
doctor_ok A
echo "ups=$ups failed=$upfail" >&2
race_result "$T_SUITE" "$IT"
