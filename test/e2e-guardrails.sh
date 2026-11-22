#!/bin/bash
# Guardrails for a shared server (docs/COMMANDS.md "Profiles and guardrails"): limit profiles
# (ceilings, mandatory CPU/task/job limits, no workers), outbound mail closed per app, the outbound
# connection rate, per-uid byte counters and their metrics columns, egress_ip (SNAT) and bind_ip
# (the site on one address), the awake governor (awake_max, wake_rate) against a crawler that
# walks the idle apps, and a container app's packets matched by its slice (they leave as root).
#
#   test/e2e-guardrails.sh [--reset]     --reset: recreate the server first (only one this suite owns)
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT. About 6 minutes (the
# container part builds examples/container with docker or podman on this machine and installs
# Podman on the server; without either it SKIPs). Output: PASS/FAIL/SKIP lines (docs/TESTING.md).
# shellcheck disable=SC2034  # these variables are read inside the eval'd check strings
set -u
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init guardrails
W=$E/w
AG=/opt/tando/bin/tando-agent

if [ "${1:-}" = --reset ]; then t_server_up --reset || exit 1; else t_server_up || exit 1; fi
t_host_add test
srv() { "$SSH" "$@" 2> /dev/null; }
P='memory=128M,cpu=20%,tasks=200,workers=0,job_timeout=60,job_every=10m,mail_out=off'
"$R" host setup test public_port="$T_HTTP_PORT" "profile.small=$P" conn_rate_out=5 awake_max=2 wake_rate=4 > "$E/setup.out" 2>&1; rc=$?
cat "$E/setup.out" >&2
check "G0 host setup takes a profile, conn_rate_out, awake_max and wake_rate" eval '[ $rc = 0 ] && srv "grep -qx \"profile.small=$P\" /opt/tando/host.conf"'
check "G0b a bad profile is refused, naming the key" eval '! "$R" host setup test "profile.x=memory=1G,disk=2G" > "$E/bad.out" 2>&1 && grep -q "unknown key disk" "$E/bad.out"'

mk() { # app tando.conf-lines...: a copy of examples/hello
  local a=$1; shift
  rm -rf "${W:?}/$a"; mkdir -p "$W"; cp -R "$ROOT/examples/hello" "$W/$a"
  printf 'app = %s\n' "$a" >> "$W/$a/tando.conf"
  for l; do printf '%s\n' "$l" >> "$W/$a/tando.conf"; done
}
up() { (cd "$W/$1" && "$R" up --yes > "$E/up-$1.log" 2>&1); }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 40 "$(t_url "$1")"; }

# ---- profiles --------------------------------------------------------------------------------
mk gp 'profile = small' 'memory = 256M'
up gp; rc=$?
check "G1 over the profile's memory: refused, saying which limit" eval '[ $rc != 0 ] && grep -q "memory = 256M is over 128M" "$E/up-gp.log"'
mk gp 'profile = small' 'memory = 128M' 'worker.q = node server.js'
up gp; rc=$?
check "G2 a worker where the profile allows none: refused" eval '[ $rc != 0 ] && grep -q "1 workers, the profile allows 0" "$E/up-gp.log"'
mk gp 'profile = small' 'memory = 128M' 'job.often = */1 * * * * | true'
up gp; rc=$?
check "G3 a job more often than job_every: refused" eval '[ $rc != 0 ] && grep -q "often runs every 60s, more often than every 600s" "$E/up-gp.log"'
mk gp 'profile = small' 'memory = 128M' 'job.nightly = 0 3 * * * | true'
up gp; rc=$?
check "G4 within the profile it deploys and answers" eval '[ $rc = 0 ] && [ "$(code gp)" = 200 ]'
sl=$(srv 'systemctl cat tando-gp.slice')
check "G5 the slice (web, workers, jobs) gets the profile's CPU and task limits" eval 'echo "$sl" | grep -qx "CPUQuota=20%" && echo "$sl" | grep -qx "TasksMax=200"'
check "G6 the job's timeout is the profile's ceiling" eval 'srv "systemctl cat tando-gp_job-nightly.service" | grep -qx "TimeoutStartSec=60"'
check "G7 the app's row (inventory) names its profile" eval 'srv "sudo $AG status gp" | grep "^app" | awk -F"\t" "{ print \$NF }" | grep -qx small'
mk gp 'profile = small' 'memory = 128M' 'cpu = 50%'
up gp; rc=$?
check "G8 a cpu over the profile's is refused" eval '[ $rc != 0 ] && grep -q "cpu = 50% is over 20%" "$E/up-gp.log"'

# ---- outbound: mail, connection rate, bytes ---------------------------------------------------
mk gq
up gq; rc=$?
check "G9 an app without a profile deploys" eval '[ $rc = 0 ] && [ "$(code gq)" = 200 ]'
cnt() { srv "sudo nft list counter inet tando $1" | sed -n 's/.*packets \([0-9]*\).*/\1/p'; }
as() { # app command: run a bash command as the app's user
  srv "sudo setpriv --reuid=tando-$1 --regid=tando-$1 --clear-groups timeout 4 bash -c '$2'"
}
m0=$(cnt app_mail)
t0=$SECONDS; as gp 'exec 3<>/dev/tcp/192.0.2.1/587'; rmail=$?; dt=$((SECONDS - t0))
m1=$(cnt app_mail)
check "G10 mail_out off (from the profile): a connection to port 587 is refused at once ($m0 -> $m1, ${dt}s)" eval '[ $rmail != 0 ] && [ "$m1" -gt "$m0" ] && [ $dt -lt 3 ]'
check "G11 the mail rule covers 25, 465, 587, 2525 in the inet table (IPv4 and IPv6)" eval 'srv "sudo nft list chain inet tando output" | grep -q "meta skuid $(srv "id -u tando-gp") tcp dport { 25, 465, 587, 2525 }"'
as gq 'exec 3<>/dev/tcp/192.0.2.1/587' > /dev/null 2>&1
check "G12 another app without mail_out off is not blocked by it" eval '[ "$(cnt app_mail)" = "$m1" ]'
r0=$(cnt app_rate)
as gq 'for i in $(seq 40); do (exec 3<>/dev/tcp/192.0.2.1/80) 2> /dev/null & done; wait' > /dev/null 2>&1
r1=$(cnt app_rate)
check "G13 over conn_rate_out new connections a second are refused ($r0 -> $r1)" eval '[ "$r1" -gt "$r0" ]'
gw=$(srv "ip route | awk '/^default/ { print \$3; exit }'")
uq=$(srv "id -u tando-gq")
as gq "exec 3<>/dev/tcp/$gw/1" > /dev/null 2>&1
bytes() { srv "sudo nft list counter inet tando $1" | sed -n 's/.*bytes \([0-9]*\).*/\1/p'; }
check "G14 the app's uid's bytes out and back are counted (out_$uq $(bytes "out_$uq"), in_$uq $(bytes "in_$uq"))" \
  eval '[ "$(bytes "out_$uq")" -gt 0 ] && [ "$(bytes "in_$uq")" -gt 0 ]'
srv 'sudo /opt/tando/bin/tando-metrics sample' > /dev/null; sleep 1
as gq "exec 3<>/dev/tcp/$gw/1" > /dev/null 2>&1
srv 'sudo /opt/tando/bin/tando-metrics sample' > /dev/null
line=$(srv 'sudo tail -1 /var/lib/tando/metrics/gq.tsv')
check "G15 tando-metrics writes the bytes as columns 11 and 12 ($line)" eval 'echo "$line" | awk -F"\t" "NF == 12 && \$11 ~ /^[0-9]+\$/ && \$11 > 0 { ok = 1 } END { exit !ok }"'

# ---- the app's own addresses ----------------------------------------------------------------
dev=$(srv "ip route | awk '/^default/ { print \$5; exit }'")
main=$(srv "ip route get 192.0.2.1 | sed -n 's/.* src \([^ ]*\).*/\1/p'")
extra=${main%.*}.250
srv "sudo ip addr add $extra/32 dev $dev" > /dev/null
mk ge "egress_ip = 198.51.100.7"
up ge; rc=$?
check "G16 egress_ip that is not the server's: refused, listing its addresses" eval '[ $rc != 0 ] && grep -q "is not an address of this server" "$E/up-ge.log"'
mk ge "egress_ip = $extra"
up ge; rc=$?
ue=$(srv "id -u tando-ge")
check "G17 egress_ip: the app's uid's outbound connections are SNATed to it" eval '[ $rc = 0 ] && srv "sudo nft list chain inet tando egress" | grep -q "meta skuid $ue meta nfproto ipv4 counter packets [0-9]* bytes [0-9]* snat ip to $extra"'
as ge "exec 3<>/dev/tcp/$gw/1" > /dev/null 2>&1
check "G18 and the rule matched its connection" eval 'srv "sudo nft list chain inet tando egress" | grep "skuid $ue" | grep -Eq "packets [1-9]"'
mk gb "bind_ip = $main"
up gb; rc=$?
check "G19 bind_ip on the server's main address (every other site's) is refused" eval '[ $rc != 0 ] && grep -q "main address" "$E/up-gb.log"'
mk gb "bind_ip = $extra"
up gb; rc=$?
inside() { srv "curl -s --max-time 5 -H 'Host: $1.localhost' http://$2/"; }
check "G20 bind_ip: the site answers on that address" eval '[ $rc = 0 ] && inside gb "$extra" | grep -q hello'
check "G21 and not on the others" eval '! inside gb 127.0.0.1 | grep -q hello'
check "G22 the other sites still answer on the server's addresses" eval '[ "$(code gq)" = 200 ] && inside gq 127.0.0.1 | grep -q hello'

# ---- the awake governor: a crawler that walks the idle apps ----------------------------------
for a in gi1 gi2 gi3; do mk "$a" 'idle_stop = 10m'; up "$a" || fail "G23 deploy $a"; done
stopped() { [ "$(srv "systemctl show -P ActiveState tando-$1.service")" = inactive ]; }
for a in gi1 gi2 gi3; do srv "sudo systemctl stop tando-${a}_wake.service tando-$a.service" > /dev/null; done
t_until 20 eval 'stopped gi1 && stopped gi2 && stopped gi3' > /dev/null
srv 'sudo rm -f /run/tando-wake/*.wakes /run/tando-wake/*.cool /run/tando-wake/.full' > /dev/null
crawl=""; for a in gi1 gi2 gi3; do crawl="$crawl$a=$(code "$a") "; done
check "G23 a crawler over 3 idle apps with awake_max=2: two wake, the third gets 503 ($crawl)" \
  eval '[ "$crawl" = "gi1=200 gi2=200 gi3=503 " ]'
check "G24 the 503 says try again later (Retry-After)" eval 'curl -s -D - -o /dev/null --max-time 10 "$(t_url gi3)" | grep -qi "^Retry-After: 60"'
check "G25 the third was not started" stopped gi3
# a minute later the first two have no open connection: the next wake stops the one woken first
srv 'sudo /opt/tando/bin/tando-agent wake-check' > /dev/null
t_until 200 eval '[ "$(code gi3)" = 200 ]' > /dev/null; r=$?
check "G26 once an awake app is quiet (no connection, awake over 60 s) a new wake takes its place" eval '[ $r = 0 ] && t_until 20 stopped gi1'
# wake_rate=4: the fifth wake of one app within a minute is refused for a minute
srv 'sudo rm -f /run/tando-wake/*.wakes' > /dev/null
rates=""; for i in 1 2 3 4 5; do
  srv "sudo systemctl stop tando-gi2_wake.service tando-gi2.service" > /dev/null; t_until 15 stopped gi2 > /dev/null
  rates="$rates$(code gi2) "
done
check "G27 an app woken more than wake_rate times a minute answers 503 while cooling ($rates)" eval 'case "$rates" in *503*) true;; *) false;; esac'

# ---- container apps: matched by their slice ---------------------------------------------------
if command -v docker > /dev/null 2>&1 || command -v podman > /dev/null 2>&1; then
  "$R" host setup test public_port="$T_HTTP_PORT" podman=yes > "$E/setup-podman.out" 2>&1 || skip "G28 podman could not be installed (network?)"
  rm -rf "${W:?}/gc"; cp -R "$ROOT/examples/container" "$W/gc"
  sed -i.bak 's/^app = .*/app = gc/' "$W/gc/tando.conf"; rm -f "$W/gc/tando.conf.bak"
  printf 'mail_out = off\n' >> "$W/gc/tando.conf"
  up gc; rc=$?
  port=$(srv "sudo sed -n 's/^port=//p' /opt/tando/apps/gc/app.conf")
  check "G28 a container app's slice has its rules (chain containers)" eval '[ $rc = 0 ] && srv "sudo nft list chain inet tando containers" | grep -q "socket cgroupv2 level 2 \"tando.slice/tando-gc.slice\" tcp dport { 25, 465, 587, 2525 }"'
  m0=$(cnt app_mail)
  srv "sudo podman exec tando-gc-$port sh -c 'nc -w 4 192.0.2.1 25 < /dev/null'" > /dev/null
  m1=$(cnt app_mail)
  check "G29 a connection from inside the container is refused by the app's mail rule ($m0 -> $m1)" eval '[ "$m1" -gt "$m0" ]'
  x0=$(cnt app_meta)
  t0=$SECONDS; srv "sudo podman exec tando-gc-$port sh -c 'nc -w 5 169.254.169.254 80 < /dev/null'" > /dev/null; dt=$((SECONDS - t0))
  check "G30 the metadata address is refused from inside the container ($x0 -> $(cnt app_meta), ${dt}s)" eval '[ "$(cnt app_meta)" -gt "$x0" ] && [ $dt -lt 5 ]'
  srv "sudo systemctl restart tando-gc.service" > /dev/null
  m0=$(cnt app_mail)
  t_until 30 eval 'srv "sudo podman exec tando-gc-$port true"' > /dev/null
  srv "sudo podman exec tando-gc-$port sh -c 'nc -w 4 192.0.2.1 25 < /dev/null'" > /dev/null
  check "G31 after a restart of the app (a new slice id) its rules still match" eval '[ "$(cnt app_mail)" -gt "$m0" ]'
else
  skip "G28 container apps: no docker or podman here to build examples/container"
fi

for a in gp gq ge gb gi1 gi2 gi3 gc; do "$R" destroy -a "$a" -H test --purge --yes > /dev/null 2>&1; done
srv "sudo ip addr del $extra/32 dev $dev" > /dev/null
t_done
