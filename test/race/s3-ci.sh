#!/bin/bash
# s3-ci.sh <mode> <iterations>: admin key vs CI deploy key on one app (app "cia").
#   owner-ci:  an owner deploy (laptop A) and a CI-key deploy at once
#   ci-ci:     two CI runs with the same key at once
#   revoke:    a CI deploy while the owner revokes (odd rounds) / rotates (even rounds) the key
#   unlock:    a CI deploy while the owner runs `tando unlock`
# Each deploy ships VERSION and a marker naming the same version: a live release whose two
# differ is a mixed upload. Invariants after every round.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
MODE=$1 IT=${2:-20} APP=${3:-cia}
race_init "s3-ci-$MODE"
pa=$(mkproj A "$APP" 1); pc=$(mkproj CI "$APP" 1); echo 1 > "$pa/marker"
secret() { awk -v n="--- $2" '$0 == n { on = 1; next } /^--- / { on = 0 } on' "$1"; }
(cd "$pa" && rA up --force --yes > "$LOG/init.out" 2>&1) || { cat "$LOG/init.out"; exit 1; }
newkey() {
  (cd "$pa" && rA ci setup > "$E/ci.setup" 2> "$LOG/ci.setup.err") || { cat "$LOG/ci.setup.err" >&2; return 1; }
  secret "$E/ci.setup" TANDO_DEPLOY_KEY > "$E/ci.key"; chmod 600 "$E/ci.key"
}
[ -s "$E/ci.key" ] || newkey || exit 1
ci() { # deploy as CI from $pc (own config dir), output to $1
  (
    export TANDO_DEPLOY_KEY=$E/ci.key TANDO_HOST=$(secret "$E/ci.setup" TANDO_HOST)
    export TANDO_PORT=$(secret "$E/ci.setup" TANDO_PORT) TANDO_KNOWN_HOSTS=$(secret "$E/ci.setup" TANDO_KNOWN_HOSTS)
    export TANDO_CONFIG_DIR=$E/cfg-ci$2 CI=true
    cd "${3:-$pc}" && "$R" deploy --force --yes
  ) > "$1" 2>&1
}
pc2=$(mkproj CI2 "$APP" 1)
for i in $(seq 1 "$IT"); do
  head -c 1500000 /dev/urandom > "$pa/blob.bin"; head -c 2500000 /dev/urandom > "$pc/blob.bin"
  setv A "$APP" "$i.1"; echo "$i.1" > "$pa/marker"; setv CI "$APP" "$i.2"; echo "$i.2" > "$pc/marker"
  setv CI2 "$APP" "$i.3"; echo "$i.3" > "$pc2/marker"
  case $MODE in
    owner-ci) ( jitter 800; cd "$pa" && rA deploy --force --yes > "$LOG/$i.a.out" 2>&1; echo $? > "$LOG/$i.a.rc" ) &
              ( jitter 800; ci "$LOG/$i.b.out" 1; echo $? > "$LOG/$i.b.rc" ) & ;;
    ci-ci)    ( jitter 800; ci "$LOG/$i.a.out" 1; echo $? > "$LOG/$i.a.rc" ) &
              ( jitter 800; ci "$LOG/$i.b.out" 2 "$pc2"; echo $? > "$LOG/$i.b.rc" ) & ;;
    revoke)   ( ci "$LOG/$i.a.out" 1; echo $? > "$LOG/$i.a.rc" ) &
              ( jitter 2000; if [ $((i % 2)) = 1 ]; then (cd "$pa" && rA ci revoke all) else (cd "$pa" && rA ci rotate); fi > "$LOG/$i.b.out" 2>&1; echo $? > "$LOG/$i.b.rc" ) & ;;
    unlock)   ( ci "$LOG/$i.a.out" 1; echo $? > "$LOG/$i.a.rc" ) &
              ( jitter 2000; rB unlock "$APP" > "$LOG/$i.b.out" 2>&1; echo $? > "$LOG/$i.b.rc" ) & ;;
  esac
  wait
  settle "$APP"
  for s in a b; do
    bad_output "$LOG/$i.$s.out" > /dev/null && { echo "[$T_SUITE $i] VIOL shell error in $s: $(bad_output "$LOG/$i.$s.out" | head -1)" | tee -a "$LOG/violations" >&2; RACE_V=$((RACE_V + 1)); }
  done
  set -- $(srv "sudo cat /opt/tando/apps/$APP/current/VERSION /opt/tando/apps/$APP/current/marker" | tr '\n' ' ')
  [ "${1:-x}" = "${2:-y}" ] || { echo "[$T_SUITE $i] VIOL mixed release live: VERSION=${1:-} marker=${2:-}" | tee -a "$LOG/violations" >&2; RACE_V=$((RACE_V + 1)); }
  ok=""
  [ "$(cat "$LOG/$i.a.rc")" = 0 ] && case $MODE in owner-ci) ok="$ok $i.1";; *) ok="$ok $i.2";; esac
  [ "$(cat "$LOG/$i.b.rc")" = 0 ] && case $MODE in owner-ci) ok="$ok $i.2";; ci-ci) ok="$ok $i.3";; esac
  # a revoked key's deploy may have finished before the revoke
  exp=${ok# }; [ -n "$exp" ] || exp='*'
  inv "$i" "$APP" "$exp" || true
  echo "round $i: a=$(cat "$LOG/$i.a.rc") b=$(cat "$LOG/$i.b.rc") ok=[$ok] v=$RACE_V" >&2
  if [ "$MODE" = revoke ]; then newkey > /dev/null 2>&1 || true; fi
done
doctor_ok A
race_result "$T_SUITE" "$IT"
