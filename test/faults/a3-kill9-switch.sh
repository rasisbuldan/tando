#!/bin/bash
# a3: kill9 during switch (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a3 kill9 switch
