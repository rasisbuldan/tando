#!/bin/bash
# a6: restart during copy (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a6 restart copy
