#!/bin/bash
# a19: reload during verify (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a19 reload verify
