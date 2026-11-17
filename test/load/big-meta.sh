#!/bin/bash
# Big metadata: history.tsv with N lines, M env vars, J jobs; times history, status, ls, one top
# frame, env ls, jobs (3 runs each). usage: test/load/big-meta.sh <app> <outdir> <what>
#   what: history <lines> | env <count> | jobs <count> <app-dir>
set -u
. "$(dirname "$0")/lib.sh"
. "$LROOT/test/lib.sh"
app=$1 out=$2 what=$3; shift 3
mkdir -p "$out"
tm() { local t0 t1; t0=$(ms); "$@" > "$out/last.out" 2>&1; local rc=$?; t1=$(ms); echo "$((t1 - t0))"; }
times3() { local label=$1 a b c; shift; a=$(tm "$@"); b=$(tm "$@"); c=$(tm "$@")
  printf '%s\t%s\t%s\tms=%s,%s,%s\tload1=%s\n' "$(date +%T)" "$what" "$label" "$a" "$b" "$c" "$(load1)" | tee -a "$out/meta.tsv"; }
case $what in
  history)
    n=$1
    sx "f=/opt/tando/apps/$app/history.tsv; l=\$(tail -1 \$f); t=\$(cut -f1 <<< \"\$l\");
        for i in \$(seq 1 $n); do printf '%s\t20250101-%06d\tdeploy\tok\t3.5\t0.1\t0.4\t0.1\t0.6\t0.1\t2.1\t-\n' \$((t - $n * 60 + i * 60)) \$i; done > /tmp/h; cat \$f >> /tmp/h; cat /tmp/h > \$f; wc -l < \$f"
    times3 "history" "$R" history -a "$app"; times3 status "$R" status -a "$app"; times3 ls "$R" ls
    t_pty 160 50 8 "$R" top > "$out/top-history.pty" 2>&1
    printf '%s\thistory\ttop frame within 8 s: %s bytes, app row %s\n' "$(date +%T)" "$(wc -c < "$out/top-history.pty" | tr -d ' ')" "$(grep -c "$app" "$out/top-history.pty")" | tee -a "$out/meta.tsv"
    times3 agent-history-srv sx "/opt/tando/bin/tando-agent history $app >/dev/null"
    times3 agent-status-srv sx "/opt/tando/bin/tando-agent status $app >/dev/null";;
  env)
    n=$1 args=""
    for i in $(seq 1 "$n"); do args="$args K$i=value_$i"; done
    t0=$(ms); "$R" env set -a "$app" $args > "$out/envset.out" 2>&1; rc=$?; t1=$(ms)
    printf '%s\tenv\tset %s vars in one call\tms=%s rc=%s\n' "$(date +%T)" "$n" "$((t1 - t0))" "$rc" | tee -a "$out/meta.tsv"
    times3 "env ls" "$R" env ls -a "$app"; times3 status "$R" status -a "$app"
    times3 restart "$R" restart -a "$app"
    printf 'env count on server: %s\n' "$(sx "wc -l < /opt/tando/apps/$app/env")" | tee -a "$out/meta.tsv";;
  jobs)
    n=$1 dir=$2
    cp "$dir/tando.conf" "$dir/tando.conf.orig"
    for i in $(seq 1 "$n"); do echo "job.j$i = hourly | true"; done >> "$dir/tando.conf"
    t0=$(ms); (cd "$dir" && "$R" up > "$out/jobs-up.out" 2>&1); rc=$?; t1=$(ms)
    printf '%s\tjobs\tup with %s jobs\tms=%s rc=%s\n' "$(date +%T)" "$n" "$((t1 - t0))" "$rc" | tee -a "$out/meta.tsv"
    times3 jobs "$R" jobs -a "$app"; times3 status "$R" status -a "$app"; times3 ls "$R" ls
    printf 'timers on server: %s\n' "$(sx "systemctl list-timers --all --no-legend | grep -c tando-$app-job")" | tee -a "$out/meta.tsv";;
esac
