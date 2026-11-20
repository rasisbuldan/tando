#!/bin/bash
# a22: restart during release, the release command of tando.conf (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a22 restart release
