#!/bin/bash
# a20: reload during rollback (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a20 reload rollback
