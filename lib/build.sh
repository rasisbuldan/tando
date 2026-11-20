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

# npm ships native code as per-platform packages (@img/sharp-darwin-arm64, @next/swc-darwin-arm64,
# @esbuild/darwin-arm64, ...). Each one for another platform than the server's, at any depth of
# node_modules, is replaced in its own node_modules by the package for the server's platform, at
# the version the package beside it pins (lib/native.js finds them; docs/CROSS-ARCH.md lists the
# families). The tarball comes from `npm pack` (the registry npm is set up for here), is checked
# against the lockfile's sha512 when the lockfile has one (a mismatch stops the deploy), and is
# kept in .tando/cache beside its own sha512 (a cached file that changed is fetched again).
# Sets SWAPPED (the count for the stage line) and $TMPD/swaps: from, name, version, verified.
swap_native() {
  local cpu libc kind from dest name ver integ lock tab=$'\t' njs=$TANDO_HOME/lib/native.js
  SWAPPED=""; : > "$TMPD/swaps"
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
  while IFS=$tab read -r kind from dest name ver integ lock; do
    case $kind in swap|drop) ;; *) continue;; esac
    native_path_ok "$from" && native_path_ok "$dest" || sfail "unexpected package path from lib/native.js: $from"
    if [ "$kind" = drop ]; then   # its Linux build is there already (or another one maps to it)
      rm -rf "${STAGE:?}/$from"
      printf '%s\t%s\t-\t%s\n' "$from" "${dest##*node_modules/}" "removed (the Linux build is installed beside it)" >> "$TMPD/swaps"
      continue
    fi
    native_name_ok "$name" || sfail "not an npm package name: $(printf '%s' "$name" | strip | cut -c1-80)"
    native_ver_ok "$ver" || sfail "$name: not an exact version: $(printf '%s' "$ver" | strip | cut -c1-80)"
    native_fetch "$name" "$ver" "$integ" "${lock#*:}"
    rm -rf "${STAGE:?}/$from" "${STAGE:?}/$dest"
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
    printf '%s\t%s\t%s\t%s\n' "$from" "$name" "$ver" "$lock" >> "$TMPD/swaps"
  done < "$TMPD/plan"
  local n; n=$(grep -c . "$TMPD/swaps")
  [ "$n" = 0 ] || SWAPPED="$(plural "$n" package) swapped"
}

# swap_lines: one line per swapped package, for the deploy box (yellow when not verified)
swap_lines() {
  local from name ver how c tab=$'\t'
  [ -s "$TMPD/swaps" ] || return 0
  while IFS=$tab read -r from name ver how; do
    c=""; case $how in not*) c=$UI_YELLOW;; esac
    if [ "$ver" = - ]; then box_say "$UI_DIM" "        $from: $how"
    else box_say "$c" "        swapped $from for $name $ver, $how"; fi
  done < "$TMPD/swaps"
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
  # native code must be built for the server: every file that is not, then why and what to do
  find "$STAGE" -type f \( -name '*.node' -o -name '*.dylib' -o -name '*.so' -o -name '*.so.*' \) \
    > "$TMPD/native"
  : > "$TMPD/foreign"
  while IFS= read -r l; do
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
