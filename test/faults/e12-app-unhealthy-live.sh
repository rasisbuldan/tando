#!/bin/bash
# e12-app-unhealthy-live: release healthy in pre-flight, 500 on the live port
exec "$(dirname "$0")/app-fault.sh" e12 unhealthy@live 2
