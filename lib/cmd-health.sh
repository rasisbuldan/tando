# lib/cmd-health.sh: `tando health`, is it up and was it up: uptime, incidents, probe latency. bash 3.2.
# help: health [app] [--json]   uptime 24 h / 7 d, incidents (start, duration, cause), probe latency
#
# From what tando-watch records once a minute (tando-watch `health`, srv/watch): for each app the
# class of every minute (ok, down, unhealthy, slow, saturated; deploys, boots and stopped
# minutes are not counted), its incidents (alerts that fired, liveness restarts) and, for one
# app, the last lines it wrote before its last crash. All times GMT.

cmd_health() {
  local i=1 a
  case ${ARGS[1]:-} in ""|-*) ;; *) APP=${ARGS[1]}; i=2;; esac
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    a=${ARGS[$i]}
    case $a in --json) i=$((i + 1));; *) die "health: unknown argument: $a (tando health [app] [--json])";; esac
  done
  [ -z "$APP" ] || valid_app "$APP" || die "bad app name: $APP"
  resolve 0
  [ -n "$(type -t watch_raw)" ] || . "$TANDO_HOME/lib/cmd-alerts.sh"
  watch_raw sudo health ${APP:+"$APP"} > "$TMPD/hl" || bail 1
  NOW=$(now)
  if [ -n "$JSON" ]; then hl_json; return; fi
  if [ -n "$APP" ]; then hl_one; else hl_all; fi
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
    printf 'APP\tNOW\tUP 24H\tUP 7D\tP95\tPROBE LATENCY 24H\tINC 7D\n'
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
  ui_box_close "minutes judged once a minute; tando health <app> for one app" "$(date -u '+%H:%M GMT')"
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
  ui_kv latency "$(hl_spark "$sp")  ${UI_DIM}p50${UI_NC} $(hl_ms "$p50")  ${UI_DIM}p95${UI_NC} $(hl_ms "$p95")"
  {
    printf 'START (GMT)\tLASTED\tCHECK\tCAUSE\n'
    while IFS=$TAB read -r r a u1 u7 n1 n7; do
      [ "$r" = inc ] || continue
      ui_utc_v "$u1"; printf '%s\t%s\t%s\t%s\n' "$UI_RET" "$(hl_dur "$u1" "$u7")" "$n1" "$n7"
    done < "$TMPD/hl"
  } > "$TMPD/hl.inc"
  ui_box_sep "incidents"
  if [ "$(wc -l < "$TMPD/hl.inc")" -gt 1 ]; then ui_table "l,l,l,l:10-" < "$TMPD/hl.inc"
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

hl_json() {
  local r a u1 u7 n1 n7 ni p50 p95 sp lc lm fir
  while IFS=$TAB read -r r a u1 u7 n1 n7 ni p50 p95 sp lc lm fir; do
    [ "$r" = up ] || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$(hl_pct "$u1" | tr -d %)" "$(hl_pct "$u7" | tr -d %)" \
      "$n1" "$n7" "$ni" "$p50" "$p95" "$lc" "$fir"
  done < "$TMPD/hl" > "$TMPD/hl.j1"
  while IFS=$TAB read -r r a u1 u7 n1 n7; do
    [ "$r" = inc ] && printf '%s\t%s\t%s\t%s\t%s\n' "$a" "$u1" "$u7" "$n1" "$n7"
  done < "$TMPD/hl" > "$TMPD/hl.j2"
  printf '{"host":%s,"apps":' "$(json_str "$HOST")"
  to_json "app:s,uptime_24h_pct:n,uptime_7d_pct:n,minutes_24h:n,minutes_7d:n,incidents_7d:n,p50_ms:n,p95_ms:n,last:s,firing:s" < "$TMPD/hl.j1"
  printf ',"incidents":'
  to_json "app:s,start:n,end:n,check:s,cause:s" < "$TMPD/hl.j2"
  printf '}\n'
}
