#!/bin/bash
# A fake tando for developing the web app without a server (never touches a real host):
#   TANDO_CONFIG_DIR=/tmp/x/cfg (with hosts/web-1 and hosts/web-2 files) tando-dash --no-open --tando dev/fake-tando.sh
# web-1 answers from the fixtures; web-2 is unreachable. Uses the repo's test/fixtures/json.
F=$(cd "$(dirname "$0")/../../../.." && pwd -P)/test/fixtures/json
host=""; app=""; i=0; args=("$@")
while [ $i -lt $# ]; do case ${args[$i]} in -H) host=${args[$((i+1))]};; --app) app=${args[$((i+1))]};; esac; i=$((i+1)); done
case $1 in
  --version) echo "tando 0.2.2";;
  help) echo "tando snapshot --json";;
  snapshot)
    if [ "$host" = web-2 ]; then cat "$F/snapshot-unreachable.sample.json"
    elif [ -n "$app" ]; then cat "$F/snapshot-app.sample.json"
    else cat "$F/snapshot.sample.json"; fi;;
  doctor) cat "$F/doctor.sample.json";;
  host) cat "$F/host-status.sample.json";;
  *) echo "fake tando: $*" >&2; exit 2;;
esac
