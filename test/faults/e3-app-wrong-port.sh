#!/bin/bash
# e3-app-wrong-port: release binds PORT+1 (SocketBindDeny)
exec "$(dirname "$0")/app-fault.sh" e3 wrongport 2
