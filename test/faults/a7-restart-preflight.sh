#!/bin/bash
# a7: restart during preflight (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a7 restart preflight
