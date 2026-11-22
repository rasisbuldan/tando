#!/bin/bash
# Fleet bench (not part of the test tiers): N tiny apps on a REAL server registered with tando,
# what they cost, how long the operations take at that size, and whether they all come back
# after a reboot. For an operator running many small apps on one node.
#
#   bench/fleet.sh <host> [-n N] [-P K] [--pg 0|1] [--idle-window S] [--out DIR]
#                         [--no-reboot] [--allow-existing] [--yes]
#   bench/fleet.sh <host> --cleanup          destroy the fb-* apps (only those) and stop
#
#   <host>   a server registered with `tando host add` (and set up: `tando host setup`, with
#            postgres=yes when --pg 1, the default). Never a server you care about without
#            reading "Safety" below.
#   -n N     apps to deploy (default 100). The mix, by number: fb-1 is the PostgreSQL app
#            (examples/notes, needs npm here); then, in turn, a static site, a Go binary, a Node
#            hello, a Node hello with idle_stop (FLEET_IDLE, default 30s).
#   -P K     `tando up` at once while creating (default 2; the squeeze audit saw silent failures
#            at 4 on a loaded laptop: a first-try failure is reported, then retried alone).
#   --idle-window S   seconds of the idle-fleet sampling of PID 1 and tandod (default 300).
#   --no-reboot       skip the reboot test (the last step).
#   --yes             do not ask before the reboot.
#
# Safety: it refuses a host that has apps not created by this bench (any app whose name does not start with fb-)
# unless --allow-existing, and the reboot test then asks again (a reboot takes every app of the
# host down). Every app it makes is named fb-<n>; --cleanup destroys fb-<n> and nothing else.
#
# Measured (all on the server, from outside the apps): per type PSS of the app's processes and the
# app slice's cgroup memory (anon, current); the host's used memory, PID 1, tandod and Caddy RSS and
# the journald namespaces; units loaded; `tando up` (create) and `tando deploy` (redeploy) time
# p50/p95; systemd daemon-reload and Caddy reload at N; the daemon-reloads each create caused;
# tandod's CPU from `tando-status cost` and PID 1 RSS over the idle window; the wake latency of
# every idle_stop app (cold) beside the warm one; `tando ls` time; and the reboot: seconds until
# ssh, until the first and until the last app answers; any app that does not answer within
# FLEET_REBOOT_WAIT (default 900 s) is a failure (exit 1).
# Output: a markdown report $OUT/report.md (default bench/.fleet/<host>-<date>/), raw files beside it.
# FLEET_REBOOT_CMD="docker restart name" replaces the reboot command (Docker test servers);
# FLEET_CURL="-k" adds curl options for the probes (self-signed links). FLEET_MEM=128M the
# memory of the Node apps (static and Go get 64M).
# Takes about 10 s per app to create plus the idle window, the wake test, the deploys and the
# reboot: about 30 to 40 minutes at N=100.
set -u
# shellcheck source=bench/fleet-common.sh
. "$(cd "$(dirname "$0")" && pwd -P)/fleet-common.sh"

N=100 P=2 PG=1 IDLEW=300 OUT="" REBOOT=1 ALLOW=0 YES=0 CLEAN=0 HOST=""
while [ $# -gt 0 ]; do
  case $1 in
    -n) N=$2; shift;;
    -P) P=$2; shift;;
    --pg) PG=$2; shift;;
    --idle-window) IDLEW=$2; shift;;
    --out) OUT=$2; shift;;
    --no-reboot) REBOOT=0;;
    --allow-existing) ALLOW=1;;
    --yes) YES=1;;
    --cleanup) CLEAN=1;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0;;
    -*) fb_die "unknown option $1";;
    *) [ -z "$HOST" ] && HOST=$1 || fb_die "one host only";;
  esac
  shift
done
[ -n "$HOST" ] || fb_die "usage: bench/fleet.sh <host> [-n N] [--cleanup] (see the head of the file)"
case $N in ''|*[!0-9]*) fb_die "-n needs a number";; esac
[ "$N" -ge 1 ] && [ "$N" -le 900 ] || fb_die "-n must be 1 to 900"
case $P in ''|*[!0-9]*|0) fb_die "-P needs a number of 1 or more";; esac
fb_init "$HOST"
IDLE=${FLEET_IDLE:-30s} NMEM=${FLEET_MEM:-128M} CURLX=${FLEET_CURL:-}
[ -n "$OUT" ] || OUT=$FB_ROOT/bench/.fleet/$HOST-$(date +%Y%m%d-%H%M%S)
W=$OUT/w REP=$OUT/report.md
mkdir -p "$W"
isbench() { case $1 in fb-?*) return 0;; *) return 1;; esac; }   # every bench app is named fb-<something>
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
rep() { printf '%s\n' "$*" >> "$REP"; }

# ---- the apps already there ----------------------------------------------------------------
fb_apps > "$OUT/apps.before" || fb_die "cannot list the apps of $HOST (tando ls -H $HOST --json failed: is the host set up?)"
others=$(awk '{ print $1 }' "$OUT/apps.before" | while read -r a; do isbench "$a" || echo "$a"; done)
mine=$(awk '{ print $1 }' "$OUT/apps.before" | while read -r a; do isbench "$a" && echo "$a"; done)

if [ "$CLEAN" = 1 ]; then
  [ -n "$mine" ] || { echo "no fb-* apps on $HOST"; exit 0; }
  log "destroying $(echo "$mine" | wc -l | tr -d ' ') fb-* apps on $HOST ($(echo "$others" | grep -c .) other apps are left alone)"
  echo "$mine" | xargs -P 4 -I{} sh -c '"$1" destroy -a "$2" -H "$3" --purge --yes > /dev/null 2>&1 || echo "failed: $2"' _ "$TANDO" {} "$HOST"
  fb_apps | awk '$1 ~ /^fb-[0-9]+$/ { print "still there: " $1 }'
  exit 0
fi

if [ -n "$others" ] && [ "$ALLOW" != 1 ]; then
  echo "refusing: $HOST has apps this bench did not create:" >&2
  echo "$others" | sed 's/^/  /' >&2
  echo "Use a server of its own for the bench, or --allow-existing (the apps are not touched, but they are measured, and the reboot takes them down too)." >&2
  exit 2
fi
if [ -n "$others" ] && [ "$REBOOT" = 1 ] && [ "$YES" != 1 ]; then
  printf 'This host also runs %s other apps; the reboot test takes them down for a minute or two. Reboot anyway? [y/N] ' "$(echo "$others" | wc -l | tr -d ' ')" >&2
  read -r ans; case $ans in y|Y|yes) ;; *) REBOOT=0; echo "skipping the reboot test" >&2;; esac
fi

# ---- the apps' sources ---------------------------------------------------------------------
ARCH=$(fb_goarch)
HAVEGO=0
if command -v go > /dev/null; then
  mkdir -p "$OUT/go"
  cat > "$OUT/go/main.go" << 'EOF'
package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) { fmt.Fprintln(w, "ok") })
	if err := http.ListenAndServe("127.0.0.1:"+os.Getenv("PORT"), nil); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
EOF
  printf 'module fleetgo\n\ngo 1.21\n' > "$OUT/go/go.mod"
  (cd "$OUT/go" && CGO_ENABLED=0 GOOS=linux GOARCH=$ARCH GOTOOLCHAIN=local go build -trimpath -ldflags '-s -w' -o server . ) 2> "$OUT/go/build.err" && HAVEGO=1
fi
[ "$HAVEGO" = 1 ] || log "no Go toolchain (or the build failed): the Go slots run Node hello instead"
NODEJS='const http = require("http");
http.createServer((q, s) => s.end("ok\n")).listen(process.env.PORT, "127.0.0.1");'
if [ "$PG" = 1 ]; then
  command -v npm > /dev/null || fb_die "the PostgreSQL app needs npm here (examples/notes); --pg 0 to skip it"
  mkdir -p "$W/fb-1"
  rsync -a --exclude node_modules "$FB_ROOT/examples/notes/" "$W/fb-1/"
  (cd "$W/fb-1" && npm ci --no-audit --no-fund > "$OUT/npm.out" 2>&1) || fb_die "npm ci failed: $OUT/npm.out"
fi

# type_of <n>: pg | static | go | node | idle
type_of() {
  local n=$1
  if [ "$PG" = 1 ] && [ "$n" = 1 ]; then echo pg; return; fi
  case $(( (n - 2 + 4) % 4 )) in 0) echo static;; 1) echo go;; 2) echo node;; 3) echo idle;; esac
}
mkapp() { # n -> writes $W/fb-n
  local n=$1 d=$W/fb-$1 t
  t=$(type_of "$n")
  [ "$t" = pg ] && { sed -i.bak "s/^app = .*/app = fb-$n/" "$d/tando.conf"; rm -f "$d/tando.conf.bak"; echo "stamp-$RANDOM" > "$d/VERSION"; return; }
  mkdir -p "$d"
  case $t in
    static)
      mkdir -p "$d/public"; echo "<h1>fb-$n</h1>" > "$d/public/index.html"; echo "$RANDOM" > "$d/public/stamp"
      printf 'app = fb-%s\nrecipe = static\nout = public\nmemory = 64M\n' "$n" > "$d/tando.conf";;
    go)
      if [ "$HAVEGO" = 1 ]; then
        cp "$OUT/go/server" "$d/server"; echo "$RANDOM" > "$d/stamp"
        printf 'app = fb-%s\nrecipe = node\nstart = ./server\nmemory = 64M\n' "$n" > "$d/tando.conf"
      else
        printf '%s\n' "$NODEJS" > "$d/server.js"; echo "$RANDOM" > "$d/stamp"
        printf 'app = fb-%s\nrecipe = node\nstart = node server.js\nmemory = %s\n' "$n" "$NMEM" > "$d/tando.conf"
      fi;;
    node|idle)
      printf '%s\n' "$NODEJS" > "$d/server.js"; echo "$RANDOM" > "$d/stamp"
      printf 'app = fb-%s\nrecipe = node\nstart = node server.js\nmemory = %s\n' "$n" "$NMEM" > "$d/tando.conf"
      [ "$t" = idle ] && printf 'idle_stop = %s\nhealth_timeout = 15\n' "$IDLE" >> "$d/tando.conf";;
  esac
}
up_one() { # n -> "fb-n rc seconds t_start_ms"
  local n=$1 t0 rc
  t0=$(now_ms)
  (cd "$W/fb-$n" && "$TANDO" up --yes -H "$HOST" > "$W/fb-$n.log" 2>&1); rc=$?
  echo "fb-$n $rc $(( ($(now_ms) - t0) )) $t0"
}

# ---- server-side readings --------------------------------------------------------------------
# measure: key/value lines and one "app" line per bench app (PSS of its processes, its slice's
# cgroup memory). Run as root on the server.
measure() {
  rroot << 'EOF'
kv() { echo "$1 $2"; }
kv host_mem_total_kb "$(awk '/^MemTotal/{print $2}' /proc/meminfo)"
kv host_mem_used_kb "$(awk '/^MemTotal/{t=$2}/^MemAvailable/{a=$2}END{print t-a}' /proc/meminfo)"
kv swap_used_kb "$(awk '/^SwapTotal/{t=$2}/^SwapFree/{f=$2}END{print t-f}' /proc/meminfo)"
kv pid1_rss_kb "$(awk '/^VmRSS/{print $2}' /proc/1/status)"
tp=$(pgrep -x tandod | head -1); kv tandod_rss_kb "$( [ -n "$tp" ] && awk '/^VmRSS/{print $2}' /proc/$tp/status || echo 0)"
kv caddy_rss_kb "$(for p in $(pgrep -x caddy); do awk '/^VmRSS/{print $2}' /proc/$p/status; done | awk '{s+=$1}END{print s+0}')"
ps -C systemd-journald -o rss=,args= | awk '/tando-fb/{s+=$1;n++}END{print "journald_ns_count " n+0; print "journald_ns_rss_kb " s+0}'
kv units_loaded "$(systemctl list-units --all --no-legend --plain | wc -l)"
kv tando_slice_kb "$( [ -r /sys/fs/cgroup/tando.slice/memory.current ] && awk '{print int($1/1024)}' /sys/fs/cgroup/tando.slice/memory.current || echo 0)"
kv failed_units "$(systemctl --failed --no-legend --plain | wc -l)"
ps -eo user:40=,pid= | awk '$1 ~ /^tando-fb-[0-9]+$/' | while read -r u p; do
  echo "$u $(awk '/^Pss:/{print $2}' /proc/$p/smaps_rollup 2>/dev/null || echo 0)"
done | awk '{ s[$1] += $2; n[$1]++ } END { for (u in s) print "pss", u, s[u], n[u] }'
for d in /sys/fs/cgroup/tando.slice/tando-fb*.slice; do
  [ -r "$d/memory.current" ] || continue
  a=${d##*/tando-}; a=${a%.slice}; a=$(printf '%b' "${a//\\x2d/-}")
  echo "cg $a $(awk '{print int($1/1024)}' "$d/memory.current") $(awk '$1=="anon"{print int($2/1024)}' "$d/memory.stat")"
done
EOF
}
# tandod's own CPU so far: "<seconds running> <cpu ms> <children cpu ms>"
costs() { rroot << 'EOF' 2> /dev/null | awk '$1 == "costs" { print $2, $4, $5 }'
/opt/tando/bin/tando-status cost
EOF
}
topcost() { rroot << 'EOF' 2> /dev/null | awk '$1 == "cost" && $2 == "total" { n = $5 + $6; $1 = $2 = ""; print n, $0 }' | sort -rn | head -6
/opt/tando/bin/tando-status cost
EOF
}
# reloads_since <epoch>: daemon-reloads PID 1 logged since then
reloads_since() { rsh "sudo journalctl _PID=1 --since @$1 --no-pager -o cat 2> /dev/null | grep -c '^Reloading finished'" | tr -d ' \r'; }
srv_epoch() { rsh date +%s | tr -d '\r'; }
# kvget <file> <key>
kvget() { awk -v k="$2" '$1 == k { print $2 }' "$1"; }
# type_stats <measure file> <label>: per type: apps, PSS and cgroup anon average (MB)
type_stats() {
  awk -v tfile="$OUT/types.tsv" '
    BEGIN { while ((getline l < tfile) > 0) { split(l, f, "\t"); ty[f[1]] = f[2] } }
    $1 == "pss" { a = $2; sub(/^tando-/, "", a); if (a in ty) { p[ty[a]] += $3; np[ty[a]]++ } }
    $1 == "cg"  { if ($2 in ty) { c[ty[$2]] += $3; an[ty[$2]] += $4; nc[ty[$2]]++ } }
    END { for (t in np) printf "%s\t%d\t%.1f\t%.1f\t%.1f\n", t, np[t], p[t] / np[t] / 1024, (nc[t] ? c[t] / nc[t] / 1024 : 0), (nc[t] ? an[t] / nc[t] / 1024 : 0) }' "$1" | sort
}

probe() { # url -> "<code> <seconds>"  (curl; never fails the script)
  # shellcheck disable=SC2086
  curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time "${2:-60}" $CURLX "$1" 2> /dev/null || echo "000 0"
}
# probe_all <file with "app url">: parallel; writes "app code seconds" lines
probe_all() {
  xargs -P 16 -L 1 sh -c 'r=$(curl -s -o /dev/null -w "%{http_code} %{time_total}" --max-time 60 '"$CURLX"' "$2" 2>/dev/null || echo "000 0"); echo "$1 $r"' _ < "$1"
}

START_EPOCH=$(srv_epoch)
rep "# Fleet bench: $HOST"
rep ""
rep "- date: $(date -u +%Y-%m-%d\ %H:%M) UTC; client tando $("$TANDO" version 2> /dev/null | head -1)"
rep "- apps: N=$N (mix: 1 PostgreSQL app if --pg, then static / Go / Node / Node with idle_stop=$IDLE), create parallelism P=$P"
rep "- server: $(rsh bash -s << 'HDR' | tr '\n' ' '
nproc
awk '/^MemTotal/ { printf "%d MB RAM\n", $2 / 1024 }' /proc/meminfo
. /etc/os-release; echo "$PRETTY_NAME"; uname -r
HDR
)"
rep "- apps on the host before: $(wc -l < "$OUT/apps.before" | tr -d ' ') ($(echo "$mine" | grep -c .) fb-*, $(echo "$others" | grep -c .) other)"
rep ""
measure > "$OUT/m0.txt" || fb_die "cannot measure on $HOST (ssh or sudo failed)"
log "baseline: used $(kvget "$OUT/m0.txt" host_mem_used_kb) kB, PID 1 $(kvget "$OUT/m0.txt" pid1_rss_kb) kB, units $(kvget "$OUT/m0.txt" units_loaded)"

# ---- 1. create -------------------------------------------------------------------------------
: > "$OUT/up.tsv"; : > "$OUT/types.tsv"; : > "$OUT/steps.tsv"
STEP=$(( N / 4 )); [ "$STEP" -ge 1 ] || STEP=1
n=1 created=0 t_create=$(now_ms)
have=" $(echo "$mine" | tr '\n' ' ') "
while [ $n -le "$N" ]; do
  j=0
  while [ $j -lt "$P" ] && [ $n -le "$N" ]; do
    printf 'fb-%s\t%s\n' "$n" "$(type_of $n)" >> "$OUT/types.tsv"
    case $have in *" fb-$n "*) log "fb-$n exists, kept";; *)
      mkapp $n
      up_one $n >> "$OUT/up.tsv" &
      created=$((created + 1));;
    esac
    n=$((n + 1)) j=$((j + 1))
  done
  wait
  if [ $(( (n - 1) % STEP )) = 0 ] || [ $n -gt "$N" ]; then
    tm=$(rroot << 'TM'
for k in 1 2 3; do s=$(date +%s%N); systemctl daemon-reload; printf '%s ' $(( ($(date +%s%N) - s) / 1000000 )); done
printf '| '
for k in 1 2 3; do s=$(date +%s%N); systemctl reload caddy; printf '%s ' $(( ($(date +%s%N) - s) / 1000000 )); done
TM
)
    r=${tm%%|*}; c=${tm#*|}
    measure > "$OUT/m-$((n - 1)).txt"
    echo "$((n - 1)) | $r | $c | $(kvget "$OUT/m-$((n - 1)).txt" pid1_rss_kb) | $(kvget "$OUT/m-$((n - 1)).txt" units_loaded) | $(kvget "$OUT/m-$((n - 1)).txt" caddy_rss_kb)" >> "$OUT/steps.tsv"
    log "$((n - 1)) apps: daemon-reload (ms)$r, caddy reload (ms)$c, timed on the server"
  fi
done
T_CREATE_S=$(( ($(now_ms) - t_create) / 1000 ))
# retry what failed on the first try, alone
fails=$(awk '$2 != 0 { print $1 }' "$OUT/up.tsv")
: > "$OUT/retry.tsv"
for a in $fails; do up_one "${a#fb-}" >> "$OUT/retry.tsv"; done
NFAIL1=$(echo "$fails" | grep -c .)
NFAIL2=$(awk '$2 != 0' "$OUT/retry.tsv" | wc -l | tr -d ' ')
RELOADS=$(reloads_since "$START_EPOCH")
awk '$2 == 0 { print $3 / 1000 }' "$OUT/up.tsv" > "$OUT/up.s"
awk '$2 == 0 && NR > 0 { print $3 / 1000 }' "$OUT/up.tsv" | tail -10 > "$OUT/up.last10.s"

# ---- 2. does every app answer ----------------------------------------------------------------
fb_apps > "$OUT/apps.now"
grep '^fb-[0-9]' "$OUT/apps.now" | awk '$3 != "-" { print $1, $3 }' > "$OUT/urls.txt"
probe_all "$OUT/urls.txt" > "$OUT/answers1.txt"
OK1=$(awk '$2 == 200' "$OUT/answers1.txt" | wc -l | tr -d ' ')
log "first check: $OK1 of $(wc -l < "$OUT/urls.txt" | tr -d ' ') answer 200"

# ---- 3. idle window: PID 1, tandod CPU -----------------------------------------------------
idle_n() { fb_apps | awk '$1 ~ /^fb-[0-9]+$/ && $2 == "idle"' | wc -l | tr -d ' '; }
want_idle=$(awk -F'\t' '$2 == "idle"' "$OUT/types.tsv" | wc -l | tr -d ' ')
end=$((SECONDS + 240)); while [ "$(idle_n)" -lt "$want_idle" ] && [ $SECONDS -lt $end ]; do sleep 10; done
IDLE_N=$(idle_n)
log "idle: $IDLE_N of $want_idle idle_stop apps are idle; sampling for $IDLEW s"
: > "$OUT/pid1.tsv"
c0=$(costs); t0=$(now_ms)
end=$((SECONDS + IDLEW)); k=0
while :; do
  rss=$(rsh 'awk "/^VmRSS/{print \$2}" /proc/1/status' | tr -d '\r')
  printf '%s\t%s\n' "$(( ($(now_ms) - t0) / 1000 ))" "$rss" >> "$OUT/pid1.tsv"
  [ $SECONDS -lt "$end" ] || break
  sleep 30; k=$((k + 1))
done
c1=$(costs); t1=$(now_ms)
measure > "$OUT/m-idle.txt"
topcost > "$OUT/topcost.txt"

# ---- 4. wake latency of the idle apps, cold then warm ----------------------------------------
fb_apps | awk '$1 ~ /^fb-[0-9]+$/ && $2 == "idle" && $3 != "-" { print $1, $3 }' > "$OUT/idleurls.txt"
: > "$OUT/wake.cold"; : > "$OUT/wake.warm"
while read -r a u; do
  r=$(probe "$u"); echo "$r" | awk '{ printf "%.0f\n", $2 * 1000 }' >> "$OUT/wake.cold"; echo "$a $r" >> "$OUT/wake.raw"
done < "$OUT/idleurls.txt"
while read -r a u; do probe "$u" | awk '{ printf "%.1f\n", $2 * 1000 }' >> "$OUT/wake.warm"; done < "$OUT/idleurls.txt"
measure > "$OUT/m-awake.txt"

# ---- 5. redeploy at N: p50/p95 -------------------------------------------------------------------
: > "$OUT/redeploy.s"
SAMPLE=${FLEET_DEPLOYS:-12}
step=$(( N / SAMPLE )); [ "$step" -ge 1 ] || step=1
m=2; ndep=0
while [ $m -le "$N" ] && [ $ndep -lt "$SAMPLE" ]; do
  if [ "$(type_of $m)" != pg ]; then
    d=$W/fb-$m
    if [ "$(type_of $m)" = static ]; then echo "$RANDOM" > "$d/public/stamp"; else echo "$RANDOM" > "$d/stamp"; fi
    s=$(now_ms); (cd "$d" && "$TANDO" deploy --yes -H "$HOST" > "$W/fb-$m.deploy.log" 2>&1); rc=$?
    [ $rc = 0 ] && echo "$(( $(now_ms) - s ))" | awk '{ print $1 / 1000 }' >> "$OUT/redeploy.s" || echo "deploy of fb-$m failed (rc=$rc): $W/fb-$m.deploy.log" >&2
    ndep=$((ndep + 1))
  fi
  m=$((m + step))
done

# ---- 6. tando ls -------------------------------------------------------------------------------
: > "$OUT/ls.s"; : > "$OUT/lsjson.s"
for _ in 1 2 3; do
  s=$(now_ms); "$TANDO" ls -H "$HOST" > /dev/null 2>&1; echo "$(( $(now_ms) - s ))" | awk '{ print $1 / 1000 }' >> "$OUT/ls.s"
  s=$(now_ms); "$TANDO" ls -H "$HOST" --json > /dev/null 2>&1; echo "$(( $(now_ms) - s ))" | awk '{ print $1 / 1000 }' >> "$OUT/lsjson.s"
done

# ---- report (before the reboot, so a failed reboot still leaves it) ---------------------------
rep "## Create"
rep ""
rep "| | |"; rep "|---|---|"
rep "| apps created / first-try failures / still failing after one retry | $created / $NFAIL1 / $NFAIL2 |"
rep "| \`tando up\` (create) p50 / p95 / max | $(pctl 50 "$OUT/up.s") s / $(pctl 95 "$OUT/up.s") s / $(pctl 100 "$OUT/up.s") s |"
rep "| the last 10 creates, mean | $(avg "$OUT/up.last10.s") s |"
rep "| total time to create the fleet (P=$P) | $T_CREATE_S s |"
rep "| daemon-reloads in the whole run (create + the checks) | $RELOADS (about $(awk -v r="$RELOADS" -v c="$created" 'BEGIN { if (c) printf "%.1f", r / c; else print "-" }') per created app) |"
rep ""
rep "At each quarter of the fleet (timed on the server, 3 runs each):"
rep ""
rep "| apps | systemctl daemon-reload (ms) | systemctl reload caddy (ms) | PID 1 RSS kB | units loaded | Caddy RSS kB |"
rep "|---|---|---|---|---|---|"
awk -F' [|] ' '{ print "| " $1 " | " $2 " | " $3 " | " $4 " | " $5 " | " $6 " |" }' "$OUT/steps.tsv" >> "$REP"
rep ""
rep "## Answers"
rep ""
TOTAL=$(wc -l < "$OUT/urls.txt" | tr -d ' ')
rep "After creation: $OK1 of $TOTAL apps answer 200. Not answering: $(awk '$2 != 200 { printf "%s(%s) ", $1, $2 }' "$OUT/answers1.txt")"
rep ""
rep "## Memory"
rep ""
rep "(On a Docker test server the host figures are the VM's, not the container's: read PSS and tando.slice there.)"
rep ""
rep "Baseline before the bench: host used $(kvget "$OUT/m0.txt" host_mem_used_kb) kB, PID 1 $(kvget "$OUT/m0.txt" pid1_rss_kb) kB, tandod $(kvget "$OUT/m0.txt" tandod_rss_kb) kB, Caddy $(kvget "$OUT/m0.txt" caddy_rss_kb) kB, $(kvget "$OUT/m0.txt" units_loaded) units."
rep ""
for lab in idle awake; do
  f=$OUT/m-$lab.txt
  rep "Fleet $lab ($( [ $lab = idle ] && echo "$IDLE_N of $want_idle idle_stop apps stopped" || echo "after waking every idle app")): host used $(kvget "$f" host_mem_used_kb) kB (+$(( $(kvget "$f" host_mem_used_kb) - $(kvget "$OUT/m0.txt" host_mem_used_kb) )) kB vs baseline), tando.slice $(kvget "$f" tando_slice_kb) kB, PID 1 $(kvget "$f" pid1_rss_kb) kB, tandod $(kvget "$f" tandod_rss_kb) kB, Caddy $(kvget "$f" caddy_rss_kb) kB, journald namespaces $(awk '$1=="journald_ns_count"{print $2}' "$f") running ($(awk '$1=="journald_ns_rss_kb"{print $2}' "$f") kB), swap used $(kvget "$f" swap_used_kb) kB, units failed $(kvget "$f" failed_units)."
  rep ""
  rep "| type | apps with a process | PSS per app (MB) | slice memory.current (MB) | slice anon (MB) |"
  rep "|---|---|---|---|---|"
  type_stats "$f" | awk -F'\t' '{ print "| " $1 " | " $2 " | " $3 " | " $4 " | " $5 " |" }' >> "$REP"
  rep ""
done
rep "Per app beyond its own PSS (awake fleet, divided by the apps made): host used +$(awk -v a="$(kvget "$OUT/m-awake.txt" host_mem_used_kb)" -v b="$(kvget "$OUT/m0.txt" host_mem_used_kb)" -v n="$TOTAL" 'BEGIN { if (n) printf "%.2f", (a - b) / n / 1024; else print "-" }') MB; PID 1 +$(awk -v a="$(kvget "$OUT/m-awake.txt" pid1_rss_kb)" -v b="$(kvget "$OUT/m0.txt" pid1_rss_kb)" -v n="$TOTAL" 'BEGIN { if (n) printf "%.0f", (a - b) / n; else print "-" }') kB; Caddy +$(awk -v a="$(kvget "$OUT/m-awake.txt" caddy_rss_kb)" -v b="$(kvget "$OUT/m0.txt" caddy_rss_kb)" -v n="$TOTAL" 'BEGIN { if (n) printf "%.0f", (a - b) / n; else print "-" }') kB."
rep ""
rep "## Monitoring and PID 1 over the idle window ($IDLEW s, idle fleet)"
rep ""
if [ -n "$c0" ] && [ -n "$c1" ]; then
  rep "- tandod CPU (\`tando-status cost\`, its own plus its children's): $(echo "$c0 $c1 $t0 $t1" | awk '{ d = ($5 + $6) - ($2 + $3); w = ($8 - $7); if (w > 0) printf "%d ms of CPU in %.0f s = %.2f%% of one core", d, w / 1000, d / w * 100; else print "no window" }')"
else
  rep "- tandod CPU: \`tando-status cost\` is not available on this server (an older tando); nothing recorded"
fi
rep "- PID 1 RSS (kB) over time: first $(head -1 "$OUT/pid1.tsv" | cut -f2), last $(tail -1 "$OUT/pid1.tsv" | cut -f2), max $(cut -f2 "$OUT/pid1.tsv" | sort -n | tail -1), min $(cut -f2 "$OUT/pid1.tsv" | sort -n | head -1) ($(wc -l < "$OUT/pid1.tsv" | tr -d ' ') samples; $OUT/pid1.tsv)"
rep ""
rep "Where tandod's CPU went (since its start: CPU ms plus children's ms, section):"
rep ""
rep '```'
cat "$OUT/topcost.txt" >> "$REP"
rep '```'
rep ""
rep "## Wake latency ($(wc -l < "$OUT/idleurls.txt" | tr -d ' ') idle_stop apps, each asked once while stopped; time to the full answer from this machine, so the network is in it)"
rep ""
rep "| | p50 ms | p95 ms | max ms |"; rep "|---|---|---|---|"
rep "| cold (app stopped) | $(pctl 50 "$OUT/wake.cold") | $(pctl 95 "$OUT/wake.cold") | $(pctl 100 "$OUT/wake.cold") |"
rep "| warm (just woken) | $(pctl 50 "$OUT/wake.warm") | $(pctl 95 "$OUT/wake.warm") | $(pctl 100 "$OUT/wake.warm") |"
rep ""
rep "Answers during the wake test that were not 200: $(awk '$2 != 200 { printf "%s(%s) ", $1, $2 }' "$OUT/wake.raw" 2> /dev/null)"
rep ""
rep "## Operations at N=$TOTAL"
rep ""
rep "| | p50 | p95 | runs |"; rep "|---|---|---|---|"
rep "| \`tando deploy\` of a changed app (returns when live) | $(pctl 50 "$OUT/redeploy.s") s | $(pctl 95 "$OUT/redeploy.s") s | $(wc -l < "$OUT/redeploy.s" | tr -d ' ') |"
rep "| \`tando ls\` | $(pctl 50 "$OUT/ls.s") s | $(pctl 95 "$OUT/ls.s") s | 3 |"
rep "| \`tando ls --json\` | $(pctl 50 "$OUT/lsjson.s") s | $(pctl 95 "$OUT/lsjson.s") s | 3 |"
rep ""

# ---- 7. reboot ---------------------------------------------------------------------------------
RC=0
if [ "$REBOOT" = 1 ]; then
  log "rebooting"
  fb_apps | awk '$1 ~ /^fb-[0-9]+$/ && $3 != "-" { print $1, $3 }' > "$OUT/urls.txt"
  before=$(rsh 'cat /proc/sys/kernel/random/boot_id; cut -d" " -f1 /proc/uptime' | tr '\n' ' ')
  t0=$(now_ms)
  if [ -n "${FLEET_REBOOT_CMD:-}" ]; then sh -c "$FLEET_REBOOT_CMD" > /dev/null 2>&1
  else rsh 'sudo -n systemctl reboot' > /dev/null 2>&1; fi
  # wait for the server to go away, then to answer again (a reboot that never happened is a failure)
  down=0; end=$((SECONDS + 120))
  while [ $SECONDS -lt $end ]; do rsh true > /dev/null 2>&1 || { down=1; break; }; sleep 1; done
  T_DOWN=$(( ($(now_ms) - t0) / 1000 ))
  if [ $down = 0 ]; then
    rep "## Reboot"; rep ""; rep "**FAIL: the server still answered ssh 120 s after the reboot command.** Nothing was measured."
    RC=1
  else
    fb_wait_ssh "${FLEET_REBOOT_WAIT:-900}" || { rep "## Reboot"; rep ""; rep "**FAIL: ssh did not come back within ${FLEET_REBOOT_WAIT:-900} s.**"; RC=1; }
    T_SSH=$(( ($(now_ms) - t0) / 1000 ))
    if [ $RC = 0 ]; then
      cp "$OUT/urls.txt" "$OUT/pending.txt"; : > "$OUT/back.tsv"
      end=$((SECONDS + ${FLEET_REBOOT_WAIT:-900}))
      while [ -s "$OUT/pending.txt" ] && [ $SECONDS -lt $end ]; do
        probe_all "$OUT/pending.txt" > "$OUT/round.txt"
        el=$(( ($(now_ms) - t0) / 1000 ))
        awk -v el="$el" '$2 == 200 { print $1, el }' "$OUT/round.txt" >> "$OUT/back.tsv"
        awk 'NR == FNR { if ($2 == 200) ok[$1] = 1; next } !($1 in ok)' "$OUT/round.txt" "$OUT/pending.txt" > "$OUT/pending.new"
        mv "$OUT/pending.new" "$OUT/pending.txt"
        [ -s "$OUT/pending.txt" ] && sleep 3
      done
      T_RUN=$(( ($(now_ms) - t0) / 1000 ))
      rsh 'timeout 240 systemctl is-system-running --wait' > /dev/null 2>&1   # boot finished (boot time and failed units below)
      NBACK=$(wc -l < "$OUT/back.tsv" | tr -d ' ')
      NMISS=$(wc -l < "$OUT/pending.txt" | tr -d ' ')
      after=$(rsh 'cat /proc/sys/kernel/random/boot_id; cut -d" " -f1 /proc/uptime' | tr '\n' ' ')
      rep "## Reboot"
      rep ""
      rep "| | |"; rep "|---|---|"
      rep "| boot id / uptime before, after | $before / $after (a Docker test server shares the host's boot id: the ssh outage is the proof there) |"
      rep "| seconds until ssh went away / answered again | $T_DOWN / $T_SSH |"
      rep "| seconds until the first app answered 200 | $(awk '{ print $2 }' "$OUT/back.tsv" | sort -n | head -1) |"
      rep "| seconds until the last app answered 200 | $(awk '{ print $2 }' "$OUT/back.tsv" | sort -n | tail -1) ($NBACK of $TOTAL) |"
      rep "| apps back p50 / p95 (s after the reboot command) | $(awk '{ print $2 }' "$OUT/back.tsv" | pctl 50 /dev/stdin) / $(awk '{ print $2 }' "$OUT/back.tsv" | pctl 95 /dev/stdin) |"
      rep "| boot time (systemd-analyze) | $(rsh 'systemd-analyze 2>/dev/null | head -1' | tr -d '\r') |"
      rep "| failed units after boot | $(rsh 'systemctl --failed --no-legend --plain | awk "{print \$1}" | tr "\n" " "') |"
      if [ "$NMISS" -gt 0 ]; then
        rep ""; rep "**FAIL: $NMISS app(s) did not answer 200 within ${FLEET_REBOOT_WAIT:-900} s:** $(awk '{ printf "%s ", $1 }' "$OUT/pending.txt")"
        RC=1
      else
        rep ""; rep "Every app answered 200 after the reboot."
      fi
    fi
  fi
fi
rep ""
rep "Raw files: $OUT"
echo
cat "$REP"
echo
log "report: $REP (apps stay on $HOST: bench/fleet.sh $HOST --cleanup removes the fb-* ones)"
exit $RC
