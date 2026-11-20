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

# D2. up creates the role, database and DATABASE_URL; the app answers
"$R" up > "$E/up.out" 2>&1; rc=$?; cat "$E/up.out" >&2
check "D2 up with database = postgres: app answers ($(page))" test "$(page)" = "notes v1 db=0 file=0"

# D3. the password stays on the server
"$R" env ls > "$E/envls.out" 2>&1; cat "$E/envls.out" >&2
check "D3a env ls masks the database password" grep -q 'postgres://tando_notes:\*\*\*\*@127.0.0.1' "$E/envls.out"
"$R" db url > "$E/url1.out" 2>&1; rc=$?
check "D3b db url without --show is refused" eval '[ $rc != 0 ] && grep -q -- "--show" "$E/url1.out"'
url=$("$R" db url --show)
pw=${url#postgres://tando_notes:}; pw=${pw%%@*}
check "D3c db url --show prints the URL" \
  eval 'echo "$url" | grep -q "^postgres://tando_notes:[0-9a-f]\{48\}@127.0.0.1:5432/tando_notes$"'
check "D3d the password is not stored on the laptop" \
  eval '! grep -rq "$pw" "$TANDO_CONFIG_DIR" "$W/notes" --exclude-dir=node_modules 2> /dev/null'

# D4. the role reaches only its own database
rm -rf "${W:?}/notes2"; cp -R "$W/notes" "$W/notes2"
sed 's/^app = notes$/app = notes2/' "$W/notes/tando.conf" > "$W/notes2/tando.conf"
(cd "$W/notes2" && "$R" up > "$E/up2.out" 2>&1)
check "D4a own database: connect works" test "$(psql_as tando_notes "$pw" tando_notes 'SELECT 1')" = 1
out=$(psql_as tando_notes "$pw" tando_notes2 'SELECT 1')
check "D4b another app's database: refused ($(echo "$out" | tail -1))" eval 'echo "$out" | grep -q "permission denied"'
out=$(psql_as tando_notes "$pw" postgres 'SELECT 1')
check "D4c the postgres database: refused" eval 'echo "$out" | grep -q "permission denied"'

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

# D7-D9. backup now, destroy the data, restore
id=$("$R" backup now 2>&1 | sed -n 's/^backed up [a-z0-9-]*: \([^ ]*\).*/\1/p')
check "D7 backup now: $id" eval 'echo "$id" | grep -qE "^[0-9]{8}-[0-9]{6}-manual$"'
psql_as tando_notes "$pw" tando_notes 'DELETE FROM notes' > /dev/null
srv "sudo -u tando-notes rm /opt/tando/apps/notes/shared/data/notes.log"
check "D8 data destroyed ($(page))" test "$(page)" = "notes v2 db=0 file=0"
"$R" backup restore "$id" --yes > "$E/restore.out" 2>&1; rc=$?; cat "$E/restore.out" >&2
check "D9a restore brings back the database and the file ($(page))" test $rc = 0 -a "$(page)" = "notes v2 db=3 file=3"
check "D9b a safety backup of the replaced data exists" eval '"$R" backup ls | grep -q " safety "'

# D10. pull a backup to the laptop
"$R" backup pull "$id" "$E/pulled.tar" > /dev/null 2>&1
check "D10 backup pull: a tar with data.tar.gz and db.dump" \
  eval 'tar -tf "$E/pulled.tar" | grep -q data.tar.gz && tar -tf "$E/pulled.tar" | grep -q db.dump'
mode=$(ls -l "$E/pulled.tar" | cut -c1-10)
check "D10b the pulled backup is readable by its owner only ($mode)" test "$mode" = "-rw-------"

# D11. daily timer and status
check "D11a the daily backup timer is enabled" eval 'srv "systemctl is-enabled -q tando-notes-backup.timer"'
COLUMNS=100 "$R" status > "$E/status.out" 2>&1; cat "$E/status.out" >&2
check "D11b status shows the database and the last backup" \
  eval 'grep -q "database.*postgres" "$E/status.out" && grep -q "backup.*daily, last" "$E/status.out"'

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
        srv "systemctl is-enabled -q tando-hsql-backup.timer"'

# D16. PostgreSQL slots: an app without database = postgres cannot reach 5432 at all (it could
# hold every connection slot by never answering the password request); the app with a database
# still can; a client that stalls in authentication is dropped after 5 s; one role holds at most 10
pgtry() { srv "sudo systemd-run --quiet --wait --pipe --collect -p User=$1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/5432 && echo open || echo refused' 2> /dev/null"; }
check "D16a hsql (sqlite) cannot connect to 127.0.0.1:5432 ($(pgtry tando-hsql))" test "$(pgtry tando-hsql)" = refused
check "D16b notes (postgres) can ($(pgtry tando-notes))" test "$(pgtry tando-notes)" = open
check "D16c authentication_timeout 5s, role connection limit 10" \
  eval '[ "$(srv "sudo -u postgres psql -At -c \"SHOW authentication_timeout\"")" = 5s ] &&
        [ "$(srv "sudo -u postgres psql -At -c \"SELECT rolconnlimit FROM pg_roles WHERE rolname = '"'"'tando_notes'"'"'\"")" = 10 ]'

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
(cd "$W/notes" && "$R" deploy > /dev/null 2>&1); rc=$?
check "S4c after the link is gone, deploys work again (rc=$rc, $(page))" test $rc = 0

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
  await c.query('CREATE TABLE IF NOT EXISTS migrated (v text, uid int)');
  await c.query('INSERT INTO migrated VALUES ($1, $2)', [fs.readFileSync('VERSION', 'utf8').trim(), process.getuid()]);
  await c.end();
  console.log('migrated');
})().catch((e) => { console.error(e.message); process.exit(1); });
EOF
cd "$W/notes" || exit 2
echo "release = node migrate.js" >> tando.conf
echo 4 > VERSION
"$R" deploy > "$E/rel1.out" 2>&1; rc=$?; cat "$E/rel1.out" >&2
uidn=$(srv "id -u tando-notes"); : "$uidn"   # (read inside the check's eval string)
got=$(psql_as tando_notes "$pw" tando_notes 'SELECT v, uid FROM migrated')
check "R1 release command with database = postgres (rc=$rc): DATABASE_URL was set, the migration created its table as the app's user ($got)" \
  eval '[ $rc = 0 ] && [ -n "$uidn" ] && [ "$uidn" != 0 ] && [ "$got" = "4|$uidn" ] && [ "$(page)" = "notes v4 db=3 file=3" ]'
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

# D15. destroy keeps a final backup and drops the database
echo notes2 | (cd "$W/notes2" && "$R" destroy) > "$E/destroy.out" 2>&1; rc=$?; cat "$E/destroy.out" >&2
gone=$(srv "sudo -u postgres psql -At -c \"SELECT count(*) FROM pg_database WHERE datname = 'tando_notes2'\"")
check "D15 destroy: final backup kept, database dropped (rc=$rc, db left: $gone)" \
  eval '[ $rc = 0 ] && [ "$gone" = 0 ] && srv "sudo ls $BK/notes2" | grep -q -- "-final$"'

echo
cat "$E/pgmem"
echo "$FAILS failed"
[ $FAILS -eq 0 ]
