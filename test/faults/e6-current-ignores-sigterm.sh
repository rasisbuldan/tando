#!/bin/bash
# e6-current-ignores-sigterm: good release over a current process that ignores SIGTERM
exec "$(dirname "$0")/app-fault.sh" e6 ok 3 nosigterm
