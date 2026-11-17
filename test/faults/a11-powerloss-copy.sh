#!/bin/bash
# a11: powerloss during copy (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a11 powerloss copy
