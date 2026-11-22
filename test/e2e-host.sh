#!/bin/bash
# test/e2e-host.sh: host care (srv/hostcare, tando-host, lib/hostcare.sh; docs/HOSTCARE.md) on a
# throwaway test server.
#   H1 host setup installs tando-host, its timer and boot unit; the summary file is root 600 in a
#      root 700 directory, written by rename; doctor and tando ls show host care
#   H2 tando host status at 80 and 120 columns (no line wider), --json is valid JSON
#   H3 findings appear when the condition is made: a listener on 0.0.0.0 (exposed), password
#      login in an sshd drop-in (ssh), /run/reboot-required (reboot), a failed unit (units), a held
#      package (apt's real state); settings through tando alerts set (allow_ports, ssh=off)
#   H4 care on/off: idempotent, apt-config sees security origins only, the needrestart guard;
#      beside a site tando does not manage nothing is enabled and a reboot is refused
#   H5 host update with the needrestart guard (offline: no package source, nothing to install)
#   H6 a reboot refused while a deploy holds an app, saying why
#   H7 host reboot end to end: notice to a test webhook, the reboot (the container exits as a VM
#      would power-cycle; the suite starts it again), ssh back, every app verified, "reboot done"
# The network is used only for packages: host setup's (as every suite's) and unattended-upgrades
# (H4: the image lacks it); then the package sources are moved aside (apt has nothing to fetch). Pending security updates cannot be made offline: their parsing and
# thresholds are unit-tested with captured apt output (srv/hostcare, testdata/). bash 3.2.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-host
srv() { "$SSH" "$@"; }
t_server_up --reset || exit 1
W=$E/w
mkdir -p "$W"
summary() { srv 'sudo cat /var/lib/tando/hostcare/summary'; }
# alert <check>: its state in the summary; finding <id>: its state
alert() { summary | awk -F '\t' -v c="$1" '$1 == "alert" && $2 == c { print $3 }'; }
finding() { summary | awk -F '\t' -v c="$1" '$1 == "finding" && $2 == c { print $4 }'; }
hcheck() { srv 'sudo /opt/tando/bin/tando-host check apt' > /dev/null; }

# ---- fixtures: the notification receiver --------------------------------------------------------
# the docker image turns APT::Periodic off (a server does not): as on a server
srv 'sudo rm -f /etc/apt/apt.conf.d/docker-disable-periodic-update'
cat > "$E/recv.js" <<'EOF'
const http = require('http'), fs = require('fs');
http.createServer((req, res) => {
  let body = '';
  req.on('data', d => body += d);
  req.on('end', () => {
    fs.appendFileSync('/root/recv.log', JSON.stringify({ t: Date.now() / 1000, path: req.url, body }) + '\n', { mode: 0o600 });
    res.writeHead(200); res.end('{"ok":true}');
  });
}).listen(9999, '127.0.0.1');
EOF
srv 'sudo tee /root/recv.js > /dev/null && printf "[Unit]\nDescription=host test receiver\n[Service]\nExecStart=/usr/local/bin/node /root/recv.js\n[Install]\nWantedBy=multi-user.target\n" |
  sudo tee /etc/systemd/system/testrecv.service > /dev/null && sudo systemctl daemon-reload && sudo systemctl enable -q --now testrecv' < "$E/recv.js" ||
  { fail "H0 fixtures"; t_done; }

# ---- H1 setup ----------------------------------------------------------------------------------
t_host_add test
"$R" host setup test public_port="$T_HTTP_PORT" > "$E/setup.out" 2>&1; rc=$?; cat "$E/setup.out" >&2
check "H1a host setup with host care (rc=$rc)" eval '[ $rc = 0 ] && grep -q "care" "$E/setup.out"'
check "H1b tando-host installed, its timer active and boot unit enabled" \
  srv 'test -x /opt/tando/bin/tando-host && systemctl -q is-active tando-host.timer && systemctl -q is-enabled tando-host-boot.service'
printf 'http://127.0.0.1:9999/hook/x\n' | "$R" alerts notifier add hook webhook > /dev/null 2>&1
hcheck
check "H1c the summary is root 600 in a root 700 directory, no temp file beside it" \
  srv 'test "$(sudo stat -c %U:%a /var/lib/tando/hostcare)" = root:700 && test "$(sudo stat -c %U:%a /var/lib/tando/hostcare/summary)" = root:600 &&
       ! sudo ls -a /var/lib/tando/hostcare | grep -q tmp && sudo head -2 /var/lib/tando/hostcare/summary | grep -q "^summary	1	"'
# written by rename: the inode changes on every run (never rewritten in place)
i1=$(srv 'sudo stat -c %i /var/lib/tando/hostcare/summary'); hcheck; i2=$(srv 'sudo stat -c %i /var/lib/tando/hostcare/summary')
check "H1d the summary is replaced whole (inode $i1 -> $i2)" eval '[ -n "$i1" ] && [ "$i1" != "$i2" ]'
# K: the core keeps memory and disk when apps take theirs. MemoryLow drop-ins for Caddy, sshd and
# tandod (live in their cgroups), system.slice gets the sum; group tando-core (Caddy in it) gets the
# ext4 reserved blocks: the function itself, on a loop-mounted ext4 (the container's / is overlayfs)
lows=$(srv 'for u in caddy ssh tandod; do systemctl show -P MemoryLow $u.service; cat /sys/fs/cgroup/system.slice/$u.service/memory.low; done; systemctl show -P MemoryLow system.slice' | tr '\n' ' ')
check "H1k MemoryLow Caddy 64M, sshd 32M, tandod 32M, live in their cgroups; system.slice their sum ($lows)" \
  eval '[ "$lows" = "67108864 67108864 33554432 33554432 33554432 33554432 134217728 " ] && grep -q "128 MB kept for Caddy" "$E/setup.out"'
res=$(srv 'sudo bash -c "truncate -s 32M /root/core.img && mkfs.ext4 -q -F /root/core.img && mkdir -p /mnt/core && mount -o loop /root/core.img /mnt/core &&
  grepq() { grep \"\$@\" > /dev/null; }; eval \"\$(sed -n \"/^core_reserve() {/,/^}/p\" /opt/tando/bin/tando-agent)\"; core_reserve /mnt/core; echo \"res=\$CORE_RES\";
  d=\$(findmnt -no SOURCE /mnt/core); tune2fs -l \$d | grep \"^Reserved blocks gid\"; grep \" /mnt/core \" /proc/mounts; umount /mnt/core; rm -f /root/core.img"' 2>&1)
gid=$(srv 'getent group tando-core | cut -d: -f3')
check "H1l core_reserve gives an ext4's reserved blocks to tando-core (gid $gid), now and from the next mount; caddy is in it ($(echo "$res" | tr '\n' ' ' | cut -c1-200))" \
  eval '[ -n "$gid" ] && echo "$res" | grep -q "^res=/dev/loop[0-9]* reserve: root, PostgreSQL, Caddy" &&
        echo "$res" | grep -q "^Reserved blocks gid: *$gid " && echo "$res" | grep -q "resgid=$gid" &&
        srv "id -nG caddy" | grep -qw tando-core'
alert_rows() { [ "$(summary | grep -c "^alert	")" = 10 ]; }
check "H1e every alert check has a row" alert_rows
"$R" doctor test > "$E/doctor.out" 2>&1
check "H1f tando doctor has a host care row naming tando host status" grep -q "host care.*tando host status" "$E/doctor.out"
check "H1g tando doctor checks tando-host's version" grep -q "^│ host  *.*same as the client\|host .*same as the client" "$E/doctor.out"
# programs that differ from the client's (as after a client upgrade) are ONE row; --verbose lists each
for p in tando-gate tando-logs tando-watch; do srv "printf x | sudo tee -a /opt/tando/bin/$p > /dev/null"; done
"$R" doctor test > "$E/doctor-diff.out" 2>&1
"$R" doctor test --verbose > "$E/doctor-diffv.out" 2>&1
flat=$(tr -d '│\n' < "$E/doctor-diff.out" | tr -s ' ')
one_row() { case $flat in *"programs "*"3 of "*" programs differ from the client"*"tando host setup test"*) return 0;; esac; return 1; }
check "H1j three programs differ: one row \"3 of N programs differ ... tando host setup test\"" \
  one_row
check "H1k ... and no row of their own for gate, logs or watch" eval '! grep -Eq "^│ (gate|logs|watch) " "$E/doctor-diff.out"'
check "H1l ... with --verbose each is listed, with its warning, and there is no collapsed row" \
  eval 'grep -Eq "^│ gate .*warn" "$E/doctor-diffv.out" && grep -Eq "^│ logs .*warn" "$E/doctor-diffv.out" &&
        grep -Eq "^│ watch .*warn" "$E/doctor-diffv.out" && ! grep -Eq "^│ programs " "$E/doctor-diffv.out"'
for p in tando-gate tando-logs tando-watch; do srv "sudo truncate -s -1 /opt/tando/bin/$p"; done
"$R" doctor test > "$E/doctor-same.out" 2>&1
check "H1m restored: no differing programs, no collapsed row" eval '! grep -Eq "^│ programs " "$E/doctor-same.out"'
COLUMNS=100 "$R" ls -H test > "$E/ls.out" 2>&1
check "H1h tando ls shows the server's to-do as one line" grep -q "server: [0-9]* to do" "$E/ls.out"
COLUMNS=100 "$R" host ls > "$E/hls.out" 2>&1
check "H1i tando host ls has a CARE column" eval 'grep -q CARE "$E/hls.out" && grep -q "to do\|ok" "$E/hls.out"'

# ---- H2 the view -------------------------------------------------------------------------------
fits() { [ "$1" -le "$2" ] && grep -q "to do" "$3"; }   # widest columns file
for c in 80 120; do
  COLUMNS=$c "$R" host status test > "$E/st$c.out" 2>&1
  w=$(perl -CSD -ne 'chomp; $m = length if length > $m; END { print $m + 0 }' "$E/st$c.out")
  check "H2a$c host status at $c columns: no line wider (widest $w)" fits "$w" "$c" "$E/st$c.out"
done
cat "$E/st80.out" >&2
check "H2b sections updates, security, health, tando and the to-do list" \
  eval 'for s in updates security health tando "to do"; do grep -q "─ $s" "$E/st80.out" || exit 1; done'
"$R" host status test --json > "$E/st.json" 2> /dev/null
check "H2c --json is valid JSON with findings" \
  eval 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"findings\"] and d[\"machine\"][\"hostname\"]" "$E/st.json"'

# ---- H3 findings -------------------------------------------------------------------------------
srv 'sudo systemd-run -q --unit hctest-listen /usr/local/bin/node -e "require(\"net\").createServer().listen(8765, \"0.0.0.0\")"'
t_until 10 srv 'ss -Hltn "sport = :8765" | grep -q .'
hcheck
check "H3a a listener on 0.0.0.0:8765 is exposed (high priority)" \
  eval '[ "$(finding security.exposed.tcp-8765)" = fail ] && [ "$(alert exposed)" = bad ] && summary | grep "^alert	exposed" | grep -q "	high	"'
"$R" alerts set allow_ports=tcp/8765 > /dev/null 2>&1; hcheck
check "H3b tando alerts set allow_ports=tcp/8765 accepts it" eval '[ "$(alert exposed)" = ok ]'
"$R" alerts set allow_ports= > /dev/null 2>&1
srv 'sudo systemctl stop hctest-listen' > /dev/null 2>&1
srv 'printf "PasswordAuthentication no\nKbdInteractiveAuthentication no\n" | sudo tee /etc/ssh/sshd_config.d/10-hctest.conf > /dev/null'
hcheck; a1=$(alert ssh)
srv 'printf "PasswordAuthentication yes\n" | sudo tee /etc/ssh/sshd_config.d/05-hctest.conf > /dev/null'
hcheck; a2=$(alert ssh)
check "H3c PasswordAuthentication yes in a drop-in: ssh fires, low priority ($a1 -> $a2)" \
  eval '[ "$a1" = ok ] && [ "$a2" = bad ] && summary | grep "^alert	ssh" | grep -q "	low	"'
"$R" alerts set ssh=off > /dev/null 2>&1; hcheck
check "H3d tando alerts set ssh=off turns it off" eval '[ "$(alert ssh)" = off ]'
"$R" alerts set ssh= > /dev/null 2>&1
srv 'sudo rm -f /etc/ssh/sshd_config.d/05-hctest.conf /etc/ssh/sshd_config.d/10-hctest.conf'
srv 'echo "*** System restart required ***" | sudo tee /run/reboot-required > /dev/null && echo linux-image-test | sudo tee /run/reboot-required.pkgs > /dev/null'
hcheck
check "H3e /run/reboot-required: the reboot finding (tando can do it)" \
  eval '[ "$(finding updates.reboot)" = warn ] && summary | grep "^finding	updates.reboot" | grep -q "tando host reboot"'
srv 'sudo systemd-run -q --unit hctest-fail /bin/false' > /dev/null 2>&1
t_until 10 srv 'systemctl -q is-failed hctest-fail'
hcheck
check "H3f a failed unit fires units, named" eval '[ "$(alert units)" = bad ] && summary | grep "^alert	units" | grep -q hctest-fail'
srv 'sudo systemctl reset-failed hctest-fail' > /dev/null 2>&1; hcheck
check "H3g reset: units ok again" eval '[ "$(alert units)" = ok ]'
srv 'sudo apt-mark hold curl' > /dev/null 2>&1; hcheck
check "H3h a held package (real dpkg state) is a finding" eval '[ "$(finding updates.held)" = warn ]'
srv 'sudo apt-mark unhold curl' > /dev/null 2>&1

# ---- H4 care ------------------------------------------------------------------------------------
"$R" host care on test --updates > "$E/care1.out" 2>&1; rc1=$?
"$R" host care on test --updates > "$E/care2.out" 2>&1; rc2=$?
cat "$E/care1.out" "$E/care2.out" >&2
check "H4a care on --updates (rc=$rc1), a second run changes nothing (rc=$rc2)" \
  eval '[ $rc1 = 0 ] && [ $rc2 = 0 ] && grep -q "changed:" "$E/care1.out" && ! grep -q "changed:" "$E/care2.out"'
check "H4b apt-config: unattended-upgrades on, security origins only (tando's #clear works)" \
  srv 'd=$(apt-config dump); echo "$d" | grep -q "Unattended-Upgrade \"1\"" && echo "$d" | grep "Allowed-Origins::" | grep -q -- -security &&
       ! echo "$d" | grep "Allowed-Origins::" | grep -v -- -security | grep -q .'
check "H4c the needrestart guard is on apt-daily-upgrade.service" \
  srv 'systemctl show -p Environment apt-daily-upgrade.service | grep -q NEEDRESTART_SUSPEND=1'
hcheck
check "H4d automatic updates: ok (tando host care)" eval '[ "$(finding updates.auto)" = ok ] && summary | grep "^finding	updates.auto" | grep -q "tando host care"'
"$R" host care off test > "$E/off.out" 2>&1; rc=$?
check "H4e care off removes tando's files (rc=$rc)" \
  srv '! test -e /etc/apt/apt.conf.d/52tando-care && ! test -e /etc/systemd/system/apt-daily-upgrade.service.d/tando-care.conf'
# a site tando does not manage (Caddy is not reloaded: only tando-host reads the file)
srv 'sudo cp /etc/caddy/Caddyfile /root/Caddyfile.hc && printf "other.example {\n\trespond hi\n}\n" | sudo tee -a /etc/caddy/Caddyfile > /dev/null'
"$R" host care on test --reboot --yes > "$E/other.out" 2>&1; rc=$?; cat "$E/other.out" >&2
check "H4f beside another site: care on --reboot refused, saying why (rc=$rc)" eval '[ $rc != 0 ] && grep -q "does not manage" "$E/other.out"'
"$R" host reboot test --now --yes > "$E/other2.out" 2>&1; rc=$?
check "H4g ... and so is a reboot without --even-with-other-sites (rc=$rc)" eval '[ $rc != 0 ] && grep -q "even-with-other-sites" "$E/other2.out"'
srv 'sudo cp /root/Caddyfile.hc /etc/caddy/Caddyfile'

# ---- H5 update ----------------------------------------------------------------------------------
# from here on no package source: apt fetches nothing (the image has no updates to offer offline)
srv 'sudo mkdir -p /root/apt-off && for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do [ -e "$f" ] && sudo mv "$f" /root/apt-off/; done; true'
"$R" host update test --yes > "$E/update.out" 2>&1; rc=$?; cat "$E/update.out" >&2
check "H5a host update (offline: the lists refresh, nothing to install) (rc=$rc)" eval '[ $rc = 0 ] && grep -q "nothing to install" "$E/update.out"'
check "H5b the apt log is root's" srv 'test "$(sudo stat -c %U /var/log/tando-apt.log)" = root'

# ---- H6 a blocked reboot ------------------------------------------------------------------------
cp -R "$ROOT/examples/site" "$ROOT/examples/hello" "$W/"
(cd "$W/site" && "$R" up -H test) > "$E/site.out" 2>&1 || cat "$E/site.out" >&2
(cd "$W/hello" && "$R" up -H test) > "$E/hello.out" 2>&1 || cat "$E/hello.out" >&2
# a new app says where its alerts go: nowhere, when no notifier is set (tando up, lib/deploy.sh)
check "H6p a new app with a notifier registered: up does not say there is none" eval '! grep -q "no notifier set" "$E/hello.out"'
"$R" alerts notifier rm hook > /dev/null 2>&1
cp -R "$W/hello" "$W/third"; sed 's/^app = .*/app = third/' "$W/hello/tando.conf" > "$W/third/tando.conf"
(cd "$W/third" && "$R" up -H test) > "$E/third.out" 2>&1 || cat "$E/third.out" >&2
check "H6q ... with none, up says so and names tando alerts notifier add" \
  grep -q "no notifier set: tando alerts notifier add" "$E/third.out"
printf 'http://127.0.0.1:9999/hook/x\n' | "$R" alerts notifier add hook webhook > /dev/null 2>&1
srv 'sudo sed -i "s/^phase=.*/phase=verify/; t; \$a phase=verify" /opt/tando/apps/site/state'
"$R" host reboot test --now --yes > "$E/blocked.out" 2>&1; rc=$?; cat "$E/blocked.out" >&2
check "H6a a reboot is refused while a deploy runs, saying which (rc=$rc)" eval '[ $rc != 0 ] && grep -q "deploy of site" "$E/blocked.out"'
srv 'sudo sed -i "s/^phase=.*/phase=idle/" /opt/tando/apps/site/state'

# ---- H7 reboot end to end -----------------------------------------------------------------------
srv 'sudo truncate -s0 /root/recv.log'
"$R" host reboot test --now --yes > "$E/reboot.out" 2>&1 &
rpid=$!
# the container exits when systemd reboots (no VM to power-cycle): start it again, as a VM would
t_until 120 eval '[ "$(docker inspect -f "{{.State.Running}}" "$T_NAME" 2> /dev/null)" = false ]' &&
  docker start "$T_NAME" > /dev/null
wait "$rpid"; rc=$?; cat "$E/reboot.out" >&2
check "H7a host reboot: back, every app answers (rc=$rc)" eval '[ $rc = 0 ] && grep -q "every app answers its health check" "$E/reboot.out"'
check "H7b the notice before the reboot reached the webhook" t_until 30 srv 'sudo grep -q "rebooting now" /root/recv.log'
check "H7c \"reboot done, all apps healthy\" reached the webhook" t_until 120 srv 'sudo grep -q "reboot done" /root/recv.log'
check "H7d the audit trail has the reboot and its result" eval '"$R" audit -H test -n 30 2> /dev/null | grep -q host-reboot'
check "H7e the reboot is recorded as proven (care may reboot on its own now)" \
  eval '"$R" host care test 2> /dev/null | grep -q "reboots"'
srv 'sudo /opt/tando/bin/tando-host reboot-result' > "$E/rr.out"
check "H7f reboot-result: done, ok" eval 'grep -q "^state=done" "$E/rr.out" && grep -q "^result=ok" "$E/rr.out"'

# cost: CPU of one hourly check (the cheap pass), as systemd accounts its unit
srv 'sudo systemctl start tando-host.service; systemctl show -P CPUUsageNSec tando-host.service' > "$E/cpu.out"
log "one check run: $(( $(tail -1 "$E/cpu.out" | tr -dc 0-9) / 1000000 )) ms CPU"

srv 'for f in /root/apt-off/*; do [ -e "$f" ] || continue; case $f in *.list|*.sources) sudo mv "$f" /etc/apt/sources.list.d/;; *) sudo mv "$f" /etc/apt/;; esac; done; true'
t_done
