#!/bin/bash
# a12: powerloss during preflight (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a12 powerloss preflight
