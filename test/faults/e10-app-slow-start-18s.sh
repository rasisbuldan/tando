#!/bin/bash
# e10: release needs 18 s to listen, health_timeout 60 (pre-flight passes; Caddy holds only 15 s after the switch)
EXTRA="health_timeout = 60" exec "$(dirname "$0")/app-fault.sh" e10 slow:18 3
