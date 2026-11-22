# shellcheck shell=bash
# bench/fleet-common.sh: helpers shared by bench/fleet.sh, bench/rebuild-drill.sh and
# bench/container-egress.sh (not part of the test tiers). Source it; bash 3.2 compatible.
#
#   fb_init <host>   resolves the registered host entry into ssh options; sets TANDO, CFG, FB_HOST
#   rsh <cmd...>     runs a command on the server as the admin (one ssh, no tty)
#   rroot            reads a script on stdin and runs it as root on the server
#   now_ms, pctl, say, fb_apps, fb_wait_ssh ...
# The server is reached with the host entry's own key and port, exactly as tando does. Every
# helper that changes something on the server touches apps named fb-* only.

FB_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TANDO=${TANDO:-$FB_ROOT/bin/tando}
export TANDO_COLOR=never
CFG=${TANDO_CONFIG_DIR:-$HOME/.config/tando}
FB_SSHO=()

fb_die() { echo "$(basename "$0"): $*" >&2; exit 1; }

fb_init() {
  FB_HOST=$1
  [ -f "$CFG/hosts/$FB_HOST" ] || fb_die "host '$FB_HOST' is not registered (tando host add / tando host ls; config dir $CFG)"
  local f=$CFG/hosts/$FB_HOST k v port="" key="" tgt="" ins=0
  while IFS= read -r l; do
    k=${l%%=*} v=${l#*=}
    case $k in target) tgt=$v;; port) port=$v;; key) key=$v;; insecure) ins=$v;; esac
  done < "$f"
  FB_TARGET=$tgt
  FB_SSHO=(-o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=10 -o LogLevel=ERROR)
  [ -n "$port" ] && FB_SSHO+=(-p "$port")
  [ -n "$key" ] && FB_SSHO+=(-i "$key" -o IdentitiesOnly=yes)
  if [ "$ins" = 1 ]; then
    FB_SSHO+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
  else
    FB_SSHO+=(-o StrictHostKeyChecking=yes)
    [ -f "$CFG/known_hosts" ] && FB_SSHO+=(-o "GlobalKnownHostsFile=$CFG/known_hosts")
  fi
  [ -n "$FB_TARGET" ] || fb_die "host entry $FB_HOST has no target"
}

rsh() { ssh "${FB_SSHO[@]}" "$FB_TARGET" "$@"; }
rroot() { ssh "${FB_SSHO[@]}" "$FB_TARGET" 'sudo -n bash -s'; }   # script on stdin

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'; }
# pctl <p> <file of numbers>: nearest-rank percentile (empty file: "-")
pctl() { sort -n "$2" | awk -v p="$1" '{ a[NR] = $1 } END { if (!NR) { print "-"; exit } i = int((p / 100) * NR + 0.999999); if (i < 1) i = 1; if (i > NR) i = NR; print a[i] }'; }
avg() { awk '{ s += $1; n++ } END { if (n) printf "%.1f", s / n; else print "-" }' "$1"; }

# fb_apps: "<app> <state> <link>" per app of the host, from `tando ls --json`
fb_apps() {
  "$TANDO" ls -H "$FB_HOST" --json 2> /dev/null | python3 -I -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(3)
for a in d.get("apps", []):
    print(a["app"], a.get("state") or "-", a.get("link") or "-")
'
}

# fb_wait_ssh <seconds>: wait until the server answers ssh again
fb_wait_ssh() {
  local end=$((SECONDS + $1))
  until rsh true > /dev/null 2>&1; do
    [ $SECONDS -lt $end ] || return 1
    sleep 2
  done
}

# fb_cpu_arch: the server's CPU as Go names it
fb_goarch() { case $(rsh uname -m) in aarch64|arm64) echo arm64;; *) echo amd64;; esac; }
