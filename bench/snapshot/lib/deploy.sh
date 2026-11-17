# lib/deploy.sh: init, configure, build, stage, guard, upload, activation with progress.

cmd_init() { # writes tando.conf from what the directory looks like
  [ -f tando.conf ] && { note "tando.conf exists"; return 0; }
  local name recipe out=. start="" health=/ build=""
  name=$(basename "$PWD" | tr 'A-Z_ ' 'a-z--' | tr -cd 'a-z0-9-' | cut -c1-26)
  if [ -f package.json ]; then
    recipe=node
    grep -q '"next"' package.json && note "next.js detected: the next recipe is not in this prototype; using node"
    grep -q '"build"[[:space:]]*:' package.json && build="npm run build"
    start="npm start"; grep -q '"start"[[:space:]]*:' package.json || start="node server.js"
    [ -f server.js ] || [ -f index.js ] && { [ -f server.js ] && start="node server.js" || start="node index.js"; }
  else
    recipe=static
    for out in dist public build .; do [ -f "$out/index.html" ] && break; done
    [ -f "$out/index.html" ] || die "cannot tell what this is: no package.json, no index.html"
  fi
  { echo "app = $name"; [ -n "$HOST" ] && echo "host = $HOST"; echo "recipe = $recipe"
    [ -n "$build" ] && echo "build = $build"; [ "$out" != . ] && echo "out = $out"
    [ -n "$start" ] && echo "start = $start"; echo "health = $health"; echo "memory = 256M"; } > tando.conf
  note "wrote tando.conf ($recipe)"
}

# send tando.conf settings to the server (creates the app on first use)
configure() {
  { printf 'recipe=%s\n' "${C_recipe:-node}"; [ -n "$C_start" ] && printf 'start=%s\n' "$C_start"
    printf 'health=%s\nmemory=%s\n' "${C_health:-/}" "${C_memory:-256M}"
    [ -n "$C_timeout" ] && printf 'health_timeout=%s\n' "$C_timeout"
    printf '%s' "$C_jobs"; } | agent sudo configure "$APP" > "$TMPD/cfg"
  kv_read "$TMPD/cfg" link port created
}

stage() { # out dir -> .tando/stage (mtimes kept so rsync sends only deltas)
  local out=${C_out:-.} st=.tando/stage bad l t d
  [ -d "$out" ] || die "out directory not found: $out"
  mkdir -p "$st"
  rsync -a -c --delete --exclude=/.tando --exclude=.git --exclude=.DS_Store --exclude='.env*' \
    --exclude=tando.conf "$out/" "$st/" || die "staging failed"
  bad=$(find "$st" -name '.env*' | head -3); [ -z "$bad" ] || die "secret files in the release: $bad"
  find "$st" -type l > "$TMPD/links"
  while IFS= read -r l; do t=$(readlink "$l")
    case $t in /*) die "symlink to an absolute path: ${l#$st/} -> $t";; esac
    d=$(cd "$(dirname "$l")" && cd "$(dirname "$t")" 2>/dev/null && pwd -P) || die "dangling symlink: ${l#$st/}"
    case "$d/" in "$(cd "$st" && pwd -P)"/*) ;; *) die "symlink leaves the release: ${l#$st/} -> $t";; esac
  done < "$TMPD/links"
  find "$st" -name '*.node' -type f > "$TMPD/native"
  while IFS= read -r l; do d=$(file -b "$l")
    case "$K_arch:$d" in x86_64:*ELF*x86-64*|aarch64:*ELF*aarch64*|aarch64:*ELF*ARM\ aarch64*) ;;
      *) die "native module built for another platform (server is $K_arch): ${l#$st/}";; esac
  done < "$TMPD/native"
}

phase_line() { # n label state seconds [detail]
  local d=""; [ -n "$4" ] && d=$(ui_dur "$4"); ui_step "$1" 7 "$2" "$3" "$d${5:+  $5}"; }

do_deploy() { # assumes resolve 1 and configure (or app exists)
  local t0 t tb=0 tu=0 id sent shown="" last="" ph
  agent info > "$TMPD/info"; kv_read "$TMPD/info" arch
  ui_box_open "deploy $APP" "$HOST"
  t0=$(now)
  if [ -n "$C_build" ]; then
    /bin/sh -c "$C_build" > "$TMPD/build.log" 2>&1 || { phase_line 1 build fail ""; ui_box_close; tail -20 "$TMPD/build.log"; exit 1; }
    tb=$(( $(now) - t0 )); phase_line 1 build ok "$tb"
  else phase_line 1 build skip ""; fi
  t=$(now); stage; phase_line 2 stage ok "$(( $(now) - t ))"; tb=$(( $(now) - t0 ))
  t=$(now)
  rsync -rlptz -c --delete --stats -e "ssh ${SSHO[*]}" .tando/stage/ "$TARGET:/opt/tando/apps/$APP/incoming/" \
    > "$TMPD/rsync" 2>&1 || { phase_line 3 upload fail ""; ui_box_close; strip < "$TMPD/rsync" | tail -5; exit 1; }
  tu=$(( $(now) - t ))
  sent=$(sed -n 's/^Total sent: \([0-9]*\).*/\1/p' "$TMPD/rsync")
  UPLOAD_FILES=$(sed -n 's/^Number of files transferred: \([0-9]*\).*/\1/p' "$TMPD/rsync") UPLOAD_BYTES=$sent
  phase_line 3 upload ok "$tu" "${UPLOAD_FILES:-0} files changed, $(ui_bytes "${sent:-0}") sent"
  agent sudo activate "$APP" "$tb" "$tu" > "$TMPD/act"; kv_read "$TMPD/act" id; id=$K_id
  valid_id "$id" || die "agent returned no release id"
  ui_box_line "      release $id"
  # poll; the activation runs on the server whether or not we keep watching
  local errs=0
  trap 'echo; note "detached: release $id keeps activating on the server (tando releases)"; exit 130' INT
  while :; do
    if ! agent_raw deploy-status "$APP" "$id" > "$TMPD/ds"; then errs=$((errs + 1))
      [ $errs -lt 60 ] || die "lost contact; the activation continues on the server: tando releases"; sleep 1; continue; fi
    errs=0
    kv_read "$TMPD/ds" phase result message link t_copy t_preflight t_switch t_verify
    for ph in copy preflight switch verify; do
      case " $shown " in *" $ph "*) continue;; esac
      case $ph in copy) t=$K_t_copy;; preflight) t=$K_t_preflight;; switch) t=$K_t_switch;; verify) t=$K_t_verify;; esac
      [ -n "$t" ] || break
      case $ph in copy) n=4;; preflight) n=5;; switch) n=6;; verify) n=7;; esac
      if [ "$K_result" = failed ] && [ "$ph" = preflight ] || { [ "$K_result" = rolledback ] && [ "$ph" = verify ]; }
      then phase_line $n $ph fail "$t"; else phase_line $n $ph ok "$t"; fi
      shown="$shown $ph"
    done
    case $K_result in ok|failed|rolledback|bad|verified|unknown) break;; esac
    sleep 0.5
  done
  trap 'exit 130' INT
  n=4; for ph in copy preflight switch verify; do
    case " $shown " in *" $ph "*) ;; *) phase_line $n $ph skip "";; esac; n=$((n + 1)); done
  case $K_result in
    ok|verified) ui_box_close "live in $(ui_dur $(( $(now) - t0 )))  $K_link"; return 0;;
    *) [ -n "$K_message" ] && ui_box_line "${UI_RED}$K_message${UI_NC}"
       grep '^log=' "$TMPD/ds" | sed 's/^log=/      /' | while IFS= read -r l; do ui_box_line "$l"; done
       if [ "$K_result" = rolledback ]; then ui_box_close "release $id: rolled back to the last good release"
       else ui_box_close "release $id: $K_result; the running app was not touched"; fi
       return 1;;
  esac
}
