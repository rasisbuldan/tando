#!/bin/bash
# test/detect-test.sh: what tando init detects for each app in test/fixtures/apps (a real
# framework project each: package.json and its lockfile, or the Python files; no node_modules):
# the framework, recipe, build, start, output and the message. No server, no network, no npm.
# Run by test/ui-test.sh (and on its own); bash 3.2 compatible.
#
#   test/detect-test.sh [tando-root]     (default: this checkout)
#
# One line per failed check; the last line is "detect: <n> checks, <m> failed".
set -u
here=$(cd "$(dirname "$0")/.." && pwd -P)
ROOT=${1:-$here}
T=$(mktemp -d "${TMPDIR:-/tmp}/detect-test.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT
export TANDO_CONFIG_DIR=$T/cfg TANDO_COLOR=never
n=0 nf=0
bad() { nf=$((nf + 1)); echo "FAIL detect: $*"; }

# init <fixture>: tando init on a copy of it (no terminal); its output in $T/<fixture>.out
init() {
  rm -rf "${T:?}/$1"; cp -R "$here/test/fixtures/apps/$1" "$T/$1"
  (cd "$T/$1" && "$ROOT/bin/tando" init < /dev/null) > "$T/$1.out" 2>&1
}
# conf <fixture>: the detected settings as one line: recipe|build|out|start|start_shell|spa
conf() {
  local k v line=""
  for k in recipe build out start start_shell spa; do
    v=$(sed -n "s/^$k = //p" "$T/$1/tando.conf" 2> /dev/null)
    line="$line${line:+|}$v"
  done
  printf '%s' "$line"
}
# case <fixture> <recipe|build|out|start|start_shell|spa> <text the output must hold>
case_() {
  local want=$2 got
  n=$((n + 1)); init "$1"
  got=$(conf "$1")
  if [ "$got" != "$want" ]; then bad "$1: tando.conf  $got  (want  $want)"; return; fi
  # (the detected block is five lines, "detected: <framework>", "  why: ...", "  build: ...",
  # "  start: ...", "  output: ..."; joined back into one line here, as "detected: <framework>
  # (<why>), build: ..., start: ..., output: ...", so a case states it in reading order)
  awk 'NR > 1 && /^  why: / { sub(/^  why: /, " ("); printf "%s)", $0; next } NR > 1 && /^  (build|start|output): / { sub(/^  /, ", "); printf "%s", $0; next } NR > 1 { print "" } { printf "%s", $0 } END { print "" }' \
    "$T/$1.out" > "$T/$1.flat"
  grep -qF -- "$3" "$T/$1.flat" || bad "$1: the output does not say  $3:  $(cut -c1-400 < "$T/$1.flat" | tr '\n' ' ')"
  awk 'length > 80 { exit 1 }' "$T/$1.out" || bad "$1: a line of tando init is wider than 80 columns: $(awk 'length > 80' "$T/$1.out" | head -1)"
}

B="npm run build"
# Node: the package manager from the lockfile, start from the start script, main or entry file
case_ express-npm "node|||node server.js||" "detected: Express (express in package.json, start script, package-lock.json), build: none, start: node server.js, output: ."
case_ express-pnpm "node|||node server.js||" "detected: Express (express in package.json, start script, pnpm-lock.yaml)"
case_ fastify-yarn "node|||node src/app.js||" "detected: Fastify (fastify in package.json, main src/app.js, yarn.lock)"
case_ express-berry "node|||node index.js||" "(express in package.json, start script, yarn.lock, Yarn 2+)"
case_ express-pnp "node|||node index.js||" "Add  nodeLinker: node-modules  to .yarnrc.yml"
case_ node-fixedport "node|||node app.js||" "app.js listens on a fixed port (line 4: .listen(8000"
case_ node-nvmrc "node|||node index.js||" "output: ., Node 22 (.node-version)"
case_ nest "node|$B||node dist/main||" "detected: NestJS (@nestjs/core in package.json, package-lock.json), build: npm run build, start: node dist/main"
# Next.js: the standalone server; without output: "standalone" init says the line to add
case_ next-app "next|$B||node server.js||" "detected: Next.js (next in package.json, package-lock.json), build: npm run build, start: node server.js, output: .next"
case_ next-pages "next|$B||node server.js||" 'Next.js needs  output: "standalone"  in next.config.js'
case_ next-basepath "next|$B||node server.js||" "detected: Next.js"
n=$((n + 1)); grep -qx 'path = /shop' "$T/next-basepath/tando.conf" || bad "next-basepath: no path = /shop"
# static builds: the output directory, and SPA when a client-side router is a dependency
case_ vite-vue "static|$B|dist|||true" "detected: Vite + Vue (vite in package.json, vue-router, package-lock.json), build: npm run build, start: none (Caddy serves the files), output: dist, SPA"
case_ vite-react "static|$B|build|||true" "detected: Vite + React (vite in package.json, react-router-dom"
case_ vite-svelte "static|$B|dist|||" "detected: Vite + Svelte (vite in package.json, package-lock.json)"
case_ astro-static "static|$B|dist|||" "detected: Astro (static) (astro in package.json"
# Node SSR frameworks
case_ astro-node "node|$B||HOST=127.0.0.1 node dist/server/entry.mjs|true|" "detected: Astro (SSR) (@astrojs/node in package.json"
case_ nuxt "node|$B|.output|node server/index.mjs||" "detected: Nuxt (nuxt in package.json, package-lock.json), build: npm run build, start: node server/index.mjs, output: .output"
case_ sveltekit "node|$B||node build||" "detected: SvelteKit (@sveltejs/adapter-node in package.json"
case_ remix "node|$B||npm start||" "detected: React Router (Remix) (@react-router/serve in package.json"
# Python (start bound to $PORT, as before)
case_ django "python|||gunicorn -b 127.0.0.1:\$PORT site_one.wsgi|true|" "detected: Django (manage.py, site_one/wsgi.py)"
n=$((n + 1)); grep -q 'ALLOWED_HOSTS' "$T/django.out" || bad "django: no ALLOWED_HOSTS hint"
case_ fastapi "python|||uvicorn main:api --host 127.0.0.1 --port \$PORT|true|" "detected: FastAPI (fastapi, main.py)"
case_ flask "python|||gunicorn -b 127.0.0.1:\$PORT app:app|true|" "detected: Flask (flask, app.py)"
n=$((n + 1)); ! grep -q 'add gunicorn' "$T/flask.out" || bad "flask: says add gunicorn, but pyproject.toml lists it"
case_ static-plain "static|||||" "detected: static site (./index.html)"
# a monorepo root: refused, with the packages and what to do
n=$((n + 1)); init monorepo
if [ -f "$T/monorepo/tando.conf" ] || ! grep -q 'monorepo (a workspace root with apps/api apps/web packages/shared).*Run tando init in that directory' "$T/monorepo.out"; then
  bad "monorepo: not refused with the packages: $(tr '\n' ' ' < "$T/monorepo.out")"
fi

# a package inside a workspace (pnpm install at the root linked its node_modules): init stops early
# with what to do instead, and so does a deploy of it (it used to say "no lockfile: npm", then
# stop at stage on "dangling symlink: node_modules/express")
n=$((n + 1)); rm -rf "${T:?}/ws"; mkdir -p "$T/ws/apps/web/node_modules" "$T/ws/node_modules/.pnpm/express"
printf 'packages:\n  - "apps/*"\n' > "$T/ws/pnpm-workspace.yaml"
printf 'lockfileVersion: 9.0\n' > "$T/ws/pnpm-lock.yaml"
printf '{ "name": "root", "private": true }\n' > "$T/ws/package.json"
printf '{ "name": "web", "dependencies": { "express": "4.21.0" } }\n' > "$T/ws/apps/web/package.json"
echo 'require("http").createServer((q, s) => s.end("hi")).listen(process.env.PORT)' > "$T/ws/apps/web/server.js"
ln -s ../../../node_modules/.pnpm/express "$T/ws/apps/web/node_modules/express"
(cd "$T/ws/apps/web" && "$ROOT/bin/tando" init < /dev/null) > "$T/ws.out" 2>&1
if [ -f "$T/ws/apps/web/tando.conf" ] || ! grep -q 'is a package of the workspace in .*deploying it alone is not supported yet' "$T/ws.out" ||
   ! grep -q 'pnpm deploy --filter web <dir>' "$T/ws.out" || grep -q 'no lockfile' "$T/ws.out"; then
  bad "workspace member: init did not stop with the message: $(tr '\n' ' ' < "$T/ws.out")"
fi
n=$((n + 1))
printf 'app = web\nhost = vps\nrecipe = node\nstart = node server.js\n' > "$T/ws/apps/web/tando.conf"
mkdir -p "$T/cfg/hosts"; printf 'target=nobody@127.0.0.1\nport=9\nkey=\ninsecure=1\nkind=admin\n' > "$T/cfg/hosts/vps"
(cd "$T/ws/apps/web" && "$ROOT/bin/tando" deploy < /dev/null) > "$T/ws2.out" 2>&1
if ! grep -q 'is a package of the workspace in' "$T/ws2.out"; then
  bad "workspace member: deploy did not stop early: $(tr '\n' ' ' < "$T/ws2.out")"
fi
# a standalone project with its own lockfile inside a directory tree that has a workspace above is no member
n=$((n + 1)); : > "$T/ws/apps/web/package-lock.json"; rm "$T/ws/apps/web/tando.conf"
(cd "$T/ws/apps/web" && "$ROOT/bin/tando" init < /dev/null) > "$T/ws3.out" 2>&1
grep -q 'is a package of the workspace' "$T/ws3.out" && bad "workspace member: a directory with its own lockfile was refused"

echo "detect: $n checks, $nf failed"
[ "$nf" = 0 ]
