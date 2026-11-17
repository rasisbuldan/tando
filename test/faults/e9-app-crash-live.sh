#!/bin/bash
# e9-app-crash-live: release crashes only on the live port (passes pre-flight)
exec "$(dirname "$0")/app-fault.sh" e9 exit@live 2
