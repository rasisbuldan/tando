#!/bin/bash
# e8-app-log-flood: release floods its log (~2 MB/s+) on the live port
exec "$(dirname "$0")/app-fault.sh" e8 logflood@live 3
