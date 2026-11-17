#!/bin/bash
# s1-destroy.sh <mode> <iterations>
#   deploy:  a deploy (A) and a destroy (B) of the same app at once
#   up:      destroy (B) and `up` of the same name (A) at once, the app exists before
#   twoup:   two `up` of the same NEW app at once (A and B, two project dirs)
# After each round: invariants (no half app: app dir without app.conf, user without app, caddy file
# without app, nft rule of a gone uid, a lingering activation unit); then the app is removed.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
MODE=$1 IT=${2:-20} APP=${3:-ds}
race_init "s1-destroy-$MODE"
pa=$(mkproj A "$APP" 1); pb=$(mkproj B "$APP" 1)
for i in $(seq 1 "$IT"); do
  setv A "$APP" "$i"; setv B "$APP" "$i.2"
  rm -rf "${pa:?}/.tando" "${pb:?}/.tando"
  if [ "$MODE" != twoup ]; then
    (cd "$pa" && rA up --force --yes > "$LOG/$i.pre.out" 2>&1) || echo "[$T_SUITE $i] pre-up failed" >&2
  fi
  case $MODE in
    deploy) setv A "$APP" "$i.1"
            ( jitter 2500; cd "$pa" && rA deploy --force --yes > "$LOG/$i.a.out" 2>&1; echo $? > "$LOG/$i.a.rc" ) &
            ( jitter 2500; rB destroy "$APP" --purge --yes > "$LOG/$i.b.out" 2>&1; echo $? > "$LOG/$i.b.rc" ) & ;;
    up)     ( jitter 1500; cd "$pa" && rA up --force --yes > "$LOG/$i.a.out" 2>&1; echo $? > "$LOG/$i.a.rc" ) &
            ( jitter 1500; rB destroy "$APP" --purge --yes > "$LOG/$i.b.out" 2>&1; echo $? > "$LOG/$i.b.rc" ) & ;;
    twoup)  ( jitter 300; cd "$pa" && rA up --force --yes > "$LOG/$i.a.out" 2>&1; echo $? > "$LOG/$i.a.rc" ) &
            ( jitter 300; cd "$pb" && rB up --force --yes > "$LOG/$i.b.out" 2>&1; echo $? > "$LOG/$i.b.rc" ) & ;;
  esac
  wait
  sleep 1; settle "$APP"
  for s in a b; do
    bad_output "$LOG/$i.$s.out" > /dev/null && { echo "[$T_SUITE $i] VIOL shell error in $s: $(bad_output "$LOG/$i.$s.out" | head -1)" | tee -a "$LOG/violations" >&2; RACE_V=$((RACE_V + 1)); }
  done
  ex=$(srv "sudo test -f /opt/tando/apps/$APP/app.conf && echo yes")
  if [ "$ex" = yes ]; then
    # the app survived: it must be whole and serve one of the two versions or the round's start
    inv "$i" "$APP" "$i $i.1 $i.2" || true
    if [ "$MODE" = twoup ] && [ "$(cat "$LOG/$i.a.rc")" = 0 ] && [ "$(cat "$LOG/$i.b.rc")" = 0 ]; then
      : # both may succeed: the second is a deploy of the app the first created
    fi
  else
    inv "$i" || true
    # the deploy/up must not claim success for an app that is gone
    if [ "$(cat "$LOG/$i.a.rc" 2> /dev/null)" = 0 ] && [ "$MODE" != twoup ]; then
      bo=$(cat "$LOG/$i.b.rc");
      echo "[$T_SUITE $i] note: A reported success, destroy rc=$bo, app gone" >> "$LOG/notes"
    fi
  fi
  echo "round $i: a=$(cat "$LOG/$i.a.rc") b=$(cat "$LOG/$i.b.rc") exists=${ex:-no} v=$RACE_V" >&2
  rB destroy "$APP" --purge --yes > "$LOG/$i.clean.out" 2>&1
  srv "sudo test -e /opt/tando/apps/$APP" && {
    echo "[$T_SUITE $i] VIOL after a clean destroy /opt/tando/apps/$APP still exists: $(cat "$LOG/$i.clean.out" | tail -2 | tr '\n' ' ')" | tee -a "$LOG/violations" >&2
    RACE_V=$((RACE_V + 1))
    srv "sudo rm -rf /opt/tando/apps/$APP"; }
done
doctor_ok A
race_result "$T_SUITE" "$IT"
