#!/bin/bash
# Container egress check (not part of the test tiers): do the outgoing packets of a container app
# (recipe = container, run by root Podman on slirp4netns) go through the per-uid nftables rules
# (table inet tando: mail/connection caps, the cloud metadata block, loopback ports)?
#
#   bench/container-egress.sh <host> [--keep]
#
# The server needs `tando host setup <host> podman=yes`. It deploys examples/container as the app
# fb-egress (needs docker or podman here to build the image), then on the server, as root:
#   - makes a probe table (inet fbprobe, priority -50, before tando's rules) that only COUNTS
#     outgoing SYNs to 192.0.2.1:25 (a documentation address: nothing answers, the packet still
#     leaves the output hook) by socket owner: the app's uid, root, anyone;
#   - control: a connect as the app's uid in the host namespace (what a directory app does): the
#     counter for the app's uid must rise, or the probe proves nothing;
#   - the same connect from inside the container (podman exec ... nc): which counter rises?
#   - the metadata address 169.254.169.254: how long a connect takes as the app's uid (tando's rule
#     rejects it at once) and from inside the container;
#   - the host's own loopback through slirp4netns' gateway 10.0.2.2 (port 80, Caddy): reachable?
# then removes the probe table and (without --keep) the app. Exit 0: the container's traffic is
# constrained like a directory app's; 1: it bypasses the per-uid rules (a finding, not an error);
# 2: the check could not run.
set -u
# shellcheck source=bench/fleet-common.sh
. "$(cd "$(dirname "$0")" && pwd -P)/fleet-common.sh"
HOST="" KEEP=0
for a in "$@"; do case $a in --keep) KEEP=1;; -*) fb_die "unknown option $a";; *) HOST=$a;; esac; done
[ -n "$HOST" ] || fb_die "usage: bench/container-egress.sh <host> [--keep]"
fb_init "$HOST"
A=fb-egress
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
fb_apps | awk '{ print $1 }' | grep -x "$A" > /dev/null && { echo "$A already exists on $HOST: destroy it first (tando destroy -a $A -H $HOST --purge --yes)" >&2; exit 2; }
rsh 'command -v podman > /dev/null' || { echo "podman is not on $HOST: tando host setup $HOST podman=yes" >&2; exit 2; }

cp -R "$FB_ROOT/examples/container/." "$W/"
sed -i.bak "s/^app = .*/app = $A/" "$W/tando.conf"; rm -f "$W/tando.conf.bak"
(cd "$W" && "$TANDO" up --yes -H "$HOST" > "$W/up.log" 2>&1) || { cat "$W/up.log" >&2; echo "deploy of the container app failed" >&2; exit 2; }
cleanup() {
  [ "$KEEP" = 1 ] || "$TANDO" destroy -a "$A" -H "$HOST" --purge --yes > /dev/null 2>&1
  rm -rf "$W"
}
trap cleanup EXIT
PORT=$(fb_apps > /dev/null; "$TANDO" ls -H "$HOST" --json 2> /dev/null | python3 -I -c '
import json, sys
for a in json.load(sys.stdin)["apps"]:
    if a["app"] == "'$A'": print(a["port"])')
[ -n "$PORT" ] || { echo "no port for $A" >&2; exit 2; }

rroot << RSCRIPT > "$W/probe.out" 2> "$W/probe.err"
A=$A; PORT=$PORT
CT=tando-\$A-\$PORT
U=\$(id -u tando-\$A); G=\$(id -g tando-\$A)
cleanup() { nft delete table inet fbprobe 2> /dev/null; }
trap cleanup EXIT
nft delete table inet fbprobe 2> /dev/null
nft add table inet fbprobe
for c in c_uid c_root c_any c_cg; do nft add counter inet fbprobe \$c; done
nft add chain inet fbprobe out '{ type filter hook output priority -50; policy accept; }'
nft add rule inet fbprobe out ip daddr 192.0.2.1 tcp dport 25 meta skuid \$U counter name c_uid
nft add rule inet fbprobe out ip daddr 192.0.2.1 tcp dport 25 meta skuid 0 counter name c_root
nft add rule inet fbprobe out ip daddr 192.0.2.1 tcp dport 25 counter name c_any
# the proposed key: the app's slice (slirp4netns and conmon run inside the app's unit cgroup)
# (this app's: its container's conmon runs in the app's unit, as its slirp4netns does; another
# container app's slirp4netns may be older)
cgp=\$(awk -F: '{ print \$3 }' /proc/\$(podman inspect -f '{{.State.ConmonPid}}' tando-\$A-\$PORT)/cgroup | cut -d/ -f2,3)
echo "slice_key \$cgp"
nft add rule inet fbprobe out ip daddr 192.0.2.1 tcp dport 25 socket cgroupv2 level 2 "\"\$cgp\"" counter name c_cg
cnt() { nft list counter inet fbprobe \$1 | sed -n 's/.*packets \([0-9]*\).*/\1/p'; }
snap() { echo "\$(cnt c_uid) \$(cnt c_root) \$(cnt c_any) \$(cnt c_cg)"; }
echo "uid \$U container \$CT"
echo "tando_rules_for_uid \$(nft list table inet tando 2> /dev/null | grep -c "skuid \$U ")"
# tando's rules for a container app by its slice (fw_sync: chain containers)
echo "tando_slice_rules \$(nft list chain inet tando containers 2> /dev/null | grep -cF "\$cgp")"
echo "slirp_owner \$(ps -eo user:20=,args= | awk '/[s]lirp4netns/ { print \$1; exit }')"
# control: a directory app's way, as the app's uid in the host namespace
s0=\$(snap)
setpriv --reuid=\$U --regid=\$G --clear-groups timeout 4 bash -c 'exec 3<>/dev/tcp/192.0.2.1/25' 2> /dev/null
s1=\$(snap)
echo "control_host_uid_delta \$(echo "\$s0 \$s1" | awk '{ print \$5-\$1, \$6-\$2, \$7-\$3, \$8-\$4 }')"
# the container
podman exec \$CT sh -c 'command -v nc' > /dev/null 2>&1 || echo "nc_missing 1"
podman exec \$CT sh -c 'nc -w 4 192.0.2.1 25 < /dev/null' > /dev/null 2>&1
s2=\$(snap)
echo "container_delta \$(echo "\$s1 \$s2" | awk '{ print \$5-\$1, \$6-\$2, \$7-\$3, \$8-\$4 }')"
# metadata address: seconds to fail
t0=\$(date +%s.%N)
setpriv --reuid=\$U --regid=\$G --clear-groups timeout 6 bash -c 'exec 3<>/dev/tcp/169.254.169.254/80' 2> /dev/null; r1=\$?
t1=\$(date +%s.%N)
mb0=\$(nft list counter inet tando app_meta 2> /dev/null | sed -n 's/.*packets \([0-9]*\).*/\1/p')
podman exec \$CT sh -c 'nc -w 5 169.254.169.254 80 < /dev/null' > /dev/null 2>&1; r2=\$?
mb1=\$(nft list counter inet tando app_meta 2> /dev/null | sed -n 's/.*packets \([0-9]*\).*/\1/p')
echo "tando_meta_refused \$(( \${mb1:-0} - \${mb0:-0} ))"
t2=\$(date +%s.%N)
echo "metadata_host_uid \$r1 \$(echo "\$t0 \$t1" | awk '{ printf "%.2f", \$2-\$1 }')"
echo "metadata_container \$r2 \$(echo "\$t1 \$t2" | awk '{ printf "%.2f", \$2-\$1 }')"
# the host's loopback through slirp4netns' gateway: Caddy on 80 (or the HTTP port the host uses)
podman exec \$CT sh -c 'nc -w 3 10.0.2.2 80 < /dev/null' > /dev/null 2>&1; echo "host_loopback_via_gateway \$?"
RSCRIPT
[ -s "$W/probe.out" ] || { cat "$W/probe.err" >&2; echo "the probe did not run" >&2; exit 2; }
cat "$W/probe.out"
get() { awk -v k="$1" '$1 == k { $1 = ""; print substr($0, 2) }' "$W/probe.out"; }
ctl=$(get control_host_uid_delta); con=$(get container_delta)
cu=${ctl%% *}
case $cu in ''|*[!0-9]*) cu=0;; esac
[ "$cu" -ge 1 ] || { echo "RESULT: the control did not count (the probe proves nothing: nft, setpriv or the route)" >&2; exit 2; }
[ -z "$(get nc_missing)" ] || { echo "RESULT: the image has no nc" >&2; exit 2; }
set -- $con; uidc=${1:-0} rootc=${2:-0} anyc=${3:-0} cgc=${4:-0}
echo "counters for the container connect: app uid $uidc, root $rootc, anyone $anyc, app slice (cgroup match, the proposed key) $cgc; the host-namespace control counted $ctl"
echo
if [ "$anyc" -lt 1 ]; then
  echo "RESULT: the container's connect never left the host's output hook (no egress at all, or blocked before it): constrained."
  exit 0
elif [ "$uidc" -ge 1 ]; then
  echo "RESULT: the container's packets carry the app's uid: the per-uid rules apply (uid $uidc, root $rootc, any $anyc)."
  exit 0
fi
sr=$(get tando_slice_rules); case $sr in ''|*[!0-9]*) sr=0;; esac
mc=$(get metadata_container); mcode=${mc%% *} msec=${mc#* }
mr=$(get tando_meta_refused); case $mr in ''|*[!0-9]*) mr=0;; esac
if [ "$sr" -ge 1 ] && [ "$cgc" -ge 1 ] && [ "${mcode:-0}" != 0 ] && [ "$mr" -ge 1 ]; then
  echo "RESULT: the container's packets leave as root ($rootc), but tando's rules match the app's slice ($sr rules in chain containers; the slice saw $cgc of $anyc packets) and tando refused the container's connection to the metadata address (counter app_meta +$mr, ${msec}s): constrained."
  exit 0
else
  echo "RESULT: BYPASS. The container's packets left the host as socket owner root ($rootc) or another, never as the app's uid ($uidc of $anyc): the per-uid rules in table inet tando (connection cap, DNS rate, metadata block, loopback ports, and any mail block keyed on the uid) do not see them. A match on the app slice (socket cgroupv2 level 2) saw $cgc of those $anyc packets: that is the fix key."
  exit 1
fi
