#!/bin/bash
# s2-setup.sh <mode> <iterations>
#   during: `host setup` (laptop B) while 3 apps deploy at once (laptop A/C)
#   twice:  two `host setup` at once (laptops A and B), apps idle
#   runtime:two first apps of a recipe whose runtime is missing (python) `up` at once; needs apt
#           on the server (network); run once on a fresh server
# Invariants after each round; both setups must succeed (or one say it is busy, cleanly).
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
MODE=$1 IT=${2:-10}
race_init "s2-setup-$MODE"
apps="h1 h2 h3"
for a in $apps; do p=$(mkproj A "$a" 1); [ -f "$LOG/init.$a" ] || { (cd "$p" && rA up --force --yes > "$LOG/init.$a" 2>&1) || cat "$LOG/init.$a"; }; done
for i in $(seq 1 "$IT"); do
  case $MODE in
    during)
      for a in $apps; do setv A "$a" "$i"; ( jitter 1500; cd "$E/proj/A/$a" && rA deploy --force --yes > "$LOG/$i.$a.out" 2>&1; echo $? > "$LOG/$i.$a.rc" ) & done
      ( jitter 2000; rB host setup test public_port="$HP" domain_tls=off > "$LOG/$i.setup.out" 2>&1; echo $? > "$LOG/$i.setup.rc" ) &
      wait;;
    twice)
      ( jitter 300; rA host setup test public_port="$HP" domain_tls=off > "$LOG/$i.setup.out" 2>&1; echo $? > "$LOG/$i.setup.rc" ) &
      ( jitter 300; rB host setup test public_port="$HP" domain_tls=off > "$LOG/$i.setup2.out" 2>&1; echo $? > "$LOG/$i.setup2.rc" ) &
      wait;;
    runtime)
      for k in 1 2; do
        p=$(mkproj P$k py$k); rm -rf "$p"; mkdir -p "$p"; cp -R "$SNAP/examples/python/." "$p/"
        sed -i '' "s/^app = .*/app = py$k/" "$p/tando.conf"; echo "host = test" >> "$p/tando.conf"
        ( cd "$p" && rX "$(echo A B | cut -d' ' -f$k)" up --force --yes > "$LOG/$i.py$k.out" 2>&1; echo $? > "$LOG/$i.py$k.rc" ) &
      done
      wait;;
  esac
  settle $apps
  for f in "$LOG/$i".*.out; do
    rc=$(cat "${f%.out}.rc")
    bad_output "$f" > /dev/null && { echo "[$T_SUITE $i] VIOL shell error ${f##*/}: $(bad_output "$f" | head -1)" | tee -a "$LOG/violations" >&2; RACE_V=$((RACE_V + 1)); }
    [ "$rc" = 0 ] || grep -q 'another deploy\|busy\|try again' "$f" || {
      echo "[$T_SUITE $i] VIOL ${f##*/} failed rc=$rc: $(grep -v '^│ ✓' "$f" | grep -iE 'tando|fail|✗|error|warn' | head -3 | tr '\n' ' ')" | tee -a "$LOG/violations" >&2; RACE_V=$((RACE_V + 1)); }
  done
  exp=""; for a in $apps; do exp="$exp $a any"; done
  inv "$i" $exp || true
  echo "round $i: v=$RACE_V" >&2
done
doctor_ok A
race_result "$T_SUITE" "$IT"
