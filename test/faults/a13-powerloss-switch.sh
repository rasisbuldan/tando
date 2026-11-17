#!/bin/bash
# a13: powerloss during switch (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a13 powerloss switch
