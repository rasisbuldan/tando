# shellcheck shell=bash disable=SC2034 # variables are read inside the eval'd check strings
# test/sec2/sec3.sh: sourced by test/e2e-sec2.sh after shell.sh. Regression checks for the third
# security review (test/sec3): the attacks re-run from alpha (the compromised app) against bravo,
# tando and the host. Each id is S3-<n>, the finding's number. bash 3.2.

# 2, 12: the loopback rules name every app port, and app replies to connections from outside drop
FW=$(srv 'sudo nft list table inet tando')
AU=$(srv 'id -u tando-alpha')
check "S3-2 alpha's uid: own ports accepted, the range and 2019 rejected (adopted ports join the list)" \
  eval 'echo "$FW" | grep -q "skuid $AU tcp dport { $AP, $((AP + 100)) } accept" && echo "$FW" | grep -q "skuid $AU tcp dport { 2019, 4100-4299.*} reject"'
check "S3-12a outside connections to an app's sockets get no answer (rule present)" \
  eval 'echo "$FW" | grep -q "oifname != \"lo\" meta skuid $AU ct direction reply drop"'
IP=$(rootsh "hostname -I | cut -d' ' -f1")
if docker image inspect alpine:3.22 > /dev/null 2>&1; then
  # listen() on an unbound socket autobinds 0.0.0.0:<ephemeral> past SocketBindDeny
  x 'rm -f $TANDO_DATA_DIR/ab.port; nohup perl -MSocket -e "\$|=1; socket(S,PF_INET,SOCK_STREAM,0) or die; listen(S,5) or die; my (\$p)=sockaddr_in(getsockname(S)); print qq(\$p\n); accept(C,S); print C qq(AUTOBOUND\n); close C; sleep 1" > $TANDO_DATA_DIR/ab.port 2>&1 < /dev/null & sleep 1' > /dev/null
  abp=$(x 'cat $TANDO_DATA_DIR/ab.port')
  abo=$(docker run --rm alpine:3.22 sh -c "nc -w 4 $IP $abp < /dev/null" 2>&1)
  check "S3-12b alpha's autobound listener (0.0.0.0:$abp) answers nothing from another host (${abo:-nothing})" \
    eval 'case "$abp" in [0-9]*) ! echo "$abo" | grep -q AUTOBOUND;; *) false;; esac'
  x 'pkill -u tando-alpha -f AUTOBOUND; rm -f $TANDO_DATA_DIR/ab.port' > /dev/null
else skip "S3-12b no alpine:3.22 image for an outside client"; fi

# 3, 16: the probe secret and X-Real-IP
srv 'sudo /opt/tando/bin/tando-watch run' > /dev/null 2>&1
check "S3-3a alpha never received X-Tando-Probe (deploys, pre-flight, tando-watch)" \
  eval 'x "test -e \$TANDO_DATA_DIR/probe-seen && cat \$TANDO_DATA_DIR/probe-seen || echo none" | grep -qx none'
check "S3-3b Caddy strips the probe header and sets X-Real-IP for proxied apps" \
  srv 'sudo grep -q "header_up -X-Tando-Probe" /etc/caddy/tando/bravo.caddy && sudo grep -q "header_up X-Real-IP {remote_host}" /etc/caddy/tando/bravo.caddy'

# 4: requests Caddy 2.6 serves but would not log
cu=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: BRAVO.LOCALHOST" "http://127.0.0.1:$HP/s3-case")
printf 'GET /s3-halfclose HTTP/1.1\r\nHost: bravo.localhost\r\n\r\n' | nc -w 3 127.0.0.1 "$HP" > /dev/null 2>&1
sleep 2
rt=$(srv 'sudo /opt/tando/bin/tando-logs req-tail bravo 50')
check "S3-4a a Host in other letters is refused (got $cu), not served unlogged" t_eq "$cu" 400
check "S3-4b a request whose client half-closed is in the log, as aborted" \
  eval 'echo "$rt" | grep -q "aborted.*/s3-halfclose"'

# 5: nft flush ruleset -> tando-watch puts the table back, fires an alert, writes an audit line
fwo=$(srv 'sudo nft flush ruleset; sudo /opt/tando/bin/tando-watch run > /dev/null 2>&1; sudo nft list table inet tando | grep -c skuid; sudo tail -3 /var/log/tando/audit.log | grep -c fw-restore; sudo grep -c "^_host.firewall.st=firing" /var/lib/tando/watch/state')
check "S3-5 after nft flush ruleset the next watch run reloads the rules, alerts and audits ($(echo $fwo))" \
  eval 'set -- $fwo; [ "${1:-0}" -gt 0 ] && [ "${2:-0}" -ge 1 ] && [ "${3:-0}" = 1 ]'

# 6: Caddy's header timeout (this test server's Caddyfile is a stock-like one: tando sets them)
check "S3-6 Caddy has read_header and idle timeouts" srv 'sudo grep -q "read_header 10s" /etc/caddy/Caddyfile'

# 7: HOME is read-only, user config files are not read
o7=$(x 'echo "node-options=--require /x.js" > /opt/tando/apps/alpha/shared/.npmrc; touch $HOME/.npmrc 2>/dev/null && echo HOME-RW; echo "npm=$(HOME=/opt/tando/apps/alpha/shared npm config get node-options 2>&1)"; echo "nus=$PYTHONNOUSERSITE git=$GIT_CONFIG_GLOBAL"; rm -f /opt/tando/apps/alpha/shared/.npmrc')
check "S3-7 an .npmrc implant is not read and HOME is read-only ($(echo $o7))" \
  eval 'echo "$o7" | grep -q "^npm=null$" && ! echo "$o7" | grep -q HOME-RW && echo "$o7" | grep -q "nus=1 git=/dev/null"'

# 8: /proc of other users, and the admin's shell command
o8=$(x 'ls -d /proc/[0-9]* | wc -l; ps -eo user= | sort -u | tr "\n" " "')
check "S3-8a alpha sees only its own processes ($(echo $o8))" eval 'echo "$o8" | tail -1 | grep -qxE "tando-a(lpha|\+) *"'
x 'rm -f $TANDO_DATA_DIR/cl; nohup bash -c "end=\$((SECONDS+12)); while ((SECONDS<end)); do cat /proc/[0-9]*/cmdline 2>/dev/null | tr \"\\0\" \" \" | grep -ao \"S3SECRE[T]4[2]\"; done | sort -u > \$TANDO_DATA_DIR/cl" > /dev/null 2>&1 < /dev/null & sleep 1' > /dev/null
(cd "$W/w/bravo" && "$R" ssh bravo -- 'echo S3SECRET$((40+2)) > /dev/null; sleep 3' < /dev/null > /dev/null 2>&1)
sleep 10
o8=$(x 'cat $TANDO_DATA_DIR/cl; rm -f $TANDO_DATA_DIR/cl')
check "S3-8b alpha cannot read the admin's tando ssh bravo -- <cmd> (${o8:-nothing seen})" eval '! echo "$o8" | grep -q S3SECRET42'
check "S3-8c no command file is left under /run/tando/shell" srv 'test -z "$(sudo ls -A /run/tando/shell 2>/dev/null)"'

# 17: the kernel-facing sandbox
o17=$(x 'unshare -U true 2>&1 | head -1; cat /proc/sys/kernel/hostname 2>&1 | head -1')
sc=$(srv 'sudo systemd-analyze security tando-alpha 2> /dev/null | tail -1 | grep -o "level for [^:]*: [0-9.]*" | sed "s/.*: //"')
check "S3-17 no namespaces, no /proc/sys; exposure ${sc:-?} (was 7.7)" \
  eval 'echo "$o17" | grep -q "Operation not permitted" && [ -n "$sc" ] && [ "${sc%.*}" -lt 5 ]'

# 10: an unreadable file in the data directory no longer blocks the backup (and so the deploy)
x 'echo s > $TANDO_DATA_DIR/locked; chmod 000 $TANDO_DATA_DIR/locked' > /dev/null
(cd "$W/w/alpha" && "$R" backup now) > "$E/s3-10.out" 2>&1; rc10=$?
x 'chmod 600 $TANDO_DATA_DIR/locked; rm -f $TANDO_DATA_DIR/locked' > /dev/null
m10=$(srv 'd=$(sudo ls -t /var/backups/tando/alpha | head -1); sudo cat /var/backups/tando/alpha/$d/meta')
check "S3-10 backup with an unreadable file succeeds, the file named in its meta (rc=$rc10)" \
  eval '[ $rc10 = 0 ] && echo "$m10" | grep -q "^warning=.*locked"'

# 11: tando's lock files are root's alone
o11=$(x 'for f in /opt/tando/.ports.lock /opt/tando/.fw.lock /opt/tando/.host.lock /var/lib/tando/watch/lock /opt/tando/apps/alpha/lock; do [ -e $f ] || continue; flock -n $f true 2>/dev/null && echo "HELD $f"; done; echo done')
check "S3-11 alpha cannot open any tando lock file ($(echo $o11))" eval 'echo "$o11" | grep -qx done && ! echo "$o11" | grep -q HELD'

# 9: an app over app_max_mb raises an alert; at disk_stop_pct (1 here, to trigger it) it is stopped
x 'head -c 70000000 /dev/zero > $TANDO_DATA_DIR/s3fill' > /dev/null
(cd "$W/w/alpha" && "$R" alerts set disk_every=1 alpha.disk_stop_pct=1) > /dev/null 2>&1
srv "sudo /opt/tando/bin/tando-agent setup app_max_mb=60 public_port=$HP" > /dev/null 2>&1
srv 'sudo sed -i "/^du.alpha=/d" /run/tando-watch/vstate; sudo /opt/tando/bin/tando-watch run' > /dev/null 2>&1
o9=$(srv 'sudo grep "^alpha.disk" /var/lib/tando/watch/state; systemctl is-active tando-alpha')
srv 'sudo rm -f /opt/tando/apps/alpha/shared/data/s3fill'
srv "sudo /opt/tando/bin/tando-agent setup app_max_mb=8192 public_port=$HP" > /dev/null 2>&1
(cd "$W/w/alpha" && "$R" alerts set disk_every=10 alpha.disk_stop_pct=95 && "$R" start) > /dev/null 2>&1
check "S3-9 alpha over app_max_mb: disk alert fired and alpha stopped ($(echo $o9 | cut -c1-120))" \
  eval 'echo "$o9" | grep -q "alpha.disk.st=firing" && echo "$o9" | grep -q "was stopped" && echo "$o9" | tail -1 | grep -qv "^active$"'
check "S3-9b alpha runs again after tando start" eval 'get alpha | grep -q "alpha v"'

# 14, 18: alert state root-only; a destroyed app's gids are retired with its uid
check "S3-14 the alert state is root 600" srv 'test "$(sudo stat -c %a /var/lib/tando/watch/state)" = 600'
DL=$W/w/delta; rm -rf "$DL"; cp -R "$W/w/bravo" "$DL"; conf_set "$DL/tando.conf" app delta
(cd "$DL" && "$R" up) > /dev/null 2>&1
g18=$(srv 'getent group tando-delta tando-m-delta | cut -d: -f3 | tr "\n" " "')
(cd "$DL" && echo delta | "$R" destroy --purge) > /dev/null 2>&1
g1=${g18%% *} g2=$(echo $g18 | cut -d' ' -f2)
check "S3-18 a destroyed app's gids are retired with its uid ($g18)" \
  eval '[ -n "$g1" ] && [ "$g1" != "$g2" ] && srv "sudo grep -qx $g1 /opt/tando/retired-uids && sudo grep -qx $g2 /opt/tando/retired-uids"'
