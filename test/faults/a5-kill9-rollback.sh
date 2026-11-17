#!/bin/bash
# a5: kill9 during rollback (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a5 kill9 rollback
