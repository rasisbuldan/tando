#!/bin/bash
# bench/run-studio.sh: `tando db studio` on a 1 CPU / 2 GB test server (the budgets of the design,
# bench/RESULTS.md "db studio"). A test server (test/server, as test/e2e-faults.sh starts one with
# those limits, pinned to one CPU), PostgreSQL, an app `shop` with 100,000 rows and a 20 MB cell,
# a second app `other`. Measures, through the real client and its ssh forward:
#   startup (server side: agent verb to "ready"; laptop: command to the link), idle memory and CPU
#   over 5 minutes, the first page and page 1,000 of the table, peak memory over 50 pages, 10,000
#   rows x 10 columns, 5M rows (truncated), 20 MB cells, the page's weight, the state after stop;
#   then the scoping: the app's own pgbench (short transactions as its role) and app other's HTTP
#   requests (a) alone, (b) while a CPU-heavy studio query runs without the priority lowering,
#   (c) the same with it.
# Output: bench/raw/studio/ (results.txt and the raw files). Server: TANDO_TEST_NAME (default
# tando-bench-studio) on TANDO_TEST_SSH_PORT/TANDO_TEST_HTTP_PORT (2416/8416); removed at the end
# unless KEEP=1. Usage: bench/run-studio.sh [idle seconds (300)]
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
IDLE=${1:-300}
export TANDO_TEST_NAME=${TANDO_TEST_NAME:-tando-bench-studio} TANDO_TEST_SSH_PORT=${TANDO_TEST_SSH_PORT:-2416}
export TANDO_TEST_HTTP_PORT=${TANDO_TEST_HTTP_PORT:-8416} TANDO_TEST_CADDY=${TANDO_TEST_CADDY:-ubuntu}
O=$ROOT/bench/raw/studio W=$ROOT/bench/raw/studio/w
# SCOPE_ONLY=1: only the scoping part, on the server a previous run kept (KEEP=1)
[ "${SCOPE_ONLY:-0}" = 1 ] || rm -rf "$O"; mkdir -p "$W"
export TANDO_CONFIG_DIR=$O/cfg TANDO_COLOR=never TANDO_SOAK=2 TANDO_WAIT=1 TANDO_NO_BROWSER=1
R=$ROOT/bin/tando SSH=$ROOT/test/server/ssh.sh HP=$TANDO_TEST_HTTP_PORT
srv() { "$SSH" "$@"; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
res() { printf '%s\n' "$*" | tee -a "$O/results.txt"; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
pgsu() { srv "sudo -u postgres psql -X -At -d ${1:-tando_shop}" 2>&1; }   # lint: allow RL04 constant database names
cgf() { srv "cat /sys/fs/cgroup/tando.slice/$UNIT/$1"; }   # a file of the unit's cgroup  # lint: allow RL04 UNIT checked in st_start, constant names

if [ "${SCOPE_ONLY:-0}" = 1 ]; then
  "$R" host setup test > "$O/setup.scope.out" 2>&1 || exit 1
  PW=$("$R" db url -a shop --show); PW=${PW#postgres://tando_shop:}; PW=${PW%%@*}
else
log "server: 2 GB, 1 CPU"
TANDO_TEST_DOCKER_ARGS="--memory 2g --memory-swap 2g --cpus 1 --cpuset-cpus ${CPUSET:-2}" "$ROOT/test/server/up.sh" --reset >&2 || exit 1
"$R" host add test vmadmin@127.0.0.1 --port "$TANDO_TEST_SSH_PORT" --key "$ROOT/test/server/id_test" --yes > /dev/null 2>&1
"$R" host setup test public_port=$HP postgres=yes > "$O/setup.out" 2>&1 || { cat "$O/setup.out" >&2; exit 1; }
for a in shop other; do
  rm -rf "${W:?}/$a"; cp -R "$ROOT/examples/hello" "$W/$a"
  sed "s/^app = .*/app = $a/" "$ROOT/examples/hello/tando.conf" > "$W/$a/tando.conf"; echo "database = postgres" >> "$W/$a/tando.conf"
  (cd "$W/$a" && "$R" up > "$O/up.$a.out" 2>&1) || { cat "$O/up.$a.out" >&2; exit 1; }
done
pgsu tando_shop > "$O/seed.out" <<'SQL'
CREATE TABLE items (id bigint PRIMARY KEY, name text, note text, doc jsonb, n numeric, flag bool, created timestamptz);
INSERT INTO items SELECT i, 'item ' || i, repeat('n', i % 50), jsonb_build_object('i', i), i * 1.5, i % 2 = 0,
  '2026-01-01'::timestamptz + i * interval '1 minute' FROM generate_series(1, 100000) i;
CREATE TABLE wide (id int PRIMARY KEY, big text); INSERT INTO wide SELECT 1, repeat('w', 20 * 1024 * 1024);
CREATE TABLE acct (id int PRIMARY KEY, bal bigint); INSERT INTO acct SELECT i, 0 FROM generate_series(1, 1000) i;
ALTER TABLE items OWNER TO tando_shop; ALTER TABLE wide OWNER TO tando_shop; ALTER TABLE acct OWNER TO tando_shop;
ANALYZE;
SQL
PW=$("$R" db url -a shop --show); PW=${PW#postgres://tando_shop:}; PW=${PW%%@*}
fi

# st_start [extra TANDO_STUDIO_TEST words]: the client in the background -> PORT TOKEN UNIT SPID
st_start() {
  local url t0 t1
  t0=$(now)
  TANDO_STUDIO_TEST="$*" "$R" db studio -a shop --no-open > "$O/client.out" 2>&1 &
  SPID=$!
  until grep -q '^http://127.0.0.1:' "$O/client.out" 2> /dev/null; do kill -0 $SPID 2> /dev/null || { cat "$O/client.out" >&2; exit 1; }; sleep 0.05; done
  t1=$(now); LAPTOP=$(perl -e "printf '%.2f', $t1 - $t0")
  url=$(grep '^http://127.0.0.1:' "$O/client.out"); PORT=${url#http://127.0.0.1:}; PORT=${PORT%%/*}
  TOKEN=$(printf '{"code":"%s"}' "${url#*#c=}" | curl -s -H 'Content-Type: application/json' --data-binary @- "http://127.0.0.1:$PORT/api/session" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  UNIT=$(srv "systemctl list-units --plain --no-legend 'tando-shop-studio-*' | awk '{ print \$1 }'")
  case $UNIT in tando-shop-studio-[0-9a-f]*.service) ;; *) echo "bench: no studio unit ($UNIT)" >&2; exit 1;; esac
}
st_stop() { kill "$SPID" 2> /dev/null; wait "$SPID" 2> /dev/null; }
api() { # path [json]: prints "seconds bytes" of the answer; the body in $O/body
  if [ -n "${2:-}" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -s -K - -o "$O/body" -w '%{time_total} %{size_download}\n' -H 'Content-Type: application/json' --data-binary "$2" "http://127.0.0.1:$PORT$1"
  else printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -s -K - -o "$O/body" -w '%{time_total} %{size_download}\n' "http://127.0.0.1:$PORT$1"; fi
}
qj() { perl -MJSON::PP -e 'print JSON::PP->new->encode({id => "b", sql => $ARGV[0], max_rows => $ARGV[1] + 0})' "$1" "${2:-1000}"; }
usec() { cgf cpu.stat | awk '$1 == "usage_usec" { print $2 }'; }
median() { sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }'; }

if [ "${SCOPE_ONLY:-0}" != 1 ]; then
# lint: allow RL04 the text of a result line, not a command
res "# tando db studio bench, $(date -u +%Y-%m-%dT%H:%MZ), $(srv 'psql --version' | awk '{ print $3 }'), server 1 CPU / 2 GB"

# ---- startup: server side (the agent verb to its ready line), then laptop (command to the link)
sid=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
# lint: allow RL04 sid is 32 hex digits from od
srvms=$(srv "s=\$(date +%s%N); (sleep 3) | sudo -n /opt/tando/bin/tando-agent db-studio shop ro $sid 5 47999 test 2> /dev/null | { read -r l; echo \$(( (\$(date +%s%N) - s) / 1000000 )); cat > /dev/null; }")
res "startup, server side (agent verb to ready): ${srvms} ms   budget 400 ms"
st_start
res "startup, laptop (tando db studio to a probed link, local test server): ${LAPTOP} s   budget 2.5 s"

# ---- the page's weight
raw=0 gz=0
for f in / /s.css /s.js; do
  r1=$(curl -s -o /dev/null -w '%{size_download}' "http://127.0.0.1:$PORT$f")
  r2=$(curl -s -o /dev/null -H 'Accept-Encoding: gzip' -w '%{size_download}' "http://127.0.0.1:$PORT$f")
  raw=$((raw + r1)) gz=$((gz + r2))
done
res "page weight: $raw bytes raw, $gz bytes gzip   budget 53248 raw, 18432 gzip"

# ---- idle: memory and CPU with the page open (a ping a minute, as the page does)
api /api/info > /dev/null; api /api/tables > /dev/null
c0=$(usec); t=0
while [ $t -lt "$IDLE" ]; do sleep 60; t=$((t + 60)); api /api/ping > /dev/null; done
c1=$(usec)
res "idle ${IDLE} s: unit memory.current $(( $(cgf memory.current) / 1024 )) KB, CPU $(( (c1 - c0) / 1000 )) ms   budget 15 MB, 200 ms per 5 min"

# ---- browsing
for i in 1 2 3 4 5 6 7 8 9 10; do api /api/rows '{"schema":"public","name":"items","offset":0,"limit":100}' | cut -d' ' -f1; done > "$O/first.t"
res "first page (100 rows of 100,000), API time, median of 10: $(median < "$O/first.t") s   budget 0.150 s"
for i in 1 2 3 4 5; do api /api/rows '{"schema":"public","name":"items","offset":99900,"limit":100}' | cut -d' ' -f1; done > "$O/deep.t"
res "page 1,000 (offset 99,900), median of 5: $(median < "$O/deep.t") s   budget 0.300 s"
for i in $(seq 0 49); do api /api/rows "{\"schema\":\"public\",\"name\":\"items\",\"offset\":$((i * 2000)),\"limit\":500,\"sort\":\"note\",\"desc\":true}" > /dev/null; done
res "peak memory of the unit after 50 pages of 500 rows (sorted): $(( $(cgf memory.peak) / 1048576 )) MB   budget 30 MB"

# ---- the editor
c0=$(usec)
# shellcheck disable=SC2046 # two words: seconds and bytes
set -- $(api /api/query "$(qj 'SELECT id, name, note, n, flag, created, doc, id + 1, id * 2, md5(name) FROM items ORDER BY id LIMIT 10000' 10000)")
c1=$(usec)
kept=$(perl -MJSON::PP -0777 -ne 'my $j = decode_json($_); print scalar @{$j->{results}[0]{rows}}' "$O/body")
res "10,000 rows x 10 columns ($kept rows): $1 s, $2 bytes, studio CPU $(( (c1 - c0) / 1000 )) ms, unit peak $(( $(cgf memory.peak) / 1048576 )) MB   budget 1.5 s, 0.6 s CPU, 48 MB"
# shellcheck disable=SC2046 # two words: seconds and bytes
set -- $(api /api/query "$(qj 'SELECT generate_series(1, 5000000)')")
sleep 1
act=$(echo "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'tando studio%' AND state = 'active'" | pgsu postgres)
kept=$(perl -MJSON::PP -0777 -ne 'my $j = decode_json($_); print scalar @{$j->{results}[0]{rows}}, " rows, ", $j->{results}[0]{reason}' "$O/body")
res "SELECT of 5M rows ($kept): $1 s, unit peak $(( $(cgf memory.peak) / 1048576 )) MB, studio backends active 1 s later: $act   budget 1 s, 48 MB, 0"
# shellcheck disable=SC2046 # two words: seconds and bytes
set -- $(api /api/query "$(qj 'SELECT big FROM wide, generate_series(1, 100)')")
res "20 MB cells x 100 rows: $1 s, $2 bytes ($(perl -MJSON::PP -0777 -ne 'my $j = decode_json($_); print scalar @{$j->{results}[0]{rows}}, " rows kept, ", $j->{results}[0]{reason} || "complete", ($j->{error} ? ", error: $j->{error}{message}" : "")' "$O/body")), unit peak $(( $(cgf memory.peak) / 1048576 )) MB   budget 48 MB"

# ---- the backend's memory under a heavy query (sort, hash join, aggregate)
bpid=$(echo "SELECT pid FROM pg_stat_activity WHERE application_name LIKE 'tando studio%'" | pgsu postgres)
api /api/query "$(qj "SELECT count(*), max(h) FROM (SELECT md5(a.name || b.note) h FROM items a JOIN items b ON b.id = a.id ORDER BY 1) s, (SELECT name, count(*) FROM items GROUP BY name ORDER BY 2 DESC LIMIT 5) g")" > "$O/heavy.t" &
hp=$! peak=0
# lint: allow RL04 bpid is digits from pg_stat_activity
while kill -0 $hp 2> /dev/null; do r=$(srv "awk '/^RssAnon:/ { print \$2 }' /proc/$bpid/status" 2> /dev/null); case $r in [0-9]*) [ "$r" -gt "$peak" ] && peak=$r;; esac; sleep 0.2; done
res "heavy query (self-join 100k, sort, aggregate): $(cut -d' ' -f1 "$O/heavy.t") s, backend private memory (RssAnon) peak $((peak / 1024)) MB"
st_stop

# ---- after stop
left=$(srv "systemctl list-units --all --plain --no-legend 'tando-*-studio-*' | grep -c .; pgrep -xc tando-studio; sudo ls -A /run/tando-studio /run/tando/studio 2> /dev/null | grep -c ." | tr '\n' ' ')
res "after stop: units, processes, files under /run: $left   budget 0 0 0"

fi   # (SCOPE_ONLY)
# ---- scoping: the app's transactions and the other app's requests during a heavy studio query
cat > "$O/tx.sql" <<'SQL'
\set i random(1, 100000)
\set j random(1, 1000)
BEGIN;
SELECT name, n FROM items WHERE id = :i;
SELECT count(*) FROM items WHERE id BETWEEN :i AND :i + 20;
UPDATE acct SET bal = bal + 1 WHERE id = :j;
COMMIT;
SQL
RD=$(srv 'd=$(mktemp -d) && chmod 755 "$d" && echo "$d"')   # the server's work directory for pgbench
case $RD in */tmp.[A-Za-z0-9]*) ;; *) echo "bench: bad work directory $RD" >&2; exit 1;; esac
# lint: allow RL04 RD is checked above
srv "cat > $RD/tx.sql" < "$O/tx.sql"
HEAVY="SELECT sum(hashtext(g::text)) FROM (SELECT generate_series(1, 400000000) g) s"   # CPU only, streamed
workload() { # id name: 20 s of the app's pgbench (2 clients) and of other's HTTP, at once
  # lint: allow RL04 RD is checked above, $1 a constant id
  srv "sudo rm -rf ${RD:?}/pgb && mkdir $RD/pgb && sudo chown tando-shop $RD/pgb && read -r PGPASSWORD && export PGPASSWORD && cd $RD/pgb && sudo -E -u tando-shop pgbench -n -h 127.0.0.1 -U tando_shop -c 2 -j 1 -T 20 -l -f $RD/tx.sql tando_shop > $RD/pgb.$1.out 2>&1" <<< "$PW" &
  local pb=$! end=$(( $(date +%s) + 20 ))
  : > "$O/http.$1"
  while [ "$(date +%s)" -lt $end ]; do curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}\n' "http://other.localhost:$HP/" >> "$O/http.$1"; done
  wait $pb
  local tps p95 hn hp95
  # lint: allow RL04 RD is checked above, $1 a constant id
  tps=$(srv "grep -o 'tps = [0-9.]*' $RD/pgb.$1.out | head -1 | cut -d' ' -f3")
  # lint: allow RL04 RD is checked above
  p95=$(srv "cat $RD/pgb/pgbench_log.* | awk '{ print \$3 / 1000 }' | sort -n | awk '{ a[NR] = \$1 } END { print a[int(NR * 0.95)] }'")
  hn=$(grep -c '^200 ' "$O/http.$1"); hp95=$(awk '$1 == 200 { print $2 * 1000 }' "$O/http.$1" | sort -n | awk '{ a[NR] = $1 } END { print a[int(NR * 0.95)] }')
  res "$2: app shop pgbench $tps tps, p95 $p95 ms; app other HTTP $((hn / 20)) req/s, p95 $hp95 ms"
}
heavy() { # [prio=off]: the heavy query in a new studio session, in the background
  st_start "$@"
  api /api/query "$(qj "$HEAVY")" > /dev/null &
  HQ=$!
  local n=0
  until [ "$(echo "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'tando studio%' AND state = 'active'" | pgsu postgres)" = 1 ]; do
    n=$((n + 1)); [ $n -lt 100 ] || { res "  the heavy query did not start: $(head -c 300 "$O/body")"; return 1; }; sleep 0.2; done
  bpid=$(echo "SELECT pid FROM pg_stat_activity WHERE application_name LIKE 'tando studio%'" | pgsu postgres)
  # lint: allow RL04 bpid is digits from pg_stat_activity
  res "  (studio backend $bpid: nice $(srv "ps -o ni= -p $bpid" | tr -d ' '), $(srv "ionice -p $bpid"), cgroup $(srv "cut -d: -f3 /proc/$bpid/cgroup"))"
}
# three rounds, interleaved (the host's own load drifts): the median of each is in RESULTS.md
for round in 1 2 3; do
  res "round $round"
  workload a$round "(a) alone"
  heavy prio=off && workload b$round "(b) heavy studio query, priority not lowered"; kill $HQ 2> /dev/null; st_stop
  heavy && workload c$round "(c) heavy studio query, scoped (its own cgroup at CPUWeight 1, nice 19)"; kill $HQ 2> /dev/null; st_stop
done
srv "sudo -u postgres psql -X -At -c 'SHOW max_connections' -c 'SHOW shared_buffers'" > "$O/pg.settings"
[ "${KEEP:-0}" = 1 ] || "$ROOT/test/server/down.sh" > /dev/null 2>&1 || docker rm -f "$TANDO_TEST_NAME" > /dev/null 2>&1
log "done: $O/results.txt"
