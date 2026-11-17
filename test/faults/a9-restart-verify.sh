#!/bin/bash
# a9: restart during verify (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a9 restart verify
