#!/bin/bash
# Approach B, 3 copies of the app as 3 Kamal services (each needs its own image: Kamal checks the
# image's `service` label), each with its own proxy host. Called by run-b-kamal.sh; can be rerun
# alone against a running tando-bench-b. Leaves raw/b/mem-3-three-apps.tsv, then removes all apps.
set -u
cd "$(dirname "$0")" && . ./lib.sh
C=tando-bench-b O=${OUT:-$RAW/b}
cd app
VERSION=fixed "$BENCH/kamal.sh" deploy --skip-push > "$O/deploy-bench.log" 2>&1 || log "redeploy bench failed"
for a in bench2 bench3; do
  perl -pe "s/^service: bench\$/service: $a/; s/^image: bench\$/image: $a/; s/^  app_port: 3000/  host: $a.localhost\n  app_port: 3000/" config/deploy.yml > "config/deploy.$a.yml"
  VERSION=fixed "$BENCH/kamal.sh" deploy -c "config/deploy.$a.yml" > "$O/deploy-$a.log" 2>&1 || log "deploy $a failed"
done
for a in bench2 bench3; do echo "$a: $(curl -s -H "Host: $a.localhost" http://127.0.0.1:8412/api/version)"; done | tee -a "$O/notes.txt"
idle_snapshot $C "$O/mem-3-three-apps.tsv"
docker exec $C docker ps --format '{{.Names}} {{.Image}}' >> "$O/mem-3-three-apps.containers"
for a in bench2 bench3; do "$BENCH/kamal.sh" app remove -c "config/deploy.$a.yml" > "$O/remove-$a.log" 2>&1; rm -f "config/deploy.$a.yml"; done
"$BENCH/kamal.sh" app remove > "$O/remove-bench.log" 2>&1
