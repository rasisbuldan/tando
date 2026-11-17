#!/bin/bash
# a17: reload during preflight (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a17 reload preflight
