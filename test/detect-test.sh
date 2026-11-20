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
  grep -qF -- "$3" "$T/$1.out" || bad "$1: the output does not say  $3:  $(tr '\n' ' ' < "$T/$1.out" | cut -c1-400)"
}

B="npm run build"
# Node: the package manager from the lockfile, start from the start script, main or entry file
case_ express-npm "node|||node server.js||" "detected: Express (express in package.json, start script, package-lock.json), build: none, start: node server.js, output: ."
case_ express-pnpm "node|||node server.js||" "detected: Express (express in package.json, start script, pnpm-lock.yaml)"
case_ fastify-yarn "node|||node src/app.js||" "detected: Fastify (fastify in package.json, main src/app.js, yarn.lock)"
case_ express-berry "node|||node index.js||" "(express in package.json, start script, yarn.lock, Yarn 2+)"
case_ express-pnp "node|||node index.js||" "Add  nodeLinker: node-modules to .yarnrc.yml"
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

echo "detect: $n checks, $nf failed"
[ "$nf" = 0 ]
