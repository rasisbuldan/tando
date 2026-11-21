# lib/views.sh: ls, status, history, releases, jobs, env ls, doctor. Rows come from the agent
# as tab-separated records; every field is only ever printed, never executed.

TAB='	'

# Times are GMT (UTC), like release ids: TIME (GMT) columns ("11-14 17:01", ui_utc); elsewhere a
# time within a day reads as an age ("3m ago", "in 4m"), an older one as "11-12 17:42 GMT" (with
# its year, "2028-02-29 23:59 GMT", when that is not this year).
# id_epoch turns a release id into a time.
local_time() { date -r "$1" "$2" 2> /dev/null || date -d "@$1" "$2" 2> /dev/null || printf -- -; }
ago_date() { # epoch -> "11-12 17:42 GMT", with the year when it is not NOW's
  local y; ui_utc_v "$NOW"; y=$UI_YEAR; ui_utc_v "$1"; [ "$UI_YEAR" = "$y" ] || ui_utc_v "$1" y; printf '%s GMT' "$UI_RET"
}
ago() { # epoch -> "just now", "45s ago", "3m ago", "5h ago", else "11-12 17:42 GMT"
  ui_int "$1" || { printf -- '-'; return; }
  local d=$((NOW - $1))
  if [ $d -lt 0 ]; then d=$((-d))
    if [ $d -lt 60 ]; then printf 'in %ss' "$d"; elif [ $d -lt 3600 ]; then printf 'in %sm' $((d / 60))
    elif [ $d -lt 86400 ]; then printf 'in %sh %sm' $((d / 3600)) $((d % 3600 / 60)); else ago_date "$1"; fi
    return
  fi
  if [ $d -lt 10 ]; then printf 'just now'; elif [ $d -lt 60 ]; then printf '%ss ago' "$d"
  elif [ $d -lt 3600 ]; then printf '%sm ago' $((d / 60))
  elif [ $d -lt 86400 ]; then printf '%sh %sm ago' $((d / 3600)) $((d % 3600 / 60))
  else ago_date "$1"; fi
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

# cpu_min permille -> CPUP: the app's CPU over the last minute (tando-metrics' last sample, the app
# row's 26th field, per mille of one core) as "12%" or "0.4%"; "-" without one (no sample yet, or
# an older agent). The same window in ls and status, with and without --watch. CPUN: the number
# (percent, for JSON), "" without one.
cpu_min() {
  if ui_int "${1:-}" && [ ${#1} -le 9 ]; then   # server fields never reach $(( )) unchecked (N4)
    local v=$((10#$1))
    if [ $v -ge 100 ]; then CPUP="$((v / 10))%"; else CPUP="$((v / 10)).$((v % 10))%"; fi
    CPUN="$((v / 10)).$((v % 10))"
  else CPUP=- CPUN=""; fi
}

# the app rows of $TMPD/st with the columns ls --json and status --json share
app_json_rows() {
  firing_load
  local r a state port rel rst mem max cpu rs up link recipe bk last db lb lcap lines hourly doms lcpu ltasks lconns lreq cpum lx
  while IFS=$TAB read -r r a state port rel rst mem max cpu rs up link recipe bk last db lb lcap lines hourly doms lcpu ltasks lconns lreq cpum lx; do
    [ "$r" = app ] || continue
    cpu_min "${cpum:-}"
    lim_clean
    firing_of "$a"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$(state_word "$state" "$rel" "$recipe")" \
      "$recipe" "$port" "$rel" "$(id_epoch "$rel")" "$rst" "$mem" "$max" "$CPUN" "$rs" "$up" "$link" "$db" "${lb:-}" "${doms:-}" \
      "$lcpu" "$ltasks" "$lconns" "$lreq" "$FIREN" "$FIRED"
  done < "$TMPD/st"
}
APP_JSON="app:s,state:s,recipe:s,port:n,release:s,deployed_at:n,release_status:s,memory_bytes:n,memory_max_bytes:n,cpu_percent:n,restarts:n,uptime_s:n,link:s,database:s,log_bytes:n,domains:s,cpu_limit:s,tasks_max:n,max_conns:n,max_requests:n,alerts_firing:n,firing:s"
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

# worker_lines: one "worker" line per worker row of status (name, state, restarts, memory)
worker_lines() {
  local r wa wn ws wr wm wx t
  while IFS=$TAB read -r r wa wn ws wr wm wx; do
    [ "$r" = worker ] || continue
    case $ws in
      active) t=running;;
      restarting) t="${UI_RED}restarting${UI_NC}: it keeps exiting (tando logs --worker $wn)";;
      stopped) t=stopped;;
      *) t="${UI_YELLOW}$ws${UI_NC}";;
    esac
    if ui_int "$wx" && [ "$wx" -gt 0 ]; then wm="$(mb "$wm") of $(mb "$wx")"; else wm=$(mb "$wm"); fi
    ui_kv worker "$wn  $t   ${UI_DIM}restarts${UI_NC} $wr   ${UI_DIM}memory${UI_NC} $wm"
  done < "$TMPD/st"
  return 0
}
# worker_hint: in ls, one line per worker that does not run while its app does
worker_hint() {
  local r wa wn ws wr _x
  while IFS=$TAB read -r r wa wn ws wr _x; do
    [ "$r" = worker ] || continue
    case $ws in active|stopped) continue;; esac
    ui_box_line "${UI_RED}$wa: worker $wn is $ws ($wr restarts): tando status $wa, tando logs $wa --worker $wn${UI_NC}"
  done < "$TMPD/st"
  return 0
}
# skew_load: from the server row of status (the server's clock and tando version; an older agent
# sends none): SKEW (server minus laptop seconds, "" unknown), SRV_VER, CLI_VER (no fork)
SKEW_MAX=30
skew_load() {
  local r se sv _x
  SKEW="" SRV_VER="" CLI_VER=""
  { IFS= read -r CLI_VER || :; } < "${TANDO_HOME:-.}/VERSION" 2> /dev/null
  case $CLI_VER in [0-9]*.[0-9]*.[0-9]*) case $CLI_VER in *[!0-9.]*) CLI_VER="";; esac;; *) CLI_VER="";; esac
  while IFS=$TAB read -r r se sv _x; do
    [ "$r" = server ] || continue
    ui_int "$se" && [ ${#se} -le 12 ] && ui_int "${NOW:-}" && SKEW=$((10#$se - NOW))
    case $sv in [0-9]*.[0-9]*.[0-9]*) case $sv in *[!0-9.]*) ;; *) SRV_VER=$sv;; esac;; esac
  done < "$TMPD/st"
  return 0
}
# skew_line: one line when the server's clock is off from this laptop's by more than SKEW_MAX
# seconds (every age on screen is off by as much), or the server's tando is not this client's
skew_line() {
  skew_load
  local d=${SKEW:-0} w=ahead
  [ "$d" -lt 0 ] && d=$((-d)) w=behind
  if [ "$d" -gt "$SKEW_MAX" ]; then
    ui_box_wrap "${UI_YELLOW}clock: the server's is $(ui_dur "$d") $w of this laptop's; ages here are off by that (is time sync on, here and there?)${UI_NC}"
  fi
  if [ -n "$SRV_VER" ] && [ -n "$CLI_VER" ] && [ "$SRV_VER" != "$CLI_VER" ]; then
    ui_box_wrap "${UI_YELLOW}tando $SRV_VER on the server, $CLI_VER here: tando host setup $HOST (or update this laptop's tando)${UI_NC}"
  fi
  return 0
}
# json_meta: the fields every ls/status --json object starts with, after "host": reachable, when
# the data was read (laptop clock), the server's clock and version, this client's, the skew
json_meta() {
  skew_load
  printf ',"reachable":true,"checked_at":%s,"server_version":%s,"client_version":%s,"clock_skew_s":%s' \
    "$NOW" "$( [ -n "$SRV_VER" ] && json_str "$SRV_VER" || printf null)" \
    "$( [ -n "$CLI_VER" ] && json_str "$CLI_VER" || printf null)" "${SKEW:-null}"
}
# json_alerts: ,"alerts":[...] every alert row (firing and pending, apps and the host)
json_alerts() {
  printf ',"alerts":'
  awk -F '\t' -v OFS='\t' '$1 == "alert" { print $2, $3, $4, $5, $6 }' "$TMPD/st" | to_json "app:s,check:s,state:s,since:n,detail:s"
}
# firing_load: FIRING = " app:check ..." for every firing alert in $TMPD/st (no fork)
firing_load() {
  local r fa fc fs _x
  FIRING=""
  while IFS=$TAB read -r r fa fc fs _x; do
    [ "$r" = alert ] && [ "$fs" = firing ] || continue
    case $fa$fc in *[!a-z0-9_.-]*) continue;; esac   # plain words only: the list is word-split
    FIRING="$FIRING $fa:$fc"
  done < "$TMPD/st"
  return 0
}
# firing_of app: the checks firing for app, comma separated -> FIRED (and FIREN, their count)
firing_of() {
  local x
  FIRED="" FIREN=0
  for x in $FIRING; do
    [ "${x%%:*}" = "$1" ] || continue
    FIRED="${FIRED:+$FIRED,}${x#*:}" FIREN=$((FIREN + 1))
  done
}
render_ls() {
  local r a state port rel rst mem max cpu rs up link recipe bk last db lb lcap lines hourly doms lcpu ltasks lconns lreq cpum lx n=0 upt dep
  if [ -n "$JSON" ]; then
    printf '{"host":%s' "$(json_str "$HOST")"; json_meta
    printf ',"apps":'; app_json_rows | to_json "$APP_JSON"; json_alerts; printf '}\n'
    return
  fi
  firing_load
  # ALERT (the checks firing for the app) is a column only while one fires
  local acol="" ahd=""
  for a in $FIRING; do grep -q "^app${TAB}${a%%:*}${TAB}" "$TMPD/st" && { acol=1; ahd="${TAB}ALERT"; break; }; done
  {
    printf 'APP\tSTATE%s\tDEPLOYED\tMEMORY\tCPU 1M\tUP\tLOGS\tLINK\n' "$ahd"
    while IFS=$TAB read -r r a state port rel rst mem max cpu rs up link recipe bk last db lb lcap lines hourly doms lcpu ltasks lconns lreq cpum lx; do
      [ "$r" = app ] || continue
      n=$((n + 1))
      case ${doms:--} in -) ;; *,*) link="${doms%%,*} +$(printf '%s' "$doms" | tr -cd , | wc -c | tr -d ' ')";; *) link=$doms;; esac
      state=$(down_word "$a" "$(state_word "$state" "$rel" "$recipe")")
      cpu_min "${cpum:-}"
      upt=- dep=-
      [ "$state" = running ] && upt=$(ui_dur "$up")
      [ "$state" = "not deployed" ] || dep=$(ago "$(id_epoch "$rel")")
      if [ -n "$acol" ]; then firing_of "$a"; [ -n "$FIRED" ] && FIRED="${UI_RED}${FIRED}${UI_NC}"; FIRED="${TAB}${FIRED:--}"; fi
      printf '%s\t%s%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$(state_badge "$state")" "${acol:+$FIRED}" "$dep" "$(mb "$mem")" \
        "$CPUP" "$upt" "$(mb "${lb:-}")" "$(short_link "$link")"
    done < "$TMPD/st"
  } > "$TMPD/rows"
  ui_box_open "tando ls" "$HOST"
  watch_stale_line
  skew_line
  host_line
  grep -q "^check${TAB}fail${TAB}caddy" "$TMPD/st" 2> /dev/null &&
    ui_box_line "${UI_RED}caddy is not running: no app is reachable (tando doctor)${UI_NC}"
  ui_box_sep
  cache_apps
  if [ $n -gt 0 ] && [ -n "$acol" ]; then ui_table "l,l,l,l!3,r!2,r!4,r!5,r!6,l" < "$TMPD/rows"
  elif [ $n -gt 0 ]; then ui_table "l,l,l!3,r!2,r!4,r!5,r!6,l" < "$TMPD/rows"   # LINK whole: other columns go first
  else ui_box_line "No apps on $HOST yet. In your app's directory: tando up"; fi
  worker_hint
  restore_hint
  hc_hint
  local na foot
  na=$(grep -c "^alert${TAB}[^${TAB}]*${TAB}[^${TAB}]*${TAB}firing" "$TMPD/st")
  foot="$(plural $n app)"
  [ "$na" -gt 0 ] && foot="$foot  ${UI_RED}$(plural "$na" alert) firing: tando alerts${UI_NC}"
  [ $n -gt 0 ] && [ -z "$WATCH" ] && foot="$foot ${UI_G_MID} tando status <app> for details"
  ui_box_close "$foot ${UI_G_MID} $(watch_note)"
}
# restore_cut_text: the restorecut row (app, backup to restore again, safety backup, what was being
# replaced) as one line: the restore was cut and the command to run (status adds the safety backup)
restore_cut_text() {
  printf 'the %s restore was cut: tando backup restore %s' "$4" "$2"
}
# restore_hint: in ls, one line per app whose restore was cut off (the way worker_hint marks a worker)
restore_hint() {
  local r ra rid rsf rwh
  while IFS=$TAB read -r r ra rid rsf rwh _x; do
    [ "$r" = restorecut ] || continue
    ui_box_line "${UI_RED}$ra: the $rwh restore was cut: tando status $ra${UI_NC}"
  done < "$TMPD/st"
  return 0
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
# watch_note: the footer's time. Under --watch the age of the data on screen ("updated 3s ago"),
# or, when the last refresh failed or timed out, that the numbers are stale and since when.
watch_note() {
  if [ -z "$WATCH" ]; then date -u '+%H:%M:%S GMT'; return; fi
  local age=$((SECONDS - ${WATCH_OK:-$SECONDS}))
  if [ -n "${WATCH_FAIL:-}" ]; then
    printf '%sSTALE: data %s old, reconnecting%s %s Ctrl-C stops' "$UI_RED" "$(ui_dur "$age")" "$UI_NC$UI_DIM" "$UI_G_MID"
  else printf 'updated %s ago %s every %ss %s Ctrl-C stops' "$(ui_dur "$age")" "$UI_G_MID" "$WATCH" "$UI_G_MID"; fi
}
# watch_stale_line: under --watch after a failed refresh, one red line saying why (top of a view)
watch_stale_line() {
  [ -n "$WATCH" ] && [ -n "${WATCH_FAIL:-}" ] || return 0
  ui_box_wrap "${UI_RED}not answering: ${WATCH_FAIL}; the numbers below are from $(ui_dur $((SECONDS - ${WATCH_OK:-$SECONDS}))) ago${UI_NC}"
}
# app names per host for shell completions (never read over the network)
cache_apps() {
  mkdir -p "$CFG/cache" 2> /dev/null || return 0
  awk -F '\t' '$1 == "app" {print $2}' "$TMPD/st" | write_file "$CFG/cache/apps.$HOST" 2> /dev/null
  return 0
}
# --check: after the view, exit 2 when something needs attention (an app down, an alert firing;
# with --all also a server that did not answer), 0 when not. For scripts and the menu bar app.
check_flag() { [ -z "$CHECK" ] || [ -z "$WATCH" ] || usage_err "--check goes without --watch" "${ARGS[0]:-}"; }
# attention <rows file>...: how many apps are down (failed) plus alerts firing
attention() {
  awk -F '\t' '($1 == "app" && $3 == "failed") || ($1 == "alert" && $4 == "firing") { n++ } END { print n + 0 }' "$@"
}
check_exit() { [ -n "$CHECK" ] || return 0; [ "$(attention "$TMPD/st")" = 0 ] || exit 2; }
cmd_ls() { resolve 0; check_flag; watch_loop render_ls fetch_status; check_exit; }

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
  local r a state port rel rst mem max cpu rs up link recipe bk last db lb lcap lines hourly c g upt doms lcpu ltasks lconns lreq cpum lx
  while IFS=$TAB read -r r a state port rel rst mem max cpu rs up link recipe bk last db lb lcap lines hourly doms lcpu ltasks lconns lreq cpum lx; do
    [ "$r" = app ] && break
  done < "$TMPD/st"
  [ "$r" = app ] || die "no status for $APP"
  if [ -n "$JSON" ]; then status_json; return; fi
  state=$(down_word "$a" "$(state_word "$state" "$rel" "$recipe")")
  cpu_min "${cpum:-}"
  SPC="$SPC ${CPUN%.*}" SPM="$SPM $mem"
  # without --watch, the trend comes from the server's per-minute samples (tando-metrics)
  local mrows hm="" hc=""
  if [ -z "$WATCH" ] && mrows=$(awk -F '\t' '$1 == "m" {print $3, $4}' "$TMPD/st") && [ -n "$mrows" ]; then
    hm=$(printf '%s\n' "$mrows" | awk '{printf "%s ", $1}')
    hc=$(printf '%s\n' "$mrows" | awk '{printf "%d ", $2 / 10}')
  fi
  upt=-
  [ "$state" = running ] && upt=$(ui_dur "$up")
  ui_box_open "$a" "$HOST"
  watch_stale_line
  skew_line
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
    ui_kv memory "$(ui_bar "$mem" "$max" 20) $(mb "$mem") of $(mb "$max")  ${UI_DIM}in use, not cache${UI_NC}"
  else
    ui_kv memory "$(mb "$mem") (no cap)  ${UI_DIM}in use, not cache${UI_NC}"
  fi
  ui_kv cpu "$CPUP  ${UI_DIM}last minute${UI_NC}"
  worker_lines
  local rcid rcsf rcwh
  while IFS=$TAB read -r r _x rcid rcsf rcwh _y; do
    [ "$r" = restorecut ] || continue
    ui_kv restore "${UI_RED}$(restore_cut_text "$a" "$rcid" "$rcsf" "$rcwh")${UI_NC}"
    [ "$rcsf" = - ] && rcsf="none (it was not taken)"
    ui_kv safety "the data from before it is in backup $rcsf"
  done < "$TMPD/st"
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
    # late after backup_hours (the backup alert's threshold, from tando-watch's backupcfg row; 50 h
    # without it): red, as the alert that fires then
    local bh=50 bon=on bx bh2 bon2
    while IFS=$TAB read -r r bx bh2 bon2 _; do
      [ "$r" = backupcfg ] && ui_int "$bh2" && bh=$bh2 bon=$bon2
    done < "$TMPD/st"
    if ! ui_int "$last"; then ui_kv backup "daily, ${UI_YELLOW}no backup yet${UI_NC}"
    elif [ $((NOW - last)) -gt $((bh * 3600)) ]; then
      if [ "$bon" = off ]; then ui_kv backup "daily, ${UI_YELLOW}last $(ago "$last"): over $bh h${UI_NC} (its alert is off)"
      else ui_kv backup "daily, ${UI_RED}last $(ago "$last"): over $bh h, the backup alert fires${UI_NC}"; fi
    else ui_kv backup "daily, last $(ago "$last")  ${UI_DIM}late after $bh h${UI_NC}"; fi
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
  printf '{"host":%s' "$(json_str "$HOST")"; json_meta
  printf ',"app":'
  app_json_rows | to_json "$APP_JSON" | sed 's/^\[//; s/\]$//'
  printf ',"releases":'; rel_json
  printf ',"history":'; hist_json
  json_alerts
  pg_json "$TMPD/st" "$APP"
  printf '}\n'
}
cmd_status() {
  resolve 0
  if [ -z "$APP" ]; then cmd_ls; return; fi
  valid_app "$APP" || die "bad app name (a-z, 0-9, -; 2-24 characters)"
  SPC="" SPM=""
  check_flag
  watch_loop render_status fetch_status "$APP"
  check_exit
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

# job_result_word result status -> JOB_WORD: how a run ended, in words ("exit 3", "timed out")
job_result_word() {
  case $1 in
    success) JOB_WORD=ok;;
    exit-code) JOB_WORD="exit ${2:--}";;
    timeout) JOB_WORD="timed out";;
    oom-kill) JOB_WORD="killed (memory)";;
    signal|core-dump) JOB_WORD="killed (${2:--})";;
    "") JOB_WORD=-;;
    *) JOB_WORD=$1;;
  esac
}
# job_when_v "2026-11-20 14:00:00 UTC" -> JOB_WHEN "11-20 14:00" (the server's own clock); the
# year too when it is not JOB_YEAR (set by the caller: this year)
job_when_v() {
  local d=${1%% *} t=${1#* }
  t=${t%% *}; t=${t%:*}
  if [ "${d%%-*}" = "${JOB_YEAR:-}" ]; then JOB_WHEN="${d#*-} $t"; else JOB_WHEN="$d $t"; fi
}

# jobs_log name: the output of the last runs of a job (-n N, default 3), each under its time and result
jobs_log() {
  local name=$1 cnt=$NLINES r t d res st l
  case $name in ""|*[!A-Za-z0-9_-]*) usage_err "bad job name: $name (tando jobs lists them)" jobs;; esac
  [ "$cnt" = 100 ] && cnt=3   # (-n has no value of its own here: 100 is its default for logs)
  ui_int "$cnt" && [ "$cnt" -ge 1 ] && [ "$cnt" -le 50 ] || usage_err "-n is 1 to 50 runs (got $cnt)" jobs
  agent_raw sudo job-log "$APP" "$name" "$cnt" < /dev/null > "$TMPD/jl" || exit 1
  NOW=$(now)
  if grep -qx 'runs=0' "$TMPD/jl" || ! grep -q "^run$TAB" "$TMPD/jl"; then
    note "job $name has not run yet (tando jobs run $name runs it now)"; return 0
  fi
  while IFS=$TAB read -r r t d res st; do
    case $r in
      run)
        job_result_word "$res" "$st"
        printf '\n'
        if [ "$res" = success ]; then st=$(ui_badge ok "$JOB_WORD"); else st=$(ui_badge failed "$JOB_WORD"); fi
        printf '%s  %s, %ss\n' "$(ago "$t")" "$st" "$d";;
      log=*) printf '  %s\n' "${r#log=}";;
      gone=1) printf '  (its output is no longer in the journal)\n';;
      running=1) printf '\n  (a run is going on now)\n';;
    esac
  done < "$TMPD/jl"
  printf '\n'
}

# jobs_pause pause|resume name
jobs_pause() {
  local how=$1 name=$2
  case $name in ""|*[!A-Za-z0-9_-]*) usage_err "bad job name: $name (tando jobs lists them)" jobs;; esac
  agent sudo job-pause "$APP" "$name" "$how" < /dev/null > "$TMPD/jp"
  kv_read "$TMPD/jp" job state
  if [ "$how" = pause ]; then
    note "job $name paused on $HOST: its timer is off, also after a deploy or a reboot; tando jobs resume $name starts it again"
    note "  (a run going on now finishes; tando jobs run $name still runs it by hand)"
  else
    note "job $name resumed on $HOST; tando jobs shows its next run"
  fi
}

cmd_jobs() {
  resolve 1
  case "${ARGS[1]:-ls}" in
    run) jobs_run "${ARGS[2]:-}"; return;;
    log) jobs_log "${ARGS[2]:-}"; return;;
    pause|resume) jobs_pause "${ARGS[1]}" "${ARGS[2]:-}"; return;;
  esac
  local r n cal next last res code cmd lastw resw st dur n1 n2 n3 nextw tw zone zname x pd
  agent_raw sudo jobs "$APP" full > "$TMPD/st" || exit 1
  NOW=$(now)
  {
    printf 'JOB\tSCHEDULE\tNEXT\tLAST\tRESULT\tTOOK\tCOMMAND\n'
    while IFS=$TAB read -r r n cal next last res code cmd; do
      [ "$r" = job ] || continue
      # the second row of the job (state, duration, the next runs); an agent from before has none
      st=on dur=- n1=- n2=- n3=-
      while IFS=$TAB read -r r tw st dur n1 n2 n3; do
        [ "$r" = jobx ] && [ "$tw" = "$n" ] && break
        st=on dur=- n1=- n2=- n3=-
      done < "$TMPD/st"
      # (no run has ended yet: never, and running while the first one goes on)
      if [ "$res" = running ] || [ "$st" = running ] && [ "$last" = - ]; then lastw=never resw=$(ui_badge running running)
      elif [ "$last" = - ]; then lastw=never resw=-
      else
        lastw=$(ago "$last")
        job_result_word "$res" "$code"
        if [ "$res" = success ]; then resw=$(ui_badge ok); else resw=$(ui_badge failed "$JOB_WORD"); fi
      fi
      case $st in
        paused) nextw=$(ui_badge stopped paused);;
        running) nextw=$(ui_badge running running);;
        *) nextw=$(when "$next");;
      esac
      [ "$dur" = - ] && dur= || { ui_dur_v "$dur"; dur=$UI_RET; }
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$cal" "$nextw" "$lastw" "$resw" "${dur:--}" "$cmd"
    done < "$TMPD/st"
  } > "$TMPD/rows"
  ui_box_open "jobs $APP" "$HOST"
  if [ "$(wc -l < "$TMPD/rows")" -le 1 ]; then
    ui_box_line "No jobs. Add a line to tando.conf, then tando up:"
    ui_box_line "  job.nightly = daily | node scripts/nightly.js"
    ui_box_line "  job.sync = */15 * * * * | node scripts/sync.js      (cron syntax works too)"
    ui_box_close "job.<name> = <schedule> | <command> in tando.conf, then tando up"
  else
    ui_table "l,l,l!4,l!3,l,l!5,l:8-!1" < "$TMPD/rows"
    # the next three runs of each job, as the server's clock says them: a wrong schedule shows here
    zone="" zname=""
    while IFS=$TAB read -r r n st; do [ "$r" = zone ] && { zone=$n; zname=$st; }; done < "$TMPD/st"
    ui_box_line ""
    [ "$zname" = - ] && zname=""
    # (the word every other time of tando says for this zone: GMT)
    case $zone in UTC|GMT|UCT) zone=GMT; case $zname in UTC|Etc/UTC|Etc/GMT|GMT|UCT|Etc/UCT) zname="";; esac;; esac
    ui_box_line "next runs, server time (${zone:-?}${zname:+, $zname}):"
    while IFS=$TAB read -r r n st dur n1 n2 n3; do
      [ "$r" = jobx ] || continue
      [ "$st" = paused ] && { ui_box_line "  $n  paused (tando jobs resume $n)"; continue; }
      [ "$n1" = - ] && { ui_box_line "  $n  never (the schedule matches no time)"; continue; }
      ui_utc_v "$NOW"; JOB_YEAR=$UI_YEAR; job_when_v "$n1"; tw=$JOB_WHEN; pd=${n1%% *}
      # (a later time on the same day is shown without the date)
      for x in "$n2" "$n3"; do
        [ "$x" = - ] && continue
        job_when_v "$x"
        if [ "${x%% *}" = "$pd" ]; then tw="$tw, ${JOB_WHEN#* }"; else tw="$tw, $JOB_WHEN"; fi
        pd=${x%% *}
      done
      ui_box_line "  $n  $tw"
    done < "$TMPD/st"
    ui_box_close "run now: tando jobs run <name> · output: tando jobs log <name> · off: tando jobs pause <name>"
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

# env log: the changelog of the app's env, key NAMES only (the agent never stores a value). Rows from
# the agent: envlog <n> <epoch> <who> <verb> <note> <added> <changed> <removed> (n: 1 is the newest;
# names comma-separated, "-" for none). The time is shown in UTC.
envlog_rows() { # agent rows on stdin -> the same with the epoch as "YYYY-MM-DD HH:MM" (one awk, no date(1))
  LC_ALL=C awk -F '\t' -v OFS='\t' '
    $1 == "envlog" && NF == 9 {
      t = $3 + 0; d = int(t / 86400); s = t - d * 86400; z = d + 719468
      era = int(z / 146097); doe = z - era * 146097
      yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
      y = yoe + era * 400; doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
      mp = int((5 * doy + 2) / 153); dd = doy - int((153 * mp + 2) / 5) + 1; m = mp < 10 ? mp + 3 : mp - 9
      if (m <= 2) y++
      $3 = sprintf("%04d-%02d-%02d %02d:%02d", y, m, dd, int(s / 3600), int(s % 3600 / 60)); print }'
}
envlog_json() { # rows file -> a JSON array of entries (names only)
  LC_ALL=C awk -F '\t' '
    function esc(v) { gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); return "\"" v "\"" }
    function arr(c,   a, n, i, o) { if (c == "-") return "[]"; n = split(c, a, ","); o = "["
      for (i = 1; i <= n; i++) o = o (i > 1 ? "," : "") esc(a[i]); return o "]" }
    BEGIN { printf "[" }
    { printf "%s{\"n\":%d,\"time\":%s,\"by\":%s,\"verb\":%s,\"note\":%s,\"added\":%s,\"changed\":%s,\"removed\":%s}",
        (NR > 1 ? "," : ""), $2, esc($3 " UTC"), esc($4), esc($5), esc($6), arr($7), arr($8), arr($9) }
    END { printf "]" }' "$1"
}
# envlog_page rows-file n: one entry as a page: when, by, verb, note, then the three lists of names
envlog_page() {
  local r n when who verb nt add chg rem save_w=$UI_W save_i=$UI_IN
  [ "$UI_W" -gt 80 ] && { UI_W=80; UI_IN=76; }
  while IFS=$TAB read -r r n when who verb nt add chg rem; do
    [ "$n" = "$2" ] || continue
    ui_box_open "env change $n" "$APP on $HOST"
    ui_kv "when" "$when UTC"
    ui_kv "by" "$who"
    ui_kv "verb" "$verb"
    ui_kv_wrap "note" "$nt"
    local lbl list k c
    for lbl in Added Changed Removed; do
      case $lbl in Added) list=$add;; Changed) list=$chg;; *) list=$rem;; esac
      c=0; [ "$list" = "-" ] || c=$(printf '%s' "$list" | tr ',' '\n' | grep -c .)
      ui_box_sep "$lbl ($c)"
      if [ "$c" = 0 ]; then ui_box_line "${UI_DIM}none${UI_NC}"
      else
        for k in $(printf '%s' "$list" | tr ',' ' '); do ui_box_wrap "$k"; done
      fi
    done
    ui_box_close "names only: tando never stores or shows a value in this log"
    UI_W=$save_w UI_IN=$save_i
    return 0
  done < "$1"
  UI_W=$save_w UI_IN=$save_i
  die "no entry $2 in the env log of $APP (tando env log lists them)"
}
cmd_env_log() {
  resolve 1
  local n=${ARGS[2]:-} r i nt when who verb add chg rem
  if [ -n "$n" ]; then
    { is_num "$n" && [ "$n" -ge 1 ]; } || usage_err "env log takes an entry number (1 is the newest): $n" env
  fi
  agent_raw sudo env-log "$APP" $n < /dev/null | envlog_rows > "$TMPD/el" ; [ "${PIPESTATUS[0]}" = 0 ] || exit 1
  if [ -n "$JSON" ]; then
    printf '{"host":%s,"app":%s,"entries":' "$(json_str "$HOST")" "$(json_str "$APP")"
    envlog_json "$TMPD/el"; printf '}\n'; return 0
  fi
  if [ -n "$n" ]; then envlog_page "$TMPD/el" "$n"; return 0; fi
  if [ ! -s "$TMPD/el" ]; then note "No changes logged for $APP yet (tando env set KEY=VALUE adds the first)"; return 0; fi
  local tty=""; [ -t 0 ] && [ -t 2 ] && tty=1
  # the rows: [when] [note] >  (numbered at a terminal, where one is picked)
  i=0
  while IFS=$TAB read -r r n when who verb nt add chg rem; do
    i=$((i + 1))
    if [ -n "$tty" ]; then printf '  %3s) [%s] [%s] >\n' "$n" "$when" "$nt"
    else printf '[%s] [%s] >\n' "$when" "$nt"; fi
  done < "$TMPD/el"
  [ -n "$tty" ] || return 0
  pick_num "$i" entry 1
  echo
  envlog_page "$TMPD/el" "$PICK"
}

# doctor_prog_differs name detail: is this row "a program on the server differs from the client's"
# (agent, gate, logs, metrics, watch, status, daemon, offsite, host, studio; the agent words it three ways)?
doctor_prog() { case $1 in agent|gate|logs|metrics|watch|status|daemon|offsite|host|studio) return 0;; esac; return 1; }
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
    "host=$(server_sums tando-host | tr -d ' ')" "studio=$(server_sums tando-studio | tr -d ' ')" > "$TMPD/st" || exit 1
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

# watch_loop render fetch args...: one view, or repaint every $WATCH seconds. Each refresh has
# WATCH_TIMEOUT seconds (15); one that fails or takes longer repaints the last data with its age
# and "reconnecting" (watch_note), never the old numbers as if they were new.
WATCH_TIMEOUT=15
watch_loop() {
  local render=$1 fetch=$2
  shift 2
  $fetch "$@" || exit 1
  if [ -z "$WATCH" ]; then $render; return; fi
  trap 'UI_WINCH=1' WINCH
  trap 'exit 0' INT              # Ctrl-C is how a watch ends: not an error
  WATCH_OK=$SECONDS WATCH_FAIL=""
  while :; do
    ui_frame_begin
    $render
    ui_frame_end
    sleep "$WATCH"
    if watch_fetch "$fetch" "$@"; then WATCH_OK=$SECONDS WATCH_FAIL=""; NOW=$(now); fi
  done
}
# watch_fetch fetch args...: the fetch in the background, killed after WATCH_TIMEOUT seconds of
# wall clock (a hung ssh must not freeze the screen); on failure WATCH_FAIL says why
watch_fetch() {
  local pid end rc
  rm -f "$TMPD/wf.rc"
  ( "$@" 2> "$TMPD/wf.err"; echo $? > "$TMPD/wf.rc" ) &
  pid=$! end=$((SECONDS + WATCH_TIMEOUT))
  while [ ! -s "$TMPD/wf.rc" ] && [ $SECONDS -lt $end ]; do sleep 0.2; done
  if [ ! -s "$TMPD/wf.rc" ]; then
    pkill -P "$pid" 2> /dev/null; kill "$pid" 2> /dev/null; wait "$pid" 2> /dev/null
    WATCH_FAIL="no answer within $WATCH_TIMEOUT s"; return 1
  fi
  wait "$pid" 2> /dev/null; read -r rc < "$TMPD/wf.rc"
  [ "$rc" = 0 ] && return 0
  WATCH_FAIL=$(strip < "$TMPD/wf.err" 2> /dev/null | grep . | tail -1)
  WATCH_FAIL=${WATCH_FAIL:-the refresh failed}
  return 1
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
  check_flag
  watch_loop render_ls_all fetch_ls_all
  [ -n "$CHECK" ] || return 0
  local h; for h in $LS_HOSTS; do [ "$(cat "$TMPD/h.$h.rc")" = 0 ] || exit 2; done
  # shellcheck disable=SC2046  # a list of file names (host names: no spaces)
  [ "$(cd "$TMPD" && attention $(for h in $LS_HOSTS; do printf 'h.%s.st ' "$h"; done))" = 0 ] || exit 2
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
      printf '%s{"host":%s,"reachable":false,"checked_at":%s,"error":%s}' "$sep" "$(json_str "$h")" "$(now)" \
        "$(json_str "${e:-unreachable}")"; sep=,
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
