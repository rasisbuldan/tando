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
t_done
