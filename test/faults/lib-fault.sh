# shellcheck shell=bash
# lib-fault.sh: helpers for the tando fault-injection scenarios (test/faults; docs/FAULT-REVIEW.md).
# Each scenario: . lib-fault.sh; f_init <id> "<fault>" "<point>"; ...; f_end
# Server: TANDO_TEST_NAME (default tando-fault), TANDO_TEST_SSH_PORT (2264), TANDO_TEST_HTTP_PORT (8364).
set -u
SC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)              # test/faults
ROOT=$(cd "$SC/../.." && pwd -P)
R=$ROOT/bin/tando
export TANDO_TEST_NAME=${TANDO_TEST_NAME:-tando-fault} TANDO_TEST_SSH_PORT=${TANDO_TEST_SSH_PORT:-2264}
export TANDO_TEST_HTTP_PORT=${TANDO_TEST_HTTP_PORT:-8364}
FW=${FAULT_WORK:-$ROOT/test/.e2e-faults-$TANDO_TEST_NAME}      # work files and results
mkdir -p "$FW"
export TANDO_CONFIG_DIR=$FW/cfg-$TANDO_TEST_NAME TANDO_COLOR=never
SSH=$ROOT/test/server/ssh.sh
HP=$TANDO_TEST_HTTP_PORT
F_FAILS=0 F_NOTES="" F_TRUTH=y F_RECOVER=y F_DOWN=0 F_BAD=0 F_N=0

log() { echo "---- $*" >&2; }
srv() { "$SSH" "$@"; }
sudo_srv() { "$SSH" "sudo bash -c $(printf '%q' "$*")"; }
url() { echo "http://$1.localhost:$HP${2:-/}"; }
ver() { curl -s -m 5 "$(url "$1")" | sed -n 's/^v\([0-9]*\)$/\1/p'; }
until_() { local t=$1; shift; while ! "$@"; do t=$((t - 1)); [ $t -gt 0 ] || return 1; sleep 1; done; }

# expectation: ok <text> cmd... ; a failed one marks the scenario failed
ok() { local t=$1; shift; if "$@"; then echo "  ok   $t" >&2; else echo "  FAIL $t" >&2; F_FAILS=$((F_FAILS + 1)); F_NOTES="$F_NOTES; $t"; fi; }
untruth() { F_TRUTH=n; F_NOTES="$F_NOTES; untruthful: $*"; echo "  LIE  $*" >&2; }

f_init() { # id fault point
  F_ID=$1 F_FAULT=$2 F_POINT=$3
  W=$FW/run/$TANDO_TEST_NAME/$F_ID
  rm -rf "$W"; mkdir -p "$W"
  log "scenario $F_ID: $F_FAULT @ $F_POINT ($TANDO_TEST_NAME)"
  # an upload that takes a while (b1-b3): random, so neither rsync nor the disk compress it
  [ -s "$FW/big/blob.bin" ] || { mkdir -p "$FW/big"; head -c 209715200 /dev/urandom > "$FW/big/blob.bin"; }
  f_host
}

# the host registered and set up once per server
f_host() {
  if [ ! -f "$TANDO_CONFIG_DIR/.setup-done" ] || ! srv true 2> /dev/null; then
    mkdir -p "$TANDO_CONFIG_DIR"
    "$R" host add test vmadmin@127.0.0.1 --port "$TANDO_TEST_SSH_PORT" --key "$ROOT/test/server/id_test" \
      --yes > /dev/null 2>&1
    "$R" host setup test public_port="$HP" > "$FW/host-setup.out" 2>&1 || { cat "$FW/host-setup.out" >&2; exit 1; }
    touch "$TANDO_CONFIG_DIR/.setup-done"
  fi
}

# f_app <app> [extra tando.conf lines]: work dir $W/<app> with the fault app; not deployed
f_app() {
  local a=$1; shift
  mkdir -p "$W/$a"
  cp "$SC/app/server.js" "$W/$a/"
  printf 'app = %s\nrecipe = node\nstart = node server.js\nhealth = /health\nmemory = 128M\nhealth_timeout = 15\n' "$a" > "$W/$a/tando.conf"
  for l in "$@"; do printf '%s\n' "$l" >> "$W/$a/tando.conf"; done
  echo ok > "$W/$a/BEHAVIOR"
}
setv() { echo "$2" > "$W/$1/VERSION"; echo "${3:-ok}" > "$W/$1/BEHAVIOR"; }
# deploy <app> <version> [behaviour] [cmd: up|deploy]: output in $W/<app>.d<version>.out, status in DRC
deploy() {
  setv "$1" "$2" "${3:-ok}"
  (cd "$W/$1" && "$R" "${4:-deploy}" > "$W/$1.d$2.out" 2>&1); DRC=$?
  return $DRC
}
# fresh app with v1 and v2 deployed and verified (a last good and an older release)
f_fresh() { # app [extra conf lines]
  local a=$1; shift
  srv "sudo test -d /opt/tando/apps/$a" 2> /dev/null && { echo "$a" | (cd "$W" && "$R" destroy -a "$a" --purge > /dev/null 2>&1); }
  f_app "$a" "$@"
  # a deploy that fails here is a regression, not an environment problem: exit 1 (FAIL), never 2 (SKIP)
  deploy "$a" 1 ok up || { cat "$W/$a.d1.out" >&2; echo "f_fresh: up failed" >&2; exit 1; }
  deploy "$a" 2 ok || { cat "$W/$a.d2.out" >&2; echo "f_fresh: deploy 2 failed" >&2; exit 1; }
  [ "$(ver "$a")" = 2 ] || { echo "f_fresh: v2 not served" >&2; exit 1; }
}
rid() { sed -n 's/.*release \([0-9-]*\) *│/\1/p' "$1" | head -1; }

# request loop through Caddy: "<code> <seconds> <epoch>" per line, ~5/s
loop_start() { # app
  rm -f "$W/loop.stop"
  (
    while [ ! -f "$W/loop.stop" ]; do
      curl -s -o /dev/null -m 20 -w '%{http_code} %{time_total}' "$(url "$1")"
      perl -MTime::HiRes=time -e 'printf " %.3f\n", time'
      sleep 0.2
    done
  ) > "$W/loop" 2> /dev/null &
  LOOP=$!
  sleep 0.5
}
# stop: F_N requests, F_BAD non-200, F_DOWN longest gap between two 200s minus 1 s (s), F_SLOW > 2 s
loop_stop() {
  sleep 0.5; touch "$W/loop.stop"; wait "$LOOP" 2> /dev/null
  read -r F_N F_BAD F_SLOW F_GAP < <(awk '
    { n++; if ($1 != 200) bad++; if ($2 > 2) slow++
      if ($1 == 200) { if (last != "" && $3 - last > gap) gap = $3 - last; last = $3 } }
    END { printf "%d %d %d %.1f\n", n, bad, slow, gap }' "$W/loop")
  F_DOWN=$(awk -v g="$F_GAP" 'BEGIN { d = g - 1; if (d < 0) d = 0; printf "%.1f", d }')
  echo "  loop: $F_N requests, $F_BAD failed, $F_SLOW slower than 2 s, longest gap ${F_GAP}s" >&2
  awk '{print $1}' "$W/loop" | sort | uniq -c | tr -s ' \n' ' ' >&2; echo >&2
}

# server facts of an app as key=value (root)
facts() { # app
  srv "sudo bash -s $1" > "$W/facts" 2> /dev/null <<'EOF'
A=$1 D=/opt/tando/apps/$1
g() { sed -n "s/^$1=//p" "$2" 2> /dev/null | head -1; }
s=$(g current "$D/state")
echo "phase=$(g phase "$D/state")"
echo "scur=$s"
l=$(readlink "$D/current" 2> /dev/null); echo "lcur=${l##*/}"
echo "curstatus=$(g "status_$s" "$D/state")"
echo "lastgood=$(g last_good "$D/state")"
echo "actresult=$(g result "$D/activation")"
echo "unit=$(systemctl is-active tando-$A 2> /dev/null)"
echo "curver=$(cat "$D/current/VERSION" 2> /dev/null)"
echo "lease=$([ -f "$D/upload" ] && echo held || echo free)"
echo "releases=$(ls "$D/releases" 2> /dev/null | tr '\n' ' ')"
echo "statefile=$(stat -c %s "$D/state" 2> /dev/null)"
echo "caddysite=$(grep -c reverse_proxy /etc/caddy/tando/$A.caddy 2> /dev/null)"
echo "stray_units=$(systemctl list-units --all --plain --no-legend "tando-$A-*" 2> /dev/null | awk '$1 !~ /job|backup/ {print $1}' | tr '\n' ' ')"
EOF
  cat "$W/facts" >&2
}
fact() { sed -n "s/^$1=//p" "$W/facts"; }

# truth check: server state, `tando status`, `tando releases`, `tando history`, `tando doctor`
# against what is served. want_ver: the version that should serve now.
truth() { # app want_ver
  local a=$1 want=$2 got
  got=$(ver "$a")
  facts "$a"
  [ "$got" = "$want" ] || { F_NOTES="$F_NOTES; serves v${got:-none}, want v$want"; F_FAILS=$((F_FAILS + 1)); echo "  FAIL serves v${got:-none}, want v$want" >&2; }
  [ "$(fact phase)" = idle ] || untruth "state phase=$(fact phase) after the operation ended"
  [ "$(fact scur)" = "$(fact lcur)" ] || untruth "state current=$(fact scur) but current -> $(fact lcur)"
  [ "$(fact curver)" = "$got" ] || untruth "current release has v$(fact curver) but Caddy serves v$got"
  [ "$(fact curstatus)" = verified ] || untruth "current release status=$(fact curstatus)"
  case $(fact actresult) in running) untruth "activation result still 'running'";; esac
  "$R" status -a "$a" > "$W/status.out" 2>&1 || untruth "tando status failed"
  "$R" releases -a "$a" > "$W/releases.out" 2>&1 || untruth "tando releases failed"
  "$R" history -a "$a" > "$W/history.out" 2>&1 || untruth "tando history failed"
  "$R" doctor > "$W/doctor.out" 2>&1
  if [ "$F_TRUTH" = n ] && ! grep -q "app $a" "$W/doctor.out"; then
    F_NOTES="$F_NOTES; doctor silent about $a"; echo "  LIE  doctor says nothing about $a" >&2
  fi
}

# self-recovery: the next deploy, untouched, works
next_deploy() { # app version
  if deploy "$1" "$2" ok && [ "$(ver "$1")" = "$2" ]; then echo "  ok   next deploy v$2 works" >&2
  else F_RECOVER=n; F_NOTES="$F_NOTES; next deploy v$2 failed (rc=$DRC): $(grep -E 'busy|lease|failed|error|tando:' "$W/$1.d$2.out" | head -2 | tr '\n' ' ')"
    echo "  FAIL next deploy v$2 (rc=$DRC)" >&2; tail -5 "$W/$1.d$2.out" >&2; fi
}

f_end() {
  local res=pass
  [ "$F_FAILS" = 0 ] && [ "$F_TRUTH" = y ] && [ "$F_RECOVER" = y ] || res=fail
  printf 'RESULT\t%s\t%s\t%s\t%s\t%s/%s\t%s\t%s\t%s\n' "$F_ID" "$F_FAULT" "$F_POINT" "$res" "$F_DOWN" "$F_BAD" \
    "$F_TRUTH" "$F_RECOVER" "${F_NOTES#; }" | tee -a "$FW/results-$TANDO_TEST_NAME.tsv"
  [ $res = pass ]
}

# wait until the app's state phase is <p> (polling as root, 0.1 s)
wait_phase() { # app phase secs
  srv "sudo bash -c 'for i in \$(seq $(( $3 * 10 ))); do grep -qx phase=$2 /opt/tando/apps/$1/state 2>/dev/null && exit 0; sleep 0.1; done; exit 1'"
}
act_unit() { srv "systemctl list-units --plain --no-legend 'tando-$1-act-*'" | awk '{print $1}' | head -1; }
kill9_act() { # app: SIGKILL every process of the activation unit
  local u; u=$(act_unit "$1")
  [ -n "$u" ] || { echo "  (no activation unit)" >&2; return 1; }
  srv "sudo systemctl kill -s KILL $u"; echo "  killed $u" >&2
}
docker_restart() { docker restart -t 5 "$TANDO_TEST_NAME" > /dev/null; ok "the server came back after the restart" wait_server; }
docker_powerloss() { docker kill "$TANDO_TEST_NAME" > /dev/null; docker start "$TANDO_TEST_NAME" > /dev/null; ok "the server came back after the power loss" wait_server; }
# wait_server: ssh answers and systemd finished booting (running or degraded); fails after the timeout
booted() { case $(srv 'systemctl is-system-running' 2> /dev/null) in running|degraded) return 0;; esac; return 1; }
wait_server() {
  if ! until_ 90 srv -o ConnectTimeout=2 true 2> /dev/null; then
    # Seen with Docker on OrbStack while other test containers start and stop: the container is
    # up and sshd listens, but its published ports reach nothing. One more restart brings them back.
    if [ "$(docker exec "$TANDO_TEST_NAME" systemctl is-active ssh.socket 2> /dev/null)" = active ]; then
      echo "wait_server: the published ports do not answer: restarting the container once more" >&2
      docker restart -t 5 "$TANDO_TEST_NAME" > /dev/null
    fi
    until_ 90 srv -o ConnectTimeout=2 true 2> /dev/null || { echo "wait_server: no ssh after 90 s" >&2; return 1; }
  fi
  until_ 60 booted || { echo "wait_server: systemd still $(srv 'systemctl is-system-running') after 60 s" >&2; return 1; }
  rm -f "$TANDO_CONFIG_DIR"/cm-* 2> /dev/null; pkill -f "ControlPath=$TANDO_CONFIG_DIR" 2> /dev/null
  return 0
}

# a stray HTTP server on 127.0.0.1:<port> (transient unit fault-stray-<port>), answers 200 to everything
stray_start() { srv "sudo systemd-run --quiet --unit=fault-stray-$1 node -e \"require('http').createServer((q,s)=>s.end('stray\\\\n')).listen($1,'127.0.0.1')\""; sleep 1; }
stray_stop() { srv "sudo systemctl stop fault-stray-$1" 2> /dev/null; true; }
app_port() { srv "sudo sed -n 's/^port=//p' /opt/tando/apps/$1/app.conf"; }
# run the client in the background: CL pid, output $W/client.out (rc=N appended)
client_bg() { # app args...
  local a=$1; shift
  set -m
  (cd "$W/$a" && "$R" "$@" > "$W/client.out" 2>&1; echo "rc=$?" >> "$W/client.out") &
  CL=$!
  set +m
}
client_wait() { # secs: wait for the background client; 0 when it ended
  local t=0; while kill -0 "$CL" 2> /dev/null && [ $t -lt "$1" ]; do sleep 1; t=$((t + 1)); done
  ! kill -0 "$CL" 2> /dev/null
}
client_rc() { sed -n 's/^rc=//p' "$W/client.out"; }
# wait until a server-side upload (rsync as vmadmin into incoming/) is running
wait_rsync() { srv "for i in \$(seq 300); do pgrep -u vmadmin -f '[r]sync --server' > /dev/null && exit 0; sleep 0.1; done; exit 1"; }
# Ctrl-C / kill of the whole client process group (what a terminal does)
client_sig() { kill -"$1" -- "-$CL" 2> /dev/null; }
serves() { [ "$(ver "$1")" = "$2" ]; }          # until_ 60 serves <app> <version>
serves_any() { local v; v=$(ver "$1"); shift; for x; do [ "$v" = "$x" ] && return 0; done; return 1; }

# ---- small filesystems inside the server (tmpfs), to fill up
# tmpfs_over <dir> <size> [nr_inodes]: mount a tmpfs over dir, keeping its contents, owner and mode
tmpfs_over() {
  srv "sudo bash -s $1 $2 ${3:-0}" <<'SH'
d=$1; b=/root/tmpfs-bak${d//\//_}
rm -rf "$b"; cp -a "$d" "$b"
o=size=$2; [ "$3" != 0 ] && o=$o,nr_inodes=$3
mount -t tmpfs -o "$o" tmpfs "$d" && cp -a "$b/." "$d/" && chown --reference="$b" "$d" && chmod --reference="$b" "$d"
df -h "$d" | tail -1; df -i "$d" | tail -1
SH
}
# fill <dir> [leave KB]: a root file .fill-<n> in dir until only <leave> KB are free
fill() { srv "sudo bash -c 'f=$1/.fill; free=\$(df -Pk $1 | awk \"NR==2 {print \\\$4}\"); n=\$((free - ${2:-0})); [ \$n -gt 0 ] && head -c \${n}K /dev/zero > \$f 2>/dev/null; df -h $1 | tail -1'" >&2; }
fill_inodes() { srv "sudo bash -c 'mkdir -p $1/.ifill; i=0; while touch $1/.ifill/\$i 2>/dev/null; do i=\$((i+1)); done; df -i $1 | tail -1'" >&2; }
unfill() { srv "sudo rm -rf ${1:?}/.fill ${1:?}/.ifill; df -h $1 | tail -1" >&2; }
