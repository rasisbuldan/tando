#!/bin/bash
# shellcheck disable=SC2329  # helpers are called through check
# test/e2e-logs.sh: end-to-end test of tando logging (journals, request log, audit) against a
# clean test server. One PASS/FAIL line per check; exits non-zero on any failure.
#
# Usage: test/e2e-logs.sh [--no-reset]
# Server: TANDO_TEST_NAME (tando-test-logs), TANDO_TEST_SSH_PORT (2304), TANDO_TEST_HTTP_PORT (8304).
# Tree:   TANDO_TREE, the directory holding bin/ lib/ server/ examples/; default: this repo when
#         bin/tando already calls lib/cmd-logx.sh, else the private copy test/.work-logs/tree.
set -u
# The suite's own server by default; another one through TANDO_TEST_* (test/all.sh sets them, with
# TANDO_TEST_OWNED=1 and T_WORK). A server is reset only when this suite owns it (docs/TESTING.md).
export TANDO_TEST_NAME=${TANDO_TEST_NAME:-tando-test-logs}
export TANDO_TEST_SSH_PORT=${TANDO_TEST_SSH_PORT:-2304} TANDO_TEST_HTTP_PORT=${TANDO_TEST_HTTP_PORT:-8304}
[ "$TANDO_TEST_NAME" = tando-test-logs ] && export TANDO_TEST_OWNED=1
# the measurements in docs/LOGGING.md assume the real server's size: 1 CPU, 2 GB
export TANDO_TEST_DOCKER_ARGS=${TANDO_TEST_DOCKER_ARGS:---cpus 1 --memory 2g}
# lint: allow RL03 this suite's own test/lib.sh, next to it
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-logs                 # ROOT, E (work dir), SSH, TANDO_CONFIG_DIR=$E/cfg, T_HTTP_PORT
if [ -z "${TANDO_TREE:-}" ]; then
  if grep -q cmd-logx "$ROOT/bin/tando"; then TANDO_TREE=$ROOT; else TANDO_TREE=$ROOT/test/.work-logs/tree; fi
fi
R=$TANDO_TREE/bin/tando W=$E/w HP=$T_HTTP_PORT

srv() { "$SSH" "$@"; }
# Traffic whose request log is checked goes through --connect-to, so its Host header carries no
# port, as a real visitor's does: Caddy 2.6.2 picks a site's request log by the Host header with
# its port and would log nothing for "req.localhost:8304" (the test's published port).
root() { "$SSH" sudo "$@"; }
emit() { # app line [err]
  curl -s -o /dev/null -G "http://$1.localhost:$HP/emit" --data-urlencode "line=$2" ${3:+--data-urlencode stream=err}
}
body() { sed 's/^[0-9-]* [0-9:]* //'; }        # drop the timestamp of a text log line
mkapp() { # name [extra tando.conf lines]: a copy of examples/logflood under another name
  rm -rf "${W:?}/$1"; cp -R "$TANDO_TREE/examples/logflood" "$W/$1"
  grep -v '^app\|^log_' "$W/$1/tando.conf" > "$W/$1/c"
  { echo "app = $1"; cat "$W/$1/c"; printf '%s' "${2:-}"; } > "$W/$1/tando.conf"
  rm -f "$W/$1/c"
}
up() { (cd "$W/$1" && "$R" up > "$E/up.$1" 2>&1); }
has_line() { "$R" logs -a "$1" -n 100000 --grep "$2" | grep -q .; }
json_ok() { # file lines
  [ "$(wc -l < "$1" | tr -d ' ')" = "$2" ] || return 1
  python3 -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]' "$1"
}
no_ctrl() { ! LC_ALL=C grep -q "$(printf '[\033\007\015]')" "$@"; }
neutral() { # h1 h2
  no_ctrl "$1" "$2" && ! LC_ALL=C grep -q "$(printf '\302[\200-\237]')" "$2" &&
    grep -q '\^\[\[2J' "$1" && grep -q 'café' "$2"
}
deploy_ok() { # file id
  # (the pre-flight port: 14100-14999 for an app made now, port + 100 for an older one)
  grep -q "^# deploy $2: ok" "$1" && grep -q '\[pre\] logflood on 1\{0,1\}4[0-9][0-9][0-9]' "$1" &&
    grep -q "\[systemd\] .*tando activation filt $2" "$1"
}
no_journal_read() { # user app (constants of this file)
  case $1$2 in *[!a-z-]*) return 1;; esac
  [ -z "$("$SSH" sudo -u "$1" journalctl --namespace="tando-$2" -q --no-pager 2> /dev/null)" ] &&
    [ -z "$("$SSH" sudo -u "$1" journalctl --namespace='*' -q --no-pager 2> /dev/null)" ] &&
    # lint: allow RL04 both checked above
    ! "$SSH" "sudo -u $1 head -c 1 /var/log/journal/*.tando-$2/system.journal" > /dev/null 2>&1
}
# no line wider than N characters (perl counts characters, macOS awk counts bytes)
fits() { local w=$1; shift; perl -CSD -ne "exit 1 if length(\$_) - 1 > $w" "$@"; }
gone() { # paths (globs expanded on the server)
  ! "$SSH" "sudo sh -c 'ls -d $* 2> /dev/null'" | grep -q .
}
owner_mode() { # path expected ("user:group mode")
  [ "$("$SSH" "sudo stat -c '%U:%G %a' $1")" = "$2" ]
}
secret_free() { # pattern written so that it does not contain the secret itself (sudo logs commands)
  ! "$SSH" "sudo grep -rqa '$1' /var/log" &&
    ! "$SSH" "sudo journalctl --namespace='*' -q --no-pager -o export" | grep -qa "$1"
}
appl() { body | grep -v '\[journald\]\|\[systemd\]'; }   # app lines only, without timestamps
lines_eq() { # expected-file actual-file
  if diff "$1" "$2" > "$E/diff" 2>&1; then return 0; fi
  sed 's/^/    /' "$E/diff" >&2; return 1
}

# wait_since <epoch> <seconds> <why>: sleep until <seconds> have passed since <epoch>; nothing when
# they already have (the checks that ran in between took the time)
wait_since() {
  local left=$(($1 + $2 - $(date +%s)))
  [ "$left" -le 0 ] || { log "waiting $left s: $3"; sleep "$left"; }
}

if [ "${1:-}" = --no-reset ]; then t_server_up || exit 1; else t_server_up --reset || exit 1; fi
mkdir -p "$W"
log "tree: $TANDO_TREE"

# ---- 1. setup ----------------------------------------------------------------------------------
t_host_add t 2> /dev/null
setup() { "$R" host setup t apps_domain=localhost tls=off public_port="$HP" journal_max=128M \
  access_size=1 access_keep=2 > "$E/setup" 2>&1; }
check "1a host setup with log settings" setup
cp -R "$TANDO_TREE/examples/hello" "$TANDO_TREE/examples/site" "$W/"
mkapp flood 'log_max = 16M
log_rate = off
'
mkapp filt
mkapp req 'access_log = on
'
for a in hello site flood filt req; do up "$a" || { fail "1b up $a"; sed 's/^/    /' "$E/up.$a" >&2; }; done
ns_dirs() { # one journal namespace per app with a process (static sites have none)
  local a
  for a in hello flood filt req; do
    "$SSH" "sudo sh -c 'ls -d /var/log/journal/*.tando-$a'" > /dev/null 2>&1 || return 1   # lint: allow RL04 constants
  done
}
check "1c apps run in their own journal namespaces" ns_dirs
check "1d main journal capped by drop-in" root grep -q 'SystemMaxUse=128M' /etc/systemd/journald.conf.d/tando.conf

# ---- 2. bounded logs: a flood far beyond the cap stays within it; other apps keep their lines ---
log "flooding: 600k lines of 100 bytes (about 60 MB) into an app capped at 16 MB"
emit filt "other-app-marker-before-flood"
pre_main=$(root journalctl -u caddy --no-pager -q | wc -l)
for i in 1 2 3 4 5 6; do curl -s -o /dev/null -m 120 "http://flood.localhost:$HP/flood/100000?size=100"; done
t_until 15 has_line flood 'flood 99999 '   # the last batch reached the journal
fb=$(root du -sB1 "/var/log/journal/\$(cat /etc/machine-id).tando-flood" | cut -f1)
log "flood journal on disk: $fb bytes"
check "2a flood journal within its 16 MB cap ($fb bytes)" test "$fb" -le $((16 * 1048576))
check "2b flood app's newest lines are kept" t_until 15 has_line flood 'flood 99999 ' 
check "2c other app's lines survive the flood" has_line filt other-app-marker-before-flood
check "2d other app's startup line survives" has_line hello 'hello v1 on' 
post_main=$(root journalctl -u caddy --no-pager -q | wc -l)
check "2e main journal untouched by the flood (caddy lines $pre_main -> $post_main)" test "$post_main" -ge "$pre_main"
tot=$(root du -sB1 /var/log/journal | cut -f1)
check "2f all journals within the sum of caps ($tot bytes)" test "$tot" -le $(((128 + 5 * 50) * 1048576))

# ---- 3. filters return exactly the expected lines ---------------------------------------------
log "filters"
"$R" restart -a filt > /dev/null 2>&1
T0=$(( $(date +%s) + 1 )); sleep 1.5      # --since takes whole seconds: start on the next one
emit filt "A1 alpha plain"
emit filt "A2 Alpha <3> upper"
emit filt '<3>A3 alpha via sd prefix'
emit filt '{"level":"error","msg":"A4 alpha json error"}'
emit filt '{"level":40,"msg":"A5 pino warn"}'
emit filt 'A6 WARN something'
emit filt 'A7 TypeError: not at start' err
emit filt 'TypeError: A8 at start' err
emit filt 'A9 dollar $(touch /tmp/pwned-grep) `id` ; rm -rf / '"'"'quote'"'"
sleep 1.5; T1=$(date +%s); sleep 1.5
emit filt "B1 beta after the mark"
emit filt "B2 beta second"
t_until 10 has_line filt "B2 beta second"
"$R" logs -a filt --since "@$T0" -n 50 | appl > "$E/all"
printf '%s\n' "A1 alpha plain" "A2 Alpha <3> upper" "ERR A3 alpha via sd prefix" \
  'ERR {"level":"error","msg":"A4 alpha json error"}' 'WARN {"level":40,"msg":"A5 pino warn"}' \
  "WARN A6 WARN something" "A7 TypeError: not at start" "ERR TypeError: A8 at start" \
  'A9 dollar $(touch /tmp/pwned-grep) `id` ; rm -rf / '"'"'quote'"'" \
  "B1 beta after the mark" "B2 beta second" > "$E/exp"
check "3a all lines, in order, levels tagged" lines_eq "$E/exp" "$E/all"
"$R" logs -a filt --since "@$T0" --grep alpha | appl > "$E/o"
grep 'alpha' "$E/exp" > "$E/x"
check "3b --grep fixed string (case-sensitive)" lines_eq "$E/x" "$E/o"
"$R" logs -a filt --since "@$T0" --grep alpha -i | appl > "$E/o"
grep -i 'alpha' "$E/exp" > "$E/x"
check "3c --grep -i" lines_eq "$E/x" "$E/o"
"$R" logs -a filt --since "@$T0" --grep '^A[0-9] (alpha|Alpha)' --regex | appl > "$E/o"
printf '%s\n' "A1 alpha plain" "A2 Alpha <3> upper" "ERR A3 alpha via sd prefix" > "$E/x"
check "3d --grep --regex (ERE, matched against the message)" lines_eq "$E/x" "$E/o"
"$R" logs -a filt --since "@$T0" --level err | appl > "$E/o"
grep '^ERR ' "$E/exp" > "$E/x"
check "3e --level err" lines_eq "$E/x" "$E/o"
"$R" logs -a filt --since "@$T0" --level warning | appl > "$E/o"
grep '^ERR \|^WARN ' "$E/exp" > "$E/x"
check "3f --level warning" lines_eq "$E/x" "$E/o"
"$R" logs -a filt --since "@$T1" | appl > "$E/o"
grep '^B' "$E/exp" > "$E/x"
check "3g --since" lines_eq "$E/x" "$E/o"
"$R" logs -a filt --since "@$T0" --until "@$T1" | appl > "$E/o"
grep -v '^B' "$E/exp" > "$E/x"
check "3h --until" lines_eq "$E/x" "$E/o"
"$R" logs -a filt --since "@$T0" -n 3 | appl > "$E/o"
tail -3 "$E/exp" > "$E/x"
check "3i -n 3 gives the newest 3 matches" lines_eq "$E/x" "$E/o"
"$R" logs -a filt --since "@$T0" --level err -n 2 | appl > "$E/o"
grep '^ERR ' "$E/exp" | tail -2 > "$E/x"
check "3j -n with a filter counts matching lines" lines_eq "$E/x" "$E/o"
check "3v -n 0 prints nothing (journalctl alone would print everything)" \
  test -z "$("$R" logs -a filt -n 0 2>&1)"
"$R" logs -a filt --since "@$T0" --grep alpha --json > "$E/json"
check "3k --json: one valid object per line, 3 lines" json_ok "$E/json" 3
check "3l --json: level from the text" grep -q '"level":"err","msg":"{\\"level\\":\\"error\\"' "$E/json"
rm -f "$E/pull.txt"
"$R" logs -a filt pull "$E/pull.txt" --since "@$T0" --until "@$T1" 2> /dev/null
appl < "$E/pull.txt" > "$E/o" 2> /dev/null
grep -v '^B' "$E/exp" > "$E/x"
check "3m logs pull with a time range" lines_eq "$E/x" "$E/o"
check "3n logs pull refuses to overwrite" sh -c "! '$R' logs -a filt pull '$E/pull.txt' 2> /dev/null"

# hostile lines cannot repaint the terminal
emit filt $'H1 esc \033[2J\033[31mred\033]0;title\007 bell\r cr'
emit filt $'H2 c1 \xc2\x9b2J and \x9b raw and caf\xc3\xa9'
t_until 10 has_line filt H2
"$R" logs -a filt --grep H1 > "$E/h1"; "$R" logs -a filt --grep H2 > "$E/h2"
check "3o control characters neutralised (no ESC, BEL, CR, C1 bytes reach the terminal)" neutral "$E/h1" "$E/h2"
"$R" logs -a filt --grep H1 --json > "$E/h1j"
check "3p control characters neutralised in --json" no_ctrl "$E/h1j"

# --release and --deploy
log "release windows"
emit filt "R1 in release one"
sleep 1.5
echo "// v2" >> "$W/filt/server.js"
up filt || fail "3q deploy filt v2"
sleep 1
emit filt "R2 in release two"; t_until 10 has_line filt "R2 in release two"
rels=$("$R" releases -a filt | grep -o '[0-9]\{8\}-[0-9]\{6\}' | sort)
r1=$(echo "$rels" | head -1) r2=$(echo "$rels" | tail -1)
"$R" logs -a filt --release "$r1" -n 1000 | grep '^[0-9]' | body | grep '^R[0-9]' > "$E/o"
echo "R1 in release one" > "$E/x"
check "3r --release shows only lines from the release's live period ($r1)" lines_eq "$E/x" "$E/o"
"$R" logs -a filt --release "$r2" -n 1000 | grep '^[0-9]' | body | grep '^R[0-9]' > "$E/o"
echo "R2 in release two" > "$E/x"
check "3s --release of the next release ($r2)" lines_eq "$E/x" "$E/o"
"$R" logs -a filt --deploy "$r2" -n 200 > "$E/dep"
check "3t --deploy shows the history line, the pre-flight start and the activation unit" deploy_ok "$E/dep" "$r2"
check "3u --release of a release that was never live fails" \
  sh -c "! '$R' logs -a filt --release 20200101-000000 2> /dev/null"

# ---- 4. injection attempts fail closed --------------------------------------------------------
log "injection"
# lint: file-allow RL06 /tmp/pwned* are marker files on the throwaway server whose absence is checked
root rm -f /tmp/pwned /tmp/pwned-grep
"$R" logs -a filt --grep '$(touch /tmp/pwned)' > /dev/null 2>&1
"$R" logs -a filt --grep '`touch /tmp/pwned`' --regex > /dev/null 2>&1
"$R" logs -a filt --grep "'; touch /tmp/pwned; '" > /dev/null 2>&1
"$R" logs -a filt --grep '$(touch /tmp/pwned-grep)' > "$E/o" 2>&1
check "4a shell syntax in --grep is a literal text" sh -c "grep -q 'A9 dollar' '$E/o' && test \$(wc -l < '$E/o') = 1"
check "4b invalid regex is refused" sh -c "! '$R' logs -a filt --grep 'a(b' --regex > /dev/null 2>&1"
check "4c newline in --grep refused" sh -c "! '$R' logs -a filt --grep \"\$(printf 'a\\nb')\" > /dev/null 2>&1"
check "4d bad --since refused" sh -c "! '$R' logs -a filt --since '1h;id' > /dev/null 2>&1"
check "4e bad --level refused" sh -c "! '$R' logs -a filt --level 'err;id' > /dev/null 2>&1"
check "4f bad --release refused" sh -c "! '$R' logs -a filt --release '../x' > /dev/null 2>&1"
check "4g bad --last refused" sh -c "! '$R' requests -a req --last '1h;id' > /dev/null 2>&1"
# around the client: raw specs sent straight to the server
spec_refused() { ! printf '%s\n' "$@" | "$SSH" sudo -n /opt/tando/bin/tando-agent logs filt spec > /dev/null 2>&1; }
check "4h server refuses an unknown spec key" spec_refused n=1 shell=id
check "4i server refuses since=\$(id)" spec_refused 'since=$(id)'
check "4j server refuses a forged cursor" spec_refused follow=1 'after=s=1;rm -rf /'
check "4k server refuses n=-1" spec_refused n=-1
check "4q server refuses n=1;id" spec_refused 'n=1;id'
refused() { ! "$SSH" "sudo -n /opt/tando/bin/tando-agent $*" > /dev/null 2>&1; }   # lint: allow RL04 constants
check "4l server refuses a bad app name" refused "logs '../hello' 5"
check "4m server refuses an app name with shell syntax" refused "req-summary 'hello;id' 900"
check "4n server refuses a bad window" refused "req-summary req '900;id'"
check "4o server refuses a bad count" refused "req-tail req '5 \$(id)'"
check "4p nothing was executed" sh -c "! '$SSH' test -e /tmp/pwned && ! '$SSH' test -e /tmp/pwned-grep"

# ---- 5. isolation between apps ------------------------------------------------------------------
log "isolation"
for _ in 1 2 3; do curl -s -o /dev/null --connect-to "hello.localhost:80:127.0.0.1:$HP" "http://hello.localhost/"; done
t_until 10 root test -s /var/log/tando/hello/access.log
check "5a app user cannot read another app's journal" no_journal_read tando-filt hello
check "5b app user cannot read another app's request log" sh -c "
  ! '$SSH' sudo -u tando-filt cat /var/log/tando/hello/access.log > /dev/null 2>&1 &&
  ! '$SSH' sudo -u tando-filt ls /var/log/tando/hello > /dev/null 2>&1"
own_read() { "$SSH" sudo -u tando-hello cat /var/log/tando/hello/access.log | grep -q '"status":200'; }
check "5c app group reads its own request log" own_read
log_perms() {
  owner_mode /var/log/tando/hello/access.log 'caddy:tando-hello 640' &&
    owner_mode /var/log/tando/hello 'caddy:tando-hello 2750'
}
check "5d request log is caddy:tando-<app> 640 in a 2750 directory" log_perms
check "5e audit log is not readable by apps" \
  sh -c "! '$SSH' sudo -u tando-hello cat /var/log/tando/audit.log > /dev/null 2>&1"

# ---- 6. no Authorization, Cookie or query-string values in any log ------------------------------
log "secrets"
for a in hello req filt; do
  curl -s -o /dev/null -H 'Authorization: Bearer SECRETAUTH1' -H 'Cookie: sid=SECRETCOOKIE1' \
    -H 'Proxy-Authorization: Basic SECRETPROXY1' -u 'user:SECRETBASIC1' \
    --connect-to "$a.localhost:80:127.0.0.1:$HP" "http://$a.localhost/status/401?token=SECRETQUERY1&x=1"
done
t_until 10 eval '"$SSH" sudo cat /var/log/tando/req/access.log | grep -q "/status/401"'
for x in 'SECRET[A]UTH1' 'SECRET[C]OOKIE1' 'SECRET[P]ROXY1' 'SECRET[B]ASIC1' 'SECRET[Q]UERY1' \
    'dXNlcjpTRUNSRVRC[Q]VNJQzE'; do
  check "6-${x//[\[\]]/} no such value in /var/log or any journal" secret_free "$x"
done
q_logged() { "$SSH" sudo cat /var/log/tando/req/access.log | grep -q '"uri":"/status/401?-"'; }
check "6a the request was logged, query string replaced" q_logged

T6=$(date +%s)   # the last request to req before section 7, which needs a minute without any

# ---- 2 (again). the rate limit, here because filt must then stay unused for journald's interval
# (30 s) and req for a minute: sections 10 to 12 use neither, and run meanwhile
# rate limit: an app with the default limit keeps at most about burst x journald's disk factor
emit filt "rate-marker"
curl -s -o /dev/null -m 120 "http://filt.localhost:$HP/flood/60000?size=60"
burst_kept() { "$R" logs -a filt -n 100000 --since 2m --grep 'flood ' | wc -l | tr -d ' '; }
settled() { local k; k=$(burst_kept); [ "$k" -gt 0 ] && [ "$k" = "${kept:-}" ]; local r=$?; kept=$k; return $r; }
kept=""; t_until 15 settled   # the kept count no longer grows
log "rate-limited app kept $kept of 60000 burst lines"
check "2g per-app rate limit drops a burst ($kept of 60000 kept)" test "$kept" -lt 60000 -a "$kept" -gt 1000
TB=$(date +%s)

# ---- 10. audit: each action exactly once -------------------------------------------------------
log "audit"
a0=$(root wc -l /var/log/tando/audit.log | awk '{ print $1 }')
"$R" env set -a hello GREETING=hi > /dev/null 2>&1
"$R" restart -a hello > /dev/null 2>&1
"$R" stop -a hello > /dev/null 2>&1
"$R" start -a hello > /dev/null 2>&1
"$R" env ls -a hello > /dev/null 2>&1
"$R" rollback -a hello > /dev/null 2>&1       # fails: hello has a single release
echo "// v2" >> "$W/hello/server.js"
(cd "$W/hello" && "$R" deploy > /dev/null 2>&1)
"$R" rollback -a hello > /dev/null 2>&1
t_until 10 eval '[ "$(root wc -l /var/log/tando/audit.log | awk "{ print \$1 }")" -ge $((a0 + 8)) ]'
root tail -n +$((a0 + 1)) /var/log/tando/audit.log > "$E/aud"
cut -f4,5,6 "$E/aud" | sed 's/	/ /g' > "$E/o"
printf '%s\n' "env-set hello ok" "restart hello ok" "stop hello ok" "start hello ok" "env-ls hello ok" \
  "rollback hello fail(1)" "deploy hello ok" "rollback hello ok" > "$E/x"
check "10a audit: each action recorded exactly once, in order, with its result" lines_eq "$E/x" "$E/o"
check "10b audit: who and from" sh -c "awk -F'\t' '\$2 != \"vmadmin\" || \$3 !~ /^[0-9a-f.:]+\$/ { exit 1 }' '$E/aud'"
check "10c audit: the failed rollback says why" grep -q 'no earlier verified release' "$E/aud"
COLUMNS=100 "$R" audit hello > "$E/audbox"
aud_render() { grep -q 'rollback' "$E/audbox" && grep -q '^╭' "$E/audbox" && fits 100 "$E/audbox" &&
  grep -q 'TIME (GMT)' "$E/audbox" &&
  grep -qE " $(TZ=UTC date '+%m-%d') [0-9]{2}:[0-9]{2}:[0-9]{2} " "$E/audbox"; }
check "10d tando audit renders boxed, 100 columns" aud_render
aud_journal() { "$SSH" sudo journalctl -t tando-audit -q --no-pager | grep -q 'verb=env-set app=hello result=ok'; }
check "10e audit also copied to the main journal" aud_journal

# ---- 11. log size visibility ----------------------------------------------------------------
log "log stats"
root /opt/tando/bin/tando-agent log-stats > "$E/st1"
check "11a log-stats: one row per app" test "$(grep -c '^logs	' "$E/st1")" = 5
check "11b log-stats: flood journal bytes within cap, lines counted" awk -F'\t' '
  $2 == "flood" { ok = ($3 > 1000000 && $3 <= $4 && $6 > 10000) } END { exit !ok }' "$E/st1"
t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
root /opt/tando/bin/tando-agent log-stats > "$E/st2"
t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
check "11c log-stats: second call served from the cache" awk -F'\t' '$1 == "logs" && $11 > 60 { exit 1 }' "$E/st2"
log "log-stats cached call: $(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", b - a }') s wall incl. ssh"

# ---- 12. destroy removes the app's logs, and only that app's -----------------------------------
log "destroy"
mkapp flood-2                    # a name that starts with "flood-": globs like tando-flood-* match it
up flood-2 || fail "12x up flood-2"
emit flood-2 "flood-2-marker"
curl -s -o /dev/null --connect-to "flood-2.localhost:80:127.0.0.1:$HP" "http://flood-2.localhost/status/201"
t_until 10 has_line flood-2 flood-2-marker
printf 'flood\n' | "$R" destroy -a flood --purge > /dev/null 2>&1
check "12a destroy removes the journal namespace and request log" \
  gone /etc/systemd/journald@tando-flood.conf '/var/log/journal/*.tando-flood' /var/log/tando/flood
kept() { # the logs of flood-2 survive the destroy of flood
  "$SSH" "sudo test -f /etc/systemd/journald@tando-flood-2.conf && sudo test -f /var/log/tando/flood-2/access.log" &&
    has_line flood-2 flood-2-marker &&
    "$SSH" sudo cat /var/log/tando/flood-2/access.log | grep -q '"status":201'
}
check "12b destroying flood keeps the journal and request log of flood-2" kept

# journald writes its "Suppressed N messages" when the app logs again after the interval (30 s:
# a real interval of journald, kept; only what is left of it is waited for)
wait_since "$TB" 31 "the rate-limit interval of filt"
emit filt "after-the-burst"; t_until 10 has_line filt after-the-burst
check "2h the burst's drop shows in tando logs as a journald notice" \
  has_line filt 'messages from tando-filt.service'

# ---- 9. -f survives a killed ssh connection ----------------------------------------------------
log "follow"
"$R" logs -a filt -f -n 1 > "$E/follow" 2> "$E/follow.err" &
FP=$!
followed() { grep -q "$1" "$E/follow"; }
reconnects() { [ "$(grep -c reconnecting "$E/follow.err")" -ge "$1" ]; }
t_until 15 test -s "$E/follow"                 # connected: the last line is there
emit filt "F1 follow"; emit filt "F2 follow"; t_until 10 followed "F2 follow"
pkill -f "logs filt spec"; t_until 10 reconnects 1
emit filt "F3 written while disconnected"; t_until 20 followed "F3 written"
emit filt "F4 after reconnect"; t_until 10 followed "F4 after"
pkill -f "logs filt spec"; emit filt "F5 follow"; t_until 10 reconnects 2; t_until 20 followed "F5 follow"
emit filt "F6 follow"; t_until 10 followed "F6 follow"
kill "$FP" 2> /dev/null; pkill -f "logs filt spec"; wait "$FP" 2> /dev/null
body < "$E/follow" | grep '^F[0-9]' > "$E/o"
printf '%s\n' "F1 follow" "F2 follow" "F3 written while disconnected" "F4 after reconnect" \
  "F5 follow" "F6 follow" > "$E/x"
check "9a -f resumes after two killed connections, every line exactly once" lines_eq "$E/x" "$E/o"
check "9b -f reported the reconnects" test "$(grep -c reconnecting "$E/follow.err")" -ge 2

# ---- 7. request statistics against a known traffic pattern ------------------------------------
log "request statistics"
# the 1-minute window used below must not include earlier requests (the last one: T6; sections
# 10 to 12 and 9 ran since, so usually nothing is left to wait)
wait_since "$T6" 61 "a minute without requests to req"
T7=$(date +%s)
reqlines() { root cat /var/log/tando/req/access.log | wc -l | tr -d ' '; }
n7=$(reqlines)
curl -s --connect-to "req.localhost:80:127.0.0.1:$HP" "http://req.localhost/status/200?[1-100]" > /dev/null
curl -s --connect-to "req.localhost:80:127.0.0.1:$HP" "http://req.localhost/status/404?[1-40]" > /dev/null
curl -s --connect-to "req.localhost:80:127.0.0.1:$HP" "http://req.localhost/status/500?[1-20]" > /dev/null
curl -s --connect-to "req.localhost:80:127.0.0.1:$HP" "http://req.localhost/sleep/100?[1-40]" > /dev/null
curl -s --connect-to "req.localhost:80:127.0.0.1:$HP" "http://req.localhost/sleep/300?[1-5]" > /dev/null
t_until 15 eval '[ "$(reqlines)" -ge '"$((n7 + 205))"' ]'   # all 205 requests are in the log
win=$(( $(date +%s) - T7 + 2 )); [ "$win" -lt 60 ] && win=60
root /opt/tando/bin/tando-agent req-summary req "$win" > "$E/sum"
kv() { sed -n "s/^$1=//p" "$E/sum"; }
check "7a counts: total 205, 2xx 145, 4xx 40, 5xx 20" \
  test "$(kv total) $(kv c2xx) $(kv c4xx) $(kv c5xx)" = "205 145 40 20"
codes_ok() {
  grep -q '^code	200	145$' "$E/sum" && grep -q '^code	404	40$' "$E/sum" && grep -q '^code	500	20$' "$E/sum"
}
check "7b status codes 200:145 404:40 500:20" codes_ok
p50=$(kv p50_ms) p95=$(kv p95_ms) p99=$(kv p99_ms)
log "p50 $p50 ms, p95 $p95 ms, p99 $p99 ms, max $(kv max_ms) ms"
# (160 quick requests, 40 of 100 ms, 5 of 300 ms: in order of time the 95th percentile is the
# 194th of 205, inside the 100 ms group, and the 99th the 202nd, inside the 300 ms group; each
# is checked to be in its group. A request can only get slower, never faster, than its sleep, so
# a loaded machine moves values up inside a group; the old traffic put the 95th percentile on
# the edge of two groups, and a few slow quick requests moved it into the next one)
check "7c percentiles in their group (p50 quick < 50 ms, p95 in the 100 ms group, p99 in the 300 ms group)" \
  awk -v a="$p50" -v b="$p95" -v c="$p99" 'BEGIN { exit !(a < 50 && b >= 95 && b < 290 && c >= 295 && c < 1000) }'
check "7d paths: /sleep/:n 45 requests, /status/:n 160 with 20 5xx" sh -c "
  grep -q '^path	GET /sleep/:n	45	' '$E/sum' && grep -q '^path	GET /status/:n	160	.*	20\$' '$E/sum'"
check "7e per-minute counts add up" test "$(kv counts | tr ',' '\n' | awk '{ s += $1 } END { print s }')" = 205
check "7f 5xx per-minute counts add up" test "$(kv counts_5xx | tr ',' '\n' | awk '{ s += $1 } END { print s }')" = 20
for w in 80 120; do
  COLUMNS=$w "$R" requests -a req --last 15m > "$E/rq.$w"
  COLUMNS=$w "$R" requests errors -a req --last 15m > "$E/rqe.$w"
  COLUMNS=$w "$R" requests tail -a req -n 5 > "$E/rqt.$w"
done
rq_render() {
  grep -q '500' "$E/rq.80" && grep -q 'p95' "$E/rq.80" && grep -q '/sleep/:n' "$E/rq.120" && grep -q '^╭' "$E/rq.80" &&
    fits 80 "$E/rq.80" "$E/rqe.80" "$E/rqt.80" && fits 120 "$E/rq.120" "$E/rqe.120" "$E/rqt.120"
}
check "7g tando requests renders boxed at 80 and 120 columns" rq_render
rq_gmt() {
  grep -q 'TIME (GMT)' "$E/rqt.80" && grep -q 'TIME (GMT)' "$E/rqe.120" && grep -q 'LATENCY' "$E/rqt.80" &&
    grep -qE " $(TZ=UTC date '+%m-%d') [0-9]{2}:[0-9]{2}:[0-9]{2} " "$E/rqt.80"
}
check "7i requests tail and errors: TIME (GMT) in UTC with seconds, LATENCY for the answer time" rq_gmt
check "7h requests errors lists the 20 5xx answers" test "$(grep -c ' 500 ' "$E/rqe.120")" = 20

# ---- 8. rotation of the request log -------------------------------------------------------------
log "rotation"
for _ in 1 2 3 4 5 6 7 8; do
  curl -s --connect-to "req.localhost:80:127.0.0.1:$HP" "http://req.localhost/status/200?[1-2000]" > /dev/null
done
t_until 10 eval '[ "$(root ls /var/log/tando/req | grep -c "access-.*\.log")" -ge 2 ]'
root ls -la /var/log/tando/req > "$E/rot"
nrot=$(grep -c 'access-.*\.log' "$E/rot")
rsz=$(root du -sB1 /var/log/tando/req | cut -f1)
log "request log dir: $nrot rolled files, $rsz bytes"
check "8a rotated by size, 2 rolled files kept ($nrot)" test "$nrot" = 2
check "8b request log dir bounded by 3 x 1 MiB ($rsz bytes)" test "$rsz" -le $((3 * 1048576 + 65536))
check "8c rolled files keep owner and mode" \
  sh -c "! grep 'access-' '$E/rot' | grep -v '^-rw-r----- .* caddy tando-req '"
root /opt/tando/bin/tando-agent req-summary req 900 > "$E/sum2"
check "8d summary reads across rolled files" test "$(sed -n 's/^files=//p' "$E/sum2")" -ge 2

# ---- 13. settings: leading zeros, values ending in "=", the requests subcommand names ----------
log "settings"
zero_setup() { "$R" host setup t access_keep_for=08d log_keep=09d access_size=1 access_keep=2 > "$E/setup0" 2>&1; }
check "13a host setup accepts leading-zero settings" zero_setup
site_ok() { # numbers written in decimal, and Caddy accepts every site file
  "$SSH" "sudo grep -q 'roll_keep_for 192h' /etc/caddy/tando/hello.caddy" &&
    "$SSH" "sudo grep -q '^MaxRetentionSec=216h' /etc/systemd/journald@tando-hello.conf" &&
    "$SSH" "sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile" > /dev/null 2>&1
}
check "13b leading zeros become decimal in Caddy and journald configs; caddy validate passes" site_ok
bad_conf() { # a hand-edited bad value falls back to the default instead of reaching a site file
  "$SSH" "sudo sh -c 'echo access_keep_for=0x9d >> /opt/tando/logs.conf'" &&
    "$SSH" "sudo /opt/tando/bin/tando-logs caddy-log hello" | grep -q 'roll_keep_for 216h'
}
check "13c a bad stored value falls back to the default (log_keep, 9d)" bad_conf
check "13d log-doctor runs with those settings" \
  sh -c "'$SSH' sudo /opt/tando/bin/tando-logs log-doctor | grep -q 'log caps'"
load_eq() { # a stored value keeps its trailing "=" (IFS='=' read would drop it): access_log=off= is not
  # "off" but an invalid value, so the default (on) applies and the site still gets its log block
  local r
  "$SSH" "sudo sh -c 'echo access_log=off= >> /opt/tando/logs.conf'"
  "$SSH" sudo /opt/tando/bin/tando-logs caddy-log hello | grep -q 'roll_size'; r=$?
  "$SSH" 'sudo sed -i "/^access_log=off=\$/d" /opt/tando/logs.conf'
  return $r
}
check "13e values keep a trailing =" load_eq
check "13f tando requests summary is the default's name" sh -c "'$R' requests summary -a req | grep -q 'requests req'"

# ---- 14. a release that never went live: --release shows its deploy log; errors reach the user ---
log "failed release"
"$R" env set -a hello CRASH_VERSION=9 > /dev/null 2>&1
echo 9 > "$W/hello/VERSION"
(cd "$W/hello" && "$R" deploy > "$E/bad-deploy" 2>&1)
bad=$("$SSH" "sudo tail -n 1 /opt/tando/apps/hello/history.tsv" | cut -f2,4)
log "failed deploy: $bad"
check "14a the crashing release failed its deploy (${bad%%	*})" test "${bad#*	}" = failed
"$R" logs -a hello --release "${bad%%	*}" > "$E/badrel" 2> "$E/badrel.err"
never_live() {
  grep -q "^# release ${bad%%	*} was never live" "$E/badrel" &&
    grep -q '\[pre\] .*hello v9: crashing on purpose' "$E/badrel"
}
check "14b --release of a failed release shows its pre-flight output" never_live
"$R" logs -a hello --release 20200101-000000 > /dev/null 2> "$E/norel.err"
check "14c a refusal prints the server's reason (BSD sed/grep on macOS)" \
  grep -q 'no such release: 20200101-000000' "$E/norel.err"
"$R" env unset -a hello CRASH_VERSION > /dev/null 2>&1

# ---- 15. retention and size limits: defaults, retention, circular cap, request log history -------
log "retention and limits"
"$SSH" "sudo sed -i -e '/^access_/d' -e '/^log_keep/d' /opt/tando/logs.conf"   # back to the defaults
"$R" host setup t > /dev/null 2>&1
nsconf() { root cat "/etc/systemd/journald@tando-$1.conf"; }
fair() { # min(256M, 5% of the file system of /var/log), as tando-logs renders it
  local k; k=$("$SSH" "df -Pk /var/log | tail -1" | awk '{ print int($2 * 5 / 100 / 1024) }')
  [ "$k" -ge 256 ] && k=256; [ "$k" -lt 16 ] && k=16; echo "${k}M"
}
nsconf hello > "$E/ns.hello"
check "15a default journal cap is min(256M, 5% of the disk) ($(fair))" grep -qx "SystemMaxUse=$(fair)" "$E/ns.hello"
check "15b default retention 30 days, journal files closed daily" \
  sh -c "grep -qx 'MaxRetentionSec=720h' '$E/ns.hello' && grep -qx 'MaxFileSec=1440min' '$E/ns.hello'"
"$R" status -a hello > "$E/st.hello" 2>&1
check "15c status shows use, cap and retention (logs ... of ..., keeps 30 d)" \
  grep -q 'logs .* of .*, keeps 30 d' "$E/st.hello"
check "15c2 status puts the lines of the last 24 h first and the journal size after them" \
  grep -Eq 'logs +[0-9]+ lines/24h +journal .* of .*, keeps 30 d' "$E/st.hello"
# an app with log_keep = 1h: short journal files so that retention can trim whole files
mkapp keep 'log_keep = 1h
log_rate = off
log_max = 32M
request_log_max = 8M
'
up keep || { fail "15 up keep"; sed 's/^/    /' "$E/up.keep" >&2; }
nsconf keep > "$E/ns.keep"
check "15d log_keep = 1h: MaxRetentionSec=1h, MaxFileSec=15min, SystemMaxUse=32M" \
  sh -c "grep -qx 'MaxRetentionSec=1h' '$E/ns.keep' && grep -qx 'MaxFileSec=15min' '$E/ns.keep' &&
    grep -qx 'SystemMaxUse=32M' '$E/ns.keep'"
root /opt/tando/bin/tando-logs caddy-log keep > "$E/site.keep"
check "15e request log follows log_keep and request_log_max: 1 MiB files x 8, kept 1h, gzip'd" \
  sh -c "grep -q 'roll_size 1MiB' '$E/site.keep' && grep -q 'roll_keep 7\$' '$E/site.keep' &&
    grep -q 'roll_keep_for 1h' '$E/site.keep' && ! grep -q roll_uncompressed '$E/site.keep'"
# retention: what is in archived files older than log_keep goes at the vacuum run tando does
emit keep "keep-old-line"
t_until 10 has_line keep keep-old-line
root journalctl --namespace=tando-keep --rotate > /dev/null 2>&1
sleep 2
root journalctl --namespace=tando-keep --vacuum-time=1s > /dev/null 2>&1
emit keep "keep-new-line"
check "15f retention: a vacuum by time drops archived entries, new ones stay" \
  sh -c "! '$R' logs -a keep -n 1000 --grep keep-old-line | grep -q . &&
    '$R' logs -a keep -n 1000 --grep keep-new-line | grep -q ."
# changing the limits applies at once and does not restart the app (nor lose its stdout)
pid0=$(srv systemctl show -P MainPID tando-filt)
nr0=$(srv systemctl show -P NRestarts tando-filt)
emit filt "before-limit-change"
"$R" host setup t log_max=24M log_keep=2d > "$E/setup15" 2>&1
emit filt "after-limit-change"
check "15g a host default change rewrites the namespace config (24M, 48h)" \
  sh -c "'$SSH' sudo grep -qx SystemMaxUse=24M /etc/systemd/journald@tando-filt.conf &&
    '$SSH' sudo grep -qx MaxRetentionSec=48h /etc/systemd/journald@tando-filt.conf"
check "15h ... without restarting the app (pid $pid0, restarts $nr0)" \
  test "$(srv systemctl show -P MainPID tando-filt) $(srv systemctl show -P NRestarts tando-filt)" = "$pid0 $nr0"
check "15i ... and its lines before and after the change are both there" \
  sh -c "'$R' logs -a filt -n 100 | grep -q before-limit-change && '$R' logs -a filt -n 100 | grep -q after-limit-change"
# (the flood of 15p, here: the checks up to 15o do not touch filt, and its 30 s pass meanwhile)
curl -s -o /dev/null -m 120 "http://filt.localhost:$HP/flood/60000?size=60"
T15=$(date +%s)
# shrinking: a full journal is cut to the new cap at once (vacuum), circular from then on
curl -s -o /dev/null -m 120 "http://keep.localhost:$HP/flood/200000?size=100"
t_until 15 has_line keep 'flood 199999 '
kb=$(root du -sB1 "/var/log/journal/\$(cat /etc/machine-id).tando-keep" | cut -f1)
check "15j circular: 20 MB of lines into a 32M journal stays within it ($kb bytes)" test "$kb" -le $((32 * 1048576))
sed -i.bak 's/^log_max = 32M/log_max = 8M/' "$W/keep/tando.conf"; rm -f "$W/keep/tando.conf.bak"
up keep
kb=$(root du -sB1 "/var/log/journal/\$(cat /etc/machine-id).tando-keep" | cut -f1)
check "15k shrinking log_max to 8M cuts the journal at once ($kb bytes)" test "$kb" -le $((8 * 1048576 + 1048576))
check "15l ... and keeps the newest lines" has_line keep 'flood 199999 '
# a namespace past its cap with its config unchanged (a vacuum that met a stopped instance or
# failed was never tried again): copies of an archived file, named older, push it past 8M; the
# next host setup trims it
nsd="/var/log/journal/\$(cat /etc/machine-id).tando-keep"
srv 'sudo bash -s' <<'EOF'
d=/var/log/journal/$(cat /etc/machine-id).tando-keep
f=$(ls "$d"/system@*.journal | tail -1) i=1
while [ "$(du -sB1 "$d" | cut -f1)" -le $((20 * 1048576)) ] && [ $i -le 200 ]; do
  cp "$f" "$d/system@00000000000000000000000000000000-$(printf %016x $i)-$(printf %016x $i).journal"; i=$((i + 1))
done
EOF
kb0=$(root du -sB1 "$nsd" | cut -f1)
"$R" host setup t > "$E/setup15s" 2>&1 || cat "$E/setup15s" >&2
kb=$(root du -sB1 "$nsd" | cut -f1)
check "15s a journal past its cap, config unchanged: host setup trims it ($kb0 -> $kb bytes, cap 8M)" \
  test "$kb0" -gt $((20 * 1048576)) -a "$kb" -le $((8 * 1048576 + 1048576))
check "15t ... and keeps the newest lines" has_line keep 'flood 199999 '
# request log history: a burst of 20,000 requests (about 6.5 MB of lines) rolls the 1 MiB files,
# gzip'd, and every request is still read back (the old 4 MiB x 4 default kept seconds of a burst)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -s --connect-to "keep.localhost:80:127.0.0.1:$HP" "http://keep.localhost/status/200?[1-2000]" > /dev/null
done
t_until 15 eval '[ "$(root ls /var/log/tando/keep | grep -c "access-.*\.log\.gz")" -ge 2 ]'
root ls -la /var/log/tando/keep > "$E/rot.keep"
kz=$(root du -sB1 /var/log/tando/keep | cut -f1)
check "15m rolled request logs are gzip'd ($(grep -c 'log.gz' "$E/rot.keep") files)" grep -q 'access-.*\.log\.gz' "$E/rot.keep"
check "15n request log within request_log_max 8M ($kz bytes)" test "$kz" -le $((8 * 1048576))
"$R" requests -a keep --last 15m > "$E/rq.keep" 2>&1
root /opt/tando/bin/tando-agent req-summary keep 900 > "$E/sum.keep"
tot=$(sed -n 's/^total=//p' "$E/sum.keep")
check "15o the whole burst is still counted across the gzip'd files ($tot of 20000)" test "${tot:-0}" -ge 20000
# the journald rate limit is visible: tando logs ends with a note when lines were dropped
# journald writes its "Suppressed N messages" when the app logs again after the interval (30 s)
wait_since "$T15" 31 "the rate-limit interval of filt"; emit filt "after-the-flood"
t_until 10 eval "'$R' logs -a filt -n 5 | grep -q '^# note: journald dropped [0-9]* lines'"
check "15p tando logs notes the lines journald dropped in the window shown" \
  sh -c "'$R' logs -a filt -n 5 | grep -q '^# note: journald dropped [0-9]* lines in this window (over log_rate 5000/30s)'"
"$R" logs -a filt -n 5 --since 1s --grep never-matches-anything > "$E/nonote" 2>&1
check "15q no note for a window without drops" sh -c "! grep -q 'journald dropped' '$E/nonote'"
"$SSH" sudo /opt/tando/bin/tando-logs log-doctor > "$E/ldoc"
check "15r doctor compares the log caps with the free space" grep -q 'log caps.*MB free' "$E/ldoc"

t_done
