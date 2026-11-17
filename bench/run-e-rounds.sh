#!/bin/bash
# Dokku, 3 rounds (each from a bare VM), into raw/v2/e/round<r>/.
cd "$(dirname "$0")" && . ./lib.sh
for r in 1 2 3; do log "dokku round $r"; OUT=$RAW/v2/e/round$r ./run-e-dokku.sh 3 > "$RAW/v2/e-$r.out" 2>&1; stop_server tando-bench-e; done
log "dokku done"
