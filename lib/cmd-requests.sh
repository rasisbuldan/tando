# lib/cmd-requests.sh: `tando requests`, the app's request log as Caddy wrote it (boxed). bash 3.2.
# help: requests [--last 15m|1h|24h] | requests tail [-n N] [-f] | requests errors [--last W] [--4xx]
#
# The server summarises /var/log/tando/<app>/access.log (and the rolled files that overlap the
# window) in one awk pass: totals, status codes, requests per minute, latency percentiles from a
# log-scale histogram (5% bins), and per-path counts, mean and max with ids folded to :n / :id.

rq_window() { # 15m|1h|24h|<N>m|<N>h -> seconds
  case $1 in
    [0-9]*m) is_num "${1%m}" && echo $(( ${1%m} * 60 ));;
    [0-9]*h) is_num "${1%h}" && echo $(( ${1%h} * 3600 ));;
    [0-9]*d) is_num "${1%d}" && echo $(( ${1%d} * 86400 ));;
    *) return 1;;
  esac
}

rq_ms() { # milliseconds (decimal) -> "12 ms", "1.4 s"
  awk -v v="$1" 'BEGIN { if (v >= 1000) printf "%.1f s", v / 1000
    else if (v >= 10) printf "%d ms", v + 0.5; else printf "%.1f ms", v }'
}

cmd_requests() {
  resolve 1
  local sub=${ARGS[1]:-} i=1 a last=15m w four=""
  case $sub in
    tail|errors|summary) i=2;;
    ""|--last|--since) sub=summary;;
    *) die "requests: summary (default), tail or errors";;
  esac
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    a=${ARGS[$i]}
    case $a in
      --last|--since) last=${ARGS[$((i + 1))]:-}; i=$((i + 2));;   # --since: the name logs uses
      --4xx) four=4xx; i=$((i + 1));;
      *) die "requests: unknown argument: $a";;
    esac
  done
  w=$(rq_window "$last") || die "bad --last: $last (15m, 1h, 24h)"
  [ "$w" -ge 60 ] && [ "$w" -le 604800 ] || die "--last must be between 1m and 7d"
  case $sub in
    summary) rq_summary "$w" "$last";;
    tail) rq_tail;;
    errors) rq_errors "$w" "$last" "$four";;
  esac
}

rq_summary() { # seconds label
  local w=$1 label=$2 k v r a b c d e
  agent_raw sudo req-summary "$APP" "$w" > "$TMPD/rq" || exit 1
  kv_read "$TMPD/rq" total bucket c1xx c2xx c3xx c4xx c5xx p50_ms p95_ms p99_ms max_ms avg_ms counts counts_5xx \
    files unparsed oldest from
  local tot=${K_total:-0} rate e5 e4 per b=${K_bucket%.*} cover=""
  is_num "$tot" || tot=0
  ui_box_open "requests $APP" "$HOST  last $label"
  if [ "$tot" = 0 ]; then
    ui_box_line "no requests in the last $label"
    ui_box_close "/var/log/tando/$APP/access.log"
    return 0
  fi
  rate=$(awk -v t="$tot" -v w="$w" 'BEGIN { r = t * 60 / w; printf (r >= 10 ? "%d" : "%.1f"), r }')
  e5=$(awk -v a="${K_c5xx:-0}" -v t="$tot" 'BEGIN { printf "%.2f", 100 * a / t }')
  e4=$(awk -v a="${K_c4xx:-0}" -v t="$tot" 'BEGIN { printf "%.2f", 100 * a / t }')
  ui_kv requests "$tot   ${UI_DIM}rate${UI_NC} $rate/min   ${UI_DIM}errors${UI_NC} $(rq_rate_col "$e5")% 5xx   $e4% 4xx"
  is_num "$b" || b=60
  if [ "$b" = 60 ]; then per="per min"
  elif [ $((b % 3600)) = 0 ]; then per="per $((b / 3600))h"
  elif [ $((b % 60)) = 0 ]; then per="per $((b / 60))m"
  else per="per ${b}s"; fi
  # rotation by size can leave less history than the window asks for
  if is_num "${K_oldest:-}" && is_num "${K_from:-}" && [ "$K_oldest" -gt "$((K_from + 60))" ]; then
    ui_utc_v "$K_oldest"; cover="   ${UI_YELLOW}log starts $UI_RET GMT${UI_NC}"
  fi
  ui_kv "$per" "$(ui_spark "$(printf '%s' "$K_counts" | tr ',' ' ')")$cover"
  [ "${K_c5xx:-0}" != 0 ] && ui_kv "5xx" "$(ui_spark "$(printf '%s' "$K_counts_5xx" | tr ',' ' ')")"
  ui_kv latency "p50 $(rq_ms "$K_p50_ms")   p95 $(rq_ms "$K_p95_ms")   p99 $(rq_ms "$K_p99_ms")$(
    )   ${UI_DIM}max${UI_NC} $(rq_ms "$K_max_ms")"
  ui_box_sep "status codes"
  {
    printf 'CODE\tCOUNT\tSHARE\t\n'
    grep "^code	" "$TMPD/rq" | sort -t '	' -k3,3nr | head -8 | while IFS='	' read -r r a b; do
      printf '%s\t%s\t%s\t%s%%\n' "$a" "$b" "$(ui_bar "$b" "$tot" 16)" \
        "$(awk -v a="$b" -v t="$tot" 'BEGIN { printf "%.1f", 100 * a / t }')"
    done
  } > "$TMPD/rows"
  ui_table "l,r,l!1,r" < "$TMPD/rows"
  ui_box_sep "slowest paths (mean)"
  rq_paths 4 5 "MEAN" < "$TMPD/rq"
  ui_box_sep "most requested"
  rq_paths 3 5 "COUNT" < "$TMPD/rq"
  if [ "${K_c5xx:-0}" != 0 ]; then
    ui_box_sep "most 5xx"
    rq_paths 6 5 "5XX" < "$TMPD/rq"
  fi
  ui_box_close "${K_files:-0} log files; paths with ids folded to :n and :id; query strings are not logged"
}

rq_rate_col() { # percentage -> coloured when over 1% / 5%
  awk -v p="$1" -v r="$UI_RED" -v y="$UI_YELLOW" -v n="$UI_NC" \
    'BEGIN { c = (p >= 5) ? r : (p >= 1) ? y : ""; printf "%s%s%s", c, p, (c == "" ? "" : n) }'
}

rq_paths() { # sort column, rows, title < summary: path rows "path KEY COUNT MEAN MAX N5XX"
  local r k c m x f
  {
    printf 'PATH\tCOUNT\tMEAN\tMAX\t5XX\n'
    grep "^path	" | sort -t '	' -k"$1","$1"nr | head -n "$2" | while IFS='	' read -r r k c m x f; do
      [ "$1" = 6 ] && [ "$f" = 0 ] && continue
      printf '%s\t%s\t%s\t%s\t%s\n' "$k" "$c" "$(rq_ms "$m")" "$(rq_ms "$x")" "$f"
    done
  } > "$TMPD/prow"
  ui_table "l:10-!0,r,r,r!1,r!2" < "$TMPD/prow"
}

rq_row() { # req ts status ms method uri size ip -> one line
  local r=$1 ts=$2 st=$3 ms=$4 m=$5 u=$6 sz=$7 ip=$8
  ui_utc_v "$ts" s
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$UI_RET" "$st" "$(rq_ms "$ms")" "$m" "$u" \
    "$(ui_bytes "$sz")" "$ip"
}

rq_tail() {
  local n=$NLINES
  [ "$n" = 100 ] && n=20
  if [ -n "$FOLLOW" ]; then
    if ! valid_app "$APP" || ! is_num "$n"; then die "bad app name or count"; fi   # both go into the remote command
    [ -t 1 ] && printf '%s# times in GMT (UTC)%s\n' "$UI_DIM" "$UI_NC"
    # shellcheck disable=SC2029
    # lint: allow RL04 AGENT_BIN is a constant, APP and n were checked just above
    ssh "${SSHO[@]}" "$TARGET" "sudo -n $AGENT_BIN req-tail $APP $n follow" 2> "$TMPD/err" |
      LC_ALL=C awk -F'\t' '$1 == "req" {
        gsub(/[\001-\010\013-\037\177]/, ""); gsub(/\302[\200-\237]/, "?")
        gsub(/\342\200[\216\217\252-\256]|\342\201[\246-\251]|\330\234/, "")
        t = int($2) % 86400
        printf "%02d:%02d:%02d  %s %8.1f ms  %s %s  %s B  %s\n", t / 3600, t % 3600 / 60, t % 60, $3, $4, $5, $6, $7, $8
        fflush() }'
    return 0
  fi
  agent_raw sudo req-tail "$APP" "$n" > "$TMPD/rq" || exit 1
  {
    printf 'TIME (GMT)\tSTATUS\tLATENCY\tMETHOD\tPATH\tSIZE\tCLIENT\n'
    while IFS='	' read -r r a b c d e f g; do
      [ "$r" = req ] && rq_row "$r" "$a" "$b" "$c" "$d" "$e" "$f" "$g"
    done < "$TMPD/rq"
  } > "$TMPD/rows"
  ui_box_open "requests $APP" "$HOST  newest $n"
  ui_table "l,r,r,l!3,l:10-!0,r!2,l!1" < "$TMPD/rows"
  ui_box_close "query strings and headers are never logged"
}

rq_errors() { # seconds label [4xx]
  local n=$NLINES r a b c d e f g
  [ "$n" = 100 ] && n=20
  agent_raw sudo req-errors "$APP" "$1" "$n" ${3:+"$3"} > "$TMPD/rq" || exit 1
  {
    printf 'TIME (GMT)\tSTATUS\tLATENCY\tMETHOD\tPATH\tCLIENT\n'
    while IFS='	' read -r r a b c d e f g; do
      [ "$r" = req ] || continue
      rq_row "$r" "$a" "$b" "$c" "$d" "$e" "$f" "$g" | awk -F'\t' -v OFS='\t' '{ print $1, $2, $3, $4, $5, $7 }'
    done < "$TMPD/rq"
  } > "$TMPD/rows"
  ui_box_open "requests $APP: ${3:-5xx} errors" "$HOST  last $2"
  if [ "$(wc -l < "$TMPD/rows")" -le 1 ]; then ui_box_line "no ${3:-5xx} answers in the last $2"
  else ui_table "l,r,r,l!3,l:10-!0,l!1" < "$TMPD/rows"; fi
  ui_box_close "newest last"
}
