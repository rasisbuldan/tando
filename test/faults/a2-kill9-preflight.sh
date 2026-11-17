#!/bin/bash
# a2: kill9 during preflight (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a2 kill9 preflight
