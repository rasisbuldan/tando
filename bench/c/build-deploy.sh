#!/bin/bash
# Approach C: build and activate on the server (runs as the login user; sudo only to switch).
# Prints phase=seconds lines. npm ci runs only when package-lock.json changed (best case for
# server builds, like a cached Dokku/Coolify layer); .next/cache is kept between builds.
set -eu
export NEXT_TELEMETRY_DISABLED=1 npm_config_cache=/srv/app/.npm
cd /srv/app/src
t() { date +%s.%N; }
el() { awk -v a="$1" -v b="$(t)" 'BEGIN{printf "%.2f", b-a}'; }
t0=$(t)
if ! cmp -s package-lock.json .lock-installed 2>/dev/null || [ ! -d node_modules ]; then
  npm ci --no-audit --no-fund > /srv/app/npm.log 2>&1; cp package-lock.json .lock-installed; echo "install=$(el $t0)"
else echo "install=0"; fi
t1=$(t); npx next build > /srv/app/build.log 2>&1; echo "build=$(el $t1)"
t2=$(t); id=$(date -u +%Y%m%d-%H%M%S); r=/srv/app/releases/$id
mkdir -p "$r"; cp -a .next/standalone/. "$r/"; cp -a .next/static "$r/.next/static"; cp -a public "$r/public"
echo "stage=$(el $t2)"
t3=$(t); ln -sfn "$r" /srv/app/current.tmp && mv -Tf /srv/app/current.tmp /srv/app/current
sudo -n systemctl restart bench.service
for i in $(seq 1 60); do c=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: bench.localhost' http://127.0.0.1/api/version || true)
  [ "$c" = 200 ] && break; sleep 0.25; done
echo "activate=$(el $t3)"; [ "$c" = 200 ] || { echo "health=fail"; exit 1; }
ls -1d /srv/app/releases/* | sort -r | tail -n +6 | xargs -r rm -rf    # keep 5 releases
echo "total_server=$(el $t0)"
