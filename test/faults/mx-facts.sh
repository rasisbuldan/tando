# shellcheck shell=bash
# mx-facts.sh <app> <history lines before> [release id]: what the fault matrix's checker
# (lib-matrix.sh, mx_inv) reads of an app, as key=value lines, in one root round trip. Runs on
# the test server (bash -s), never on the laptop.
# lint: file-allow RL02 it runs on the test server (Ubuntu), not on the laptop
A=$1 H0=${2:-0} NEW=${3:-} D=/opt/tando/apps/$1
g() { sed -n "s/^$1=//p" "$2" 2> /dev/null | head -1; }
kv() { printf '%s=%s\n' "$1" "$2"; }
for k in phase current last_good target kind stopped down prev fallback; do kv "s_$k" "$(g "$k" "$D/state")"; done
l=$(readlink "$D/current" 2> /dev/null); kv link "${l##*/}"
for r in "$D"/releases/*; do
  [ -d "$r" ] || continue
  i=${r##*/}
  kv "rel_$i" "$(g "status_$i" "$D/state")"
done
for k in health start start_shell port recipe preflight_port; do kv "c_$k" "$(g "$k" "$D/app.conf")"; done
cur=$(g current "$D/state")
if [ -n "$cur" ] && [ -f "$D/start/$cur" ]; then
  kv snap_health "$(g health "$D/start/$cur")"; kv snap_start "$(g start "$D/start/$cur")"
fi
for k in id result phase; do kv "p_$k" "$(g "$k" "$D/activation")"; done
# the unit and what runs in it
u=tando-$A.service
kv u_active "$(systemctl show -P ActiveState "$u" 2> /dev/null)"
kv u_enabled "$(systemctl is-enabled "$u" 2> /dev/null)"
pid=$(systemctl show -P MainPID "$u" 2> /dev/null)
if [ -n "$pid" ] && [ "$pid" != 0 ]; then
  c=$(readlink "/proc/$pid/cwd" 2> /dev/null); kv u_cwd "${c##*/}"
  kv u_cmd "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2> /dev/null | sed 's/ $//')"
fi
port=$(g port "$D/app.conf"); pre=$(g preflight_port "$D/app.conf"); [ -n "$pre" ] || pre=$((port + 100))
own=0 foreign=0
for p in $(ss -Hltnp "sport = :$port" 2> /dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u); do
  case $(cut -d: -f3- "/proc/$p/cgroup" 2> /dev/null | tail -1) in
    */"$u"|*/"$u"/*) own=$((own + 1));;
    *) foreign=$((foreign + 1));;
  esac
done
kv listen_own "$own"; kv listen_foreign "$foreign"
kv listen_pre "$(ss -Hltn "sport = :$pre" 2> /dev/null | grep -c .)"
# Caddy's site for the app: proxy, static, stopped or down
f=/etc/caddy/tando/$A.caddy
if grep -q "is stopped" "$f" 2> /dev/null; then kv site stopped
elif grep -q "is unavailable" "$f" 2> /dev/null; then kv site down
elif grep -q reverse_proxy "$f" 2> /dev/null; then kv site proxy
elif grep -q file_server "$f" 2> /dev/null; then kv site static
else kv site none; fi
# history since the case started: "<id> <kind> <result>" per line
n=0
if [ -f "$D/history.tsv" ]; then
  n=$(wc -l < "$D/history.tsv" | tr -d ' ')
  tail -n "+$((H0 + 1))" "$D/history.tsv" | awk -F '\t' '{ print "hist=" $2 " " $3 " " $4 }'
  [ -s "$D/history.tsv" ] && [ "$(tail -c1 "$D/history.tsv" | od -An -c | tr -d ' ')" != '\n' ] && kv hist_torn 1
fi
kv hist_n "$n"
if [ -n "$NEW" ]; then
  /opt/tando/bin/tando-agent deploy-status "$A" "$NEW" 2> /dev/null | sed -n 's/^\(phase\|result\)=/ds_\1=/p'
fi
# the lock, its waiters, the lease
if [ ! -f "$D/lock" ] || flock -n "$D/lock" true; then kv lock free; else kv lock held; fi
w=0; for x in "$D"/lock.wait.*; do [ -e "$x" ] && [ -d "/proc/${x##*.}" ] && w=$((w + 1)); done; kv lock_waiters "$w"
[ -f "$D/upload" ] && kv lease held || kv lease free
# leftovers: transient units of the app's own operations, temp files, half-written site files
kv units "$(systemctl list-units --all --plain --no-legend "tando-$A-*" 2> /dev/null | awk '{ print $1 }' |
  grep -E "^tando-$A-(act|pre|rel|venv|envcheck|backup)-" | tr '\n' ' ')"
kv tmp "$( { find "$D" -maxdepth 2 \( -name '*.tmp' -o -name '*.tmp.*' -o -name current.tmp -o -name .env.check \
  -o -name '.env.??????' -o -name copy.err -o -name '.restore-*' -o -name '.replaced-*' \) 2> /dev/null
  ls "$f.tmp" "$f.old" 2> /dev/null; } | sed "s|^$D/||" | tr '\n' ' ')"
# the env file's MXVAL and MX_BAD, the data sentinel and the database's rows
kv env_val "$(sed -n 's/^MXVAL="\(.*\)"$/\1/p' "$D/env" 2> /dev/null)"
kv env_bad "$(sed -n 's/^MX_BAD="\(.*\)"$/\1/p' "$D/env" 2> /dev/null)"
[ -f "$D/env.prev" ] && kv env_prev 1
kv data_sum "$(sha256sum "$D/shared/data/sentinel" 2> /dev/null | cut -c1-16)"
if [ "$(g database "$D/app.conf")" = postgres ]; then
  db=tando_$(echo "$A" | tr - _)
  kv db_rows "$(sudo -u postgres psql -X -At -d "$db" -c 'select count(*) from mx' 2> /dev/null)"
fi
n=0; for x in /etc/systemd/system/tando-"$A"-job-*.timer; do [ -e "$x" ] && n=$((n + 1)); done; kv jobs "$n"
exit 0
