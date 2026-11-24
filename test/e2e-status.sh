#!/bin/bash
# End-to-end test of tando-status (srv/status): the read-only verbs of tando-agent in Go against
# their shell versions, on the same server state. The agent execs tando-status for status,
# deploy-status, releases, history, busy and info; this suite runs a copy of the agent without
# that delegation as the reference ("sh"), and for every verb and argument form compares, in one
# ssh call, sh, Go, sh again: stdout, stderr and exit status must be the same bytes. Numbers that
# change between two calls (uptime, cpu time, memory, load, log counts, seconds left) may differ,
# but only within what the two shell runs around the Go run bracket; everything else is exact.
# Status is compared three ways: shell, Go through tandod (it runs; checked) and, with tandod
# stopped, Go answering directly (6*). 7*: a stop, start and deploy show in the very next status.
#
#   test/e2e-status.sh [--reset]     --reset: recreate the server first (only one this suite owns)
#   test/e2e-status.sh --reuse       keep the server and its apps; only compare again
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT (default tando-testvm).
# Apps: web (node, a job, a domain with an internal-CA certificate, a redeploy), site (static),
# halt (stopped), crashy (exits 4 s after start: a crash loop), db (PostgreSQL; installs it from
# the distribution: needs the network, SKIP without), slow (a 30 s soak: compared mid-activation,
# with a second deploy queued behind it), and two written by hand: legacy (an adopted app's
# app.conf: its own user, check_url, caddy=external) and odd (damaged state and history files,
# junk in releases/), plus a directory without app.conf. Output: PASS/FAIL lines, summary.
set -u
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
REUSE=0; [ "${1:-}" = --reuse ] && REUSE=1
if [ $REUSE = 1 ]; then
  # t_init empties the work directory; --reuse keeps the config (the host entry)
  T_WORK=${T_WORK:-$(cd "$(dirname "$0")" && pwd -P)/.status-${TANDO_TEST_NAME:-tando-testvm}}
  keep=$(mktemp -d); cp -R "$T_WORK/cfg" "$keep/" 2> /dev/null
fi
t_init status
[ $REUSE = 1 ] && { cp -R "$keep/cfg/." "$E/cfg/"; rm -rf "$keep"; }
srv() { "$SSH" "$@"; }
W=$E/w

# hello <app>: a copy of examples/hello named <app> in $W
hello() {
  mkdir -p "$W/$1"; cp "$ROOT/examples/hello/server.js" "$ROOT/examples/hello/VERSION" "$W/$1/"
  printf 'app = %s\nrecipe = node\nstart = node server.js\nhealth = /health\nmemory = 128M\nhealth_timeout = 15\n' \
    "$1" > "$W/$1/tando.conf"
}

setup() {
  if [ "${1:-}" = --reset ]; then t_server_up --reset || exit 1; else t_server_up || exit 1; fi
  t_host_add test
  "$R" host setup test public_port="$T_HTTP_PORT" domain_tls=internal >&2 || exit 1
  local a
  for a in web halt crashy db slow; do hello "$a"; done
  printf 'job.tick = hourly | true\n' >> "$W/web/tando.conf"
  printf 'database = postgres\n' >> "$W/db/tando.conf"
  # crashy: healthy long enough for the 2 s soak, then exits; systemd restarts it, again and again
  printf '\nsetTimeout(() => process.exit(3), 4000);\n' >> "$W/crashy/server.js"
  cp -R "$ROOT/examples/site" "$W/site"
  for a in web site halt crashy; do (cd "$W/$a" && "$R" up >&2) || exit 1; done
  (cd "$W/web" && echo 2 > VERSION && "$R" deploy >&2) || exit 1
  (cd "$W/web" && TANDO_TEST_RESOLVE="shop.test=127.0.0.1,www.shop.test=127.0.0.1" "$R" domain add shop.test >&2)
  (cd "$W/halt" && "$R" stop >&2)
  (cd "$W/db" && "$R" up >&2) || log "db: no PostgreSQL (needs the network); compared without it"
  (cd "$W/slow" && "$R" up >&2) || exit 1
  # written by hand: an adopted app's app.conf (as tando-adopt writes it) and a damaged one
  srv 'sudo bash -s' <<'EOF'
set -e
R=/opt/tando/apps
install -d -m 751 $R/legacy $R/legacy/releases/20261101-120000 $R/legacy/releases/20261102-120000 $R/legacy/incoming
printf '%s\n' adopted_from=legacy-next caddy=external check_url=https://legacy.example.net created=1800000000 \
  health=/api/health health_timeout=60 memory=512M next_cache=release path=/app port=4190 preflight_port=4191 \
  recipe=next start='node server.js' user=www-data 'job.sync=*:0/15 | node sync.js' > $R/legacy/app.conf
printf '%s\n' current=20261102-120000 last_good=20261102-120000 phase=idle seq_20261101-120000=1 \
  seq_20261102-120000=2 status_20261101-120000=verified status_20261102-120000=verified \
  migrated_20261101-120000=no migrated_20261102-120000=yes prerelease_20261102-120000=20261102-110000-predeploy > $R/legacy/state
install -d -m 751 $R/odd $R/odd/releases/20261103-000000 $R/odd/releases/20261103-000000-2 $R/odd/releases/junk \
  $R/odd/releases/20261103-000001
printf 'port=4192\nrecipe=node\ndomains=a.odd.test|off  b.odd.test|redirect\nbackup=daily\n' > $R/odd/app.conf
# (git_<id>: the release's provenance, "sha:changed files:branch"; the history lines 4 to 6 carry it as the
# 14th field, after "-" or the release command's seconds; a 15th field is no record)
printf 'current=20261103-000000-2\nseq_20261103-000000=x\nseq_20261103-000000-2=007\nnoequals\n=novalue\nstatus_20261103-000000-2=verified\ngit_20261103-000000-2=0123456789abcdef0123456789abcdef01234567:3:feat/x\nmigrated_20261103-000000-2=?\nmigrated_20261103-000000=\nmigrated_20261103-000001=yes\nprerelease_20261103-000001=x\ty\nstopped=1' \
  > $R/odd/state
# shared-file records (skew_rows): of pruned releases (one with an .end, one with a bad .end), of a
# kept release and of the current one; only the first is a skew row (a verb's recovery may run
# assets_expire on the app: the bad one goes then, the others stay as they are)
install -d -m 700 $R/odd/assetlog
for i in 20261102-000000 20261102-000001 20261103-000000 20261103-000000-2; do : > $R/odd/assetlog/$i; : > $R/odd/assetlog/$i.spec; done
echo 1800000000 > $R/odd/assetlog/20261102-000000.end
echo 1800000100 > $R/odd/assetlog/20261103-000000.end
echo x1 > $R/odd/assetlog/20261102-000001.end
printf '1\t20261103-000000\tdeploy\tok\t1\t0\t0\t-\t-\t-\t-\tfirst\nshort\tline\n\n2\t20261103-000000-2\tdeploy\tfailed\t1\t0\t0\t-\t-\t-\t-\tbad \303\251 note\n3\t20261103-000000-2\trollback\tok\t1\t0\t0\t-\t-\t-\t-\tlast\n4\t20261103-000000-2\tdeploy\tok\t1\t0\t0\t-\t-\t-\t-\twith git\t-\t0123456789abcdef0123456789abcdef01234567:3:feat/x\n5\t20261103-000000-2\tdeploy\tok\t1\t0\t0\t-\t-\t-\t-\twith git and release\t2.5\t0123456789abcdef0123456789abcdef01234567:0:-\n6\t20261103-000000-2\tdeploy\tok\t1\t0\t0\t-\t-\t-\t-\ttoo many\t-\tx\ty\n' \
  > $R/odd/history.tsv
printf 'id=20261103-000001\nresult=failed\nphase=done\nmessage=it went down\n' > $R/odd/activation
printf 'log line one\n\033[31mred\033[0m\nunterminated' > $R/odd/activation.log
chmod 600 $R/odd/activation.log
install -d -m 755 $R/halfgone/releases
# a restore cut off in its database step (rs_end records restore_cut and the three keys status shows)
install -d -m 751 $R/cut $R/cut/releases/20261104-000000
printf 'port=4193\nrecipe=node\n' > $R/cut/app.conf
printf '%s\n' current=20261104-000000 last_good=20261104-000000 phase=idle seq_20261104-000000=1 status_20261104-000000=verified \
  'restore_cut=the restore of backup 20261104-010101-manual stopped while the database was being replaced' \
  restore_cut_id=20261104-010101-manual restore_cut_safety=20261104-020202-safety restore_cut_what=database > $R/cut/state
EOF
}

# ---- comparing -----------------------------------------------------------------------------------

# the reference: the installed agent without the block that execs tando-status
ref_install() {
  sed '/^# >>> tando-status/,/^# <<< tando-status/d' "$ROOT/server/tando-agent" |
    srv 'sudo install -d -m 755 /var/tmp/tando-status-cmp && sudo tee /var/tmp/tando-status-cmp/agent > /dev/null &&
         sudo chmod 644 /var/tmp/tando-status-cmp/agent'
}

# run_case <sudo|user> verb args...: sh, Go, sh on the server, each output section after a marker
run_case() {
  local s=$1; shift
  local p=""; [ "$s" = sudo ] && p="sudo -n "
  # lint: allow RL04 the arguments are this suite's own words
  srv "o=\$(mktemp) e=\$(mktemp); for k in 1 2 3; do
         if [ \$k = 2 ]; then ${p}/opt/tando/bin/tando-agent $* > \$o 2> \$e; else ${p}bash /var/tmp/tando-status-cmp/agent $* > \$o 2> \$e; fi
         echo \"@@out \$k \$?\"; cat \$o; echo; echo \"@@err \$k\"; cat \$e; echo
       done; rm -f \$o \$e" 2> /dev/null
}

# split <file> <dir>: the six sections into dir/{o,e}{1,2,3} and dir/rc{1,2,3} (the echo after each
# section is removed again, so a missing final newline is seen)
split_case() {
  awk -v d="$2" '
    /^@@out [123] / { if (f) close(f); n = $2; print $3 > (d "/rc" n); close(d "/rc" n); f = d "/o" n; printf "" > f; next }
    /^@@err [123]$/ { if (f) close(f); f = d "/e" $2; printf "" > f; next }
    { print >> f }' "$1"
  local x; for x in "$2"/o? "$2"/e?; do perl -0pi -e 's/\n\z//' "$x"; done
}

# same <dir>: Go (2) against the shell runs (1, 3). Exit status and stderr exact; stdout line by
# line, field by field: equal to one shell run, or for a changing number within the two runs
# (with a small margin for the ones that are not monotonic). Prints the first difference.
same() {
  local d=$1
  [ "$(cat "$d/rc2")" = "$(cat "$d/rc1")" ] || { echo "  exit status: go $(cat "$d/rc2"), sh $(cat "$d/rc1")" >&2; return 1; }
  cmp -s "$d/e2" "$d/e1" || cmp -s "$d/e2" "$d/e3" || { echo "  stderr differs:" >&2; diff "$d/e1" "$d/e2" >&2; return 1; }
  awk -F '\t' '
    function num(x) { return x ~ /^-?[0-9]+(\.[0-9]+)?$/ }
    function vol(t, i) {   # changing numbers: row type and field
      if (t == "host") return i == 4 || i == 6 || i == 8 || i == 9
      if (t == "app") return i == 7 || i == 9 || i == 10 || i == 11 || i == 17 || i == 19 || i == 20
      if (t == "mx") return i == 3
      if (t == "server") return i == 2                  # the server clock: seconds between the runs
      if (t == "m") return i >= 2
      if (t == "busy_left" || t == "waiting_left") return i == 2
      return 0
    }
    function margin(t, i, v) {
      if (t == "host" && i == 4) return 0.3
      if (t == "app" && i == 9) return 0               # cpu time only grows: between the two runs
      if (t == "app" && i == 10) return 1
      if ((t == "host" && i == 9) || (t == "app" && i == 11) || t == "mx" || t == "server" || t ~ /_left$/) return 2
      return v * 0.05 + 65536                            # memory, disk, log sizes and counts
    }
    FNR == 1 { file++ }
    { line[file, FNR] = $0; n[file] = FNR }
    END {
      if (n[1] != n[2] && n[3] != n[2]) { printf "  %d lines from go, %d and %d from sh\n", n[2], n[1], n[3] > "/dev/stderr"; exit 1 }
      ref = (n[1] == n[2]) ? 1 : 3; oth = (n[3] == n[2]) ? 3 : 1
      for (l = 1; l <= n[2]; l++) {
        g = line[2, l]; a = line[ref, l]; b = line[oth, l]
        if (g == a || g == b) continue
        ng = split(g, G, "\t"); na = split(a, A, "\t"); nb = split(b, B, "\t")
        if (ng == 1 && g ~ /^[a-z_]+=/) {             # key=value: the key is the type
          ng = split(g, G, "="); na = split(a, A, "="); nb = split(b, B, "=")
          G[2] = substr(g, length(G[1]) + 2); A[2] = substr(a, length(A[1]) + 2); B[2] = substr(b, length(B[1]) + 2)
          ng = na = nb = 2
        }
        if (ng != na) { printf "  line %d: %d fields, sh %d\n  go %s\n  sh %s\n", l, ng, na, g, a > "/dev/stderr"; exit 1 }
        for (i = 1; i <= ng; i++) {
          if (G[i] == A[i] || (nb == ng && G[i] == B[i])) continue
          t = G[1]
          if (vol(t, i) && num(G[i]) && num(A[i])) {
            lo = A[i]; hi = A[i]
            if (nb == ng && num(B[i])) { if (B[i] + 0 < lo + 0) lo = B[i]; if (B[i] + 0 > hi + 0) hi = B[i] }
            m = margin(t, i, hi + 0)
            if (G[i] + 0 >= lo - m && G[i] + 0 <= hi + m) continue
          }
          printf "  line %d field %d differs\n  go %s\n  sh %s\n  sh %s\n", l, i, g, a, b > "/dev/stderr"; exit 1
        }
      }
    }' "$d/o1" "$d/o2" "$d/o3"
}

# unbound_row <dir>: the one difference allowed for `status <app>` without root: the shell died
# of set -u on the app.conf it may not read (C[port]: unbound variable) and printed no app row; Go
# prints the row (with "-" for what it cannot read). Removed here, then compared as usual.
unbound_row() {
  local d=$1 k
  for k in 1 3; do
    grep -q 'C\[port\]: unbound variable$' "$d/e$k" || return 0
    : > "$d/e$k"
  done
  grep -v "^app	" "$d/o2" > "$d/o2.x"; mv "$d/o2.x" "$d/o2"
}

N=0
# cmp_case <id> <sudo|user> verb args...: compare, up to 3 tries (a crash-looping app may change
# state between the runs; the tries are logged)
cmp_case() {
  local id=$1 s=$2; shift 2
  local d=$E/cmp/$id try=0
  mkdir -p "$d"
  while [ $try -lt 3 ]; do
    try=$((try + 1))
    run_case "$s" "$@" > "$d/raw"
    split_case "$d/raw" "$d"
    [ "$s:$1:$#" = user:status:2 ] && unbound_row "$d"
    if same "$d" 2> "$d/why"; then
      [ $try = 1 ] || log "$id: same on try $try"
      pass "$id $s $* (go = sh, $(wc -l < "$d/o2" | tr -d ' ') lines, rc $(cat "$d/rc2"))"
      N=$((N + 1))
      return 0
    fi
  done
  cat "$d/why" >&2
  fail "$id $s $* (go differs from sh, see $d)"
}

apps() { srv 'ls /opt/tando/apps'; }
ids() { srv "sudo ls /opt/tando/apps/$1/releases" | grep -E '^[0-9]{8}-[0-9]{6}(-[0-9]+)?$'; }

compare_all() {
  local a i k=0 id
  cmp_case 1a sudo status
  cmp_case 1b user status
  cmp_case 1c sudo info
  cmp_case 1d user info
  cmp_case 1e sudo history
  cmp_case 1f user history
  cmp_case 1g sudo history 2   # a lone number is the count, over all apps
  cmp_case 1h user history 0
  for a in $(apps); do
    k=$((k + 1))
    cmp_case "2.$k.a" sudo status "$a"
    cmp_case "2.$k.b" sudo releases "$a"
    cmp_case "2.$k.c" sudo history "$a"
    cmp_case "2.$k.d" sudo history "$a" 3
    cmp_case "2.$k.e" sudo busy "$a"
    cmp_case "2.$k.f" user releases "$a"
    cmp_case "2.$k.g" user status "$a"
    i=0
    for id in $(ids "$a" | tail -3) 20200101-000000; do
      i=$((i + 1))
      cmp_case "2.$k.h$i" sudo deploy-status "$a" "$id"
    done
  done
  # a cut restore is one row, from the shell and from Go: the backup to restore again, the safety backup
  local want="restorecut	cut	20261104-010101-manual	20261104-020202-safety	database" how2
  for how2 in "/opt/tando/bin/tando-agent" "bash /var/tmp/tando-status-cmp/agent"; do
    # lint: allow RL04 the agent paths are this suite's own words
    check "2z status of an app whose restore was cut shows the restorecut row ($how2)" \
      t_eq "$(srv "sudo $how2 status cut" | grep "^restorecut	")" "$want"
  done
  # errors: the same message and exit status
  cmp_case 3a sudo status Bad_Name
  cmp_case 3b sudo status nosuch
  cmp_case 3c sudo status halfgone
  cmp_case 3d sudo releases nosuch
  # no app at all: the shell versions died of `set -u` ("$1: unbound variable"); the same exit
  # status, and the message of a bad name
  for v in releases busy deploy-status; do
    run_case sudo "$v" > "$E/cmp/3e-$v.raw"; mkdir -p "$E/cmp/3e-$v"; split_case "$E/cmp/3e-$v.raw" "$E/cmp/3e-$v"
    check "3e $v without an app: exit 1 as before, 'invalid app name' instead of 'unbound variable'" \
      eval '[ "$(cat "$E/cmp/3e-$v/rc1")$(cat "$E/cmp/3e-$v/rc2")" = 11 ] && grep -q "unbound variable" "$E/cmp/3e-$v/e1" &&
            [ "$(cat "$E/cmp/3e-$v/e2")" = "tando-agent: invalid app name" ]'
  done
  cmp_case 3f sudo deploy-status web bad-id
  cmp_case 3g sudo deploy-status nosuch 20261101-000000
  cmp_case 3h sudo deploy-status web
  cmp_case 3i sudo history web x
  cmp_case 3j sudo history Bad 5
  cmp_case 3k sudo history nosuch 5
  cmp_case 3l user busy web
  cmp_case 3m sudo busy nosuch
  cmp_case 3n sudo history web 0
  cmp_case 3o sudo history web 0010
}

# mid-activation: slow's next release soaks 30 s, the app's lock held (the comparisons 4a-4g take
# about 3 s, also on a busy machine, and 4h fails if the soak ended under them). A release queued behind it
# is what `activate` leaves before its activation gets the lock: a directory in releases/ without
# a status (the client itself waits out a soak before it uploads, so one is made here by hand)
mid_activation() {
  [ -d "$W/slow" ] || hello slow   # (--reuse: the work directory was emptied)
  printf 'soak = 30\n' >> "$W/slow/tando.conf"
  echo 2 > "$W/slow/VERSION"
  (cd "$W/slow" && TANDO_WAIT=1 "$R" deploy --force > "$E/slow1.out" 2>&1) &   # (--reuse: maybe another checkout last)
  local p1=$! cur q=20991231-000000
  t_until 90 eval 'srv "sudo grep -qx phase=soak /opt/tando/apps/slow/activation"' || { fail "4 slow never reached its soak"; return; }
  cur=$(srv "sudo sed -n 's/^target=//p' /opt/tando/apps/slow/state")
  cmp_case 4a sudo status
  cmp_case 4b sudo status slow
  cmp_case 4c sudo deploy-status slow "$cur"
  cmp_case 4d sudo busy slow
  cmp_case 4e user deploy-status slow "$cur"
  srv "sudo mkdir /opt/tando/apps/slow/releases/$q"
  cmp_case 4f sudo deploy-status slow "$q"
  cmp_case 4g sudo releases slow
  check "4h still soaking while the comparisons ran" srv "sudo grep -qx phase=soak /opt/tando/apps/slow/activation"
  srv "sudo rmdir /opt/tando/apps/slow/releases/$q"
  wait $p1
  cmp_case 4i sudo deploy-status slow "$cur"
  cmp_case 4j sudo busy slow
}

# fresh: a status from tandod is collected when asked, not at the last tick: a stop, a start and a
# deploy show in the very next `tando ls` / `tando status`
fresh() {
  [ -d "$W/halt" ] || hello halt   # (--reuse: the work directory was emptied)
  local st
  (cd "$W/halt" && "$R" start > /dev/null 2>&1)
  st=$(srv 'sudo /opt/tando/bin/tando-agent status halt' | awk -F '\t' '$1 == "app" { print $3 }')
  check "7a after tando start, the next status says it runs ($st)" t_eq "$st" active
  (cd "$W/halt" && "$R" stop > /dev/null 2>&1)
  "$R" ls > "$E/ls-stop.out" 2>&1
  check "7b after tando stop, the very next tando ls shows it stopped" grep -Eq 'halt +.*stopped' "$E/ls-stop.out"
  echo 9 > "$W/halt/VERSION"
  (cd "$W/halt" && "$R" deploy --force > "$E/fresh-deploy.out" 2>&1)
  local id; id=$(srv 'sudo sed -n "s/^current=//p" /opt/tando/apps/halt/state')
  "$R" status -a halt > "$E/st-deploy.out" 2>&1
  check "7c after a deploy, the very next tando status shows its release ($id)" grep -q "${id:-none}" "$E/st-deploy.out"
  (cd "$W/halt" && "$R" stop > /dev/null 2>&1)
  cmp_case 7d sudo status
}

# direct_pass: the status forms again, tandod stopped (Go answering itself)
direct_pass() {
  local a k=0
  cmp_case 6b sudo status
  cmp_case 6c user status
  for a in $(apps); do
    k=$((k + 1))
    cmp_case "6d.$k" sudo status "$a"
  done
}

if [ $REUSE = 0 ]; then setup "${1:-}"; fi
ref_install
check "0 the installed agent execs tando-status, the reference copy does not" \
  srv 'grep -q "^# >>> tando-status" /opt/tando/bin/tando-agent && ! sudo grep -q "tando-status\" \"\$@\"" /var/tmp/tando-status-cmp/agent &&
       sudo /opt/tando/bin/tando-status version | grep -q .'
# status is answered by tandod when it runs (tando-status asks it first): the comparisons above
# and below go through it; then again with tandod stopped (Go answering directly)
how() { srv "sudo TANDO_STATUS_TRACE=1 /opt/tando/bin/tando-agent status $* 2>&1 > /dev/null" | sed -n 's/^tando-status: //p'; }
srv 'sudo systemctl start tandod' > /dev/null 2>&1
T_UNTIL_STEP=0.2 t_until 10 srv 'sudo test -S /run/tandod/tandod.sock' > /dev/null
check "0b tandod runs and answers status (all apps and one app)" eval '[ "$(how)" = "via tandod" ] && [ "$(how web)" = "via tandod" ]'
compare_all
# (the comparison above is not empty for skew rows: the odd app has one, from both)
sk=$(srv "sudo -n /opt/tando/bin/tando-agent releases odd" 2>&1 | grep "^skew" | tr '\t' ' ')
check "0c releases has the skew row of a pruned release's shared files (until its .end + 24h), not the others ($sk)" \
  test "$sk" = "skew 20261102-000000 1800086400"
mid_activation
fresh
srv 'sudo systemctl stop tandod'
check "6a with tandod stopped status is answered directly" eval '[ "$(how)" = direct ] && [ "$(how web)" = direct ]'
direct_pass
srv 'sudo systemctl start tandod'
# the shell versions stay as the fallback: without the binary the agent answers as before
srv 'sudo mv /opt/tando/bin/tando-status /opt/tando/bin/tando-status.off'
fb=$(srv 'sudo /opt/tando/bin/tando-agent releases web | head -1; sudo /opt/tando/bin/tando-agent status | head -1 | cut -f1')
srv 'sudo mv /opt/tando/bin/tando-status.off /opt/tando/bin/tando-status'
check "5 without tando-status the agent falls back to its shell versions ($(echo $fb))" eval 'echo "$fb" | grep -q "^rel" && echo "$fb" | grep -qx host'
# what the client's monitoring reads from status (docs/COMMANDS.md, ls and status): the server
# row (its clock and version), the last minute's CPU of a running app (26th field, from
# tando-metrics once it has two samples), the backup alert's threshold with an app
srv 'sudo /opt/tando/bin/tando-agent status web' > "$E/mon.st"
sv=$(srv 'cat /opt/tando/VERSION' | head -1)
check "8a status has the server row: the server's clock (within 30 s of the laptop's) and tando version ($sv)" \
  awk -F '\t' -v now="$(date +%s)" -v v="$sv" '$1 == "server" { f = 1; d = $2 - now; if (d < 0) d = -d; ok = (d <= 30 && $3 == v) } END { exit !(f && ok) }' "$E/mon.st"
cpu1m() { srv 'sudo /opt/tando/bin/tando-agent status web' | awk -F '\t' '$1 == "app" && $26 ~ /^[0-9]+$/ { f = 1 } END { exit !f }'; }
check "8b the app row of a running app has the last minute's cpu (per mille, 26th field)" t_until 150 cpu1m
check "8c status <app> has the backup alert's threshold (backupcfg web 50 on)" grep -qx "backupcfg	web	50	on" "$E/mon.st"
"$R" ls --json > "$E/mon.json" 2>&1
check "8d ls --json: reachable, checked_at, server and client versions, skew, alerts and per-app alerts_firing" \
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["reachable"] is True and d["checked_at"] > 0 and d["server_version"] and abs(d["clock_skew_s"]) <= 30 and isinstance(d["alerts"], list) and all("alerts_firing" in a and "cpu_percent" in a for a in d["apps"])' "$E/mon.json"
# git provenance (the odd app's hand-written state and history): the Go verbs show it as the shell does
# (the comparisons above are exact); here that it is shown at all
sha=0123456789abcdef0123456789abcdef01234567
srv 'sudo /opt/tando/bin/tando-agent releases odd' > "$E/prov.rel" 2>&1
srv 'sudo /opt/tando/bin/tando-agent history odd' > "$E/prov.hist" 2>&1
srv 'sudo /opt/tando/bin/tando-agent releases legacy' > "$E/prov.web" 2>&1
check "9a releases: the release with git_<id> has the provenance as a 6th field; a release without has 5 fields" \
  eval 'awk -F "\t" -v s="$sha:3:feat/x" '"'"'$1 == "rel" && $6 == s && NF == 6 { a = 1 } END { exit !a }'"'"' "$E/prov.rel" &&
        awk -F "\t" '"'"'$1 == "rel" { n++; if (NF != 5) bad = 1 } END { exit !(n > 0 && !bad) }'"'"' "$E/prov.web"'
check "9b history: a 14th field is a record, with \"-\" for no release command; a 15th is not" \
  awk -F '\t' -v s="$sha" '$1 == "hist" && $15 == "-" && $16 == s ":3:feat/x" { a = 1 } $1 == "hist" && $15 == "2.5" && $16 == s ":0:-" { b = 1 } $1 == "hist" && $14 == "too many" { c = 1 } END { exit !(a && b && !c) }' "$E/prov.hist"
log "compared $N cases"
srv 'sudo rm -rf /var/tmp/tando-status-cmp'
t_done
