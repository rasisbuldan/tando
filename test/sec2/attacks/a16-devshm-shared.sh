#!/bin/bash
# A16 (threat 1): /dev/shm is the host's (PrivateDevices=yes keeps the host /dev/shm), shared by every app,
# never cleaned by tando destroy, and uids are reused by the next app. (a) a file left by a destroyed app
# now belongs to another app's user; (b) shmem written by an app leaves its MemoryMax when the unit
# restarts: alpha (MemoryMax 192M) parks 3 x 150 MB of RAM in /dev/shm by crashing between writes.
. "$(dirname "$0")/lib.sh"
echo "== (a) leftovers:"; rootsh 'ls -ln /dev/shm; for f in /dev/shm/*; do echo "$f owner now: $(stat -c %U "$f")"; done'
echo "== (b) memory outside the cap:"
rootsh 'grep Shmem: /proc/meminfo'
for i in 1 2 3; do
  x "head -c 157286400 /dev/zero > /dev/shm/park$i; echo wrote park$i; cat /sys/fs/cgroup/memory.current 2>/dev/null; kill -9 \$PPID" > /dev/null 2>&1
  for j in $(seq 1 20); do [ "$(get alpha /health)" = ok ] && break; sleep 1; done
done
rootsh 'grep Shmem: /proc/meminfo; du -sh /dev/shm; echo "alpha memory.current now: $(cat /sys/fs/cgroup/system.slice/tando-alpha.service/memory.current)"; systemctl show -P MemoryMax tando-alpha'
n=$(rootsh 'du -sm /dev/shm | cut -f1'); rootsh 'rm -f /dev/shm/park*'
case $n in ""|*[!0-9]*) inconclusive "no measurement of /dev/shm (got [$n])";; esac
if [ "$n" -gt 400 ]; then succeeded "$n MB parked in /dev/shm by an app capped at 192 MB"; else blocked "only $n MB"; fi
