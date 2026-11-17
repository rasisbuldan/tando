#!/bin/bash
# e1-app-exits: release exits at once (pre-flight catches it)
exec "$(dirname "$0")/app-fault.sh" e1 exit 2
