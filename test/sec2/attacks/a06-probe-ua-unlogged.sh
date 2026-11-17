#!/bin/bash
# A06 (threat 5): the request log's skip_log rule is "User-Agent tando-probe AND remote_ip 127.0.0.1/::1".
# (a) a remote client with that UA and X-Forwarded-For: 127.0.0.1 must be logged;
# (b) any local process (a compromised app) can send requests to ANOTHER app through Caddy with that UA and
#     leave no trace in that app's request log. Run with SEC2_B=1 for Caddy 2.6.2.
. "$(dirname "$0")/lib.sh"
log() { rootsh 'wc -l < /var/log/tando/bravo/access.log'; }
n0=$(log)
curl -s -o /dev/null -A tando-probe -H 'X-Forwarded-For: 127.0.0.1' -H 'X-Real-IP: 127.0.0.1' -H 'Host: bravo.localhost' "http://127.0.0.1:$HP/remote-spoof-$RANDOM"
sleep 1; n1=$(log); echo "(a) remote request with UA tando-probe + XFF 127.0.0.1: log lines $n0 -> $n1"
x 'for i in 1 2 3; do curl -s -o /dev/null -A tando-probe -H "Host: bravo.localhost" "http://127.0.0.1/admin/login?try=$i"; done; echo sent'
sleep 1; n2=$(log); echo "(b) 3 requests from alpha's process to bravo with UA tando-probe: log lines $n1 -> $n2"
rootsh 'caddy version'
[ "$n1" -gt "$n0" ] || succeeded "a remote client evaded the request log"
[ "$n2" -eq "$n1" ] && succeeded "alpha's requests to bravo through Caddy are not logged (remote spoof was logged)"
blocked "both logged"
