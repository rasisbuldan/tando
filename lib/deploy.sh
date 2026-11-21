# lib/deploy.sh: configure the app on the server, then deploy: build, stage, take the upload
# lease, upload, start the detached activation and follow its progress.

# send tando.conf settings to the server; creates the app on first use. configure check: only
# validate them and learn whether the app exists (K_exists, K_current), before anything is built
configure() {
  {
    [ "${1:-}" = check ] && printf 'check=1\n'
    # where this app is deployed from (TANDO_ORIGIN: the git hook builds in a temporary checkout)
    local o=${TANDO_ORIGIN:-$PWD}; o=${o%/.}; o=${o%/}
    printf 'origin=%s\n' "$(client_name):$o" | tr -d '\000-\037'
    printf '\n'
    [ -n "$FORCE" ] && printf 'force=1\n'
    printf 'recipe=%s\n' "${C_recipe:-node}"
    [ -n "$C_start" ] && printf 'start=%s\n' "$C_start"
    [ -n "$C_start_shell" ] && printf 'start_shell=%s\n' "$C_start_shell"
    [ -n "$C_release" ] && printf 'release=%s\n' "$C_release"
    [ -n "$C_release_shell" ] && printf 'release_shell=%s\n' "$C_release_shell"
    [ -n "$C_release_timeout" ] && printf 'release_timeout=%s\n' "$C_release_timeout"
    printf 'health=%s\nmemory=%s\n' "${C_health:-/}" "${C_memory:-256M}"
    [ -n "$C_timeout" ] && printf 'health_timeout=%s\n' "$C_timeout"
    # soak: seconds a new release must stay up after going live (TANDO_SOAK: tests use a short one)
    [ -n "${C_soak:-${TANDO_SOAK:-}}" ] && printf 'soak=%s\n' "${C_soak:-$TANDO_SOAK}"
    [ -n "$C_path" ] && printf 'path=%s\n' "$C_path"
    [ "${C_spa:-}" = true ] && printf 'spa=true\n'   # (an older agent knows no spa: sent only when on)
    [ -n "$C_data" ] && printf 'data=%s\n' "$C_data"
    if [ -n "$C_writable" ]; then printf 'writable=%s\n' "$C_writable"
    elif [ "$C_recipe" = next ]; then   # regenerated (ISR) pages: Next 16 and Next 14/15 locations
      printf 'writable=.next/server/route-cache .next/server/app\n'
    fi
    [ -n "$C_backup" ] && printf 'backup=%s\n' "$C_backup"
    [ -n "$C_database" ] && printf 'database=%s\n' "$C_database"
    [ -n "$C_image" ] && printf 'image=%s\n' "$C_image"
    [ -n "$C_container_port" ] && printf 'container_port=%s\n' "$C_container_port"
    [ -n "$C_build_memory" ] && printf 'build_memory=%s\n' "$C_build_memory"
    # limits (docs/COMMANDS.md "Limits and load"); C_* set by conf_load when tando.conf has them
    [ -n "${C_cpu:-}" ] && printf 'cpu=%s\n' "$C_cpu"
    [ -n "${C_tasks:-}" ] && printf 'tasks=%s\n' "$C_tasks"
    [ -n "${C_max_conns:-}" ] && printf 'max_conns=%s\n' "$C_max_conns"
    [ -n "${C_max_requests:-}" ] && printf 'max_requests=%s\n' "$C_max_requests"
    [ -n "${C_stop_timeout:-}" ] && printf 'stop_timeout=%s\n' "$C_stop_timeout"
    [ -n "${C_hold:-}" ] && printf 'hold=%s\n' "$C_hold"
    [ -n "${C_idle_stop:-}" ] && printf 'idle_stop=%s\n' "$C_idle_stop"
    [ -n "${C_assets:-}" ] && printf 'assets=%s\n' "$C_assets"
    [ "${C_compress:-}" = off ] && printf 'compress=off\n'   # (on is the default; an older agent knows no compress)
    [ -n "$C_job_timeout" ] && printf 'job_timeout=%s\n' "$C_job_timeout"
    [ -n "$C_job_spread" ] && printf 'job_spread=%s\n' "$C_job_spread"
    [ -n "$C_job_missed" ] && printf 'job_missed=%s\n' "$C_job_missed"
    printf '%s' "$C_jobs"
    printf '%s' "$C_workers"
    printf '%s' "$C_logs"
    [ -n "$C_domain" ] && printf 'domain=%s\n' "$C_domain"
    [ -n "$C_www" ] && printf 'www=%s\n' "$C_www"
  } > "$TMPD/settings"
  if [ "${1:-}" != check ] && [ -n "${BUSY_ID:-}" ]; then configure_wait
  else agent sudo configure "$APP" < "$TMPD/settings" > "$TMPD/cfg"; fi
  kv_read "$TMPD/cfg" link port created changed exists current needs node domains \
    busy busy_phase busy_left busy_soak conf
  # configure check: something holds the app now (a release soaking, a rollback, a backup); the
  # real configure waits for it, and configure_wait says so if it still does then
  if [ "${1:-}" = check ]; then
    BUSY_ID=$K_busy BUSY_PHASE=$K_busy_phase BUSY_LEFT=$K_busy_left BUSY_SOAK=$K_busy_soak BUSY_T=$(now)
  fi
}

# busy_text: what a call waits for, from busy=/busy_phase=/busy_left=/busy_soak= of the agent
# (BUSY_ID, BUSY_PHASE, BUSY_LEFT, BUSY_SOAK; BUSY_T: when BUSY_LEFT was measured). Sets BUSY_WHAT.
# Server values are checked before any arithmetic or display.
busy_text() {
  local left=""
  # (ui_int: no leading zeros, at most 18 digits, before any arithmetic on a server value)
  ui_int "$BUSY_SOAK" || BUSY_SOAK=30
  ui_int "$BUSY_LEFT" && ui_int "${BUSY_T:-}" && left=$(( BUSY_LEFT - ($(now) - BUSY_T) ))
  [ -n "$left" ] && [ "$left" -lt 1 ] && left=1
  valid_id "$BUSY_ID" || BUSY_ID=""
  case $BUSY_PHASE in
    soak) BUSY_WHAT="the soak of release $BUSY_ID (live, watched by the server)"
          [ -n "$left" ] && BUSY_WHAT="the soak of release $BUSY_ID: about $(ui_dur "$left") more";;
    rollback) if [ -n "$BUSY_ID" ]; then BUSY_WHAT="the rollback to $BUSY_ID to finish, up to about $(ui_dur "$BUSY_SOAK")"
              else BUSY_WHAT="the rollback of $APP to finish, up to about $(ui_dur "$BUSY_SOAK")"; fi;;
    copy|preflight|release|switch|verify|queued)
      BUSY_WHAT="release $BUSY_ID to finish activating ($BUSY_PHASE, then a soak of $(ui_dur "$BUSY_SOAK"))";;
    *) case ${BUSY_BY:-} in
         "a "[a-z]*|"an "[a-z]*|destroy) BUSY_WHAT="$BUSY_BY on $APP to finish";;
         *) BUSY_WHAT="another operation on $APP to finish (a backup, restore, env change or restart)";;
       esac;;
  esac
}

# configure_wait: the configure call when the app was busy at configure check. Once it has not
# answered within a second, one line says what it waits for and about how long (R2), then
# another how long it took; the server finishes the other operation first (lock 300 s at most)
configure_wait() {
  local pid i=0 t0 rc=0
  agent_raw sudo configure "$APP" < "$TMPD/settings" > "$TMPD/cfg" &
  pid=$!
  trap 'kill $pid 2> /dev/null; bail 130' INT TERM
  while kill -0 $pid 2> /dev/null && [ $i -lt 4 ]; do sleep 0.25; i=$((i + 1)); done
  if kill -0 $pid 2> /dev/null; then
    t0=$(now)
    busy_text
    box_say "$UI_DIM" "        waiting for $BUSY_WHAT"
    wait $pid || rc=$?
    [ $rc = 0 ] && box_say "$UI_DIM" "        waited $(ui_dur $(( $(now) - t0 + 1 ))); deploying"
  else
    wait $pid || rc=$?
  fi
  trap 'exit 130' INT TERM
  [ $rc = 0 ] || bail 1
}

# agent_wait [sudo] <verb> <app> [args]: `agent` for a verb that takes the app's lock (env set,
# start, restart, rollback, backup ...). When it has not answered within a second, it asks the
# server what holds the app (verb busy) and says so on stderr with about how long, instead of
# waiting in silence (a release soaking holds it up to its soak). stdin and stdout as `agent`.
# The asking runs beside the call (aw_watch), so the answer is taken the moment it arrives: a
# loop of 0.25 s sleeps here added up to a quarter of a second to every restart and rollback.
agent_wait() {
  local pid wpid rc=0 v=$1
  [ "$v" = sudo ] && v=$2
  cat > "$TMPD/aw.in"
  agent_raw "$@" < "$TMPD/aw.in" > "$TMPD/aw.out" &
  pid=$!
  aw_watch "$v" < /dev/null > /dev/null &
  wpid=$!
  trap 'kill $pid $wpid 2> /dev/null; bail 130' INT TERM
  wait $pid || rc=$?
  kill $wpid 2> /dev/null; wait $wpid 2> /dev/null
  trap 'echo >&2; exit 130' INT
  trap 'exit 143' TERM
  cat "$TMPD/aw.out"
  [ $rc = 0 ] || bail 1
}
# aw_watch verb: after 1 s, then every 2 s (at most 8 times), whether the call waits for the app's
# lock: only a call that waits says so (busy_waiting=1; an agent without that field: any holder),
# never one that is just slow (its own restart and health check hold the lock). Killed by
# agent_wait when the call ends: its sleep goes with it (no sleep left holding the caller's pipes)
aw_watch() {
  local q=0 sp=""
  trap '[ -n "$sp" ] && kill $sp 2> /dev/null; exit 0' TERM
  sleep 1 > /dev/null 2>&1 & sp=$!; wait $sp
  while [ $q -lt 8 ]; do
    q=$((q + 1))
    if ERRF=$TMPD/aw.err agent_raw sudo busy "$APP" < /dev/null > "$TMPD/aw.busy" 2> /dev/null; then
      kv_read "$TMPD/aw.busy" busy busy_phase busy_left busy_soak busy_waiting busy_by
      if [ -n "$K_busy" ] && [ "$K_busy_waiting" != 0 ]; then
        BUSY_ID=$K_busy BUSY_PHASE=$K_busy_phase BUSY_LEFT=$K_busy_left BUSY_SOAK=$K_busy_soak BUSY_T=$(now)
        BUSY_BY=$(printf '%s' "$K_busy_by" | tr -cd 'a-z -')
        busy_text
        note "tando: waiting for $BUSY_WHAT; then $1 runs"
        return 0
      fi
    fi
    sleep 2 > /dev/null 2>&1 & sp=$!; wait $sp
  done
}

# node_major: the Node.js major this project asks for: node = in tando.conf, .nvmrc, or
# engines.node in package.json; else the current LTS the server would install
node_major() {
  local v=$C_node n
  if [ -z "$v" ] && n=$(first_file .nvmrc .node-version); then
    v=$(tr -d ' v\r' < "$n" | head -1); v=${v%%.*}
    case $v in lts*|node|"") v="";; esac
  fi
  if [ -z "$v" ] && [ -f package.json ]; then
    n=$(tr -d '\n' < package.json | sed -n 's/.*"engines"[^}]*"node"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    v=$(printf '%s' "$n" | grep -o '[0-9][0-9]' | head -1)
    case $n in *">"*) [ -n "$v" ] && [ "$v" -le "$NODE_LTS" ] && v=$NODE_LTS;; esac
  fi
  case $v in [0-9][0-9]) printf '%s' "$v";; *) printf '%s' "$NODE_LTS";; esac
}
NODE_LTS=24

# runtimes: install what the app needs on the server before the first deploy (Node at the version
# the project asks for, python3-venv, podman, postgres). Once per server; later apps find them
runtimes() {
  local r ver
  for r in $K_needs; do
    ver=""; [ "$r" = node ] && ver=$(node_major)
    note "installing ${r}${ver:+ $ver} on $HOST (the first app that needs it; up to a minute)..."
    agent sudo runtime "$r" ${ver:+"$ver"} < /dev/null > "$TMPD/rt"
    note "  $(sed -n 's/^detail=//p' "$TMPD/rt")"
  done
  case $C_recipe in node|next) ;; *) return 0;; esac
  if [ -n "$K_node" ] && [ "${K_node%%.*}" != "$(node_major)" ]; then
    note "note: $HOST runs Node $K_node, this project asks for $(node_major)" \
      "(one Node per server; node = ${K_node%%.*} in tando.conf silences this)"
  fi
  return 0
}

# one line when the host's agent was installed by another client version
version_notice() {
  local mine
  mine=$(cat "$TANDO_HOME/VERSION" 2> /dev/null) || return 0
  [ -n "$1" ] && [ "$1" != "$mine" ] &&
    note "tando: host $HOST runs agent $1, this client is $mine: tando host setup $HOST updates it"
  return 0
}

# PHASES: the server's phases in the deploy box, after build, stage and upload (1 to 3); with a
# release command in tando.conf, `release` between pre-flight and switch (8 steps instead of 7)
PHASES="copy preflight switch verify" PH_TOTAL=7
phases_init() {
  PHASES="copy preflight switch verify" PH_TOTAL=7
  [ -z "$C_release" ] || { PHASES="copy preflight release switch verify"; PH_TOTAL=8; }
}
phase_line() { # n label state seconds [detail]
  local d=""
  [ -n "$4" ] && d=$(ui_dur "$4")
  ui_step "$1" "$PH_TOTAL" "$2" "$3" "$d${5:+  $5}"
}

# client name shown to a second deploy that finds the upload lease taken
client_name() { printf '%s@%s' "$(id -un)" "$(hostname -s)" | tr -cd 'A-Za-z0-9_.@-' | cut -c1-64; }

# lease_giveback file: `end` with the token in that file (token=<t> or the token on its first
# line), if it has one; quiet (the failure that led here was already told)
lease_giveback() {
  local t; t=$(sed -n '1s/^token=//; 1p' "$1" 2> /dev/null)
  case $t in ""|*[!a-f0-9-]*) return 0;; esac
  printf '%s\n' "$t" | ERRF=$TMPD/err.end agent_raw sudo end "$APP" > /dev/null 2>&1
  return 0
}

upload() { # sets UPLOAD_SECS, UPLOAD_FILES, UPLOAD_BYTES, TOKEN
  local t0
  # (with its size, so a server refuses an upload over its per-app limit before it is sent; a
  # deploy key's gate takes no size)
  local kb=""; [ -n "${DEPLOY_KEY:-}" ] || kb=$(du -sk "$STAGE" 2> /dev/null | awk '{ print $1 }')
  # (a begin that failed after it printed the token may have written the lease: given back)
  if ! agent_raw sudo begin "$APP" "$(client_name)" ${kb:+"$kb"} > "$TMPD/lease"; then
    lease_giveback "$TMPD/lease"; bail 1
  fi
  kv_read "$TMPD/lease" token upload_as
  TOKEN=$K_token
  case $TOKEN in ""|*[!a-f0-9-]*) die "agent returned no upload token";; esac
  printf '%s\n' "$TOKEN" > "$TMPD/token"
  # after `tando ci setup` the app's incoming/ belongs to its deploy user; the admin writes as it
  local rp=()
  # (through tando-gate's confined receiver: it cannot write outside incoming/, whatever is there)
  case $K_upload_as in tando-d-"$APP") rp=(--rsync-path="sudo -n /opt/tando/bin/tando-gate admin receive $APP rsync");; esac
  trap 'agent_raw sudo end "$APP" < "$TMPD/token" > /dev/null 2>&1; bail 130' INT TERM
  t0=$(clock)
  ssh_wrapper   # (rsync splits -e on spaces: the host's options go in a script, quoted)
  if ! rsync -rlptz -c --delete --stats ${rp[@]+"${rp[@]}"} -e "$SSH_WRAPPER" "$STAGE/" \
       "$TARGET:/opt/tando/apps/$APP/incoming/" > "$TMPD/rsync" 2>&1; then
    agent_raw sudo end "$APP" < "$TMPD/token" > /dev/null 2>&1
    phase_line 3 upload fail ""
    if grep -q 'No space left on device\|Disk quota exceeded' "$TMPD/rsync"; then
      box_say "$UI_RED" "$HOST ran out of disk space during the upload"
      box_say "" "  free space: tando doctor -H $HOST; the upload is" \
        "$(ui_bytes "$(du -sk "$STAGE" | awk '{print $1 * 1024}')")"
      ui_box_close "nothing was deployed"
      exit 1
    fi
    if ssh_explain "$TMPD/rsync" 2> "$TMPD/expl"; then
      while IFS= read -r l; do box_say "" "$l"; done < "$TMPD/expl"
    else
      box_say "$UI_RED" "the upload to $HOST failed; rsync said:"
      # its error lines, not its statistics (which follow them)
      { strip < "$TMPD/rsync" | grep -i 'rsync\|error\|failed\|denied\|vanished\|No such' | grep -v '^Total\|^Number of\|^File list' |
          tail -4 | grep . || strip < "$TMPD/rsync" | grep . | tail -3; } |
        while IFS= read -r l; do box_say "" "  $l"; done
    fi
    ui_box_close "nothing was deployed"
    exit 1
  fi
  UPLOAD_SECS=$(since "$t0")
  # openrsync: "Total sent: 123"; GNU rsync 3.x (CI runners): "Total bytes sent: 1,234"
  UPLOAD_BYTES=$(sed -n 's/^Total \(bytes \)\{0,1\}sent: \([0-9,]*\).*/\2/p' "$TMPD/rsync" | tr -d ,)
  UPLOAD_FILES=$(sed -n 's/^Number of \(regular \)\{0,1\}files transferred: \([0-9,]*\).*/\2/p' "$TMPD/rsync" | tr -d ,)
}

# show the server phases that finished since the last poll
show_phases() {
  local ph n t
  n=4
  for ph in $PHASES; do
    case " $SHOWN " in *" $ph "*) n=$((n + 1)); continue;; esac
    case $ph in
      copy) t=$K_t_copy;; preflight) t=$K_t_preflight;; release) t=$K_t_release;;
      switch) t=$K_t_switch;; verify) t=$K_t_verify;;
    esac
    [ -n "$t" ] || return 0
    # verify is shown once the result is final (a failed verify is followed by a rollback)
    [ "$ph" = verify ] && [ "$K_result" = running ] && return 0
    # a failed pre-flight writes its time a moment before its result: wait for one or the other
    [ "$ph" = preflight ] && [ "$K_result" = running ] && [ "$K_phase" = preflight ] && return 0
    # (a failed deploy: the last phase with a time is the one that failed)
    if { [ "$K_result" = failed ] && [ "$ph" = preflight ] && [ -z "$K_t_release" ]; } ||
       { [ "$K_result" = failed ] && [ "$ph" = release ]; } ||
       { [ "$K_result" = rolledback ] && [ "$ph" = verify ]; }; then
      phase_line $n $ph fail "$t"
    else
      phase_line $n $ph ok "$t"
      phase_after "$ph"
    fi
    SHOWN="$SHOWN $ph"
    n=$((n + 1))
  done
}

# target_guard: this checkout deploys where it did last time. A tando.conf that now names another
# app or server (an edit, a pull, a pull request) asks once (--yes or --force: go on)
target_guard() {
  local last="" want="$HOST $APP $PWD" a
  [ -n "${DEPLOY_KEY:-}" ] && return 0
  [ -f .tando/target ] && last=$(cat .tando/target 2> /dev/null)
  # (the server renamed since: tando host rename left its old name as an alias of this one)
  case $last in "$HOST "*|"") ;; *) [ ! -f "$CFG/hosts/${last%% *}" ] && [ "$(host_alias "${last%% *}")" = "$HOST" ] && last="$HOST ${last#* }";; esac
  # (a copy of the directory elsewhere is a new project: only the same path counts)
  if [ -n "$last" ] && [ "${last#* * }" = "$PWD" ] && [ "$last" != "$want" ] && [ -z "$YES$FORCE" ]; then
    last=${last% "$PWD"}
    note "this directory last deployed ${last#* } to ${last%% *}; tando.conf now says ${APP} on ${HOST}."
    if [ -t 0 ]; then
      printf 'Deploy %s to %s? [y/N] ' "$APP" "$HOST" >&2; IFS= read -r a || a=""
      case $a in y|Y|yes) ;; *) die "not deployed";; esac
    else
      die "not deployed: check tando.conf, then run again with --yes"
    fi
  fi
  mkdir -p .tando && printf '%s\n' "$want" > .tando/target
}

# dir_lock: one deploy at a time from a project directory (both would build into .tando/stage).
# A directory .tando/deploy.lock holds the pid; a lock whose process is gone is taken over. It is
# not removed at exit (no trap to spare): the next deploy finds the pid dead.
dir_lock() {
  local l=.tando/deploy.lock p n=0
  mkdir -p .tando
  # mkdir is the atomic step: whoever creates the directory holds the lock. A directory without a
  # pid yet belongs to a deploy that is just starting (wait for it to write one); a pid that is
  # gone is a stale lock, moved away by exactly one taker (dir_unstale).
  while ! mkdir "$l" 2> /dev/null; do
    p=$(cat "$l/pid" 2> /dev/null)
    if is_num "$p"; then
      [ "$p" = $$ ] && break
      if kill -0 "$p" 2> /dev/null; then
        die "another tando deploy is running in this directory (pid $p); wait for it, or run this one from another checkout"
      fi
      dir_unstale "$l" "$p"
    else
      n=$((n + 1))
      if [ "$n" -gt 30 ]; then dir_unstale "$l" ""; n=0; fi
      sleep 0.1
    fi
  done
  printf '%s\n' $$ > "$l/pid"
}
# dir_unstale lock pid: moves the lock away while it still holds that pid (the dead one). Two
# deploys that found it dead at once do this one after the other (the directory lock.break), so
# the second one sees the first one's pid and leaves its lock alone. A lock.break left by a deploy
# killed in these few lines is cleared after a minute.
dir_unstale() {
  if ! mkdir "$1.break" 2> /dev/null; then
    [ -n "$(find "$1.break" -maxdepth 0 -mmin +1 2> /dev/null)" ] && rmdir "$1.break" 2> /dev/null
    sleep 0.1; return 0
  fi
  [ "$(cat "$1/pid" 2> /dev/null)" = "$2" ] && mv "$1" "$1.stale.$$" 2> /dev/null && rm -rf "$1.stale.$$"
  rmdir "$1.break" 2> /dev/null
  return 0
}

# node_install: the command that installs a Node project's dependencies when node_modules is
# missing (a fresh clone), "" when nothing is to install, by the project's lockfile. Runs before
# anything else of a deploy: tando deploy (and --dry-run) stops here with the command to run
# (it does not change the project's tree); tando up and the pre-push hook's temporary checkout
# (TANDO_ORIGIN) install them. Fails with the exact fix when the command is not installed.
node_install() {
  NODE_INSTALL=""
  [ -f package.json ] || return 0
  # (a static site built from package.json, like Vite or Astro, needs them for its build)
  case $C_recipe in node|next) ;; static) [ -n "$C_build" ] || return 0;; *) return 0;; esac
  # "dependencies" or "devDependencies": { } with at least one entry
  tr -d '\n' < package.json | grepq -E '"(dependencies|devDependencies)"[[:space:]]*:[[:space:]]*\{[[:space:]]*"' || return 0
  yarn_pnp
  ws_member_check
  NODE_INSTALL_DIR=""
  if ws_member; then   # a package of a workspace: the workspace is installed at its root
    [ -d "$WS_ROOT/node_modules" ] && return 0
    NODE_INSTALL=$(ws_install) NODE_INSTALL_DIR=$WS_UP
  elif [ -d node_modules ]; then return 0
  elif [ -f pnpm-lock.yaml ]; then NODE_INSTALL="pnpm install --frozen-lockfile"
  elif [ -f yarn.lock ] && [ -f .yarnrc.yml ]; then NODE_INSTALL="yarn install --immutable"   # (Yarn 2+)
  elif [ -f yarn.lock ]; then NODE_INSTALL="yarn install --frozen-lockfile"
  elif [ -f bun.lock ] || [ -f bun.lockb ]; then NODE_INSTALL="bun install --frozen-lockfile"
  elif [ -f package-lock.json ] || [ -f npm-shrinkwrap.json ]; then NODE_INSTALL="npm ci"
  else NODE_INSTALL="npm install"; fi
  if [ -z "${UP:-}${TANDO_ORIGIN:-}" ] || [ -n "${DRY_RUN:-}" ]; then
    local again="tando deploy"; [ -z "${DRY_RUN:-}" ] || again="tando deploy --dry-run"
    die "node_modules is missing (a fresh clone?): run $NODE_INSTALL${NODE_INSTALL_DIR:+ in $NODE_INSTALL_DIR} first, then $again" \
      "(tando up runs it for you)"
  fi
  # pnpm and Yarn 2+ come with Node as corepack shims: used when the command itself is not installed
  case $NODE_INSTALL in pnpm*|"yarn install --immutable")
    command -v "${NODE_INSTALL%% *}" > /dev/null || ! command -v corepack > /dev/null || NODE_INSTALL="corepack $NODE_INSTALL";;
  esac
  command -v "${NODE_INSTALL%% *}" > /dev/null ||
    die "package.json lists dependencies but node_modules is missing, and ${NODE_INSTALL%% *} is not installed here: install Node.js, then run $NODE_INSTALL"
}

# yarn_pnp: Yarn 2+ with Plug'n'Play has no node_modules, which is what tando ships
yarn_pnp() {
  [ -f .yarnrc.yml ] || return 0
  grep -q '^nodeLinker:[[:space:]]*["'"'"']*\(node-modules\|pnpm\)' .yarnrc.yml && return 0
  die "Yarn Plug'n'Play: tando ships node_modules, which PnP does not make." \
    "
  Add  nodeLinker: node-modules  to .yarnrc.yml, run yarn install,
  then deploy again"
}

# next_standalone: Next.js must build with output: "standalone" (tando ships .next/standalone).
# Checked before the build; with --yes or a yes at the terminal, the line is added to next.config
next_standalone() {
  local cfg re="output:[[:space:]]*['\"]standalone['\"]"
  [ "$C_recipe" = next ] || return 0
  cfg=$(next_config)
  [ -n "$cfg" ] && grep -q "$re" "$cfg" && return 0
  # (lib/build.sh) asks, or with --yes edits the real file or writes next.config.mjs
  if [ -z "${DRY_RUN:-}" ] && { [ -n "$YES" ] || [ -t 0 ]; }; then init_next; fi
  cfg=$(next_config)
  [ -n "$cfg" ] && grep -q "$re" "$cfg" && return 0
  die "Next.js needs  output: \"standalone\"  in ${cfg:-next.config.mjs}: tando ships .next/standalone, the" \
    "files the server needs (a small app: 56 MB and 1,900 files, against 360 MB and 9,000 with next start" \
    "and all of node_modules). Add it inside its config object, or run tando up --yes to let tando add it"
}
# next_add_standalone file: one line after the opening of the config object (create-next-app's
# "const nextConfig: NextConfig = {", "module.exports = {" or "export default {")
next_add_standalone() {
  awk 'done != 1 && /(nextConfig[^=]*=|module\.exports[[:space:]]*=|export default)[[:space:]]*\{[[:space:]]*$/ {
         print; print "  output: \"standalone\","; done = 1; next } { print } END { exit done != 1 }' \
    "$1" > "$1.tando-tmp" || { rm -f "$1.tando-tmp"; return 1; }
  mv "$1.tando-tmp" "$1"
}

# fail_report: why a release did not go live, plain words first: what it means and the fix
# (wrapped, never cut), then the server's message, then a few lines of the app's own output
# (systemd's and podman's own lines dropped), then where the rest is
fail_report() {
  local f=$TMPD/crash l w n=7 port exp=""
  grep '^log=' "$TMPD/ds" | sed 's/^log=//' |
    grep -v 'systemd\[[0-9]*\]\|^tando-[a-z0-9-]*\.service: \|Started tando-\|Stopped tando-' |
    grep -v 'Deactivated successfully\|Consumed .* CPU time' |
    grep -v -E ' container (create|init|start|attach|died|remove|cleanup|stop|kill) |image pull|^Trying to pull' |
    grep -v -E '^Getting image source|^Copying (blob|config)|^Writing manifest|^Storing signatures' > "$f"
  port=${K_port:-}; [ -n "$port" ] || port=$(sed -n 's/^port=//p' "$TMPD/cfg" 2> /dev/null)
  local y=$UI_YELLOW
  if grep -q 'EADDRINUSE\|EACCES\|EPERM\|address already in use\|Permission denied\|Operation not permitted' "$f" &&
     { grep -qi 'listen\|bind' "$f" || [ "$C_recipe" = python ]; }; then
    box_say "$y" "the app listens on a fixed port; tando gives it one in PORT and blocks the others."
    case $C_recipe in
      python) box_say "$y" "  fix: bind to os.environ[\"PORT\"] (Flask/FastAPI: start = gunicorn" \
                "-b 127.0.0.1:\$PORT app:app with start_shell = true), then deploy again";;
      container) box_say "$y" "  fix: set container_port = <the port the image listens on> in tando.conf";;
      *) box_say "$y" "  fix: listen on process.env.PORT instead of a number, then deploy again";;
    esac
  elif grep -q 'EROFS\|Read-only file system' "$f"; then
    l=$(grep -o "path: '[^']*'\|'[^']*'\$" "$f" | head -1)
    box_say "$y" "the app wrote into its release${l:+ ($l)}, which is read-only."
    box_say "$y" "  fix: data = data in tando.conf, then write to \$TANDO_DATA_DIR"
  elif l=$(env_missing "$f") && [ -n "$l" ]; then
    box_say "$y" "the app needs the environment variable $l, which is not set on $HOST."
    box_say "$y" "  fix: tando env set $l=... (or tando env import .env), then deploy again"
  elif grep -q "MODULE_NOT_FOUND\|Cannot find module\|ERR_MODULE_NOT_FOUND" "$f"; then
    l=$(grep -o "Cannot find \(module\|package\) '[A-Za-z0-9@_./+-]*'" "$f" | head -1)
    case $l in
      *" '."*|*" '/"*)   # a path, not a package: a file of the project that was not uploaded
        l=${l#*\'}; l=${l%\'}
        case $l in /opt/tando/apps/*/releases/*) l=./${l#/opt/tando/apps/*/releases/*/};; esac
        box_say "$y" "the file $l is not in the release that was uploaded (it is imported by path)."
        box_say "$y" "  fix: make sure it exists in ${C_out:-the project directory} here (a generated file needs" \
          "build = ... in tando.conf; .env* files are never uploaded), then deploy again";;
      *)
        box_say "$y" "${l:-a module is missing}: tando uploads node_modules as it is here."
        box_say "$y" "  fix: npm install, then deploy again";;
    esac
  elif grep -q "ModuleNotFoundError\|No module named" "$f"; then
    box_say "$y" "a Python module is missing: add it to requirements.txt, then deploy again"
  elif [ "$C_recipe" = python ] && l=$(grep -o -E '(^|[ :])[A-Za-z0-9_.-]+: (command )?not found' "$f" | head -1) && [ -n "$l" ]; then
    l=${l%%: *}; l=${l##*[ :]}
    box_say "$y" "$l is not installed in the app's virtualenv (the server builds it from requirements.txt)."
    box_say "$y" "  fix: add $l to requirements.txt, then tando up"
  else
    case $C_recipe:$K_message in
      container:*"connection refused"*|container:*"empty reply"*|container:*"no answer within"*)
        [ -f "${C_dockerfile:-Dockerfile}" ] && exp=$(dockerfile_port "${C_dockerfile:-Dockerfile}")
        if [ -n "$exp" ] && [ "$exp" != "${C_container_port:-8080}" ]; then
          box_say "$y" "nothing answered on container_port ${C_container_port:-8080}; the Dockerfile EXPOSEs $exp."
          box_say "$y" "  fix: container_port = $exp in tando.conf, then deploy again"
        else
          box_say "$y" "nothing answered on container_port ${C_container_port:-8080}:" \
            "set container_port = <the port the image listens on>"
        fi;;
      static:*) ;;
      *:"pre-flight: no healthy answer"*"connection refused"*)
        box_say "$y" "the app is running but does not listen on the port tando gave it (PORT=$port)."
        box_say "$y" "  fix: listen on process.env.PORT (Node) or os.environ[\"PORT\"] (Python), then deploy again";;
      *) n=10;;
    esac
  fi
  [ -n "$K_message" ] && box_say "$UI_RED" "$K_message"
  [ -s "$f" ] || return 0
  [ $n = 10 ] || n=3   # a known cause: the first error line and two after it are enough
  l=$(grep -n -m1 -E 'Error|Exception|Traceback|panic|ERR!|error:|fatal' "$f" | cut -d: -f1)
  [ -n "$l" ] || l=$(( $(grep -c . "$f") - n + 1 ))
  [ "$l" -ge 1 ] 2> /dev/null || l=1
  w=$(( ${UI_W:-80} - 6 ))
  sed -n "$l,$((l + n - 1))p" "$f" | cut -c1-400 | fold -w "$w" | head -$((n + 2)) |
    while IFS= read -r l; do ui_box_line "  ${UI_DIM}$l${UI_NC}"; done
}

# env_missing file: the name of an environment variable the app's output says is missing
# (Python KeyError on os.environ, "X is not set/required/missing", "missing env var X"); only
# [A-Z0-9_] names reach the screen
env_missing() {
  { sed -n -E "s/.*KeyError: '([A-Z][A-Z0-9_]{2,63})'.*/\1/p" "$1"
    sed -n -E 's/^(.*[^A-Za-z0-9_])?([A-Z][A-Z0-9_]{2,63})[^A-Za-z0-9_ ]* (is not set|is not defined|is required|is missing|must be set|not set|is undefined).*/\2/p' "$1"
    sed -n -E 's/.*([Mm]issing|[Rr]equired) (env(ironment)? )?(var(iable)?|key|setting)s?:? *[`"'"'"']?([A-Z][A-Z0-9_]{2,63}).*/\6/p' "$1"
  } 2> /dev/null | grep -v -E '^(PATH|HOME|NODE_ENV|ERR|ENOENT|EACCES|EPERM|MODULE_NOT_FOUND)$' | head -1
}

# dockerfile_port file: the first port the Dockerfile EXPOSEs ("" when none)
dockerfile_port() {
  awk 'toupper($1) == "EXPOSE" { p = $2; sub(/\/.*/, "", p); if (p ~ /^[0-9]+$/) { print p; exit } }' "$1" 2> /dev/null
}

do_deploy() { # needs resolve 1; with UP=1 the app is created (after the build) when missing
  local t0 id ph n l existed=1 current=""
  BUILD_SECS=0 BUILD_SUMMARY="" STAGE_NOTE="" SWAPPED="" VENV_SHOWN="" STARTED=""
  # Next.js without standalone output is refused (or fixed with --yes) before anything is installed
  next_standalone
  # a fresh clone: before anything is asked of the server (tando up installs the dependencies)
  node_install
  agent info > "$TMPD/info"
  proto_check "$TMPD/info"
  kv_read "$TMPD/info" arch libc version glibc dswait
  version_notice "$K_version"
  # deploy-status wait=<phase> (below): always for an admin (an agent without it ignores the word);
  # through a deploy key's gate only when it says it takes it (an older gate refuses the call)
  DSWAIT=1; [ -z "${DEPLOY_KEY:-}" ] || [ "$K_dswait" = 1 ] || DSWAIT=""
  if [ "$C_recipe" = container ] && [ -z "$C_image" ]; then
    ENGINE=$(command -v docker || command -v podman) ||
      die "the container recipe builds the image here: install docker or podman, or set image = <name>"
  fi
  # tando.conf is checked by the server before anything is built (a deploy key cannot change it:
  # it deploys with the settings of the admin's last tando up)
  if [ -z "${DEPLOY_KEY:-}" ]; then
    configure check
    existed=$K_exists current=$K_current
    # (a dry run installs nothing on the server: it says what tando up or deploy would install)
    if [ -n "${DRY_RUN:-}" ]; then
      [ -z "$K_needs" ] || note "dry run: the deploy would install $K_needs on $HOST first"
    else
      runtimes
    fi
    # domains of tando.conf the app does not have yet: DNS first, before anything is built
    NEW_DOMAINS=""
    local d
    [ -z "${DRY_RUN:-}" ] || C_domain=""   # (domains: tando domain add checks their DNS)
    for d in $C_domain; do
      case ",$K_domains," in *",$d,"*) ;; *) NEW_DOMAINS="$NEW_DOMAINS $d";; esac
    done
    # a domain whose DNS is not right yet never holds up the code: it is left out of this deploy
    # and its records are printed at the end (tando domain add <d> --wait is the blocking path)
    DNS_LATER=""
    if [ -n "$NEW_DOMAINS" ]; then
      . "$TANDO_HOME/lib/cmd-domain.sh"
      server_addrs
      local ok=""
      for d in $NEW_DOMAINS; do
        if FORCE="" DNS_WAIT="" domain_dns "$d" "${C_www:-$(default_www "$d")}" 2> /dev/null; then ok="$ok $d"
        else DNS_LATER="$DNS_LATER $d"; cp "$TMPD/dns" "$TMPD/dns.$d"; fi
      done
      NEW_DOMAINS=$ok
      ok=""   # configure gets every domain of tando.conf except those
      for d in $C_domain; do case " $DNS_LATER " in *" $d "*) ;; *) ok="$ok $d";; esac; done
      C_domain=${ok# }
    fi
    if [ -n "${DRY_RUN:-}" ] && [ "$existed" != 1 ]; then
      note "dry run: $APP is not on $HOST yet (tando up creates it); building and staging it here, creating nothing there"
    fi
    [ "$existed" = 1 ] || [ -n "${UP:-}" ] || [ -n "${DRY_RUN:-}" ] ||
      die "$APP is not on $HOST (never created, or destroyed): tando up creates it"
  fi
  [ -n "${DRY_RUN:-}" ] || target_guard   # (a dry run deploys nowhere: the last target stays)
  dir_lock
  phases_init
  ui_box_open "${DRY_RUN:+dry run: }deploy $APP" "$HOST"
  t0=$(clock)

  if [ -n "$NODE_INSTALL" ]; then
    local ti lock=""; ti=$(clock)
    [ -f package-lock.json ] || [ "$NODE_INSTALL" != "npm install" ] || lock=", created package-lock.json"
    if ! (cd "${NODE_INSTALL_DIR:-.}" && $NODE_INSTALL) > "$TMPD/build.log" 2>&1; then
      phase_line 1 build fail "$(since "$ti")"
      box_say "$UI_RED" "node_modules was missing and $NODE_INSTALL failed here:" \
        "run it yourself to see why, then deploy again"
      strip < "$TMPD/build.log" | grep . | tail -10 | while IFS= read -r l; do ui_box_line "  $l"; done
      ui_box_close "dependencies could not be installed; nothing was uploaded"
      exit 1
    fi
    local where=here; [ -z "$NODE_INSTALL_DIR" ] || where="in $NODE_INSTALL_DIR"
    box_say "" "        installed dependencies: $NODE_INSTALL, $where" \
      "(node_modules was missing$lock; $(ui_dur "$(since "$ti")"))"
  fi
  needs_build && step_start "build: running ${C_build:-$ENGINE build} here"
  if ! needs_build; then
    phase_line 1 build skip "" "nothing to build (no build in tando.conf)"
  elif run_build; then
    phase_line 1 build ok "$BUILD_SECS" "$BUILD_SUMMARY"
  else
    phase_line 1 build fail "$BUILD_SECS"
    box_say "$UI_RED" "the build failed here: ${C_build:-$ENGINE build} exited with an error. Its last lines:"
    # whole lines, wrapped (the reason is often at the end of a long one), and the full output
    # kept where it can be read after this command has gone
    strip < "$TMPD/build.log" | grep . | tail -15 | while IFS= read -r l; do ui_box_wrap "  $l"; done
    if mkdir -p .tando 2> /dev/null && strip < "$TMPD/build.log" > .tando/build.log 2> /dev/null; then
      box_say "" "all of it: .tando/build.log"
    fi
    ui_box_close "build failed; nothing was uploaded"
    exit 1
  fi

  local t files stage_secs kb
  step_start "stage: copying the release into $STAGE, then the checks"
  t=$(clock)
  stage
  stage_secs=$(since "$t")
  files=$(find "$STAGE" -type f | wc -l | tr -d ' ')
  kb=$(du -sk "$STAGE" 2> /dev/null | awk '{ print $1 }')
  phase_line 2 stage ok "$stage_secs" "$(plural "$files" file), $(ui_bytes $(( ${kb:-0} * 1024 )))${SWAPPED:+, $SWAPPED for $K_arch}"
  [ -n "$STAGE_NOTE" ] && ui_box_line "         $STAGE_NOTE"
  swap_lines
  if [ -n "${DRY_RUN:-}" ]; then dry_run_report "$files" "${kb:-0}"; return 0; fi
  # a large release (over 50 MB): where its size is, one line
  if [ "${kb:-0}" -gt 51200 ]; then
    box_say "$UI_DIM" "        over 50 MB; largest: $(stage_largest 3 | awk -F'\t' '{ printf "%s%s %s", (NR > 1 ? ", " : ""), $1, $2 }')"
  fi

  if [ -z "${DEPLOY_KEY:-}" ]; then   # create the app now that there is something to deploy
    configure
    [ "$K_created" = 1 ] && ui_box_line "        created $APP on $HOST: user tando-$APP, port $K_port"
    [ "$K_created" = 1 ] && : > "$TMPD/created"
  fi

  step_start "upload: sending the changes to $HOST"
  upload
  phase_line 3 upload ok "$UPLOAD_SECS" "$(plural "${UPLOAD_FILES:-0}" file) changed, $(ui_bytes "${UPLOAD_BYTES:-0}") sent"
  local build_total
  build_total=$(awk -v a="$BUILD_SECS" -v b="$stage_secs" 'BEGIN { printf "%.1f", a + b }')
  # the lease token, then the id of this deploy's settings (configure staged them on the server:
  # the activation runs with these, whatever another client configured meanwhile)
  printf '%s\n%s\n' "$TOKEN" "${K_conf:-}" > "$TMPD/token"
  # (an activate that failed before it wrote the release id leaves the lease: given back, so the
  # next deploy need not wait for it; one with the id keeps it, end leaves that alone)
  if ! agent_raw sudo activate "$APP" "$build_total" "$UPLOAD_SECS" < "$TMPD/token" > "$TMPD/act"; then
    lease_giveback "$TMPD/token"; bail 1
  fi
  kv_read "$TMPD/act" id same
  id=$K_id
  valid_id "$id" || die "agent returned no release id"
  if [ "$K_same" = 1 ]; then   # the live release already is this upload, with these settings
    phase_line 4 copy skip "" "unchanged: already live and verified"
    phase_line 5 preflight skip ""; phase_line 6 switch skip ""; phase_line 7 verify skip ""
    ui_box_close "already live  $(sed -n 's/^link=//p' "$TMPD/cfg" 2> /dev/null)"
    note "nothing was restarted; to restart it anyway: tando restart"
    return 0
  fi
  ui_box_line "        release $id"
  phase_start copy

  # follow the activation; it runs on the server whether or not we keep watching
  act_follow "$id" "$t0" || { [ $? = 3 ] && return 0; return 1; }   # (3: live; the server watches its soak)
  trap 'exit 130' INT TERM

  n=4
  for ph in $PHASES; do
    case " $SHOWN " in *" $ph "*) ;; *) phase_line $n $ph skip "";; esac
    n=$((n + 1))
  done
  case $K_result in
    ok|verified)
      ui_box_close "live in $(ui_dur "$(since "$t0")")  $K_link"
      after_live
      return 0;;
  esac
  fail_report
  box_say "$UI_DIM" "all of it: tando logs --release $id ${UI_G_MID} the server: tando doctor"
  if [ "$K_result" = rolledback ]; then
    ui_box_close "release $id: rolled back to the last good release"
  elif [ -z "$current" ]; then
    ui_box_close "release $id: $K_result; nothing is live yet"
  else
    ui_box_close "release $id: $K_result; the running app was not touched"
  fi
  return 1
}

# act_follow id t0: follows the activation of release id until its result (K_* from deploy-status;
# returns 0), or until it is live and soaking (the box closed, after_live done: returns 3)
act_follow() {
  local id=$1 t0=$2 errs=0 late="" dsw=""
  trap 'echo; note "detached: release $id keeps activating on the server; follow it with tando status --watch 2"; exit 130' INT TERM
  SHOWN="" SOAKING="" QUEUED_SAID=""
  [ -z "$DSWAIT" ] || dsw=wait=copy   # (the activation starts with the copy)
  # a deadline: an activation that neither ends nor dies is reported, not waited for forever
  local rto=0; [ -z "$C_release" ] || rto=${C_release_timeout:-300}
  # (counted from the end of a queue: a queued activation waits for the app up to an hour on the
  # server, then gives up by itself and says so; the client waits as long, not 17 minutes)
  local dlen=$(( 2 * ${C_timeout:-60} + ${C_soak:-${TANDO_SOAK:-30}} + rto + 900 ))
  local deadline=$(( $(now) + dlen ))
  while :; do
    # wait=<phase>: the server answers when the phase changes (or after 10 s) and says waited=1,
    # one ssh call instead of a poll every 0.5 s; an older server answers at once without it
    if ! agent_raw sudo deploy-status "$APP" "$id" ${dsw:+"$dsw"} > "$TMPD/ds"; then
      errs=$((errs + 1)) dsw=""
      [ $errs -lt 60 ] || die "lost contact; the activation continues on the server: tando releases"
      sleep 1
      continue
    fi
    errs=0
    kv_read "$TMPD/ds" phase result message link venv t_copy t_preflight t_release t_switch t_verify soak \
      waiting_for waiting_phase waiting_left waited
    [ "$K_phase" = queued ] && deadline=$(( $(now) + dlen ))
    # queued behind another activation (its soak, a rollback): say for what, once
    if [ "$K_phase" = queued ] && [ -n "$K_waiting_phase" ] && [ -z "${QUEUED_SAID:-}" ]; then
      QUEUED_SAID=1
      BUSY_ID=$K_waiting_for BUSY_PHASE=$K_waiting_phase BUSY_LEFT=$K_waiting_left BUSY_SOAK=${C_soak:-${TANDO_SOAK:-30}} BUSY_T=$(now) BUSY_BY=""
      busy_text
      box_say "$UI_DIM" "        queued: waiting for $BUSY_WHAT"
    fi
    if [ -n "$K_venv" ] && [ -z "${VENV_SHOWN:-}" ]; then ui_box_line "        venv: $K_venv"; VENV_SHOWN=1; fi
    show_phases
    if [ "$K_phase" = soak ] && [ -z "$SOAKING" ]; then
      SOAKING=1
      # live: the server keeps watching it (and rolls back if it falls over); --wait stays for that
      if [ -z "${WAIT_VERIFIED:-}${TANDO_WAIT:-}" ]; then
        trap 'exit 130' INT TERM
        phase_line 7 verify skip "" "the server watches it ${K_soak:-30} s (in the background)"
        ui_box_close "live in $(ui_dur "$(since "$t0")")  $K_link"
        note "if it falls over within those ${K_soak:-30} s, the server rolls back by itself" \
          "(tando status; --wait waits)"
        after_live
        return 3
      fi
      ui_box_line "        live; watching it ${K_soak:-30} s before calling it verified"
    fi
    case $K_result in ok|failed|rolledback|bad|verified|unknown) break;; esac
    # (past it, one more answer is asked for first: a laptop that slept through the activation
    # reports its result, not that it has not finished)
    if [ "$(now)" -gt "$deadline" ]; then
      [ -n "$late" ] || { late=1; dsw=""; continue; }
      ui_box_close "release $id: still activating after $(ui_dur $(( deadline - ${t0%.*} )))"
      die "the activation of $id has not finished; it may still be running on $HOST: tando status -a $APP, tando doctor"
    fi
    # (an answer that waited and still shows the phase asked about: the server's 10 s were up, or
    # it misbehaves; a pause all the same, so nothing can turn this into a busy loop)
    [ "$K_waited" = 1 ] && [ "wait=$K_phase" != "$dsw" ] || sleep 0.5
    dsw=""
    [ -z "$DSWAIT" ] || case $K_phase in ""|*[!a-z]*) ;; *) dsw="wait=$K_phase";; esac
  done
  return 0
}

# after_live: what else the deploy did, in the user's words: new domains (a domain that does not
# answer yet is a warning, not a failed deploy), domains left out for their DNS, database, jobs
after_live() {
  local d r n cal next rest
  for d in ${NEW_DOMAINS:-}; do domain_live "$d" || true; done
  for d in ${DNS_LATER:-}; do
    note "tando: $d was not added: its DNS does not point at $HOST yet (the code is live without it)"
    note "  at your DNS provider, create:"
    cat "$TMPD/dns.$d" >&2
    note "  then: tando domain add $d --wait"
  done
  [ -n "${DEPLOY_KEY:-}" ] && return 0
  if [ -n "$C_database" ] && [ "${K_created:-0}" = 1 ]; then
    note "database $C_database created; the app gets DATABASE_URL (tando db url --show)"
  fi
  # once, for a new app: the checks already watch it; only where to send alerts may be missing
  if [ "${K_created:-0}" = 1 ]; then
    note "alerts on for $APP: down, unhealthy, 5xx, new errors"
    # one more call, for a new app only: with no notifier the alerts go nowhere but tando alerts
    [ -n "$(type -t watch_raw)" ] || . "$TANDO_HOME/lib/cmd-alerts.sh"
    if watch_raw sudo show 8 > "$TMPD/al.n" 2> /dev/null && ! grep -q "^notifier$TAB" "$TMPD/al.n"; then
      note "  (no notifier set: tando alerts notifier add phone ntfy reaches your phone)"
    fi
    note "  see them: tando health; where they go: tando alerts"
  fi
  [ -n "$C_jobs" ] && [ "${K_changed:-0}" = 1 ] || return 0   # (jobs are rescheduled only on a change)
  agent_raw sudo jobs "$APP" > "$TMPD/jobs" 2> /dev/null || return 0
  NOW=$(now)
  while IFS=$TAB read -r r n cal next rest; do
    [ "$r" = job ] || continue
    # jobs take effect with the verified release: during its soak a new job has no timer yet
    if is_num "$next"; then note "job scheduled: $n $cal, next $(ago "$next")"
    else note "job $n ($cal): scheduled once this release is verified"; fi
  done < "$TMPD/jobs"
  return 0
}

# step_start text: outside a terminal (CI, a log file) one line when a step starts, so a long
# upload, pre-flight or verify is not a silent wait; a terminal shows only the result lines
step_start() {
  [ "${UI_ISTTY:-0}" = 1 ] && return 0
  box_say "$UI_DIM" "        $*"
}
# phase_after phase: the phase after it (in PHASES) has started
phase_after() {
  local p prev=""
  for p in $PHASES; do [ "$prev" = "$1" ] && { phase_start "$p"; return 0; }; prev=$p; done
}
# phase_start phase: step_start for one of the server's phases, once
phase_start() {
  local t
  case " $STARTED " in *" $1 "*) return 0;; esac
  case $1 in
    copy) t="copy: the server copies the upload into a new release";;
    preflight) t="pre-flight: the new release starts on a spare port; its health check (up to ${C_timeout:-60} s)";;
    release) t="release: running the release command on the server (up to ${C_release_timeout:-300} s)";;
    switch) t="switch: traffic moves to the new release";;
    verify) t="verify: checking the live release through Caddy";;
    *) return 0;;
  esac
  STARTED="$STARTED $1"
  step_start "$t"
}

# stage_largest n: the n largest directories of the staged release (each npm package on its own,
# else the top-level directory), as path<TAB>size
stage_largest() {
  ( cd "$STAGE" 2> /dev/null || exit 0
    { find . -mindepth 1 -maxdepth 1 -type d ! -name node_modules
      [ -d node_modules ] && find node_modules -mindepth 1 -maxdepth 2 -type d ! -name '.*' |
        awk -F/ '$2 ~ /^@/ ? NF == 3 : NF == 2'
    } | sed 's|^\./||' > "$TMPD/dirs"
    [ -s "$TMPD/dirs" ] || exit 0
    tr '\n' '\0' < "$TMPD/dirs" | xargs -0 du -sk 2> /dev/null ) |
    sort -rn | head -"$1" | while IFS=$'\t' read -r k p; do printf '%s\t%s\n' "$p" "$(ui_bytes $(( k * 1024 )))"; done
}

# dry_run_report files kb: what tando deploy --dry-run built and staged; nothing was sent
dry_run_report() {
  local p s
  ui_box_line "        $(plural "$1" file), $(ui_bytes $(( $2 * 1024 ))) in $STAGE"
  stage_largest 5 > "$TMPD/largest"
  if [ -s "$TMPD/largest" ]; then
    ui_box_line "        largest:"
    while IFS=$'\t' read -r p s; do box_say "$UI_DIM" "          $s  $p"; done < "$TMPD/largest"
  fi
  [ -s "$TMPD/swaps" ] || box_say "$UI_DIM" "        no platform packages to swap for $K_arch"
  ui_box_close "dry run: nothing was uploaded; tando deploy sends it"
}

plural() { if [ "$1" = 1 ]; then printf '1 %s' "$2"; else printf '%s %ss' "$1" "$2"; fi; }
