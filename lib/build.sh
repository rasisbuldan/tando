# lib/build.sh: tando init, the build step, staging, the release guard, and swapping
# platform-specific npm packages (such as sharp) to the server's platform.

STAGE=.tando/stage
CACHE=.tando/cache

# ---- init ----------------------------------------------------------------------------------

next_config() { ls next.config.js next.config.mjs next.config.ts next.config.cjs 2> /dev/null | head -1; }

# the first file of a list that exists
first_file() { local f; for f; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }

# ---- package.json, read without Node (grep and sed on the file; no network, no npm) --------

# pkg_dep name...: one of the names is a key in package.json (dependencies, devDependencies)
pkg_dep() {
  local d
  for d; do grep -q "\"$d\"[[:space:]]*:" package.json && return 0; done
  return 1
}
# pkg_obj key: the inside of the top-level object "key": { ... } of package.json (one line)
pkg_obj() { tr -d '\n\r' < package.json | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*{\([^}]*\)}.*/\1/p"; }
# pkg_script name: the command of scripts.<name> (fails when there is none)
pkg_script() {
  local s
  s=$(pkg_obj scripts | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")
  [ -n "$s" ] && printf '%s\n' "$s"
}
# pkg_str key: a top-level string of package.json (main)
pkg_str() { tr -d '\n\r' < package.json | sed -n "s/^[[:space:]]*{[[:space:]]*\(.*\)/\1/p" |
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"; }

# node_start: start for a plain Node app (and the file it runs in entry): the start script when
# it is `node <file>`, a server.js, index.js, app.js or main.js, the main of package.json, or
# npm start; why says which
node_start() {
  local s m
  s=$(pkg_script start 2> /dev/null || true)
  case $s in
    "node "*) set -- $s
      if [ $# = 2 ] && [ -f "$2" ]; then start=$s entry=$2 why="${why:+$why, }start script"; return 0; fi;;
  esac
  if [ -n "$entry" ]; then start="node $entry" why="${why:+$why, }$entry"; return 0; fi
  [ -f package.json ] && m=$(pkg_str main)
  if [ -n "$m" ] && [ -f "$m" ]; then start="node $m" entry=$m why="${why:+$why, }main $m"; return 0; fi
  if [ -n "$s" ]; then start="npm start" why="${why:+$why, }start script"; return 0; fi
  start="node server.js"
  note "node: no start script, main, server.js, index.js, app.js or main.js: set  start = node <file>  in tando.conf"
}

# node_pm: the package manager the lockfile names (what tando up installs the dependencies with)
node_pm() {
  if [ -f pnpm-lock.yaml ]; then echo pnpm-lock.yaml
  elif [ -f yarn.lock ] && [ -f .yarnrc.yml ]; then echo "yarn.lock, Yarn 2+"
  elif [ -f yarn.lock ]; then echo yarn.lock
  elif [ -f bun.lock ] || [ -f bun.lockb ]; then echo bun.lock
  elif [ -f package-lock.json ]; then echo package-lock.json
  else echo "no lockfile: npm"; fi
}

# node_framework: a Node framework whose build, start and output tando knows (the first that
# matches, by its dependency in package.json); sets recipe, build, start, out, fw, why, spa.
# A workspace root (a monorepo) stops here: which package to deploy cannot be guessed.
node_framework() {
  local b=npm\ run\ build v
  pkg_script build > /dev/null || b=""
  if [ -f pnpm-workspace.yaml ] || [ -n "$(tr -d '\n\r' < package.json | sed -n 's/.*"workspaces"[[:space:]]*:[[:space:]]*\([[{]\).*/\1/p')" ]; then
    v=$(for d in */*/package.json; do [ -f "$d" ] && printf '%s ' "${d%/package.json}"; done)
    d=${v%% *}
    die "this is a monorepo (a workspace root${v:+ with ${v% }}): tando deploys one app from its own" \
      "directory, with its dependencies installed there. Run tando init in that directory" \
      "(cd ${d:-apps/web}); deploying a workspace package from the root is not supported yet"
  fi
  if pkg_dep nuxt; then
    recipe=node fw=Nuxt why="nuxt in package.json" build=${b:-npx nuxt build} out=.output start="node server/index.mjs"
  elif pkg_dep @sveltejs/adapter-node; then
    recipe=node fw=SvelteKit why="@sveltejs/adapter-node in package.json" build=${b:-npx vite build} start="node build"
  elif pkg_dep @sveltejs/kit; then
    die "SvelteKit without @sveltejs/adapter-node: tando runs it with Node. Install it" \
      "(npm i -D @sveltejs/adapter-node) and set  adapter: adapter()  from it in svelte.config.js, then tando init"
  elif pkg_dep @astrojs/node; then
    recipe=node fw="Astro (SSR)" why="@astrojs/node in package.json" build=${b:-npx astro build} \
      start="HOST=127.0.0.1 node dist/server/entry.mjs" shell=1
  elif pkg_dep @react-router/serve @remix-run/serve; then
    recipe=node fw="React Router (Remix)" why="$(pkg_dep @react-router/serve && echo @react-router/serve || echo @remix-run/serve) in package.json" \
      build=$b start="npm start"
    pkg_script start > /dev/null || start="npx react-router-serve ./build/server/index.js"
  elif pkg_dep @nestjs/core; then
    recipe=node fw=NestJS why="@nestjs/core in package.json" build=${b:-npx nest build} start="node dist/main"
    v=$(pkg_script start:prod 2> /dev/null || true)
    case $v in "node "*) start=$v;; esac
  elif pkg_dep astro; then
    recipe=static fw="Astro (static)" why="astro in package.json" build=${b:-npx astro build} out=dist
  elif pkg_dep vite && ! entry=$(first_file server.js index.js app.js main.js); then
    recipe=static build=${b:-npx vite build} out=dist fw=Vite why="vite in package.json"
    if pkg_dep @vitejs/plugin-vue; then fw="Vite + Vue"
    elif pkg_dep @vitejs/plugin-react @vitejs/plugin-react-swc; then fw="Vite + React"
    elif pkg_dep @sveltejs/vite-plugin-svelte; then fw="Vite + Svelte"; fi
    v=$(ls vite.config.js vite.config.mjs vite.config.ts vite.config.mts 2> /dev/null | head -1)
    [ -n "$v" ] && v=$(sed -n "s/.*outDir:[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" "$v" | head -1)
    case $v in ""|/*|*..*) ;; *) out=${v#./};; esac
    # a client-side router in history mode: deep links (/about/team) are the app's, not files
    for v in vue-router react-router-dom react-router @tanstack/react-router svelte-routing @solidjs/router; do
      pkg_dep "$v" && { spa=1 why="$why, $v"; break; }
    done
  else
    return 1
  fi
  return 0
}

# detection order: next, node, python, container (Dockerfile), static
cmd_init() {
  [ -f tando.conf ] && { note "tando.conf exists"; return 0; }
  # shellcheck disable=SC2153 # HOST: set by -H (lib/common.sh)
  local name recipe="" out=. start="" health=/ build="" path="" cfg entry="" dir host=$HOST shell="" cport="" db=""
  dir=$(basename "$PWD")
  name=$(printf '%s' "$dir" | tr '[:upper:]' '[:lower:]' | tr '_ .' '---' | tr -cd 'a-z0-9-' |
    sed 's/^[^a-z]*//; s/-\{2,\}/-/g' | cut -c1-26 | sed 's/-$//')
  valid_app "$name" ||
    die "cannot make an app name from the directory \"$dir\" (2-26 of a-z, 0-9, -, starting with a letter):" \
      "write tando.conf with  app = <name>  yourself, or rename the directory"
  [ "$name" = "$dir" ] || note "app name: $name (from the directory $dir)"
  # one registered server: it goes into tando.conf, so adding a second one later breaks nothing
  if [ -z "$host" ] && [ -z "${TANDO_DEPLOY_KEY:-}" ]; then
    set -- "$CFG"/hosts/*
    [ $# -eq 1 ] && [ -f "$1" ] && host=${1##*/}
  fi
  local fw="" why="" spa="" v
  if [ -f package.json ] && pkg_dep next; then
    recipe=next build="npm run build" start="node server.js" fw=Next.js why="next in package.json"
    cfg=$(next_config)
    if [ -n "$cfg" ]; then
      path=$(sed -n "s/.*basePath:[[:space:]]*['\"]\(\/[^'\"]*\)['\"].*/\1/p" "$cfg" | head -1)
    fi
    out=.next/standalone
  elif [ -f package.json ] && node_framework; then
    :   # (a framework with a known build, start and output: node_framework set them)
  elif entry=$(first_file server.js index.js app.js main.js) || [ -f package.json ]; then
    recipe=node fw=Node.js why=package.json
    [ -f package.json ] || why=$entry
    if [ -f package.json ]; then
      pkg_script build > /dev/null && build="npm run build"
      for v in Express:express Fastify:fastify Koa:koa Hono:hono hapi:@hapi/hapi; do
        pkg_dep "${v#*:}" && { fw=${v%%:*} why="${v#*:} in package.json"; break; }
      done
    fi
    node_start
    node_port_hint "$entry"
  elif entry=$(first_file app.py main.py wsgi.py asgi.py) || [ -f requirements.txt ] || [ -f pyproject.toml ]; then
    recipe=python start="python ${entry:-app.py}" fw=Python why="${entry:-requirements.txt}"
    python_start "${entry:-app.py}"
    [ -f requirements.txt ] || [ -f pyproject.toml ] ||
      note "python: no requirements.txt; the server builds the virtualenv from it"
    [ -n "$entry$shell" ] || note "python: no app.py, main.py, wsgi.py or asgi.py; check start"
  elif [ -f Dockerfile ]; then
    recipe=container fw=container why=Dockerfile
    note "container: the image is built here for the server's platform (docker or podman needed)"
    cport=$(dockerfile_port Dockerfile)
    [ -n "$cport" ] && note "container: the Dockerfile EXPOSEs $cport, so container_port = $cport"
  else
    recipe=static
    for out in dist public build .; do [ -f "$out/index.html" ] && break; done
    [ -f "$out/index.html" ] || die "cannot tell what this is: no package.json, Node or Python entry file," \
      "Dockerfile or index.html (tando recipes lists what each recipe looks for)"
    fw="static site" why="$out/index.html"
  fi
  case $recipe in node|next) v=$(first_file .nvmrc .node-version) || { grep -q '"engines"' package.json 2> /dev/null && v="engines in package.json"; };; *) v="";; esac
  [ -f package.json ] && why="$why, $(node_pm)"
  note "detected: $fw ($why), build: ${build:-none}, start: ${start:-none (Caddy serves the files)}," \
    "output: $out${spa:+, SPA (unknown paths get index.html)}${v:+, Node $(node_major) ($v)}"
  [ "$out" = .next/standalone ] && out=.
  [ "$recipe" = static ] || [ ! -f .yarnrc.yml ] || (yarn_pnp) || true   # (says what to add; deploy refuses)
  if [ "$recipe" != static ]; then
    health=$(health_path "$entry")
    if [ "$health" = / ]; then
      note "health = / (no health route found). Add one that checks the app, then set"
      note "  health = /api/health in tando.conf: a release that breaks it never goes live"
    fi
  fi
  if dep_postgres; then
    db="database = postgres              # a PostgreSQL dependency is here: uncomment to get DATABASE_URL"
    note "$(dep_postgres_name) is a dependency: database = postgres in tando.conf gives the app a PostgreSQL database"
  fi
  if [ -f Dockerfile ] && [ "$recipe" != container ]; then
    note "a Dockerfile is here too: set recipe = container to run its image instead"
  fi
  {
    echo "app = $name"
    [ -n "$host" ] && echo "host = $host"
    echo "recipe = $recipe"
    [ -n "$build" ] && echo "build = $build"
    [ "$out" != . ] && echo "out = $out"
    [ -n "$start" ] && echo "start = $start"
    [ -n "$shell" ] && echo "start_shell = true"
    [ -n "$spa" ] && echo "spa = true"
    [ -n "$cport" ] && echo "container_port = $cport"
    [ -n "$path" ] && echo "path = $path"
    [ "$recipe" = next ] && echo "writable = .next/server/route-cache .next/server/app"
    echo "health = $health"
    [ "$recipe" = static ] || echo "memory = 256M"   # Caddy serves a static site: no process
    echo
    echo "# More settings (tando help conf lists them all). Change them, then: tando deploy"
    echo "# data = data                      # a directory that survives deploys (\$TANDO_DATA_DIR)"
    echo "# ${db:-database = postgres              # or sqlite; the app gets DATABASE_URL}"
    echo "# job.nightly = daily | node scripts/nightly.js"
    [ "$recipe" = static ] || [ "$recipe" = container ] ||
      echo "# release = node scripts/migrate.js  # run on the server at every deploy, before the switch (migrations)"
    echo "# path = /shop                     # serve under a sub-path"
    [ -n "$shell" ] || [ "$recipe" = static ] ||
      echo "# start_shell = true               # run start with sh -c (pipes, &&, \$VARS)"
  } > tando.conf
  note "wrote tando.conf ($recipe${host:+, host $host})"
  [ -z "$shell" ] && case $start in *'|'*|*'&'*|*'$'*|*';'*|*'>'*|*'<'*)
    note "start runs without a shell (no pipes, &&, \$VARS): set start_shell = true for sh -c";; esac
  [ "$recipe" = next ] && init_next
  return 0
}

# init_next: Next.js must build with output: "standalone" (tando ships .next/standalone). With
# --yes or a yes at the terminal it is added to next.config.*, or next.config.mjs is written when
# the project has none. init never fails on it: tando.conf is written, and deploy checks again.
init_next() {
  local cfg a what
  cfg=$(next_config)
  [ -n "$cfg" ] && grep -q "output:[[:space:]]*['\"]standalone['\"]" "$cfg" && return 0
  if [ -n "$cfg" ]; then what="add  output: \"standalone\"  to $cfg"
  else what="write next.config.mjs with  output: \"standalone\"  (there is no next.config yet)"; fi
  if [ -z "$YES" ] && [ -t 0 ]; then
    printf 'Next.js: %s? tando ships .next/standalone [Y/n] ' "$what" >&2
    IFS= read -r a || a=n
    case $a in ""|y|Y|yes) ;; *) a=no;; esac
  elif [ -n "$YES" ]; then a=y
  else a=no; fi
  if [ "$a" = no ]; then
    note "Next.js needs  output: \"standalone\"  in ${cfg:-next.config.mjs} before tando deploy" \
      "(tando init --yes or tando up --yes adds it)"
    return 0
  fi
  if [ -z "$cfg" ]; then
    printf '%s\n' '// written by tando init: tando ships the standalone server (.next/standalone)' \
      '/** @type {import("next").NextConfig} */' 'export default { output: "standalone" };' > next.config.mjs &&
      note "wrote next.config.mjs (output: \"standalone\")"
  elif next_add_standalone "$cfg"; then
    # the lines as they are now in the file: the opening of the config object and the new one
    local ln
    ln=$(grep -n '^  output: "standalone",$' "$cfg" | head -1 | cut -d: -f1)
    note "added  output: \"standalone\"  to $cfg:"
    if [ -n "$ln" ] && [ "$ln" -gt 1 ]; then
      note "  $(printf '%4s' $((ln - 1)))    $(sed -n "$((ln - 1))p" "$cfg" | strip)"
      note "  $(printf '%4s' "$ln")  + $(sed -n "${ln}p" "$cfg" | strip)"
    fi
  else
    note "could not find the config object in $cfg: add  output: \"standalone\"  inside it before tando deploy"
  fi
  return 0
}

# health_path entry: a health route the project defines (Next app/ or pages/ routes, or the
# path in the entry file: /api/health, /health, /healthz, /api/healthz), else /
health_path() {
  local f p d
  for p in api/health api/healthz health healthz; do
    for d in app src/app; do [ -e "$d/$p" ] && { echo "/$p"; return 0; }; done
    for d in pages src/pages; do
      for f in "$d/$p".js "$d/$p".ts "$d/$p"/index.js "$d/$p"/index.ts; do [ -e "$f" ] && { echo "/$p"; return 0; }; done
    done
  done
  for f in "$1" app.py main.py server.js index.js app.js main.js; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    for p in /api/health /health /healthz /api/healthz; do
      grep -qE "[\"'\`]${p}[\"'\`]" "$f" && { echo "$p"; return 0; }
    done
  done
  echo /
}

# dep_postgres: package.json or the Python requirements name a PostgreSQL client
dep_postgres() { [ -n "$(dep_postgres_name)" ]; }
dep_postgres_name() {
  if [ -f package.json ] && grep -qE '"(pg|postgres)"[[:space:]]*:' package.json; then
    sed -n -E 's/.*"(pg|postgres)"[[:space:]]*:.*/\1/p' package.json | head -1
  elif { cat requirements.txt pyproject.toml 2> /dev/null || true; } | grepq -iE '^[[:space:]"]*(psycopg|psycopg2|psycopg2-binary|asyncpg)([^A-Za-z0-9_-]|$)'; then
    echo psycopg
  fi
}

# node_port_hint file: a Node entry that listens on a number instead of process.env.PORT
node_port_hint() {
  [ -n "$1" ] && [ -f "$1" ] || return 0
  grep -q 'process\.env\.PORT' "$1" && return 0
  local l
  local re='\.listen\([[:space:]]*[0-9]{2,5}|[Pp][Oo][Rr][Tt][[:space:]]*=[[:space:]]*[0-9]{2,5}'
  l=$(grep -n -o -E "$re" "$1" | head -1)
  [ -n "$l" ] || return 0
  note "node: $1 listens on a fixed port (line ${l%%:*}: ${l#*:}...)."
  note "  tando gives the app its port in PORT and blocks the others: use .listen(process.env.PORT || 3000)"
}

# python_start entry: Flask, FastAPI or Django get a production server bound to $PORT
# (start, shell and a note when its package is not in requirements.txt)
python_start() {
  local m=${1%.py} v pkg="" reqs
  reqs=$(cat requirements.txt pyproject.toml 2> /dev/null | tr '[:upper:]' '[:lower:]')
  if [ -f manage.py ] || printf '%s' "$reqs" | grepq '^django\|"django'; then
    for v in ./*/wsgi.py; do [ -f "$v" ] && break; v=""; done
    v=${v#./}; v=${v%/wsgi.py}
    [ -n "$v" ] || return 0
    start="gunicorn -b 127.0.0.1:\$PORT $v.wsgi" pkg=gunicorn fw=Django why="manage.py, $v/wsgi.py"
    note "django: ALLOWED_HOSTS must list the app's domain; for its static files set STATIC_ROOT and" \
      "  release = python manage.py collectstatic --noinput  in tando.conf"
  elif printf '%s' "$reqs" | grepq 'fastapi' || grepq 'FastAPI(' "$1" 2> /dev/null; then
    v=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=[[:space:]]*FastAPI(.*/\1/p' "$1" 2> /dev/null | head -1)
    start="uvicorn $m:${v:-app} --host 127.0.0.1 --port \$PORT" pkg=uvicorn fw=FastAPI why="fastapi, $1"
  elif printf '%s' "$reqs" | grepq 'flask' || grepq 'Flask(' "$1" 2> /dev/null; then
    v=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=[[:space:]]*Flask(.*/\1/p' "$1" 2> /dev/null | head -1)
    start="gunicorn -b 127.0.0.1:\$PORT $m:${v:-app}" pkg=gunicorn fw=Flask why="flask, $1"
  else
    grep -q 'environ' "$1" 2> /dev/null ||
      note "python: listen on the port in os.environ[\"PORT\"] (tando gives the app one and blocks the others)"
    return 0
  fi
  shell=1
  note "python: start = $start (bound to the PORT tando gives the app)"
  printf '%s\n' "$reqs" | grepq -E "(^|[\"' ])$pkg" ||
    note "  add $pkg to requirements.txt: the server installs the venv from it"
}

# python_server_pkg: start runs gunicorn or uvicorn (the default start of tando init for Flask,
# Django and FastAPI) but requirements.txt does not list it: the uploaded copy gets it, so the
# server's venv has it (the project's own file is not changed; the note says so)
python_server_pkg() {
  local w pkg
  for w in $C_start; do case $w in *=*) continue;; esac; pkg=$w; break; done
  case ${pkg:-} in gunicorn|uvicorn) ;; *) return 0;; esac
  if [ -f "$STAGE/requirements.txt" ]; then
    tr '[:upper:]' '[:lower:]' < "$STAGE/requirements.txt" |
      grepq -E "^[[:space:]]*$pkg([^a-z0-9_-]|\$)" && return 0
  elif [ -f "$STAGE/pyproject.toml" ]; then return 0   # (its own dependency list: not edited)
  fi
  { [ ! -s "$STAGE/requirements.txt" ] || [ -z "$(tail -c1 "$STAGE/requirements.txt")" ] || echo
    echo "$pkg"; } >> "$STAGE/requirements.txt"
  STAGE_NOTE="${STAGE_NOTE:+$STAGE_NOTE; }$pkg added to the uploaded requirements.txt (start runs it; add it to yours to keep this exact)"
}

cmd_recipes() {
  {
    printf 'RECIPE\tDETECTED BY\tRUNS\tSERVER NEEDS\n'
    printf 'next\tpackage.json with next\tnode server.js from .next/standalone\tnode\n'
    printf 'node\tserver.js, index.js, app.js, main.js or package.json\tstart, as the app user\tnode\n'
    printf 'python\tapp.py, main.py, wsgi.py, asgi.py or requirements.txt\ta venv built on the server\tpython=yes\n'
    printf 'container\tDockerfile (or image = ...)\tthe image under Podman, as the app uid\tpodman=yes\n'
    printf 'static\tindex.html in dist, public, build or .\tCaddy itself (request log, no app log)\tnothing\n'
  } > "$TMPD/rows"
  ui_box_open "recipes"
  ui_table "l,l!2,l!1,l" < "$TMPD/rows"
  ui_box_close "detected in this order by tando init; set recipe in tando.conf to choose"
}

# ---- build ---------------------------------------------------------------------------------

# the build command: tando.conf's build, then for containers the image build for the server's
# platform with docker or podman, whichever exists
needs_build() { [ -n "$C_build" ] || { [ "$C_recipe" = container ] && [ -z "$C_image" ]; }; }
run_build_cmd() {
  if [ -n "$C_build" ]; then /bin/sh -c "$C_build" || return 1; fi
  [ "$C_recipe" = container ] && [ -z "$C_image" ] || return 0
  "$ENGINE" build --platform "linux/$(server_cpu)" -t "tando-build/$APP:latest" -f "${C_dockerfile:-Dockerfile}" .
}
server_cpu() { case $K_arch in x86_64) echo amd64;; aarch64|arm64) echo arm64;; *) echo "$K_arch";; esac; }

# run_build: runs C_build; sets BUILD_SECS and BUILD_SUMMARY; on failure prints the output tail
run_build() {
  local t0 lines last
  BUILD_SECS=0 BUILD_SUMMARY=""
  needs_build || return 0
  t0=$(clock)
  if ! run_build_cmd > "$TMPD/build.log" 2>&1; then
    BUILD_SECS=$(since "$t0")
    return 1
  fi
  BUILD_SECS=$(since "$t0")
  # summary: the last line that looks like a result, else the last line of output
  lines=$(grep -c . "$TMPD/build.log")
  last=$(grep -iE '✓|success|done|built|compiled|ok\b' "$TMPD/build.log" | tail -1 | strip)
  [ -n "$last" ] || last=$(grep . "$TMPD/build.log" | tail -1 | strip)
  BUILD_SUMMARY="$lines lines${last:+, $(trim "$last")}"
}

# ---- staging -------------------------------------------------------------------------------

# sfail message: a staging or guard failure, shown as a failed stage step in the deploy box
sfail() {
  if [ "${UI_BOX:-0}" = 1 ]; then
    phase_line 2 stage fail ""
    box_say "$UI_RED" "$*"
    ui_box_close "nothing was uploaded"
  else
    note "tando: $*"
  fi
  exit 1
}
# sfail_lines headline file: the same, with the lines of file after it (paths, why, what to do)
sfail_lines() {
  local l
  if [ "${UI_BOX:-0}" = 1 ]; then
    phase_line 2 stage fail ""
    box_say "$UI_RED" "$1"
    while IFS= read -r l; do box_say "" "$l"; done < "$2"
    ui_box_close "nothing was uploaded"
  else
    note "tando: $1"
    cat "$2" >&2
  fi
  exit 1
}

# rsync with checksums: same-size edits within the same second are still seen
sync_dir() { # src dst [excludes...]
  local src=$1 dst=$2
  shift 2
  mkdir -p "$dst"
  rsync -a -c --delete "$@" "$src/" "$dst/" || sfail "staging $src failed"
}

# the standalone server directory inside .next/standalone (nested when tracing used a parent)
next_root() { # -> NEXT_ROOT
  NEXT_ROOT=.next/standalone
  [ -f "$NEXT_ROOT/server.js" ] && return 0
  NEXT_ROOT=$(find .next/standalone -name server.js -not -path '*/node_modules/*' 2> /dev/null | head -1)
  [ -n "$NEXT_ROOT" ] || sfail "no .next/standalone/server.js: set output: 'standalone' in $(next_config)"
  NEXT_ROOT=$(dirname "$NEXT_ROOT")
}

stage() {
  local ex=(--exclude=.git --exclude=.DS_Store '--exclude=.env*' --exclude=.npmrc) out=${C_out:-.}   # (.npmrc can hold a registry token)
  STAGE_NOTE=""
  # .tando/ is the staging area: never something to commit
  mkdir -p .tando && { [ -f .tando/.gitignore ] || printf '*\n' > .tando/.gitignore; }
  [ -n "$C_data" ] && ex+=("--exclude=/$C_data")
  case $C_recipe in
    container)
      stage_container
      return;;
    next)
      next_root
      sync_dir "$NEXT_ROOT" "$STAGE" "${ex[@]}" --exclude=/.next/static --exclude=/public --exclude=/.next/cache
      sync_dir .next/static "$STAGE/.next/static"
      if [ -d public ]; then sync_dir public "$STAGE/public" "${ex[@]}"; else rm -rf "$STAGE/public"; fi
      ;;
    *)
      [ -d "$out" ] || sfail "out directory not found: $out"
      [ "$C_recipe" = python ] && ex+=(--exclude=/.venv --exclude=__pycache__ '--exclude=*.pyc')
      # fsevents is macOS only (an optional dependency of vite, rollup, chokidar: they run without
      # it); its Mach-O file would stop the release at the native-code guard
      ex+=(--exclude=node_modules/fsevents)
      sync_dir "$out" "$STAGE" "${ex[@]}" --exclude=/.tando --exclude=/tando.conf
      if [ -n "$C_data" ] && [ -e "$out/$C_data" ]; then
        STAGE_NOTE="$C_data/ not uploaded: it is the app's data directory on the server"
      elif [ -f "$out/.env" ]; then
        STAGE_NOTE=".env not uploaded (secrets stay out of releases); to use it: tando env import .env"
      fi
      [ "$C_recipe" = python ] && python_server_pkg
      ;;
  esac
  SWAPPED=""
  swap_native
  native_fix
  guard
}

# container: the saved image (an OCI/docker archive, unpacked so unchanged layers are files that
# rsync skips), or just the name of an image the server pulls
stage_container() {
  rm -rf "${TMPD:?}/img"; mkdir -p "$TMPD/img"
  if [ -n "$C_image" ]; then
    printf '%s\n' "$C_image" > "$TMPD/img/image-ref"
  else
    "$ENGINE" save "tando-build/$APP:latest" | tar -x -C "$TMPD/img" || sfail "$ENGINE save failed"
  fi
  sync_dir "$TMPD/img" "$STAGE"
  SWAPPED=""
}


# ---- platform packages ---------------------------------------------------------------------

# npm ships native code as per-platform packages (@img/sharp-darwin-arm64, @next/swc-darwin-arm64,
# @esbuild/darwin-arm64, ...). Each one for another platform than the server's, at any depth of
# node_modules, is replaced in its own node_modules by the package for the server's platform, at
# the version the package beside it pins (lib/native.js finds them; docs/CROSS-ARCH.md lists the
# families). The tarball comes from `npm pack` (the registry npm is set up for here), is checked
# against the lockfile's sha512 when the lockfile has one (a mismatch stops the deploy), and is
# kept in .tando/cache beside its own sha512 (a cached file that changed is fetched again).
# Sets SWAPPED (the count for the stage line) and $TMPD/swaps: from, name, version, verified.
swap_native() {
  local cpu libc kind from dest name ver integ lock why tab=$'\t' njs=$TANDO_HOME/lib/native.js
  SWAPPED=""; : > "$TMPD/swaps"; : > "$TMPD/native.notes"
  [ -d "$STAGE/node_modules" ] || return 0
  case $K_arch in x86_64) cpu=x64;; aarch64|arm64) cpu=arm64;; *) cpu=$K_arch;; esac
  libc=glibc; [ "${K_libc:-}" = musl ] && libc=musl
  # (without Node nothing here was built by npm; the guard still looks at every native file)
  command -v node > /dev/null || return 0
  node "$njs" plan "$STAGE" "$cpu" "$libc" "$(native_lockdir)" > "$TMPD/plan" 2> "$TMPD/plan.err" ||
    sfail "could not read the staged node_modules: $(strip < "$TMPD/plan.err" | grep . | tail -1)"
  if grep -q "^fail$tab" "$TMPD/plan"; then
    { sed -n "s/^fail$tab/  /p" "$TMPD/plan" | strip
      echo "  build on Linux instead: tando ci github (CI builds and deploys); docs/CROSS-ARCH.md"
    } > "$TMPD/plan.msg"
    sfail_lines "cannot swap the npm packages built for this machine for ones for linux $K_arch:" "$TMPD/plan.msg"
  fi
  while IFS=$tab read -r kind from dest name ver integ lock why; do
    case $kind in swap|drop) ;; *) continue;; esac
    { [ "$from" = - ] || native_path_ok "$from"; } && native_path_ok "$dest" || sfail "unexpected package path from lib/native.js: $from"
    if [ "$kind" = drop ]; then   # its Linux build is there already (or another one maps to it)
      rm -rf "${STAGE:?}/$from"
      printf '%s\t%s\t-\t%s\n' "$from" "${dest##*node_modules/}" "removed (the Linux build is installed beside it)" >> "$TMPD/swaps"
      continue
    fi
    native_name_ok "$name" || sfail "not an npm package name: $(printf '%s' "$name" | strip | cut -c1-80)"
    native_ver_ok "$ver" || sfail "$name: not an exact version: $(printf '%s' "$ver" | strip | cut -c1-80)"
    native_fetch "$name" "$ver" "$integ" "${lock#*:}"
    [ "$from" = - ] || rm -rf "${STAGE:?}/$from"
    rm -rf "${STAGE:?}/$dest"
    mkdir -p "$STAGE/$dest"
    tar -xzf "$TGZ" -C "$STAGE/$dest" --strip-components 1 || sfail "cannot unpack $TGZ"
    node "$njs" check "$STAGE/$dest" "$name" "$ver" > "$TMPD/chk" ||
      sfail "npm pack $name@$ver: $(strip < "$TMPD/chk" | head -1)"
    case $lock in
      found:*) lock="verified against ${lock#*:}";;
      absent:*) lock="not verified: ${lock#*:} has no entry for $name@$ver";;
      weak:*) lock="not verified: ${lock#*:} has only a sha1 for $name@$ver";;
      unsupported:*) lock="not verified: tando cannot read the checksums of ${lock#*:}";;
      *) lock="not verified: no lockfile";;
    esac
    [ "$from" = - ] && lock="$lock; $why"
    printf '%s\t%s\t%s\t%s\n' "$from" "$name" "$ver" "$lock" >> "$TMPD/swaps"
  done < "$TMPD/plan"
  local n; n=$(grep -c . "$TMPD/swaps")
  [ "$n" = 0 ] || SWAPPED="$(plural "$n" package) swapped"
}

# swap_lines: what was done to the native code of the release, one line per module (yellow when
# something is not verified), then the notes (Prisma)
swap_lines() {
  local from name ver how c tab=$'\t' l
  [ -s "$TMPD/swaps" ] || [ -s "$TMPD/native.notes" ] || return 0
  while IFS=$tab read -r from name ver how; do
    c=""; case $how in *"not verified"*) c=$UI_YELLOW;; esac
    if [ "$from" = - ]; then box_say "$c" "        added $name $ver, $how"
    elif [ "$ver" = - ]; then box_say "${c:-$UI_DIM}" "        $from: $how"
    else box_say "$c" "        swapped $from for $name $ver, $how"; fi
  done < "$TMPD/swaps"
  while IFS= read -r l; do box_say "$UI_DIM" "        $l"; done < "$TMPD/native.notes"
}

# the server's cpu and libc as npm names them: NCPU, NLIBC
native_target() {
  case $K_arch in x86_64) NCPU=x64;; aarch64|arm64) NCPU=arm64;; *) NCPU=$K_arch;; esac
  NLIBC=glibc; [ "${K_libc:-}" = musl ] && NLIBC=musl
}

# the project directory whose node_modules is the full copy (Next's standalone output holds less)
native_projdir() { if [ "${C_recipe:-}" = next ]; then echo .; else echo "${C_out:-.}"; fi; }

# the Node major of the server (what the downloaded binaries must fit)
native_nodemajor() {
  local v=${K_node:-}
  case ${v%%.*} in ""|*[!0-9]*) v=$(node_major 2> /dev/null || true);; esac
  printf '%s' "${v%%.*}"
}

# native_fix: after the platform packages are swapped, every package with native code must hold
# the server's binary. Packages that carry several platforms' binaries (prebuilds/) keep theirs and
# lose the others; a package Next's standalone output pruned is restored from the project's
# node_modules; one whose install script downloads its binary (prebuild-install, node-pre-gyp)
# gets the server's from the host its package.json declares; one that only compiles stops the
# deploy here, before anything is uploaded. Adds a line per module to $TMPD/swaps.
native_fix() {
  local kind rel a b c tab=$'\t' njs=$TANDO_HOME/lib/native.js proj nmaj
  [ -d "$STAGE/node_modules" ] || return 0
  command -v node > /dev/null || return 0
  native_target
  proj=$(native_projdir)
  nmaj=$(native_nodemajor)
  : > "$TMPD/fixed"; : > "$TMPD/pruned"
  native_fix_plan
  if grep -q "^fail$tab" "$TMPD/fix"; then   # before anything is fetched
    { while IFS=$tab read -r kind rel a b; do
        [ "$kind" = fail ] || continue
        echo "  $rel: $(printf '%s' "$a" | strip | cut -c1-80): $(printf '%s' "$b" | strip | cut -c1-200)"
      done < "$TMPD/fix"
      native_ways_out
    } > "$TMPD/fix.msg"
    sfail_lines "these packages cannot run on linux $K_arch without being compiled there:" "$TMPD/fix.msg"
  fi
  while IFS=$tab read -r kind rel a b c; do
    case $kind in
      restore)
        native_path_ok "$rel" && native_path_ok "$a" || sfail "unexpected package path from lib/native.js: $rel"
        native_name_ok "$b" && native_ver_ok "$c" || sfail "unexpected package from lib/native.js: $b"
        mkdir -p "$STAGE/$rel"
        rsync -a --delete --exclude=/node_modules "$proj/$a/" "$STAGE/$rel/" || sfail "cannot restore $rel from $proj/$a"
        printf '%s\t-\t-\t%s\n' "$rel" "restored from node_modules ($b $c; the standalone output had dropped its binary for linux-$NCPU)" >> "$TMPD/swaps"
        printf '%s\n' "$rel" >> "$TMPD/fixed";;
      prebuilt)
        native_path_ok "$rel" || sfail "unexpected package path from lib/native.js: $rel"
        native_name_ok "$a" && native_ver_ok "$b" || sfail "unexpected package from lib/native.js: $a"
        native_prebuilt "$rel" "$a" "$b" "$nmaj"
        printf '%s\n' "$rel" >> "$TMPD/fixed";;
      optional)
        printf '%s\t-\t-\t%s\n' "$rel" "not verified: $(printf '%s' "$a" | strip | cut -c1-200)" >> "$TMPD/swaps";;
      note)
        [ "$rel" = prisma ] && native_prisma_note "$a";;
    esac
  done < "$TMPD/fix"
  # binaries for other platforms beside the server's own go; each module gets its line
  native_fix_plan
  while IFS=$tab read -r kind rel a; do
    [ "$kind" = prune ] || continue
    native_path_ok "$a" || continue   # (the guard names a file that stays)
    rm -f "${STAGE:?}/$a"
    rmdir "$(dirname "$STAGE/$a")" 2> /dev/null || true
    printf '%s\n' "$a" >> "$TMPD/pruned"
  done < "$TMPD/fix"
  while IFS=$tab read -r kind rel a; do
    [ "$kind" = inside ] || continue
    native_path_ok "$rel" || continue
    grep -qxF "$rel" "$TMPD/fixed" && continue
    printf '%s\t-\t-\t%s\n' "$rel" "already inside the package ($a$(native_pruned_note "$rel"))" >> "$TMPD/swaps"
  done < "$TMPD/fix"
  # the final scan: every module has the server's binary now (the guard then looks at every file)
  native_fix_plan
  if grep -q -E "^(restore|prebuilt|fail)$tab" "$TMPD/fix"; then
    sfail "native code is still not right after the fixes (a bug in tando): $(grep -E "^(restore|prebuilt|fail)$tab" "$TMPD/fix" | head -1 | cut -d"$tab" -f2 | strip)"
  fi
  return 0
}
native_fix_plan() {
  node "$TANDO_HOME/lib/native.js" fix "$STAGE" "$NCPU" "$NLIBC" "$(native_projdir)" > "$TMPD/fix" 2> "$TMPD/fix.err" ||
    sfail "could not read the staged node_modules: $(strip < "$TMPD/fix.err" | grep . | tail -1)"
}

native_ways_out() {
  echo "what to do:"
  echo "  - build in CI on Linux, where these compile: tando ci github (GitHub Actions builds and deploys)"
  echo "  - or build in a Linux container (not available yet)"
  echo "  More: docs/CROSS-ARCH.md"
}

# ", N files for other platforms removed" for the package, from the files pruned in this stage
native_pruned_note() {
  local n
  n=$(grep -c "^$1/" "$TMPD/pruned" 2> /dev/null || true)
  [ "${n:-0}" -gt 0 ] && printf '; %s for other platforms removed' "$(plural "$n" file)"
  return 0
}

# native_prebuilt pkg name version node-major: the server's prebuilt binary, from where the
# package's own package.json says (lib/native.js checks the host and the archive)
native_prebuilt() {
  local rel=$1 name=$2 ver=$3 major=$4 kind url glibc why tab=$'\t' host how have
  [ -n "$major" ] || sfail "cannot tell the server's Node version (needed to pick $name's binary)"
  node "$TANDO_HOME/lib/native.js" prebuilt "$STAGE" "$rel" "$NCPU" "$NLIBC" "$major" "$TMPD/prebuilt.$RANDOM" \
    > "$TMPD/prebuilt.out" 2> "$TMPD/prebuilt.err" || sfail "downloading the binary of $name failed: $(strip < "$TMPD/prebuilt.err" | grep . | tail -1)"
  IFS=$tab read -r kind url glibc < "$TMPD/prebuilt.out"
  if [ "$kind" != ok ]; then
    why=$(printf '%s' "$glibc" | strip | cut -c1-240)
    { echo "  $rel $ver: $why"
      [ "$url" = refused ] && echo "  tando downloads only from the https host the package declares, and follows no redirects."
      native_ways_out
    } > "$TMPD/fix.msg"
    sfail_lines "the binary of $name for linux $K_arch cannot be downloaded:" "$TMPD/fix.msg"
  fi
  host=${url#*://}; host=${host%%/*}
  how="downloaded prebuilt for linux-$NCPU from $host (not verified by the lockfile)"
  if [ "$glibc" != - ]; then
    have=${K_glibc:-}
    if [ -z "$have" ]; then
      case $glibc in 2.[0-9]|2.[0-2][0-9]|2.30|2.31) ;; *)
        how="$how; needs glibc $glibc or newer: the server's tando does not report its glibc (tando host setup <host> updates it), so check it (Debian 12 has 2.36, Ubuntu 24.04 2.39)";;
      esac
    elif [ "$(printf '%s\n%s\n' "$glibc" "$have" | sort -t. -k1,1n -k2,2n | head -1)" != "$glibc" ]; then
      printf '  %s\n' "$rel needs glibc $glibc or newer, the server has $have" > "$TMPD/fix.msg"
      native_ways_out >> "$TMPD/fix.msg"
      sfail_lines "the prebuilt binary of $name does not fit this server:" "$TMPD/fix.msg"
    fi
  fi
  printf '%s\t-\t-\t%s\n' "$rel" "$how" >> "$TMPD/swaps"
}

# native_prisma_note version: one line, when Prisma is in the release
native_prisma_note() {
  case ${1%%.*} in
    [0-6]) printf '%s\n' "Prisma $1: its query engine is a binary; the guard says when it is for another platform (docs/CROSS-ARCH.md)";;
    *) printf '%s\n' "Prisma $1: nothing to swap; prisma migrate deploy on the server needs PRISMA_CLI_BINARY_TARGETS=$(native_prisma_target) and libssl3 (docs/CROSS-ARCH.md)";;
  esac >> "$TMPD/native.notes"
}

# the directory whose lockfile describes the staged node_modules
native_lockdir() {
  local d=. f
  [ "${C_recipe:-}" = next ] || d=${C_out:-.}
  for f in pnpm-lock.yaml yarn.lock bun.lock bun.lockb npm-shrinkwrap.json package-lock.json; do
    [ -f "$d/$f" ] && { printf '%s\n' "$d"; return 0; }
  done
  echo .
}

# what is put into an npm command or a path: checked here again, whatever lib/native.js said
native_name_ok() { # @scope/name or name: a-z 0-9 . _ -, starting with a letter or digit
  local n=$1 s l=abcdefghijklmnopqrstuvwxyz0123456789
  [ -n "$n" ] && [ ${#n} -le 214 ] || return 1
  case $n in
    @*/*) s=${n%%/*}; s=${s#@}; n=${n#*/}
          case $s in ""|[!$l]*|*[!$l._-]*) return 1;; esac;;
  esac
  case $n in ""|[!$l]*|*[!$l._-]*) return 1;; esac
}
native_ver_ok() { # 1.2.3 or 1.2.3-rc.1: no range, tag, URL or path
  local v=$1 core pre x n=0
  [ -n "$v" ] && [ ${#v} -le 64 ] || return 1
  core=${v%%-*}; pre=${v#"$core"}
  case $core in *[!0-9.]*|.*|*.|*..*) return 1;; esac
  for x in ${core//./ }; do
    n=$((n + 1))
    case $x in 0) ;; 0*|"") return 1;; esac
    [ ${#x} -le 9 ] || return 1
  done
  [ $n = 3 ] || return 1
  case $pre in
    "") ;;
    -*) pre=${pre#-}; case $pre in ""|*[!A-Za-z0-9.-]*|.*|*.|*..*) return 1;; esac;;
    *) return 1;;
  esac
}
native_path_ok() { # node_modules/.../name: plain names only, inside the stage
  case $1 in node_modules/*) ;; *) return 1;; esac
  case $1 in *[!A-Za-z0-9@._/+-]*|*//*|*/) return 1;; esac
  case /$1/ in */../*|*/./*) return 1;; esac
}

# native_fetch name version sha512|- lockfile: TGZ, the package's tarball, from .tando/cache or
# npm pack; checked against the lockfile's sha512 when there is one
native_fetch() {
  local name=$1 ver=$2 want=$3 lockf=$4 tgz d got njs=$TANDO_HOME/lib/native.js
  tgz=$CACHE/$(printf '%s' "$name" | tr '@/' '_+')-$ver.tgz   # (+ is in no package name: one file per name)
  mkdir -p "$CACHE" || sfail "cannot create $CACHE"
  got=""
  if [ -f "$tgz" ] && [ -f "$tgz.sha512" ]; then
    got=$(node "$njs" hash "$tgz")
    [ "$got" = "$(cat "$tgz.sha512")" ] || got=""
  fi
  if [ -z "$got" ]; then
    rm -f "$tgz" "$tgz.sha512"
    d=$TMPD/pack.$RANDOM; rm -rf "$d"; mkdir -p "$d"
    npm pack --ignore-scripts --silent --pack-destination "$d" -- "$name@$ver" > /dev/null 2> "$TMPD/npm" ||
      sfail "npm pack $name@$ver failed: $(strip < "$TMPD/npm" | grep . | tail -1)"
    set -- "$d"/*.tgz
    [ $# = 1 ] && [ -f "$1" ] || sfail "npm pack $name@$ver did not write one tarball"
    got=$(node "$njs" hash "$1") || sfail "cannot read the tarball of $name@$ver"
    mv "$1" "$tgz.tmp" && printf '%s\n' "$got" > "$tgz.sha512.tmp" &&
      mv "$tgz.tmp" "$tgz" && mv "$tgz.sha512.tmp" "$tgz.sha512" || sfail "cannot write $tgz"
    rm -rf "$d"
  fi
  if [ "$want" != - ] && [ "$got" != "$want" ]; then
    rm -f "$tgz" "$tgz.sha512"
    printf '  %s\n' "$lockf records $want" "the registry gave $got" \
      "The file npm fetched is not the one your lockfile recorded. Check the registry in your .npmrc" \
      "(a mirror or proxy), then deploy again; or build on Linux: tando ci github. docs/CROSS-ARCH.md" \
      > "$TMPD/mismatch"
    sfail_lines "$name@$ver does not match $lockf: not deployed" "$TMPD/mismatch"
  fi
  TGZ=$tgz
}

# ---- guard ---------------------------------------------------------------------------------

guard() {
  local bad l t d st_abs tab=$'\t'
  bad=$(find "$STAGE" \( -name '.env*' -o -name '.npmrc' \) | head -3)
  [ -z "$bad" ] || sfail "secret files in the release (.env* and .npmrc can hold tokens): $bad"
  st_abs=$(cd "$STAGE" && pwd -P)
  find "$STAGE" -type l > "$TMPD/links"
  while IFS= read -r l; do
    t=$(readlink "$l")
    case $t in /*) sfail "symlink to an absolute path: ${l#"$STAGE"/} -> $t";; esac
    d=$(cd "$(dirname "$l")" && cd "$(dirname "$t")" 2> /dev/null && pwd -P) ||
      sfail "dangling symlink: ${l#"$STAGE"/}"
    case "$d/" in "$st_abs"/*) ;; *) sfail "symlink leaves the release: ${l#"$STAGE"/} -> $t";; esac
  done < "$TMPD/links"
  # native code must be built for the server: every file that is not, then why and what to do
  find "$STAGE" -type f \( -name '*.node' -o -name '*.dylib' -o -name '*.so' -o -name '*.so.*' \) \
    > "$TMPD/native"
  : > "$TMPD/foreign"
  # a binary for another platform in prebuilds/ of a package that holds the server's own is not
  # one the loader picks (node-gyp-build, better-sqlite3 13, bcrypt 6, argon2): it is accepted
  : > "$TMPD/excused"
  if command -v node > /dev/null && [ -s "$TMPD/native" ]; then
    native_target
    node "$TANDO_HOME/lib/native.js" excused "$STAGE" "$NCPU" "$NLIBC" > "$TMPD/excused" 2> /dev/null || : > "$TMPD/excused"
  fi
  while IFS= read -r l; do
    grep -qxF "${l#"$STAGE"/}" "$TMPD/excused" && continue
    d=$(file -b "$l")
    case "$K_arch:$d" in
      x86_64:*ELF*x86-64*|aarch64:*ELF*aarch64*) ;;   # "ARM aarch64" also matches *aarch64*
      *) printf '%s\t%s\n' "${l#"$STAGE"/}" "$(printf '%s' "$d" | cut -d, -f1 | strip | cut -c1-60)" >> "$TMPD/foreign";;
    esac
  done < "$TMPD/native"
  [ -s "$TMPD/foreign" ] && guard_native
  return 0
}

# guard_native: the refusal for native files built for another platform ($TMPD/foreign: path,
# kind): which files, why tando could not make them fit, and what to do, for this recipe
guard_native() {
  local n p k m tab=$'\t' f=$TMPD/guard.msg
  n=$(grep -c . "$TMPD/foreign")
  {
    head -8 "$TMPD/foreign" | while IFS=$tab read -r p k; do echo "  $p ($k)"; done
    [ "$n" -le 8 ] || echo "  and $((n - 8)) more"
    echo "why, and what to do:"
    if grep -q -E '(^|/)node_modules/(@[^/]+/)?[^/@][^/]*/node_modules/' "$TMPD/foreign"; then
      p=$(sed -n -E 's#^(.*node_modules/(@[^/]+/)?[^/@][^/]*)/node_modules/.*#\1#p' "$TMPD/foreign" | head -1)
      echo "  - a nested copy under $p/node_modules: your package.json asks for another version of a"
      echo "    package than ${p##*/} does, so npm installed both. One version for both leaves one copy"
      echo "    (npm ls <package> shows who wants which)."
    fi
    if grep -q -i 'prisma\|query_engine\|schema-engine' "$TMPD/foreign"; then
      echo "  - Prisma downloads its engine for this machine at prisma generate: add the server's target to"
      echo "    the generator in schema.prisma (binaryTargets = [\"native\", \"$(native_prisma_target)\"]),"
      echo "    then prisma generate and deploy again."
    fi
    if grep -q '/build/Release/\|/prebuilds/\|better-sqlite3\|bcrypt\|canvas' "$TMPD/foreign"; then
      echo "  - a package compiled (or given a prebuilt binary) for this machine at npm install: it is not"
      echo "    a platform package tando can swap. It has to be installed on Linux."
    fi
    m=$(sed -n 's|.*node_modules/\(@[^/]*/[^/]*\)/.*|\1|p; s|.*node_modules/\([^@/][^/]*\)/.*|\1|p' "$TMPD/foreign" |
      grep -E -- '-(darwin|win32|freebsd|linux|linuxmusl)-' | sort -u | head -3 | tr '\n' ' ')
    if [ -n "$m" ]; then
      echo "  - platform packages tando could not swap (no package.json with os and cpu, or no package"
      echo "    beside them pins a Linux build): ${m% }"
    fi
    if [ "${C_recipe:-}" = next ] && grep -q 'sharp\|@img' "$TMPD/foreign"; then
      echo "  - Next.js: sharp only optimises next/image. Give sharp in your package.json the version Next"
      echo "    asks for (npm ls sharp), or set images: { unoptimized: true } in $(next_config | grep . || echo next.config.mjs)"
      echo "    when you do not need optimised images."
    fi
    echo "  - or build on Linux: tando ci github (GitHub Actions builds and deploys). More: docs/CROSS-ARCH.md"
  } > "$f"
  sfail_lines "native code built for another platform (the server is linux $K_arch):" "$f"
}
native_prisma_target() {
  case $K_arch:${K_libc:-} in
    aarch64:musl) echo linux-musl-arm64-openssl-3.0.x;; *:musl) echo linux-musl-openssl-3.0.x;;
    aarch64:*) echo linux-arm64-openssl-3.0.x;; *) echo debian-openssl-3.0.x;;
  esac
}
