#!/bin/bash
# a16: reload during copy (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a16 reload copy
