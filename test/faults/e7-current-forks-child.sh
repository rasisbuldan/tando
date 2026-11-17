#!/bin/bash
# e7-current-forks-child: good release over a current process whose child keeps the port and ignores SIGTERM
exec "$(dirname "$0")/app-fault.sh" e7 ok 3 forkchild
