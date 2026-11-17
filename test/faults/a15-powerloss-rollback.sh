#!/bin/bash
# a15: powerloss during rollback (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a15 powerloss rollback
