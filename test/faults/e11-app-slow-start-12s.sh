#!/bin/bash
# e11-app-slow-start-12s: release needs 12 s to listen
exec "$(dirname "$0")/app-fault.sh" e11 slow:12 3
