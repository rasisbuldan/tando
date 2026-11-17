#!/bin/bash
# e4-app-crash-after-20s: release healthy, then crashes after 20 s on the live port
exec "$(dirname "$0")/app-fault.sh" e4 crash20@live 2
