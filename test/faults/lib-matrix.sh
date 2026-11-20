# shellcheck shell=bash
# lib-matrix.sh: the fault matrix (test/e2e-matrix.sh; docs/TESTING.md "Fault matrix").
#
# An operation (a deploy, a rollback, stop, start, restart, env set...) runs with ONE fault at
# ONE point of the agent: a point is a named place before an external action (fp <name> in
# server/tando-agent) or a write of a state file (pre:/post:<file>, inside save). The fault is
# kill (SIGKILL of the agent there), fail (that action fails: a full disk, a command that
# fails) or reboot (the agent waits there, then the server restarts: docker restart). Then
# recovery runs as on a server (the activation's ExecStopPost, a recover-all as tando-watch or
# the boot would run it), and ONE checker (mx_inv) asserts the invariants of the matrix (eleven; the 11th, the workers', for
# the kind worker).
# The points of an operation come from a trace of the same operation without a fault.
#
# The hook fires only with root's /etc/tando-test-server and /run/tando-test/fault on the server
# (made here, through docker exec): never on a real server. Real power loss (a write the disk
# never got) cannot be simulated in a container: docker kill keeps the page cache.
# bash 3.2 (laptop side).

MX_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
MX_T=/run/tando-test
MX_LOG=${MX_LOG:-/dev/stderr}

dx() { docker exec -i "$TANDO_TEST_NAME" "$@"; }                     # root on the server
dxs() { docker exec -i "$TANDO_TEST_NAME" bash -c "$1"; }

# ---- markers, fault specs, traces --------------------------------------------------------------
mx_markers() {
  dxs "install -m 644 -o root -g root /dev/null /etc/tando-test-server && install -d -m 700 -o root -g root $MX_T"
}
mx_spec_clear() { dxs "rm -f $MX_T/fault $MX_T/next $MX_T/fired $MX_T/taking.* $MX_T/reached $MX_T/release"; }
# mx_spec <file: fault|next> <point> <action> <nth> <verb>: one fault spec, for this app only
mx_spec() {
  printf 'point=%s\naction=%s\nnth=%s\nverb=%s\napp=%s\n' "$2" "$3" "$4" "$5" "$A" |
    dxs "cat > $MX_T/.spec && mv -f $MX_T/.spec $MX_T/$1"
}
mx_fired() { dxs "test -f $MX_T/fired"; }
mx_trace_on() { dxs ": > $MX_T/trace"; }
mx_trace_off() { dxs "cat $MX_T/trace 2> /dev/null; rm -f $MX_T/trace"; }

# ---- the app, one version at a time -------------------------------------------------------------
# Odd versions: health /hc-odd, start "node server.js"; even ones: /hc-even, "node ./server.js".
# A rollback or a recovery that leaves app.conf with the other version's lines is seen by the
# checker (the live release would answer 404 at that health path; its start command differs).
# (MX_SAMECONF=1: every version has the odd one's: to look past those two checks)
mx_health_of() { if [ $(($1 % 2)) = 1 ] || [ -n "${MX_SAMECONF:-}" ]; then echo /hc-odd; else echo /hc-even; fi; }
# memory (the unit file) and max_conns (the Caddy site) differ by parity too: a unit or a site
# left with the other version's settings (configure applying them before the release went live,
# a revert that did not put them back) is seen by the checker
mx_mem_of() { if [ $(($1 % 2)) = 1 ] || [ -n "${MX_SAMECONF:-}" ]; then echo 128M; else echo 144M; fi; }
# and the job's schedule (node and data: the job units are the live release's)
mx_job_of() { if [ $(($1 % 2)) = 1 ] || [ -n "${MX_SAMECONF:-}" ]; then echo '*:0/10'; else echo '*:0/20'; fi; }
mx_has_job() { case $KIND in node|data) return 0;; esac; return 1; }
# and the workers (kind worker): odd versions have a and b, even ones a only, so a worker left
# from the other version (or missing) is seen by the checker (inv11)
mx_workers_of() { if [ $(($1 % 2)) = 1 ] || [ -n "${MX_SAMECONF:-}" ]; then echo "a b"; else echo "a"; fi; }
# and a domain (domain = in tando.conf; every version its own, as domains are only added: one
# of a version that never went live must not be the app's) and, with a database, a role limit
mx_dom_of() { if [ -n "${MX_SAMECONF:-}" ]; then echo mx.test; else echo "v$1.mx.test"; fi; }
mx_dbst_of() { if [ $(($1 % 2)) = 1 ] || [ -n "${MX_SAMECONF:-}" ]; then echo 30s; else echo 45s; fi; }
mx_mc_of() { if [ $(($1 % 2)) = 1 ] || [ -n "${MX_SAMECONF:-}" ]; then echo 64; else echo 96; fi; }
mx_start_of() {
  local n=$1; [ -n "${MX_SAMECONF:-}" ] && n=1
  set -- "$n"
  case $KIND in
    python) if [ $(($1 % 2)) = 1 ]; then echo "python3 app.py"; else echo "python3 ./app.py"; fi;;
    static|container) echo "";;
    *) if [ $(($1 % 2)) = 1 ]; then echo "node server.js"; else echo "node ./server.js"; fi;;
  esac
}
# mx_version <n> [behaviour]: the work dir holds version n
mx_version() {
  local n=$1 beh=${2:-ok} d=$W/$A h s
  h=$(mx_health_of "$n") s=$(mx_start_of "$n")
  mkdir -p "$d"
  echo "$n" > "$d/VERSION"; echo "$h" > "$d/HEALTH"; echo "$beh" > "$d/BEHAVIOR"
  {
    echo "app = $A"
    case $KIND in
      static) echo "recipe = static";;
      python) echo "recipe = python"; echo "start = $s";;
      next) echo "recipe = next"; echo "build = sh build.sh"; echo "start = $s";;
      container) echo "recipe = container"; echo "container_port = 8080";;
      *) echo "recipe = node"; echo "start = $s";;
    esac
    echo "health = $h"
    echo "health_timeout = 10"
    echo "soak = ${MX_SOAK:-2}"
    echo "domain = $(mx_dom_of "$n")"; echo "www = off"
    [ "$KIND" = static ] || { echo "memory = $(mx_mem_of "$n")"; echo "max_conns = $(mx_mc_of "$n")"; }
    case $KIND in
      data) echo "data = data"; echo "database = postgres"; echo "db_statement_timeout = $(mx_dbst_of "$n")";;
    esac
    mx_has_job && echo "job.tick = $(mx_job_of "$n") | true"
    [ "$KIND" = node ] && echo "assets = assets"
    if [ "$KIND" = worker ]; then for w in $(mx_workers_of "$n"); do echo "worker.$w = node worker.js"; done; fi
    [ -n "${MX_RELEASE:-}" ] && echo "release = $MX_RELEASE"
  } > "$d/tando.conf"
  case $KIND in
    static)
      rm -f "$d"/hc-*; echo "v$n env=-" > "$d/index.html"; echo ok > "$d/${h#/}"
      # (static cannot be unhealthy after the switch; its pre-flight checks that the health file
      # exists in the release: exit@pre leaves it out, so the release is refused there)
      case $beh in ok) ;; exit@pre) rm -f "$d/${h#/}";; *) echo "x" > "$d/${h#/}";; esac;;
    python) cp "$MX_DIR/mx-app/app.py" "$d/"; : > "$d/requirements.txt";;
    next)
      cp "$MX_DIR/mx-app/server.js" "$d/mx.js"
      printf '{ "name": "mx", "dependencies": { "next": "16.0.0" } }\n' > "$d/package.json"
      printf 'export default { output: "standalone" };\n' > "$d/next.config.mjs"
      # a stand-in for `next build`: the standalone server and a static file, as Next lays them out
      printf '%s\n' 'rm -rf .next && mkdir -p .next/standalone .next/static/mx' \
        'cp mx.js .next/standalone/server.js && cp VERSION HEALTH BEHAVIOR .next/standalone/' \
        'echo x > .next/static/mx/a.js' > "$d/build.sh";;
    container)
      mkdir -p "$d/www"; rm -f "$d"/www/hc-*
      echo ok > "$d/www/${h#/}"; echo "v$n env=-" > "$d/www/index.html"
      [ "$beh" = ok ] || rm -f "$d/www/${h#/}"
      printf '%s\n' 'FROM alpine:3.22' 'RUN apk add --no-cache busybox-extras' 'COPY www /www' \
        'CMD ["/bin/sh", "-c", "exec httpd -f -v -p 0.0.0.0:${PORT:-8080} -h /www"]' > "$d/Dockerfile";;
    worker) cp "$MX_DIR/mx-app/server.js" "$MX_DIR/mx-app/worker.js" "$d/";;
    *) cp "$MX_DIR/mx-app/server.js" "$d/";;
  esac
  # a fingerprinted file per version (node: assets = assets; static: found by its name)
  if mx_has_assets; then mkdir -p "$d/assets"; rm -f "$d"/assets/*; echo "v$n asset" > "$d/assets/$(mx_asset_name "$n")"; fi
}
# mx_has_assets: the kinds whose versions ship a fingerprinted file (the shared assets directory)
mx_has_assets() { case $KIND in node|static) return 0;; esac; return 1; }
mx_asset_name() { echo "app-$(printf 'v%s' "$1" | cksum | cut -d' ' -f1).js"; }
# mx_settings <n>: what a client's configure sends for version n (the race action: a second client
# configures the app with its own tando.conf while this one's deploy is in flight)
mx_settings() {
  local n=$1 r=node
  case $KIND in static|python|next|container) r=$KIND;; esac
  printf 'recipe=%s\n' "$r"
  [ -n "$(mx_start_of "$n")" ] && printf 'start=%s\n' "$(mx_start_of "$n")"
  printf 'health=%s\nhealth_timeout=10\nsoak=%s\n' "$(mx_health_of "$n")" "${MX_SOAK:-2}"
  [ "$KIND" = static ] || printf 'memory=%s\nmax_conns=%s\n' "$(mx_mem_of "$n")" "$(mx_mc_of "$n")"
  [ "$KIND" = container ] && printf 'container_port=8080\n'
  [ "$KIND" = data ] && printf 'data=data\ndatabase=postgres\ndb_statement_timeout=%s\n' "$(mx_dbst_of "$n")"
  printf 'domain=%s\nwww=off\n' "$(mx_dom_of "$n")"
  mx_has_job && printf 'job.tick=%s | true\n' "$(mx_job_of "$n")"
  [ "$KIND" = node ] && printf 'assets=assets\n'
  if [ "$KIND" = worker ]; then for w in $(mx_workers_of "$n"); do printf 'worker.%s=node worker.js\n' "$w"; done; fi
  return 0
}
# mx_client <out> <args...>: the CLI in the app's work dir; status in MXRC
# (the version's domain resolves to the test server: the client checks a new domain's DNS first)
mx_client() {
  local o=$1; shift
  (cd "$W/$A" && TANDO_TEST_RESOLVE="$(sed -n 's/^domain = \(.*\)/\1=127.0.0.1/p' tando.conf)" "$R" "$@" > "$o" 2>&1); MXRC=$?
  return $MXRC
}
# the release id a deploy printed ("release <id>"), recorded with its version
mx_rid() { sed -n 's/.*release \([0-9][0-9-]*\).*/\1/p' "$1" | head -1; }
mx_note_id() { [ -n "$1" ] && echo "$1 $2" >> "$W/ids"; }
mx_ver_of() { awk -v i="$1" '$1 == i { v = $2 } END { print v }' "$W/ids" 2> /dev/null; }
# mx_deploy [behaviour]: a deploy of the next version, no fault (a step around the cases)
mx_deploy() {
  local cur; cur=$(dxs "readlink /opt/tando/apps/$A/current" 2> /dev/null); cur=${cur##*/}
  MXV=$((MXV + 1))
  [ -n "$cur" ] && [ -n "$(mx_ver_of "$cur")" ] && [ $(( (MXV - $(mx_ver_of "$cur")) % 2 )) = 0 ] && MXV=$((MXV + 1))
  mx_version "$MXV" "${1:-ok}"
  mx_client "$W/d$MXV.out" deploy; local rc=$MXRC
  mx_note_id "$(mx_rid "$W/d$MXV.out")" "$MXV"
  [ "$rc" != 0 ] || echo "$MXV" >> "$W/served"
  return $rc
}

# ---- facts and the request loop -----------------------------------------------------------------
# mx_facts [new id]: the server's side (mx-facts.sh) into $W/facts, plus what a visitor gets
mx_facts() {
  dx bash -s "$A" "${MX_H0:-0}" "${1:-}" < "$MX_DIR/mx-facts.sh" > "$W/facts" 2> "$W/facts.err"
  rm -f "$W/body"
  MX_CODE=$(curl -s -m 10 -o "$W/body" -w '%{http_code}' "http://$A.localhost:$TANDO_TEST_HTTP_PORT/")
  MX_BODY=$(head -c 200 "$W/body" | tr -d '\r\n')
}
fv() { sed -n "s/^$1=//p" "$W/facts" | head -1; }
mx_served_ver() { printf '%s' "$MX_BODY" | sed -n 's/^v\([0-9]*\) env=.*/\1/p'; }
mx_served_env() { printf '%s' "$MX_BODY" | sed -n 's/^v[0-9]* env=//p'; }
mx_releases() { sed -n 's/^rel_\([^=]*\)=.*/\1/p' "$W/facts" | tr '\n' ' '; }

mx_loop_start() {
  rm -f "$W/loop.stop" "$W/loop"
  (
    while [ ! -f "$W/loop.stop" ]; do
      curl -s -o /dev/null -m 30 -w '%{http_code} %{time_total}' "http://$A.localhost:$TANDO_TEST_HTTP_PORT/"
      echo " $(date +%s)"
      sleep 0.2
    done
  ) > "$W/loop" 2> /dev/null &
  MX_LOOP=$!
}
mx_loop_stop() {
  touch "$W/loop.stop"; wait "$MX_LOOP" 2> /dev/null
  MX_REQ=$(grep -c . "$W/loop" 2> /dev/null)
}

# ---- the checker: the invariants ----------------------------------------------------------
# Inputs (set by the case): MX_OP, MX_OLD (current before), MX_NEW (the operation's release:
# the deploy's new one, the rollback's target; may be empty), MX_WANT old|new|any (which of the
# two must serve), MX_RUN running|stopped|any, MX_ENVW (env value expected, or "any:a b"),
# MX_H0 (history lines before), MX_DATA0/MX_DB0 (data sentinel, row count before),
# MX_LOOPOK 1 when no request may fail (MX_LOOP503 1: a 503 page is allowed: stop, start).
# Prints "inv<N> <name>: <what>" for each broken invariant; MX_BROKEN lists their numbers.
mx_bad() { MX_BROKEN="$MX_BROKEN $1"; echo "    inv$1 $2" >&2; echo "inv$1 $2" >> "$W/inv.out"; }
mx_inv() {
  MX_BROKEN="" ; : > "$W/inv.out"
  [ "${MX_OP:-}" = destroy ] && { mx_inv_gone; return; }
  mx_facts "$MX_NEW"
  local sid="" sv cur link st lg n h nh ok rel s
  sv=$(mx_served_ver)
  cur=$(fv s_current) link=$(fv link)
  # which release serves: the one whose version answered
  if [ -n "$sv" ]; then
    for rel in $(mx_releases); do [ "$(mx_ver_of "$rel")" = "$sv" ] && sid=$rel; done
  fi
  local stopped=0; [ -n "$(fv s_stopped)" ] && stopped=1
  # 1. exactly one release serves, the intended one (or the stopped page)
  if [ "$stopped" = 1 ]; then
    [ "$MX_RUN" != running ] || mx_bad 1 "serving: the app is stopped, but this operation must leave it running"
    { [ "$MX_CODE" = 503 ] && printf '%s' "$MX_BODY" | grep -q "is stopped"; } ||
      mx_bad 1 "serving: the state says stopped, a visitor gets $MX_CODE \"$MX_BODY\""
  else
    [ "$MX_RUN" != stopped ] || mx_bad 1 "serving: the app must be stopped (state stopped=), it is not; visitor: $MX_CODE"
    if [ "$MX_CODE" != 200 ] || [ -z "$sid" ]; then
      mx_bad 1 "serving: a visitor gets $MX_CODE \"$MX_BODY\" (no known release)"
    else
      case $MX_WANT in
        old) [ "$sid" = "$MX_OLD" ] || mx_bad 1 "serving: $sid (v$sv) serves, the old release $MX_OLD must";;
        new) [ "$sid" = "$MX_NEW" ] || mx_bad 1 "serving: $sid (v$sv) serves, the new release ${MX_NEW:-?} must";;
        any) [ "$sid" = "$MX_OLD" ] || [ "$sid" = "$MX_NEW" ] || mx_bad 1 "serving: $sid serves, neither old $MX_OLD nor new $MX_NEW";;
      esac
      if [ "$KIND" != static ]; then
        [ "$(fv listen_own)" -ge 1 ] 2> /dev/null && [ "$(fv listen_foreign)" = 0 ] ||
          mx_bad 1 "serving: listeners on the app port: own $(fv listen_own), foreign $(fv listen_foreign)"
        [ "$(fv listen_pre)" = 0 ] || mx_bad 1 "serving: something still listens on the pre-flight port"
        [ "$KIND" = container ] || [ "$(fv u_cwd)" = "$sid" ] || mx_bad 1 "serving: the unit's process runs in release $(fv u_cwd), not $sid"
      fi
    fi
  fi
  # 2. link, state and app.conf agree with what serves
  local want=${sid:-$cur}
  [ -n "$want" ] && [ "$link" = "$want" ] && [ "$cur" = "$want" ] ||
    mx_bad 2 "agree: current -> ${link:-none}, state current=${cur:-none}, serving ${sid:-none}"
  if [ -n "$want" ] && [ -n "$(mx_ver_of "$want")" ]; then
    local v; v=$(mx_ver_of "$want")
    [ "$(fv c_health)" = "$(mx_health_of "$v")" ] ||
      mx_bad 2 "agree: app.conf health=$(fv c_health), release $want (v$v) answers on $(mx_health_of "$v")"
    s=$(mx_start_of "$v")
    if [ -n "$s" ]; then
      [ "$(fv c_start)" = "$s" ] || [ "$(fv snap_start)" = "$s" ] ||
        mx_bad 2 "agree: release $want starts with \"$s\"; app.conf has \"$(fv c_start)\", its snapshot \"$(fv snap_start)\""
      if [ "$stopped" = 0 ] && [ -n "$(fv u_cmd)" ]; then
        case "$(fv u_cmd) " in *"$s "*) ;; *) mx_bad 2 "agree: the process runs \"$(fv u_cmd)\", release $want's start is \"$s\"";; esac
      fi
    fi
  fi
  if [ -n "$want" ] && [ -n "$(mx_ver_of "$want")" ] && [ "$KIND" != static ]; then
    local v2; v2=$(mx_ver_of "$want")
    [ "$(fv u_mem)" = "$(mx_mem_of "$v2")" ] ||
      mx_bad 2 "agree: the unit file has MemoryMax=$(fv u_mem), release $want (v$v2) is deployed with $(mx_mem_of "$v2")"
    [ "$(fv site)" != proxy ] || [ "$(fv site_mc)" = "$(mx_mc_of "$v2")" ] ||
      mx_bad 2 "agree: Caddy's site has max_conns $(fv site_mc), release $want (v$v2) is deployed with $(mx_mc_of "$v2")"
    ! mx_has_job || [ "$(fv job_cal)" = "$(mx_job_of "$v2")" ] ||
      mx_bad 2 "agree: the job timer says OnCalendar=$(fv job_cal), release $want (v$v2) is deployed with $(mx_job_of "$v2")"
    [ "$KIND" != data ] || [ "$(fv db_st)" = "$(mx_dbst_of "$v2")" ] ||
      mx_bad 2 "agree: the database role has statement_timeout=$(fv db_st), release $want (v$v2) is deployed with $(mx_dbst_of "$v2")"
  fi
  # domains: the serving release's is the app's (app.conf and Caddy's site); one of a version that
  # never went live (a refused deploy's, a reverted one's, a second client's) is in neither
  if [ -n "$want" ] && [ -n "$(mx_ver_of "$want")" ]; then
    local v3 dm dv; v3=$(mx_ver_of "$want")
    [ -n "$sv" ] && echo "$sv" >> "$W/served"
    case " $(fv c_domains) " in *" $(mx_dom_of "$v3")|"*) ;; *)
      mx_bad 2 "agree: app.conf has domains=$(fv c_domains), release $want (v$v3) is deployed with $(mx_dom_of "$v3")";; esac
    case " $(fv site_names) " in *" $(mx_dom_of "$v3") "*) ;; *)
      mx_bad 2 "agree: Caddy's site answers for $(fv site_names), release $want (v$v3) is deployed with $(mx_dom_of "$v3")";; esac
    for dm in $( { fv c_domains | tr ' ' '\n' | cut -d'|' -f1; fv site_names | tr ' ' '\n'; } | sort -u); do
      dv=$(printf '%s' "$dm" | sed -n 's/^v\([0-9]*\)\.mx\.test$/\1/p')
      [ -n "$dv" ] || continue
      grep -qx "$dv" "$W/served" 2> /dev/null ||
        mx_bad 2 "agree: $dm (app.conf: $(fv c_domains); site: $(fv site_names)) is of v$dv, which never went live"
    done
  fi
  case $stopped:$(fv site) in
    1:stopped|0:proxy|0:static) ;;
    *) mx_bad 2 "agree: state stopped=$(fv s_stopped) down=$(fv s_down), Caddy's site is $(fv site)";;
  esac
  [ -z "$(fv s_down)" ] || mx_bad 2 "agree: the state says down after recovery"
  if [ "$KIND" != static ]; then
    case $stopped:$(fv u_active):$(fv u_enabled) in
      1:inactive:disabled|1:failed:disabled|0:active:enabled) ;;
      *) mx_bad 2 "agree: state stopped=$(fv s_stopped), unit $(fv u_active) and $(fv u_enabled)";;
    esac
  fi
  # the env the process runs with is the env file's, and the expected one
  if [ "$stopped" = 0 ] && [ "$MX_CODE" = 200 ] && [ "$KIND" != static ] && [ "$KIND" != container ]; then
    local ev; ev=$(mx_served_env)
    if [ "$ev" != "$(fv env_val)" ] && ! { [ "$ev" = - ] && [ -z "$(fv env_val)" ]; }; then
      mx_bad 2 "agree: the app runs with MXVAL=$ev, the env file says $(fv env_val)"
    fi
    case $MX_ENVW in
      any:*) case " ${MX_ENVW#any:} " in *" $(fv env_val) "*) ;; *) mx_bad 2 "agree: env MXVAL=$(fv env_val), not one of ${MX_ENVW#any:}";; esac;;
      "") ;;
      *) [ "$(fv env_val)" = "$MX_ENVW" ] || mx_bad 2 "agree: env MXVAL=$(fv env_val), it must be $MX_ENVW";;
    esac
    [ -z "$(fv env_bad)" ] || mx_bad 2 "agree: the env that broke the app (MX_BAD) is still in the env file"
  fi
  # 11. the workers that run are exactly the serving release's, each running it (none when stopped)
  if [ "$KIND" = worker ] && [ -n "$want" ] && [ -n "$(mx_ver_of "$want")" ]; then
    local ww wn wa wr we wl run=""
    ww=" $(mx_workers_of "$(mx_ver_of "$want")") "
    for wl in $(sed -n 's/^wk=//p' "$W/facts"); do
      IFS=: read -r wn wa wr we <<< "$wl"
      case $wa in active|activating|reloading|deactivating) run="$run $wn";; esac
      if [ "$stopped" = 1 ]; then
        case $wa in active|activating|reloading) mx_bad 11 "workers: the app is stopped, worker $wn is $wa";; esac
        [ "$we" != enabled ] || mx_bad 11 "workers: the app is stopped, worker $wn is enabled (it would start at boot)"
        continue
      fi
      case $ww in *" $wn "*) ;; *) mx_bad 11 "workers: worker $wn (unit $wa) is not one of release $want's:$ww"; continue;; esac
      [ "$wa" = active ] || mx_bad 11 "workers: worker $wn of release $want is $wa, not active"
      [ "$wr" = "$want" ] || mx_bad 11 "workers: worker $wn runs release ${wr:-none}, the serving one is $want"
      [ "$we" = enabled ] || mx_bad 11 "workers: worker $wn is $we, not enabled (a reboot would not start it)"
    done
    if [ "$stopped" = 0 ]; then
      for wn in $ww; do case " $run " in *" $wn "*) ;; *) mx_bad 11 "workers: release $want's worker $wn does not run";; esac; done
    fi
  fi
  # 3. statuses
  if [ -n "$want" ]; then
    st=$(fv "rel_$want") lg=$(fv s_last_good)
    [ "$st" = verified ] || mx_bad 3 "status: the live release $want is \"$st\", not verified"
    [ "$lg" = "$want" ] || mx_bad 3 "status: last_good=$lg, the live release is $want"
  fi
  if [ -n "$MX_NEW" ] && [ "$want" != "$MX_NEW" ] && [ "$MX_OP" != rollback ]; then
    st=$(sed -n "s/^rel_$MX_NEW=//p" "$W/facts")
    if grep -q "^rel_$MX_NEW=" "$W/facts"; then
      [ "$st" = bad ] || mx_bad 3 "status: the refused release $MX_NEW is on disk as \"$st\", not bad"
    fi
  fi
  [ "$MX_OP" != rollback ] || [ "$want" != "$MX_NEW" ] || [ "$(fv "rel_$MX_OLD")" = rolledback ] ||
    mx_bad 3 "status: the release rolled back from ($MX_OLD) is \"$(fv "rel_$MX_OLD")\", not rolledback"
  # 4. history: one line for the operation, its result; nothing left running
  nh=$(grep -c '^hist=' "$W/facts")
  case $MX_OP in
    deploy*|rollback|recover)
      local kind=deploy; [ "$MX_OP" = rollback ] && kind=rollback
      if [ -z "$MX_NEW" ]; then
        [ "$nh" = 0 ] || mx_bad 4 "history: $nh lines, but the operation never got a release: $(grep '^hist=' "$W/facts" | tr '\n' ' ')"
      elif [ "$MX_OP" = rollback ] && [ "$nh" = 0 ] && [ "$want" = "$MX_OLD" ] && [ "$(fv p_id)" != "$MX_NEW" ]; then
        :   # (a rollback cut before it wrote anything, its progress file included: it never began)
      else
        n=$(grep -c "^hist=$MX_NEW $kind " "$W/facts")
        [ "$nh" = 1 ] && [ "$n" = 1 ] || mx_bad 4 "history: $nh new lines, $n for $MX_NEW $kind (exactly one): $(grep '^hist=' "$W/facts" | tr '\n' ' ')"
        h=$(sed -n "s/^hist=$MX_NEW $kind //p" "$W/facts" | tail -1)
        if [ "$want" = "$MX_NEW" ]; then [ "$h" = ok ] || mx_bad 4 "history: $MX_NEW serves, its line says \"$h\""
        elif [ -n "$h" ]; then case $h in failed|rolledback) ;; *) mx_bad 4 "history: $MX_NEW does not serve, its line says \"$h\"";; esac; fi
        case $(fv ds_result) in running|"") mx_bad 4 "history: deploy-status says phase=$(fv ds_phase) result=$(fv ds_result) for $MX_NEW";; esac
      fi;;
    *) [ "$nh" = 0 ] || mx_bad 4 "history: $nh new lines for a $MX_OP: $(grep '^hist=' "$W/facts" | tr '\n' ' ')";;
  esac
  [ "$(fv p_result)" != running ] || mx_bad 4 "history: activation $(fv p_id) still says result=running"
  [ -z "$(fv hist_torn)" ] || mx_bad 4 "history: history.tsv does not end with a newline"
  # 5. idle, lock free
  case $(fv s_phase) in idle|"") ;; *) mx_bad 5 "idle: phase=$(fv s_phase)";; esac
  [ "$(fv lock)" = free ] || mx_bad 5 "idle: the app's lock is held"
  [ "$(fv lock_waiters)" = 0 ] || mx_bad 5 "idle: $(fv lock_waiters) waiting for the lock"
  # 6. leftovers
  [ "$(fv lease)" = free ] || mx_bad 6 "leftovers: the upload lease is still held"
  [ -z "$(fv units | tr -d ' ')" ] || mx_bad 6 "leftovers: units $(fv units)"
  [ -z "$(fv tmp | tr -d ' ')" ] || mx_bad 6 "leftovers: files $(fv tmp)"
  [ -z "$(fv env_prev)" ] || mx_bad 6 "leftovers: env.prev"
  for rel in $(mx_releases); do
    [ -n "$(fv "rel_$rel")" ] || mx_bad 6 "leftovers: release $rel is on disk with no status (a reservation)"
  done
  # 7. a release to roll back to is still there
  ok=0
  for rel in $(mx_releases); do
    [ "$rel" != "$want" ] && case $(fv "rel_$rel") in verified|rolledback) ok=1;; esac
  done
  [ "$ok" = 1 ] || mx_bad 7 "rollback target: no other verified release on disk ($(mx_releases))"
  # 8. stopped stays stopped: in MX_RUN (1) and the unit (2); here: a stopped app has no process,
  # and a deploy to a stopped app that did not go live leaves it stopped
  if [ "$MX_OP" = deploy-stopped ] && [ "$want" != "$MX_NEW" ] && [ "$stopped" = 0 ]; then
    mx_bad 8 "stopped: a deploy to the stopped app did not go live, and the app runs"
  fi
  if [ "$stopped" = 1 ] && [ "$KIND" != static ]; then
    [ "$(fv u_active)" != active ] || mx_bad 8 "stopped: the state says stopped, the unit runs"
  fi
  # 9. data and database untouched
  if [ "$MX_OP" = restore ]; then
    # 13. a restore: the data and rows are all the backup's or all as before; anything else (cut
    # off half way) is recorded in the state and reported by tando doctor. Without a fault: the backup's.
    local ds dr cut co=0
    ds=$(fv data_sum) dr=$(fv db_rows) cut=$(fv s_restore_cut)
    { [ "$ds" = "$MX_DATA_BK" ] && { [ -z "${MX_DB_BK:-}" ] || [ "$dr" = "$MX_DB_BK" ]; }; } && co=new
    { [ "$ds" = "${MX_DATA0:-}" ] && { [ -z "${MX_DB0:-}" ] || [ "$dr" = "$MX_DB0" ]; }; } && [ "$co" = 0 ] && co=old
    if [ "${MX_FAULT:--}" = - ]; then
      [ "$co" = new ] || mx_bad 13 "restore: without a fault, the data is not the backup's (sentinel $ds, rows $dr)"
    fi
    [ "$co" != 0 ] || [ -n "$cut" ] ||
      mx_bad 13 "restore: neither the backup's data nor the old (sentinel $ds, rows $dr), and the state records no cut-off restore"
    if [ -n "$cut" ]; then
      dx /opt/tando/bin/tando-agent doctor > "$W/doctor" 2>&1
      grep -q "restore of backup $MX_BK stopped" "$W/doctor" ||
        mx_bad 13 "restore: the state records a cut-off restore ($cut), tando doctor does not say it"
    fi
    [ -z "$(fv s_restore_step)" ] || mx_bad 5 "idle: restore_step=$(fv s_restore_step) is left in the state"
  else
    [ "$(fv data_sum)" = "${MX_DATA0:-}" ] || mx_bad 9 "data: the sentinel changed (${MX_DATA0:-none} -> $(fv data_sum))"
    [ -z "${MX_DB0:-}" ] || [ "$(fv db_rows)" = "$MX_DB0" ] || mx_bad 9 "data: database rows $MX_DB0 -> $(fv db_rows)"
  fi
  # 12. assets: the serving release's fingerprinted file answers through Caddy with its bytes and
  # the immutable header (linked before the switch: a kill at any point of the copy must not take it)
  if [ "$stopped" = 0 ] && [ -n "$sv" ] && [ "$MX_CODE" = 200 ] && mx_has_assets; then
    local acode
    acode=$(curl -s -m 10 -D "$W/ah" -o "$W/ab" -w '%{http_code}' "http://$A.localhost:$TANDO_TEST_HTTP_PORT/assets/$(mx_asset_name "$sv")")
    { [ "$acode" = 200 ] && [ "$(cat "$W/ab")" = "v$sv asset" ] && grep -qi '^cache-control:.*immutable' "$W/ah"; } ||
      mx_bad 12 "assets: v$sv's fingerprinted file answers $acode \"$(head -c 40 "$W/ab" | tr -d '\r\n')\", cache: $(grep -i '^cache-control' "$W/ah" | tr -d '\r')"
    [ -z "$(fv asset_left)" ] || mx_bad 12 "assets: leftovers in the shared directory: $(fv asset_left)"
  fi
  # 10. visitors
  if [ "${MX_LOOPOK:-0}" = 1 ] && [ -s "$W/loop" ]; then
    # (a reboot: requests fail while the server is down; from the first 200 after it, none may)
    local badn
    # (the server is down from MX_REBOOT_T until it answers ssh again, MX_UP_T; Caddy may still
    # answer while it shuts down: the first 200 that counts is one after MX_UP_T)
    badn=$(awk -v t="${MX_REBOOT_T:-0}" -v u="${MX_UP_T:-0}" -v a="${MX_LOOP503:-0}" '
      { if (t > 0 && s == 0 && $3 >= t) s = 1
        if (s == 1) { if ($1 == 200 && $3 > u) s = 2; else next }
        if ($1 != 200 && !(a == 1 && $1 == 503)) n++ }
      END { print n + 0 }' "$W/loop")
    [ "$badn" = 0 ] || mx_bad 10 "requests: $badn of $MX_REQ failed ($(awk '{ print $1 }' "$W/loop" | sort | uniq -c | tr -s ' \n' ' '))"
  fi
  [ -z "$MX_BROKEN" ]
}

# mx_inv_gone: after a destroy (invariant 14), nothing of the app is left: its directory, unit
# files and loaded units (timers, workers, slice), Caddy site, journal settings, user and groups,
# firewall rules of its uid, database and role; its final backup is there, complete (kind data:
# the one with data to back up; no --purge)
mx_inv_gone() {
  local left
  left=$(dxs "A=$A; U=${MX_UID:-none}
    ls -d /opt/tando/apps/\$A /opt/tando/apps/.gone-\$A.* /etc/caddy/tando/\$A.caddy /etc/tmpfiles.d/tando-journal-\$A.conf \
      /etc/systemd/system/systemd-journald@tando-\$A.service.d /etc/systemd/system/tando-\$A.* /etc/systemd/system/tando-\$A-* \
      /etc/systemd/system/tando-\${A}_* /etc/systemd/system/*.wants/tando-\$A[._-]* 2> /dev/null | sed 's/^/file /'
    systemctl list-units --all --plain --no-legend \"tando-\$A.*\" \"tando-\$A-*\" \"tando-\${A}_*\" 2> /dev/null | awk '{ print \"unit \" \$1 }'
    getent passwd tando-\$A > /dev/null && echo 'user tando-'\$A
    getent group tando-\$A > /dev/null && echo 'group tando-'\$A
    getent group tando-m-\$A > /dev/null && echo 'group tando-m-'\$A
    nft list table inet tando 2> /dev/null | grep -q \"skuid \$U \" && echo \"firewall uid \$U\"
    if command -v psql > /dev/null; then
      sudo -u postgres psql -X -At -c \"select 'role ' || rolname from pg_roles where rolname = 'tando_\$A' union all select 'database ' || datname from pg_database where datname = 'tando_\$A'\" 2> /dev/null
    fi
    ls -d /var/backups/tando/\$A/.*.tmp 2> /dev/null | sed 's/^/backup-tmp /'
    n=0; for b in /var/backups/tando/\$A/*-final; do [ -f \"\$b/meta\" ] && n=\$((n + 1)); done
    [ \$n = $([ "$KIND" = data ] && echo 1 || echo 0) ] || echo \"final-backups \$n\"
    true" 2>> "$W/case.log")
  [ -z "$left" ] || mx_bad 14 "gone: $(printf '%s' "$left" | tr '\n' ';' | sed 's/;$//; s/;/, /g')"
  [ -z "$MX_BROKEN" ]
}

# ---- recovery as a server does it ----------------------------------------------------------------
# settled: no activation unit of the app (also none still loaded after it ended: the checker's
# leftover list counts those), the lock free (an ExecStopPost recover holds it)
mx_settled() {
  dxs "! systemctl list-units --all --plain --no-legend 'tando-$A-act-*' | grep -q . &&
       { [ ! -f /opt/tando/apps/$A/lock ] || flock -n /opt/tando/apps/$A/lock true; }"
}
mx_wait_settled() { T_UNTIL_STEP=0.5 t_until "${1:-240}" mx_settled; }
# what tando-watch's minute does (srv/watch/pretick.go recoverNeeded): recover-all when an app is
# in a phase other than idle with its lock free, its link and state disagree, it is down, a
# release is reserved by an activation whose unit has no process, a rollback cut before its first
# state write (activation says kind=rollback result=running, lock free), an operation's end was not
# written out (outcome), or an upload lease without a release id has lost its holder (lease_orphaned)
mx_watcher() {
  dxs "D=/opt/tando/apps/$A; g() { sed -n \"s/^\$1=//p\" \$D/state | head -1; }
    ph=\$(g phase); cur=\$(g current); l=\$(readlink \$D/current); l=\${l##*/}
    need=0
    if [ \"\${ph:-idle}\" != idle ]; then flock -n \$D/lock true && need=1
    elif [ -n \"\$cur\" ] && [ \"\$l\" != \"\$cur\" ] && [ -d \$D/releases/\$cur ]; then need=1
    elif [ -z \"\$cur\" ] && [ -n \"\$l\" ] && [ -d \$D/releases/\$l ]; then need=1
    elif [ -n \"\$(g down)\" ] && [ -z \"\$(g stopped)\" ] && [ -n \"\$cur\" ]; then need=1
    elif grep -qx kind=rollback \$D/activation 2>/dev/null && grep -qx result=running \$D/activation && flock -n \$D/lock true; then need=1
    elif [ -n \"\$(g outcome)\" ] && [ \"\$(g outcome)\" != \"\$(g outcome_done)\" ]; then need=1
    elif [ -f \$D/upload ] && ! grep -q '^id=' \$D/upload && grep -q '^token=.' \$D/upload && {
         { b=\$(sed -n 's/^boot=//p' \$D/upload); [ -n \"\$b\" ] &&
           [ \"\$b\" != \"\$(cat /proc/sys/kernel/random/boot_id)\" ]; } ||
         { h=\$(sed -n 's/^holder=//p' \$D/upload); [ -n \"\$h\" ] &&
           [ \"\$(awk '{ sub(/.*\\) /, \"\"); print \$20 }' /proc/\${h%% *}/stat 2> /dev/null)\" != \"\${h#* }\" ]; }; }
    then need=1
    else
      for r in \$D/releases/*; do i=\${r##*/}; [ -d \"\$r\" ] && [ -z \"\$(g status_\$i)\" ] && [ \"\$i\" != \"\$cur\" ] || continue
        grep -qs 'populated 1' /sys/fs/cgroup/system.slice/tando-$A-act-\$i.service/cgroup.events || need=1; done
    fi
    [ \$need = 1 ] && /opt/tando/bin/tando-agent recover-all; exit 0" >> "$W/case.log" 2>&1
}
# the server restarts (clean: systemd stops everything, the boot runs recover-all)
mx_reboot() {
  docker restart -t 10 "$TANDO_TEST_NAME" > /dev/null
  T_UNTIL_STEP=1 t_until 120 "$SSH" -o ConnectTimeout=2 true 2> /dev/null || return 1
  T_UNTIL_STEP=1 t_until 90 mx_booted || return 1
  rm -f "$TANDO_CONFIG_DIR"/cm-* 2> /dev/null
  mx_markers
}
mx_booted() { case $(dx systemctl is-system-running 2> /dev/null) in running|degraded) return 0;; esac; return 1; }
