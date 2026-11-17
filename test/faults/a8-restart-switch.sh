#!/bin/bash
# a8: restart during switch (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a8 restart switch
