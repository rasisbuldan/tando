#!/bin/bash
# s1-pair.sh <op> <iterations> [app]: a deploy (laptop A) and <op> (laptop B) of the same app at
# once, random jitter on both sides. ops: rollback env restart stop-start domain backup restore job
# jobtimer watch recover rollback2 env2 domain2
# After each round: invariants, plus the op's own post-check (env keys present, domain present...).
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
OP=$1 IT=${2:-20} APP=${3:-pr}
race_init "s1-pair-$OP"
p=$(mkproj A "$APP" 1)
grep -q '^data' "$p/tando.conf" || printf 'data = data\njob.tick = hourly | echo tick\n' >> "$p/tando.conf"
pb=$(mkproj B "$APP" 1); cp "$p/tando.conf" "$pb/tando.conf"
(cd "$p" && rA up --force --yes > "$LOG/init.out" 2>&1) || { cat "$LOG/init.out"; exit 1; }
(cd "$p" && setv A "$APP" 2 && rA deploy --force --yes > /dev/null 2>&1)
fails=0
for i in $(seq 1 "$IT"); do
  v=$((i * 10)); setv A "$APP" "$v"; echo "$v" > "$p/marker"
  ( jitter 1500; cd "$p" && rA deploy --force --yes > "$LOG/$i.dep.out" 2>&1; echo $? > "$LOG/$i.dep.rc" ) &
  post=""
  case $OP in
    rollback) ( jitter 3000; rB rollback "$APP" > "$LOG/$i.op.out" 2>&1; echo $? > "$LOG/$i.op.rc" ) & ;;
    rollback2) ( jitter 500; rA rollback "$APP" > "$LOG/$i.op.out" 2>&1 ) &
               ( jitter 500; rB rollback "$APP" > "$LOG/$i.op2.out" 2>&1 ) & ;;
    env) ( jitter 3000; rB env set -a "$APP" "K$i=v$i" > "$LOG/$i.op.out" 2>&1; echo $? > "$LOG/$i.op.rc" ) &
         post="env K$i" ;;
    env2) ( jitter 1000; rA env set -a "$APP" "A$i=a$i" > "$LOG/$i.op.out" 2>&1; echo $? > "$LOG/$i.op.rc" ) &
          ( jitter 1000; rB env set -a "$APP" "B$i=b$i" > "$LOG/$i.op2.out" 2>&1; echo $? > "$LOG/$i.op2.rc" ) &
          post="env A$i B$i" ;;
    restart) ( jitter 3000; rB restart "$APP" > "$LOG/$i.op.out" 2>&1 ) & ;;
    stop-start) ( jitter 3000; rB stop "$APP" > "$LOG/$i.op.out" 2>&1; jitter 1000; rB start "$APP" >> "$LOG/$i.op.out" 2>&1 ) & ;;
    domain) ( jitter 3000; rB domain add "d$i.race.test" -a "$APP" --www off --force > "$LOG/$i.op.out" 2>&1; echo $? > "$LOG/$i.op.rc"
              [ $((i % 2)) = 0 ] && rB domain rm "d$((i - 1)).race.test" -a "$APP" >> "$LOG/$i.op.out" 2>&1 ) &
            post="domain d$i.race.test" ;;
    domain2) ( jitter 800; rA domain add "x$i.race.test" -a "$APP" --www off --force > "$LOG/$i.op.out" 2>&1; echo $? > "$LOG/$i.op.rc" ) &
             ( jitter 800; rB domain add "y$i.race.test" -a "$APP" --www off --force > "$LOG/$i.op2.out" 2>&1; echo $? > "$LOG/$i.op2.rc" ) &
             post="domain x$i.race.test y$i.race.test" ;;
    backup) ( jitter 3000; rB backup now "$APP" > "$LOG/$i.op.out" 2>&1 ) & ;;
    restore) ( jitter 3000; id=$(rB backup ls "$APP" 2> /dev/null | grep -oE '[0-9]{8}-[0-9]{6}-[a-z]+' | head -1)
               rB backup restore "$id" -a "$APP" --yes > "$LOG/$i.op.out" 2>&1 ) & ;;
    job) ( jitter 3000; rB jobs run tick -a "$APP" > "$LOG/$i.op.out" 2>&1 ) & ;;
    jobtimer) ( jitter 3000; sroot systemctl start "tando-${APP}_job-tick.service" > "$LOG/$i.op.out" 2>&1 ) & ;;
    watch) ( jitter 3000; sroot /opt/tando/bin/tando-watch run > "$LOG/$i.op.out" 2>&1 ) & ;;
    recover) ( for j in 1 2 3 4 5; do jitter 1500; sroot /opt/tando/bin/tando-agent recover "$APP"; done > "$LOG/$i.op.out" 2>&1
               sroot /opt/tando/bin/tando-agent recover-all >> "$LOG/$i.op.out" 2>&1 ) & ;;
    *) echo "unknown op $OP" >&2; exit 2;;
  esac
  wait
  settle "$APP" || echo "[$T_SUITE $i] settle timed out" >&2
  for f in "$LOG/$i".*.out; do
    if bad_output "$f" > /dev/null; then
      echo "[$T_SUITE $i] VIOL shell error in ${f##*/}: $(bad_output "$f" | head -2)" | tee -a "$LOG/violations" >&2
      RACE_V=$((RACE_V + 1))
    fi
  done
  case $post in
    env*) set -- $post; shift
          envs=$(srv "sudo cat /opt/tando/apps/$APP/env")
          for k; do
            rc=$(cat "$LOG/$i.op.rc" 2> /dev/null); [ "$k" = "B$i" ] && rc=$(cat "$LOG/$i.op2.rc" 2> /dev/null)
            if [ "$rc" = 0 ] && ! printf '%s\n' "$envs" | grep -q "^$k="; then
              echo "[$T_SUITE $i] VIOL env set $k reported ok but the key is not in env (lost update)" | tee -a "$LOG/violations" >&2
              RACE_V=$((RACE_V + 1))
            fi
            # the running process must have it too (when the set restarted it)
          done;;
    domain*) set -- $post; shift
             conf=$(srv "sudo cat /opt/tando/apps/$APP/app.conf /etc/caddy/tando/$APP.caddy")
             for d; do
               rc=$(cat "$LOG/$i.op.rc" 2> /dev/null); case $d in y*) rc=$(cat "$LOG/$i.op2.rc" 2> /dev/null);; esac
               n=$(printf '%s\n' "$conf" | grep -c "$d")
               if [ "$rc" = 0 ] && [ "$n" -lt 2 ]; then
                 echo "[$T_SUITE $i] VIOL domain add $d reported ok but it is in $n of app.conf/Caddy" | tee -a "$LOG/violations" >&2
                 RACE_V=$((RACE_V + 1))
               fi
             done;;
  esac
  # a stop that ended stopped is fine; start it again so the next round deploys a running app
  if [ "$OP" = stop-start ]; then rB start "$APP" > /dev/null 2>&1; settle "$APP"; fi
  inv "$i" "$APP" "*" || true
  echo "round $i: deploy rc=$(cat "$LOG/$i.dep.rc") v=$RACE_V" >&2
done
doctor_ok A
race_result "$T_SUITE" "$IT"
