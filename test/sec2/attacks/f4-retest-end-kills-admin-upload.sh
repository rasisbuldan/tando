#!/bin/bash
# F4 re-test: during the admin's own upload (confined receiver tando-rx-alpha, as tando-d-alpha), the key
# sends end (wrong token), begin, and a receive: none may stop or join the admin's upload.
. "$(dirname "$0")/lib.sh"
srv 'cat > ~/f4.sh' <<'R'
set -u
K() { ssh -F /dev/null -i ~/ka -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR tando-d-alpha@127.0.0.1 "$@"; }
G=/opt/tando/bin/tando-agent
printf '#!/bin/sh\nshift; c=$(echo "$*" | sed "s/ --bwlimit=[0-9]*//"); exec sh -c "$c"\n' > ~/local-e; chmod +x ~/local-e
sudo $G unlock alpha > /dev/null 2>&1
[ -f ~/big/big.bin ] || { mkdir -p ~/big; head -c 30000000 /dev/urandom > ~/big/big.bin; }
tok=$(sudo -n $G begin alpha admin@laptop | sed -n 's/^token=//p'); echo "admin lease: $tok"
( rsync -rlptz -c --delete --bwlimit=3000 --rsync-path="sudo -n /opt/tando/bin/tando-gate admin receive alpha rsync" -e ~/local-e ~/big/ x:/opt/tando/apps/alpha/incoming/; echo "admin rsync exit status: $?" ) &
sleep 3; echo "admin receiver: $(systemctl is-active tando-rx-alpha.service)"
echo "== key: end with a wrong token"; echo 00000000-0000-0000-0000-000000000000 | K "sudo -n $G end alpha" 2>&1
echo "== key: begin"; K "sudo -n $G begin alpha x" 2>&1
echo "== key: its own rsync into the admin's lease"; rsync -r -e ~/kssh ~/big/ x:/opt/tando/apps/alpha/incoming/ 2>&1 | grep -v ^remote: | head -2
echo "admin receiver after: $(systemctl is-active tando-rx-alpha.service)"
wait; sudo -n $G end alpha "$tok" > /dev/null
R
out=$(srv 'bash ~/f4.sh' 2>&1); echo "$out"
echo "$out" | grep -q 'admin rsync exit status: [0-9]' || inconclusive "the admin's upload did not report its exit status"
if echo "$out" | grep -q 'admin rsync exit status: 0$'; then blocked "the admin's upload completed"; else succeeded "the admin's upload was cut"; fi
