#!/bin/bash
# adopt-fw.sh <adopted-app-port> <other-app-port>: run INSIDE a tando app, then inside the adopted app.
# (1) right after `tando adopt apply`, the adopted app's uid has no nftables rule at all
#     (tando-adopt never calls fw_sync): from the adopted app, curl 127.0.0.1:<other-app-port> succeeds;
# (2) the adopted app's own port (e.g. 3100) is outside the rejected set {2019, port_min..port_max+100},
#     so every tando app reaches it directly, bypassing Caddy and forging X-Real-IP.
curl -s -m 3 -H 'X-Real-IP: 6.6.6.6' "http://127.0.0.1:$1/direct" | head -c 300; echo
curl -s -m 3 "http://127.0.0.1:$2/" | head -c 100; echo " (rc=$?)"
