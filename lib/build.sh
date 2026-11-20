# lib/build.sh: tando init, the build step, staging, the release guard, and swapping
# platform-specific npm packages (such as sharp) to the server's platform.

STAGE=.tando/stage
CACHE=.tando/cache

# ---- init ----------------------------------------------------------------------------------

next_config() { ls next.config.js next.config.mjs next.config.ts next.config.cjs 2> /dev/null | head -1; }

# the first file of a list that exists
first_file() { local f; for f; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }

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
  if [ -f package.json ] && grep -q '"next"[[:space:]]*:' package.json; then
    recipe=next build="npm run build" start="node server.js"
    cfg=$(next_config)
    if [ -n "$cfg" ]; then
      path=$(sed -n "s/.*basePath:[[:space:]]*['\"]\(\/[^'\"]*\)['\"].*/\1/p" "$cfg" | head -1)
    fi
  elif entry=$(first_file server.js index.js app.js main.js) || [ -f package.json ]; then
    recipe=node
    [ -f package.json ] && grep -q '"build"[[:space:]]*:' package.json && build="npm run build"
    if [ -n "$entry" ]; then start="node $entry"
    elif grep -q '"start"[[:space:]]*:' package.json; then start="npm start"
    else start="node server.js"; note "node: no server.js, index.js, app.js or main.js; check start"; fi
    node_port_hint "$entry"
  elif entry=$(first_file app.py main.py wsgi.py asgi.py) || [ -f requirements.txt ] || [ -f pyproject.toml ]; then
    recipe=python start="python ${entry:-app.py}"
    python_start "${entry:-app.py}"
    [ -f requirements.txt ] || note "python: no requirements.txt; the server builds the virtualenv from it"
    [ -n "$entry$shell" ] || note "python: no app.py, main.py, wsgi.py or asgi.py; check start"
  elif [ -f Dockerfile ]; then
    recipe=container
    note "container: the image is built here for the server's platform (docker or podman needed)"
    cport=$(dockerfile_port Dockerfile)
    [ -n "$cport" ] && note "container: the Dockerfile EXPOSEs $cport, so container_port = $cport"
  else
    recipe=static
    for out in dist public build .; do [ -f "$out/index.html" ] && break; done
    [ -f "$out/index.html" ] || die "cannot tell what this is: no package.json, Node or Python entry file," \
      "Dockerfile or index.html (tando recipes lists what each recipe looks for)"
  fi
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
    [ -n "$cport" ] && echo "container_port = $cport"
    [ -n "$path" ] && echo "path = $path"
    [ "$recipe" = next ] && echo "writable = .next/server/route-cache .next/server/app"
    echo "health = $health"
    [ "$recipe" = static ] || echo "memory = 256M"   # Caddy serves a static site: no process
    echo
    echo "# More settings (README.md lists them all). Change them, then: tando deploy"
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
    note "added  output: \"standalone\"  to $cfg"
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
    start="gunicorn -b 127.0.0.1:\$PORT $v.wsgi" pkg=gunicorn
  elif printf '%s' "$reqs" | grepq 'fastapi' || grepq 'FastAPI(' "$1" 2> /dev/null; then
    v=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=[[:space:]]*FastAPI(.*/\1/p' "$1" 2> /dev/null | head -1)
    start="uvicorn $m:${v:-app} --host 127.0.0.1 --port \$PORT" pkg=uvicorn
  elif printf '%s' "$reqs" | grepq 'flask' || grepq 'Flask(' "$1" 2> /dev/null; then
    v=$(sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=[[:space:]]*Flask(.*/\1/p' "$1" 2> /dev/null | head -1)
    start="gunicorn -b 127.0.0.1:\$PORT $m:${v:-app}" pkg=gunicorn
  else
    grep -q 'environ' "$1" 2> /dev/null ||
      note "python: listen on the port in os.environ[\"PORT\"] (tando gives the app one and blocks the others)"
    return 0
  fi
  shell=1
  note "python: start = $start (bound to the PORT tando gives the app)"
  printf '%s\n' "$reqs" | grepq "^$pkg" ||
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
  local ex=(--exclude=.git --exclude=.DS_Store '--exclude=.env*') out=${C_out:-.}
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

# npm ships native code as per-platform packages (@img/sharp-darwin-arm64, ...). Replace each
# one for this laptop's platform with the package for the server's platform, at the version the
# parent package pins in optionalDependencies. Tarballs are cached in .tando/cache.
swap_native() {
  local cpu os d name target ver tgz f
  case $K_arch in
    x86_64) cpu=x64;;
    aarch64|arm64) cpu=arm64;;
    *) cpu=$K_arch;;
  esac
  os=linux
  [ "$K_libc" = musl ] && os=linuxmusl
  [ -d "$STAGE/node_modules" ] || return 0
  find "$STAGE/node_modules" -maxdepth 2 -type d -name '*-darwin-*' > "$TMPD/plat"
  while IFS= read -r d; do
    name=${d#"$STAGE"/node_modules/}
    target=$(printf '%s' "$name" | sed "s/darwin-[a-z0-9]*/$os-$cpu/")
    ver=$(cat "$STAGE"/node_modules/*/package.json "$STAGE"/node_modules/@*/*/package.json 2> /dev/null |
      sed -n "s|.*\"$target\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*|\1|p" | head -1)
    [ -n "$ver" ] || sfail "$name is built for macOS and no package pins $target"
    mkdir -p "$CACHE"
    tgz="$CACHE/$(printf '%s' "$target" | tr '/@' '__')-$ver.tgz"
    if [ ! -f "$tgz" ]; then
      f=$(npm pack "$target@$ver" --pack-destination "$CACHE" --silent 2> "$TMPD/npm") ||
        sfail "npm pack $target@$ver failed: $(strip < "$TMPD/npm" | tail -1)"
      mv "$CACHE/$f" "$tgz"
    fi
    rm -rf "$d" "$STAGE/node_modules/$target"
    mkdir -p "$STAGE/node_modules/$target"
    tar -xzf "$tgz" -C "$STAGE/node_modules/$target" --strip-components 1 || sfail "cannot unpack $tgz"
    SWAPPED="${SWAPPED:+$SWAPPED, }${target#@*/}"
  done < "$TMPD/plat"
}

# ---- guard ---------------------------------------------------------------------------------

guard() {
  local bad l t d st_abs
  bad=$(find "$STAGE" -name '.env*' | head -3)
  [ -z "$bad" ] || sfail "secret files in the release: $bad"
  st_abs=$(cd "$STAGE" && pwd -P)
  find "$STAGE" -type l > "$TMPD/links"
  while IFS= read -r l; do
    t=$(readlink "$l")
    case $t in /*) sfail "symlink to an absolute path: ${l#"$STAGE"/} -> $t";; esac
    d=$(cd "$(dirname "$l")" && cd "$(dirname "$t")" 2> /dev/null && pwd -P) ||
      sfail "dangling symlink: ${l#"$STAGE"/}"
    case "$d/" in "$st_abs"/*) ;; *) sfail "symlink leaves the release: ${l#"$STAGE"/} -> $t";; esac
  done < "$TMPD/links"
  # native code must be built for the server
  find "$STAGE" -type f \( -name '*.node' -o -name '*.dylib' -o -name '*.so' -o -name '*.so.*' \) \
    > "$TMPD/native"
  while IFS= read -r l; do
    d=$(file -b "$l")
    case "$K_arch:$d" in
      x86_64:*ELF*x86-64*|aarch64:*ELF*aarch64*) ;;   # "ARM aarch64" also matches *aarch64*
      *) sfail "native code built for another platform (server is $K_arch): ${l#"$STAGE"/}";;
    esac
  done < "$TMPD/native"
}
