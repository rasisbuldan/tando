#!/bin/bash
# Node rebuild and offsite restore drill (not part of the test tiers): export the apps'
# definitions, take offsite backups, destroy the apps, bring them back from the offsite copy
# alone, and check that the data is the same.
#
#   bench/rebuild-drill.sh <host> [--target <host2>] [--apps K] [--rows N] [--out DIR]
#                          [--fake-s3 <docker container of the server>]
#
#   <host>      a server registered with `tando host add`, set up with postgres=yes, with offsite
#               backups configured (`tando backup offsite set`; a real bucket such as R2 or any
#               S3-compatible store). With --fake-s3 the drill starts a throwaway S3 server of
#               its own (srv/offsite/testdata/fakes3, needs docker and go here) and configures
#               it on a DOCKER TEST server: for the smoke run, never for a real server.
#   --target    restore onto another registered server (the rebuilt node) instead of onto <host>.
#               It must be set up (postgres=yes) and have the same bucket and the recovery key:
#               see "The manual parts" below. Without --target the apps are destroyed and restored on
#               <host> itself (the data path is the same; the fresh VM is what is not exercised).
#   --apps K    drill apps (default 2: fb-rd1 ... ), each examples/notes: PostgreSQL rows, a file in
#               its data directory, env variables, a domain-less link.
#   --rows N    notes per app (default 25).
#
# Safety: it creates, backs up, destroys and restores apps named fb-rd<k> and nothing else; it
# refuses to run if one of them exists. The offsite step then removes the apps' LOCAL backups
# (/var/backups/tando/fb-rd<k>) so that the restore can only use the offsite copy.
#
# What it does, and times:
#  1 deploy K notes apps, add rows and file lines, set env variables
#  2 export: ls --json, each app's settings (app.conf), env NAMES (never values), domains, the
#    offsite host id, to $OUT/export (a copy to keep outside the node)
#  3 `tando backup now` for each, wait until the offsite copy is uploaded
#  4 destroy the apps and remove their local backups
#  5 `tando restore --from-host <host id> fb-rd1 ...` on the target (runtimes, env, settings, data)
#  6 `tando up` of each project again (releases are not in backups), then check: the page says the
#    same rows and file lines, the env names are the same, the settings are the same
# Output: $OUT/report.md and raw files (default bench/.fleet/drill-<host>-<date>/). Exit 1 when
# a check fails.
#
# The manual parts (not scripted: they need a fresh VM and your accounts). To rebuild a lost node
# (docs/BACKUP.md, "Disaster recovery runbook"):
#  a. Provision a VM of the same size (cloud console or API); note its address. Point the new
#     VM's ssh at your key; apps_domain DNS and any wildcard record come later (step e).
#  b. `tando host add newnode admin@<address>` then `tando host setup newnode apps_domain=<same>
#     postgres=yes podman=yes` (what the old node had: `tando host ls`, the export's setup notes).
#  c. `tando backup offsite key --import -H newnode` (paste the recovery key from your password
#     manager: it is shown once, at `offsite set` on the old node) and `tando backup offsite set
#     -H newnode` (the same bucket, an access key that may read).
#  d. `bench/rebuild-drill.sh <old host> --target newnode` (or by hand: `tando backup offsite
#     hosts -H newnode`, `tando restore --from-host <id> --all -H newnode`, then `tando up -H
#     newnode --yes` in each project).
#  e. DNS: point the apps' domains (and the wildcard) at the new address; Caddy gets certificates.
#  f. `tando ls -H newnode`, `tando doctor newnode`, then take a first offsite backup there.
# Time every manual step once; the drill's report gives the scripted ones.
set -u
# shellcheck source=bench/fleet-common.sh
. "$(cd "$(dirname "$0")" && pwd -P)/fleet-common.sh"

K=2 ROWS=25 OUT="" TARGET="" FAKE="" HOST=""
while [ $# -gt 0 ]; do
  case $1 in
    --apps) K=$2; shift;;
    --rows) ROWS=$2; shift;;
    --out) OUT=$2; shift;;
    --target) TARGET=$2; shift;;
    --fake-s3) FAKE=$2; shift;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0;;
    -*) fb_die "unknown option $1";;
    *) [ -z "$HOST" ] && HOST=$1 || fb_die "one host only";;
  esac
  shift
done
[ -n "$HOST" ] || fb_die "usage: bench/rebuild-drill.sh <host> [--target host2] [--fake-s3 container] (see the head of the file)"
case $K in ''|*[!0-9]*|0) fb_die "--apps needs a number";; esac
command -v npm > /dev/null || fb_die "npm is needed here (examples/notes)"
fb_init "$HOST"
SRC_SSHO=("${FB_SSHO[@]}"); SRC_TARGET=$FB_TARGET
[ -n "$OUT" ] || OUT=$FB_ROOT/bench/.fleet/drill-$HOST-$(date +%Y%m%d-%H%M%S)
W=$OUT/w REP=$OUT/report.md EXP=$OUT/export
mkdir -p "$W" "$EXP"
DEST=${TARGET:-$HOST}
[ -z "$TARGET" ] || [ -f "$CFG/hosts/$TARGET" ] || fb_die "target host '$TARGET' is not registered"
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
rep() { printf '%s\n' "$*" >> "$REP"; }
T() { "$TANDO" "$@"; }
FAILS=0
check() { # text, then a command
  local t=$1; shift
  if "$@"; then rep "- PASS $t"; else rep "- **FAIL $t**"; FAILS=$((FAILS + 1)); fi
}
on() { # host cmd... : fb_init for that host, run, restore the source's ssh options
  local h=$1; shift
  fb_init "$h"; "$@"; local rc=$?
  fb_init "$HOST"; return $rc
}
sec() { # seconds since $1 (ms)
  echo $(( ($(now_ms) - $1) / 1000 ))
}

names=""; i=1; while [ $i -le "$K" ]; do names="$names fb-rd$i"; i=$((i + 1)); done
fb_apps | awk '{ print $1 }' | grep -E '^fb-rd[0-9]+$' > "$OUT/existing" && { echo "refusing: $(tr '\n' ' ' < "$OUT/existing")already exist on $HOST (destroy them or use a server of its own)" >&2; exit 2; }

# ---- optional: a throwaway S3 for a Docker test server -------------------------------------
S3C=""
if [ -n "$FAKE" ]; then
  command -v go > /dev/null && command -v docker > /dev/null || fb_die "--fake-s3 needs go and docker here"
  docker container inspect "$FAKE" > /dev/null 2>&1 || fb_die "no docker container named $FAKE (--fake-s3 takes the test server's container name)"
  arch=$(docker info --format '{{.Architecture}}' 2> /dev/null); case $arch in aarch64|arm64) arch=arm64;; *) arch=amd64;; esac
  mkdir -p "$OUT/s3"; S3C=$FAKE-fbs3
  (cd "$FB_ROOT/srv" && CGO_ENABLED=0 GOOS=linux GOARCH=$arch GOTOOLCHAIN=local go build -o "$OUT/s3/fakes3" ./offsite/testdata/fakes3) || fb_die "cannot build fakes3"
  docker rm -f "$S3C" > /dev/null 2>&1
  docker run -d --name "$S3C" --label tando.test=1 -v "$OUT/s3:/s3" ubuntu:24.04 /s3/fakes3 -addr :9000 -bucket fb-drill \
    -access FBDRILLACCESS01 -secret fb-drill-secret-0123456789 -names s3.test -ca /s3/ca.pem > /dev/null || fb_die "cannot start the fake S3"
  end=$((SECONDS + 20)); while [ ! -s "$OUT/s3/ca.pem" ] && [ $SECONDS -lt $end ]; do sleep 0.5; done
  s3ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$S3C")
  docker exec -i "$FAKE" sh -c "tee /usr/local/share/ca-certificates/fb-s3.crt > /dev/null && update-ca-certificates > /dev/null 2>&1 && echo '$s3ip s3.test' >> /etc/hosts" < "$OUT/s3/ca.pem"
  printf 'endpoint=https://s3.test:9000\nbucket=fb-drill\naccess_key_id=FBDRILLACCESS01\nsecret_access_key=fb-drill-secret-0123456789\n' | T backup offsite set -H "$HOST" > "$OUT/offsite-set.out" 2>&1 ||
    { cat "$OUT/offsite-set.out" >&2; fb_die "offsite set against the fake S3 failed"; }
  grep -o 'tando-key-[a-z2-7-]*' "$OUT/offsite-set.out" | head -1 > "$OUT/recovery.key"; chmod 600 "$OUT/recovery.key"
  T backup offsite key --saved -H "$HOST" > /dev/null 2>&1
  trap 'docker rm -f "$S3C" > /dev/null 2>&1' EXIT
fi
T backup offsite status -H "$HOST" > "$OUT/offsite-status.out" 2>&1
grep -qi 'bucket' "$OUT/offsite-status.out" || { cat "$OUT/offsite-status.out" >&2; echo "offsite backups are not configured on $HOST: tando backup offsite set -H $HOST (see docs/BACKUP.md)" >&2; exit 2; }
HID=$(rsh "sudo sed -n 's/^host_id=//p' /opt/tando/offsite.id" | tr -d '\r')
[ -n "$HID" ] || fb_die "no offsite host id on $HOST"

rep "# Rebuild and restore drill: $HOST${TARGET:+ -> $TARGET}"
rep ""
rep "- date: $(date -u +%Y-%m-%d\ %H:%M) UTC; apps: $names; $ROWS rows each; offsite: $([ -n "$FAKE" ] && echo "throwaway fake S3 (smoke run)" || echo "the configured bucket"); restore target: $DEST"
rep ""

# ---- 1. the apps -----------------------------------------------------------------------------
mkdir -p "$W/base"
rsync -a --exclude node_modules "$FB_ROOT/examples/notes/" "$W/base/"
(cd "$W/base" && npm ci --no-audit --no-fund > "$OUT/npm.out" 2>&1) || fb_die "npm ci failed: $OUT/npm.out"
url_of() { # app on host $2
  T ls -H "$2" --json 2> /dev/null | python3 -I -c '
import json, sys
for a in json.load(sys.stdin)["apps"]:
    if a["app"] == sys.argv[1]: print(a.get("link") or "")' "$1"
}
t0=$(now_ms)
for a in $names; do
  rsync -a "$W/base/" "$W/$a/"
  sed -i.bak "s/^app = .*/app = $a/" "$W/$a/tando.conf"; rm -f "$W/$a/tando.conf.bak"
  (cd "$W/$a" && T up --yes -H "$HOST" > "$W/$a.up.log" 2>&1) || { cat "$W/$a.up.log" >&2; fb_die "deploy of $a failed"; }
  u=$(url_of "$a" "$HOST")
  j=1; while [ $j -le "$ROWS" ]; do curl -s -m 10 -X POST "$u/notes?text=row-$a-$j" > /dev/null; j=$((j + 1)); done
  (cd "$W/$a" && T env set -H "$HOST" DRILL_MARK="mark-$a" DRILL_OTHER=two > /dev/null 2>&1)
  got=$(curl -s -m 10 "$u/")
  echo "$a $got" >> "$OUT/expected.txt"
done
rep "## Scripted steps (seconds)"
rep ""
rep "| step | seconds |"; rep "|---|---|"
rep "| 1 deploy $K apps, $ROWS rows and file lines each, env set | $(sec "$t0") |"

# ---- 2. export ---------------------------------------------------------------------------
t0=$(now_ms)
T ls -H "$HOST" --json > "$EXP/ls.json" 2> /dev/null
T backup offsite hosts -H "$HOST" > "$EXP/offsite-hosts.txt" 2>&1
for a in $names; do
  rsh "sudo cat /opt/tando/apps/$a/app.conf" > "$EXP/$a.app.conf" 2> /dev/null
  T env ls -a "$a" --names -H "$HOST" > "$EXP/$a.env-names.txt" 2> /dev/null
  T domain ls "$a" -H "$HOST" > "$EXP/$a.domains.txt" 2> /dev/null
  cp "$W/$a/tando.conf" "$EXP/$a.tando.conf"
done
echo "$HID" > "$EXP/offsite-host-id.txt"
rep "| 2 export definitions and env names | $(sec "$t0") |"

# ---- 3. offsite backups ----------------------------------------------------------------------
t0=$(now_ms)
for a in $names; do
  T backup now -a "$a" -H "$HOST" > "$W/$a.backup.log" 2>&1 || { cat "$W/$a.backup.log" >&2; fb_die "backup of $a failed"; }
done
uploaded() { # every drill app's newest backup is offsite
  local a w
  for a in $names; do
    w=$(T backup ls -a "$a" -H "$HOST" --json 2> /dev/null | python3 -I -c '
import json, sys
b = json.load(sys.stdin).get("backups", [])
print(b[0].get("where") if b else "")')
    case $w in both|offsite) ;; *) return 1;; esac
  done
}
end=$((SECONDS + 300)); until uploaded; do [ $SECONDS -lt $end ] || { rep "- **FAIL the offsite upload did not finish in 300 s**"; cat "$REP"; exit 1; }; sleep 3; done
rep "| 3 backup now + offsite upload, all apps | $(sec "$t0") |"

# ---- 4. destroy ----------------------------------------------------------------------------
t0=$(now_ms)
for a in $names; do
  case $a in fb-rd[0-9]*) ;; *) fb_die "refusing to destroy $a";; esac
  T destroy -a "$a" -H "$HOST" --yes > "$W/$a.destroy.log" 2>&1 || { cat "$W/$a.destroy.log" >&2; fb_die "destroy of $a failed"; }
  rsh "sudo rm -rf /var/backups/tando/$a"
done
rep "| 4 destroy the apps and their local backups | $(sec "$t0") |"
gone=$(fb_apps | awk '{ print $1 }' | grep -cE '^fb-rd[0-9]+$')
check "the apps are gone from $HOST ($gone left)" test "$gone" = 0
check "no local backup is left (only the offsite copy)" eval '! rsh "sudo ls /var/backups/tando/ 2>/dev/null" | grep -q "^fb-rd"'

# ---- 5. restore from the offsite copy -----------------------------------------------------
t0=$(now_ms)
# shellcheck disable=SC2086
T restore --from-host "$HID" $names --yes -H "$DEST" > "$OUT/restore.out" 2>&1; rc=$?
rep "| 5 restore --from-host (runtimes, env, settings, data, database) | $(sec "$t0") (rc=$rc) |"
[ $rc = 0 ] || { cat "$OUT/restore.out" >&2; rep ""; rep "**FAIL: restore exited $rc**: $OUT/restore.out"; cat "$REP"; exit 1; }

# ---- 6. deploy the code again, then verify ---------------------------------------------------
t0=$(now_ms)
for a in $names; do
  (cd "$W/$a" && T up --yes -H "$DEST" > "$W/$a.up2.log" 2>&1) || { cat "$W/$a.up2.log" >&2; rep "- **FAIL tando up of $a on $DEST**"; FAILS=$((FAILS + 1)); }
done
rep "| 6 tando up of each project on $DEST (releases are not in backups) | $(sec "$t0") |"
rep ""
rep "## Checks"
rep ""
for a in $names; do
  u=$(url_of "$a" "$DEST"); want=$(awk -v a="$a" '$1 == a { $1 = ""; print substr($0, 2) }' "$OUT/expected.txt")
  end=$((SECONDS + 60)); got=""
  while [ $SECONDS -lt $end ]; do got=$(curl -s -m 10 "$u/"); [ "$got" = "$want" ] && break; sleep 2; done
  check "$a: page says '$got' (before: '$want'): database rows and data-directory lines survived" test "$got" = "$want"
  T env ls -a "$a" --names -H "$DEST" > "$OUT/$a.env-names.after" 2> /dev/null
  check "$a: env names are the same" cmp -s "$EXP/$a.env-names.txt" "$OUT/$a.env-names.after"
  rsh_dest() { on "$DEST" rsh "$@"; }
  rsh_dest "sudo cat /opt/tando/apps/$a/app.conf" > "$OUT/$a.app.conf.after" 2> /dev/null
  pick() { grep -E '^(recipe|memory|database|start|idle_stop|data|health)=' "$1" | sort; }
  check "$a: settings (recipe, memory, database, start, data, health) are the same" eval 'pick "$EXP/$a.app.conf" > "$OUT/$a.s1"; pick "$OUT/$a.app.conf.after" > "$OUT/$a.s2"; [ -s "$OUT/$a.s1" ] && cmp -s "$OUT/$a.s1" "$OUT/$a.s2"'
  mark=$(cd "$W/$a" && T ssh -a "$a" -H "$DEST" -- printenv DRILL_MARK 2> /dev/null | tr -d '\r')
  check "$a: the env value reached the app (DRILL_MARK=$mark)" test "$mark" = "mark-$a"
done
rep ""
rep "Raw files and the export (definitions and env names, no values): $OUT"
rep ""
if [ -n "$FAKE" ]; then
  rep "The recovery key of this throwaway bucket is in $OUT/recovery.key (a smoke run: delete the directory when done)."
fi
# leave nothing behind unless asked: the drill apps are bench apps
for a in $names; do T destroy -a "$a" -H "$DEST" --purge --yes > /dev/null 2>&1; done
echo; cat "$REP"
[ "$FAILS" = 0 ] || { echo "drill: $FAILS check(s) failed" >&2; exit 1; }
echo "drill: every check passed" >&2
