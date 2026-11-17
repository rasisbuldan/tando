# bench/lib.sh: shared helpers for the run-*.sh scripts. Source it; bash 3.2 compatible.
# Every container, volume, network and image created here is named tando-bench-*.
BENCH=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RAW=$BENCH/raw
KEY=$BENCH/.key/id_bench
NET=tando-bench-net
mkdir -p "$RAW" "$BENCH/.key"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N '' -C tando-bench -f "$KEY"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
ms() { python3 -c 'import time; print(int(time.time()*1000))'; }   # wall clock in ms

# start_server <name> <image> <ssh_port> <http_port> [extra docker run args...]
# Limits match the owner's VPS: 2 GB RAM, 1 CPU. Published on 127.0.0.1 only.
start_server() {
  local name=$1 image=$2 sp=$3 hp=$4; shift 4
  docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --hostname "$name" --label tando.bench=1 \
    --privileged --cgroupns=private --memory 2g --memory-swap 2g --cpus 1 --cpuset-cpus "${CPUSET:-2}" --network "$NET" \
    -p 127.0.0.1:"$sp":22 -p 127.0.0.1:"$hp":80 "$@" "$image" >/dev/null
  # Docker's ubuntu image ships /usr/sbin/policy-rc.d (exit 101), which stops apt from starting
  # services it installs (Caddy, nginx...). A real VM has no such file: remove it.
  docker exec "$name" rm -f /usr/sbin/policy-rc.d
  docker exec -i "$name" sh -c 'install -d -m700 -o vmadmin -g vmadmin ~vmadmin/.ssh &&
    cat > ~vmadmin/.ssh/authorized_keys && chown vmadmin:vmadmin ~vmadmin/.ssh/authorized_keys &&
    chmod 600 ~vmadmin/.ssh/authorized_keys' < "$KEY.pub"
  local i=0
  until bssh "$sp" -o ConnectTimeout=2 true 2>/dev/null; do
    i=$((i + 1)); [ $i -lt 90 ] || { log "$name: ssh not ready"; return 1; }; sleep 1; done
  # wait for systemd to settle (boot finished)
  docker exec "$name" systemctl is-system-running --wait >/dev/null 2>&1 || true
  log "$name up (ssh 127.0.0.1:$sp, http 127.0.0.1:$hp)"
}
bssh() { local p=$1; shift
  ssh -F /dev/null -i "$KEY" -p "$p" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR vmadmin@127.0.0.1 "$@"; }

# cgroup readings of the whole server container (the cgroup namespace root is the container's cgroup)
cg() { docker exec "$1" cat "/sys/fs/cgroup/${2:-}${2:+/}$3" 2>/dev/null; }
cpu_usec() { docker exec "$1" sh -c 'sed -n "s/^usage_usec //p" /sys/fs/cgroup/cpu.stat'; }
# anon+shmem bytes of a cgroup path ("" = whole container)
anon_shmem() { docker exec "$1" sh -c "awk '\$1==\"anon\"||\$1==\"shmem\"{s+=\$2} END{print s+0}' /sys/fs/cgroup/${2:-}${2:+/}memory.stat"; }
mem_current() { docker exec "$1" sh -c "cat /sys/fs/cgroup/${2:-}${2:+/}memory.current"; }
# reset the container's memory.peak (cgroup v2: write anything to memory.peak, kernel >= 6.12)
peak_reset() { docker exec "$1" sh -c 'echo 0 > /sys/fs/cgroup/memory.peak' 2>/dev/null; }
peak() { docker exec "$1" cat /sys/fs/cgroup/memory.peak; }

# memory table of every cgroup under system.slice plus init.scope, as TSV: cgroup current anon+shmem
mem_breakdown() { docker exec "$1" bash -c '
  cd /sys/fs/cgroup
  printf "TOTAL\t%s\t%s\n" "$(cat memory.current)" "$(awk "\$1==\"anon\"||\$1==\"shmem\"{s+=\$2} END{print s}" memory.stat)"
  for d in init.scope system.slice system.slice/*/ user.slice machine.slice machine.slice/*/; do
    d=${d%/}; [ -f "$d/memory.current" ] || continue
    printf "%s\t%s\t%s\n" "$d" "$(cat $d/memory.current)" "$(awk "\$1==\"anon\"||\$1==\"shmem\"{s+=\$2} END{print s}" $d/memory.stat)"
  done'; }
# meminfo-based "used" inside the container's view is the host's; use cgroup numbers instead.

# request loop: ~10 req/s against a URL for N seconds; writes "ms_epoch code time_total" lines
# usage: req_loop <url> <outfile> &   (stop with kill)
req_loop() { local url=$1 out=$2 host=${3:-}
  : > "$out"
  while :; do
    if [ -n "$host" ]; then
      curl -s -o /dev/null -m 5 -H "Host: $host" -w "$(ms) %{http_code} %{time_total}\n" "$url" >> "$out" 2>/dev/null || echo "$(ms) 000 5" >> "$out"
    else
      curl -s -o /dev/null -m 5 -w "$(ms) %{http_code} %{time_total}\n" "$url" >> "$out" 2>/dev/null || echo "$(ms) 000 5" >> "$out"
    fi
    sleep 0.1
  done; }
# summarize a req_loop file: total, non-200, longest gap between consecutive 200 responses (ms),
# p50/p95/max latency (ms)
req_summary() { python3 - "$1" <<'EOF'
import sys
rows=[l.split() for l in open(sys.argv[1]) if l.strip()]
rows=[(int(a),b,float(c)) for a,b,c in rows]
ok=[r for r in rows if r[1]=='200']
bad=[r for r in rows if r[1]!='200']
gap=0; prev=None
for t,c,d in rows:
    if c=='200':
        end=t+int(d*1000)
        if prev is not None: gap=max(gap,end-prev)
        prev=end
lat=sorted(r[2]*1000 for r in ok)
q=lambda p: lat[min(len(lat)-1,int(p*len(lat)))] if lat else 0
print(f"requests={len(rows)} ok={len(ok)} failed={len(bad)} longest_gap_ms={gap} p50_ms={q(.5):.1f} p95_ms={q(.95):.1f} max_ms={(lat[-1] if lat else 0):.1f} codes={sorted(set(r[1] for r in bad))}")
EOF
}
# summary of numbers: median, min, max
stats() { python3 -c 'import sys,statistics as s; v=[float(x) for x in sys.argv[1:]]; print(f"n={len(v)} median={s.median(v):.2f} min={min(v):.2f} max={max(v):.2f}")' "$@"; }

# change the app's version string (the one-line warm change)
set_version() { printf "export const VERSION = '%s';\n" "$2" > "$1/lib/version.js"; }

# Peak memory during an operation. memory.peak cannot be reset at the container's root cgroup, so
# reset it (per file descriptor, kernel >= 6.12) on each top-level child cgroup and report each
# peak plus their sum (an upper bound of the true combined peak; children may peak at different
# moments). Includes page cache. Zero CPU while waiting (sleep 1 polling a stop file).
peak_start() { # container outfile
  docker exec "$1" rm -f /run/bench-peak-stop
  docker exec "$1" perl -e '
    my @c=grep { -e "/sys/fs/cgroup/$_/memory.peak" } ("init.scope","system.slice","user.slice","machine.slice"); my %f;
    for my $c (@c){ open(my $h,"+<","/sys/fs/cgroup/$c/memory.peak") or next; syswrite($h,"reset\n"); $f{$c}=$h }
    $|=1; print "ready\n";
    sleep 1 until -e "/run/bench-peak-stop";
    my $s=0; for my $c (sort keys %f){ my $h=$f{$c}; sysseek($h,0,0); sysread($h,my $b,64); chomp $b; $s+=$b; print "$c\t$b\n" }
    print "SUM\t$s\n";' > "$2" &
  PEAK_PID=$!
  local i=0; until grep -q ready "$2" 2>/dev/null; do i=$((i+1)); [ $i -lt 50 ] || break; sleep 0.1; done; }
peak_stop() { docker exec "$1" touch /run/bench-peak-stop; wait "$PEAK_PID" 2>/dev/null; }

# ext4 data disk for a server: a sparse 12 GB file inside the container, loop-mounted with
# direct-io (no double caching) at /srv/disk; each <path> becomes a bind mount of /srv/disk/<name>.
# Real VPS disks are ext4: no reflinks, real copies, overlay storage works natively.
disk_setup() { # container path...
  local c=$1; shift
  docker exec "$c" bash -c '
    set -e
    truncate -s 12G /var/bench-disk.img
    dev=$(losetup --direct-io=on -f --show /var/bench-disk.img)
    mkfs.ext4 -q -F "$dev"; mkdir -p /srv/disk; mount "$dev" /srv/disk
    echo "$dev" > /run/bench-loop
    for p in "$@"; do n=$(echo "$p" | tr / _); mkdir -p "/srv/disk/$n" "$p"
      cp -a "$p/." "/srv/disk/$n/" 2>/dev/null || true; mount --bind "/srv/disk/$n" "$p"; done' _ "$@"
}
# stop and remove a server, releasing its loop device first (loop devices belong to the VM)
stop_server() { # container
  docker exec "$1" bash -c 'systemctl stop docker.socket docker containerd podman 2>/dev/null
    for m in $(findmnt -rno TARGET | grep -E "^/(var/lib/(docker|containerd|containers)|opt/tando|srv/)" | sort -r); do umount -l "$m" 2>/dev/null; done
    [ -f /run/bench-loop ] && losetup -d "$(cat /run/bench-loop)"; true' 2>/dev/null
  docker rm -f "$1" >/dev/null 2>&1 || true
}
net_rx() { docker exec "$1" awk '$1=="eth0:"{print $2}' /proc/net/dev; }

# measured <container> <outdir> <label> cmd... : run cmd on the laptop, record wall ms, server CPU ms
# (cgroup cpu.stat usage_usec delta of the whole server container), bytes received on the server's
# eth0, and the per-slice peak memory sum. Appends one TSV line to <outdir>/measured.tsv.
measured() {
  local c=$1 out=$2 label=$3 cpu0 cpu1 rx0 rx1 t0 t1 rc; shift 3
  mkdir -p "$out"
  peak_start "$c" "$out/$label.peak"
  cpu0=$(cpu_usec "$c"); rx0=$(net_rx "$c"); t0=$(ms)
  "$@" > "$out/$label.log" 2>&1; rc=$?
  t1=$(ms); cpu1=$(cpu_usec "$c"); rx1=$(net_rx "$c")
  peak_stop "$c"
  printf '%s\trc=%s\twall_ms=%s\tcpu_ms=%s\trx_bytes=%s\tpeak_sum=%s\n' "$label" "$rc" $((t1 - t0)) \
    $(((cpu1 - cpu0) / 1000)) $((rx1 - rx0)) "$(awk '$1=="SUM"{print $2}' "$out/$label.peak")" | tee -a "$out/measured.tsv" >&2
  return $rc
}
# with_loop <outdir> <label> <url> <host|-> cmd... : run cmd while reqloop.py hits url at ~10 req/s
# (3 s before and 3 s after); appends the reqsummary line plus wall ms to <outdir>/downtime.tsv
with_loop() {
  local out=$1 label=$2 url=$3 host=$4 rl t0 t1 rc; shift 4
  mkdir -p "$out"
  if [ "$host" = - ]; then "$BENCH/reqloop.py" "$url" "$out/$label.req" & else "$BENCH/reqloop.py" "$url" "$out/$label.req" "$host" & fi
  rl=$!; sleep 3; t0=$(ms)
  "$@" > "$out/$label.log" 2>&1; rc=$?
  t1=$(ms); sleep 3; kill "$rl"; wait "$rl" 2>/dev/null
  printf '%s\trc=%s\twall_ms=%s\t%s\n' "$label" "$rc" $((t1 - t0)) "$("$BENCH/reqsummary.py" "$out/$label.req")" | tee -a "$out/downtime.tsv" >&2
  return $rc
}
# idle_snapshot <container> <outfile>: settle, then 3 memory breakdowns 10 s apart and the CPU rate
idle_snapshot() {
  local c=$1 f=$2 i a b
  sleep "${SETTLE:-30}"; : > "$f"
  a=$(cpu_usec "$c")
  for i in 1 2 3; do echo "# sample $i $(date +%T)" >> "$f"; mem_breakdown "$c" >> "$f"; [ $i = 3 ] || sleep 10; done
  b=$(cpu_usec "$c"); echo "# idle cpu: $(((b - a) / 1000)) ms over ~20 s" >> "$f"
}
export NEXT_TELEMETRY_DISABLED=1

# anon_peak <container> <outdir> <label> cmd... : run cmd while sampling the container's anon+shmem
# every 0.2 s (a separate run from `measured`, because the sampler itself costs some CPU).
anon_peak() {
  local c=$1 out=$2 label=$3; shift 3
  docker exec -d "$c" bash -c 'rm -f /run/samp-stop; : > /run/samp; while [ ! -e /run/samp-stop ]; do
    awk "\$1==\"anon\"||\$1==\"shmem\"{s+=\$2} END{print s}" /sys/fs/cgroup/memory.stat >> /run/samp; sleep 0.2; done'
  sleep 1; local base; base=$(docker exec "$c" head -1 /run/samp)
  "$@" > "$out/$label.log" 2>&1; local rc=$?
  docker exec "$c" bash -c 'touch /run/samp-stop; sleep 0.5'
  printf '%s\trc=%s\tanon_before=%s\tanon_peak=%s\tsamples=%s\n' "$label" $rc "$base" \
    "$(docker exec "$c" sort -n /run/samp | tail -1)" "$(docker exec "$c" wc -l < /dev/null /run/samp | awk '{print $1}')" | tee -a "$out/anonpeak.tsv" >&2
}
