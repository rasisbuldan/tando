#!/bin/bash
# test/e2e-offsite.sh: offsite backups end to end (docs/BACKUP.md): set/test/status, every backup
# uploaded and encrypted, an offsite-only restore and pull, retention, a failed upload retried and
# its state for the alerts, wrong and revoked credentials, a 300 MB backup in parts, an upload
# killed mid-way, and the disaster recovery of a PostgreSQL app onto a second, fresh server.
#
# The S3 target: MinIO's image could not be pulled where this suite was written, so the suite runs
# srv/offsite/testdata/fakes3 (a small S3 server of our own, standard library only, which checks
# every SigV4 signature, payload hash and Content-MD5) in a container of the plain ubuntu:24.04
# image on the test servers' Docker network, with TLS: its CA goes into each test server's trust
# store and s3.test into their /etc/hosts, so tando talks https with verification on, as to R2.
#
# Servers: A = TANDO_TEST_NAME (2222/8080), B = TANDO_TEST_NAME2 (default <A>b, 2272/8372).
# Uses examples/notes (needs npm) and installs PostgreSQL on both. Usage: test/e2e-offsite.sh
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-offsite
N2=${TANDO_TEST_NAME2:-${T_NAME}b} P2=${TANDO_TEST_SSH_PORT2:-$((T_SSH_PORT + 50))} H2=${TANDO_TEST_HTTP_PORT2:-$((T_HTTP_PORT + 300))}
S3=$T_NAME-s3 BUCKET=tando-e2e ACCESS=E2EACCESSKEY01 SECRET=e2e-secret-0123456789abcdef
W=$E/w
srv() { "$SSH" "$@"; }
srvB() { TANDO_TEST_NAME=$N2 TANDO_TEST_SSH_PORT=$P2 "$SSH" "$@"; }
page() { curl -s -m 5 "http://notes.localhost:${1:-$T_HTTP_PORT}/"; }
addnote() { curl -s -m 5 -X POST "http://notes.localhost:$T_HTTP_PORT/notes?text=$1" > /dev/null; }
ctl() { srv "curl -s -m 20 https://s3.test:9000/_ctl/$1"; }
settings() { printf 'endpoint=https://s3.test:9000\nbucket=%s\naccess_key_id=%s\nsecret_access_key=%s\n' "$BUCKET" "$ACCESS" "${1:-$SECRET}"; }
ost() { srv "sudo sed -n 's/^state=//p' /var/backups/tando/notes/$1/offsite"; }
created_b=0
cleanup() {
  docker rm -f "$S3" > /dev/null 2>&1
  [ "$created_b" = 1 ] && [ "${TANDO_TEST_KEEP:-0}" != 1 ] && TANDO_TEST_NAME=$N2 "$ROOT/test/server/down.sh" > /dev/null 2>&1
  return 0
}
trap cleanup EXIT

command -v npm > /dev/null || { skip "o0 npm is needed for examples/notes"; t_done; }

# ---- the servers and the S3 target -----------------------------------------------------------
t_server_up --reset || exit 1
docker container inspect "$N2" > /dev/null 2>&1 || created_b=1
TANDO_TEST_NAME=$N2 TANDO_TEST_SSH_PORT=$P2 TANDO_TEST_HTTP_PORT=$H2 "$ROOT/test/server/up.sh" --reset >&2 || exit 1
arch=$(docker info --format '{{.Architecture}}' 2> /dev/null); case $arch in aarch64|arm64) arch=arm64;; *) arch=amd64;; esac
mkdir -p "$E/s3"
(cd "$ROOT/srv" && CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -o "$E/s3/fakes3" ./offsite/testdata/fakes3) || exit 1
docker rm -f "$S3" > /dev/null 2>&1
docker run -d --name "$S3" --label tando.test=1 -v "$E/s3:/s3" ubuntu:24.04 /s3/fakes3 -addr :9000 -bucket "$BUCKET" \
  -access "$ACCESS" -secret "$SECRET" -names s3.test -ca /s3/ca.pem > /dev/null || exit 1
T_UNTIL_STEP=0.5 t_until 20 test -s "$E/s3/ca.pem" || exit 1
s3ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$S3")
for s in srv srvB; do
  $s "sudo tee /usr/local/share/ca-certificates/tando-test-s3.crt > /dev/null && sudo update-ca-certificates > /dev/null 2>&1 &&
      echo '$s3ip s3.test' | sudo tee -a /etc/hosts > /dev/null" < "$E/s3/ca.pem"
done
check "o1 the S3 target answers both servers over verified TLS ($s3ip)" \
  eval 'srv "curl -s -o /dev/null -w %{http_code} https://s3.test:9000/_ctl/requests" | grep -q 200 &&
        srvB "curl -s -o /dev/null -w %{http_code} https://s3.test:9000/_ctl/requests" | grep -q 200'

mkdir -p "$W"
rsync -a --exclude node_modules "$ROOT/examples/notes/" "$W/notes/"
cd "$W/notes" || exit 1
npm ci --no-audit --no-fund > "$E/npm.out" 2>&1 || { cat "$E/npm.out" >&2; exit 1; }
t_host_add a
"$R" host add b vmadmin@127.0.0.1 --port "$P2" --key "$ROOT/test/server/id_test" --yes >&2
printf 'host = a\n' >> tando.conf
"$R" host setup a public_port="$T_HTTP_PORT" postgres=yes > "$E/setupA.out" 2>&1 || { cat "$E/setupA.out" >&2; exit 1; }
"$R" up > "$E/up.out" 2>&1; cat "$E/up.out" >&2
addnote OFFSITE-MARKER-one; addnote OFFSITE-MARKER-two
"$R" env set NOTES_TEST=offsite-env-value > /dev/null 2>&1
check "o2 notes runs on A with two notes in PostgreSQL and the data file ($(page))" test "$(page)" = "notes v1 db=2 file=2"

# ---- set, test, status ------------------------------------------------------------------------
settings "wrong-secret-0000000000" | "$R" backup offsite set > "$E/set-wrong.out" 2>&1; rc=$?
cat "$E/set-wrong.out" >&2
check "o3 set with a wrong secret: refused, says why, saves nothing, never shows the secret (rc=$rc)" \
  eval '[ $rc = 1 ] && grep -q "secret access key does not match" "$E/set-wrong.out" && grep -q "nothing was saved" "$E/set-wrong.out" &&
        ! grep -q "wrong-secret-0000000000" "$E/set-wrong.out" && ! srv "sudo test -e /opt/tando/offsite.conf"'
settings | "$R" backup offsite set > "$E/set.out" 2>&1; rc=$?
cat "$E/set.out" >&2
key=$(grep -o 'tando-key-[a-z2-7-]*' "$E/set.out" | head -1)
check "o4 set: write, read, list, delete and clock checked; the recovery key shown once (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -q "write" "$E/set.out" && grep -q "clock" "$E/set.out" && [ ${#key} = 79 ] && grep -q -- "--saved" "$E/set.out"'
perms=$(srv "sudo stat -c %a:%U /opt/tando/offsite.conf /opt/tando/offsite.key" | tr '\n' ' ')
check "o5a credentials and key are root-only files ($perms)" test "$perms" = "600:root 600:root "
# (the secret goes to grep on stdin: in its argv, sudo would log it to the journal itself)
printf '%s\n' "$SECRET" | srv "sudo grep -rlsF -f /dev/stdin /var/log /var/lib/tando /etc/systemd /run/systemd/transient" > "$E/leak" 2>&1
check "o5b the secret is in no log, state or unit file ($(tr '\n' ' ' < "$E/leak"))" test ! -s "$E/leak"
"$R" backup offsite set > "$E/set2.out" 2>&1 < <(settings)
check "o6 a second set shows no key (it is shown once)" eval '! grep -q "tando-key-" "$E/set2.out"'
"$R" backup offsite test > "$E/test.out" 2>&1; rc=$?
check "o7 backup offsite test passes (rc=$rc)" eval '[ $rc = 0 ] && grep -q "delete" "$E/test.out"'
COLUMNS=120 "$R" backup offsite status > "$E/status.out" 2>&1; cat "$E/status.out" >&2
check "o8 status: bucket, encryption on with a key not yet saved, the timer active" \
  eval 'grep -q "bucket $BUCKET" "$E/status.out" && grep -q "not confirmed saved" "$E/status.out" && ! grep -q "not active" "$E/status.out"'
"$R" doctor > "$E/doc1.out" 2>&1
check "o9 doctor warns until the key is confirmed saved" grep -q "recovery key.*not confirmed saved" "$E/doc1.out"
"$R" backup offsite key --saved > /dev/null 2>&1
"$R" doctor > "$E/doc2.out" 2>&1; grep -i offsite "$E/doc2.out" >&2
check "o10 after key --saved doctor says saved; offsite and its queue rows are there" \
  eval 'grep -q "recovery key.*saved by the admin" "$E/doc2.out" && grep -q "offsite queue" "$E/doc2.out"'

# ---- every backup is uploaded, encrypted --------------------------------------------------------
id=$("$R" backup now 2>&1 | sed -n 's/^backed up [a-z0-9-]*: \([^ ]*\).*/\1/p')
t_until 60 eval '[ "$(ost "$id")" = uploaded ]'
check "o11 backup now: uploaded within a minute ($id)" test "$(ost "$id")" = uploaded
hid=$(srv "sed -n 's/^host_id=//p' /opt/tando/offsite.id")
ctl list > "$E/objs"
check "o12 the object, its manifest and the app's config object are in the bucket under the host id" \
  eval 'grep -q "^tando/$hid/notes/$id.rbk " "$E/objs" && grep -q "^tando/$hid/notes/$id.manifest " "$E/objs" && grep -q "^tando/$hid/notes/app.rbk " "$E/objs"'
ctl "get?key=tando/$hid/notes/$id.rbk" > "$E/obj.bin"
ctl "get?key=tando/$hid/notes/app.rbk" > "$E/app.bin"
check "o13 the object is encrypted: no plaintext marker, no env value, starts with TANDOBK1 ($(wc -c < "$E/obj.bin" | tr -d ' ') bytes)" \
  eval '[ -s "$E/obj.bin" ] && head -c 8 "$E/obj.bin" | grep -q TANDOBK1 && ! grep -aq "OFFSITE-MARKER" "$E/obj.bin" &&
        ! grep -aq "offsite-env-value" "$E/obj.bin" "$E/app.bin" && ! grep -aq "notes.log" "$E/obj.bin"'
echo 2 > VERSION
"$R" deploy > "$E/d2.out" 2>&1
pre=$(srv "sudo ls /var/backups/tando/notes" | grep predeploy | tail -1)
t_until 60 eval '[ "$(ost "$pre")" = uploaded ]'
check "o14 the pre-deploy backup is uploaded too, after the deploy ($pre)" test "$(ost "$pre")" = uploaded
"$R" backup ls > "$E/bls.out" 2>&1; cat "$E/bls.out" >&2
check "o15 backup ls has a WHERE column: local + offsite" grep -q "local + offsite" "$E/bls.out"
COLUMNS=120 "$R" status > "$E/st.out" 2>&1
check "o16 tando status shows the offsite state" grep -q "offsite.*last upload" "$E/st.out"

# ---- offsite-only restore and pull ----------------------------------------------------------------
srv "sudo rm -rf /var/backups/tando/notes/$id"
"$R" backup ls > "$E/bls2.out" 2>&1
check "o17 a backup deleted here is listed as offsite only" grep -q "$id.*offsite only" "$E/bls2.out"
addnote three
"$R" restore "$id" --yes > "$E/restore.out" 2>&1; rc=$?; cat "$E/restore.out" >&2
check "o18 tando restore <id>: fetched, verified, restored with its safety backup ($(page))" \
  eval '[ $rc = 0 ] && [ "$(page)" = "notes v2 db=2 file=2" ] && grep -q "safety" "$E/restore.out"'
srv "sudo rm -rf /var/backups/tando/notes/$id"
"$R" backup pull "$id" "$E/pulled.tar" > /dev/null 2>&1
check "o19 backup pull of an offsite-only backup: a tar with data.tar.gz and db.dump" \
  eval 'tar -tf "$E/pulled.tar" | grep -q data.tar.gz && tar -tf "$E/pulled.tar" | grep -q db.dump'

# ---- a failed upload: recorded, alert state, retried ----------------------------------------------
ctl "fail?mode=writes" > /dev/null
# shellcheck disable=SC2034 # fid is read by the evals of the checks
fid=$("$R" backup now 2>&1 | sed -n 's/^backed up [a-z0-9-]*: \([^ ]*\).*/\1/p')
t_until 60 eval '[ "$(ost "$fid")" = failed ]'
srv "cat /var/lib/tando/offsite/state/notes" > "$E/brief" 2>/dev/null; cat "$E/brief" >&2
check "o20 an upload that fails: state failed; the state file for the alerts says pending, failed, since when" \
  eval '[ "$(ost "$fid")" = failed ] && grep -q "^failed=1" "$E/brief" && grep -q "^oldest_pending=[1-9]" "$E/brief" &&
        grep -q "^oldest_pending_id=$fid" "$E/brief" && grep -q "^alert_hours=6" "$E/brief"'
srv "sudo /opt/tando/bin/tando-offsite brief notes" > "$E/brief2"
check "o21 tando-offsite brief notes: pending (late after alert_hours)" grep -q "^offsite	notes	pending	" "$E/brief2"
ctl "fail?mode=off" > /dev/null
"$R" backup offsite sync > "$E/sync.out" 2>&1; cat "$E/sync.out" >&2
check "o22 sync retries it: uploaded; nothing waits" \
  eval '[ "$(ost "$fid")" = uploaded ] && srv "grep -q ^pending=0 /var/lib/tando/offsite/state/notes"'

# ---- credentials revoked ----------------------------------------------------------------------------
ctl "secret?value=revoked-0000000000" > /dev/null
srv "sudo /opt/tando/bin/tando-offsite sync" > /dev/null 2>&1
srv "sudo /opt/tando/bin/tando-offsite brief notes" > "$E/brief3"
"$R" doctor > "$E/doc3.out" 2>&1
check "o23 revoked credentials: the state says failing, doctor fails the offsite row" \
  eval 'grep -q "	failing	" "$E/brief3" && grep -q "offsite.*credentials fail" "$E/doc3.out"'
ctl "secret?value=$SECRET" > /dev/null
srv "sudo /opt/tando/bin/tando-offsite sync" > /dev/null 2>&1

# ---- retention: only this server's objects, the newest always ---------------------------------------
"$R" backup offsite set keep_other=2 keep_min=1 > /dev/null 2>&1 < <(settings)
for i in 1 2 3; do "$R" backup now > /dev/null 2>&1; sleep 1; done
"$R" backup offsite sync > /dev/null 2>&1
ctl list > "$E/objs2"
n=$(grep -c "^tando/$hid/notes/.*-manual.rbk " "$E/objs2")
check "o24 retention keeps 2 manual backups offsite (keep_other=2) while 5 stay local ($n offsite)" test "$n" = 2

# ---- 300 MB in parts; an upload killed mid-way ------------------------------------------------------
srv "sudo -u tando-notes head -c 300M /dev/urandom | sudo -u tando-notes tee /opt/tando/apps/notes/shared/data/big.bin > /dev/null"
ctl "delay?d=300ms" > /dev/null
bid=$("$R" backup now 2>&1 | sed -n 's/^backed up [a-z0-9-]*: \([^ ]*\).*/\1/p')
t_until 120 eval 'ctl uploads | awk "\$3 >= 3" | grep -q .'
srv "sudo systemctl kill -s KILL tando-offsite-notes-$bid.service" 2> /dev/null
sleep 1
ctl list > "$E/objs3"; ctl uploads > "$E/ups3"
check "o25 a push killed mid-way: no object visible under its name, its parts in an unfinished upload" \
  eval '! grep -q "$bid.rbk" "$E/objs3" && grep -q "$bid.rbk" "$E/ups3" && [ "$(ost "$bid")" = uploading ]'
ctl "delay?d=0s" > /dev/null
"$R" backup offsite sync > /dev/null 2>&1
ctl list > "$E/objs4"; ctl uploads > "$E/ups4"
size=$(awk -v k="tando/$hid/notes/$bid.rbk" '$1 == k { print $2 }' "$E/objs4")
check "o26 the next sync aborts the leftover upload and sends it whole, in parts ($size bytes)" \
  eval '[ "$(ost "$bid")" = uploaded ] && ! grep -q . "$E/ups4" && [ "${size:-0}" -gt 314572800 ]'
srv "sudo rm -rf /var/backups/tando/notes/$bid"
srv "sudo /opt/tando/bin/tando-offsite fetch notes $bid" > "$E/fetch.out" 2>&1; rc=$?
check "o27 the 300 MB backup comes back verified (rc=$rc)" eval '[ $rc = 0 ] && grep -q "^fetched=$bid" "$E/fetch.out"'
srv "sudo -u tando-notes rm -f /opt/tando/apps/notes/shared/data/big.bin"
"$R" backup now > /dev/null 2>&1; "$R" backup offsite sync > /dev/null 2>&1   # (the newest without big.bin)

# ---- disaster recovery onto B -----------------------------------------------------------------------
want=$(page)
"$R" host setup b public_port="$H2" postgres=yes > "$E/setupB.out" 2>&1 || { cat "$E/setupB.out" >&2; fail "o28 host setup b"; t_done; }
printf '%s\n' "$key" | "$R" backup offsite key --import -H b > "$E/imp.out" 2>&1; rc=$?
settings | "$R" backup offsite set -H b > "$E/setB.out" 2>&1
check "o28 on B: the key imported, the same bucket set, no new key made (rc=$rc)" \
  eval '[ $rc = 0 ] && ! grep -q "tando-key-" "$E/setB.out" && grep -q "saved" "$E/setB.out"'
"$R" backup offsite hosts -H b > "$E/hosts.out" 2>&1; cat "$E/hosts.out" >&2
check "o29 backup offsite hosts on B lists A's host id and apps" grep -q "$hid.*notes" "$E/hosts.out"
"$R" restore --from-host "$hid" --all --yes -H b > "$E/dr.out" 2>&1; rc=$?; cat "$E/dr.out" >&2
check "o30 restore --from-host --all: notes recreated, its data restored, the next command printed (rc=$rc)" \
  eval '[ $rc = 0 ] && grep -q "tando up -H b --yes" "$E/dr.out" && srvB "test -f /opt/tando/apps/notes/app.conf"'
check "o31 its env came across, server to server (NOTES_TEST set on A)" \
  srvB "sudo grep -q '^NOTES_TEST=\"offsite-env-value\"' /opt/tando/apps/notes/env"
"$R" up -H b --yes > "$E/upB.out" 2>&1; cat "$E/upB.out" >&2
check "o32 tando up -H b: B serves the restored data and database ($(page "$H2"), A: $want)" test "$(page "$H2")" = "$want"
t_done
