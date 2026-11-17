#!/bin/bash
# a10: restart during rollback (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a10 restart rollback
