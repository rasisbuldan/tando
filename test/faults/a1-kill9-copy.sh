#!/bin/bash
# a1: kill9 during copy (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a1 kill9 copy
