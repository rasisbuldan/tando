# lib/cmd-adopt.sh: tando adopt: bring a hand-deployed Next.js app under tando, in place.
# help: adopt plan|apply <unit> [--health /path] [--no-jobs] | undo|status <app> | site <app> [--apply]   take over a hand-deployed app
#
#   tando adopt plan <unit> -H <host>     read-only: what changes, what does not, downtime, risks
#   tando adopt apply <unit> -H <host>    backup, register, switch, timers, verify; rolls back on failure
#   tando adopt undo <app> -H <host>      back to the recorded hand-managed state, verified
#   tando adopt status <app> -H <host>    the steps of the latest apply or undo
#   tando adopt site <app> -H <host>      what the hand-written Caddy site lacks (request hold, request
#                                         log); --apply adds it: copy, validate, reload, check
#
# The server does the work: tando-agent adopt-* with server/tando-adopt, which this file installs.
# Nothing here reads or prints an env file:
# the plan shows variable names only. See docs/MIGRATION.md. bash 3.2.

AD_TAB='	'

# ad_wrap prefix text: one or more box lines, the text wrapped under the prefix
ad_wrap() {
  local pre=$1 w l first=1 pad
  ui_width "$pre"
  w=$((UI_IN - UI_RET - 1))
  [ "$w" -lt 20 ] && w=20
  pad=$(printf '%*s' "$UI_RET" '')
  while IFS= read -r l; do
    if [ $first = 1 ]; then ui_box_line "$pre$l"; first=0; else ui_box_line "$pad$l"; fi
  done < <(printf '%s\n' "$2" | fold -s -w "$w")
}

ad_opts() { # sets AD_UNIT AD_HEALTH AD_JOBS AD_YES from ARGS[2..]
  local i=2 n=${#ARGS[@]}
  AD_UNIT="" AD_HEALTH=/ AD_JOBS=yes AD_YES="" AD_APPLY=""
  while [ $i -lt $n ]; do
    case ${ARGS[$i]} in
      --health) i=$((i + 1)); AD_HEALTH=${ARGS[$i]:-};;
      --no-jobs) AD_JOBS=no;;
      --yes) AD_YES=1;;
      --apply) AD_APPLY=apply;;
      -*) die "adopt: unknown option ${ARGS[$i]}";;
      *) [ -z "$AD_UNIT" ] || die "adopt: one unit at a time"; AD_UNIT=${ARGS[$i]};;
    esac
    i=$((i + 1))
  done
  AD_UNIT=${AD_UNIT%.service}
  case $AD_UNIT in ""|*[!A-Za-z0-9_.@-]*) die "usage: tando adopt plan|apply <unit> | undo|status <app>";; esac
  case $AD_HEALTH in /*) ;; *) die "--health takes a path under the app's base path, like /health";; esac
  case $AD_HEALTH in *[!A-Za-z0-9._~/-]*) die "bad health path: $AD_HEALTH";; esac
}

# the server side of adopt (server/tando-adopt) is installed on demand, like the agent itself
ad_install() {
  install_helpers tando-adopt ||
    die "could not install the adopt helper: $(strip < "$TMPD/err" | tail -2 | tr '\n' ' ')"
}

# ad_scan: the agent's read-only scan into $TMPD/scan; K_* for the facts used here
ad_scan() {
  agent sudo adopt-scan "$AD_UNIT" "health=$AD_HEALTH" > "$TMPD/scan"
  kv_read "$TMPD/scan" unit app port user root link link_target path start data_dir data_owner data_size \
    data_files data_env env_file env_mode env_names memory check_url public_dirs preflight_port jobs \
    ready_ms backup_script health blocked baseline writable
}

ad_plan_box() { # title
  local kind a b c d e lvl col n=0
  ui_box_open "$1" "$HOST"
  ui_kv app "$K_app   ${UI_DIM}port${UI_NC} $K_port   ${UI_DIM}user${UI_NC} $K_user"
  ui_kv release "$K_link -> ${K_link_target#$K_root/}"
  [ -n "$K_data_dir" ] && ui_kv data "$K_data_dir  $(ui_bytes "${K_data_size:-0}") in ${K_data_files:-0} files${K_data_env:+  ($K_data_env)}"
  [ -n "$K_env_file" ] && ad_wrap "$(printf '%-12s' 'env file')" "$K_env_file  names only: $(printf '%s' "$K_env_names" | sed 's/,/, /g')"
  ui_kv site "$K_check_url$K_path   ${UI_DIM}health${UI_NC} $K_path$K_health"
  case $K_baseline in
    ok) ui_kv now "$(ui_badge running) healthy through Caddy, static files included";;
    *) ui_kv now "$(ui_badge failed) ${K_baseline:-unknown}";;
  esac
  ui_box_sep "will change"
  while IFS="$AD_TAB" read -r kind a b c; do
    [ "$kind" = chg ] || continue
    if [ "$b" = - ]; then ad_wrap "  • " "$a: $c"; else ad_wrap "  • " "$a: $b  →  $c"; fi
  done < "$TMPD/scan"
  ui_box_sep "will not change"
  while IFS="$AD_TAB" read -r kind a b; do
    [ "$kind" = keep ] && ad_wrap "  • " "$a: $b"
  done < "$TMPD/scan"
  if grep -q "^job$AD_TAB" "$TMPD/scan"; then
    ui_box_sep "timers"
    {
      printf 'JOB\tTIMER\tSCHEDULE\tTANDO JOB\n'
      while IFS="$AD_TAB" read -r kind a b c d e; do
        [ "$kind" = job ] || continue
        if [ "$d" = yes ]; then d="yes"; else d="no: $e"; fi
        printf '%s\t%s\t%s\t%s\n' "$a" "$b" "$c" "$d"
      done < "$TMPD/scan"
    } > "$TMPD/jobs"
    ui_table "l,l!2,l,l:8-" < "$TMPD/jobs"
  fi
  ui_box_sep "downtime"
  ad_wrap "  " "One restart of the app: Caddy answers 502 from the moment ${K_unit}.service stops until tando-$K_app answers; its last start took ${K_ready_ms:-?} ms here. Static files switch with no gap. Timers hand over between two runs."
  ui_box_sep "risks"
  for lvl in high medium low; do
    case $lvl in high) col=$UI_RED;; medium) col=$UI_YELLOW;; *) col=$UI_DIM;; esac
    while IFS="$AD_TAB" read -r kind a b; do
      [ "$kind" = risk ] && [ "$a" = $lvl ] || continue
      ad_wrap "  ${col}$(printf '%-6s' "$lvl")${UI_NC} " "$b"; n=$((n + 1))
    done < "$TMPD/scan"
  done
  [ $n = 0 ] && ui_box_line "  none found"
  if [ "$K_blocked" = 1 ]; then
    ui_box_sep "blocked"
    while IFS="$AD_TAB" read -r kind a; do [ "$kind" = block ] && ad_wrap "  ${UI_RED}✗${UI_NC} " "$a"; done < "$TMPD/scan"
  fi
}

# the tando.conf that matches the adopted app (written only where none exists)
ad_conf() { # file
  local kind a b c d e
  {
    echo "# written by tando adopt from $K_unit.service on $HOST; review build before the first deploy"
    echo "app = $K_app"
    echo "host = $HOST"
    echo "recipe = next"
    echo "# the hand-written deploy may build differently (standalone output, precompressed files)"
    echo "build = npm run build"
    echo "start = $K_start"
    [ -n "$K_path" ] && echo "path = $K_path"
    echo "health = $K_health"
    echo "health_timeout = 60"
    echo "memory = ${K_memory:-512M}"
    echo "writable = ${K_writable:-.next/server/app}"
    while IFS="$AD_TAB" read -r kind a b c d e; do
      [ "$kind" = job ] && [ "$d" = yes ] && [ "$AD_JOBS" = yes ] && echo "job.$a = $c | $e"
    done < "$TMPD/scan"
  } > "$1"
}

# ad_site_rows file: the "site" rows of adopt-site as box lines; AD_SITE_TODO counts what is missing
ad_site_rows() {
  local kind what st det mark
  AD_SITE_TODO=0
  while IFS="$AD_TAB" read -r kind what st det; do
    [ "$kind" = site ] || continue
    case $st in
      have) mark="${UI_GREEN}✓${UI_NC}";;
      add) mark="${UI_YELLOW}+${UI_NC}"; AD_SITE_TODO=$((AD_SITE_TODO + 1));;
      *) mark="${UI_YELLOW}!${UI_NC}"; AD_SITE_TODO=$((AD_SITE_TODO + 1));;
    esac
    ad_wrap "  $mark $(printf '%-5s' "$what")" "$det"
  done < "$1"
}

ad_follow() { # title total: poll adopt-status until a result; steps as they finish
  local shown="" kind n name st secs det errs=0
  while :; do
    if ! agent_raw sudo adopt-status "$APP" > "$TMPD/as" 2> /dev/null; then
      errs=$((errs + 1)); [ $errs -lt 60 ] || die "lost contact; the run continues on the server: tando adopt status $APP"
      sleep 1; continue
    fi
    errs=0
    while IFS="$AD_TAB" read -r kind n name st secs det; do
      [ "$kind" = step ] || continue
      case $st in ok|fail) ;; *) continue;; esac
      case " $shown " in *" $n "*) continue;; esac
      ui_step "$n" "$2" "$name" "$st" "${secs}s  $det"
      shown="$shown $n"
    done < "$TMPD/as"
    kv_read "$TMPD/as" result message backup release_id
    case $K_result in ok|failed|rolledback|interrupted) break;; esac
    sleep 0.5
  done
}

cmd_adopt() {
  local sub=${ARGS[1]:-} typed
  case $sub in
    plan)
      ad_opts; resolve 0; ad_install; ad_scan
      ad_plan_box "adopt plan $AD_UNIT"
      if [ "$K_blocked" = 1 ]; then ui_box_close "nothing can be adopted yet"; exit 1; fi
      ui_box_close "tando adopt apply $AD_UNIT -H $HOST${AD_HEALTH:+ --health $AD_HEALTH}";;
    apply)
      ad_opts; resolve 0; ad_install; ad_scan
      ad_plan_box "adopt plan $AD_UNIT"
      if [ "$K_blocked" = 1 ]; then ui_box_close "blocked: nothing was changed"; exit 1; fi
      ui_box_close "full backup first; any failed check returns to the hand-managed state"
      APP=$K_app
      if [ -z "$AD_YES" ]; then
        printf 'Type the app name to adopt it: ' >&2
        IFS= read -r typed || typed=""
        [ "$typed" = "$APP" ] || die "not confirmed; nothing was changed"
      fi
      agent sudo adopt-apply "$AD_UNIT" "health=$AD_HEALTH" "jobs=$AD_JOBS" > "$TMPD/o"
      ui_box_open "adopt $APP" "$HOST"
      trap 'echo; note "detached: the adoption continues on the server (tando adopt status $APP)"; exit 130' INT TERM
      ad_follow "adopt $APP" 6
      trap 'exit 130' INT TERM
      case $K_result in
        ok)
          ui_kv backup "$K_backup"
          if [ ! -f tando.conf ]; then ad_conf tando.conf; ui_kv tando.conf "written here (check its build line)"
          else ad_conf tando.conf.adopted; ui_kv tando.conf "exists; the adopted settings are in tando.conf.adopted"; fi
          # what the hand-written site lacks next to one tando renders (never edited by apply)
          if agent_raw sudo adopt-site "$APP" > "$TMPD/site" 2> /dev/null; then
            if grep -q "^site${AD_TAB}[a-z]*${AD_TAB}\(add\|manual\)${AD_TAB}" "$TMPD/site"; then
              ui_box_sep "your Caddy site"; ad_site_rows "$TMPD/site"
              ad_wrap "  " "tando adopt site $APP -H $HOST --apply adds what is marked +, with a copy of the Caddyfile, a validation and a reload."
            fi
          fi
          ui_box_close "adopted: tando deploy ships the next release; tando adopt undo goes back"
          ;;
        *)
          ad_wrap "${UI_RED}" "$K_message${UI_NC}"
          ui_box_close "$K_result"; exit 1;;
      esac;;
    undo)
      ad_opts; resolve 0; APP=$AD_UNIT
      valid_app "$APP" || die "bad app name: $APP"
      ad_install
      if [ -z "$AD_YES" ]; then
        note "This stops tando-$APP and starts the hand-written unit again, as recorded at adoption."
        printf 'Type the app name to confirm: ' >&2
        IFS= read -r typed || typed=""
        [ "$typed" = "$APP" ] || die "not confirmed; nothing was changed"
      fi
      agent sudo adopt-undo "$APP" > "$TMPD/o"
      ui_box_open "adopt undo $APP" "$HOST"
      ad_follow "undo $APP" 2
      if [ "$K_result" = ok ]; then ui_box_close "$K_message"
      else ad_wrap "${UI_RED}" "$K_message${UI_NC}"; ui_box_close "$K_result"; exit 1; fi;;
    site)
      ad_opts; resolve 0; APP=$AD_UNIT
      valid_app "$APP" || die "bad app name: $APP"
      ad_install
      agent sudo adopt-site "$APP" $AD_APPLY > "$TMPD/site"
      kv_read "$TMPD/site" changes kept result
      ui_box_open "adopt site $APP" "$HOST"
      ad_site_rows "$TMPD/site"
      if [ -n "$AD_APPLY" ]; then
        [ -n "$K_kept" ] && ui_kv "copy" "$K_kept (the Caddyfile as it was)"
        if [ "$K_result" = added ]; then ui_box_close "added and reloaded; $APP answers through Caddy"
        else ui_box_close "${K_result:-nothing changed}"; fi
      elif [ "${K_changes:-0}" -gt 0 ]; then ui_box_close "tando adopt site $APP -H $HOST --apply"
      else ui_box_close "nothing to add automatically"; fi;;
    status)
      ad_opts; resolve 0; APP=$AD_UNIT
      valid_app "$APP" || die "bad app name: $APP"
      ad_install
      ui_box_open "adopt status $APP" "$HOST"
      ad_follow "status $APP" 6
      [ -n "$K_message" ] && ad_wrap "  " "$K_result: $K_message"
      ui_box_close;;
    *) die "usage: tando adopt plan|apply <unit> [--health /path] [--no-jobs] [--yes] | undo|status <app> | site <app> [--apply]";;
  esac
}
