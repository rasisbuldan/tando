# lib/views.sh: ls, status, history, releases, jobs, env ls. Rows come from the agent as
# tab-separated records; each field is only ever printed, never executed.

ago() { # epoch -> "3m ago"
  is_num "$1" || { printf -- '-'; return; }
  local d=$(( NOW - $1 )); [ $d -lt 0 ] && d=0; printf '%s ago' "$(ui_dur $d)"; }
when() { is_num "$1" && date -r "$1" '+%m-%d %H:%M' || printf -- '-'; }
secs() { case $1 in ""|*[!0-9.]*) printf -- '-';; *) ui_dur "$1";; esac; }
mb() { is_num "$1" && [ "$1" -gt 0 ] && ui_bytes "$1" || printf -- '-'; }
badge() { case $1 in rolledback) ui_badge rolled-back;; *) ui_badge "$1";; esac; }
var() { printf '%s' "$1" | tr -c 'a-zA-Z0-9\n' '_'; }   # app name -> variable suffix

fetch_status() { # [app] -> $TMPD/st
  agent_raw status ${1:+"$1"} > "$TMPD/st.new" || return 1; mv "$TMPD/st.new" "$TMPD/st"; NOW=$(now); }

host_line() { # from the host row
  local r n cpus load mt mu dt du up
  while IFS='	' read -r r n cpus load mt mu dt du up; do [ "$r" = host ] || continue
    ui_flow "$(ui_meter load "${load%%.*}" "$cpus" 8 "$load")" \
            "$(ui_meter mem "$mu" "$mt" 8 "$(mb "$mu")/$(mb "$mt")")" \
            "$(ui_meter disk "$du" "$dt" 8 "$(mb "$du")/$(mb "$dt")")" "${UI_DIM}up${UI_NC} $(ui_dur "$up")"
  done < "$TMPD/st"
}
cpu_pct() { # app cpu_ns uptime -> CPUP percent (delta since the last sample while watching, else average)
  local v; v=$(var "$1"); local pc="PC_$v" pt="PT_$v" p=""
  if [ -n "${!pc:-}" ] && [ "$NOW" -gt "${!pt}" ]; then p=$(( ($2 - ${!pc}) / 10000000 / (NOW - ${!pt}) ))
  elif is_num "$3" && [ "$3" -gt 0 ]; then p=$(( $2 / 10000000 / $3 )); fi
  printf -v "$pc" %s "$2"; printf -v "$pt" %s "$NOW"; CPUP=${p:-0}
}
render_ls() {
  local r a state port rel rst mem max cpu rs up link recipe n=0
  ui_box_open "tando ls" "$HOST"; host_line; ui_box_sep
  { printf 'APP\tSTATE\tRELEASE\tMEMORY\tCPU\tUP\tLINK\n'
    while IFS='	' read -r r a state port rel rst mem max cpu rs up link recipe; do [ "$r" = app ] || continue
      n=$((n + 1)); [ "$state" = active ] && state=running; [ "$state" = inactive ] && state=stopped
      cpu_pct "$a" "$cpu" "$up"
      printf '%s\t%s\t%s\t%s\t%s%%\t%s\t%s\n' "$a" "$(ui_badge "$state")" "${rel:--}" "$(mb "$mem")" \
        "$CPUP" "$( [ "$state" = running ] && ui_dur "$up" || printf -- '-')" "$link"
    done < "$TMPD/st"; } > "$TMPD/rows"
  if [ $n -gt 0 ]; then ui_table "l,l,l:8-17!3,r!2,r!4,r!5,l:10-" < "$TMPD/rows"; else ui_box_line "no apps yet: tando up"; fi
  ui_box_close "$n apps  $(date '+%H:%M:%S')"
}
cmd_ls() { resolve 0; watch_loop render_ls fetch_status; }

render_status() {
  local r a state port rel rst mem max cpu rs up link recipe v p
  while IFS='	' read -r r a state port rel rst mem max cpu rs up link recipe; do [ "$r" = app ] && break; done < "$TMPD/st"
  [ "$r" = app ] || die "no status for $APP"
  [ "$state" = active ] && state=running; [ "$state" = inactive ] && state=stopped
  cpu_pct "$a" "$cpu" "$up"; p=$CPUP
  SPC="$SPC $p" SPM="$SPM $mem"
  ui_box_open "$a" "$HOST"
  ui_kv state "$(ui_badge "$state")   ${UI_DIM}recipe${UI_NC} $recipe   ${UI_DIM}port${UI_NC} $port"
  ui_kv release "$rel  $( [ "$rst" != - ] && ui_badge "$rst")"
  ui_kv uptime "$( [ "$up" -gt 0 ] 2>/dev/null && ui_dur "$up" || printf -- '-')   ${UI_DIM}restarts${UI_NC} $rs"
  if is_num "$max" && [ "$max" -gt 0 ]; then ui_kv memory "$(ui_bar "$mem" "$max" 20) $(mb "$mem") of $(mb "$max")"
  else ui_kv memory "$(mb "$mem") (no cap)"; fi
  ui_kv cpu "$p%"
  [ -n "$WATCH" ] && ui_kv trend "cpu $(ui_spark "$SPC" 16)  mem $(ui_spark "$SPM" 16)"
  ui_kv link "$link"
  ui_box_sep releases
  { printf 'RELEASE\tSTATUS\t\n'
    while IFS='	' read -r r a state port rel; do [ "$r" = rel ] || continue
      printf '%s\t%s\t%s\n' "$a" "$(ui_badge "$state")" "$( [ "$port" = 1 ] && echo current)$( [ "$rel" = 1 ] && echo ' last good')"
    done < "$TMPD/st"; } > "$TMPD/rows"
  ui_table "l,l,l!1" < "$TMPD/rows"
  ui_box_sep "recent deploys"; hist_rows 5 > "$TMPD/rows"; ui_table "l,l,l,l,r,r!1" < "$TMPD/rows"
  ui_box_close "$(date '+%H:%M:%S')"
}
hist_rows() { # max -> WHEN RELEASE KIND RESULT TOTAL PHASES (newest first)
  printf 'WHEN\tRELEASE\tKIND\tRESULT\tTOTAL\tbuild/upload/copy/pre/switch/verify\n'
  grep '^hist	' "$TMPD/st" | sort -t '	' -k3,3nr | head -n "$1" |
  while IFS='	' read -r r a ts id kind res tot b u c p s v note; do
    printf '%s\t%s\t%s\t%s\t%s\t%s/%s/%s/%s/%s/%s\n' "$(when "$ts")" "$id" "$kind" "$(badge "$res")" "$(secs "$tot")" \
      "${b:--}" "${u:--}" "${c:--}" "${p:--}" "${s:--}" "${v:--}"
  done
}
cmd_status() { resolve 0
  if [ -z "$APP" ]; then cmd_ls; return; fi
  valid_app "$APP" || die "bad app name"; SPC="" SPM=""
  watch_loop render_status fetch_status "$APP"
}

cmd_history() { resolve 0; local r a ts id kind res tot b u c p s v note
  agent_raw history ${APP:+"$APP"} 30 > "$TMPD/st" || exit 1; NOW=$(now)
  ui_box_open "history${APP:+ $APP}" "$HOST"
  { printf 'WHEN\tAPP\tRELEASE\tKIND\tRESULT\tTOTAL\tBUILD\tUPLOAD\tCOPY\tPRE\tSWITCH\tVERIFY\tNOTE\n'
    sort -t '	' -k3,3nr "$TMPD/st" | while IFS='	' read -r r a ts id kind res tot b u c p s v note; do
      [ "$r" = hist ] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(when "$ts")" "$a" "$id" "$kind" "$(badge "$res")" \
        "$(secs "$tot")" "$b" "$u" "$c" "$p" "$s" "$v" "${note:-}"
    done; } > "$TMPD/rows"
  ui_table "l,l!7,l,l,l,r,r!4,r!3,r!5,r,r!6,r,l:4-30!9" < "$TMPD/rows"
  ui_box_close "phase times in seconds; newest first"
}

cmd_releases() { resolve 1; local r id st c g
  agent_raw releases "$APP" > "$TMPD/st" || exit 1
  ui_box_open "releases $APP" "$HOST"
  { printf 'RELEASE\tSTATUS\t\n'
    while IFS='	' read -r r id st c g; do [ "$r" = rel ] || continue
      printf '%s\t%s\t%s\n' "$id" "$(ui_badge "$st")" "$( [ "$c" = 1 ] && echo current)$( [ "$g" = 1 ] && echo ' last good')"
    done < "$TMPD/st"; } > "$TMPD/rows"
  ui_table "l,l,l" < "$TMPD/rows"; ui_box_close "newest 5 kept; current and last good never pruned"
}

cmd_jobs() { resolve 1; local r n cal nx la res code cmd
  agent_raw jobs "$APP" > "$TMPD/st" || exit 1; NOW=$(now)
  ui_box_open "jobs $APP" "$HOST"
  { printf 'JOB\tSCHEDULE\tNEXT\tLAST\tRESULT\tCOMMAND\n'
    while IFS='	' read -r r n cal nx la res code cmd; do [ "$r" = job ] || continue
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$cal" "$(when "$nx")" "$( [ "$la" != - ] && ago "$la" || echo never)" \
        "$( [ "$la" = - ] && echo - || { [ "$res" = success ] && ui_badge ok || ui_badge failed "$res"; })" "$cmd"
    done < "$TMPD/st"; } > "$TMPD/rows"
  ui_table "l,l,l!2,l!3,l,l:8-!1" < "$TMPD/rows"; ui_box_close "job.<name> = <OnCalendar> | <command> in tando.conf, then tando up"
}

cmd_env_ls() { resolve 1; local r k v
  agent_raw sudo env-ls "$APP" > "$TMPD/st" || exit 1
  ui_box_open "env $APP" "$HOST"
  { printf 'KEY\tVALUE\n'; while IFS='	' read -r r k v; do [ "$r" = env ] && printf '%s\t%s\n' "$k" "$v"; done < "$TMPD/st"; } > "$TMPD/rows"
  ui_table "l,l" < "$TMPD/rows"; ui_box_close "PORT and HOME are set by tando"
}

watch_loop() { # render fetch args...
  local render=$1 fetch=$2; shift 2
  $fetch "$@" || exit 1
  if [ -z "$WATCH" ]; then $render; return; fi
  trap "UI_WINCH=1" WINCH
  while :; do ui_frame_begin; $render; ui_frame_end; sleep "$WATCH"; $fetch "$@" || sleep "$WATCH"; done
}
