#!/bin/bash
# a4: kill9 during verify (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a4 kill9 verify
