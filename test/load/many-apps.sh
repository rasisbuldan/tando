#!/bin/bash
# Many apps on one server: create apps <from>..<to> (hello copies, or static sites with KIND=static),
# timing `tando up` of each; every STEP apps (and at the end) time ls, status, doctor, one top frame,
# a Caddy reload, and record memory (whole box, Caddy) and the last tando-watch run's CPU.
# usage: test/load/many-apps.sh <from> <to> <outdir>     (KIND=node|static, STEP=10)
set -u
. "$(dirname "$0")/lib.sh"
. "$LROOT/test/lib.sh"          # t_pty
from=$1 to=$2 out=$3 KIND=${KIND:-node} STEP=${STEP:-10}
mkdir -p "$out" "$LW/many"
export TANDO_SOAK=${TANDO_SOAK:-2}
tm() { local t0 t1; t0=$(ms); "$@" > /dev/null 2>&1; local rc=$?; t1=$(ms); echo "$((t1 - t0))ms/rc$rc"; }
measure() {
  local n=$1 ls st dr tp rl mem
  ls=$(tm "$R" ls); st=$(tm "$R" status a001); dr=$(tm "$R" doctor)
  tp=$(tm t_pty 120 40 6 "$R" top)
  rl=$(sx 't0=$(date +%s%N); systemctl reload caddy; echo $(( ($(date +%s%N) - t0) / 1000000 ))ms')
  mem=$(sx 'a() { awk '"'"'$1=="anon"||$1=="shmem"{s+=$2} END{printf "%d", s/1048576}'"'"' /sys/fs/cgroup/$1/memory.stat; }
           printf "total=%sMB caddy=%sMB cur=%sMB" "$(a .)" "$(a system.slice/caddy.service)" $(( $(cat /sys/fs/cgroup/memory.current) / 1048576 ))')
  local w; w=$(sx 'journalctl -u tando-watch.service -o cat --no-pager | grep -o "Consumed [^ ]* CPU time" | tail -3 | tr "\n" " "')
  local ag; ag=$(sx 't0=$(date +%s%N); /opt/tando/bin/tando-agent status >/dev/null; echo $(( ($(date +%s%N) - t0) / 1000000 ))ms')
  printf '%s\tapps=%s\tls=%s\tstatus=%s\tdoctor=%s\ttop1=%s\tcaddy_reload=%s\tagent_status_server=%s\t%s\twatch_last3=%s\tload1=%s\n' \
    "$(date +%H:%M:%S)" "$n" "$ls" "$st" "$dr" "$tp" "$rl" "$ag" "$mem" "$w" "$(load1)" | tee -a "$out/measure.tsv" >&2
}
for i in $(seq "$from" "$to"); do
  a=$(printf 'a%03d' "$i"); d=$LW/many/$a
  if [ ! -d "$d" ]; then
    mkdir -p "$d"
    if [ "$KIND" = static ]; then
      mkdir -p "$d/public"; echo "<h1>$a</h1>" > "$d/public/index.html"
      printf 'app = %s\nrecipe = static\nout = public\n' "$a" > "$d/tando.conf"
    else
      cp "$LROOT/examples/hello/server.js" "$LROOT/examples/hello/VERSION" "$d/"
      printf 'app = %s\nrecipe = node\nstart = node server.js\nhealth = /health\nmemory = %s\nhealth_timeout = 15\n' "$a" "${MEM:-128M}" > "$d/tando.conf"
    fi
  fi
  t0=$(ms); (cd "$d" && "$R" up > "$out/up-$a.out" 2>&1); rc=$?; t1=$(ms)
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$a.localhost:$TANDO_TEST_HTTP_PORT/")
  printf '%s\t%s\t%s\tup_ms=%s\trc=%s\thttp=%s\tload1=%s\t%s\n' "$(date +%H:%M:%S)" "$a" "$KIND" "$((t1 - t0))" "$rc" "$code" "$(load1)" \
    "$(grep -E 'failed|error|no free|✗' "$out/up-$a.out" | head -1 | tr -s ' ' | cut -c1-200)" | tee -a "$out/up.tsv" >&2
  [ $((i % STEP)) = 0 ] && measure "$i"
  [ "$rc" = 0 ] || [ "${KEEP_GOING:-1}" = 1 ] || break
done
measure "$to-end"
