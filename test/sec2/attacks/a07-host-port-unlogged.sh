#!/bin/bash
# A07 (threat 5, unauthenticated): Caddy's per-site request log maps loggers by the exact Host. On Caddy
# 2.6.2 (the real target's version) a Host header that carries a port ("bravo.example.com:443") still
# reaches the site but matches no logger name, and skip_unmapped_hosts drops the log line: any remote
# client can use the app without appearing in its request log (tando requests, alerts' statistics).
# Run with SEC2_B=1 (Caddy 2.6.2); without it, the same against upstream Caddy as a control.
. "$(dirname "$0")/lib.sh"
log() { rootsh 'wc -l < /var/log/tando/bravo/access.log'; }
n0=$(log)
a=$(curl -s -H 'Host: bravo.localhost' "http://127.0.0.1:$HP/plain-$RANDOM"); sleep 1; n1=$(log)
b=$(curl -s -H 'Host: bravo.localhost:443' "http://127.0.0.1:$HP/attack-$RANDOM"); sleep 1; n2=$(log)
echo "caddy $(rootsh 'caddy version' | cut -d' ' -f1)"
echo "plain Host:       answer [$a], log lines $n0 -> $n1"
echo "Host with :443:   answer [$b], log lines $n1 -> $n2"
[ "$n1" -gt "$n0" ] || inconclusive "normal requests are not logged either"
[ -n "$b" ] && [ "$n2" -eq "$n1" ] && succeeded "served but not logged"
blocked "logged"
