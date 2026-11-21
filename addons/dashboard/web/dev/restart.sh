#!/bin/bash
# dev helper: rebuild the web app, rebuild tando-dash with it embedded, run it against the fake tando
set -e
D=$(cd "$(dirname "$0")/../.." && pwd -P); T=${TMPDIR:-/tmp}/tando-dash-dev
mkdir -p "$T/cfg/hosts"; touch "$T/cfg/hosts/web-1" "$T/cfg/hosts/web-2"
(cd "$D/web" && npm run build >/dev/null)
(cd "$D/server" && GOTOOLCHAIN=local go build -o "$T/tando-dash" .)
pkill -f "$T/tando-dash" || true; sleep 1
TANDO_CONFIG_DIR=$T/cfg "$T/tando-dash" --no-open --port 8099 --tando "$D/web/dev/fake-tando.sh" > "$T/log" 2>&1 &
sleep 2; cat "$T/log"
