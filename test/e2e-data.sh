#!/bin/bash
# End-to-end test of data features: PostgreSQL per app, file data, backups and restore, destroy.
# Uses examples/notes (needs npm for `npm ci`). Installs PostgreSQL in the test container through
# `tando host setup test postgres=yes`. Starts from a clean `test/server/up.sh --reset`.
# Usage: test/e2e-data.sh [--no-reset]
set -u
# Server: TANDO_TEST_NAME, TANDO_TEST_SSH_PORT, TANDO_TEST_HTTP_PORT (default tando-testvm, 2222,
# 8080). The server is reset first when run by hand on the default one, or when TANDO_TEST_OWNED=1.
TN=${TANDO_TEST_NAME:-tando-testvm} SP=${TANDO_TEST_SSH_PORT:-2222} HP=${TANDO_TEST_HTTP_PORT:-8080}
export TANDO_TEST_NAME=$TN TANDO_TEST_SSH_PORT=$SP TANDO_TEST_HTTP_PORT=$HP
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
. "$ROOT/test/lib.sh"   # t_until (this suite keeps its own pass/fail/check, defined below)
E=${T_WORK:-$ROOT/test/.e2e-data-$TN}   # one work dir per test server
W=$E/w R=$ROOT/bin/tando SSH=$ROOT/test/server/ssh.sh
AGENT=/opt/tando/bin/tando-agent
BK=/var/backups/tando
export TANDO_CONFIG_DIR=$E/cfg TANDO_COLOR=never
export TANDO_SOAK=${TANDO_SOAK:-2} TANDO_WAIT=1   # a short soak (30 s by default) keeps the suite fast
FAILS=0

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check() { local n=$1; shift; if "$@"; then pass "$n"; else fail "$n"; fi; }
log() { echo "---- $*" >&2; }
srv() { "$SSH" "$@"; }
page() { curl -s -m 5 "http://${1:-notes}.localhost:$HP/"; }
note() { curl -s -m 5 -X POST "http://notes.localhost:$HP/notes?text=$1" > /dev/null; }
psql_as() { # role password db sql
  srv "PGPASSWORD=$2 psql -X -At -h 127.0.0.1 -U $1 -d $3 -c \"$4\"" 2>&1
}
psql_in() { # role password db: statements on stdin, one session; an error does not end it
  srv "PGPASSWORD=$2 psql -X -At -h 127.0.0.1 -U $1 -d $3" 2>&1
}
pgsu() { # db: statements on stdin as the superuser
  srv "sudo -u postgres psql -X -At -d $1" 2>&1
}
oom_adj() { srv "cat /proc/$1/oom_score_adj"; }
pg_rows() { srv "sudo $AGENT doctor" 2> /dev/null | grep "postgresql $1"; }   # the doctor row "postgresql <name>"

if [ "${1:-}" != --no-reset ] && { [ "$TN" = tando-testvm ] || [ "${TANDO_TEST_OWNED:-}" = 1 ]; }; then
  log "resetting test server"
  "$ROOT/test/server/up.sh" --reset >&2 || exit 1
fi
rm -rf "${E:?}"
mkdir -p "$W"
rsync -a --exclude node_modules "$ROOT/examples/notes/" "$W/notes/"
cd "$W/notes"
npm ci --no-audit --no-fund > "$E/npm.out" 2>&1 || { cat "$E/npm.out" >&2; exit 1; }

# D1. host setup installs PostgreSQL; measure what it adds
"$R" host add test vmadmin@127.0.0.1 --port $SP --key "$ROOT/test/server/id_test" --yes >&2
# apt fails once on the way (a mirror that stalls does this): setup tries again by itself. The
# stand-in sits before the real apt-get in root's PATH, fails its first "install" and then gets
# out of the way.
srv 'sudo tee /usr/local/sbin/apt-get > /dev/null && sudo chmod 755 /usr/local/sbin/apt-get' <<'SHIM'
#!/bin/sh
case " $* " in *" install "*)
  if [ ! -e /root/apt-failed-once ]; then
    touch /root/apt-failed-once
    echo "E: Failed to fetch http://archive.example/pool/x.deb  Connection timed out (test stand-in)" >&2
    exit 100
  fi;;
esac
exec /usr/bin/apt-get "$@"
SHIM
mem0=$(srv "free -m | awk '/^Mem:/ {print \$3}'")
t0=$SECONDS
"$R" host setup test public_port=$HP postgres=yes > "$E/setup.out" 2>&1; rc=$?; cat "$E/setup.out" >&2
secs=$((SECONDS - t0))
T_UNTIL_STEP=0.5 t_until 30 srv "pg_isready -q -h 127.0.0.1"   # PostgreSQL is up before it is measured
mem1=$(srv "free -m | awk '/^Mem:/ {print \$3}'")
unit=$(srv "systemctl list-units --plain --no-legend 'postgresql@*' | awk '{print \$1}' | head -1")
pgmem=$(srv "cat /sys/fs/cgroup/system.slice/system-postgresql.slice/$unit/memory.current" 2> /dev/null)
pganon=$(srv "awk '\$1 == \"anon\" || \$1 == \"shmem\" {s += \$2} END {print s}' \
  /sys/fs/cgroup/system.slice/system-postgresql.slice/$unit/memory.stat" 2> /dev/null)
log "postgres: setup ${secs}s; $unit memory.current $((${pgmem:-0} / 1048576)) MB," \
  "anon+shmem $((${pganon:-0} / 1048576)) MB; host used $mem0 -> $mem1 MB"
echo "postgres memory: $unit memory.current $((${pgmem:-0} / 1048576)) MB, anon+shmem" \
  "$((${pganon:-0} / 1048576)) MB, host used memory $mem0 -> $mem1 MB, setup ${secs}s" > "$E/pgmem"
check "D1 host setup postgres=yes (${secs}s): PostgreSQL accepting connections" \
  eval '[ $rc = 0 ] && srv "pg_isready -q -h 127.0.0.1"'
tries=$(srv "sudo grep -c 'apt try 1 of 3 .* failed' /var/log/tando-apt.log")
check "D1r apt failed once (the stand-in) and setup tried again by itself ($tries failed try in the log)" \
  eval '[ $rc = 0 ] && [ "$tries" = 1 ] && srv "sudo test -e /root/apt-failed-once"'
srv 'sudo rm -f /usr/local/sbin/apt-get'

# G1-G2. PostgreSQL sized from the server's RAM, pgbouncer in front of it (docs/ARCHITECTURE.md)
pgconf() { srv "sudo sed -n 's/^$1 = //p' /etc/postgresql/*/main/conf.d/tando.conf"; }
pgshow() { srv "sudo -u postgres psql -X -At -c 'SHOW $1'"; }
sbmb() { srv "sudo -u postgres psql -X -At -c \"SELECT setting::bigint * 8 / 1024 FROM pg_settings WHERE name = 'shared_buffers'\""; }
mc=$(pgconf max_connections); sb=$(pgconf shared_buffers)
ram=$(tr -d '│\n ' < "$E/setup.out" | grep -o 'from[0-9]*MBofRAM' | head -1 | tr -cd '0-9')
want=$(( (${ram:-0} / 80 + 5) / 10 * 10 )); [ "$want" -lt 50 ] && want=50; [ "$want" -gt 400 ] && want=400
check "G1 PostgreSQL runs sized from the RAM setup names (${ram:-?} MB): max_connections $mc (one per 80 MB, 50 to 400), shared_buffers $sb (15%)" \
  eval '[ -n "$ram" ] && [ "$mc" = "$want" ] && [ "$(pgshow max_connections)" = "$mc" ] &&
        [ "$sb" = "$((ram * 15 / 100))MB" ] && [ "$(sbmb)MB" = "$sb" ]'
check "G2 pgbouncer runs on 127.0.0.1:6432 only (no unix socket); setup's database step says so" \
  eval 'srv "systemctl is-active -q pgbouncer" && [ "$(srv "ss -Hltn sport = :6432" | awk "{ print \$4 }" | tr "\n" " ")" = "127.0.0.1:6432 " ] &&
        srv "! test -e /var/run/postgresql/.s.PGSQL.6432" && tr -d "│\n " < "$E/setup.out" | grep -q "pgbounceron127.0.0.1:6432,transactionpooling"'

# P1. out of memory, the kernel must not pick the postmaster; a connection's process stays killable
pv=$(srv "ls /etc/postgresql")   # the major version this server installed
pm=$(srv "head -1 /run/postgresql/$pv-main.pid")
kid=$(srv "pgrep -P $pm | head -1")
check "P1a oom_score_adj: postmaster $(oom_adj "$pm") (-900), one of its processes $(oom_adj "$kid") (0)" \
  eval '[ "$(oom_adj "$pm")" = -900 ] && [ "$(oom_adj "$kid")" = 0 ]'
check "P1b tando's drop-in is part of the unit, and the version is recorded in host.conf ($pv)" \
  eval 'srv "systemctl show -P DropInPaths postgresql@$pv-main" | grep -q "postgresql@.service.d/tando.conf" &&
        srv "systemctl show -P OOMScoreAdjust postgresql@$pv-main" | grep -qx -- -900 &&
        srv "grep -qx postgres_version=$pv /opt/tando/host.conf"'
check "P1c doctor: postgresql memory ok" eval 'pg_rows memory | grep -q "^check.ok.*postmaster last (-900)"'
srv "echo 0 | sudo tee /proc/$pm/oom_score_adj > /dev/null"
check "P1d doctor reads the live value: a postmaster at 0 is a warning" \
  eval 'pg_rows memory | grep -q "^check.warn.*postmaster 0"'
srv "echo -900 | sudo tee /proc/$pm/oom_score_adj > /dev/null"

# D2. up creates the role, database and DATABASE_URL; the app answers
"$R" up > "$E/up.out" 2>&1; rc=$?; cat "$E/up.out" >&2
check "D2 up with database = postgres: app answers ($(page))" test "$(page)" = "notes v1 db=0 file=0"
# penv app KEY: the value in the environment of the app's running process
penv() { local pid; pid=$(srv "systemctl show -P MainPID tando-$1"); srv "sudo cat /proc/$pid/environ" | tr '\0' '\n' | sed -n "s/^$2=//p"; }
check "G3 the app (answering, D2) runs with pgbouncer's DATABASE_URL (6432), and DATABASE_URL_DIRECT PostgreSQL's (5432)" \
  eval 'penv notes DATABASE_URL | grep -q "@127.0.0.1:6432/tando_notes$" && penv notes DATABASE_URL_DIRECT | grep -q "@127.0.0.1:5432/tando_notes$"'

# D3. the password stays on the server
"$R" env ls > "$E/envls.out" 2>&1; cat "$E/envls.out" >&2
check "D3a env ls masks the database password" grep -q 'postgres://tando_notes:\*\*\*\*@127.0.0.1' "$E/envls.out"
"$R" db url > "$E/url1.out" 2>&1; rc=$?
check "D3b db url without --show is refused" eval '[ $rc != 0 ] && grep -q -- "--show" "$E/url1.out"'
url=$("$R" db url --show)
pw=${url#postgres://tando_notes:}; pw=${pw%%@*}
check "D3c db url --show prints the URL (pgbouncer's)" \
  eval 'echo "$url" | grep -q "^postgres://tando_notes:[0-9a-f]\{48\}@127.0.0.1:6432/tando_notes$"'
check "D3d the password is not stored on the laptop" \
  eval '! grep -rq "$pw" "$TANDO_CONFIG_DIR" "$W/notes" --exclude-dir=node_modules 2> /dev/null'
# shellcheck disable=SC2034  # (read in the check's eval)
ul=$(srv "sudo cat /etc/pgbouncer/userlist.txt"); ini=$(srv "sudo cat /etc/pgbouncer/pgbouncer.ini")
check "G4 pgbouncer knows tando_notes: its SCRAM secret (not the password), a pool of 5; its files root:postgres 0640; env ls masks DATABASE_URL_DIRECT" \
  eval 'echo "$ul" | grep -qF "\"tando_notes\" \"SCRAM-SHA-256\$" && ! echo "$ul" | grep -q "$pw" &&
        echo "$ini" | grep -qx "tando_notes = host=127.0.0.1 port=5432 dbname=tando_notes pool_size=5 max_db_connections=5" &&
        [ "$(srv "sudo stat -c %U:%G:%a /etc/pgbouncer/userlist.txt /etc/pgbouncer/pgbouncer.ini" | sort -u)" = root:postgres:640 ] &&
        grep -q "DATABASE_URL_DIRECT.*postgres://tando_notes:\*\*\*\*@127.0.0.1:5432" "$E/envls.out"'

# D4. the role reaches only its own database
rm -rf "${W:?}/notes2"; cp -R "$W/notes" "$W/notes2"
sed 's/^app = notes$/app = notes2/' "$W/notes/tando.conf" > "$W/notes2/tando.conf"
(cd "$W/notes2" && "$R" up > "$E/up2.out" 2>&1)
check "D4a own database: connect works" test "$(psql_as tando_notes "$pw" tando_notes 'SELECT 1')" = 1
out=$(psql_as tando_notes "$pw" tando_notes2 'SELECT 1')
check "D4b another app's database: refused ($(echo "$out" | tail -1))" eval 'echo "$out" | grep -q "permission denied"'
out=$(psql_as tando_notes "$pw" postgres 'SELECT 1')
check "D4c the postgres database: refused" eval 'echo "$out" | grep -q "permission denied"'
# K. bounded shared fate: one app's uid holds at most 20 x db_pool (100) connections to pgbouncer
# and PostgreSQL (pgbouncer's max_client_conn is every app's); PostgreSQL's memory is protected
cat > "$E/kc.js" <<'JS'
const net = require('net'), N = Number(process.argv[2]); let ok = 0, bad = 0, n = 0;
for (let i = 0; i < N; i++) {
  const s = net.connect(6432, '127.0.0.1');
  s.on('connect', () => { ok++; done(); }); s.on('error', () => { bad++; done(); });
}
function done() { if (++n === N) { console.log('ok=' + ok + ' bad=' + bad); setTimeout(() => process.exit(0), 3000); } }
JS
kd=$(srv 'd=$(mktemp -d) && chmod 755 "$d" && cat > "$d/kc.js" && chmod 644 "$d/kc.js" && echo "$d"' < "$E/kc.js")
srv "cd / && sudo -u tando-notes node $kd/kc.js 130" > "$E/kc1.out" 2>&1 &
kp=$!; sleep 1
o2=$(srv "cd / && sudo -u tando-notes2 node $kd/kc.js 5" 2>&1); wait $kp; o1=$(cat "$E/kc1.out")
check "K1 notes opens 130 connections to pgbouncer at once: at most 100 connect, the rest refused ($o1); notes2 meanwhile connects ($o2)" \
  eval 'ok=$(echo "$o1" | sed -n "s/.*ok=\([0-9]*\).*/\1/p"); [ -n "$ok" ] && [ "$ok" -le 100 ] && [ "$ok" -ge 80 ] &&
        echo "$o1" | grep -q "bad=[1-9]" && [ "$o2" = "ok=5 bad=0" ] &&
        srv "sudo nft list chain inet tando output" | grep -q "dport { 5432, 6432 } ct state new ct count over 100 "'
lowpg=$(srv "systemctl show -P MemoryLow postgresql@$pv-main"); lowsys=$(srv "systemctl show -P MemoryLow system.slice")
check "K2 PostgreSQL keeps its shared buffers and more from reclaim (MemoryLow $lowpg, system.slice $lowsys); postgres is in tando-core" \
  eval '[ "${lowpg:-0}" -ge $(( ($(sbmb) + 32) * 1048576 )) ] && [ "${lowsys:-0}" -gt "${lowpg:-0}" ] &&
        srv "id -nG postgres" | grep -qw tando-core'

# P2. the role's limits: defaults on both apps; tando db shows what PostgreSQL holds
"$R" db > "$E/db1.out" 2>&1; cat "$E/db1.out" >&2
check "P2a tando db: 30s statement timeout, 5min idle in transaction, 1GB temporary files" \
  eval 'grep -q "statement timeout *30s" "$E/db1.out" && grep -q "idle in transaction *5min" "$E/db1.out" &&
        grep -q "temporary files *1GB" "$E/db1.out" && grep -q "tando_notes .*PostgreSQL $pv/main" "$E/db1.out"'
url2=$(cd "$W/notes2" && "$R" db url --show); pw2=${url2#postgres://tando_notes2:}; pw2=${pw2%%@*}
# P2b-c. a setting the client refuses, and one the server refuses
cp tando.conf "$E/tando.conf.orig"
echo "db_statement_timeout = 30" >> tando.conf
"$R" deploy > "$E/badconf.out" 2>&1; rc=$?
check "P2b the client refuses db_statement_timeout = 30 (no unit) and says what it takes (rc=$rc)" \
  eval '[ $rc != 0 ] && grep -q "db_statement_timeout is a time like" "$E/badconf.out"'
cp "$E/tando.conf.orig" tando.conf
out=$(printf 'recipe=node\ndb_temp_limit=4X\n' | srv "sudo $AGENT configure notes" 2>&1)
check "P2c the server refuses db_temp_limit=4X ($out)" eval 'echo "$out" | grep -q "bad db_temp_limit: 4X"'
# from the next deploy (D6): notes gets short limits of its own, notes2 keeps the defaults
printf 'db_statement_timeout = 1s\ndb_idle_tx_timeout = 2s\ndb_temp_limit = 4M\n' >> tando.conf

# D5-D6. write data, deploy: a pre-deploy backup is taken, data stays
note one; note two; note three
check "D5 three notes in the database and the data file" test "$(page)" = "notes v1 db=3 file=3"
echo 2 > VERSION
"$R" deploy > "$E/d2.out" 2>&1; rc=$?; cat "$E/d2.out" >&2
"$R" backup ls > "$E/bls.out" 2>&1; cat "$E/bls.out" >&2
check "D6a deploy v2 keeps the data ($(page))" test $rc = 0 -a "$(page)" = "notes v2 db=3 file=3"
check "D6b a pre-deploy backup holds data and db" grep -qE 'predeploy .* data db' "$E/bls.out"
check "D6c backup ls: TIME (GMT) column in UTC" \
  eval 'grep -q "TIME (GMT)" "$E/bls.out" && grep -qE " $(TZ=UTC date +%m-%d) [0-9]{2}:[0-9]{2} " "$E/bls.out"' 

# P3. a statement over the app's statement_timeout (1s) is cancelled; the session goes on
t0=$SECONDS
out=$(psql_in tando_notes "$pw" tando_notes <<'SQL'
SELECT pg_sleep(8);
SELECT 'next ' || count(*) FROM notes;
SQL
)
check "P3a a query over the 1s limit is cancelled ($((SECONDS - t0))s), the session's next query answers" \
  eval '[ $((SECONDS - t0)) -lt 6 ] && echo "$out" | grep -q "canceling statement due to statement timeout" &&
        echo "$out" | grep -qx "next 3"'
check "P3b the app itself still answers ($(page))" test "$(page)" = "notes v2 db=3 file=3"
# P4. the second app is not under the first one's limits
out=$(psql_in tando_notes2 "$pw2" tando_notes2 <<'SQL'
SELECT pg_sleep(2);
SHOW statement_timeout;
SHOW temp_file_limit;
SQL
)
check "P4 notes2 keeps the defaults: a 2 s query runs, 30s and 1GB ($(echo "$out" | tr '\n' ' '))" \
  eval '! echo "$out" | grep -q cancel && echo "$out" | grep -qx 30s && echo "$out" | grep -qx 1GB'
# P5. a session idle inside a transaction for longer than 2 s is closed (a real timer: it waits)
out=$(psql_in tando_notes "$pw" tando_notes <<'SQL'
BEGIN;
SELECT 'in transaction';
\! sleep 4
SELECT 'still here';
SQL
)
check "P5 idle in transaction over 2s: the connection is closed ($(echo "$out" | grep -i -m1 'idle\|closed'))" \
  eval 'echo "$out" | grep -qx "in transaction" && echo "$out" | grep -q "idle-in-transaction timeout" &&
        ! echo "$out" | grep -qx "still here"'
# P6. temporary files over 4 MB: the statement fails; the role cannot lift that limit itself
out=$(psql_in tando_notes "$pw" tando_notes <<'SQL'
SET statement_timeout = 0;
SELECT count(*) FROM (SELECT g FROM generate_series(1, 2000000) g ORDER BY g DESC) s;
SET temp_file_limit = -1;
SELECT 'after';
SQL
)
check "P6 a sort past the temp file limit fails, and the app cannot raise the limit" \
  eval 'echo "$out" | grep -q "temporary file size exceeds .\{0,1\}temp_file_limit" &&
        echo "$out" | grep -q "permission denied to set parameter \"temp_file_limit\"" && echo "$out" | grep -qx after'
# P7. a migration raises the timeout for itself: SET for the session, SET LOCAL for a transaction
out=$(psql_in tando_notes "$pw" tando_notes <<'SQL'
BEGIN;
SET LOCAL statement_timeout = '20s';
SELECT pg_sleep(2);
SELECT 'local done';
COMMIT;
SHOW statement_timeout;
SET statement_timeout = 0;
SELECT pg_sleep(2);
SELECT 'session done';
SQL
)
check "P7 SET LOCAL and SET statement_timeout let a 2 s statement through; after COMMIT it is 1s again" \
  eval '! echo "$out" | grep -q cancel && echo "$out" | grep -qx "local done" && echo "$out" | grep -qx 1s &&
        echo "$out" | grep -qx "session done"'
# P8. tando db psql (a person at a prompt): the two timeouts are off, the temp file limit stays
out=$(echo 'SHOW statement_timeout; SHOW idle_in_transaction_session_timeout; SHOW temp_file_limit;' |
  srv "sudo $AGENT db-psql notes" 2>&1)
check "P8 db psql: timeouts 0, temp_file_limit 4MB ($(echo "$out" | grep -c '^ 0$') zeros)" \
  eval '[ "$(echo "$out" | grep -c "^ 0\$")" = 2 ] && echo "$out" | grep -q "^ 4MB\$"'
# P9. a backup that takes longer than the app's statement_timeout: pg_dump waits 5 s for a table
# lock (one statement, 1s limit for the role) and still succeeds
pgsu tando_notes > /dev/null <<'SQL' &
BEGIN; LOCK TABLE notes IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(7); COMMIT;
SQL
locked() { [ "$(echo "SELECT count(*) FROM pg_locks WHERE mode = 'AccessExclusiveLock' AND granted AND relation = 'notes'::regclass" | pgsu tando_notes)" = 1 ]; }
T_UNTIL_STEP=0.2 t_until 10 locked
out=$(psql_as tando_notes "$pw" tando_notes 'SELECT count(*) FROM notes')
t0=$SECONDS
idl=$("$R" backup now 2>&1 | sed -n 's/^backed up [a-z0-9-]*: \([^ ]*\).*/\1/p')
took=$((SECONDS - t0))
wait
check "P9a the app's own query on the locked table is cancelled at 1s" \
  eval 'echo "$out" | grep -q "canceling statement due to statement timeout"'
check "P9b backup now waited ${took}s for the lock (over the 1s limit) and succeeded: $idl" \
  eval '[ "$took" -ge 3 ] && echo "$idl" | grep -qE "^[0-9]{8}-[0-9]{6}-manual$" &&
        srv "sudo test -s $BK/notes/$idl/db.dump"'
# P10. a restore builds indexes through temporary files (18 MB here, the app's limit is 4 MB):
# the limit is lifted for the restore and is back after it
pgsu tando_notes > /dev/null <<'SQL'
SET ROLE tando_notes;
CREATE TABLE big AS SELECT g, md5(g::text) AS t FROM generate_series(1, 500000) g;
CREATE INDEX big_t ON big (t);
SQL
idb=$("$R" backup now 2>&1 | sed -n 's/^backed up [a-z0-9-]*: \([^ ]*\).*/\1/p')
"$R" backup restore "$idb" --yes > "$E/restore-big.out" 2>&1; rc=$?; cat "$E/restore-big.out" >&2
out=$(psql_in tando_notes "$pw" tando_notes <<'SQL'
SET statement_timeout = 0;
SELECT 'rows ' || count(*) FROM big;
SELECT 'index ' || count(*) FROM pg_indexes WHERE indexname = 'big_t';
SHOW temp_file_limit;
SQL
)
check "P10a restore of a database with a large index succeeds under a 4 MB temp limit (rc=$rc, $(page))" \
  eval '[ $rc = 0 ] && echo "$out" | grep -qx "rows 500000" && echo "$out" | grep -qx "index 1" &&
        [ "$(page)" = "notes v2 db=3 file=3" ]'
check "P10b the limit is back after the restore (4MB)" eval 'echo "$out" | grep -qx 4MB'
echo "DROP TABLE big" | psql_in tando_notes "$pw" tando_notes > /dev/null

# D7-D9. backup now, destroy the data, restore. pg_dump and pg_restore are stand-ins meanwhile that
# log their cgroup (check B1) and run the real ones
srv 'sudo tee /usr/local/bin/pg_dump > /dev/null && sudo chmod 755 /usr/local/bin/pg_dump &&
     sudo ln -sf pg_dump /usr/local/bin/pg_restore' <<'WRAP'
#!/bin/sh
p=${0##*/}
logger -t tando-test-pgcg "$p $(cat /proc/self/oom_score_adj) $(cat /proc/self/cgroup)"
exec /usr/bin/$p "$@"
WRAP
id=$("$R" backup now 2>&1 | sed -n 's/^backed up [a-z0-9-]*: \([^ ]*\).*/\1/p')
check "D7 backup now: $id" eval 'echo "$id" | grep -qE "^[0-9]{8}-[0-9]{6}-manual$"'
psql_as tando_notes "$pw" tando_notes 'DELETE FROM notes' > /dev/null
srv "sudo -u tando-notes rm /opt/tando/apps/notes/shared/data/notes.log"
check "D8 data destroyed ($(page))" test "$(page)" = "notes v2 db=0 file=0"
"$R" backup restore "$id" --yes > "$E/restore.out" 2>&1; rc=$?; cat "$E/restore.out" >&2
check "D9a restore brings back the database and the file ($(page))" test $rc = 0 -a "$(page)" = "notes v2 db=3 file=3"
check "D9b a safety backup of the replaced data exists" eval '"$R" backup ls | grep -q " safety "'
srv 'sudo rm -f /usr/local/bin/pg_dump /usr/local/bin/pg_restore'
# B1. they ran in the app's slice (its memory limits) with the app's OOMScoreAdjust (500), not in
# the ssh session's
cg() { srv 'sudo journalctl -q -o cat -t tando-test-pgcg'; }
t_until 10 eval 'cg | grep -q "^pg_restore "' || true
cg=$(cg)
check "B1 pg_dump and pg_restore ran in tando-notes.slice, oom_score_adj 500 ($(echo "$cg" | grep -v "tando-notes.slice" | head -1 | cut -c1-100))" \
  eval 'echo "$cg" | grep -q "^pg_dump 500 0::/tando.slice/tando-notes.slice/" &&
        echo "$cg" | grep -q "^pg_restore 500 0::/tando.slice/tando-notes.slice/" &&
        ! echo "$cg" | grep -v "^pg_[a-z]* 500 0::/tando.slice/tando-notes.slice/" | grep -q .'

# D9c. a restore whose database step fails (pg_restore stand-in: exit 1) is a cut restore: tando
# status shows one line (the database restore was cut, the backup to restore again with its
# command, the safety backup) and tando ls marks the app; a restore that ends clears both
printf '#!/bin/sh\nexit 1\n' | srv 'sudo tee /usr/local/bin/pg_restore > /dev/null && sudo chmod 755 /usr/local/bin/pg_restore'
"$R" backup restore "$id" --yes > "$E/restore-cut.out" 2>&1; rcc=$?; cat "$E/restore-cut.out" >&2
check "D9c a restore whose database step fails ends with an error (rc=$rcc)" test "$rcc" != 0
COLUMNS=220 "$R" status notes > "$E/cut-status.out" 2>&1; cat "$E/cut-status.out" >&2
COLUMNS=220 "$R" ls > "$E/cut-ls.out" 2>&1; cat "$E/cut-ls.out" >&2
check "D9d status shows the cut restore: the database, the backup to restore again, the safety backup" \
  eval 'grep -q "restore.*database restore was cut: tando backup restore $id " "$E/cut-status.out" &&
        grep -q "safety .*data from before it is in backup [0-9]*-[0-9]*-safety" "$E/cut-status.out"'
check "D9e ls marks the app with a cut restore" eval 'grep -q "notes: the database restore was cut: tando status notes" "$E/cut-ls.out"'
srv 'sudo rm -f /usr/local/bin/pg_restore'
"$R" backup restore "$id" --yes > "$E/restore-again.out" 2>&1; rc=$?; cat "$E/restore-again.out" >&2
COLUMNS=220 "$R" status notes > "$E/cut-status2.out" 2>&1; COLUMNS=220 "$R" ls > "$E/cut-ls2.out" 2>&1
check "D9f restoring again works (rc=$rc, $(page)) and status and ls no longer show a cut restore" \
  eval '[ $rc = 0 ] && [ "$(page)" = "notes v2 db=3 file=3" ] && ! grep -q "restore was cut" "$E/cut-status2.out" "$E/cut-ls2.out"'

# D9g. a restore of an app stopped on purpose (tando stop) leaves it stopped: the data restored, the
# unit inactive and disabled, the state stopped, Caddy's stopped page; tando start brings it back
kept_stopped() { # file for the page
  curl -s -o "$1" -w '%{http_code}' -m 5 "http://notes.localhost:$HP/" | grep -qx 503 && grep -q "notes is stopped" "$1" &&
    ! srv "systemctl -q is-active tando-notes" && ! srv "systemctl -q is-enabled tando-notes" &&
    srv "sudo grep -qx stopped=1 /opt/tando/apps/notes/state && sudo grep -qx phase=idle /opt/tando/apps/notes/state"
}
nrows() { psql_as tando_notes "$pw" tando_notes "SELECT count(*) FROM notes"; }
psql_as tando_notes "$pw" tando_notes 'DELETE FROM notes' > /dev/null
"$R" stop >&2
"$R" backup restore "$id" --yes > "$E/restore-stopped.out" 2>&1; rc=$?; cat "$E/restore-stopped.out" >&2
check "D9g a restore of a stopped app restores the data and leaves it stopped (rc=$rc, $(nrows) rows)" \
  eval '[ $rc = 0 ] && [ "$(nrows)" = 3 ] && kept_stopped "$E/stopped1.body" && grep -q "notes stays stopped" "$E/restore-stopped.out"'
# D9h. the same restore cut off (the agent killed as it ends: fault point rs.start), ended by
# recovery (what tando-watch and a boot run): the app stays stopped too
psql_as tando_notes "$pw" tando_notes 'DELETE FROM notes' > /dev/null
srv "sudo install -m 644 -o root -g root /dev/null /etc/tando-test-server && sudo install -d -m 700 -o root -g root /run/tando-test &&
     printf 'point=rs.start\naction=kill\nnth=1\nverb=backup-restore\napp=notes\n' | sudo tee /run/tando-test/fault > /dev/null"
"$R" backup restore "$id" --yes > "$E/restore-stopped-cut.out" 2>&1; rcc=$?; cat "$E/restore-stopped-cut.out" >&2
fired=$(srv "sudo test -f /run/tando-test/fired && echo yes")
srv "sudo rm -rf /run/tando-test /etc/tando-test-server"
srv "sudo $AGENT recover notes" >&2
check "D9h a restore of a stopped app cut off (rc=$rcc, fault fired: ${fired:-no}) and recovered leaves it stopped, data restored ($(nrows) rows)" \
  eval '[ "$fired" = yes ] && [ $rcc != 0 ] && [ "$(nrows)" = 3 ] && kept_stopped "$E/stopped2.body"'
"$R" start >&2
check "D9i tando start brings it back with the restored data" t_until 30 eval '[ "$(page)" = "notes v2 db=3 file=3" ]'

# D9j. a backup cut off (kill, reboot) leaves its temp directory: doctor names it; recover-all
# removes it, but not while the app's lock is held (a backup being written holds it); the next
# backup of the app removes one too
tmpd=$BK/notes/.20260101-000000-manual.tmp
srv "sudo mkdir -m 700 $tmpd && sudo touch $tmpd/data.tar.gz"
COLUMNS=250 "$R" doctor > "$E/doctor-tmp.out" 2>&1; cat "$E/doctor-tmp.out" >&2
check "D9j doctor names a backup temp directory a cut-off backup left" grep -q "notes.*unfinished backup temp directory" "$E/doctor-tmp.out"
srv "sudo flock /opt/tando/apps/notes/lock sh -c 'touch /run/tando-test-held; while [ -e /run/tando-test-held ]; do sleep 0.2; done'" > /dev/null 2>&1 &
hp=$!
t_until 20 eval 'srv "test -e /run/tando-test-held"'
srv "sudo $AGENT recover-all" > /dev/null 2>&1
kept=$(srv "sudo test -d $tmpd && echo yes")
srv "sudo rm -f /run/tando-test-held"; wait $hp
srv "sudo $AGENT recover-all" > /dev/null 2>&1
gone=$(srv "sudo test -e $tmpd || echo yes")
check "D9k recover-all removes it once nothing holds the app's lock (kept while held: ${kept:-no}, removed after: ${gone:-no})" \
  test "$kept/$gone" = yes/yes
srv "sudo mkdir -m 700 $tmpd"
"$R" backup now > "$E/bk-tmp.out" 2>&1; rc=$?; cat "$E/bk-tmp.out" >&2
gone=$(srv "sudo test -e $tmpd || echo yes")
check "D9l the next backup removes it too (rc=$rc, removed: ${gone:-no})" test "$rc/$gone" = 0/yes
# D9m. backup-run outlives a dropped ssh session (Ctrl-C at the laptop): its output pipe closes,
# and the agent's next write (here the warning about a file the app made unreadable) must not end
# it half way, with the backup never finished and its temp directory left
srv "sudo -u tando-notes sh -c 'echo x > /opt/tando/apps/notes/shared/data/locked && chmod 000 /opt/tando/apps/notes/shared/data/locked'"
srv "sudo bash -c '$AGENT backup-run notes manual 2>&1 | true'"
done_bk=$(srv "sudo sh -c 'grep -l ^warning=.*locked $BK/notes/*/meta' 2> /dev/null | wc -l | tr -d ' '")   # (root's glob: the directory is 700)
left=$(srv "sudo ls -A $BK/notes | grep -c '^\..*\.tmp\$'")
check "D9m a backup whose ssh session dropped finishes (backups with the warning: $done_bk, temp dirs left: $left)" \
  test "$done_bk/$left" = 1/0
srv "sudo rm -f /opt/tando/apps/notes/shared/data/locked"

# D10. pull a backup to the laptop
"$R" backup pull "$id" "$E/pulled.tar" > /dev/null 2>&1
check "D10 backup pull: a tar with data.tar.gz and db.dump" \
  eval 'tar -tf "$E/pulled.tar" | grep -q data.tar.gz && tar -tf "$E/pulled.tar" | grep -q db.dump'
mode=$(ls -l "$E/pulled.tar" | cut -c1-10)
check "D10b the pulled backup is readable by its owner only ($mode)" test "$mode" = "-rw-------"

# D11. daily timer and status
# (one queue for every app's daily backup: the host's timer starts the app's backup unit)
check "D11a the daily backup: the host's queue timer is enabled, the app has its backup unit and no timer of its own" \
  eval 'srv "systemctl is-enabled -q tando-backups.timer && test -f /etc/systemd/system/tando-notes-backup.service &&
            ! test -e /etc/systemd/system/tando-notes-backup.timer"'
srv "sudo systemctl start tando-backups.service" > /dev/null 2>&1
check "D11c the queue backs the app up (backup-all; backup_daily_ok in its state)" \
  eval 'srv "sudo grep -q ^backup_daily_ok= /opt/tando/apps/notes/state"'
COLUMNS=100 "$R" status > "$E/status.out" 2>&1; cat "$E/status.out" >&2
check "D11b status shows the database and the last backup" \
  eval 'grep -q "database.*postgres" "$E/status.out" && grep -q "backup.*daily, last" "$E/status.out"'

# D11d. the restore drill: the newest backup restored into a throwaway database and directory
# shellcheck disable=SC2034  # (read in the check's eval)
page_before=$(page)
# what an app can put in its own dump to get more than its own rights when the drill restores it as
# a superuser: an index on its function (run as the table's owner during the restore), and a
# function named like a built-in that the row count would call (format(text, name, name) beats
# pg_catalog's VARIADIC one). Both only fail inside a drill database, never in the live one
psql_in tando_notes "$pw" tando_notes > "$E/probe.out" <<'SQL'
CREATE FUNCTION public.drill_probe(x int) RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF current_database() LIKE '%drill%' THEN
    IF (SELECT rolsuper FROM pg_catalog.pg_roles WHERE rolname = current_user) THEN RAISE EXCEPTION 'PROBE the drill restores as a superuser'; END IF;
    IF has_database_privilege('public', current_database(), 'CONNECT') THEN RAISE EXCEPTION 'PROBE the drill database is open to PUBLIC'; END IF;
  END IF;
  RETURN x;
END $$;
CREATE TABLE drill_probe_t (x int);
INSERT INTO drill_probe_t VALUES (1);
CREATE INDEX drill_probe_i ON drill_probe_t (public.drill_probe(x));
CREATE FUNCTION public.format(f text, a name, b name) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  IF current_database() LIKE '%drill%' THEN RAISE EXCEPTION 'PROBE the drill called the app''s format()'; END IF;
  RETURN pg_catalog.format(f, a, b);
END $$;
SQL
cat "$E/probe.out" >&2
"$R" backup now > /dev/null 2>&1
LIVE_SQL="SELECT coalesce(sum((xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', schemaname, tablename), false, true, '')))[1]::text::bigint), 0) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema')"
live_before=$(echo "$LIVE_SQL" | pgsu tando_notes | tail -1)
"$R" backup drill > "$E/drill.out" 2>&1; rc=$?
live_after=$(echo "$LIVE_SQL" | pgsu tando_notes | tail -1)
cat "$E/drill.out" >&2
check "D11d backup drill restores the newest backup and reports it (rc=$rc; it holds an index on an app function and an app format())" \
  eval 'test $rc = 0 && grep -q "tables, $live_before rows" "$E/drill.out" && grep -q "drill .*ok" "$E/drill.out"'
check "D11e ... the live database was not touched (rows $live_before -> $live_after) and the live data stays" \
  eval 'test "$live_before" = "$live_after" && test "$live_before" -ge 1 && test "$(page)" = "$page_before"'
check "D11f ... the throwaway database and directory are gone" \
  eval 'test "$(echo "select count(*) from pg_database where datname like '"'"'%drill%'"'"'" | pgsu postgres | tail -1)" = 0 &&
        test "$(srv "sudo ls -A /opt/tando/apps/notes/shared | grep -c drill")" = 0'
"$R" backup ls > "$E/bkls.out" 2>&1; "$R" backup ls --json > "$E/bkls.json" 2>&1
check "D11g backup ls shows the last drill (text and --json)" \
  eval 'grep -q "restore drill: .*ok" "$E/bkls.out" && grep -q "\"drill\":{\"at\":[0-9]*,\"result\":\"ok\"" "$E/bkls.json"'
check "D11h the host runs a drill monthly: tando-drill.timer on the 1st, five minutes after the backup window opens" \
  eval 'srv "systemctl is-enabled -q tando-drill.timer" && srv "systemctl cat tando-drill.timer" | grep -qx "OnCalendar=\*-\*-01 01:05:00"'
dall=$(srv "sudo $AGENT backup-drill-all" 2> /dev/null | tr '\n' ' ')
check "D11i backup-drill-all drills every app with daily backups ($dall)" eval 'case $dall in drilled=[1-9]" failed=0 ") true;; *) false;; esac'
# a backup that does not restore: the drill says so, the state keeps it (the alert and doctor read it)
"$R" backup now > "$E/bk-bad.out" 2>&1
idb=$(sed -n 's/^backed up [a-z0-9-]*: \([^ ]*\).*/\1/p' "$E/bk-bad.out")
srv "sudo sh -c 'head -c 200 $BK/notes/$idb/db.dump > $BK/notes/$idb/db.cut && mv $BK/notes/$idb/db.cut $BK/notes/$idb/db.dump'"
"$R" backup drill > "$E/drill-bad.out" 2>&1; rc=$?
check "D11j a backup that does not restore: the drill fails, names why and exits non-zero (rc=$rc)" \
  eval 'test $rc != 0 && grep -q "drill .*failed" "$E/drill-bad.out" && grep -q "pg_restore" "$E/drill-bad.out"'
check "D11k ... the failure is in the state (the alert reads it), the throwaway database is gone, doctor warns" \
  eval 'srv "sudo grep -qx drill_result=fail /opt/tando/apps/notes/state" &&
        test "$(echo "select count(*) from pg_database where datname like '"'"'%drill%'"'"'" | pgsu postgres | tail -1)" = 0 &&
        srv "sudo $AGENT doctor" 2> /dev/null | grep "app notes" | grep -q "restore drill failed"'
srv "sudo rm -rf $BK/notes/$idb"
"$R" backup now > /dev/null 2>&1; "$R" backup drill > "$E/drill-ok2.out" 2>&1
check "D11l the next drill that works clears it" \
  eval 'srv "sudo grep -qx drill_result=ok /opt/tando/apps/notes/state" && ! srv "sudo $AGENT doctor" 2> /dev/null | grep "app notes" | grep -q "restore drill"'
# D11o. the throwaway database is never another app's: an app drill-notes has tando_drill_notes
echo "CREATE DATABASE tando_drill_notes" | pgsu postgres > /dev/null
echo "CREATE TABLE keep (x int); INSERT INTO keep VALUES (1);" | pgsu tando_drill_notes > /dev/null
"$R" backup drill > "$E/drill-o.out" 2>&1; rc=$?
check "D11o a drill of notes (rc=$rc) leaves tando_drill_notes alone (the database of an app drill-notes)" \
  test "$(echo 'SELECT count(*) FROM keep' | pgsu tando_drill_notes | tail -1)" = 1
echo "DROP DATABASE tando_drill_notes" | pgsu postgres > /dev/null
# D11p. a database with the drill's own name that a drill did not make: never dropped, the drill fails
echo "CREATE DATABASE tdrill_notes" | pgsu postgres > /dev/null
echo "CREATE TABLE keep (x int); INSERT INTO keep VALUES (1);" | pgsu tdrill_notes > /dev/null
"$R" backup drill > "$E/drill-p.out" 2>&1; rc=$?
cat "$E/drill-p.out" >&2
check "D11p a database tdrill_notes not made by a drill: the drill fails (rc=$rc), says why and leaves it" \
  eval 'test $rc != 0 && grep -q "not a restore drill" "$E/drill-p.out" && test "$(echo "SELECT count(*) FROM keep" | pgsu tdrill_notes | tail -1)" = 1'
echo "DROP DATABASE tdrill_notes" | pgsu postgres > /dev/null
# D11q. an archive that unpacks far larger than it is (it compressed well): the listed size counts,
# and a disk that cannot hold it (with 256 MB to spare) is refused before anything is unpacked
"$R" backup now > "$E/bk-big.out" 2>&1
idg=$(sed -n 's/^backed up [a-z0-9-]*: \([^ ]*\).*/\1/p' "$E/bk-big.out")
freek=$(srv "df -Pk /opt/tando/apps | awk 'NR == 2 { print \$4 }'")
srv "sudo sh -c 'd=\$(mktemp -d) && truncate -s $((freek + 1048576))K \$d/big && tar -C \$d -cSzf $BK/notes/$idg/data.tar.gz big && rm -rf \$d'"
"$R" backup drill > "$E/drill-q.out" 2>&1; rc=$?
cat "$E/drill-q.out" >&2
check "D11q a backup that unpacks to more than the free disk: refused before unpacking (rc=$rc)" \
  eval 'test $rc != 0 && grep -q "not enough free disk space" "$E/drill-q.out" && test "$(srv "sudo ls -A /opt/tando/apps/notes/shared | grep -c drill")" = 0'
srv "sudo rm -rf $BK/notes/$idg"
"$R" backup drill > /dev/null 2>&1
check "D11r ... and the drill of the newest good backup works again" srv "sudo grep -qx drill_result=ok /opt/tando/apps/notes/state"
echo "DROP TABLE drill_probe_t; DROP FUNCTION public.drill_probe(int); DROP FUNCTION public.format(text, name, name);" | psql_in tando_notes "$pw" tando_notes > /dev/null

# D12. retention: 7 daily plus 4 weekly
srv "for d in \$(seq 1 40); do i=\$(date -u -d \"-\$d days\" +%Y%m%d)-030000-daily; sudo mkdir -p $BK/notes/\$i;
  echo created=0 | sudo tee $BK/notes/\$i/meta > /dev/null; done"
srv "sudo $AGENT backup-run notes daily" > /dev/null
n=$(srv "sudo ls $BK/notes | grep -c -- '-daily$'")
check "D12 retention keeps 7 daily + 4 weekly of 41 ($n)" test "$n" = 11

# D13. root does not follow links the app plants in its data
srv "sudo -u tando-notes ln -s /etc/shadow /opt/tando/apps/notes/shared/data/secret"
id2=$("$R" backup now 2>&1 | sed -n 's/^backed up [a-z0-9-]*: \([^ ]*\).*/\1/p')
listing=$(srv "sudo tar -tvzf $BK/notes/$id2/data.tar.gz")
check "D13 a planted symlink is archived as a link, not as the file it points to" \
  eval 'echo "$listing" | grep -q "secret -> /etc/shadow"'

# D14. sqlite: a file inside data, path in DATABASE_PATH, backed up with the data
rm -rf "${W:?}/hsql"; cp -R "$ROOT/examples/hello" "$W/hsql"
printf 'app = hsql\nrecipe = node\nstart = node server.js\nhealth = /health\ndatabase = sqlite\n' > "$W/hsql/tando.conf"
(cd "$W/hsql" && "$R" up > "$E/hsql.out" 2>&1)
pid=$(srv "systemctl show -P MainPID tando-hsql")
check "D14 database = sqlite: DATABASE_PATH in data, daily backup on" \
  eval 'srv "sudo cat /proc/$pid/environ" | tr "\\0" "\\n" |
        grep -qx DATABASE_PATH=/opt/tando/apps/hsql/shared/data/app.sqlite &&
        srv "test -f /etc/systemd/system/tando-hsql-backup.service"'

# D16. PostgreSQL slots: an app without database = postgres cannot reach 5432 at all (it could
# hold every connection slot by never answering the password request); the app with a database
# still can; a client that stalls in authentication is dropped after 5 s; one role holds at most 10
pgtry() { srv "sudo systemd-run --quiet --wait --pipe --collect -p User=$1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/${2:-5432} && echo open || echo refused' 2> /dev/null"; }
check "D16a hsql (sqlite) cannot connect to 127.0.0.1:5432 ($(pgtry tando-hsql))" test "$(pgtry tando-hsql)" = refused
check "D16b notes (postgres) can ($(pgtry tando-notes))" test "$(pgtry tando-notes)" = open
check "G12 nor to pgbouncer's 6432 ($(pgtry tando-hsql 6432)); notes can ($(pgtry tando-notes 6432))" \
  eval '[ "$(pgtry tando-hsql 6432)" = refused ] && [ "$(pgtry tando-notes 6432)" = open ]'
check "D16c authentication_timeout 5s, role connection limit 10" \
  eval '[ "$(srv "sudo -u postgres psql -At -c \"SHOW authentication_timeout\"")" = 5s ] &&
        [ "$(srv "sudo -u postgres psql -At -c \"SELECT rolconnlimit FROM pg_roles WHERE rolname = '"'"'tando_notes'"'"'\"")" = 10 ]'

# D17. database = postgres added to an app already live without one: the live release has no
# database to back up (no pre-deploy dump), and the new release reaches its DATABASE_URL from the
# pre-flight on (the database, its role and the loopback rule for the app's user come first)
rm -rf "${W:?}/hpg"; cp -R "$ROOT/examples/hello" "$W/hpg"
printf 'app = hpg\nrecipe = node\nstart = node server.js\nhealth = /health\n' > "$W/hpg/tando.conf"
(cd "$W/hpg" && "$R" up > "$E/hpg1.out" 2>&1)
echo 'database = postgres' >> "$W/hpg/tando.conf"
(cd "$W/hpg" && "$R" up > "$E/hpg2.out" 2>&1); rc=$?; tail -5 "$E/hpg2.out" >&2
pid=$(srv "systemctl show -P MainPID tando-hpg")
hurl=$(srv "sudo cat /proc/$pid/environ" | tr '\0' '\n' | sed -n 's/^DATABASE_URL=//p')
hres=none; [ -n "$hurl" ] &&
  hres=$(srv "sudo systemd-run --quiet --wait --pipe --collect -p User=tando-hpg psql -X -At '$hurl' -c 'SELECT 1'" 2>&1 | tail -1)
check "D17 database added to a deployed app: the deploy passes (rc=$rc, no pre-deploy dump), the new release's DATABASE_URL answers as its user ($hres)" \
  eval '[ $rc = 0 ] && ! grep -q "pre-deploy backup failed" "$E/hpg2.out" && [ "$hres" = 1 ]'

# S4 (F2, F2b). a symlink the app plants for shared/data is refused, never followed by root
srv "sudo -u tando-notes sh -c 'cd /opt/tando/apps/notes/shared && mv data data.real && ln -s /etc/systemd/system data'"
echo 3 > "$W/notes/VERSION"
(cd "$W/notes" && "$R" deploy > "$E/s4.out" 2>&1); rc=$?; cat "$E/s4.out" >&2
own=$(srv "stat -c %U:%G:%a /etc/systemd/system")
check "S4a deploy refuses a symlinked shared/data (rc=$rc), /etc/systemd/system stays $own" \
  eval '[ $rc != 0 ] && grep -q "shared/data is not a directory" "$E/s4.out" && [ "$own" = root:root:755 ]'
(cd "$W/notes" && "$R" backup restore "$id" --yes > "$E/s4r.out" 2>&1); rc=$?; cat "$E/s4r.out" >&2
own2=$(srv "stat -c %U:%G:%a /etc/systemd/system;
  sudo find /etc/systemd/system -maxdepth 1 -newer /opt/tando/apps/notes/app.conf -user tando-notes | wc -l" | tr '\n' ' ')
check "S4b restore refuses it too and writes nothing there (rc=$rc, $own2)" \
  eval '[ $rc != 0 ] && [ "$own2" = "root:root:755 0 " ]'
srv "sudo -u tando-notes sh -c 'cd /opt/tando/apps/notes/shared && rm data && mv data.real data'"
# (this deploy also carries new limits for P11: one off, one changed, one back to its default)
{ cat "$E/tando.conf.orig"; printf 'db_statement_timeout = off\ndb_idle_tx_timeout = 10m\n'; } > "$W/notes/tando.conf"
(cd "$W/notes" && "$R" deploy > /dev/null 2>&1); rc=$?
check "S4c after the link is gone, deploys work again (rc=$rc, $(page))" test $rc = 0

# P11. off, an override, and a setting taken out of tando.conf (back to the default)
(cd "$W/notes" && "$R" db) > "$E/db2.out" 2>&1; cat "$E/db2.out" >&2
out=$(psql_in tando_notes "$pw" tando_notes <<'SQL'
SELECT pg_sleep(2);
SHOW statement_timeout;
SQL
)
check "P11 db_statement_timeout = off (a 2 s query runs), idle 10min, temp files 1GB again" \
  eval 'grep -q "statement timeout *off" "$E/db2.out" && grep -q "idle in transaction *10min" "$E/db2.out" &&
        grep -q "temporary files *1GB" "$E/db2.out" && ! echo "$out" | grep -q cancel && echo "$out" | grep -qx 0'

# P12. the PostgreSQL version is recorded and kept. A newer major appears (its configuration
# directory, as after a distribution upgrade); host setup runs again
echo "ALTER ROLE tando_notes2 RESET ALL" | pgsu postgres > /dev/null   # an app from before the limits
srv "sudo mkdir -p /etc/postgresql/99/main/conf.d"
pm1=$(srv "head -1 /run/postgresql/$pv-main.pid")
"$R" host setup test public_port=$HP postgres=yes > "$E/setup2.out" 2>&1; rc=$?; cat "$E/setup2.out" >&2
check "P12a host setup with a newer version beside it: tando stays on $pv (rc=$rc), nothing written for 99" \
  eval '[ $rc = 0 ] && srv "grep -qx postgres_version=$pv /opt/tando/host.conf" &&
        srv "sudo test ! -e /etc/postgresql/99/main/conf.d/tando.conf" && grep -q "postgresql $pv" "$E/setup2.out"'
check "P12b doctor says a newer version is there and that tando does not switch" \
  eval 'pg_rows version | grep -q "^check.warn.*PostgreSQL 99 is on this server too. tando keeps using $pv/main"'
check "P12c host setup again did not restart PostgreSQL (pid $pm1), the app answers ($(page))" \
  eval '[ "$(srv "head -1 /run/postgresql/$pv-main.pid")" = "$pm1" ] && [ "$(page)" = "notes v3 db=3 file=3" ]'
(cd "$W/notes2" && "$R" db) > "$E/db3.out" 2>&1
check "P12d host setup gave an app without limits (set up by an older tando) the defaults" \
  eval 'grep -q "statement timeout *30s" "$E/db3.out" && grep -q "temporary files *1GB" "$E/db3.out"'
srv "sudo rm -rf /etc/postgresql/99"
check "P12e without the newer version the doctor row is ok again" \
  eval 'pg_rows version | grep -q "^check.ok.*$pv/main"'
# G9-G10. a new max_connections on a server whose apps have databases waits for the owner's yes
# (a restart drops every app's connections): PostgreSQL runs with 37 here, tando's file says otherwise
pgpid() { srv "head -1 /run/postgresql/$pv-main.pid"; }
srv "sudo sed -i 's/^max_connections = .*/max_connections = 37/' /etc/postgresql/$pv/main/conf.d/tando.conf && sudo systemctl restart postgresql"
T_UNTIL_STEP=0.5 t_until 30 srv "pg_isready -q -h 127.0.0.1"
# shellcheck disable=SC2034  # (read in the check's eval)
pm2=$(pgpid)
"$R" host setup test public_port=$HP > "$E/setup3.out" 2>&1; rc=$?; cat "$E/setup3.out" >&2
check "G9 host setup (rc=$rc): max_connections $mc waits, PostgreSQL not restarted (still $(pgshow max_connections)); the step says --pg-restart; doctor warns" \
  eval '[ $rc = 0 ] && [ "$(pgpid)" = "$pm2" ] && [ "$(pgshow max_connections)" = 37 ] &&
        tr -d "│\n " < "$E/setup3.out" | grep -q "keepsitsoldmax_connectionsuntilarestart.*--pg-restart" &&
        pg_rows settings | grep -q "^check.warn.*max_connections wait for a restart"'
"$R" host setup test public_port=$HP --pg-restart --yes > "$E/setup4.out" 2>&1; rc=$?; cat "$E/setup4.out" >&2
T_UNTIL_STEP=0.5 t_until 30 eval '[ "$(page)" = "notes v3 db=3 file=3" ]'
check "G10 host setup --pg-restart (rc=$rc): restarted, max_connections $(pgshow max_connections); the app answers ($(page)); no warning" \
  eval '[ $rc = 0 ] && [ "$(pgpid)" != "$pm2" ] && [ "$(pgshow max_connections)" = "$mc" ] &&
        [ "$(page)" = "notes v3 db=3 file=3" ] && ! pg_rows settings | grep -q warn'
# R. the release command (release = in tando.conf) with database = postgres: DATABASE_URL is set
# for it and a migration that creates a table works; a failing one fails the deploy and names the
# pre-deploy backup, which the owner can restore (tando itself restores nothing)
cat > "$W/notes/migrate.js" <<'EOF'
// creates the table "migrated" and records the version and who ran it; with the shipped file
// MIGRATE it creates the table "half", deletes every note and then fails
const fs = require('fs');
const { Client } = require('pg');
if (!process.env.DATABASE_URL) { console.error('DATABASE_URL is not set'); process.exit(2); }
(async () => {
  const c = new Client({ connectionString: process.env.DATABASE_URL });
  await c.connect();
  if (fs.existsSync('MIGRATE')) {
    await c.query('CREATE TABLE IF NOT EXISTS half (x int)');
    await c.query('DELETE FROM notes');
    throw new Error('migration 0002 failed on purpose');
  }
  await c.query('CREATE TABLE IF NOT EXISTS migrated (v text, uid int, port text)');
  await c.query('INSERT INTO migrated VALUES ($1, $2, $3)', [fs.readFileSync('VERSION', 'utf8').trim(), process.getuid(), new URL(process.env.DATABASE_URL).port]);
  await c.end();
  console.log('migrated');
})().catch((e) => { console.error(e.message); process.exit(1); });
EOF
cd "$W/notes" || exit 2
echo "release = node migrate.js" >> tando.conf
echo 4 > VERSION
"$R" deploy > "$E/rel1.out" 2>&1; rc=$?; cat "$E/rel1.out" >&2
uidn=$(srv "id -u tando-notes"); : "$uidn"   # (read inside the check's eval string)
got=$(psql_as tando_notes "$pw" tando_notes 'SELECT v, uid, port FROM migrated')
check "R1 release command with database = postgres (rc=$rc): DATABASE_URL was set (PostgreSQL's own, 5432), the migration created its table as the app's user ($got)" \
  eval '[ $rc = 0 ] && [ -n "$uidn" ] && [ "$uidn" != 0 ] && [ "$got" = "4|$uidn|5432" ] && [ "$(page)" = "notes v4 db=3 file=3" ]'
half() { psql_as tando_notes "$pw" tando_notes "SELECT count(*) FROM pg_tables WHERE tablename = 'half'"; }
echo fail > MIGRATE; echo 5 > VERSION
"$R" deploy > "$E/rel2.out" 2>&1; rc=$?; cat "$E/rel2.out" >&2
bk=$(tr -d '│\n' < "$E/rel2.out" | tr -s ' ' | grep -oE 'backup [0-9]{8}-[0-9]{6}-predeploy' | head -1 | cut -d' ' -f2)
check "R2 a failing migration fails the deploy (rc=$rc), v4 keeps serving ($(page)); what it did to the database stays: tando restores nothing (half=$(half))" \
  eval '[ $rc != 0 ] && [ "$(page)" = "notes v4 db=0 file=3" ] && [ "$(half)" = 1 ]'
check "R3 the failure names the pre-deploy backup (${bk:-none}), which holds the database" \
  eval '[ -n "$bk" ] && srv "sudo test -s $BK/notes/$bk/db.dump"'
"$R" backup restore "$bk" --yes > "$E/rel-restore.out" 2>&1; rc=$?; cat "$E/rel-restore.out" >&2
# (a restore brings back what the backup holds; a table created after it, "half", is not dropped)
check "R4 the owner restores it by hand (rc=$rc): the rows the command deleted are back ($(page))" \
  eval '[ $rc = 0 ] && [ "$(page)" = "notes v4 db=3 file=3" ] &&
        [ "$(psql_as tando_notes "$pw" tando_notes "SELECT count(*) FROM migrated")" = 1 ]'

# G5-G7. per app: db_direct = true (PostgreSQL's own port), db_pool (pgbouncer's pool and the
# role's limit), and the pools together against max_connections
cd "$W/notes2" || exit 2
cp tando.conf "$E/notes2.conf"
echo 'db_direct = true' >> tando.conf; echo 7 > VERSION
"$R" deploy > "$E/g5.out" 2>&1; rc=$?; tail -3 "$E/g5.out" >&2
check "G5 db_direct = true (rc=$rc): DATABASE_URL is PostgreSQL's own (5432), the app answers ($(page notes2))" \
  eval '[ $rc = 0 ] && penv notes2 DATABASE_URL | grep -q "@127.0.0.1:5432/tando_notes2$" && page notes2 | grep -q "^notes v7"'
cp "$E/notes2.conf" tando.conf; echo 'db_pool = 7' >> tando.conf; echo 8 > VERSION
"$R" deploy > "$E/g6.out" 2>&1; rc=$?; tail -3 "$E/g6.out" >&2
# shellcheck disable=SC2034  # (read in the check's eval)
ini=$(srv "sudo cat /etc/pgbouncer/pgbouncer.ini")
lim=$(srv "sudo -u postgres psql -X -At -c \"SELECT rolconnlimit FROM pg_roles WHERE rolname = 'tando_notes2'\"")
check "G6 db_pool = 7, db_direct gone (rc=$rc): on pgbouncer again with a pool of 7, the role's limit 12 ($lim), the app answers" \
  eval '[ $rc = 0 ] && penv notes2 DATABASE_URL | grep -q "@127.0.0.1:6432/tando_notes2$" &&
        echo "$ini" | grep -qx "tando_notes2 = host=127.0.0.1 port=5432 dbname=tando_notes2 pool_size=7 max_db_connections=7" &&
        [ "$lim" = 12 ] && page notes2 | grep -q "^notes v8"'
{ cat "$E/notes2.conf"; echo 'db_pool = 999'; } > tando.conf; echo 9 > VERSION
"$R" deploy > "$E/g7.out" 2>&1; rc=$?; cat "$E/g7.out" >&2
check "G7 db_pool = 999 is refused (rc=$rc): the pools would pass max_connections; it says what to do; v8 serves" \
  eval '[ $rc != 0 ] && tr -d "│\n " < "$E/g7.out" | grep -q "PostgreSQLhasforthem.*smallerdb_pool" && page notes2 | grep -q "^notes v8"'
{ cat "$E/notes2.conf"; echo 'db_pool = 7'; } > tando.conf
cd "$W/notes" || exit 2

# D15. destroy keeps a final backup and drops the database
echo notes2 | (cd "$W/notes2" && "$R" destroy) > "$E/destroy.out" 2>&1; rc=$?; cat "$E/destroy.out" >&2
gone=$(srv "sudo -u postgres psql -At -c \"SELECT count(*) FROM pg_database WHERE datname = 'tando_notes2'\"")
check "D15 destroy: final backup kept, database dropped (rc=$rc, db left: $gone)" \
  eval '[ $rc = 0 ] && [ "$gone" = 0 ] && srv "sudo ls $BK/notes2" | grep -q -- "-final$"'
check "G8 destroy took tando_notes2 out of pgbouncer (its user and its database); tando_notes stays" \
  eval '! srv "sudo grep -q tando_notes2 /etc/pgbouncer/userlist.txt /etc/pgbouncer/pgbouncer.ini" &&
        srv "sudo grep -q tando_notes /etc/pgbouncer/pgbouncer.ini"'

# D16. backup_drill = off: no timer, and the host's run does nothing (last: host setup runs again here)
"$R" host setup test backup_drill=off > /dev/null 2>&1
check "D11m host setup backup_drill=off removes the timer; backup-drill-all then drills nothing" \
  eval '! srv "systemctl is-enabled -q tando-drill.timer" && test "$(srv "sudo $AGENT backup-drill-all" 2> /dev/null | head -1)" = drilled=0'
"$R" host setup test backup_drill=monthly > /dev/null 2>&1
check "D11n ... and monthly puts it back" srv "systemctl is-enabled -q tando-drill.timer"

echo
cat "$E/pgmem"
echo "$FAILS failed"
[ $FAILS -eq 0 ]
