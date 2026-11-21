# lib/cmd-health.sh: `tando health`, is it up and was it up: uptime, incidents, probe latency. bash 3.2.
# help: health [app] [--json]   uptime 24 h / 7 d, incidents (start, duration, cause), probe latency
#
# From what tando-watch records once a minute (tando-watch `health`, srv/watch): for each app the
# class of every minute (ok, down, unhealthy, slow, saturated; deploys, boots and stopped
# minutes are not counted), its incidents (alerts that fired, liveness restarts) and, for one
# app, the last lines it wrote before its last crash. All times GMT.

cmd_health() {
  local i=1 a forget=""
  case ${ARGS[1]:-} in ""|-*) ;; *) APP=${ARGS[1]}; i=2;; esac
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    a=${ARGS[$i]}
    case $a in
      --json) i=$((i + 1));;
      --forget) forget=${ARGS[$((i + 1))]:-}; i=$((i + 2));;
      --forget=*) forget=${a#--forget=}; i=$((i + 1));;
      *) die "health: unknown argument: $a (tando health [app] [--json])";;
    esac
  done
  [ -z "$APP" ] || valid_app "$APP" || die "bad app name: $APP (a-z, 0-9, -; 2-24 characters)"
  resolve 0
  [ -n "$(type -t watch_raw)" ] || . "$TANDO_HOME/lib/cmd-alerts.sh"
  watch_raw sudo health ${APP:+"$APP"} > "$TMPD/hl" || bail 1
  NOW=$(now)
  if [ -n "$forget" ]; then hl_forget "$forget"; return; fi
  if [ -n "$JSON" ]; then hl_json; return; fi
  if [ -n "$APP" ]; then hl_one; else hl_all; fi
}

# hl_forget N: drop the app's Nth incident (1 = newest, the order tando health shows them in)
hl_forget() {
  local r a s e c why n=0 hit=""
  [ -n "$APP" ] || die "health --forget needs the app: tando health <app> --forget N"
  is_num "$1" && [ "$1" -ge 1 ] || die "health --forget takes the incident's number in tando health $APP (1 is the newest)"
  while IFS=$TAB read -r r a s e c why; do
    [ "$r" = inc ] && [ "$a" = "$APP" ] || continue
    n=$((n + 1)); [ "$n" = "$1" ] && { hit=$s; break; }
  done < "$TMPD/hl"
  [ -n "$hit" ] || die "$APP has $n incidents listed: no number $1 (tando health $APP)"
  is_num "$e" || die "incident $1 of $APP is still open: it can be dropped once it has ended"
  watch_raw sudo forget-incident "$APP" "$hit" > "$TMPD/hlf" || bail 1
  ui_utc_v "$hit"
  printf '%s\n' "dropped the incident of $UI_RET ($c, $(ui_dur "$((e - hit))")): its minutes no longer count in $APP's uptime"
}

hl_pct() { # x100 -> "99.93%" (or -)
  ui_int "$1" || { printf -- '-'; return; }
  printf '%d.%02d%%' $(($1 / 100)) $(($1 % 100))
}
hl_ms() { if ui_int "$1"; then printf '%s ms' "$1"; else printf -- '-'; fi; }
hl_now() { # last class, firing checks
  if [ "$2" != - ] && [ -n "$2" ]; then ui_badge failed "$(printf '%s' "$2" | tr ',' ' ')"
  else case $1 in ok) ui_badge ok ok;; -|"") printf -- '-';; hold) ui_badge pending deploying;; stopped) ui_badge stopped;;
    *) ui_badge failed "$1";; esac; fi
}
hl_spark() { ui_spark "$(printf '%s' "$1" | tr ',' ' ' | sed 's/-/0/g')" 24; }
hl_dur() { # start end
  if ui_int "$2"; then ui_dur "$(($2 - $1))"; elif ui_int "$1"; then printf 'ongoing, %s' "$(ui_dur "$((NOW - $1))")"; else printf -- '-'; fi
}

hl_all() {
  local r a u1 u7 n1 n7 ni p50 p95 sp lc lm fir na=0
  {
    printf 'APP\tNOW\tUP 24H\tUP 7D\tPROBE P95\tPROBE LATENCY 24H\tINC 7D\n'
    while IFS=$TAB read -r r a u1 u7 n1 n7 ni p50 p95 sp lc lm fir; do
      [ "$r" = up ] || continue
      na=$((na + 1))
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$(hl_now "$lc" "$fir")" "$(hl_pct "$u1")" "$(hl_pct "$u7")" \
        "$(hl_ms "$p95")" "$(hl_spark "$sp")" "$ni"
    done < "$TMPD/hl"
  } > "$TMPD/hl.rows"
  {
    printf 'START (GMT)\tAPP\tCHECK\tLASTED\tCAUSE\n'
    while IFS=$TAB read -r r a u1 u7 n1 n7; do
      [ "$r" = inc ] || continue
      ui_utc_v "$u1"; printf '%s\t%s\t%s\t%s\t%s\n' "$UI_RET" "$a" "$n1" "$(hl_dur "$u1" "$u7")" "$n7"
    done < "$TMPD/hl" | sort -r
  } > "$TMPD/hl.inc"
  ui_box_open "health" "$HOST"
  if [ "$na" = 0 ]; then ui_box_line "no apps yet"
  else ui_table "l,l,r,r!2,r!3,l!1,r" < "$TMPD/hl.rows"; fi
  ui_box_sep "recent incidents"
  if [ "$(wc -l < "$TMPD/hl.inc")" -gt 1 ]; then ui_table "l,l,l,l!1,l:10-" < "$TMPD/hl.inc"
  else ui_box_line "none recorded"; fi
  ui_box_close "P95: tando-watch's probe, 24 h; real traffic: tando requests" "$(date -u '+%H:%M GMT')"
}

hl_one() {
  local r a u1 u7 n1 n7 ni p50 p95 sp lc lm fir found=""
  while IFS=$TAB read -r r a u1 u7 n1 n7 ni p50 p95 sp lc lm fir; do
    [ "$r" = up ] && [ "$a" = "$APP" ] && { found=1; break; }
  done < "$TMPD/hl"
  ui_box_open "health $APP" "$HOST"
  if [ -z "$found" ]; then ui_box_line "nothing recorded yet"; ui_box_close "tando-watch records once a minute"; return 0; fi
  ui_kv now "$(hl_now "$lc" "$fir")  ${UI_DIM}last probe${UI_NC} $(hl_ms "$lm")"
  ui_int "$n1" || n1=0; ui_int "$n7" || n7=0
  ui_kv "uptime 24h" "$(hl_pct "$u1")  ${UI_DIM}of $n1 minutes judged${UI_NC}"
  ui_kv "uptime 7d" "$(hl_pct "$u7")  ${UI_DIM}of $n7 minutes, $ni incidents${UI_NC}"
  ui_kv "probe 24h" "$(hl_spark "$sp")  ${UI_DIM}p50${UI_NC} $(hl_ms "$p50")  ${UI_DIM}p95${UI_NC} $(hl_ms "$p95")  ${UI_DIM}tando-watch's, not visitors'${UI_NC}"
  local pgn; pgn=$(pg_note "$TMPD/hl" "$APP")   # its PostgreSQL database: size, connections of its role
  [ -z "$pgn" ] || ui_kv database "$pgn"
  {
    local k=0
    printf '#\tSTART (GMT)\tLASTED\tCHECK\tCAUSE\n'
    while IFS=$TAB read -r r a u1 u7 n1 n7; do
      [ "$r" = inc ] || continue
      k=$((k + 1))
      ui_utc_v "$u1"; printf '%s\t%s\t%s\t%s\t%s\n' "$k" "$UI_RET" "$(hl_dur "$u1" "$u7")" "$n1" "$n7"
    done < "$TMPD/hl"
  } > "$TMPD/hl.inc"
  ui_box_sep "incidents (a false alarm: tando health $APP --forget N)"
  if [ "$(wc -l < "$TMPD/hl.inc")" -gt 1 ]; then ui_table "r,l,l,l,l:10-" < "$TMPD/hl.inc"
  else ui_box_line "none recorded"; fi
  if grep -q "^tail$TAB" "$TMPD/hl"; then
    ui_box_sep "its last lines before the last crash or restart"
    while IFS=$TAB read -r r a u1 n1; do
      [ "$r" = tail ] || continue
      ui_utc_v "$u1" s; ui_box_wrap "${UI_DIM}${UI_RET#* }${UI_NC} $n1"
    done < "$TMPD/hl"
  fi
  ui_box_close "probed through Caddy once a minute; tando errors -a $APP" "$(date -u '+%H:%M GMT')"
}

# health --json: per app its uptime, minutes judged, incidents, probe percentiles, last class and
# firing checks, and series: the average probe time of each of the last 24 hours (tando-watch's
# hourly figure; hour i starts at now - 86400 + i * 3600, now being this laptop's clock when read),
# null where no probe ran; then every incident
hl_json() {
  printf '{"host":%s,"apps":' "$(json_str "$HOST")"
  LC_ALL=C awk -F '\t' -v now="$NOW" '
    function n(v) { return (v ~ /^[0-9]+$/) ? v + 0 : "null" }
    function pct(v) { return (v ~ /^[0-9]+$/) ? sprintf("%d.%02d", int(v / 100), v % 100) : "null" }
    function s(v) { if (v == "-" || v == "") return "null"; gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); return "\"" v "\"" }
    BEGIN { printf "[" }
    $1 == "up" {
      printf "%s{\"app\":%s,\"uptime_24h_pct\":%s,\"uptime_7d_pct\":%s,\"minutes_24h\":%s,\"minutes_7d\":%s,\"incidents_7d\":%s,\"p50_ms\":%s,\"p95_ms\":%s,\"last\":%s,\"firing\":%s",
        (k++ ? "," : ""), s($2), pct($3), pct($4), n($5), n($6), n($7), n($8), n($9), s($11), s($13)
      m = split($10, v, ","); r = ""
      for (i = 1; i <= 24; i++) r = r (i > 1 ? "," : "") sprintf("{\"t\":%d,\"avg_ms\":%s}", now - 86400 + (i - 1) * 3600, (i <= m ? n(v[i]) : "null"))
      printf ",\"series\":[%s]}", r }
    END { printf "]" }' "$TMPD/hl"
  printf ',"incidents":'
  awk -F '\t' -v OFS='\t' '$1 == "inc" { print $2, $3, $4, $5, $6 }' "$TMPD/hl" | to_json "app:s,start:n,end:n,check:s,cause:s"
  [ -z "$APP" ] || pg_json "$TMPD/hl" "$APP"
  printf '}\n'
}
