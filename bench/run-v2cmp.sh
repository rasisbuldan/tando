#!/bin/bash
# v2 comparison: tando v0.1.1 against the current tree on identical fresh servers, interleaved.
# Usage: bench/run-v2cmp.sh <tree-old> <tree-new> [rounds]     (each tree = a checkout holding bin/tando)
#   Per round: old then new. Server = tando-testvm:caddy-ubuntu (Caddy from Ubuntu, rsync, Node: like the
#   real VPS image), 2 GB / 1 CPU pinned, ext4 loop disk for /opt/tando. Names tando-hn-<label><round>,
#   ssh 3121/3122, http 9121/9122. Output: raw/v2cmp/<label>/round<r>/ (raw/ is not committed).
# Env: ONLY=old|new (one tree), PHASEX=1 (extra: nothing yet).
set -u
OLD=$(cd "${1:?old tree}" && pwd -P); NEW=$(cd "${2:?new tree}" && pwd -P); ROUNDS=${3:-3}
cd "$(dirname "$0")" && . ./lib.sh
IMG=tando-testvm:caddy-ubuntu
export NO_COLOR=1 COLUMNS=100 TERM=dumb
verified_wait() { local i; for i in $(seq 1 90); do
    tando releases --json 2>/dev/null | python3 -c 'import sys,json
d=json.load(sys.stdin); c=[r for r in d.get("releases",[]) if r.get("current")]
sys.exit(0 if c and c[0].get("status")=="verified" else 1)' && return 0; sleep 1; done; return 1; }
deploy_t() { local l=$1 t0 v=-; shift; t0=$(ms); "$@" 2>&1 | "$BENCH/tstamp.pl" > "$O/$l.tlog"; local rc=${PIPESTATUS[0]}
  if [ "$rc" = 0 ] && [ "${NOVERIFY:-0}" != 1 ]; then verified_wait && v=$(awk -v a="$t0" -v b="$(ms)" 'BEGIN{printf "%.1f", (b-a)/1000}'); fi
  awk -v l="$l" -v rc="$rc" -v v="$v" '/live (in|at)|is live/ && !lv {lv=$1} {last=$1} END{printf "%s\trc=%s\tlive_s=%s\treturn_s=%s\tverified_s=%s\n", l, rc, (lv?lv:"-"), last, v}' "$O/$l.tlog" | tee -a "$O/times.tsv" >&2
  return $rc; }
step() { local l=$1 t0 t1 rc; shift; t0=$(ms); "$@" >> "$O/steps.log" 2>&1; rc=$?; t1=$(ms)
  printf 'step\t%s\t%s\t%s\n' "$l" $((t1 - t0)) "$rc" | tee -a "$O/steps.tsv" >&2; return $rc; }
# measured_c: like measured, plus the client's own user+sys CPU seconds (python wrapper)
# mem_all: every cgroup with memory.current, depth <= 3 (tando's slices are not under system.slice)
mem_all() { docker exec "$1" bash -c '
  cd /sys/fs/cgroup; printf "TOTAL\t%s\t%s\n" "$(cat memory.current)" "$(awk "\$1==\"anon\"||\$1==\"shmem\"{s+=\$2} END{print s}" memory.stat)"
  find . -mindepth 1 -maxdepth 3 -name memory.current | sort | while read -r f; do d=${f%/memory.current}
    printf "%s\t%s\t%s\n" "${d#./}" "$(cat $f)" "$(awk "\$1==\"anon\"||\$1==\"shmem\"{s+=\$2} END{print s}" $d/memory.stat)"; done'; }
idle_snap() { local c=$1 f=$2 i a b; sleep "${SETTLE:-30}"; : > "$f"; a=$(cpu_usec "$c")
  for i in 1 2 3; do echo "# sample $i $(date +%T)" >> "$f"; mem_all "$c" >> "$f"; [ $i = 3 ] || sleep 10; done
  b=$(cpu_usec "$c"); echo "# idle cpu: $(((b - a) / 1000)) ms over ~20 s" >> "$f"; }
ctime() { python3 - "$@" <<'PY'
import sys,subprocess,resource,time
t=time.time(); r=subprocess.call(sys.argv[1:]); u=resource.getrusage(resource.RUSAGE_CHILDREN)
sys.stderr.write("CLIENT wall=%.2f user=%.2f sys=%.2f maxrss_kb=%d\n"%(time.time()-t,u.ru_utime,u.ru_stime,u.ru_maxrss//1024)); sys.exit(r)
PY
}
run_tree() { # label tree round sshport httpport
  local L=$1 T=$2 r=$3 SP=$4 HP=$5 C=tando-hn-$1$3
  O=$RAW/v2cmp/$L/round$r; rm -rf "$O"; mkdir -p "$O"; : > "$O/steps.tsv"
  local W=$BENCH/.cache/hn-$L; rm -rf "$W" "$BENCH/.rc-$L"; mkdir -p "$W/bench"
  export TANDO_CONFIG_DIR=$BENCH/.rc-$L PATH=$T/bin:$PATH
  local URL=http://127.0.0.1:$HP/api/version H=bench.localhost
  echo "tree $T $(cat "$T/VERSION") load $(uptime | sed 's/.*averages*: //')" > "$O/notes.txt"
  log "[$L r$r] start $C"
  CPUSET=${CPUSET:-3} start_server $C $IMG $SP $HP || return 1
  disk_setup $C /opt/tando
  docker exec $C systemctl restart caddy   # (Caddy runs in its own mount namespace: it must see /opt/tando on the loop disk)
  (cd app && tar -cf - --exclude=./node_modules --exclude=./.next --exclude=./dist --exclude=./.tando --exclude=./.kamal \
    --exclude=./config --exclude=./Dockerfile .) | (cd "$W/bench" && tar -xf -)
  cp "$BENCH/tando-next-stage.sh" "$W/"; export BENCH_CACHE=$BENCH/.cache
  cd "$W/bench"; set_version . v1
  c0=$(cpu_usec $C)
  step 1-host-add tando host add bench$L vmadmin@127.0.0.1 --port $SP --key "$KEY" --insecure-test
  step 2-host-setup tando host setup bench$L public_port=$HP domain_tls=internal
  echo "host_setup_cpu_ms $(( ($(cpu_usec $C) - c0) / 1000 ))" >> "$O/notes.txt"
  peak_start $C "$O/cold.peak"; c0=$(cpu_usec $C); x0=$(net_rx $C)
  echo "load $(uptime | sed 's/.*averages*: //')" >> "$O/notes.txt"
  NOVERIFY=1 deploy_t cold ctime tando up --yes
  peak_stop $C; printf 'cold\tcpu_ms=%s\trx_bytes=%s\tpeak_sum=%s\n' $(( ($(cpu_usec $C) - c0) / 1000 )) $(( $(net_rx $C) - x0 )) \
    "$(awk '$1=="SUM"{print $2}' "$O/cold.peak")" >> "$O/measured.tsv"
  echo "served after cold: $(curl -s -m 5 -H "Host: $H" $URL)" >> "$O/notes.txt"
  tando history --json > "$O/history-cold.json" 2>&1
  SETTLE=35 idle_snap $C "$O/mem-1app.tsv"; verified_wait
  docker exec $C ps -eo pid,rss,comm,args --sort=-rss > "$O/ps-1app.txt" 2>&1
  for i in 1 2; do set_version . "q$i"; echo "load $(uptime | sed 's/.*averages*: //')" >> "$O/notes.txt"
    if [ $i = 1 ]; then measured $C "$O" "warm-quiet-$i" deploy_t "warm-quiet-$i" ctime tando deploy
    else NOVERIFY=1 measured $C "$O" "warm-quiet-$i" deploy_t "warm-quiet-$i" ctime tando deploy; verified_wait; fi
    echo "served after q$i: $(curl -s -m 5 -H "Host: $H" $URL)" >> "$O/notes.txt"; done
  tando history --json > "$O/history-warm.json" 2>&1
  set_version . l1; echo "load $(uptime | sed 's/.*averages*: //')" >> "$O/notes.txt"
  NOVERIFY=1 with_loop "$O" warm-loop-1 "$URL" "$H" deploy_t warm-loop-1 ctime tando deploy; verified_wait
  for cmd in "ls" "status" "doctor" "deploy --dry-run"; do n=${cmd// /-}
    for i in 1 2 3; do measured $C "$O" "cmd-$n-$i" ctime tando $cmd; done; done
  # disk now: 6+ deploys done
  docker exec $C bash -c 'd=/opt/tando/apps/bench; echo "releases: $(ls $d/releases | wc -l)"; ls $d
    for x in $d/* ; do [ -e "$x" ] && printf "%s\t%s\n" "${x#$d/}" "$(du -sb "$x" | cut -f1)"; done
    for x in $d/releases/*; do printf "rel %s apparent %s du %s\n" "${x##*/}" "$(du -sb --apparent-size "$x" | cut -f1)" "$(du -sb "$x" | cut -f1)"; done
    printf "assets_dir\t%s\n" "$(du -sb $d/assets 2>/dev/null | cut -f1)"
    printf "opt_tando\t%s\n" "$(du -sb /opt/tando | cut -f1)"; ls /opt/tando; ls -la /opt/tando/backups 2>&1 | head' > "$O/disk.txt" 2>&1
  # logs per 100 requests: journal + caddy logs + app log
  docker exec $C bash -c 'journalctl --disk-usage; du -sb /var/log/caddy /var/log/journal /run/log/journal /var/log 2>/dev/null' > "$O/log-before.txt" 2>&1
  for i in $(seq 1 100); do curl -s -o /dev/null -H "Host: $H" $URL; done; sleep 2
  docker exec $C bash -c 'journalctl --disk-usage; du -sb /var/log/caddy /var/log/journal /run/log/journal /var/log 2>/dev/null; journalctl --since "-1min" --no-pager | wc -c' > "$O/log-after.txt" 2>&1
  # 3 apps (copies built from the first), idle memory, and tando-watch accounting in the window
  t0=$(docker exec $C date -u '+%Y-%m-%d %H:%M:%S')
  for i in 2 3; do d=$W/copy$i; rm -rf "$d"; mkdir -p "$d"
    (cd "$W/bench" && tar -cf - --exclude=.next/cache package.json next.config.mjs .next public dist) | (cd "$d" && tar -xf -)
    ln -s "$W/bench/node_modules" "$d/node_modules"
    sed -e "s/^app = .*/app = bench$i/" -e '/^build = /d' "$W/bench/tando.conf" > "$d/tando.conf"
    (cd "$d" && tando up --yes > "$O/up-copy$i.log" 2>&1) || log "copy $i failed"; done
  SETTLE=25 idle_snap $C "$O/mem-3apps.tsv"
  docker exec $C ps -eo pid,rss,comm,args --sort=-rss > "$O/ps-3apps.txt" 2>&1
  docker exec $C journalctl -u tando-watch.service --since "$t0 UTC" --no-pager -o short-precise > "$O/watch-journal.txt" 2>&1
  docker exec $C systemctl list-timers --all --no-pager > "$O/timers.txt" 2>&1
  echo "load at end $(uptime | sed 's/.*averages*: //')" >> "$O/notes.txt"
  cd "$BENCH"; stop_server $C
}
for r in $(seq 1 "$ROUNDS"); do
  [ "${ONLY:-}" = new ] || run_tree old "$OLD" $r 3121 9121
  [ "${ONLY:-}" = old ] || run_tree new "$NEW" $r 3122 9122
done
