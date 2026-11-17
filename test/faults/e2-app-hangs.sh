#!/bin/bash
# e2-app-hangs: release never listens
exec "$(dirname "$0")/app-fault.sh" e2 hang 2
