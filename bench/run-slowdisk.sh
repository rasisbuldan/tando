#!/bin/bash
# bench/run-slowdisk.sh: the copy phase of a warm deploy on a slow, shared disk (bench/RESULTS.md
# "Slow disk"). One fresh test server (test/server, 2 GB / 1 CPU), /opt/tando on an ext4 loop disk
# throttled by the kernel (io.max on the container's cgroup: READ_BPS/WRITE_BPS, default 10 MB/s,
# WRITE_IOPS 300, READ_IOPS 600), and a background writer standing in for other apps (64 KB
# appended and flushed every 0.1 s, on the same disk). Deploys a prebuilt Next.js standalone app
# (bench/app, built once on the laptop: APP_DIST, the directory holding its dist/) with the client
# and agent of <tree>: one cold `tando up`, then RUNS warm deploys (one small file changed each),
# each under a request loop against the app being deployed (reqloop.py, ~10 req/s, 5 s timeout).
# Records per warm deploy: copy_s and total_s (tando history --json), the worst request time and
# failed requests during the deploy. Then times each step of the copy by hand, on the server, on the
# same disk (STEPS=0 skips it).
# Usage: bench/run-slowdisk.sh <tree> <label> <app-dist-dir> [runs (3)]   (ASSETS=1: the app's
# .next/static shared with Caddy, assets = .next/static, /_next/static; 0.1.1 has no assets)
# Server: TANDO_TEST_NAME (tando-je1), TANDO_TEST_SSH_PORT (3801), TANDO_TEST_HTTP_PORT (9801);
# removed at the end unless KEEP=1. Output: bench/raw/slowdisk/<label>/ (results.tsv).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
T=$(cd "${1:?tree}" && pwd -P) L=${2:?label} APPD=$(cd "${3:?app dir}" && pwd -P) RUNS=${4:-3}
. "$ROOT/bench/lib.sh"
export TANDO_TEST_NAME=${TANDO_TEST_NAME:-tando-je1} TANDO_TEST_SSH_PORT=${TANDO_TEST_SSH_PORT:-3801}
export TANDO_TEST_HTTP_PORT=${TANDO_TEST_HTTP_PORT:-9801} TANDO_TEST_CADDY=${TANDO_TEST_CADDY:-ubuntu}
C=$TANDO_TEST_NAME HP=$TANDO_TEST_HTTP_PORT
O=$ROOT/bench/raw/slowdisk/$L W=$O/w
rm -rf "$O"; mkdir -p "$W"
export TANDO_CONFIG_DIR=$O/cfg TANDO_COLOR=never NO_COLOR=1 TERM=dumb COLUMNS=100 PATH=$T/bin:$PATH
res() { printf '%s\n' "$*" | tee -a "$O/results.tsv"; }

log "[$L] server $C"
TANDO_TEST_DOCKER_ARGS="--memory 2g --memory-swap 2g --cpus 1 --cpuset-cpus ${CPUSET:-5}" "$ROOT/test/server/up.sh" --reset >&2 || exit 1
disk_setup "$C" /opt/tando
docker exec "$C" systemctl restart caddy   # (its own mount namespace: it must see /opt/tando on the loop disk)
# the throttle: io.max of the container's cgroup, written from the Docker host's side (the
# container's own root cgroup refuses it), on the loop device's major:minor
dev=$(docker exec "$C" cat /run/bench-loop); mm=$(docker exec "$C" lsblk -dno MAJ:MIN "$dev" | tr -d ' ')
cid=$(docker inspect -f '{{.Id}}' "$C")
docker run --rm --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup tando-testvm:bare sh -c \
  "p=\$(find /sys/fs/cgroup -maxdepth 3 -type d -name '*$cid*' | head -1) && [ -n \"\$p\" ] &&
   echo '$mm rbps=${READ_BPS:-10485760} wbps=${WRITE_BPS:-10485760} riops=${READ_IOPS:-600} wiops=${WRITE_IOPS:-300}' > \$p/io.max && cat \$p/io.max" > "$O/throttle.txt" || { log "throttle failed"; exit 1; }
log "[$L] throttle: $(cat "$O/throttle.txt")"
# the other apps: a steady writer with flushes on the same disk
docker exec "$C" bash -c 'mkdir -p /opt/tando/bgw && systemd-run -q --unit=bench-bgw bash -c "while :; do
  dd if=/dev/urandom of=/opt/tando/bgw/log bs=64k count=1 oflag=append conv=notrunc,fsync status=none
  [ \$(stat -c %s /opt/tando/bgw/log) -lt 104857600 ] || : > /opt/tando/bgw/log; sleep 0.1; done"'

tando host add je vmadmin@127.0.0.1 --port "$TANDO_TEST_SSH_PORT" --key "$ROOT/test/server/id_test" --insecure-test > "$O/add.out" 2>&1 ||
  tando host add je vmadmin@127.0.0.1 --port "$TANDO_TEST_SSH_PORT" --key "$ROOT/test/server/id_test" --yes > "$O/add.out" 2>&1
tando host setup je public_port="$HP" > "$O/setup.out" 2>&1 || { cat "$O/setup.out" >&2; exit 1; }
# the app: the prebuilt dist only (no build on the laptop: the copy is what is measured)
mkdir -p "$W/bench"
cp -R "$APPD/dist" "$W/bench/dist"
printf 'app = bench\nrecipe = node\nout = dist\nstart = node server.js\nhealth = /api/version\nhealth_timeout = 30\nmemory = 512M\n' > "$W/bench/tando.conf"
[ "${ASSETS:-0}" = 1 ] && echo 'assets = .next/static, /_next/static' >> "$W/bench/tando.conf"
cd "$W/bench" || exit 1
verified_wait() { local i; for i in $(seq 1 90); do
    tando releases --json 2> /dev/null | python3 -c 'import sys,json
d=json.load(sys.stdin); c=[r for r in d.get("releases",[]) if r.get("current")]
sys.exit(0 if c and c[0].get("status")=="verified" else 1)' && return 0; sleep 1; done; return 1; }
echo v0 > dist/bench-version.txt
tando up --yes > "$O/cold.out" 2>&1 || { tail -20 "$O/cold.out" >&2; exit 1; }
verified_wait || log "[$L] cold: not verified"
res "label	run	rc	copy_s	total_s	deploy_wall_s	req	failed	max_req_ms	p95_req_ms"
URL=http://127.0.0.1:$HP/api/version H=bench.localhost
for r in $(seq 1 "$RUNS"); do
  echo "v$r" > dist/bench-version.txt
  "$ROOT/bench/reqloop.py" "$URL" "$O/req.$r" "$H" & rl=$!
  sleep 2; t0=$(ms)
  tando deploy > "$O/deploy.$r.out" 2>&1; rc=$?
  t1=$(ms); sleep 2; kill $rl; wait $rl 2> /dev/null
  h=$(tando history --json 2> /dev/null | python3 -c 'import sys,json
d=json.load(sys.stdin); e=d if isinstance(d,list) else d.get("history",d.get("entries",[]))
e=[x for x in e if x.get("kind")=="deploy"]; x=max(e,key=lambda x:x.get("at",0))
print(x.get("copy_s"), x.get("total_s"))')
  q=$(python3 -c 'import sys
rows=[l.split() for l in open(sys.argv[1]) if l.strip()]
lat=sorted(float(c) for a,b,c in rows); bad=sum(1 for a,b,c in rows if b!="200")
print(len(rows), bad, "%.0f" % lat[-1], "%.0f" % lat[int(.95*len(lat))])' "$O/req.$r")
  # shellcheck disable=SC2086 # words
  res "$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$L" "$r" "$rc" $h "$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.1f", (b - a) / 1000 }')" $q)"
  verified_wait || log "[$L] run $r: not verified"
done
tando history --json > "$O/history.json" 2>&1
# (an agent traced by hand writes its xtrace with timestamps here: kept with the results)
docker exec "$C" cat /run/tando-trace > "$O/trace.txt" 2> /dev/null || rm -f "$O/trace.txt"

# each step of the copy, by hand, on the same throttled disk with the writer running: the live
# release and the upload as the last deploy left them; caches dropped before each step
if [ "${STEPS:-1}" = 1 ]; then
  docker exec -i "$C" bash -s > "$O/steps.txt" 2>&1 <<'EOS'
D=/opt/tando/apps/bench; cur=$(readlink "$D/current"); cur=${cur##*/}; P=$D/releases/$cur; X=/opt/tando/apps/bench/releases/zz-bench
g=$(stat -c %G "$P")
st() { local l=$1 t0 t1; shift; sync; echo 3 > /proc/sys/vm/drop_caches; t0=$(date +%s%N); "$@" > /dev/null 2>&1; t1=$(date +%s%N); printf 'step\t%s\t%d ms\n' "$l" $(( (t1 - t0) / 1000000 )); }
echo "files: $(find "$D/incoming" | wc -l), $(du -sm "$D/incoming" | cut -f1) MB"
st "cp -a (0.1.1's copy)" cp -a --no-dereference "$D/incoming" "$X"; rm -rf "$X"
st "rsync -c --link-dest" rsync -rltHD -c --modify-window=2000000000 --link-dest="$P" "$D/incoming/" "$X"
st "chown -R + chmod -R" sh -c "chown -RhP root:$g $X && chmod -R a-st,u=rwX,g=rX,o= $X"
st "find checks (links, symlinks, special)" sh -c "find $X ! -type d -links +1 -printf '%i\n' | sort | uniq -d; find $X -type l; find $X -name '.env*'; find $P ! -type d -printf '%i\n' > /dev/null"
rm -rf "$X"
st "rsync --size-only --link-dest" rsync -rltHD --size-only --modify-window=2000000000 --link-dest="$P" "$D/incoming/" "$X"; rm -rf "$X"
st "sync (global)" sync
st "sync <file> <dir>" sh -c "echo x > $D/zz.tmp && sync $D/zz.tmp && sync $D"; rm -f "$D/zz.tmp"
EOS
  cat "$O/steps.txt" >&2
fi
cd "$ROOT" || exit 1
[ "${KEEP:-0}" = 1 ] || stop_server "$C"
log "[$L] done: $O/results.tsv"
