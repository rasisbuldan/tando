#!/bin/bash
# test/e2e-studio.sh: tando db studio (lib/studio.sh, the agent's db-studio verbs, srv/studio) on a
# test server with PostgreSQL: the always-on service of host setup (docs/STUDIO.md), its front and
# its per-app helpers. The page's API is driven with curl through the client's own ssh forward
# (curl is this harness's tool, not the client's); the helpers run with shorter limits from
# /opt/tando/studio.test (a 4 s statement limit, a few seconds of idle time) so the lifecycle
# checks take seconds. Every attempt to write is checked as the postgres superuser: the data
# must be unchanged.
#
#   S1  start: the service installed, enabled and running; the link, /healthz and its probe word,
#       the page and its CSP, read-only, one helper as the app's user without capabilities, the
#       front with CAP_SETUID/CAP_SETGID only, no TCP listener, the sockets' modes
#   S2  refusals: no or a wrong token, a used or foreign code, foreign Host/Origin/Sec-Fetch-Site,
#       a form post, a preflight
#   S3  read-only: every bypass known (the review's and more), each across one and two requests;
#       the app's own sessions cannot be signalled, the settings not changed through U& or SQL text
#   S4  limits: 5M rows, a 20 MB cell, the studio's own clock, SET LOCAL timeout, nothing runaway
#   S5  cancel; S6 browsing; S7 the end of a session in every way (Stop, Ctrl-C ends the forward
#       and not the service, idle, --stop and a restart revoke every token, two clients at once,
#       --json), the service's memory when idle; S8 CI keys (four layers); S9 no database, not
#       installed, an old agent, the old client's verb, sshd without stream forwarding, destroy;
#       S10 the password and a secret cell never in the journal, the audit log or a process list;
#       S11 pgwire and the studio against this server's PostgreSQL (Go tests built for its CPU);
#       S12 doctor; S13 the backend's scoping (settings, priority, a heavy query's memory, a
#       migration's lock wait, no snapshot between requests); S9s/t/i connection slots and the
#       idle connection; S14 isolation of two apps and the switcher's routes; S15 the picker;
#       S16 scope: the app's own tables only (no system schema listed or served, every way to a
#       system relation refused in the editor, the demo's tables and everyday SQL still work)
# shellcheck disable=SC2034 # (values set here are read inside the eval strings of checks)
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-studio
t_server_up --reset || exit 1
SP=$T_SSH_PORT HP=$T_HTTP_PORT
srv() { "$SSH" "$@"; }
W=$E/w
mkdir -p "$W"
unset TANDO_DEPLOY_KEY TANDO_HOST TANDO_PORT TANDO_KNOWN_HOSTS
export TANDO_NO_BROWSER=1 TANDO_STUDIO_HB=1

# ---- helpers ----------------------------------------------------------------------------------
# st_start <out> <app> [args]: the client in the background (SIGINT left at its default, as in a
# terminal: a background job of a script would ignore it); waits for the link and trades its code
# for the token -> ST_PID ST_PORT ST_CODE ST_TOKEN ST_APP
st_start() {
  local o=$1 a=$2 url; shift 2
  ST_TOKEN="" ST_PORT="" ST_CODE="" ST_APP=""
  perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die' "$R" db studio -a "$a" --no-open "$@" > "$o" 2>&1 &
  ST_PID=$!
  T_UNTIL_STEP=0.2 t_until 30 eval 'grep -q "^http://127.0.0.1:" "$o" || ! kill -0 $ST_PID 2> /dev/null' || return 1
  url=$(grep '^http://127.0.0.1:' "$o" | head -1)
  [ -n "$url" ] || { cat "$o" >&2; return 1; }
  ST_PORT=${url#http://127.0.0.1:}; ST_PORT=${ST_PORT%%/*}; ST_CODE=${url#*#c=}; ST_APP=${ST_CODE#*&app=}; ST_CODE=${ST_CODE%%&*}
  ST_TOKEN=$(curl -s -m 5 -H 'Content-Type: application/json' --data "{\"code\":\"$ST_CODE\"}" \
    "http://127.0.0.1:$ST_PORT/api/session" | sed -n 's/.*"token":"\([A-Za-z0-9_-]*\)".*/\1/p')
  [ -n "$ST_TOKEN" ]
}
# api <path> [json] [curl args...]: the studio's API with the token -> $E/body, HTTP status in CODE
api() {
  local p=$1 d=${2:-}
  shift; [ $# -gt 0 ] && shift
  if [ -n "$d" ]; then
    CODE=$(curl -s -m 60 -o "$E/body" -w '%{http_code}' -H "Authorization: Bearer $ST_TOKEN" \
      -H 'Content-Type: application/json' --data-binary "$d" "$@" "http://127.0.0.1:$ST_PORT$p")
  else
    CODE=$(curl -s -m 60 -o "$E/body" -w '%{http_code}' -H "Authorization: Bearer $ST_TOKEN" "$@" "http://127.0.0.1:$ST_PORT$p")
  fi
}
jenc() { perl -MJSON::PP -e 'print JSON::PP->new->canonical->encode({id => $ARGV[0], sql => $ARGV[1], max_rows => $ARGV[2] + 0})' "$@"; }
# q <sql> [max rows] [id]: run in the editor; the answer in $E/body
q() { api /api/query "$(jenc "${3:-q1}" "$1" "${2:-1000}")"; }
# jx <perl expression, % for the answer>: a value of the last answer ($E/body); % instead of $j
# keeps it safe inside a check's eval
jx() { perl -MJSON::PP -e 'local $/; open my $f, "<", $ARGV[1] or exit; my $j = eval { decode_json(<$f>) } || {}; (my $e = $ARGV[0]) =~ s/%/\$j/g; my $v = eval $e; print defined $v ? $v : ""' "$1" "$E/body"; }
qerr() { jx '%->{error}{sqlstate}'; }   # the error's SQLSTATE of the last answer ("" when none)
pgsu() { srv "sudo -u postgres psql -X -At -v ON_ERROR_STOP=1 -d ${1:-tando_shop}" 2>&1; }   # SQL on stdin
DATASUM="SELECT (SELECT md5(string_agg(t::text, ',' ORDER BY id)) FROM items t) || ' ' ||
  (SELECT md5(string_agg(t::text, ',' ORDER BY id)) FROM secrets t) || ' ' || (SELECT md5(big) FROM wide) || ' ' ||
  (SELECT last_value FROM s) || ' ' || (SELECT count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace) || ' ' ||
  (SELECT count(*) FROM pg_largeobject_metadata) || ' ' || (SELECT count(*) FROM pg_prepared_xacts)"
datasum() { echo "$DATASUM" | pgsu tando_shop; }
knobs() { echo "$1" | srv "sudo tee /opt/tando/studio.test > /dev/null"; }   # the helpers' test limits
helpers() { srv "pgrep -f '^/opt/tando/bin/tando-studio serve --fd' | grep -c ." 2> /dev/null; }   # helpers running
helper_pid() { srv "pgrep -u tando-${1:-shop} -f '^/opt/tando/bin/tando-studio serve --fd' | head -1"; }
front_pid() { srv "systemctl show -P MainPID tando-studio.service"; }
db_scopes() { srv "systemctl list-units --plain --no-legend --all 'tando-*-studiodb-*' | grep -c ."; }
left_now() { # the service runs on; no helper, no studio connection, no lowered scope, no forward
  [ "$(helpers)" = 0 ] && [ "$(db_scopes)" = 0 ] && srv "systemctl is-active -q tando-studio.service" &&
  [ "$(echo "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'tando studio%'" | pgsu postgres)" = 0 ]
}
# nothing_left: within 20 s (a helper ends after its idle time: 8 s here, 120 s for real)
nothing_left() {
  T_UNTIL_STEP=0.5 t_until 20 left_now && return 0
  srv "systemctl status --no-pager tando-studio.service | head -20; pgrep -af tando-studio; systemctl list-units --all --plain --no-legend 'tando-*-studiodb-*'" >&2
  echo "SELECT pid, usename, state, application_name FROM pg_stat_activity WHERE application_name LIKE 'tando studio%'" | pgsu postgres >&2
  return 1
}
st_wait_exit() { T_UNTIL_STEP=0.2 t_until "${1:-15}" eval '! kill -0 $ST_PID 2> /dev/null'; wait "$ST_PID" 2> /dev/null; }

# ---- the server, two apps with a database, data --------------------------------------------
t_host_add test
"$R" host setup test public_port=$HP postgres=yes > "$E/setup.out" 2>&1 || { cat "$E/setup.out" >&2; fail "0 host setup postgres=yes"; t_done; }
mk_app() { # name [nodb]
  rm -rf "${W:?}/$1"; cp -R "$ROOT/examples/hello" "$W/$1"
  sed "s/^app = .*/app = $1/" "$ROOT/examples/hello/tando.conf" > "$W/$1/tando.conf"
  [ "${2:-}" = nodb ] || echo "database = postgres" >> "$W/$1/tando.conf"
  (cd "$W/$1" && "$R" up > "$E/up.$1.out" 2>&1)
}
mk_app shop; mk_app other; mk_app plain nodb
check "0 three apps up (shop and other with a database)" eval 'srv "sudo test -f /opt/tando/apps/shop/app.conf && sudo test -f /opt/tando/apps/other/app.conf"'
CANARY="cell-canary-$$-$RANDOM"
pgsu tando_shop > "$E/seed.out" <<SQL
CREATE TABLE items (id bigint PRIMARY KEY, name text, note text, doc jsonb, blob bytea, n numeric, flag bool, created timestamptz);
INSERT INTO items SELECT i, 'item ' || i, CASE WHEN i % 10 = 0 THEN NULL WHEN i % 10 = 1 THEN '' ELSE repeat('n', i % 50) END,
  jsonb_build_object('i', i, 'tags', jsonb_build_array('a', 'b')), decode(md5(i::text), 'hex'), i * 1.5, i % 2 = 0,
  '2026-01-01'::timestamptz + i * interval '1 minute' FROM generate_series(1, 100000) i;
CREATE TABLE secrets (id int PRIMARY KEY, v text); INSERT INTO secrets VALUES (1, '$CANARY'), (2, '<img src=x onerror=alert(1)>');
CREATE TABLE wide (id int PRIMARY KEY, big text); INSERT INTO wide SELECT 1, repeat('w', 20 * 1024 * 1024);
CREATE TABLE "x""<b>" (id int PRIMARY KEY, v text); INSERT INTO "x""<b>" VALUES (1, '</script><b>hi</b>');
CREATE SEQUENCE s; CREATE VIEW items_v AS SELECT id, name FROM items;
CREATE OR REPLACE PROCEDURE p() LANGUAGE sql AS 'DELETE FROM items WHERE id = 2';
ANALYZE;
DO \$\$ DECLARE r text; BEGIN FOR r IN SELECT format('%I', tablename) FROM pg_tables WHERE schemaname = 'public' LOOP
  EXECUTE 'ALTER TABLE ' || r || ' OWNER TO tando_shop'; END LOOP; END \$\$;
ALTER SEQUENCE s OWNER TO tando_shop; ALTER VIEW items_v OWNER TO tando_shop; ALTER PROCEDURE p() OWNER TO tando_shop;
SQL
OCANARY="other-canary-$$-$RANDOM"
echo "CREATE TABLE other_secret (v text); INSERT INTO other_secret VALUES ('$OCANARY'); ALTER TABLE other_secret OWNER TO tando_other;" | pgsu tando_other > /dev/null
SUM0=$(datasum)
check "0 seeded: 100,000 rows, a secret, a 20 MB cell ($SUM0)" eval '[ -n "$SUM0" ] && ! grep -q ERROR "$E/seed.out"'
PW=$("$R" db url -a shop --show); PW=${PW#postgres://tando_shop:}; PW=${PW%%@*}
PW2=$("$R" db url -a other --show); PW2=${PW2#postgres://tando_other:}; PW2=${PW2%%@*}
check "0 the app's password is known to the test (the canary for S10)" eval '[ ${#PW} -ge 32 ]'
T0=$(srv date +%s)

# ---- S1 start ----------------------------------------------------------------------------------
log "S1 start"
check "S1s host setup installed the service: enabled, running, no helper and no database connection yet" \
  eval 'srv "systemctl is-enabled -q tando-studio.service && systemctl is-active -q tando-studio.service && systemctl is-enabled -q tando-studio-lower.path" && [ "$(helpers)" = 0 ] && [ "$(echo "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '"'"'tando studio%'"'"'" | pgsu postgres)" = 0 ]'
knobs "timeout=4 idle-s=8"
FRONT=$(front_pid)
st_start "$E/s1.out" shop
check "S1a the client printed the box and the link (with the app), and the code bought a token" eval '[ -n "$ST_TOKEN" ] && [ "$ST_APP" = shop ] && grep -q "database studio" "$E/s1.out"'
check "S1b the link's port is the host's stable port (47100-47409): $ST_PORT" eval '[ "$ST_PORT" -ge 47100 ] && [ "$ST_PORT" -le 47409 ]'
probe=$(curl -s -m 5 "http://127.0.0.1:$ST_PORT/healthz")
check "S1c /healthz answers with the probe word: $probe" eval 'case $probe in "tando-studio "?*) true;; *) false;; esac'
curl -s -m 5 -D "$E/h" -o "$E/page" "http://127.0.0.1:$ST_PORT/"
check "S1d the page: CSP self only, no inline script, Trusted Types, nosniff" eval \
  'grep -qi "^content-security-policy: default-src .self.; base-uri .none.; form-action .none.; frame-ancestors .none.; object-src .none.; require-trusted-types-for .script." "$E/h" &&
   grep -qi "^x-content-type-options: nosniff" "$E/h" && grep -q "<script src=\"/s.js\"></script>" "$E/page"'
api /api/info
check "S1e /api/info: read-only, the role and database, no password" eval '[ "$(jx "%->{mode}")" = ro ] && [ "$(jx "%->{role}")" = tando_shop ] && ! grep -q "$PW" "$E/body"'
check "S1f one helper (for shop), in the service's cgroup" eval '[ "$(helpers)" = 1 ] && srv "cat /proc/$(helper_pid)/cgroup" | grep -q "/system.slice/tando-studio.service$"'
srv "sudo ss -ltnpuwH" > "$E/ss" 2>&1
check "S1g no TCP or UDP listener belongs to the studio" eval '! grep -q tando-studio "$E/ss" && [ -s "$E/ss" ]'
perm=$(srv "sudo stat -c '%a %U:%G' /run/tando-studio /run/tando-studio/ctl /run/tando-studio/u/vmadmin /run/tando-studio/u/vmadmin/s /run/tando-studio/h" | tr '\n' ' ')
check "S1h /run/tando-studio root 711, ctl root 600, the admin's directory 711 and socket 600 vmadmin, the helpers' root 700: $perm" \
  test "$perm" = "711 root:root 600 root:root 711 root:root 600 vmadmin:root 700 root:root "
pid=$(helper_pid)
st=$(srv "ps -o user=,group= -p $pid; grep -E '^(Groups|CapEff|CapPrm|NoNewPrivs):' /proc/$pid/status | tr -s '\t' ' '" | tr '\n' ' ' | tr -s ' ')
check "S1i the helper runs as tando-shop, no other group, without capabilities, no new privileges: $st" \
  test "$st" = "tando-shop tando-shop Groups: CapPrm: 0000000000000000 CapEff: 0000000000000000 NoNewPrivs: 1 "
st=$(srv "ps -o user= -p $FRONT; grep -E '^(CapEff|CapBnd|NoNewPrivs):' /proc/$FRONT/status | tr -s '\t' ' '" | tr '\n' ' ')
check "S1k the front: root with CAP_SETUID and CAP_SETGID only, no new privileges: $st" \
  test "$st" = "root CapEff: 00000000000000c0 CapBnd: 00000000000000c0 NoNewPrivs: 1 "
check "S1j another local user cannot reach the admin's socket (permission denied)" \
  eval 'srv "sudo useradd -M stranger 2> /dev/null; sudo -u stranger curl -s -m 3 --unix-socket /run/tando-studio/u/vmadmin/s http://127.0.0.1:$ST_PORT/healthz; echo rc=\$?" | grep -q "rc=7"'
check "S1l the app's env stays root 0640 to its own group: another app's user cannot read it (shop's helper reads its own)" \
  eval '! srv "sudo -u tando-other cat /opt/tando/apps/shop/env" > /dev/null 2>&1 && [ "$(srv "sudo stat -c %a:%U /opt/tando/apps/shop/env")" = 640:root ]'

# ---- S2 refusals -----------------------------------------------------------------------------
log "S2 refusals"
st() { curl -s -m 5 -o /dev/null -w '%{http_code}' "$@"; }
U=http://127.0.0.1:$ST_PORT
check "S2a no token: 401" test "$(st "$U/api/info")" = 401
check "S2b a wrong token: 401" test "$(st -H 'Authorization: Bearer nope' "$U/api/info")" = 401
check "S2c the code again (used): 401" test "$(st -H 'Content-Type: application/json' --data "{\"code\":\"$ST_CODE\"}" "$U/api/session")" = 401
check "S2d Host evil.example: 403" test "$(st -H "Authorization: Bearer $ST_TOKEN" -H "Host: evil.example:$ST_PORT" "$U/api/info")" = 403
check "S2e Host of another port: 403" test "$(st -H "Authorization: Bearer $ST_TOKEN" -H "Host: 127.0.0.1:1" "$U/api/info")" = 403
check "S2f Host localhost. (trailing dot): 403" test "$(st -H "Authorization: Bearer $ST_TOKEN" -H "Host: localhost.:$ST_PORT" "$U/api/info")" = 403
check "S2g Origin http://evil.example: 403" test "$(st -H "Authorization: Bearer $ST_TOKEN" -H 'Origin: http://evil.example' "$U/api/info")" = 403
check "S2h Sec-Fetch-Site: cross-site: 403" test "$(st -H "Authorization: Bearer $ST_TOKEN" -H 'Sec-Fetch-Site: cross-site' "$U/api/info")" = 403
check "S2i a form post: 415" test "$(st -H "Authorization: Bearer $ST_TOKEN" --data 'id=a&sql=select+1' "$U/api/query")" = 415
check "S2j a preflight from another site: 403" test "$(st -X OPTIONS -H 'Origin: http://evil.example' "$U/api/query")" = 403
check "S2k OPTIONS from the page's own origin: 405" test "$(st -X OPTIONS "$U/api/query")" = 405
check "S2l the page's own origin with the token: 200" test "$(st -H "Authorization: Bearer $ST_TOKEN" -H "Origin: http://127.0.0.1:$ST_PORT" -H 'Sec-Fetch-Site: same-origin' "$U/api/info")" = 200

# ---- S3 read-only ------------------------------------------------------------------------------
log "S3 read-only"
q "SELECT count(*) FROM items"
check "S3a a query works: count = $(jx '%->{results}[0]{rows}[0][0]')" test "$(jx '%->{results}[0]{rows}[0][0]')" = 100000
# each attempt: must fail; then a second request that only PostgreSQL can refuse; then the data
# as the superuser sees it
SECOND="WITH d AS (DELETE FROM items WHERE id = 1 RETURNING id) SELECT count(*) FROM d"
n=0
attempt() { # id sql
  local id=$1 e1 e2 sum
  q "$2"; e1=$(qerr); [ -n "$e1" ] || e1="none:$(jx '%->{results}[-1]{command}')"
  q "$SECOND"; e2=$(qerr)
  sum=$(datasum)
  check "$id refused ($e1), the next request too ($e2), data unchanged: $2" \
    eval 'case $e1 in none:*) false;; esac && [ "$e2" = 25006 ] && [ "$sum" = "$SUM0" ]'
}
attempt S3b "INSERT INTO items (id) VALUES (0)"
attempt S3c "COMMIT; INSERT INTO items (id) VALUES (0)"
attempt S3d "BEGIN READ WRITE; INSERT INTO items (id) VALUES (0)"
attempt S3e "SET default_transaction_read_only = off; COMMIT; DELETE FROM items"
attempt S3f "SET TRANSACTION READ WRITE; DELETE FROM items"
attempt S3g "SET TRANSACTION READ WRITE; DELETE FROM items; COMMIT"
attempt S3h "COMMIT; SET TRANSACTION READ WRITE; DELETE FROM items"
attempt S3i "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE; COMMIT; DELETE FROM items"
attempt S3j "SELECT set_config('transaction_read_only', 'off', true); DELETE FROM items"
attempt S3k "SELECT set_config('transaction_read_only', 'off', true); $SECOND"
attempt S3l "SET LOCAL transaction_read_only = off; UPDATE items SET name = 'x'; COMMIT"
attempt S3m "WITH d AS (DELETE FROM items RETURNING 1) SELECT count(*) FROM d"
attempt S3n "EXPLAIN ANALYZE DELETE FROM items"
attempt S3o "SELECT nextval('s')"
attempt S3p "SELECT setval('s', 99)"
attempt S3q "CREATE TEMP TABLE tt (a int)"
attempt S3r "SELECT * INTO items_copy FROM items"
attempt S3s "SELECT * FROM items WHERE id = 1 FOR UPDATE"
attempt S3t "COPY items TO STDOUT"
attempt S3u "COPY (SELECT 1) TO PROGRAM 'id'"
attempt S3v "DO \$\$ BEGIN DELETE FROM items; COMMIT; END \$\$"
attempt S3w "CALL p()"
attempt S3x "PREPARE x AS DELETE FROM items; EXECUTE x"
attempt S3y "LOCK items IN ACCESS EXCLUSIVE MODE"
attempt S3z "REINDEX TABLE items"
attempt S3A "ANALYZE items"
attempt S3B "VACUUM items"
attempt S3C "NOTIFY c, 'x'; COMMIT"
attempt S3D "SELECT pg_notify('c', 'x'); COMMIT"
attempt S3E "SELECT lo_from_bytea(0, 'x')"
attempt S3F "SET ROLE postgres; DELETE FROM items"
attempt S3G "SET SESSION AUTHORIZATION postgres"
attempt S3H "select 1 /* ; */ ; end; delete from items"
attempt S3I "(DELETE FROM items)"
attempt S3J "SELECT pg_read_file('/etc/shadow')"
attempt S3K "SELECT * FROM tando_other.public.other_secret"
attempt S3L "TRUNCATE items"
attempt S3M "ALTER TABLE items ADD COLUMN x int"
attempt S3N "GRANT SELECT ON items TO PUBLIC"
attempt S3O "SELECT dblink_exec('dbname=tando_shop', 'DELETE FROM items')"
# an advisory lock is allowed, and released when the request ends (DISCARD ALL)
q "SELECT pg_advisory_lock(42)"
got=$(srv "read -r PGPASSWORD; export PGPASSWORD; psql -X -At -h 127.0.0.1 -U tando_shop -d tando_shop -c 'SELECT pg_try_advisory_lock(42)'" <<< "$PW")
check "S3P pg_advisory_lock(42) in the studio, then the app's role gets it: $got" test "$got" = t
q "SET search_path = nowhere"
q "SHOW search_path"
check "S3Q session settings do not outlive a request: search_path back ($(jx '%->{results}[0]{rows}[0][0]'))" \
  test "$(jx '%->{results}[0]{rows}[0][0]')" = '"$user", public'
q "WITH d AS (DELETE FROM items WHERE id = 1 RETURNING id) SELECT count(*) FROM d"
check "S3R a write the allowlist lets through is PostgreSQL's to refuse: $(qerr) $(jx '%->{error}{message}')" \
  eval '[ "$(qerr)" = 25006 ] && jx "%->{error}{message}" | grep -q "read-only transaction"'
check "S3S after all of it the data is what it was" test "$(datasum)" = "$SUM0"
# (red team) the app's own sessions: the role may signal them and a read-only transaction does
# not stop that; and the resource settings through a U& identifier or SQL run from text
srv "read -r PGPASSWORD; export PGPASSWORD; setsid nohup psql -X -At -h 127.0.0.1 -U tando_shop -d tando_shop -c 'SELECT pg_sleep(30)' > /dev/null 2>&1 < /dev/null &" <<< "$PW"
T_UNTIL_STEP=0.2 t_until 10 eval '[ "$(echo "SELECT count(*) FROM pg_stat_activity WHERE usename = '"'"'tando_shop'"'"' AND application_name = '"'"'psql'"'"' AND state = '"'"'active'"'"'" | pgsu postgres)" = 1 ]'
for a in "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'psql'" \
    "SELECT pg_catalog.pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'psql'"; do
  q "$a"; e=$(qerr)
  alive=$(echo "SELECT count(*) FROM pg_stat_activity WHERE usename = 'tando_shop' AND application_name = 'psql' AND state = 'active'" | pgsu postgres)
  check "S3T refused ($e), the app's session still runs ($alive): $a" eval '[ "$e" = 25006 ] && [ "$alive" = 1 ]'
done
echo "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'tando_shop' AND application_name = 'psql'" | pgsu postgres > /dev/null
for a in "SELECT U&\"\\0073et_config\"('work_mem', '1GB', false); SHOW work_mem" \
    "SELECT query_to_xml('select set_config(''work_mem'',''1GB'',false)', true, false, ''); SHOW work_mem" \
    "SELECT ts_stat('select set_config(''work_mem'',''1GB'',false)::tsvector'); SHOW work_mem"; do
  q "$a"; e=$(qerr)
  check "S3U refused ($e, work_mem not changed): $a" eval '[ "$e" = 25006 ] && [ "$(jx "scalar @{%->{results}}")" = 0 ]'
done

# ---- S4 limits ---------------------------------------------------------------------------------
log "S4 limits"
q "SELECT generate_series(1, 5000000)"
mem=$(($(srv "awk '/^VmHWM:/ { print \$2 }' /proc/$(helper_pid)/status") * 1024))
check "S4a 5M rows: 1,000 kept, truncated (rows); the helper's peak memory $((mem / 1048576)) MB <= 64 MB" \
  eval '[ "$(jx "scalar @{%->{results}[0]{rows}}")" = 1000 ] && [ "$(jx "%->{results}[0]{reason}")" = rows ] && [ "$mem" -le 67108864 ]'
active=$(echo "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'tando studio%' AND state = 'active'" | pgsu postgres)
check "S4b nothing runaway: no studio query active after the answer ($active)" test "$active" = 0
q "SELECT big FROM wide"
check "S4c a 20 MB cell is cut at 64 KB, with its full length in trunc" \
  eval '[ "$(jx "length %->{results}[0]{rows}[0][0]")" = 65536 ] && [ "$(jx "%->{results}[0]{trunc}[0][2]")" = 20971520 ]'
q "SELECT left(big, 100000) FROM wide, generate_series(1, 200)" 1000
mem=$(($(srv "awk '/^VmHWM:/ { print \$2 }' /proc/$(helper_pid)/status") * 1024))
check "S4d 200 cells of 100 KB: the 8 MB answer cap ($(jx "%->{results}[0]{reason}"), $(jx "scalar @{%->{results}[0]{rows}}") rows), peak $((mem / 1048576)) MB" \
  eval '[ "$(jx "%->{results}[0]{reason}")" = bytes ] && [ "$mem" -le 67108864 ]'
t1=$SECONDS; q "SET statement_timeout = 0; SELECT pg_sleep(30)"; dt=$((SECONDS - t1))
check "S4e SET statement_timeout = 0 does not help: the studio's own clock stops pg_sleep(30) at 4 s ($dt s): $(jx '%->{error}{message}')" \
  eval '[ "$(qerr)" = 57014 ] && [ $dt -le 8 ] && jx "%->{error}{message}" | grep -q limit'
q "SET LOCAL statement_timeout = '1s'; SELECT pg_sleep(3)"
check "S4f SET LOCAL statement_timeout = '1s'; pg_sleep(3): 57014" test "$(qerr)" = 57014
q "SELECT 1"
check "S4g the session works after the clock" test "$(jx '%->{results}[0]{rows}[0][0]')" = 1

# ---- S5 cancel ---------------------------------------------------------------------------------
log "S5 cancel"
( q "SELECT pg_sleep(20)" 1000 c1; cp "$E/body" "$E/cancel.body" ) &
cpid=$!
T_UNTIL_STEP=0.2 t_until 5 eval '[ "$(echo "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '"'"'tando studio%'"'"' AND state = '"'"'active'"'"'" | pgsu postgres)" = 1 ]'
t1=$(perl -MTime::HiRes=time -e 'print time')
curl -s -m 5 -o "$E/c.out" -H "Authorization: Bearer $ST_TOKEN" -H 'Content-Type: application/json' --data '{"id":"c1"}' "$U/api/cancel"
wait $cpid
dt=$(perl -MTime::HiRes=time -e "printf '%.1f', time - $t1")
check "S5a cancel: answered within 2 s ($dt s) with 57014 (cancelled)" \
  eval 'grep -q "\"cancelled\":true" "$E/c.out" && grep -q "57014" "$E/cancel.body" && perl -e "exit !($dt < 2)"'
active=$(echo "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'tando studio%' AND state = 'active'" | pgsu postgres)
check "S5b no studio query active afterwards ($active)" test "$active" = 0

# ---- S13 the studio's backend is scoped (memory, CPU and I/O priority, locks, snapshots) -------
log "S13 scoping"
q "SHOW work_mem; SHOW hash_mem_multiplier; SHOW max_parallel_workers_per_gather; SHOW max_parallel_workers; SHOW jit; SHOW temp_buffers; SHOW lock_timeout"
set_=$(jx 'join " ", map { $_->{rows}[0][0] } @{%->{results}}')
check "S13a the backend's settings (work_mem, hash_mem_multiplier, parallel, jit, temp_buffers, lock_timeout): $set_" test "$set_" = "2MB 1 0 0 off 1MB 2s"
for a in "SET work_mem = '1GB'" "SELECT set_config('work_mem', '1GB', false)" "SELECT pg_catalog.set_config('jit', 'on', false)" \
    "SET max_parallel_workers_per_gather = 4" "SET LOCAL hash_mem_multiplier = 8" "SET lock_timeout = 0"; do
  q "$a"; e=$(qerr)
  check "S13b refused: $a ($e)" test "$e" = 25006
done
q "SHOW work_mem"
check "S13c work_mem is still 2MB in the next request" test "$(jx '%->{results}[0]{rows}[0][0]')" = 2MB
bpid=$(echo "SELECT pid FROM pg_stat_activity WHERE application_name LIKE 'tando studio%'" | pgsu postgres)
T_UNTIL_STEP=0.2 t_until 10 eval 'srv "test -e /sys/fs/cgroup/tando-shop-studiodb-$bpid.scope/cpu.weight"'   # (the path unit runs the agent)
pr=$(srv "ps -o ni= -p $bpid; ionice -p $bpid; ps -o ni= -p $(helper_pid); cut -d: -f3 /proc/$bpid/cgroup; cat /sys/fs/cgroup/tando-shop-studiodb-$bpid.scope/cpu.weight" | tr -s ' \n' ' ')
check "S13d the backend $bpid in a scope of its own at CPU weight 1, nice 19, idle I/O; the helper at nice 10 (through the front's request and the root agent's checks): $pr" \
  eval 'case "$pr" in *"19 idle 10 /tando-shop-studiodb-$bpid.scope 1 ") true;; *) false;; esac'
# (red team) the agent lowers no other process: its studio_lower, given the pid of the other
# app's session (with the studio's application_name), of shop's own app session and of the
# postmaster, refuses each and leaves it where it was
srv "read -r A; read -r B; (PGPASSWORD=\$A setsid nohup psql -X -h 127.0.0.1 -U tando_shop -d tando_shop -c 'SELECT pg_sleep(20)' > /dev/null 2>&1 < /dev/null &)
  (PGAPPNAME='tando studio (x)' PGPASSWORD=\$B setsid nohup psql -X -h 127.0.0.1 -U tando_other -d tando_other -c 'SELECT pg_sleep(20)' > /dev/null 2>&1 < /dev/null &)" <<< "$PW
$PW2"
T_UNTIL_STEP=0.2 t_until 10 eval '[ "$(echo "SELECT count(*) FROM pg_stat_activity WHERE query = '"'"'SELECT pg_sleep(20)'"'"'" | pgsu postgres)" = 2 ]'
cat > "$E/lower-probe" <<'AG'
a=/opt/tando/bin/tando-agent; head -n "$(($(grep -n '^verb=' "$a" | head -1 | cut -d: -f1) - 1))" "$a" > /root/.agent-head
set --; . /root/.agent-head; app shop; load "$R/host.conf" H; db_creds
for p in $(runuser -u postgres -- psql -XAt -c "SELECT pid FROM pg_stat_activity WHERE query = 'SELECT pg_sleep(20)'") "$(head -1 /run/postgresql/*-main.pid)"; do
  b=$(cut -d: -f3 "/proc/$p/cgroup"); studio_lower "$p"; r=$?; echo "$p:$r:$([[ $(cut -d: -f3 "/proc/$p/cgroup") == "$b" ]] && echo same || echo moved):$(ps -o ni= -p "$p" | tr -d ' ')"
done; rm -f /root/.agent-head
AG
fake=$(srv 'sudo bash -s' < "$E/lower-probe" 2>&1)
check "S13r the agent refuses to lower another app's session, the app's own and the postmaster: $(echo $fake)" \
  eval '[ "$(echo "$fake" | grep -c ":1:same:0$")" = 3 ]'
echo "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query = 'SELECT pg_sleep(20)'" | pgsu postgres > /dev/null
# a heavy query (a self-join of 100,000 rows sorted on a computed key, and an aggregate): the
# backend's private memory, sampled while it runs, stays near its settings
heavy="SELECT count(*), max(h) FROM (SELECT md5(a.name || b.note) h FROM items a JOIN items b ON b.id = a.id ORDER BY 1) s, (SELECT name, count(*) FROM items GROUP BY name ORDER BY 2 DESC LIMIT 5) g"
( q "$heavy" 1000 h1; cp "$E/body" "$E/heavy.body" ) &
hp=$! peak=0
while kill -0 $hp 2> /dev/null; do   # (a measurement: one sample every 0.2 s while it runs)
  r=$(srv "awk '/^RssAnon:/ { print \$2 }' /proc/$bpid/status" 2> /dev/null)
  case $r in [0-9]*) [ "$r" -gt "$peak" ] && peak=$r;; esac
  sleep 0.2
done
echo "heavy query: backend RssAnon peak ${peak} kB" > "$E/heavy.mem"
check "S13e a heavy sort, hash join and aggregate: the backend's private memory peaked at $((peak / 1024)) MB (<= 24 MB), the query finished ($(jx '%->{error}{message}'))" \
  eval 'cp "$E/heavy.body" "$E/body"; [ -z "$(qerr)" ] && [ "$peak" -gt 0 ] && [ "$peak" -le 24576 ]'
# locks: a studio query holds ACCESS SHARE; the app's ALTER TABLE waits at most the studio's limit
( q "SELECT pg_sleep(30) FROM items LIMIT 1" 1000 l1; cp "$E/body" "$E/lock.body" ) &
lp=$!
T_UNTIL_STEP=0.2 t_until 5 eval '[ "$(echo "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '"'"'tando studio%'"'"' AND state = '"'"'active'"'"'" | pgsu postgres)" = 1 ]'
t1=$(perl -MTime::HiRes=time -e 'print time')
echo "SET lock_timeout = 0; ALTER TABLE items ADD COLUMN zz int" | pgsu tando_shop > "$E/alter.out"
dt=$(perl -MTime::HiRes=time -e "printf '%.1f', time - $t1")
wait $lp
check "S13f the app's ALTER TABLE waited $dt s for a studio query (its limit: 4 s), which the studio's clock stopped" \
  eval 'grep -q ALTER "$E/alter.out" && perl -e "exit !($dt <= 6)" && grep -q 57014 "$E/lock.body" && grep -q "limit" "$E/lock.body"'
echo "ALTER TABLE items DROP COLUMN zz" | pgsu tando_shop > /dev/null
q "SELECT 1"
st=$(echo "SELECT state || ' xmin=' || coalesce(backend_xmin::text, 'none') FROM pg_stat_activity WHERE application_name LIKE 'tando studio%'" | pgsu postgres)
check "S13g between requests the studio's connection is idle, holding no snapshot ($st)" test "$st" = "idle xmin=none"

# ---- S6 browsing ---------------------------------------------------------------------------------
log "S6 browsing"
api /api/tables
names=$(jx 'join ",", map { "$_->{name}:$_->{kind}:" . ($_->{est} > 90000 ? "est" : "") } @{%->{tables}}')
check "S6a the tables, kinds and estimates: $names" \
  eval 'case ",$names," in *",items:r:est,"*) true;; *) false;; esac && case ",$names," in *",items_v:v:,"*) true;; *) false;; esac &&
        case $names in *"x\"<b>:r:"*) true;; *) false;; esac && grep -q "u003cb" "$E/body"'
api "/api/table?schema=public&name=items"
check "S6b the structure: 8 columns, id the primary key, an index" \
  eval '[ "$(jx "scalar @{%->{columns}}")" = 8 ] && [ "$(jx "%->{columns}[0]{pk}")" = 1 ] && jx "%->{indexes}[0]{def}" | grep -q "UNIQUE INDEX items_pkey"'
api /api/rows '{"schema":"public","name":"items","offset":0,"limit":100}'
check "S6c the first page: 100 rows, more after, ids 1..100" \
  eval '[ "$(jx "scalar @{%->{result}{rows}}")" = 100 ] && [ "$(jx "%->{has_more}")" = 1 ] && [ "$(jx "%->{result}{rows}[99][0]")" = 100 ]'
# (wide columns are selected cut, left(c::text, n): the header must still be the table's column;
# seen in a browser: name, note, doc and n were all headed "left", type text)
hdr=$(jx 'join ",", map { "$_->{name}:$_->{type}" } @{%->{result}{columns}}')
check "S6c2 the page's header is the table's columns and types: $hdr" \
  test "$hdr" = "id:bigint,name:text,note:text,doc:jsonb,blob:bytea,n:numeric,flag:boolean,created:timestamp with time zone"
api /api/rows '{"schema":"public","name":"items","offset":99900,"limit":100}'
check "S6d page 1,000 (offset 99,900): the last 100 rows, none after" \
  eval '[ "$(jx "%->{result}{rows}[99][0]")" = 100000 ] && [ "$(jx "%->{has_more}")" = 0 ]'
api /api/rows '{"schema":"public","name":"items","offset":0,"limit":5,"sort":"note","desc":true}'
check "S6e sorted by a column (desc, NULLs last), then the key" test "$(jx '%->{result}{rows}[0][2]')" = "$(printf 'n%.0s' $(seq 49))"
api /api/rows '{"schema":"public","name":"x\"<b>","offset":0,"limit":5}'
check "S6f markup in a name and in data comes back as JSON text (escaped)" \
  eval '[ "$(jx "%->{result}{rows}[0][1]")" = "</script><b>hi</b>" ] && grep -q "u003c/script" "$E/body" && ! grep -q "<b>" "$E/body"'
api /api/rows '{"schema":"public","name":"nope","offset":0,"limit":5}'
check "S6g an unknown table: 404" test "$CODE" = 404
api /api/rows '{"schema":"public","name":"items","offset":0,"limit":5,"sort":"id; DROP TABLE items"}'
check "S6h an unknown sort column: 404, nothing run" eval '[ "$CODE" = 404 ] && [ "$(datasum)" = "$SUM0" ]'
api /api/rows '{"schema":"public","name":"wide","offset":0,"limit":5}'
check "S6i browsing a 20 MB cell: 16,384 characters, marked cut" \
  eval '[ "$(jx "length %->{result}{rows}[0][1]")" = 16384 ] && [ "$(jx "%->{result}{trunc}[0][1]")" = 1 ]'

# ---- S16 scope: the app's own tables only, never the system catalogs -----------------------------
log "S16 scope"
# the demo's relations (customers, items, orders, the view big_orders) and three of the app's
# objects that reach a catalog from inside: a view over pg_roles, a view calling current_setting,
# a function reading pg_roles (the documented limit). Dropped at the end of the section.
pgsu tando_shop > "$E/s16seed.out" <<'SQL'
CREATE TABLE customers (id int PRIMARY KEY, name text); CREATE TABLE orders (id int PRIMARY KEY, customer_id int REFERENCES customers, item_id bigint REFERENCES items, qty int);
INSERT INTO customers SELECT i, 'customer ' || i FROM generate_series(1, 200) i;
INSERT INTO orders SELECT i, 1 + i % 200, 1 + i % 1000, i % 7 FROM generate_series(1, 20000) i;
CREATE VIEW big_orders AS SELECT * FROM orders WHERE qty > 4;
CREATE VIEW sys_v AS SELECT rolname FROM pg_roles; CREATE VIEW set_v AS SELECT current_setting('work_mem') AS w;
CREATE FUNCTION roles_f() RETURNS SETOF text LANGUAGE sql AS 'SELECT rolname::text FROM pg_roles';
ALTER TABLE customers OWNER TO tando_shop; ALTER TABLE orders OWNER TO tando_shop; ALTER VIEW big_orders OWNER TO tando_shop;
ALTER VIEW sys_v OWNER TO tando_shop; ALTER VIEW set_v OWNER TO tando_shop; ALTER FUNCTION roles_f() OWNER TO tando_shop; ANALYZE customers, orders;
SQL
check "S16 seeded: customers, orders, the view big_orders; views over pg_roles and current_setting" eval '! grep -q ERROR "$E/s16seed.out"'
# the table list and browsing: no system schema, whatever is asked (a system table is a 404)
for p in /api/tables "/api/tables?system=1"; do
  api "$p"; sys=$(jx 'scalar grep { $_->{schema} =~ /^pg_|^information_schema$/ } @{%->{tables}}')
  names=$(jx 'join ",", sort map { $_->{name} } grep { $_->{name} =~ /^(customers|items|orders|big_orders)$/ } @{%->{tables}}')
  check "S16a $p: no table of a system schema ($sys), the app's are there ($names)" eval '[ "$sys" = 0 ] && [ "$names" = big_orders,customers,items,orders ]'
done
for sn in pg_catalog/pg_class pg_catalog/pg_authid information_schema/tables pg_toast/pg_toast_1259 pg_catalog/pg_roles; do
  api "/api/table?schema=${sn%/*}&name=${sn#*/}"; c1=$CODE
  api /api/rows "{\"schema\":\"${sn%/*}\",\"name\":\"${sn#*/}\",\"offset\":0,\"limit\":5}"; c2=$CODE
  check "S16b ${sn%/*}.${sn#*/}: structure $c1, rows $c2 (404: as an unknown table)" eval '[ "$c1" = 404 ] && [ "$c2" = 404 ]'
done
# browsing a view of the app's that reads pg_roles: the editor's plan check, 403; the demo's view is browsed
api /api/rows '{"schema":"public","name":"sys_v","offset":0,"limit":5}'; c1=$CODE m1=$(jx '%->{error}{message}')
api /api/rows '{"schema":"public","name":"big_orders","offset":0,"limit":5}'; c2=$CODE n2=$(jx 'scalar @{%->{result}{rows}}')
check "S16b2 the rows of a view over pg_roles: $c1 ($m1); of big_orders: $c2, $n2 rows" \
  eval '[ "$c1" = 403 ] && case $m1 in *"pg_catalog.pg_authid is a system table") true;; *) false;; esac && [ "$c2" = 200 ] && [ "$n2" = 5 ]'
# the editor: every way to a system relation is refused before it runs (42501, the message names it)
scope_no() { # id sql [sqlstate (42501)]: refused with that code; with 42501 the guard's message
  local want=${3:-42501} e m
  q "$2"; e=$(qerr); m=$(jx '%->{error}{message}')
  check "$1 refused ($e: $m): $2" eval '[ "$e" = "$want" ] && { [ "$want" != 42501 ] || case $m in "the studio only reads this app'"'"'s own tables: "*" is "*) true;; *) false;; esac; }'
}
scope_no S16c1 "SELECT * FROM pg_class"
scope_no S16c2 'SELECT * FROM "pg_class"'
scope_no S16c3 "SELECT * FROM PG_CATALOG.pg_class"
scope_no S16c4 "SELECT * FROM pg_catalog /* x */ .
  -- y
  pg_class"
scope_no S16c5 'SELECT * FROM U&"pg\005fclass"' 25006
scope_no S16c6 "WITH x AS (SELECT * FROM pg_roles) SELECT * FROM x"
scope_no S16c7 "SELECT * FROM (SELECT rolname FROM pg_roles) s"
scope_no S16c8 "SELECT * FROM items i, LATERAL (SELECT rolname FROM pg_roles LIMIT 1) r"
scope_no S16c9 "SELECT name FROM customers UNION SELECT rolname FROM pg_roles"
scope_no S16d1 "SELECT 1 WHERE EXISTS (SELECT 1 FROM pg_stat_activity)"
scope_no S16d2 "TABLE pg_roles"
scope_no S16d3 "SELECT * FROM information_schema.tables"
scope_no S16d4 "SELECT (SELECT rolname FROM pg_roles LIMIT 1)"
for f in "pg_get_userbyid(10)" "current_setting('work_mem')" "has_table_privilege('items', 'select')" "to_regclass('pg_authid')" \
    "pg_database_size(current_database())" "obj_description(1259)" "pg_relation_size('items')" "pg_ls_dir('.')" "txid_current()" \
    "lo_get(1)" "'pg_authid'::regclass::oid" "CAST('x' AS regclass)" "1 OPERATOR(pg_catalog.+) 1" "table_to_xml('pg_authid', true, false, '')" \
    "tableoid::regclass FROM items LIMIT 1"; do
  scope_no S16e "SELECT $f"
done
scope_no S16f1 "SELECT * FROM sys_v"   # the app's view over pg_roles: the plan shows pg_catalog.pg_authid
check "S16f1b ... and names the system table: $(jx '%->{error}{message}')" \
  eval 'jx "%->{error}{message}" | grep -q "pg_catalog.pg_authid is a system table"'
scope_no S16f2 "SELECT * FROM set_v"   # the app's view calling current_setting: the plan's Output
scope_no S16f3 "SELECT o.* FROM big_orders o JOIN sys_v ON true"
scope_no S16g1 "SET LOCAL search_path = pg_catalog; SELECT * FROM pg_class"
scope_no S16g2 "SET LOCAL search_path = 'information_schema'; SELECT * FROM tables"
check "S16g2b ... the first statement ran, the second was refused by its plan: stmt $(jx '%->{error}{stmt}'), $(jx 'scalar @{%->{results}}') result" \
  eval '[ "$(jx "%->{error}{stmt}")" = 1 ] && [ "$(jx "scalar @{%->{results}}")" = 1 ]'
scope_no S16g3 "SELECT * FROM pg_temp.x"
scope_no S16h1 "EXPLAIN SELECT * FROM pg_class"
scope_no S16h2 "EXPLAIN SELECT * FROM sys_v"
scope_no S16h3 "EXPLAIN (ANALYZE) SELECT * FROM sys_v"
scope_no S16h4 "EXPLAIN ANALYZE VERBOSE (SELECT * FROM sys_v)"
scope_no S16i1 "VALUES ((SELECT count(*) FROM pg_class))"
scope_no S16i2 "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT * FROM r, sys_v"
scope_no S16i3 "SELECT * FROM items, pg_class"
scope_no S16i4 '\d' 25006
scope_no S16i5 "SHOW ALL"
scope_no S16i6 "SELECT * FROM tando_other.public.other_secret" 0A000   # another app's database: PostgreSQL's refusal
# what stays: the demo's relations, joins, aggregates, the view, EXPLAIN, everyday functions, SHOW
scope_ok() { # id sql [max rows] -> no error; R1 = the first cell, N = the rows of the last result
  q "$2" "${3:-1000}"; local e; e=$(qerr); R1=$(jx '%->{results}[-1]{rows}[0][0]'); N=$(jx 'scalar @{%->{results}[-1]{rows}}')
  check "$1 runs ($R1, $N rows${e:+; error $e $(jx '%->{error}{message}')}): $2" test -z "$e"
}
scope_ok S16j1 "SELECT count(*) FROM orders"
check "S16j1b count(*) = $R1" test "$R1" = 20000
scope_ok S16j2 "SELECT c.name, sum(o.qty) FROM orders o JOIN customers c ON c.id = o.customer_id JOIN items i ON i.id = o.item_id GROUP BY 1 ORDER BY 2 DESC LIMIT 5"
scope_ok S16j3 "SELECT count(*) FROM big_orders"
scope_ok S16j4 "EXPLAIN SELECT * FROM big_orders b JOIN customers c ON c.id = b.customer_id"
scope_ok S16j5 "EXPLAIN ANALYZE SELECT count(*) FROM orders"
scope_ok S16j6 "SELECT * FROM orders ORDER BY id" 10000
check "S16j6b a CSV-sized result: 10,000 rows ($N)" test "$N" = 10000
scope_ok S16j7 "SELECT now(), current_user, current_database(), version(), pg_typeof(1), upper(name), to_char(now(), 'YYYY'), jsonb_build_object('a', 1) FROM customers LIMIT 1"
scope_ok S16j8 "SELECT g, x.name FROM generate_series(1, 3) g, LATERAL (SELECT name FROM customers WHERE id = g) x"
scope_ok S16j9 "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT count(*) FROM r"
scope_ok S16k1 "SELECT 'pg_class', \$\$pg_authid\$\$ -- pg_roles"
scope_ok S16k2 "SHOW work_mem"
scope_ok S16k3 "SET LOCAL search_path = public; SELECT count(*) FROM customers"
scope_ok S16l "SELECT * FROM roles_f()"   # the documented limit: a function of the app's is called by its name
echo "DROP FUNCTION roles_f(); DROP VIEW sys_v, set_v, big_orders; DROP TABLE orders, customers" | pgsu tando_shop > /dev/null
check "S16m the section's objects are gone, the data is what it was" test "$(datasum)" = "$SUM0"

# ---- S10 secrets (while a session is open) ----------------------------------------------------
log "S10 secrets"
q "SELECT v FROM secrets WHERE id = 1"
check "S10a the canary cell is in the answer (the probe works)" grep -q "$CANARY" "$E/body"
srv "ps -eo args" > "$E/ps.server"; ps -eo args > "$E/ps.laptop"
check "S10b the password is in no process list (server and laptop)" eval '! grep -q "$PW" "$E/ps.server" "$E/ps.laptop" && grep -q tando-studio "$E/ps.server"'
check "S10c ... nor in the helper's or the front's environment" eval '! srv "sudo cat /proc/$(helper_pid)/environ /proc/$(front_pid)/environ" | tr "\0" "\n" | grep -q "$PW"'
check "S10d ... nor in the laptop's config directory or the client's output" eval '! grep -rq "$PW" "$TANDO_CONFIG_DIR" "$E/s1.out"'

# ---- S7 the end, in every way -----------------------------------------------------------------
log "S7 end"
api /api/end '{}'
api /api/ping
check "S7a Stop in the page: its token is gone (401) and its helper with it" eval '[ "$CODE" = 401 ] && T_UNTIL_STEP=0.2 t_until 10 eval "[ \"\$(helpers)\" = 0 ]"'
kill -INT "$ST_PID"; st_wait_exit 15
check "S7b Ctrl-C at the client ends the forward only: it says so; the service runs on (same process), nothing else left" \
  eval 'grep -q "forward closed; the studio keeps running on test" "$E/s1.out" && [ "$(front_pid)" = "$FRONT" ] && nothing_left'
srv "sudo journalctl --since=@$T0 --no-pager -o cat" > "$E/journal"; srv "sudo cat /var/log/tando/audit.log" > "$E/audit"
check "S10e the password and the canary cell are not in the journal or the audit log" \
  eval '! grep -q "$PW" "$E/journal" "$E/audit" && ! grep -q "$CANARY" "$E/journal" "$E/audit" && grep -q "tando-studio: started for shop (vmadmin)" "$E/journal"'
check "S7i the service never restarted (no failure)" test "$(srv "systemctl show -P NRestarts tando-studio.service")" = 0
check "S10f the audit log: every code minted, by whom, for which app and port; no SQL" \
  eval 'grep "	db-studio-code	shop	ok	read-only, port $ST_PORT$" "$E/audit" | grep -q vmadmin && ! grep -q "SELECT" "$E/audit"'

st_start "$E/s7c.out" shop; t1=$ST_TOKEN
q "SELECT 1"
kill -INT "$ST_PID"; st_wait_exit 15
check "S7c Ctrl-C with a helper open: the service survives the client, the helper ends when unused, nothing left" \
  eval 'grep -q "forward closed" "$E/s7c.out" && [ "$(front_pid)" = "$FRONT" ] && nothing_left'
mem=$(srv "ps -o rss= -p $FRONT" | tr -d ' ')
check "S7n idle: the front alone, no helper, no database connection, $((mem / 1024)) MB resident (< 15 MB)" eval '[ "$mem" -gt 0 ] && [ "$mem" -lt 15360 ] && left_now'
# two clients at once, on two ports; the second's token is not the first's
st_start "$E/s7d1.out" shop; p1=$ST_PID k1=$ST_TOKEN o1=$ST_PORT
st_start "$E/s7d2.out" shop; p2=$ST_PID k2=$ST_TOKEN o2=$ST_PORT
q "SELECT 2"; a2=$(jx '%->{results}[0]{rows}[0][0]')
ST_TOKEN=$k1 ST_PORT=$o1; q "SELECT 1"; a1=$(jx '%->{results}[0]{rows}[0][0]')
check "S7d two clients at once (ports $o1, $o2) both answer, through one service" eval '[ "$a1" = 1 ] && [ "$a2" = 2 ] && [ "$o1" != "$o2" ] && [ "$(front_pid)" = "$FRONT" ]'
kill -INT "$p2"; ST_PID=$p2; st_wait_exit 15
q "SELECT 3"
check "S7e the second client's Ctrl-C leaves the first one working" test "$(jx '%->{results}[0]{rows}[0][0]')" = 3
"$R" db studio -a shop --stop > "$E/stop.out" 2>&1
api /api/ping
check "S7g tando db studio --stop: the service restarted (a new process), every token revoked (401)" \
  eval 'grep -q "every studio session on test ended; the service restarted" "$E/stop.out" && [ "$CODE" = 401 ] && [ "$(front_pid)" != "$FRONT" ] && srv "systemctl is-active -q tando-studio.service"'
kill -INT "$p1"; ST_PID=$p1; st_wait_exit 15
FRONT=$(front_pid)
st_start "$E/s7r.out" shop
srv "sudo systemctl restart tando-studio.service"
api /api/ping
check "S7r a restart of the service revokes the tokens (401)" test "$CODE" = 401
kill -INT "$ST_PID"; st_wait_exit 15
FRONT=$(front_pid)
check "S7h the stable port is the same each time ($o1)" eval 'grep -q "127.0.0.1:$o1/" "$E/s1.out"'
# --json (tando-dash runs it so): one JSON line when ready; the end of its stdin ends the forward
rm -f "$E/s7i.in"; mkfifo "$E/s7i.in"
"$R" db studio -a shop --json < "$E/s7i.in" > "$E/s7i.out" 2> "$E/s7i.err" &
ST_PID=$!
exec 5> "$E/s7i.in"   # (the writer end: held here, as tando-dash holds its pipe)
T_UNTIL_STEP=0.2 t_until 30 eval 'grep -q . "$E/s7i.out" || ! kill -0 $ST_PID 2> /dev/null'
s7k=0
grep -qE "^\{\"url\":\"http://127\.0\.0\.1:([0-9]+)/#c=[A-Za-z0-9_-]+&app=shop\",\"port\":[0-9]+,\"sid\":\"[A-Za-z0-9_-]+\"\}$" "$E/s7i.out" &&
  [ "$(wc -l < "$E/s7i.out" | tr -d " ")" = 1 ] && s7k=1
check "S7k --json prints one line {url, port, sid} and no box ($(head -c 60 "$E/s7i.out"))" eval '[ $s7k = 1 ]'
exec 5>&-
s7l=0; T_UNTIL_STEP=0.2 t_until 20 eval '! kill -0 $ST_PID 2> /dev/null' && s7l=1
kill -TERM "$ST_PID" 2> /dev/null; wait "$ST_PID" 2> /dev/null   # (when it did not end: not left running; a background job ignores SIGINT)
check "S7l --json: the end of stdin (the program that started it is gone) ends the forward; the service runs on, nothing else left" \
  eval '[ $s7k = 1 ] && [ $s7l = 1 ] && [ "$(front_pid)" = "$FRONT" ] && nothing_left'

# ---- S8 CI keys -----------------------------------------------------------------------------
log "S8 CI keys"
secret() { awk -v n="--- $2" '$0 == n { on = 1; next } /^--- / { on = 0 } on' "$1"; }
(cd "$W/shop" && "$R" ci setup > "$E/ci.out" 2> "$E/ci.err")
KEY=$E/key.shop; secret "$E/ci.out" TANDO_DEPLOY_KEY > "$KEY"; chmod 600 "$KEY"
check "S8a tando ci setup made a deploy key" grep -q "PRIVATE KEY" "$KEY"
(TANDO_DEPLOY_KEY=$KEY TANDO_HOST=127.0.0.1 TANDO_PORT=$SP TANDO_KNOWN_HOSTS=$(secret "$E/ci.out" TANDO_KNOWN_HOSTS) \
  TANDO_CONFIG_DIR=$E/cfg-ci "$R" db studio -a shop --no-open > "$E/s8b.out" 2>&1)
check "S8b layer 1, the client: a deploy key is refused ($(tail -1 "$E/s8b.out"))" grep -q "needs the admin's login, not a deploy key" "$E/s8b.out"
KOPTS=(-F /dev/null -p "$SP" -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o StrictHostKeyChecking=no
       -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
ssh "${KOPTS[@]}" -i "$KEY" tando-d-shop@127.0.0.1 "sudo -n /opt/tando/bin/tando-agent db-studio-code shop 47999 test" > "$E/s8c.out" 2>&1; rc=$?
ssh "${KOPTS[@]}" -i "$KEY" tando-d-shop@127.0.0.1 "sudo -n /opt/tando/bin/tando-studio ctl code tando-d-shop shop 47999 test" > "$E/s8c2.out" 2>&1; rc2=$?
check "S8c layer 2, the gate: db-studio-code and tando-studio ctl are not in its grammar (rc=$rc, $rc2; no code minted)" \
  eval '[ $rc != 0 ] && [ $rc2 != 0 ] && ! grep -q "code=" "$E/s8c.out" "$E/s8c2.out"'
srv "sudo sudo -l -U tando-d-shop" > "$E/sudo-l" 2>&1
check "S8d layer 3, sudo: the deploy user may run the gate's root mode only" \
  eval 'grep -q "tando-gate" "$E/sudo-l" && ! grep -q "tando-agent" "$E/sudo-l"'
st_start "$E/s8e.out" shop
ssh "${KOPTS[@]}" -i "$KEY" -N -o ExitOnForwardFailure=yes -L "47998:/run/tando-studio/u/vmadmin/s" tando-d-shop@127.0.0.1 > "$E/s8e.ssh" 2>&1 &
fpid=$!
T_UNTIL_STEP=0.2 t_until 10 eval '! kill -0 $fpid 2> /dev/null || (exec 3<> /dev/tcp/127.0.0.1/47998) 2> /dev/null'
check "S8e layer 4, sshd: the deploy key's ssh -L to the studio's socket gets nothing" \
  eval '! curl -s -m 3 http://127.0.0.1:47998/healthz | grep -q tando-studio'
kill $fpid 2> /dev/null; wait $fpid 2> /dev/null
out=$(srv "sudo env SUDO_USER=tando-d-shop /opt/tando/bin/tando-agent db-studio-code shop 47997 test" 2>&1 < /dev/null)
check "S8f the agent itself refuses SUDO_USER=tando-d-*: $out" eval 'echo "$out" | grep -q "a CI deploy key cannot open the studio" && ! srv "sudo test -e /run/tando-studio/u/tando-d-shop"'
kill -INT "$ST_PID"; st_wait_exit 15

# ---- S9 misc --------------------------------------------------------------------------------
log "S9 misc"
"$R" db studio -a plain --no-open > "$E/s9a.out" 2>&1
check "S9a an app without a database: $(tail -1 "$E/s9a.out")" grep -q "plain has no database (add database = postgres" "$E/s9a.out"
srv "sudo mv /opt/tando/bin/tando-studio /root/tando-studio.away"
"$R" db studio -a shop --no-open > "$E/s9b.out" 2>&1
srv "sudo mv /root/tando-studio.away /opt/tando/bin/tando-studio"
check "S9b the studio missing on the server: $(tail -1 "$E/s9b.out")" grep -q "the studio is not installed on test: tando host setup test" "$E/s9b.out"
srv "sudo cp -p /opt/tando/bin/tando-agent /root/agent.new && sudo sed -i '/^  db-studio) cmd_db_studio/d' /opt/tando/bin/tando-agent"
"$R" db studio -a shop --no-open > "$E/s9c.out" 2>&1
srv "sudo cp -p /root/agent.new /opt/tando/bin/tando-agent"
check "S9c an agent without the verbs (older): $(tail -1 "$E/s9c.out")" grep -q "is older than this client: tando host setup test" "$E/s9c.out"
srv "sudo cp -p /opt/tando/bin/tando-agent /root/agent.new && sudo sed -i '/^  echo \"service=1\"$/d' /opt/tando/bin/tando-agent"
"$R" db studio -a shop --no-open > "$E/s9c2.out" 2>&1; rc=$?
srv "sudo cp -p /root/agent.new /opt/tando/bin/tando-agent"
check "S9c2 an agent without the service (older): the client takes the per-session way (here answered: update): $(tail -1 "$E/s9c2.out")" \
  eval '[ $rc != 0 ] && grep -q "now one service for the whole server: update tando on this computer" "$E/s9c2.out"'
out=$(srv "sudo /opt/tando/bin/tando-agent db-studio shop ro 0123456789abcdef0123456789abcdef 5 47996 test" 2>&1 < /dev/null)
check "S9c3 an older client's per-session verb: a clear update message: $out" eval 'echo "$out" | grep -q "update tando on this computer"'
srv "echo 'AllowStreamLocalForwarding no' | sudo tee /etc/ssh/sshd_config.d/00-studio-test.conf > /dev/null && sudo systemctl reload ssh"
"$R" db studio -a shop --no-open > "$E/s9d.out" 2>&1; rc=$?
srv "sudo rm -f /etc/ssh/sshd_config.d/00-studio-test.conf && sudo systemctl reload ssh"
check "S9d sshd without stream forwarding: the precise message, nothing left (rc=$rc)" \
  eval '[ $rc != 0 ] && grep -q "does not allow forwarding to a unix socket" "$E/s9d.out" && grep -q "AllowStreamLocalForwarding local" "$E/s9d.out" && nothing_left'
# connection slots: the studio leaves the app at least 2 of its role's connections
app_sessions() { # n: n sessions of the app's role, each in pg_sleep(60), detached on the server
  srv "read -r PGPASSWORD; export PGPASSWORD; for i in \$(seq $1); do setsid nohup psql -X -At -h 127.0.0.1 -U tando_shop -d tando_shop -c 'SELECT pg_sleep(60)' > /dev/null 2>&1 < /dev/null & done" <<< "$PW"
  T_UNTIL_STEP=0.2 t_until 10 eval '[ "$(echo "SELECT count(*) FROM pg_stat_activity WHERE usename = '"'"'tando_shop'"'"' AND query LIKE '"'"'SELECT pg_sleep(60)'"'"'" | pgsu postgres)" = $1 ]'
}
echo "ALTER ROLE tando_shop CONNECTION LIMIT 4" | pgsu postgres > /dev/null
app_sessions 2
st_start "$E/s9s.out" shop; q "SELECT 1"
check "S9s near its limit (2 of 4 in use: the studio would leave 1) the studio does not connect ($CODE): $(jx '%->{error}{message}')" \
  eval '[ "$CODE" = 503 ] && grep -q "the app uses 2 of its 4 database connections; the studio needs one and leaves 2 free" "$E/body"'
kill -INT "$ST_PID"; st_wait_exit 15
echo "ALTER ROLE tando_shop CONNECTION LIMIT 5" | pgsu postgres > /dev/null
st_start "$E/s9t.out" shop; q "SELECT 1"
check "S9t with 2 free after it (2 of 5 in use), it does" test "$(jx '%->{results}[0]{rows}[0][0]')" = 1
kill -INT "$ST_PID"; st_wait_exit 15
echo "ALTER ROLE tando_shop CONNECTION LIMIT 10; SELECT count(pg_terminate_backend(pid)) >= 0 FROM pg_stat_activity WHERE usename = 'tando_shop'" | pgsu postgres > /dev/null
# the connection is closed when the page sends nothing for a while (conn-idle: 2 s here, 60 s)
knobs "timeout=4 conn-idle=2 idle-s=30"
st_start "$E/s9i.out" shop
q "SELECT 1"
T_UNTIL_STEP=0.5 t_until 15 eval '[ "$(echo "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '"'"'tando studio%'"'"'" | pgsu postgres)" = 0 ]'; gone=$?
q "SELECT 2"; again=$(jx '%->{results}[0]{rows}[0][0]')
bpid=$(echo "SELECT pid FROM pg_stat_activity WHERE application_name LIKE 'tando studio%'" | pgsu postgres)
T_UNTIL_STEP=0.2 t_until 10 eval '[ "$(srv "ps -o ni= -p $bpid" | tr -d " ")" = 19 ]'
check "S9i unused, the database connection is closed (the helper runs on); the next request opens one ($again), its priority lowered again" \
  eval '[ $gone = 0 ] && [ "$(helpers)" = 1 ] && [ "$again" = 2 ] && [ "$(srv "ps -o ni= -p $bpid" | tr -d " ")" = 19 ]'
kill -INT "$ST_PID"; st_wait_exit 15
knobs "timeout=4 idle-s=8"

# ---- S15 which app: the picker -----------------------------------------------------------------
log "S15 picker"
(cd "$W" && "$R" db studio -H test < /dev/null > "$E/pick.list" 2>&1); rc=$?
check "S15a no app named, no tando.conf, not a terminal: the list with the command for each, exit 2 (rc=$rc)" \
  eval '[ $rc = 2 ] && grep -q "tando db studio other *-H test" "$E/pick.list" && grep -q "tando db studio shop *-H test" "$E/pick.list" &&
        grep -q "plain.*no database" "$E/pick.list" && ! grep -q "tando db studio plain" "$E/pick.list"'
(cd "$W" && printf '2\n' | "$ROOT/test/pty-run.sh" "$E/pick.tty" "$R" db studio -H test --no-open > /dev/null 2>&1) &
pk=$!
fwd() { pgrep -f 'ControlPath=none.*127.0.0.1:[0-9]*:/run/tando-studio/u/' > /dev/null; }   # a client's forward
T_UNTIL_STEP=0.2 t_until 30 fwd   # (script(1) may write its file only at the end)
pkill -f 'ControlPath=none.*127.0.0.1:[0-9]*:/run/tando-studio/u/'   # (the forward ends: so does the client)
wait $pk 2> /dev/null
check "S15b at a terminal: a numbered list (other, shop; plain dimmed), 2 picks shop and opens its studio" \
  eval 'grep -q "Which app.s database" "$E/pick.tty" && grep -q " 1) other" "$E/pick.tty" && grep -q " 2) shop" "$E/pick.tty" &&
        grep -q "plain *no database" "$E/pick.tty" && grep -q "shop .*database studio" "$E/pick.tty" && nothing_left'

# ---- S14 isolation: two apps, two studios, no data of one in the other ---------------------------
log "S14 isolation"
st_start "$E/s9e1.out" shop; p1=$ST_PID t1=$ST_TOKEN o1=$ST_PORT
api /api/info; h1=$(jx '%->{hkey}'); w1=$(jx '%->{app} . " " . %->{db}')
st_start "$E/s9e2.out" other; p2=$ST_PID t2=$ST_TOKEN o2=$ST_PORT
api /api/info; h2=$(jx '%->{hkey}'); w2=$(jx '%->{app} . " " . %->{db}')
q "SELECT v FROM other_secret"; a2=$(jx '%->{results}[0]{rows}[0][0]')
q "SELECT count(*) FROM items"; e2=$(qerr)
ST_TOKEN=$t1 ST_PORT=$o1; q "SELECT count(*) FROM items"; a1=$(jx '%->{results}[0]{rows}[0][0]')
check "S9e two studios at once (shop, other) both answer, each with its own database only ($w1: $a1; $w2: $a2, items: $e2)" \
  eval '[ "$a1" = 100000 ] && [ "$a2" = "$OCANARY" ] && [ "$e2" = 42P01 ] && [ "$o1" != "$o2" ] && [ "$w1" = "shop tando_shop" ] && [ "$w2" = "other tando_other" ]'
check "S14a the token of one client is refused on the other's port (401 both ways)" \
  eval '[ "$(st -H "Authorization: Bearer $t1" "http://127.0.0.1:$o2/api/info")" = 401 ] && [ "$(st -H "Authorization: Bearer $t2" "http://127.0.0.1:$o1/api/info")" = 401 ]'
check "S14b each has its own history key and browser origin (port $o1, $o2)" eval '[ -n "$h1" ] && [ -n "$h2" ] && [ "$h1" != "$h2" ]'
: > "$E/iso.all"
iso() { # id expected-result text: one attempt from shop's studio at other's data; every answer kept
  local id=$1 want=$2; shift 2
  cat "$E/body" >> "$E/iso.all"
  check "$id from shop's studio: $* -> $GOT (want $want)" test "$GOT" = "$want"
}
q "SELECT * FROM tando_other.public.other_secret"; GOT=$(qerr); iso S14c 0A000 "a cross-database name"
q "SELECT * FROM other_secret"; GOT=$(qerr); iso S14d 42P01 "the other app's table by name"
api "/api/table?schema=public&name=other_secret"; GOT=$CODE; iso S14e 404 "its structure"
api /api/rows '{"schema":"public","name":"other_secret","offset":0,"limit":5}'; GOT=$CODE; iso S14f 404 "its rows"
api /api/rows '{"schema":"public","name":"items","offset":0,"limit":5,"database":"tando_other"}'; GOT=$CODE; iso S14g 400 "a database in the request"
api /api/query '{"id":"x","sql":"select 1","db":"tando_other","role":"tando_other"}'; GOT=$CODE; iso S14h 400 "a database or role in a query"
q "SELECT dblink('dbname=tando_other', 'SELECT v FROM other_secret')"; GOT=$(qerr); iso S14i 42883 "dblink (not installed)"
api "/api/tables?system=1"; GOT=$(jx 'scalar grep { $_->{name} eq "other_secret" } @{%->{tables}}'); iso S14j 0 "the table list (asked for system schemas too)"
# the other app runs a statement that carries its canary. Shop's studio may not read
# pg_stat_activity at all (the scope guard); what the role itself would see there, and the
# database names it can read in pg_database, are shown by the role's own psql on the server
srv "read -r PGPASSWORD; export PGPASSWORD; setsid nohup psql -X -At -h 127.0.0.1 -U tando_other -d tando_other -c \"SELECT pg_sleep(8), '$OCANARY'\" > /dev/null 2>&1 < /dev/null &" <<< "$PW2"
T_UNTIL_STEP=0.2 t_until 10 eval '[ "$(echo "SELECT count(*) FROM pg_stat_activity WHERE usename = '"'"'tando_other'"'"' AND state = '"'"'active'"'"'" | pgsu postgres)" = 1 ]'
q "SELECT usename, datname, query, client_addr::text FROM pg_stat_activity WHERE usename = 'tando_other'"
GOT=$(qerr); iso S14k 42501 "the other app's sessions in pg_stat_activity (refused: a system view)"
GOT=$(srv "read -r PGPASSWORD; export PGPASSWORD; psql -X -At -F, -h 127.0.0.1 -U tando_shop -d tando_shop -c \"SELECT DISTINCT usename, datname, query, coalesce(client_addr::text, 'NULL') FROM pg_stat_activity WHERE usename = 'tando_other'\"" <<< "$PW" | sort -u | tr '\n' '|')
check "S14k2 the role's own psql: the other app's sessions show no query or address: $GOT" test "$GOT" = "tando_other,tando_other,<insufficient privilege>,NULL|"
q "SELECT string_agg(datname, ',') FROM pg_database"; GOT=$(qerr); iso S14k3 42501 "pg_database (refused: a system table)"
dbs=$(srv "read -r PGPASSWORD; export PGPASSWORD; psql -X -At -h 127.0.0.1 -U tando_shop -d tando_shop -c \"SELECT string_agg(datname, ',') FROM pg_database\"" <<< "$PW")
check "S14l none of shop's studio answers holds other's canary; database names are visible to the role's psql (documented), not to the studio: $dbs" \
  eval '! grep -q "$OCANARY" "$E/iso.all" && case ",$dbs," in *,tando_other,*) true;; *) false;; esac'
# the role itself: its own database only
for d in tando_other postgres template1; do
  out=$(srv "read -r PGPASSWORD; export PGPASSWORD; psql -X -At -h 127.0.0.1 -U tando_shop -d $d -c 'SELECT 1' 2>&1" <<< "$PW")
  check "S14m tando_shop cannot connect to $d: $(echo "$out" | tail -1)" eval 'echo "$out" | grep -q "CONNECT privilege\|permission denied"'
done
out=$(srv "read -r PGPASSWORD; export PGPASSWORD; psql -X -At -h 127.0.0.1 -U tando_shop -d tando_shop -c 'CREATE EXTENSION dblink' 2>&1" <<< "$PW")
ext=$(echo "SELECT string_agg(datname, ',') FROM pg_database WHERE datallowconn" | pgsu postgres | tr ',' '\n' |
  while read -r d; do echo "SELECT string_agg(extname, ',') FROM pg_extension" | pgsu "$d"; done | sort -u | tr '\n' ' ')
check "S14n dblink cannot be created by the role ($(echo "$out" | tail -1)); the extensions in any database: $ext" \
  eval 'echo "$out" | grep -q "permission denied\|must be superuser\|Must be superuser" && [ "$ext" = "plpgsql " ]'
echo "GRANT CONNECT ON DATABASE tando_other TO PUBLIC" | pgsu postgres > /dev/null
out=$(srv "read -r PGPASSWORD; export PGPASSWORD; psql -X -At -h 127.0.0.1 -U tando_shop -d tando_other -c 'SELECT 1' 2>&1" <<< "$PW")
"$R" host setup test > "$E/setup2.out" 2>&1
out2=$(srv "read -r PGPASSWORD; export PGPASSWORD; psql -X -At -h 127.0.0.1 -U tando_shop -d tando_other -c 'SELECT 1' 2>&1" <<< "$PW")
check "S14o a database left open to PUBLIC (as an older server may have: shop got in: $out) is closed again by host setup ($(echo "$out2" | tail -1))" \
  eval '[ "$out" = 1 ] && echo "$out2" | grep -q "CONNECT privilege"'
ST_TOKEN=$t2 ST_PORT=$o2
ST_TOKEN=$t1 ST_PORT=$o1
api /api/a/other/info; sw=$(jx '%->{app} . " " . %->{db}')
q "SELECT 1"
check "S14s the switcher: shop's page may open other (the admin's), each request on that app's own helper ($sw); the link's app stays shop" \
  eval '[ "$sw" = "other tando_other" ] && [ "$(jx "%->{results}[0]{rows}[0][0]")" = 1 ] && [ -n "$(helper_pid other)" ] && [ -n "$(helper_pid shop)" ]'
api /api/a/plain/info; c1=$CODE; api /api/a/nope/info; c2=$CODE; api "/api/a/..%2fshop/info"; c3=$CODE
check "S14t no route to an app without a database, an unknown one or a path trick ($c1 $c2 $c3)" eval '[ $c1 = 404 ] && [ $c2 = 404 ] && [ $c3 = 404 ]'
"$R" destroy -a other --purge --yes > "$E/destroy.out" 2>&1
check "S9g destroy of an app with a studio open: its helpers are gone, the service runs on" \
  eval 'T_UNTIL_STEP=0.2 t_until 10 eval "[ -z \"\$(helper_pid other)\" ]" && srv "systemctl is-active -q tando-studio.service"'
kill -INT "$p2"; ST_PID=$p2; st_wait_exit 15
ST_PID=$p1; kill -INT "$p1"; st_wait_exit 15
check "S9h nothing left at the end" nothing_left
(cd "$W" && "$R" db studio -H test --no-open < /dev/null > "$E/pick.one" 2>&1) &
pk=$!
T_UNTIL_STEP=0.2 t_until 30 grep -q "^http://127.0.0.1:" "$E/pick.one"
pkill -f 'ControlPath=none.*127.0.0.1:[0-9]*:/run/tando-studio/u/'; wait $pk 2> /dev/null
check "S15c one app with a database left: it opens that one and says which" \
  eval 'grep -q "the one app with a database on test is shop: opening its studio" "$E/pick.one" && grep -q "^http://127.0.0.1:" "$E/pick.one" && nothing_left'

# ---- S11 pgwire and the studio against this PostgreSQL ------------------------------------------
log "S11 Go tests against the server's PostgreSQL"
arch=$(srv uname -m); case $arch in aarch64|arm64) arch=arm64;; *) arch=amd64;; esac
if command -v go > /dev/null 2>&1; then
  ok=1
  for pkg in pgwire studio; do
    b=$E/live-$pkg.test
    (cd "$ROOT/srv" && CGO_ENABLED=0 GOOS=linux GOARCH=$arch GOFLAGS='' GOTOOLCHAIN=local go test -c -o "$b" "./studio/${pkg#studio}") > "$E/gotest-c.out" 2>&1 || ok=0
    rd=$(srv 'd=$(mktemp -d) && chmod 755 "$d" && echo "$d"')
    case $rd in */tmp.[A-Za-z0-9]*) ;; *) ok=0; continue;; esac
    srv "cat > $rd/t && chmod 755 $rd/t" < "$b"   # lint: allow RL04 rd checked above
    # lint: allow RL04 rd checked above
    srv "cd $rd && sudo -u tando-shop bash -c 'read -r PGWIRE_LIVE_PW; export PGWIRE_LIVE_PW PGWIRE_LIVE=\"127.0.0.1:5432 tando_shop tando_shop\"; exec $rd/t -test.run \"^TestLive\" -test.v -test.count=1'" \
      <<< "$PW" > "$E/live-$pkg.out" 2>&1 || ok=0
    srv "rm -rf ${rd:?}"   # lint: allow RL04 rd checked above
  done
  check "S11a pgwire's and the studio's live tests (read-only, scope) pass against PostgreSQL $(srv 'psql --version' | awk '{ print $3 }') (as tando-shop)" \
    eval '[ $ok = 1 ] && grep -q "^--- PASS: TestLive " "$E/live-pgwire.out" && grep -q "^--- PASS: TestLiveReadOnly " "$E/live-studio.out" && grep -q "^--- PASS: TestLiveScope " "$E/live-studio.out"'
  echo "DROP TABLE IF EXISTS studio_live; DROP SEQUENCE IF EXISTS studio_seq;" | pgsu tando_shop > /dev/null
else skip "S11a Go is not installed here: the live pgwire tests need it"; fi

# ---- S12 doctor ---------------------------------------------------------------------------------
"$R" doctor > "$E/doctor.out" 2>&1
check "S12 doctor: the studio is the client's, and its service runs" \
  eval 'grep -q "studio .*same as the client" "$E/doctor.out" && grep -q "studio .*running" "$E/doctor.out"'
t_done
