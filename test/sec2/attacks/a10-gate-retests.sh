#!/bin/bash
# A10 (threat 2): re-tests of F6c (parallel receivers), F6 (single-file cap), F7 (file names into history /
# activation), F8 (root mode from a process that is not the key's ssh session), F10 (client locale),
# plus option smuggling. Prints one line per sub-test; exit 0 only when every sub-test held.
. "$(dirname "$0")/lib.sh"
srv 'cat > ~/a10.sh' <<'R'
set -u
Kc() { local c=$1; shift; ssh -F /dev/null -i ~/ka -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$@" tando-d-alpha@127.0.0.1 "$c"; }
G=/opt/tando/bin/tando-agent GT=/opt/tando/bin/tando-gate
sudo $G unlock alpha > /dev/null 2>&1
tok=$(Kc "sudo -n $G begin alpha x" | sed -n "s/^token=//p")
# F6c: two receivers under one lease
mkdir -p ~/slow; [ -f ~/slow/r.bin ] || head -c 20000000 /dev/urandom > ~/slow/r.bin
printf '#!/bin/sh\nwhile [ "$1" != x ]; do shift; done; shift; c=$(echo "$*" | sed "s/ --bwlimit=[0-9]*//"); exec ssh -F /dev/null -i ~/ka -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -l tando-d-alpha 127.0.0.1 "$c"\n' > ~/kssh2; chmod +x ~/kssh2
rsync -r --bwlimit=2000 -e ~/kssh2 ~/slow/ x:/opt/tando/apps/alpha/incoming/ > /dev/null 2>&1 & p=$!; sleep 2
o=$(rsync -r -e ~/kssh2 ~/slow/ x:/opt/tando/apps/alpha/incoming/ 2>&1 | grep tando-gate)
echo "F6c second receiver: ${o:-ACCEPTED}"; echo "F6c receivers running: $(pgrep -u tando-d-alpha -c -x rsync)"
kill $p 2>/dev/null; wait 2>/dev/null; sleep 1
# F6: one sparse file over the 1 GiB cap
rm -rf ~/sp; mkdir ~/sp; truncate -s 1100M ~/sp/s.bin
o=$(rsync -r -e ~/kssh2 ~/sp/ x:/opt/tando/apps/alpha/incoming/ 2>&1 | grep -iE 'error|limit|stopped|File too large' | head -1)
echo "F6 1100 MiB sparse file: ${o:-ACCEPTED} ($(sudo du -b --apparent-size /opt/tando/apps/alpha/incoming 2>/dev/null | tail -1 | cut -f1) bytes in incoming)"
sudo rm -f /opt/tando/apps/alpha/incoming/s.bin /opt/tando/apps/alpha/incoming/.s.bin.* /opt/tando/apps/alpha/incoming/r.bin
# F7: file name with newline, C1 controls and a forged row
rm -rf ~/fi; mkdir ~/fi; sudo cp /opt/tando/apps/alpha/current/server.js ~/fi/; sudo chown -R vmadmin ~/fi; echo 9 > ~/fi/VERSION
n=$(printf ".env\xc2\x9b2J\xc2\x9d0;tando: all good\xc2\x9c\x1b[31m\n1794590000\t20261113-999999\tdeploy\tok")
echo x > ~/fi/"$n"
rsync -rlpt --delete -e ~/kssh2 ~/fi/ x:/opt/tando/apps/alpha/incoming/ > /dev/null 2>&1
id=$(echo "$tok" | Kc "sudo -n $G activate alpha 0 0" | sed -n "s/^id=//p"); sleep 3
echo "F7 history row: $(sudo tail -1 /opt/tando/apps/alpha/history.tsv | cat -v | cut -c1-160)"
echo "F7 forged history rows (a line of its own): $(sudo grep -c '^1794590000' /opt/tando/apps/alpha/history.tsv)"
echo "F7 deploy-status message: $(Kc "$G deploy-status alpha $id" | grep ^message | cat -v)"
# F8: a process of the deploy user that is not the key's ssh session asks root mode for a lease
kid=$(sudo cut -f1 /opt/tando/ci/alpha/keys | head -1)
o=$(sudo -u tando-d-alpha bash -c "printf 'keyid=$kid\n' | sudo -n $GT root alpha begin" 2>&1 | head -1)
echo "F8 root mode from a non-session process: $o"
o=$(sudo -u tando-d-alpha cat /opt/tando/ci/alpha/.ssh/authorized_keys 2>&1 | head -1 | cut -c1-80); echo "F8 deploy user reads its key ids: $o"
# F10: client locale
o=$(env LC_ALL=/opt/tando/apps/alpha/incoming/x LANG=/x ssh -F /dev/null -i ~/ka -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o SendEnv=LC_ALL -o SendEnv=LANG tando-d-alpha@127.0.0.1 "$G status alpha" 2>&1 | grep -i setlocale | head -1); echo "F10 client LC_ALL: ${o:-ignored}"
# smuggling: shell, sftp, -e, --sender, other app, extra args
for c in "sh" "rsync --server --sender -r . /opt/tando/apps/alpha/incoming/" "rsync --server -r -e.L . /opt/tando/apps/alpha/incoming/" \
  "rsync --server -r . /opt/tando/apps/bravo/incoming/" "rsync --server -r --info=all . /opt/tando/apps/alpha/incoming/" \
  "$G status bravo" "$G env-ls alpha" "$G deploy-status alpha 1;id" "sudo -n $GT root alpha receive" "$G logs alpha"; do
  o=$(Kc "$c" < /dev/null 2>&1 | head -1); echo "smuggle [$c]: $o"
done
o=$(sftp -F /dev/null -i ~/ka -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR tando-d-alpha@127.0.0.1 <<< ls 2>&1 | head -1); echo "smuggle [sftp]: $o"
sudo $G unlock alpha > /dev/null 2>&1
R
out=$(srv 'bash ~/a10.sh' 2>&1); echo "$out"
bad=0
echo "$out" | grep -q 'F6c second receiver: ACCEPTED' && bad=1
echo "$out" | grep -q 'F6 1100 MiB sparse file: ACCEPTED' && bad=1
echo "$out" | grep -q 'F7 forged history rows (a line of its own): [1-9]' && bad=1
echo "$out" | grep -q $'\xc2\x9b' && bad=1
echo "$out" | grep -q '^F8 root mode.*token=' && bad=1
echo "$out" | grep -q 'F10 client LC_ALL: .*setlocale' && bad=1
echo "$out" | grep -E '^smuggle' | grep -vqE 'tando-gate|Permission denied|Connection closed|subsystem request failed|not allowed' && bad=1
# every sub-test must have reported (an empty or cut-short run is not "held")
for t in 'F6c second receiver:' 'F6 1100 MiB sparse file:' 'F7 forged history rows' 'F8 root mode' 'F10 client LC_ALL:' 'smuggle \[sftp\]:'; do
  echo "$out" | grep -q "^$t" || inconclusive "sub-test '$t' did not report"
done
[ "$(echo "$out" | grep -c '^smuggle')" = 11 ] || inconclusive "not every smuggling attempt reported"
if [ $bad = 0 ]; then blocked "every sub-test held"; else succeeded "a sub-test failed (see above)"; fi
