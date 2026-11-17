#!/bin/bash
# e5-app-oom: release leaks memory into MemoryMax (OOM kill) 5 s after start on the live port
exec "$(dirname "$0")/app-fault.sh" e5 oom@live 2
