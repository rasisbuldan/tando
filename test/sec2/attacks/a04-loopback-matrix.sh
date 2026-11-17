#!/bin/bash
# A04 (threats 1+5): from alpha's unit, reach bravo's port and pre-flight port over 127.0.0.1, ::1,
# 127.0.0.2, the container's own address; Caddy's admin API on 2019 and its unix socket. Exit 0 if all refused.
. "$(dirname "$0")/lib.sh"
ip=$(rootsh "hostname -I | cut -d' ' -f1")
out=$(x "for t in 127.0.0.1:4101 '[::1]:4101' $ip:4101 127.0.0.2:4101 127.0.0.1:4201 127.0.0.1:2019; do
  printf '%s %s\n' \$t \"\$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://\$t/)\"; done
printf 'unix:/run/caddy/admin.sock %s\n' \"\$(curl -s -m 2 -o /dev/null -w '%{http_code}' --unix-socket /run/caddy/admin.sock http://x/config/)\"")
echo "$out"
# 7 targets, each with a 3-digit status (000 = refused); anything else means the probe did not run
[ "$(echo "$out" | grep -cE ' [0-9]{3}$')" = 7 ] || inconclusive "the probe did not report all 7 targets"
if echo "$out" | grep -qv ' 000$'; then succeeded "something answered"; else blocked "every target refused"; fi
