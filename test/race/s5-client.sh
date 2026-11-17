#!/bin/bash
# s5-client.sh <mode> <iterations>: client-side shared state on one laptop.
#   samedir: two deploys at once from ONE project dir with ONE config dir (shared .tando/stage,
#            ControlMaster, last-host); the project changes a bulky file between rounds
#   firstcm: a fresh config dir each round (copy of laptop A without its cm/ sockets); 6 commands
#            at once on it (status, ls, releases, history, env ls, deploy) race to start the
#            ControlMaster; none may fail for a reason other than a lease refusal
# Checks: client errors (rsync errors, ssh mux errors, shell errors), invariants, mixed release.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
MODE=$1 IT=${2:-20} APP=${3:-cs}
race_init "s5-client-$MODE"
pa=$(mkproj A "$APP" 1)
(cd "$pa" && rA up --force --yes > "$LOG/init.out" 2>&1) || { cat "$LOG/init.out"; exit 1; }
for i in $(seq 1 "$IT"); do
  head -c $(( (RANDOM % 4 + 1) * 700000 )) /dev/urandom > "$pa/blob.bin"
  setv A "$APP" "$i"; echo "$i" > "$pa/marker"
  case $MODE in
    samedir)
      for k in 1 2; do ( jitter 300; cd "$pa" && rA deploy --force --yes > "$LOG/$i.$k.out" 2>&1; echo $? > "$LOG/$i.$k.rc" ) & done
      # the project changes while they stage (an editor saving): a third writer
      ( jitter 400; head -c 900000 /dev/urandom > "$pa/blob.bin" ) &
      wait;;
    firstcm)
      C=$E/cfgF$i; rm -rf "$C"; mkdir -p "$C"; cp -R "$E/cfgA/hosts" "$C/"; cp "$E/cfgA/known_hosts" "$C/" 2> /dev/null
      k=0
      for cmd in "status $APP" "ls" "releases $APP" "history $APP" "env ls $APP" "--force --yes deploy"; do
        k=$((k + 1))
        ( cd "$pa" && TANDO_CONFIG_DIR=$C "$R" $cmd > "$LOG/$i.$k.out" 2>&1; echo $? > "$LOG/$i.$k.rc" ) &
      done
      wait
      # close this round's master
      for s in "$C"/cm/* $(cat "$C/ctl-dir" 2> /dev/null)/*; do [ -S "$s" ] && ssh -o ControlPath="$s" -O exit x > /dev/null 2>&1; done
      rm -rf "$C";;
  esac
  settle "$APP"
  for f in "$LOG/$i".*.out; do
    rc=$(cat "${f%.out}.rc")
    if bad_output "$f" > /dev/null || grep -qiE 'rsync error|rsync:|mux_client|ControlSocket|Control socket|broken pipe|connection closed' "$f"; then
      echo "[$T_SUITE $i] VIOL ${f##*/} rc=$rc: $( (bad_output "$f"; grep -iE 'rsync|mux|control|pipe|closed' "$f") | head -2 | tr '\n' ' ')" | tee -a "$LOG/violations" >&2
      RACE_V=$((RACE_V + 1))
    elif [ "$rc" != 0 ] && ! grep -qE 'another deploy|another tando deploy is running in this directory|try again|busy' "$f"; then
      echo "[$T_SUITE $i] VIOL ${f##*/} failed rc=$rc: $(grep -v '│' "$f" | head -2 | tr '\n' ' ')" | tee -a "$LOG/violations" >&2
      RACE_V=$((RACE_V + 1))
    fi
  done
  set -- $(srv "sudo cat /opt/tando/apps/$APP/current/VERSION /opt/tando/apps/$APP/current/marker" | tr '\n' ' ')
  [ "${1:-x}" = "${2:-y}" ] || { echo "[$T_SUITE $i] VIOL mixed release live: VERSION=${1:-} marker=${2:-}" | tee -a "$LOG/violations" >&2; RACE_V=$((RACE_V + 1)); }
  inv "$i" "$APP" "*" || true
  echo "round $i: v=$RACE_V" >&2
done
race_result "$T_SUITE" "$IT"
