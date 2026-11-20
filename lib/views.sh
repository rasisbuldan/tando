# lib/views.sh: ls, status, history, releases, jobs, env ls, doctor. Rows come from the agent
# as tab-separated records; every field is only ever printed, never executed.

TAB='	'

# Times are GMT (UTC), like release ids: TIME (GMT) columns ("11-14 17:01", ui_utc); elsewhere a
# time within a day reads as an age ("3m ago", "in 4m"), an older one as "11-12 17:42 GMT".
# id_epoch turns a release id into a time.
local_time() { date -r "$1" "$2" 2> /dev/null || date -d "@$1" "$2" 2> /dev/null || printf -- -; }
ago() { # epoch -> "just now", "45s ago", "3m ago", "5h ago", else "11-12 17:42 GMT"
  ui_int "$1" || { printf -- '-'; return; }
  local d=$((NOW - $1))
  if [ $d -lt 0 ]; then d=$((-d))
    if [ $d -lt 60 ]; then printf 'in %ss' "$d"; elif [ $d -lt 3600 ]; then printf 'in %sm' $((d / 60))
    elif [ $d -lt 86400 ]; then printf 'in %sh %sm' $((d / 3600)) $((d % 3600 / 60)); else ui_utc "$1"; printf ' GMT'; fi
    return
  fi
  if [ $d -lt 10 ]; then printf 'just now'; elif [ $d -lt 60 ]; then printf '%ss ago' "$d"
  elif [ $d -lt 3600 ]; then printf '%sm ago' $((d / 60))
  elif [ $d -lt 86400 ]; then printf '%sh %sm ago' $((d / 3600)) $((d % 3600 / 60))
  else ui_utc "$1"; printf ' GMT'; fi
}
when() { if ui_int "$1"; then ago "$1"; else printf -- '-'; fi; }
id_epoch() { # release id (YYYYMMDD-HHMMSS, UTC) -> epoch, by the civil-from-days formula
  valid_id "$1" || { printf -- '-'; return; }
  local y=$((10#${1:0:4})) m=$((10#${1:4:2})) d=$((10#${1:6:2})) era yoe doy doe
  [ $m -le 2 ] && y=$((y - 1))
  era=$((y / 400)) yoe=$((y - y / 400 * 400))
  doy=$(( (153 * ((m + 9) % 12) + 2) / 5 + d - 1 )) doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  printf '%s' $(( (era * 146097 + doe - 719468) * 86400 + 10#${1:9:2} * 3600 + 10#${1:11:2} * 60 + 10#${1:13:2} ))
}

# to_json spec: TSV rows on stdin -> a JSON array of objects. spec is "key:type,...", one per
# column; type s (string), n (number) or b (1 -> true). "-" and "" are null.
to_json() {
  LC_ALL=C awk -F '\t' -v spec="$1" '
    function esc(v) { gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); return "\"" v "\"" }
    BEGIN { n = split(spec, K, ","); printf "[" }
    { printf "%s{", (NR > 1 ? "," : "")
      for (i = 1; i <= n; i++) {
        split(K[i], kt, ":"); v = $i
        if (kt[2] == "n") o = (v ~ /^-?[0-9]+(\.[0-9]+)?$/) ? v : "null"
        else if (kt[2] == "b") o = (v == "1") ? "true" : "false"
        else o = (v == "-" || v == "") ? "null" : esc(v)
        printf "%s\"%s\":%s", (i > 1 ? "," : ""), kt[1], o
      } printf "}" }
    END { printf "]" }'
}
json_str() { printf '%s' "$1" | LC_ALL=C awk '{ gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); printf "\"%s\"", $0 }'; }
secs() { case $1 in ""|*[!0-9.]*) printf -- '-';; *) ui_dur "$1";; esac; }
mb() { if ui_int "$1" && [ "$1" -gt 0 ]; then ui_bytes "$1"; else printf -- '-'; fi; }
# pg_note <rows file> <app>: "12 MB, 3 of 10 connections", from the pg row of tando-watch: the size
# of the app's PostgreSQL database and the connections of its role against the role's limit, as
# the checks last read them (the size every 10 minutes, the connections every minute). Nothing
# when there is no such row (no database, alerts off, PostgreSQL not answering and never asked).
pg_note() {
  local r a b c l o=""
  while IFS=$TAB read -r r a b c l; do
    [ "$r" = pg ] && [ "$a" = "$2" ] || continue
    o=""
    ui_int "$b" && o=$(ui_bytes "$b")
    ui_int "$c" || continue
    if ui_int "$l" && [ "$l" -gt 0 ]; then o="${o:+$o, }$c of $l connections"; else o="${o:+$o, }$c connections"; fi
  done < "$1"
  printf '%s' "$o"
}
# pg_json <rows file> <app>: the same as ,"database":{...} for --json (nothing without the row)
pg_json() {
  local o
  o=$(awk -F '\t' -v OFS='\t' -v a="$2" '$1 == "pg" && $2 == a { print $3, $4, $5 }' "$1" | tail -n 1 |
    to_json "bytes:n,connections:n,connection_limit:n" | sed 's/^\[//; s/\]$//')
  [ -z "$o" ] || printf ',"database":%s' "$o"
}
badge() { case $1 in rolledback) ui_badge rolled-back;; *) ui_badge "$1";; esac; }
marks() { # current-flag last-good-flag
  local m=""
  [ "$1" = 1 ] && m="current"
  [ "$2" = 1 ] && m="${m:+$m }last good"
  printf '%s' "$m"
}
state_word() { # agent state, release, recipe -> what ls and status call it
  case $1:${2:-x}:${3:-} in
    *:-:*|*::*) echo "not deployed";;
    active:*:static) echo static;;
    active:*) echo running;; inactive:*) echo down;; *) echo "$1";;
  esac
}
# down_word app state-word: "down" for an app that died (systemd failed, or not running with a down
# alert) rather than one stopped with tando stop; ls and status show it (JSON keeps the state)
down_word() {
  case $2 in
    failed) echo down;;
    stopped) if grep -q "^alert${TAB}$1${TAB}down${TAB}" "$TMPD/st" 2> /dev/null; then echo down
             else echo stopped; fi;;
    *) echo "$2";;
  esac
}
state_badge() {
  case $1 in down) ui_badge failed down;; "not deployed") ui_badge new "not deployed";; static) ui_badge running static;;
    *) ui_badge "$1";; esac
}
short_link() { local l=${1#http://}; l=${l#https://}; printf '%s' "$l"; }
var() { printf '%s' "$1" | tr -c 'a-zA-Z0-9\n' '_'; }   # app name -> variable suffix

fetch_status() { # [app] -> $TMPD/st
  agent_raw sudo status ${1:+"$1"} > "$TMPD/st.new" || return 1
  mv "$TMPD/st.new" "$TMPD/st"
  NOW=$(now)
}

host_line() { # from the host row
  local r n cpus load mt mu dt du up
  while IFS=$TAB read -r r n cpus load mt mu dt du up; do
    [ "$r" = host ] || continue
    ui_flow "$(ui_meter load "${load%%.*}" "$cpus" 8 "$load")" \
            "$(ui_meter mem "$mu" "$mt" 8 "$(mb "$mu")/$(mb "$mt")")" \
            "$(ui_meter disk "$du" "$dt" 8 "$(mb "$du")/$(mb "$dt")")" \
            "${UI_DIM}up${UI_NC} $(ui_dur "$up")"
  done < "$TMPD/st"
}

# cpu_pct app cpu_ns uptime -> CPUP: percent since the previous sample while watching,
# otherwise the average since the app started
cpu_pct() {
  local v pc pt p=""
  ui_int "$2" || set -- "$1" 0 "${3:-}"   # server fields never reach $(( )) unchecked (N4)
  ui_int "${3:-}" || set -- "$1" "$2" 0
  v=$(var "$1"); pc="PC_$v" pt="PT_$v"
  if [ -n "${!pc:-}" ] && [ "$NOW" -gt "${!pt}" ]; then
    p=$(( ($2 - ${!pc}) / 10000000 / (NOW - ${!pt}) ))
  elif ui_int "$3" && [ "$3" -gt 0 ]; then
    p=$(( $2 / 10000000 / $3 ))
  fi
  printf -v "$pc" %s "$2"
  printf -v "$pt" %s "$NOW"
  CPUP=${p:-0}
}

# the app rows of $TMPD/st with the columns ls --json and status --json share
app_json_rows() {
  local r a state port rel rst mem max cpu rs up link recipe bk last db lb lcap lines hourly doms lcpu ltasks lconns lreq lx
  while IFS=$TAB read -r r a state port rel rst mem max cpu rs up link recipe bk last db lb lcap lines hourly doms lcpu ltasks lconns lreq lx; do
    [ "$r" = app ] || continue
    cpu_pct "$a" "$cpu" "$up"
    lim_clean
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$(state_word "$state" "$rel" "$recipe")" \
      "$recipe" "$port" "$rel" "$(id_epoch "$rel")" "$rst" "$mem" "$max" "$CPUP" "$rs" "$up" "$link" "$db" "${lb:-}" "${doms:-}" \
      "$lcpu" "$ltasks" "$lconns" "$lreq"
  done < "$TMPD/st"
}
APP_JSON="app:s,state:s,recipe:s,port:n,release:s,deployed_at:n,release_status:s,memory_bytes:n,memory_max_bytes:n,cpu_percent:n,restarts:n,uptime_s:n,link:s,database:s,log_bytes:n,domains:s,cpu_limit:s,tasks_max:n,max_conns:n,max_requests:n"
# lim_clean: the app's limits from the server (cpu "50%" or "1.5" cores, "-" = no cap), else "-"
lim_clean() {
  case ${lcpu:-} in [0-9]%|[0-9][0-9]%|[0-9][0-9][0-9]%|[0-9]|[0-9].[0-9]|[0-9].[0-9][0-9]|[0-9][0-9]|[0-9][0-9].[0-9]) ;; *) lcpu=-;; esac
  ui_int "${ltasks:-}" || ltasks=-; ui_int "${lconns:-}" || lconns=-; ui_int "${lreq:-}" || lreq=-
}
# limits_line: one "limits" row in status (an older agent sends none: no row)
limits_line() {
  lim_clean
  [ "$ltasks$lconns$lreq" = --- ] && return 0
  local c="no cap"
  case $lcpu in -) ;; *%) c=$lcpu;; *) c="$lcpu cores";; esac
  local q="no 503 limit"; [ "$lreq" = - ] || q="503 over $lreq in flight"
  ui_kv_wrap limits "cpu $c ${UI_G_MID} $ltasks tasks ${UI_G_MID} $lconns conns ${UI_G_MID} $q"
}

render_ls() {
  local r a state port rel rst mem max cpu rs up link recipe bk last db lb lcap lines hourly doms lcpu ltasks lconns lreq lx n=0 upt dep
  if [ -n "$JSON" ]; then
    printf '{"host":%s,"apps":' "$(json_str "$HOST")"; app_json_rows | to_json "$APP_JSON"; printf '}\n'
    return
  fi
  {
    printf 'APP\tSTATE\tDEPLOYED\tMEMORY\tCPU\tUP\tLOGS\tLINK\n'
    while IFS=$TAB read -r r a state port rel rst mem max cpu rs up link recipe bk last db lb lcap lines hourly doms lcpu ltasks lconns lreq lx; do
      [ "$r" = app ] || continue
      n=$((n + 1))
      case ${doms:--} in -) ;; *,*) link="${doms%%,*} +$(printf '%s' "$doms" | tr -cd , | wc -c | tr -d ' ')";; *) link=$doms;; esac
      state=$(down_word "$a" "$(state_word "$state" "$rel" "$recipe")")
      cpu_pct "$a" "$cpu" "$up"
      upt=- dep=-
      [ "$state" = running ] && upt=$(ui_dur "$up")
      [ "$state" = "not deployed" ] || dep=$(ago "$(id_epoch "$rel")")
      printf '%s\t%s\t%s\t%s\t%s%%\t%s\t%s\t%s\n' "$a" "$(state_badge "$state")" "$dep" "$(mb "$mem")" \
        "$CPUP" "$upt" "$(mb "${lb:-}")" "$(short_link "$link")"
    done < "$TMPD/st"
  } > "$TMPD/rows"
  ui_box_open "tando ls" "$HOST"
  host_line
  grep -q "^check${TAB}fail${TAB}caddy" "$TMPD/st" 2> /dev/null &&
    ui_box_line "${UI_RED}caddy is not running: no app is reachable (tando doctor)${UI_NC}"
  ui_box_sep
  cache_apps
  if [ $n -gt 0 ]; then ui_table "l,l,l!3,r!2,r!4,r!5,r!6,l" < "$TMPD/rows"   # LINK whole: other columns go first
  else ui_box_line "No apps on $HOST yet. In your app's directory: tando up"; fi
  hc_hint
  local na foot
  na=$(grep -c "^alert${TAB}[^${TAB}]*${TAB}[^${TAB}]*${TAB}firing" "$TMPD/st")
  foot="$(plural $n app)"
  [ "$na" -gt 0 ] && foot="$foot  ${UI_RED}$(plural "$na" alert) firing: tando alerts${UI_NC}"
  [ $n -gt 0 ] && foot="$foot ${UI_G_MID} tando status <app> for details"
  ui_box_close "$foot ${UI_G_MID} $(watch_note)"
}
# hc_hint: one line when host care has something to do (the hostcare row of status: tando-host's
# hourly summary, a file read on the server; nothing extra runs)
hc_hint() {
  local r todo fail warn at
  while IFS=$TAB read -r r todo fail warn at; do
    [ "$r" = hostcare ] && ui_int "$todo" && [ "$todo" -gt 0 ] || continue
    if ui_int "$fail" && [ "$fail" -gt 0 ]; then
      ui_box_line "${UI_RED}server: $todo to do, $fail failing: tando host status${UI_NC}"
    else ui_box_line "${UI_YELLOW}server: $todo to do: tando host status${UI_NC}"; fi
  done < "$TMPD/st"
  return 0
}
watch_note() { if [ -n "$WATCH" ]; then printf 'every %ss %s Ctrl-C stops' "$WATCH" "$UI_G_MID"; else date -u '+%H:%M:%S GMT'; fi; }
# app names per host for shell completions (never read over the network)
cache_apps() {
  mkdir -p "$CFG/cache" 2> /dev/null || return 0
  awk -F '\t' '$1 == "app" {print $2}' "$TMPD/st" | write_file "$CFG/cache/apps.$HOST" 2> /dev/null
  return 0
}
cmd_ls() { resolve 0; watch_loop render_ls fetch_status; }

hist_rows() { # max -> TIME (GMT) RELEASE KIND RESULT TOTAL, newest first; the notes -> $TMPD/notes
  local r a ts id kind res tot b u c p s v note
  printf 'TIME (GMT)\tRELEASE\tKIND\tRESULT\tTOTAL\n'
  : > "$TMPD/notes"
  grep "^hist$TAB" "$TMPD/st" | sort -t "$TAB" -k3,3nr | head -n "$1" |
  while IFS=$TAB read -r r a ts id kind res tot b u c p s v note; do
    ui_utc_v "$ts"
    printf '%s\t%s\t%s\t%s\t%s\n' "$UI_RET" "$id" "$kind" "$(badge "$res")" "$(secs "$tot")"
    hist_note "$id" "$kind" "$res" "$note" >> "$TMPD/notes"
  done
}
# hist_note id kind result note: "id: note" for a rollback or a failure that has a reason
hist_note() {
  case ${4:--} in -|"") return 0;; esac
  case $2:$3 in
    rollback:*) case $4 in from\ *) printf '%s: rolled back to it %s\n' "$1" "$4";; *) printf '%s: %s\n' "$1" "$4";; esac;;
    *:rolledback|*:failed|*:bad) printf '%s: %s\n' "$1" "$4";;
  esac
}
# hist_notes_box: the reasons under a history table, wrapped (never cut at 80 columns)
hist_notes_box() {
  local l
  [ -s "$TMPD/notes" ] || return 0
  while IFS= read -r l; do ui_box_wrap "  ${UI_DIM}why${UI_NC} $l"; done < "$TMPD/notes"
}

render_status() {
  local r a state port rel rst mem max cpu rs up link recipe bk last db lb lcap lines hourly c g upt doms lcpu ltasks lconns lreq lx
  while IFS=$TAB read -r r a state port rel rst mem max cpu rs up link recipe bk last db lb lcap lines hourly doms lcpu ltasks lconns lreq lx; do
    [ "$r" = app ] && break
  done < "$TMPD/st"
  [ "$r" = app ] || die "no status for $APP"
  if [ -n "$JSON" ]; then status_json; return; fi
  state=$(down_word "$a" "$(state_word "$state" "$rel" "$recipe")")
  cpu_pct "$a" "$cpu" "$up"
  SPC="$SPC $CPUP" SPM="$SPM $mem"
  # without --watch, the trend comes from the server's per-minute samples (tando-metrics)
  local mrows hm="" hc=""
  if [ -z "$WATCH" ] && mrows=$(awk -F '\t' '$1 == "m" {print $3, $4}' "$TMPD/st") && [ -n "$mrows" ]; then
    hm=$(printf '%s\n' "$mrows" | awk '{printf "%s ", $1}')
    hc=$(printf '%s\n' "$mrows" | awk '{printf "%d ", $2 / 10}')
  fi
  upt=-
  [ "$state" = running ] && upt=$(ui_dur "$up")
  ui_box_open "$a" "$HOST"
  if [ "$state" = down ]; then
    ui_kv state "$(state_badge down) (not stopped by you)   ${UI_DIM}recipe${UI_NC} $recipe"
    ui_kv next "tando logs -a $a; then tando start -a $a"
  fi
  [ "$state" = down ] ||
    ui_kv state "$(state_badge "$state")   ${UI_DIM}recipe${UI_NC} $recipe   ${UI_DIM}port${UI_NC} $port"
  if [ "$state" = "not deployed" ]; then ui_kv release "none yet: tando up (or tando deploy) in its directory"
  elif [ "$rst" != - ]; then ui_kv release "$rel  $(badge "$rst")  ${UI_DIM}deployed $(ago "$(id_epoch "$rel")")${UI_NC}"
  else ui_kv release "$rel"; fi
  ui_kv uptime "$upt   ${UI_DIM}restarts${UI_NC} $rs"
  if ui_int "$max" && [ "$max" -gt 0 ]; then
    ui_kv memory "$(ui_bar "$mem" "$max" 20) $(mb "$mem") of $(mb "$max")"
  else
    ui_kv memory "$(mb "$mem") (no cap)"
  fi
  ui_kv cpu "$CPUP%"
  limits_line
  if [ -n "$WATCH" ]; then ui_kv trend "cpu $(ui_spark "$SPC" 16)  mem $(ui_spark "$SPM" 16)"
  elif [ -n "$hm" ]; then ui_kv "16 min" "cpu $(ui_spark "$hc" 16)  mem $(ui_spark "$hm" 16)"; fi
  ui_kv link "$link"
  local dn dw de
  while IFS=$TAB read -r r dn dw de; do
    [ "$r" = domain ] || continue
    if ui_int "$de"; then de="certificate until $(TZ=UTC local_time "$de" '+%Y-%m-%d')"; else de="no certificate yet"; fi
    [ "$dw" = off ] || dw="www $dw, " ; [ "$dw" = off ] && dw=""
    ui_kv domain "https://$dn  ${UI_DIM}${dw}$de${UI_NC}"
  done < "$TMPD/st"
  while IFS=$TAB read -r r a c g up rel; do
    [ "$r" = alert ] || continue
    if [ "$g" = firing ]; then ui_kv alert "$(ui_badge failed "$c") $rel ${UI_DIM}since $(ago "$up")${UI_NC}"
    else ui_kv alert "$(ui_badge pending "$c pending") $rel"; fi
  done < "$TMPD/st"
  if [ "$db" != - ]; then
    local pgn; pgn=$(pg_note "$TMPD/st" "$APP")
    ui_kv database "$db${pgn:+  $pgn}"
  fi
  if ui_int "${lb:-}"; then   # disk use of journal + request log, the journal cap, 24 h of lines
    # retention from the logcfg row (keep hours, request log budget); an older agent sends none
    local lkh="" lrq="" lw
    while IFS=$TAB read -r r a lw lrq _; do
      [ "$r" = logcfg ] && ui_int "$lw" && lkh=$lw
    done < "$TMPD/st"
    if [ -n "$lkh" ]; then
      if [ $((lkh % 24)) = 0 ]; then lw="$((lkh / 24)) d"; else lw="$lkh h"; fi
      # the lines first: a new app's journal is pre-allocated (8 MB), which says nothing about use
      # (the sparkline last: it is what a narrow terminal cuts)
      ui_kv logs "${lines:-0} lines/24h  ${UI_DIM}journal $(mb "$lb") of $(mb "${lcap:-}"), keeps $lw${UI_NC}  $(ui_spark "$(printf '%s' "${hourly:-}" |
        tr ',' ' ')" 24)"
    else
      ui_kv logs "${lines:-0} lines/24h  ${UI_DIM}journal $(mb "$lb") (cap $(mb "${lcap:-}"))${UI_NC}  $(ui_spark "$(printf '%s' "${hourly:-}" |
        tr ',' ' ')" 24)"
    fi
  fi
  if [ "$bk" = daily ]; then
    if ! ui_int "$last"; then ui_kv backup "daily, ${UI_YELLOW}no backup yet${UI_NC}"
    elif [ $((NOW - last)) -gt 172800 ]; then
      ui_kv backup "daily, ${UI_YELLOW}last $(ago "$last"): older than 2 days${UI_NC}"
    else ui_kv backup "daily, last $(ago "$last")"; fi
  fi
  # offsite copies (tando-offsite's state, one row): last upload, waiting, late, failing
  local olu opn oop oah ocr oer
  while IFS=$TAB read -r r olu opn oop oah ocr oer; do
    [ "$r" = offsite ] || continue
    if [ "$ocr" = failing ]; then ui_kv offsite "${UI_RED}credentials fail${UI_NC}: tando backup offsite test"
    elif ui_int "$oop" && [ "$oop" -gt 0 ] && [ $((NOW - oop)) -gt $((${oah:-6} * 3600)) ]; then
      ui_kv offsite "${UI_YELLOW}$opn waiting, oldest $(ago "$oop")${UI_NC}${oer:+ ($oer)}"
    elif ui_int "$opn" && [ "$opn" -gt 0 ]; then ui_kv offsite "$opn uploading$(ui_int "$olu" && [ "$olu" -gt 0 ] && printf ', last upload %s' "$(ago "$olu")")"
    elif ui_int "$olu" && [ "$olu" -gt 0 ]; then ui_kv offsite "copied, last upload $(ago "$olu")"
    else ui_kv offsite "on, nothing uploaded yet"; fi
  done < "$TMPD/st"
  ui_box_sep releases
  rel_rows > "$TMPD/rows"
  ui_table "l,l,l!2,l!1" < "$TMPD/rows"
  ui_box_sep history
  hist_rows 5 > "$TMPD/rows"
  if [ "$(wc -l < "$TMPD/rows")" -le 1 ]; then ui_box_line "${UI_DIM}no deploy has finished yet${UI_NC}"
  else ui_table "l,l,l,l,r" < "$TMPD/rows"; fi
  hist_notes_box
  ui_box_close "$(watch_note)"
}
rel_rows() { # RELEASE STATUS DEPLOYED marks, from the rel rows of $TMPD/st
  local r id st c g
  printf 'RELEASE (UTC)\tSTATUS\tDEPLOYED\t\n'
  while IFS=$TAB read -r r id st c g; do
    [ "$r" = rel ] && printf '%s\t%s\t%s\t%s\n' "$id" "$(badge "$st")" "$(ago "$(id_epoch "$id")")" "$(marks "$c" "$g")"
  done < "$TMPD/st"
}
rel_json() {
  local r id st c g
  while IFS=$TAB read -r r id st c g; do
    [ "$r" = rel ] && printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$(id_epoch "$id")" "$st" "$c" "$g"
  done < "$TMPD/st" | to_json "id:s,deployed_at:n,status:s,current:b,last_good:b"
}
HIST_JSON="at:n,app:s,release:s,kind:s,result:s,total_s:n,build_s:n,upload_s:n,copy_s:n,preflight_s:n,switch_s:n,verify_s:n,note:s,release_s:n"
# (release_s: the seconds of the release command, null for a deploy without one)
hist_json() { grep "^hist$TAB" "$TMPD/st" | sort -t "$TAB" -k3,3nr | cut -f2-15 |
  awk -F '\t' -v OFS='\t' '{ print $2, $1, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14 }' | to_json "$HIST_JSON"; }
status_json() {
  printf '{"host":%s,"app":' "$(json_str "$HOST")"
  app_json_rows | to_json "$APP_JSON" | sed 's/^\[//; s/\]$//'
  printf ',"releases":'; rel_json
  printf ',"history":'; hist_json
  printf ',"alerts":'
  awk -F '\t' -v OFS='\t' '$1 == "alert" { print $2, $3, $4, $5, $6 }' "$TMPD/st" | to_json "app:s,check:s,state:s,since:n,detail:s"
  pg_json "$TMPD/st" "$APP"
  printf '}\n'
}
cmd_status() {
  resolve 0
  if [ -z "$APP" ]; then cmd_ls; return; fi
  valid_app "$APP" || die "bad app name"
  SPC="" SPM=""
  watch_loop render_status fetch_status "$APP"
}

cmd_history() {
  resolve 0
  local r a ts id kind res tot b u c p s v note rc n=30 hasrc="" spec
  [ "$NLINES" != 100 ] && n=$NLINES
  [ "$n" -gt 999 ] && n=999
  agent_raw sudo history ${APP:+"$APP"} "$n" > "$TMPD/st" || exit 1
  NOW=$(now)
  if [ -n "$JSON" ]; then printf '{"host":%s,"history":' "$(json_str "$HOST")"; hist_json; printf '}\n'; return; fi
  : > "$TMPD/notes"
  # RELCMD (the release command's seconds, a 15th field) is a column only when a deploy shown ran one
  awk -F '\t' '$1 == "hist" && NF >= 15 { f = 1 } END { exit !f }' "$TMPD/st" && hasrc=1
  {
    printf 'TIME (GMT)\tAPP\tRELEASE\tKIND\tRESULT\tTOTAL\tBUILD\tUPLOAD\tCOPY\tPRE\t%sSWITCH\tVERIFY\tNOTE\n' "${hasrc:+RELCMD$TAB}"
    sort -t "$TAB" -k3,3nr "$TMPD/st" |
    while IFS=$TAB read -r r a ts id kind res tot b u c p s v note rc; do
      [ "$r" = hist ] || continue
      hist_note "$id" "$kind" "$res" "$note" >> "$TMPD/notes"
      case $kind in deploy) ;; *) [ "$b" = 0 ] && b=-; [ "$u" = 0 ] && u=-;; esac   # not built or uploaded
      ui_utc_v "$ts"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s%s\t%s\t%s\n' "$UI_RET" "$a" "$id" "$kind" \
        "$(badge "$res")" "$(secs "$tot")" "$b" "$u" "$c" "$p" "${hasrc:+${TAB}${rc:--}}" "$s" "$v" "$note"
    done
  } > "$TMPD/rows"
  ui_box_open "history${APP:+ $APP}" "$HOST"
  # dropped first when narrow: note, phase times, app, release; never TIME (GMT) or RESULT
  if [ "$(wc -l < "$TMPD/rows")" -le 1 ]; then ui_box_line "No deploys yet: tando up"
  else
    spec="l,l!5,l!4,l,l,r,r!6,r!7,r!8,r!9,r!10,r!11,l:4-30!12"
    [ -z "$hasrc" ] || spec="l,l!5,l!4,l,l,r,r!6,r!7,r!8,r!9,r!10,r!11,r!12,l:4-30!13"
    ui_table "$spec" < "$TMPD/rows"
    # the NOTE column was dropped or cut: the reasons of rollbacks and failures, whole, below
    case $UI_TABLE_SHOWN in
      *0) hist_notes_box;;
      *) awk '{ i = index($0, ": "); if (length($0) - i - 1 > 30) f = 1 } END { exit !f }' "$TMPD/notes" &&
           hist_notes_box;;
    esac
  fi
  ui_box_close "phase times in seconds; newest first"
}

cmd_releases() {
  resolve 1
  agent_raw sudo releases "$APP" > "$TMPD/st" || exit 1
  NOW=$(now)
  if [ -n "$JSON" ]; then
    printf '{"host":%s,"app":%s,"releases":' "$(json_str "$HOST")" "$(json_str "$APP")"; rel_json; printf '}\n'; return
  fi
  rel_rows > "$TMPD/rows"
  ui_box_open "releases $APP" "$HOST"
  if [ "$(wc -l < "$TMPD/rows")" -le 1 ]; then ui_box_line "No releases yet: tando up"
  else ui_table "l,l,l,l" < "$TMPD/rows"; fi
  ui_box_close "newest 5 kept; current and last good never pruned"
}

# jobs_run name: run a scheduled job now; its output, then its result and exit status
jobs_run() {
  local name=$1
  case $name in ""|*[!A-Za-z0-9_-]*) usage_err "bad job name: $name (tando jobs lists them)" jobs;; esac
  note "running job $name of $APP on $HOST..."
  agent sudo job-run "$APP" "$name" < /dev/null > "$TMPD/jr"
  kv_read "$TMPD/jr" result status secs timeout
  sed -n 's/^log=//p' "$TMPD/jr"
  if [ "${K_status:-1}" = 0 ] && [ "${K_result:-success}" = success ]; then note "job $name: ok in ${K_secs:-?}s"; return 0; fi
  case $K_timeout in *[!0-9a-z\ ]*) K_timeout="?";; esac   # (the server's words, shown)
  if [ "${K_result:-}" = timeout ]; then
    note "job $name: timed out after ${K_secs:-?}s and was stopped (its limit: ${K_timeout:-?}; job_timeout in tando.conf)"
    return 124
  fi
  note "job $name: failed (${K_result:-failed}, exit ${K_status:-?}) in ${K_secs:-?}s"
  ui_int "${K_status:-}" && [ "$K_status" -gt 0 ] && [ "$K_status" -lt 256 ] && return "$K_status"
  return 1
}

cmd_jobs() {
  resolve 1
  [ "${ARGS[1]:-ls}" = run ] && { jobs_run "${ARGS[2]:-}"; return; }
  local r n cal next last res code cmd lastw resw
  agent_raw sudo jobs "$APP" > "$TMPD/st" || exit 1
  NOW=$(now)
  {
    printf 'JOB\tSCHEDULE\tNEXT\tLAST\tRESULT\tCOMMAND\n'
    while IFS=$TAB read -r r n cal next last res code cmd; do
      [ "$r" = job ] || continue
      if [ "$last" = - ]; then lastw=never resw=-
      else
        lastw=$(ago "$last")
        if [ "$res" = success ]; then resw=$(ui_badge ok); else resw=$(ui_badge failed "$res"); fi
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$cal" "$(when "$next")" "$lastw" "$resw" "$cmd"
    done < "$TMPD/st"
  } > "$TMPD/rows"
  ui_box_open "jobs $APP" "$HOST"
  if [ "$(wc -l < "$TMPD/rows")" -le 1 ]; then
    ui_box_line "No jobs. Add a line to tando.conf, then tando up:"
    ui_box_line "  job.nightly = daily | node scripts/nightly.js"
    ui_box_close "job.<name> = <OnCalendar> | <command> in tando.conf, then tando up"
  else
    ui_table "l,l,l!2,l!3,l,l:8-!1" < "$TMPD/rows"
    ui_box_close "run one now: tando jobs run <name>"
  fi
}

cmd_env_ls() {
  resolve 1
  local r k v
  agent_raw sudo env-ls "$APP" > "$TMPD/st" || exit 1
  {
    printf 'KEY\tVALUE\n'
    while IFS=$TAB read -r r k v; do
      [ "$r" = env ] || continue
      # values are secrets more often than not: hidden unless --show (like tando db url --show)
      case $v in ""|*"****"*) ;; *) [ -n "$SHOW" ] || v="******** ($(plural ${#v} character))";; esac
      printf '%s\t%s\n' "$k" "$v"
    done < "$TMPD/st"
  } > "$TMPD/rows"
  ui_box_open "env $APP" "$HOST"
  if [ "$(wc -l < "$TMPD/rows")" -le 1 ]; then ui_box_line "No variables yet: tando env set KEY=VALUE (or tando env import .env)"
  else ui_table "l,l" < "$TMPD/rows"; fi
  if [ -n "$SHOW" ]; then ui_box_close "PORT, HOME and TANDO_DATA_DIR are set by tando"
  else ui_box_close "values hidden: tando env ls --show prints them"; fi
}

# doctor_prog_differs name detail: is this row "a program on the server differs from the client's"
# (agent, gate, logs, metrics, watch, status, daemon, offsite, host; the agent words it three ways)?
doctor_prog() { case $1 in agent|gate|logs|metrics|watch|status|daemon|offsite|host) return 0;; esac; return 1; }
doctor_prog_differs() {
  doctor_prog "$1" || return 1
  case $2 in *"differs from this tando"*|*" on the laptop: "*|*"differs from the client"*) return 0;; esac
  return 1
}

cmd_doctor() {
  [ -n "${ARGS[1]:-}" ] && HOST=${ARGS[1]}
  resolve 0
  local r state name detail warn=0 fail=0 avail=$(( ${UI_IN:-76} - 26 )) nprog=0 ndiff=0 shown=""
  : > "$TMPD/dnotes"
  # shellcheck disable=SC2046  # four checksums, one word each
  # (the sums of tando-status and tandod come after the version, named: an older agent ignores them)
  agent_raw sudo doctor $(server_sums) "$(client_version)" "status=$(server_sums tando-status | tr -d ' ')" \
    "tandod=$(server_sums tandod | tr -d ' ')" "offsite=$(server_sums tando-offsite | tr -d ' ')" \
    "host=$(server_sums tando-host | tr -d ' ')" > "$TMPD/st" || exit 1
  # after a client upgrade every program differs: nine near-identical rows would bury the findings
  # that matter, so they become one row (--verbose lists each)
  while IFS=$TAB read -r r state name detail; do
    [ "$r" = check ] || continue
    doctor_prog "$name" && nprog=$((nprog + 1))
    ! doctor_prog_differs "$name" "$detail" || ndiff=$((ndiff + 1))
  done < "$TMPD/st"
  {
    printf 'CHECK\tSTATE\tDETAIL\n'
    while IFS=$TAB read -r r state name detail; do
      [ "$r" = check ] || continue
      detail=${detail//<host>/$HOST}
      if [ -z "$VERBOSE" ] && doctor_prog_differs "$name" "$detail"; then
        [ -n "$shown" ] && continue
        shown=1; name=programs
        detail="$ndiff of $nprog programs differ from the client's $(client_version): tando host setup $HOST"
      fi
      case $name:$detail in metrics:sampled*|metrics:"no sample"*) name="metrics sample";; esac
      case $state in
        ok) printf '%s\t%s\t%s\n' "$name" "$(ui_badge ok)" "$detail";;
        warn) warn=$((warn + 1)); printf '%s\t%s\t%s\n' "$name" "$(ui_badge deploying warn)" "$detail";;
        *) fail=$((fail + 1)); printf '%s\t%s\t%s\n' "$name" "$(ui_badge failed fail)" "$detail";;
      esac
      # a warning or failure too long for its cell: whole, wrapped, under the table (it holds the fix)
      [ "$state" != ok ] && [ ${#detail} -gt $avail ] && printf '%s: %s\n' "$name" "$detail" >> "$TMPD/dnotes"
    done < "$TMPD/st"
  } > "$TMPD/rows"
  ui_box_open "doctor" "$HOST"
  ui_table "l,l,l" < "$TMPD/rows"
  if [ -s "$TMPD/dnotes" ]; then
    ui_box_sep
    # a note too long for one line puts its command (the last "tando ...") on a line of its own, whole
    while IFS= read -r r; do
      _ui_avail
      case $r in
        *" tando "*) if [ ${#r} -gt "$_UA" ]; then
                       name=${r% tando *}; ui_box_wrap "$name"; ui_box_wrap "  tando ${r#"$name" tando }"; continue
                     fi;;
      esac
      ui_box_wrap "$r"
    done < "$TMPD/dnotes"
  fi
  ui_box_close "$fail failed, $(plural "$warn" warning)${shown:+; --verbose lists each program that differs}"
  [ $fail -eq 0 ]
}

# watch_loop render fetch args...: one view, or repaint every $WATCH seconds
watch_loop() {
  local render=$1 fetch=$2
  shift 2
  $fetch "$@" || exit 1
  if [ -z "$WATCH" ]; then $render; return; fi
  trap 'UI_WINCH=1' WINCH
  trap 'exit 0' INT              # Ctrl-C is how a watch ends: not an error
  while :; do
    ui_frame_begin
    $render
    ui_frame_end
    sleep "$WATCH"
    $fetch "$@" || sleep "$WATCH"
  done
}

cmd_backup_ls() {
  local r id kind created size what where off="" err=""
  agent_raw sudo backup-ls "$APP" > "$TMPD/st" || exit 1
  NOW=$(now)
  # WHERE (a 7th field from an agent with offsite copies): local, both, offsite, local+pending ...
  grep -Eq '	(offsite|both|local\+[a-z]+)$' "$TMPD/st" && off=1
  {
    printf 'TIME (GMT)\tBACKUP\tKIND\tSIZE\tHOLDS%s\n' "${off:+	WHERE}"
    while IFS=$TAB read -r r id kind created size what where; do
      [ "$r" = offsite-error ] && { err=$id; continue; }
      [ "$r" = backup ] || continue
      ui_utc_v "$created"
      case $where in
        both) where="local + offsite";;
        offsite) where="offsite only";;
        local+pending|local+uploading) where="local, uploading";;
        local+failed) where="local, ${UI_YELLOW}upload failed${UI_NC}";;
      esac
      printf '%s\t%s\t%s\t%s\t%s%s\n' "$UI_RET" "$id" "$kind" "$(ui_bytes "$size")" "$what" "${off:+	$where}"
    done < "$TMPD/st"
  } > "$TMPD/rows"
  ui_box_open "backups $APP" "$HOST"
  if [ "$(wc -l < "$TMPD/rows")" -gt 1 ]; then
    if [ -n "$off" ]; then ui_table "l,l,l!2,r,l!1,l" < "$TMPD/rows"; else ui_table "l,l,l!2,r,l!1" < "$TMPD/rows"; fi
  else ui_box_line "No backups. Apps with data = <dir> or database = ... in tando.conf are backed up daily."; fi
  [ -n "$err" ] && ui_box_wrap "${UI_YELLOW}offsite storage did not answer:${UI_NC} $err"
  if [ -n "$off" ]; then ui_box_close "keeps 7 daily, 4 weekly, 5 of each other kind, every final; offsite: tando backup offsite"
  else ui_box_close "keeps 7 daily, 4 weekly, 5 of each other kind, every final"; fi
}

# ---- several hosts -------------------------------------------------------------------------

# fetch_hosts host...: `status` from every host in parallel into $TMPD/h.<host>.{st,rc,err};
# hosts that have not answered within 10 s are marked as timed out
fetch_hosts() {
  local h missing
  for h; do
    (
      host_use "$h"
      ERRF="$TMPD/h.$h.err"
      agent_raw sudo status > "$TMPD/h.$h.st" 2> /dev/null
      echo $? > "$TMPD/h.$h.rc.tmp" && mv "$TMPD/h.$h.rc.tmp" "$TMPD/h.$h.rc"
    ) 2> /dev/null &
  done
  # at most 10 s of wall clock (not a count of sleeps, which a busy machine stretches)
  local end=$((SECONDS + 11))
  while [ $SECONDS -lt $end ]; do
    missing=0
    for h; do [ -f "$TMPD/h.$h.rc" ] || missing=1; done
    [ $missing = 0 ] && break
    sleep 0.1
  done
  for h; do
    [ -f "$TMPD/h.$h.rc" ] && continue
    echo 124 > "$TMPD/h.$h.rc"; echo "no answer within 10 s" > "$TMPD/h.$h.err"
  done
  local pids
  pids=$(jobs -p)
  # shellcheck disable=SC2086  # a list of pids
  [ -n "$pids" ] && kill $pids 2> /dev/null
  return 0
}
all_hosts() { local f; for f in "$CFG"/hosts/*; do [ -f "$f" ] && printf '%s ' "${f##*/}"; done; }
host_err() { # the reason a host did not answer, in a few words
  local e; e=$(strip < "$TMPD/h.$1.err" 2> /dev/null | grep . | tail -3)
  case $e in
    *"tando-agent: No such file"*) echo "not set up: tando host setup $1";;
    *"password is required"*|*"terminal is required"*) echo "no passwordless sudo (tando host add $1 ... checks)";;
    *"Connection refused"*) echo "connection refused";;
    *"Permission denied"*) echo "key refused";;
    *"Host key verification failed"*|*"host key is known"*) echo "host key not trusted";;
    *"timed out"*|*"no answer"*) echo "no answer";;
    *) printf '%s\n' "$e" | tail -1;;
  esac
}

# ls --all: every registered server, in parallel; --watch repaints, --json is one object
# {"hosts": [{"host", "apps"} or {"host", "error"}]}
cmd_ls_all() {
  LS_HOSTS=$(all_hosts)
  [ -n "$LS_HOSTS" ] || die "no hosts registered: tando host add"
  watch_loop render_ls_all fetch_ls_all
}
# shellcheck disable=SC2086  # a list of host names
fetch_ls_all() { rm -f "$TMPD"/h.*.rc; fetch_hosts $LS_HOSTS; }
render_ls_all() {
  local h e sep=""
  [ -n "$JSON" ] && printf '{"hosts":['
  for h in $LS_HOSTS; do
    if [ "$(cat "$TMPD/h.$h.rc")" = 0 ]; then
      cp "$TMPD/h.$h.st" "$TMPD/st"; HOST=$h NOW=$(now)
      if [ -n "$JSON" ]; then printf '%s' "$sep"; render_ls | tr -d '\n'; sep=,; else render_ls; fi
    elif [ -n "$JSON" ]; then
      e=$(host_err "$h")
      printf '%s{"host":%s,"error":%s}' "$sep" "$(json_str "$h")" "$(json_str "${e:-unreachable}")"; sep=,
    else
      ui_box_open "tando ls" "$h"
      ui_box_line "$(ui_badge failed unreachable)  $(host_err "$h")"
      ui_box_close
    fi
  done
  [ -n "$JSON" ] && printf ']}\n'
  return 0
}

host_ls() {
  local h hosts apps reach care
  hosts=$(all_hosts)
  # shellcheck disable=SC2086
  [ -n "$hosts" ] && fetch_hosts $hosts
  {
    printf 'NAME\tTARGET\tPORT\tAPPS\tCARE\tREACHABLE\tHOST KEY\n'
    for h in $hosts; do
      care=-
      if [ "$(cat "$TMPD/h.$h.rc")" = 0 ]; then
        apps=$(grep -c "^app$TAB" "$TMPD/h.$h.st"); reach=$(ui_badge ok yes)
        care=$(awk -F '\t' '$1 == "hostcare" { print $2 "\t" $3; exit }' "$TMPD/h.$h.st")
        case $care in "") care=-;; "0$TAB"*) care=$(ui_badge ok ok);;
          *) if [ "${care#*"$TAB"}" != 0 ]; then care=$(ui_badge failed "${care%%"$TAB"*} to do"); else care=$(ui_badge deploying "${care%%"$TAB"*} to do"); fi;; esac
      else
        apps=- reach=$(ui_badge failed "$(host_err "$h")")
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t' "$h" "$(host_get "$h" target)" "$(host_get "$h" port)" "$apps" "$care" "$reach"
      if [ "$(host_get "$h" insecure)" = 1 ]; then echo 'not checked (test)'; else echo strict; fi
    done
  } > "$TMPD/h"
  ui_box_open "hosts"
  if [ -z "$hosts" ]; then ui_box_line "No servers yet. Add one:  tando host add vps admin@203.0.113.7"
  else ui_table "l,l,r!4,r!5,l!3,l:6-40,l!2" < "$TMPD/h"; fi
  local t='~'
  ui_box_close "${CFG/#$HOME/$t}/hosts"
}
