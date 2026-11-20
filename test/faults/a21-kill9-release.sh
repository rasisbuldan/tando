#!/bin/bash
# a21: kill9 during release, the release command of tando.conf (see act-fault.sh)
exec "$(dirname "$0")/act-fault.sh" a21 kill9 release
