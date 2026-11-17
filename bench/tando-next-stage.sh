#!/bin/bash
# Stage a Next.js `output: 'standalone'` build into ./dist for tando (which has no `next` recipe
# yet). Run from the app directory after `next build`:
#   1. copy .next/standalone to dist/, add .next/static and public/ (Next does not copy them)
#   2. swap sharp's macOS binaries for the Linux ones matching the server (tando refuses native
#      modules built for another platform, and Next traces @img/sharp-darwin-* into standalone).
set -euo pipefail
ARCH=${TANDO_SERVER_ARCH:-arm64}      # server arch in npm terms: arm64 or x64
CACHE=${BENCH_CACHE:-$(cd "$(dirname "$0")" && pwd)/.cache}/sharp-linux-$ARCH
[ -d .next/standalone ] || { echo "no .next/standalone: set output: 'standalone' and run next build" >&2; exit 1; }
mkdir -p dist
rsync -a --delete --exclude=/.next/static --exclude=/public .next/standalone/ dist/
rsync -a --delete .next/static/ dist/.next/static/
[ -d public ] && rsync -a --delete public/ dist/public/
if ls dist/node_modules/@img 2>/dev/null | grep -q -- '-darwin-'; then
  v=$(node -p 'require("./node_modules/sharp/package.json").version')
  if [ ! -f "$CACHE/.v$v" ]; then
    rm -rf "$CACHE"; mkdir -p "$CACHE"
    (cd "$CACHE" && npm init -y >/dev/null && npm install --no-audit --no-fund --os=linux --cpu="$ARCH" \
      --libc=glibc "sharp@$v" >/dev/null) && touch "$CACHE/.v$v"
  fi
  rm -rf dist/node_modules/@img/*-darwin-*
  cp -R "$CACHE"/node_modules/@img/*-linux-"$ARCH"* dist/node_modules/@img/
fi
