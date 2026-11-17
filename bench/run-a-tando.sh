#!/bin/bash
# Approach A: tando, current CLI, from a FROZEN SNAPSHOT of the repo (never the live tree).
# Usage: bench/run-a-tando.sh <snapshot-dir> [rounds] [warm_runs]      (default 3 rounds, 3 warm)
#   <snapshot-dir>: a copy of the tando repo containing bin/tando (plus lib/, server/, templates/,
#   VERSION, ...: whatever bin/tando loads relative to itself). Make one with
#     rsync -a --exclude=.git --exclude=bench --exclude='test/.*' ~/github/tando/ bench/snapshot-YYYYMMDD/
# Each round starts from the BARE image (Ubuntu 26.04: systemd, sshd, sudo user; nothing else), the
# same as the rivals' empty-VM runs (run-bare.sh) and Dokku. Server: tando-bench-a, 2 GB / 1 CPU,
# ssh 127.0.0.1:2411, http 127.0.0.1:8411. Output: raw/v2/a/round<r>/. (v1 script: raw/v1/.)
# Per round:
#   1. empty VM -> live: host add, host setup, up (fresh app copy without node_modules or .next,
#      no tando.conf: up writes it), each timed; then domain add (timed separately)
#   2. idle memory 0 / 1 app; warm deploys (quiet: CPU, bytes, peak; anon sampling run);
#      warm deploys under load, one by one, and 3 consecutive deploys under ONE load loop
#      (the zero-failed-request check); rollback quiet + under load; broken release under load
#   3. status call CPU (ls, status, ls --json), tando-watch CPU per minute, host setup again
#   4. disk; idle memory with 3, 5 and 10 apps
# Deploy time is recorded twice: "live" = when the output says the release is live (traffic
# switched; comparable to Kamal's return), and "return" = when the command exits (after the soak).
set -u
SNAP=$(cd "${1:?usage: run-a-tando.sh <snapshot-dir> [rounds] [warm_runs]}" && pwd -P)
[ -x "$SNAP/bin/tando" ] || { echo "no $SNAP/bin/tando" >&2; exit 2; }
[ -d "$SNAP/.git" ] && { echo "refusing $SNAP: it is a git checkout (the live tree?); give a snapshot copy" >&2; exit 2; }
ROUNDS=${2:-3} N=${3:-3}
# Options (env): OUT_BASE (default raw/v2/a), HEALTH=/api/version (set after the first up, like the
# rivals' health checks; init writes health = / for Next), QUICK=1 (skip tando-watch, status calls,
# disk and the 3/5/10-app part: for the same-load comparison round).
cd "$(dirname "$0")" && . ./lib.sh
C=tando-bench-a SP=2411 HP=8411 URL=http://127.0.0.1:8411/api/version H=bench.localhost
export TANDO_CONFIG_DIR=$BENCH/.rc PATH=$SNAP/bin:$PATH NO_COLOR=1 COLUMNS=100
W=$BENCH/.cache/a-work                       # app copies live here, never in bench/app
served() { curl -s -m 5 -H "Host: ${1:-$H}" "$URL"; }
# deploy_t <label> cmd...: run cmd with timestamped output, append live_s/return_s to $O/times.tsv
verified_wait() { # poll until the current release is verified (max 120 s); prints seconds or -
  local i; for i in $(seq 1 120); do
    tando releases --json 2>/dev/null | python3 -c 'import sys,json
d=json.load(sys.stdin); c=[r for r in d.get("releases",[]) if r.get("current")]
sys.exit(0 if c and c[0].get("status")=="verified" else 1)' && return 0; sleep 1; done; return 1; }
# deploy_t <label> cmd...: run cmd with timestamped output; append live_s / return_s / verified_s
# (seconds from the start) to $O/times.tsv. "verified" = the release passed its soak (tando
# releases --json polled once a second after the command returned).
deploy_t() { local l=$1 t0 v=-; shift; t0=$(ms); "$@" 2>&1 | "$BENCH/tstamp.pl" > "$O/$l.tlog"; local rc=${PIPESTATUS[0]}
  if [ "$rc" = 0 ]; then verified_wait && v=$(awk -v a="$t0" -v b="$(ms)" 'BEGIN{printf "%.1f", (b-a)/1000}'); fi
  awk -v l="$l" -v rc="$rc" -v v="$v" '/live (in|at)|is live/ && !lv {lv=$1} {last=$1} END{printf "%s\trc=%s\tlive_s=%s\treturn_s=%s\tverified_s=%s\n", l, rc, (lv?lv:"-"), last, v}' "$O/$l.tlog" | tee -a "$O/times.tsv" >&2
  return $rc; }
step() { local l=$1 t0 t1 rc; shift; t0=$(ms); "$@" >> "$O/steps.log" 2>&1; rc=$?; t1=$(ms)
  printf 'step\t%s\t%s\t%s\n' "$l" $((t1 - t0)) "$rc" | tee -a "$STEPS" >&2; return $rc; }
three_deploys() { local i; for i in 1 2 3; do set_version . "z$i"; deploy_t "three-$i" tando deploy || return 1; done; }
copies() { # from to: create apps bench<from>..bench<to> from the built app (no build step)
  local i d; for i in $(seq "$1" "$2"); do d=$W/copy$i; rm -rf "$d"; mkdir -p "$d"
    (cd "$W/bench" && tar -cf - --exclude=.next/cache package.json next.config.mjs .next public) | (cd "$d" && tar -xf -)
    ln -s "$W/bench/node_modules" "$d/node_modules"   # present, so up does not run npm ci; stage uses .next/standalone
    sed -e "s/^app = .*/app = bench$i/" -e '/^build = /d' "$W/bench/tando.conf" > "$d/tando.conf"
    (cd "$d" && tando up --yes > "$O/up-copy$i.log" 2>&1) || log "copy $i failed"
  done; }

for r in $(seq 1 "$ROUNDS"); do
  OB=${OUT_BASE:-$RAW/v2/a}; O=$OB/round$r STEPS=$OB/round$r/steps.tsv
  rm -rf "$O" "$TANDO_CONFIG_DIR" "$W"; mkdir -p "$O" "$W"; : > "$STEPS"
  echo "snapshot $SNAP $(cat "$SNAP/VERSION" 2>/dev/null)" > "$O/notes.txt"
  (cd "$SNAP" && find bin lib server -type f | sort | xargs shasum -a 256) > "$O/snapshot.sha256"
  log "round $r: bare server"
  CPUSET=2 start_server $C tando-bench-bare:26.04 $SP $HP
  disk_setup $C /opt/tando                     # harness: ext4 like a VPS disk; not a user step
  echo "load $(uptime | sed 's/.*averages*: //')" >> "$O/notes.txt"
  # fresh app copy, as a newcomer has it: sources only (no node_modules, .next, tando.conf)
  (cd app && tar -cf - --exclude=./node_modules --exclude=./.next --exclude=./dist --exclude=./.tando \
    --exclude=./.kamal --exclude=./config --exclude=./Dockerfile --exclude=./.dockerignore --exclude=./tando.conf .) |
    (mkdir -p "$W/bench" && cd "$W/bench" && tar -xf -)
  cd "$W/bench"; set_version . v1

  log "empty VM -> live"
  step 1-host-add tando host add bencha vmadmin@127.0.0.1 --port $SP --key "$KEY" --insecure-test
  step 2-host-setup tando host setup bencha public_port=$HP domain_tls=internal
  cp "$O/steps.log" "$O/host-setup.log"
  SETTLE=30 idle_snapshot $C "$O/mem-1-zero-apps.tsv"       # not counted in the empty-VM time
  peak_start $C "$O/cold.peak"; c0=$(cpu_usec $C); x0=$(net_rx $C)
  step 3-up deploy_t cold tando up --yes
  peak_stop $C; printf 'cold\tcpu_ms=%s\trx_bytes=%s\tpeak_sum=%s\n' $(( ($(cpu_usec $C) - c0) / 1000 )) $(( $(net_rx $C) - x0 )) \
    "$(awk '$1=="SUM"{print $2}' "$O/cold.peak")" >> "$O/measured.tsv"
  echo "served after cold: $(served)" >> "$O/notes.txt"
  awk -F'\t' '$1=="step"{s+=$3; n++} END{printf "empty_vm_to_live_ms\t%d\tcommands\t%d\n", s, n}' "$STEPS" | tee -a "$O/notes.txt"
  cp tando.conf "$O/tando.conf.written-by-up" 2>/dev/null
  export TANDO_TEST_RESOLVE="bench.test=127.0.0.1,www.bench.test=127.0.0.1"
  step 4-domain-add tando domain add bench.test
  docker exec $C bash -c 'curl -s --cacert /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt --resolve bench.test:443:127.0.0.1 https://bench.test/api/version' >> "$O/notes.txt" 2>&1
  unset TANDO_TEST_RESOLVE
  if [ -n "${HEALTH:-}" ]; then sed -i '' "s|^health = .*|health = $HEALTH|" tando.conf
    tando deploy > "$O/health-set.log" 2>&1; verified_wait; echo "health set to $HEALTH (tando.conf), redeployed" >> "$O/notes.txt"; fi
  SETTLE=45 idle_snapshot $C "$O/mem-2-one-app.tsv"

  log "warm deploys, quiet"
  for i in $(seq 1 "$N"); do set_version . "q$i"; measured $C "$O" "warm-quiet-$i" deploy_t "warm-quiet-$i" tando deploy
    echo "served after q$i: $(served)" >> "$O/notes.txt"; done
  set_version . ap1; anon_peak $C "$O" anonpeak-1 tando deploy
  log "warm deploys under load, one by one"
  for i in $(seq 1 "$N"); do set_version . "l$i"; with_loop "$O" "warm-loop-$i" "$URL" "$H" deploy_t "warm-loop-$i" tando deploy
    echo "served after l$i: $(served)" >> "$O/notes.txt"; done
  log "zero-failed check: 3 consecutive deploys under one load loop"
  with_loop "$O" three-deploys "$URL" "$H" three_deploys
  echo "served after three-deploys: $(served)" >> "$O/notes.txt"
  log "rollback"
  measured $C "$O" rollback-quiet-1 deploy_t rollback-quiet-1 tando rollback; echo "after rollback-quiet-1: $(served)" >> "$O/notes.txt"
  measured $C "$O" rollback-quiet-2 deploy_t rollback-quiet-2 tando rollback; echo "after rollback-quiet-2: $(served)" >> "$O/notes.txt"
  with_loop "$O" rollback-loop-1 "$URL" "$H" deploy_t rollback-loop-1 tando rollback; echo "after rollback-loop-1: $(served)" >> "$O/notes.txt"
  set_version . back; tando deploy > "$O/redeploy.log" 2>&1
  log "broken release"
  set_version . broken1; with_loop "$O" broken "$URL" "$H" deploy_t broken tando deploy
  echo "served after broken: $(served)" >> "$O/notes.txt"
  set_version . fixed; tando deploy > "$O/fixed.log" 2>&1

  if [ "${QUICK:-0}" != 1 ]; then
  log "status call cost"
  tando ls > "$O/ls-first.log" 2>&1
  for i in $(seq 1 10); do measured $C "$O" "ls-$i" tando ls; done
  for i in $(seq 1 5); do measured $C "$O" "status-$i" tando status; done
  for i in $(seq 1 5); do measured $C "$O" "lsjson-$i" tando ls --json; done
  log "tando-watch CPU: per-run accounting from the journal, and container CPU with the timer on/off"
  docker exec $C systemctl list-timers --all --no-pager > "$O/timers.txt" 2>&1
  t0=$(docker exec $C date -u '+%Y-%m-%d %H:%M:%S'); a=$(cpu_usec $C); sleep 300; b=$(cpu_usec $C)
  docker exec $C journalctl -u tando-watch.service --since "$t0 UTC" --no-pager -o cat > "$O/watch-journal.txt"
  docker exec $C systemctl stop tando-watch.timer; a2=$(cpu_usec $C); sleep 300; b2=$(cpu_usec $C); docker exec $C systemctl start tando-watch.timer
  printf 'container_cpu_ms_per_min_timer_on\t%s\ncontainer_cpu_ms_per_min_timer_off\t%s\nwatch_runs_consumed\t%s\n' \
    $(( (b - a) / 5000 )) $(( (b2 - a2) / 5000 )) "$(grep -o 'Consumed .* CPU time' "$O/watch-journal.txt" | tr '\n' ';')" | tee "$O/watch-cpu.tsv"
  log "host setup again (idempotent run)"
  measured $C "$O" host-setup-again tando host setup bencha public_port=$HP domain_tls=internal

  log "disk"
  docker exec $C bash -c 'd=/opt/tando/apps/bench; echo "releases: $(ls $d/releases | wc -l)"
    for x in $d/incoming $d/releases/*; do [ -e "$x" ] && printf "%s\t%s\n" "${x#$d/}" "$(du -sb --apparent-size "$x" | cut -f1)"; done
    printf "opt_tando\t%s\n" "$(du -sb /opt/tando | cut -f1)"; printf "ext4_used_total\t%s\n" "$(df -B1 --output=used /srv/disk | tail -1)"
    for p in caddy rsync curl nftables; do printf "pkg_%s_kb\t%s\n" $p "$(dpkg-query -W -f="\${Installed-Size}" $p 2>/dev/null)"; done
    n=$(command -v node) && printf "node_runtime\t%s\n" "$(du -sb "$(dirname "$(dirname "$(readlink -f "$n")")")" | cut -f1)"' > "$O/disk.txt" 2>&1
  docker exec $C bash -c 'for cg in /sys/fs/cgroup/system.slice/tando-*.service; do printf "%s current %s anon+shmem %s\n" "${cg##*/}" "$(cat $cg/memory.current)" "$(awk "\$1==\"anon\"||\$1==\"shmem\"{s+=\$2} END{print s}" $cg/memory.stat)"; done' > "$O/app-mem.txt"

  log "3, 5, 10 apps"
  copies 2 3;  SETTLE=45 idle_snapshot $C "$O/mem-3-three-apps.tsv"
  copies 4 5;  SETTLE=45 idle_snapshot $C "$O/mem-4-five-apps.tsv"
  copies 6 10; SETTLE=45 idle_snapshot $C "$O/mem-5-ten-apps.tsv"
  tando ls > "$O/ls-ten-apps.log" 2>&1
  for i in 1 2 3; do measured $C "$O" "ls10-$i" tando ls; done
  fi
  echo "load at end $(uptime | sed 's/.*averages*: //')" >> "$O/notes.txt"
  cd "$BENCH"; stop_server $C
done
rm -rf "$W"
log "tando done: ${OUT_BASE:-$RAW/v2/a}"
