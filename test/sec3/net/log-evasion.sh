#!/bin/bash
# log-evasion.sh <http port> <app> : three ways an outside client reaches an app without a row in
# `tando requests` on Caddy 2.6.2: (1) Host in another letter case, (2) request + half-close of the
# client's write side (logged with status 0, which tando-logs drops as unparsed). Compare
# `sudo /opt/tando/bin/tando-logs req-tail <app> 20` before and after.
P=$1 A=$2
curl -s -o /dev/null -w 'case: %{http_code}\n' -H "Host: $(echo "$A" | tr a-z A-Z).LOCALHOST" "http://127.0.0.1:$P/evade-by-case"
printf 'GET /evade-by-halfclose HTTP/1.1\r\nHost: %s.localhost\r\n\r\n' "$A" | nc -w 3 127.0.0.1 "$P" | head -1
curl -s -o /dev/null -w 'control: %{http_code}\n' -H "Host: $A.localhost" "http://127.0.0.1:$P/control"
