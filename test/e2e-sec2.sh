#!/bin/bash
# test/e2e-sec2.sh: the attacks of docs/SECURITY-REVIEW-2.md (test/sec2/attacks, by the reviewer)
# against this tree. Setup as the review had it: app alpha (the attacker: a backdoor that runs
# bash as tando-alpha, and a job every 20 s) and bravo (the victim), with deploy keys. Every
# attack script exits 0 when the attack was blocked: that is a PASS here. Run once more with
# TANDO_TEST_CADDY=ubuntu (Caddy 2.6.2) for the Host-with-port check (a07). The SH checks attack the
# sandboxed app shell (tando ssh <app>) from inside it (test/sec2/shell.sh). bash 3.2 compatible.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init e2e-sec2   # work dir: test/.<suite>-<server>, or $T_WORK (all.sh)
SRC=$ROOT/test/sec2
t_server_up --reset || exit 1

# the review's environment, pointed at this tree, this work dir and this server
cp -R "$SRC/attacks" "$SRC/env.sh" "$SRC/setup.sh" "$SRC/w" "$E/"
sed -e "s#^W=.*#W=$E#" -e "s#^ROOT=.*#ROOT=$ROOT T=$ROOT R=$ROOT/bin/tando#" \
    -e "s#^if \[ \"\$SEC2_B\" = 1 \].*#SP=$T_SSH_PORT HP=$T_HTTP_PORT NAME=$T_NAME CFGD=\$W/cfg#" \
    -e "s#/Users/[^ ]*/test/.work-sec2#$E#g" "$SRC/env.sh" > "$E/env.sh"
for f in "$E/setup.sh" "$E/attacks/lib.sh"; do sed -i.bak "s#/Users/[^ ]*/test/.work-sec2/env.sh#$E/env.sh#" "$f"; rm -f "$f.bak"; done
log "setting up alpha and bravo"
bash "$E/setup.sh" > "$E/setup.log" 2>&1 || { cat "$E/setup.log" >&2; echo "FAIL 0 setup"; t_done; }
# the reviewer's key helpers on the server (a09, a10, f4 upload with alpha's deploy key)
. "$E/env.sh"
srv 'umask 077; cat > ~/ka' < "$KA"
srv "printf '%s\n' '#!/bin/sh' 'while [ \"\$1\" != x ]; do shift; done; shift; c=\$(echo \"\$*\" | sed \"s/ --bwlimit=[0-9]*//\"); exec ssh -F /dev/null -i ~/ka -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -l tando-d-alpha 127.0.0.1 \"\$c\"' > ~/kssh; chmod +x ~/kssh"

# finding -> attack script
for t in "N1 a01-job-port-hijack" "N2 a02-job-preflight-port" "N3 a03-destroy-survivor" \
         "F1 a04-loopback-matrix" "F2 a05-writable-chown-race" "N11 a06-probe-ua-unlogged" \
         "N7 a07-host-port-unlogged" "F3 a08-rx-single-session-writethrough" "N10 a09-disk-amplification" \
         "F6 a10-gate-retests" "N8 a15-journal-namespace-flood" "N9 a16-devshm-shared" \
         "F4 f4-retest-end-kills-admin-upload"; do
  id=${t%% *} s=${t#* }
  perl -e 'alarm shift; exec @ARGV' 600 bash "$E/attacks/$s.sh" > "$E/$s.out" 2>&1; rc=$?
  r=$(sed -n 's/^RESULT: //p' "$E/$s.out" | tail -1)
  case $rc in
    0) pass "$id-$s blocked: ${r#BLOCKED - }";;
    # inconclusive is a failure unless skips are accepted: an attack that could not run proves nothing
    2) if [ "${TANDO_ALLOW_SKIP:-0}" = 1 ]; then skip "$id-$s inconclusive: ${r#INCONCLUSIVE - }"
       else sed 's/^/  /' "$E/$s.out" >&2; fail "$id-$s inconclusive (TANDO_ALLOW_SKIP=1 accepts that): ${r#INCONCLUSIVE - }"; fi;;
    *) sed 's/^/  /' "$E/$s.out" >&2; fail "$id-$s ${r:-exit $rc}";;
  esac
done

# N8: another app's journal namespace cannot be written (its directory is closed)
o=$(x 'logger -u /run/systemd/journal.tando-bravo/dev-log -t forged forged-line 2>&1; echo rc=$?')
check "N8 alpha cannot write into bravo's journal namespace ($(echo "$o" | tr '\n' ' '))" \
  eval 'echo "$o" | grep -q "rc=[1-9]" && ! srv "sudo journalctl --namespace=tando-bravo -o cat --no-pager | grep -q forged-line"'
# N13: a backup never follows the app's symlinked data directory (and runs in the app's sandbox)
x 'cd /opt/tando/apps/alpha/shared && mv data data.real && ln -s /etc data && echo linked' > /dev/null
(cd "$W/w/alpha" && "$R" backup now) > "$E/n13.out" 2>&1; rc=$?
x 'cd /opt/tando/apps/alpha/shared && rm data && mv data.real data' > /dev/null
check "N13 backup of a symlinked data directory is refused (rc=$rc)" \
  eval '[ $rc != 0 ] && grep -q "not a directory of tando-alpha" "$E/n13.out"'
# N9: units get a private, capped /dev/shm and private IPC; uids are never reused
check "N9 alpha's /dev/shm is its own tmpfs" eval 'x "df --output=fstype,size /dev/shm | tail -1" | grep -q "^tmpfs"'
check "N9 a destroyed app's uid is retired" srv 'sudo test -s /opt/tando/retired-uids'
# N11: the probe header is root's alone; site files are not world-readable
check "N11 probe header root 600, site files root:caddy 640" \
  srv 'test "$(sudo stat -c %U:%a /opt/tando/probe.header)" = root:600 && test "$(sudo stat -c %G:%a /etc/caddy/tando/bravo.caddy)" = caddy:640'
# SH: the sandboxed app shell (tando ssh <app>), attacked from inside (test/sec2/shell.sh)
# lint: allow RL03 SRC is this checkout's test/sec2
. "$SRC/shell.sh"
# S3: the third review's attacks (test/sec3), one check per finding
# (not $SRC: shell.sh uses SRC for the exit status of its commands)
# lint: allow RL03 ROOT is this checkout
. "$ROOT/test/sec2/sec3.sh"
# L, J: the upload lease and the job units of similar app names (test/sec2/lease-jobs.sh)
# lint: allow RL03 ROOT is this checkout
. "$ROOT/test/sec2/lease-jobs.sh"

# H: an outside review's findings. Domains of tando.conf get the checks of tando domain add (not
# another app's link, nor its domain's www twin); apps reach neither the cloud metadata address nor
# other apps' metrics; a site whose link and domains differ in TLS gets each its own.
srv "sudo $AG domain-add bravo shop.test off" > "$E/h3.out" 2>&1
HR=TANDO_TEST_RESOLVE=bravo.localhost=127.0.0.1,www.shop.test=127.0.0.1,shop.test=127.0.0.1
cp "$W/w/alpha/tando.conf" "$E/alpha.conf.keep"
conf_set "$W/w/alpha/tando.conf" domain bravo.localhost
(cd "$W/w/alpha" && env "$HR" "$R" deploy) > "$E/h3a.out" 2>&1; rc=$?
check "H3a alpha's tando.conf cannot take bravo's link, domain = bravo.localhost (rc=$rc)" \
  eval '[ $rc != 0 ] && grep -q "under the server.s apps_domain" "$E/h3a.out" &&
        ! srv "sudo grep -q bravo.localhost /etc/caddy/tando/alpha.caddy"'
conf_set "$W/w/alpha/tando.conf" domain www.shop.test
(cd "$W/w/alpha" && env "$HR" "$R" deploy) > "$E/h3b.out" 2>&1; rc=$?
cp "$E/alpha.conf.keep" "$W/w/alpha/tando.conf"
check "H3b nor www.shop.test, whose www twin is bravo's shop.test (rc=$rc)" \
  eval '[ $rc != 0 ] && grep -q "shop.test belongs to bravo" "$E/h3b.out" && get alpha | grep -q "alpha v"'
o=$(XT=10 x 'timeout 5 bash -c "exec 3<>/dev/tcp/169.254.169.254/80" 2>&1; echo rc=$?')
check "H5a alpha cannot reach the cloud metadata address, refused at once ($(echo $o | cut -c1-120))" \
  eval 'echo "$o" | grep -q "refused" && echo "$o" | grep -qx "rc=1"'
srv 'sudo /opt/tando/bin/tando-metrics sample' > /dev/null 2>&1
o=$(x 'ls /var/lib/tando/metrics 2>&1; head -c 60 /var/lib/tando/metrics/bravo.tsv 2>&1; echo end')
check "H5b alpha can neither list nor read the metrics of bravo ($(echo $o | cut -c1-120))" \
  eval 'echo "$o" | grep -q "Permission denied" && ! echo "$o" | grep -qE "^(bravo|alpha|host)\.tsv|^[0-9]{10}" &&
        srv "sudo test -s /var/lib/tando/metrics/bravo.tsv"'
# (last: the host's TLS changes for every app) the link on Caddy's local CA, the domain public
srv "sudo $AG setup tls=internal domain_tls=auto public_port=$HP" > "$E/h3c.out" 2>&1
site=$(srv 'sudo cat /etc/caddy/tando/bravo.caddy')
blk() { echo "$site" | awk -v h="$1 {" '$0 == h { on = 1; next } on && $0 == "}" { exit } on'; }
check "H3c tls=internal, domain_tls=auto: bravo.localhost on tls internal, shop.test in a block without it" \
  eval 'blk bravo.localhost | grep -q "tls internal" && blk shop.test | grep -q "import tando-site-bravo" &&
        ! blk shop.test | grep -q "tls internal"'
srv "sudo $AG setup tls=off public_port=$HP" > /dev/null 2>&1
t_done
