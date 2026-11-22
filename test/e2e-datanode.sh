#!/bin/bash
# test/e2e-datanode.sh: a stateless app node with its PostgreSQL on a data node (docs/DATA-NODE.md),
# on two test servers. host setup role=data (PostgreSQL and pgbouncer on the node's address with
# TLS), the firewall and pg_hba before and after tando host link, an app's role and database made
# on the data node from here (never with the data node's superuser on the app node), TLS
# verify-full against the pinned CA, pg_hba refusing another address, the per-role limits
# enforced, backup and restore and the restore drill through the remote database, and destroy
# dropping the project there.
#
# Servers: A (the app node) = TANDO_TEST_NAME, B (the data node) = TANDO_TEST_NAME2 (default <A>b,
# ssh and http ports + 50). Uses examples/notes (needs npm); installs PostgreSQL on B and
# its client on A. Usage: test/e2e-datanode.sh
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-datanode
N2=${TANDO_TEST_NAME2:-${T_NAME}b} P2=${TANDO_TEST_SSH_PORT2:-$((T_SSH_PORT + 50))} H2=${TANDO_TEST_HTTP_PORT2:-$((T_HTTP_PORT + 50))}
W=$E/w
srv() { "$SSH" "$@"; }
srvB() { TANDO_TEST_NAME=$N2 TANDO_TEST_SSH_PORT=$P2 "$SSH" "$@"; }
page() { curl -s -m 5 "http://notes.localhost:$T_HTTP_PORT/"; }
addnote() { curl -s -m 5 -X POST "http://notes.localhost:$T_HTTP_PORT/notes?text=$1" > /dev/null; }
bsql() { srvB "sudo -u postgres psql -X -At ${2:+-d $2} -c \"$1\"" 2>&1; }   # sql [database]
# envv KEY: a value of the app's env on A
envv() { srv "sudo sed -n 's/^$1=\"\\(.*\\)\"\$/\\1/p' /opt/tando/apps/notes/env"; }
created_b=0
cleanup() {
  [ "$created_b" = 1 ] && [ "${TANDO_TEST_KEEP:-0}" != 1 ] && TANDO_TEST_NAME=$N2 "$ROOT/test/server/down.sh" > /dev/null 2>&1
  return 0
}
trap cleanup EXIT

command -v npm > /dev/null || { skip "dn0 npm is needed for examples/notes"; t_done; }

# ---- the two servers ---------------------------------------------------------------------------
t_server_up --reset || exit 1
docker container inspect "$N2" > /dev/null 2>&1 || created_b=1
TANDO_TEST_NAME=$N2 TANDO_TEST_SSH_PORT=$P2 TANDO_TEST_HTTP_PORT=$H2 "$ROOT/test/server/up.sh" --reset >&2 || exit 1
AIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$T_NAME")
BIP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$N2")
log "app node $AIP, data node $BIP"
mkdir -p "$W"
rsync -a --exclude node_modules "$ROOT/examples/notes/" "$W/notes/"
cd "$W/notes" || exit 1
npm ci --no-audit --no-fund > "$E/npm.out" 2>&1 || { cat "$E/npm.out" >&2; exit 1; }
t_host_add a
"$R" host add b vmadmin@127.0.0.1 --port "$P2" --key "$ROOT/test/server/id_test" --yes >&2
printf 'host = a\ndb_statement_timeout = 2s\ndb_pool = 1\n' >> tando.conf

# ---- the data node -------------------------------------------------------------------------------
"$R" host setup b role=data > "$E/setupB.out" 2>&1; rc=$?; cat "$E/setupB.out" >&2
check "dn1 host setup role=data: PostgreSQL on every address with TLS, pgbouncer on 6432 with TLS (rc=$rc)" \
  eval '[ $rc = 0 ] && [ "$(bsql "SHOW listen_addresses")" = "*" ] && [ "$(bsql "SHOW ssl")" = on ] &&
        srvB "ss -Hltn sport = :6432" | grep -qE "(0\.0\.0\.0|\*):6432" &&
        srvB "sudo grep -qx \"client_tls_sslmode = allow\" /etc/pgbouncer/pgbouncer.ini" &&
        srvB "sudo openssl x509 -noout -ext subjectAltName -in /etc/tando-data/server.pem" | grep -q "IP Address:$BIP" &&
        tr -d "│\n " < "$E/setupB.out" | grep -q "pgbouncer6432withTLS"'
"$R" host setup a public_port="$T_HTTP_PORT" > "$E/setupA.out" 2>&1 || { cat "$E/setupA.out" >&2; exit 1; }

# an app node that is not linked: the data node's firewall resets it (both ports)
tcp_from_a() { srv "timeout 4 bash -c '</dev/tcp/$BIP/$1' 2>/dev/null && echo open || echo closed"; }
check "dn2 before host link: 5432 and 6432 of the data node are closed to the app node" \
  eval '[ "$(tcp_from_a 5432)" = closed ] && [ "$(tcp_from_a 6432)" = closed ]'

"$R" host link a b > "$E/link.out" 2>&1; rc=$?; cat "$E/link.out" >&2
check "dn3 host link: the app node reaches 5432 and 6432, pins the data node's CA, records db_host (rc=$rc)" \
  eval '[ $rc = 0 ] && [ "$(tcp_from_a 5432)" = open ] && [ "$(tcp_from_a 6432)" = open ] &&
        [ "$(srv "sudo cat /opt/tando/db-ca.pem" | openssl x509 -noout -fingerprint -sha256)" = "$(srvB "sudo cat /etc/tando-data/ca.pem" | openssl x509 -noout -fingerprint -sha256)" ] &&
        srv "grep -qx db_host=b /opt/tando/host.conf && grep -qx db_addr=$BIP /opt/tando/host.conf"'

# ---- an app with database = postgres on the app node ------------------------------------------
"$R" up > "$E/up.out" 2>&1; rc=$?; cat "$E/up.out" >&2
addnote one; addnote two
url=$(envv DATABASE_URL) direct=$(envv DATABASE_URL_DIRECT)
check "dn4 tando up: notes runs on A with its database on B ($(page)); no PostgreSQL server on A (rc=$rc)" \
  eval '[ $rc = 0 ] && [ "$(page)" = "notes v1 db=2 file=2" ] && ! srv "test -d /etc/postgresql" &&
        [ "$(bsql "SELECT count(*) FROM pg_database WHERE datname IN ('"'"'tando_notes'"'"', '"'"'tdrill_notes'"'"')")" = 2 ] &&
        case $url in "postgres://tando_notes:"*"@$BIP:6432/tando_notes?sslmode=verify-full&sslrootcert=/opt/tando/db-ca.pem") true;; *) false;; esac &&
        case $direct in *"@$BIP:5432/tando_notes?sslmode=verify-full"*) true;; *) false;; esac'
check "dn5 the data node's superuser is nowhere on the app node (no postgres user, no password of it)" \
  eval '! srv "getent passwd postgres" > /dev/null && ! srv "sudo grep -rqs postgres:// /opt/tando/host.conf /opt/tando/db-ca.pem"'
# the app's own sessions on B are TLS (through pgbouncer, and pgbouncer to PostgreSQL is local)
pw=${url#postgres://tando_notes:}; pw=${pw%%@*}
apsql() { srv "PGPASSWORD=$pw PGCONNECT_TIMEOUT=5 psql -X -At \"$1\" -c \"$2\"" 2>&1; }
export dsn="host=$BIP port=5432 dbname=tando_notes user=tando_notes"   # (read inside eval)
mkca() { openssl req -x509 -new -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 1 -subj /CN=other -keyout /dev/null 2> /dev/null; }
mkca | srv "cat > ~/other-ca.pem"
check "dn6 TLS verify-full: the pinned CA and the node's address pass; another CA, another name, and no TLS are refused" \
  eval '[ "$(apsql "$dsn sslmode=verify-full sslrootcert=/opt/tando/db-ca.pem" "SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()")" = t ] &&
        apsql "$dsn sslmode=verify-full sslrootcert=$(srv "echo ~")/other-ca.pem" "SELECT 1" | grep -q "certificate verify failed" &&
        apsql "$dsn hostaddr=$BIP host=db.invalid sslmode=verify-full sslrootcert=/opt/tando/db-ca.pem" "SELECT 1" | grep -qi "does not match" &&
        apsql "$dsn sslmode=disable" "SELECT 1" | grep -q "no pg_hba.conf entry"'
# pg_hba: the role, with its right password and TLS, from an address that is not its app node's
check "dn7 pg_hba refuses the project's role from an unlinked address (the data node's own $BIP)" \
  eval 'srvB "PGPASSWORD=$pw PGCONNECT_TIMEOUT=5 psql -X -At \"host=$BIP dbname=tando_notes user=tando_notes sslmode=require\" -c \"SELECT 1\"" 2>&1 |
        grep -q "no pg_hba.conf entry for host \"$BIP\""'
check "dn8 the app node's firewall: only apps with a database reach the data node (per-uid rules for $BIP)" \
  eval 'srv "sudo nft list table inet tando" | grep -q "ip daddr $BIP meta skuid .* tcp dport { 5432, 6432 }"'

# ---- the per-role limits, enforced on the data node ---------------------------------------------
check "dn9 the role's limits on B: connection limit db_pool + 5, statement and idle timeouts, temp limit" \
  eval '[ "$(bsql "SELECT rolconnlimit FROM pg_roles WHERE rolname = '"'"'tando_notes'"'"'")" = 6 ] &&
        [ "$(bsql "SELECT array_to_string(setconfig, '"'"' '"'"') FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole WHERE r.rolname = '"'"'tando_notes'"'"' AND s.setdatabase = 0")" = "statement_timeout=2s idle_in_transaction_session_timeout=5min temp_file_limit=1GB" ]'
check "dn10 statement_timeout enforced: a 4 s statement of the app's role is cancelled after 2 s" \
  eval 'apsql "$direct" "SELECT pg_sleep(4)" | grep -q "canceling statement due to statement timeout"'
# 8 sessions at once against a limit of 6 (pgbouncer may hold one of them for the app)
srv "for i in 1 2 3 4 5 6 7 8; do PGPASSWORD=$pw psql -X -At \"$direct\" -c \"SET statement_timeout = 0; SELECT pg_sleep(4)\" > ~/conn.\$i 2>&1 & done; wait; cat ~/conn.*" > "$E/conns.out" 2>&1
check "dn11 connection limit enforced: sessions over the role's limit are refused ($(grep -c 'too many connections' "$E/conns.out") of 8)" \
  eval 'grep -q "too many connections for role \"tando_notes\"" "$E/conns.out"'

# ---- the data node's own bounds, the catalog, re-link, the certificate (security review) -------
# limits come from this tando.conf and the data node's bounds, never off there
printf 'db_temp_limit = off\n' >> tando.conf
"$R" up > "$E/up-off.out" 2>&1; rc=$?; cat "$E/up-off.out" >&2
sed -i.bak '/^db_temp_limit = off$/d' tando.conf && rm -f tando.conf.bak
check "dn16 db_temp_limit = off is refused by the data node; the role keeps its 1GB (rc=$rc)" \
  eval '[ $rc != 0 ] && grep -q "cannot be off on a data node" "$E/up-off.out" &&
        bsql "SELECT array_to_string(setconfig, '"'"' '"'"') FROM pg_db_role_setting s JOIN pg_roles r ON r.oid = s.setrole WHERE r.rolname = '"'"'tando_notes'"'"' AND s.setdatabase = 0" | grep -q "temp_file_limit=1GB"'
check "dn17 no other role may use the project's schema public (only the catalog's names are shared)" \
  eval '[ "$(bsql "SELECT has_schema_privilege('"'"'public'"'"', '"'"'public'"'"', '"'"'USAGE'"'"')" tando_notes)" = f ]'
"$R" host link a b app_addr=192.0.2.50 > "$E/relink.out" 2>&1; rc=$?; cat "$E/relink.out" >&2
check "dn18 linking the app node's name from another address is refused while it has projects (rc=$rc)" \
  eval '[ $rc != 0 ] && grep -q -- "--move" "$E/relink.out" && srvB "sudo grep -qx addr=$AIP /opt/tando/data/nodes/a"'
check "dn19 the data node's certificate: tando doctor shows the days left, renewed by a daily timer" \
  eval 'srvB "sudo /opt/tando/bin/tando-agent doctor" 2> /dev/null | grep -q "data node certificate.*days left.*tando-data-renew.timer" &&
        srvB "systemctl is-enabled tando-data-renew.timer" | grep -qx enabled'
check "dn20 the role's password is in no PostgreSQL log on the data node" \
  eval '! srvB "sudo grep -rqs -- $pw /var/log/postgresql"'
"$R" host setup b role=data data_conn_per_node=10 > "$E/setupB2.out" 2>&1 || cat "$E/setupB2.out" >&2
srv "sudo bash -c 'for i in \$(seq 16); do (exec 3<>/dev/tcp/$BIP/5432 && sleep 3) 2> /dev/null || echo refused & done; wait'" > "$E/cap.out" 2>&1
check "dn21 one app node holds at most data_conn_per_node connections to the data node ($(grep -c refused "$E/cap.out") of 16 refused at 10)" \
  eval 'cnt=$(grep -c refused "$E/cap.out"); [ "$cnt" -ge 5 ] && [ "$cnt" -le 12 ]'   # (some refused, the first ones not)

# ---- backup, restore and the restore drill through the remote database -----------------------
id=$("$R" backup now 2>&1 | sed -n 's/^backed up [a-z0-9-]*: \([^ ]*\).*/\1/p')
addnote three
check "dn12 backup: the dump of the database on B is in the app node's backup ($id; now $(page))" \
  eval '[ -n "$id" ] && srv "sudo test -s /var/backups/tando/notes/$id/db.dump" && [ "$(page)" = "notes v1 db=3 file=3" ]'
"$R" backup restore "$id" --yes > "$E/restore.out" 2>&1; rc=$?; cat "$E/restore.out" >&2
check "dn13 restore: the database on B is back as it was at the backup ($(page), rc=$rc)" \
  eval '[ $rc = 0 ] && [ "$(page)" = "notes v1 db=2 file=2" ]'
"$R" backup drill > "$E/drill.out" 2>&1; rc=$?; cat "$E/drill.out" >&2
# (the newest backup is the restore's safety backup: three notes)
check "dn14 restore drill: restored into tdrill_notes on B with the app's own role, then emptied (rc=$rc)" \
  eval '[ $rc = 0 ] && tr -d "│" < "$E/drill.out" | grep -q "1 tables, 3 rows" &&
        [ "$(bsql "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = '"'"'public'"'"' AND c.relkind = '"'"'r'"'"'" tdrill_notes)" = 0 ]'

# ---- destroy: the project goes from the data node too --------------------------------------------
"$R" destroy --yes > "$E/destroy.out" 2>&1; rc=$?; cat "$E/destroy.out" >&2
check "dn15 destroy: role, database and drill database dropped on B, its pg_hba line and record gone (rc=$rc)" \
  eval '[ $rc = 0 ] && [ "$(bsql "SELECT count(*) FROM pg_roles WHERE rolname = '"'"'tando_notes'"'"'")" = 0 ] &&
        [ "$(bsql "SELECT count(*) FROM pg_database WHERE datname LIKE '"'"'%notes'"'"'")" = 0 ] &&
        ! srvB "sudo grep -q tando_notes /etc/postgresql/*/main/pg_hba.conf /etc/pgbouncer/hba.tando" &&
        ! srvB "sudo test -e /opt/tando/data/db/notes"'
# ---- a compromised app node cannot aim provisioning or a drop at another project ------------------
# B also holds "shop" of another app node, c; A then claims to be c
srvB "sudo /opt/tando/bin/tando-agent data-link c 192.0.2.99 && sudo /opt/tando/bin/tando-agent data-db ensure shop c" > /dev/null 2>&1
hash0=$(bsql "SELECT rolpassword FROM pg_authid WHERE rolname = 'tando_shop'")
srv "sudo sed -i 's/^db_node=a\$/db_node=c/' /opt/tando/host.conf"
rsync -a "$W/notes/" "$W/shop/" && sed -i.bak 's/^app = notes$/app = shop/' "$W/shop/tando.conf" && rm -f "$W/shop/tando.conf.bak"
(cd "$W/shop" && "$R" up) > "$E/up-evil.out" 2>&1; rc=$?; cat "$E/up-evil.out" >&2
shop_pw() { bsql "SELECT rolpassword FROM pg_authid WHERE rolname = 'tando_shop'"; }
evil_up() { [ "$1" != 0 ] && grep -q REFUSED "$E/up-evil.out" && [ -n "$hash0" ] && [ "$(shop_pw)" = "$hash0" ]; }
check "dn22 an app node reporting another node's identity: tando up refused, the other project's password unchanged (rc=$rc)" evil_up "$rc"
(cd "$W/shop" && "$R" destroy --yes) > "$E/destroy-evil.out" 2>&1; rc=$?; cat "$E/destroy-evil.out" >&2
evil_destroy() { [ "$1" != 0 ] && grep -q REFUSED "$E/destroy-evil.out" && [ "$(bsql "SELECT count(*) FROM pg_database WHERE datname = 'tando_shop'")" = 1 ]; }
check "dn23 and tando destroy is refused before anything goes: the other project's database stays (rc=$rc)" evil_destroy "$rc"
srv "sudo sed -i 's/^db_node=c\$/db_node=a/' /opt/tando/host.conf"
t_done
