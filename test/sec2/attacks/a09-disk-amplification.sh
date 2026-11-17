#!/bin/bash
# A09 (threat 2, F6 re-test): upload limits are on apparent bytes in incoming/ (3 GB, 1 GB per file), but
# incoming/ persists and every activation copies it into releases/<id>, and failed releases are kept
# (KEEP=5 newest). Compressible, non-sparse data costs ~1/1000 on the wire. Here: one 1000 MiB file of 'A'.
. "$(dirname "$0")/lib.sh"
srv 'cat > ~/a09.sh' <<'R'
set -u
K() { ssh -F /dev/null -i ~/ka -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR tando-d-alpha@127.0.0.1 "$@"; }
G=/opt/tando/bin/tando-agent
sudo $G unlock alpha > /dev/null 2>&1
mkdir -p ~/amp; [ -f ~/amp/a.bin ] || head -c 1048576000 /dev/zero | tr '\0' A > ~/amp/a.bin
u0=$(df -k --output=used / | tail -1)
for i in 1 2; do
  tok=$(K "sudo -n $G begin alpha x" | sed -n "s/^token=//p")
  touch ~/amp/v$i
  rsync -rz --stats -e ~/kssh ~/amp/ x:/opt/tando/apps/alpha/incoming/ 2>&1 | grep -E "Total bytes sent" | sed "s/^/  deploy $i: /"
  id=$(echo "$tok" | K "sudo -n $G activate alpha 0 0" | sed -n 's/^id=//p'); echo "  release $id"
  for j in $(seq 1 60); do K "$G deploy-status alpha $id" 2>/dev/null | grep -q '^phase=done' && break; sleep 1; done
done
u1=$(df -k --output=used / | tail -1)
echo "disk used grew by $(( (u1 - u0) / 1024 )) MiB"
sudo du -sh /opt/tando/apps/alpha/incoming /opt/tando/apps/alpha/releases
R
out=$(srv 'bash ~/a09.sh' 2>&1); echo "$out"
# du (allocated blocks) is what an ext4 VPS pays; this test VM's btrfs compresses and reflinks, so df grows less
g=$(echo "$out" | awk '/G\t\/opt\/tando\/apps\/alpha\/(incoming|releases)$/ { s += $1 } END { print int(s) }')
[ "${g:-0}" -ge 3 ] && succeeded "${g} GB allocated (du) for ~32 KB on the wire; each further deploy adds a copy (5 kept)"
blocked "allocated ${g:-?} GB"
