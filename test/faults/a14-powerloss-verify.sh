#!/bin/bash
# a14: powerloss during verify (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a14 powerloss verify
