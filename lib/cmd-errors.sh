# lib/cmd-errors.sh: `tando errors`, the app's errors from its own log, grouped. bash 3.2.
# help: errors [app] [--since 24h] [-n N] [--json]   error groups from the app's log, with a sample each
#
# The server (tando-logs errors) reads the app's journal incrementally (tando-watch does the same
# once a minute) and groups error lines with the stack trace that follows them (Node, Python, Go)
# by exception type + first frame of the app's own code, numbers and ids normalised. Each group:
# how often in the window, first and last seen (GMT), the release it first appeared in, one sample.
# Every text from the server is the app's own output: it goes through strip and the table cells.

cmd_errors() {
  local i=1 a since=24h w
  case ${ARGS[1]:-} in ""|-*) ;; *) APP=${ARGS[1]}; i=2;; esac
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    a=${ARGS[$i]}
    case $a in
      --since|--last) since=${ARGS[$((i + 1))]:-}; i=$((i + 2));;
      --json) i=$((i + 1));;
      *) die "errors: unknown argument: $a (tando errors [app] [--since 24h] [-n N] [--json])";;
    esac
  done
  [ -z "$APP" ] || valid_app "$APP" || die "bad app name: $APP (a-z, 0-9, -; 2-24 characters)"
  resolve 1
  w=$(er_window "$since") || die "bad --since: $since (like 30m, 6h, 24h, 7d)"
  [ "$w" -ge 60 ] && [ "$w" -le 604800 ] || die "--since must be between 1m and 7d"
  local n=$NLINES
  [ "$n" = 100 ] && n=10
  ui_int "$n" && [ "$n" -le 200 ] || die "-n is 1 to 200"
  agent_raw sudo errors "$APP" "$w" "$n" > "$TMPD/er" || exit 1
  if [ -n "$JSON" ]; then er_json; return; fi
  er_render "$since"
}

er_window() { # 30m|6h|24h|7d -> seconds
  local n=${1%?}
  ui_int "$n" || return 1
  case $1 in *m) echo $((n * 60));; *h) echo $((n * 3600));; *d) echo $((n * 86400));; *) return 1;; esac
}

# the server's err rows, checked: id count total first last release kind label title
er_rows() {
  local r id c t f l rel k lab tit
  while IFS=$TAB read -r r id c t f l rel k lab tit; do
    [ "$r" = err ] || continue
    case $id in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) continue;; esac
    ui_int "$c" || c=0; ui_int "$t" || t=0; ui_int "$f" || f=0; ui_int "$l" || l=0
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$c" "$t" "$f" "$l" "$rel" "$k" "$lab" "$tit"
  done < "$TMPD/er"
}

er_json() {
  er_rows > "$TMPD/er.rows"
  printf '{"host":%s,"app":%s,"errors":' "$(json_str "$HOST")" "$(json_str "$APP")"
  to_json "id:s,count:n,total:n,first_seen:n,last_seen:n,release:s,kind:s,label:s,title:s" < "$TMPD/er.rows"
  printf '}\n'
}

er_render() { # since-label
  local id c t f l rel k lab tit ng=0 line
  er_rows > "$TMPD/er.rows"
  {
    printf 'COUNT\tLAST (GMT)\tFIRST (GMT)\tRELEASE\tERROR\n'
    while IFS=$TAB read -r id c t f l rel k lab tit; do
      ng=$((ng + 1))
      [ "$k" = line ] && lab=$tit
      ui_utc_v "$l"; line="$c	$UI_RET"
      ui_utc_v "$f"; printf '%s\t%s\t%s\t%s\n' "$line" "$UI_RET" "$rel" "$lab"
    done < "$TMPD/er.rows"
  } > "$TMPD/er.tab"
  ui_box_open "errors $APP" "$HOST  last $1"
  if [ "$ng" = 0 ]; then
    ui_box_line "$(ui_badge ok "no errors") in the app's log in the last $1"
    ui_box_close "error lines and stack traces of stdout/stderr; tando requests errors for HTTP 5xx"
    return 0
  fi
  ui_table "r,l,l!2,l!1,l:12-" < "$TMPD/er.tab"
  # one sample per group, newest group first
  while IFS=$TAB read -r id c t f l rel k lab tit; do
    ui_box_sep "$c x  $(printf '%s' "$lab" | cut -c1-50)  [$id]"
    awk -F'\t' -v id="$id" '$1 == "sample" && $2 == id { sub(/^[^\t]*\t[^\t]*\t/, ""); print }' "$TMPD/er" |
      head -n 12 | while IFS= read -r line; do ui_box_wrap "  $line"; done
  done < "$TMPD/er.rows"
  ui_box_close "$ng groups; numbers and ids folded; tando logs --grep shows every line"
}
