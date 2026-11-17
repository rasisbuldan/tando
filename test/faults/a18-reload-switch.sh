#!/bin/bash
# a18: reload during switch (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a18 reload switch
