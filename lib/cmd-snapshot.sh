# lib/cmd-snapshot.sh: `tando snapshot --json`, everything a dashboard shows of a server in ONE ssh
# exec per host (built like top_fetch in lib/cmd-top.sh). bash 3.2.
#
#   tando snapshot --json [-H host | --all] [--app A [--range 1h|24h|7d]]
#
# One JSON document per host, one per line (hosts in parallel, each with a timeout; an unreachable
# host is {"host", "reachable": false, "error", "checked_at"}). Without --app it is the cheap one
# (status, the load averages, the server clock): what `tando ls --json` prints, plus state_reason,
# the system object, server_now and the alerts. With --app the same exec also reads the app's
# releases, history (with the deployer, from the audit log's who), metrics over the range (gap
# filled: every bucket present, null where no sample) and health. Fields: docs/COMMANDS.md.
# Every server field is data: numbers are checked before they are printed as numbers.

SNAP_TIMEOUT=${TANDO_SNAPSHOT_TIMEOUT:-15}

cmd_snapshot() {
  local i=1 a app="" range="" hosts h
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    a=${ARGS[$i]}
    case $a in
      --json) i=$((i + 1));;
      --app) app=${ARGS[$((i + 1))]:-}; i=$((i + 2));;
      --range) range=${ARGS[$((i + 1))]:-}; i=$((i + 2));;
      *) usage_err "snapshot: unknown argument: $a" snapshot;;
    esac
  done
  [ -n "$JSON" ] || usage_err "snapshot prints JSON only: tando snapshot --json" snapshot
  [ -n "$app" ] || app=$APP   # -a works too (never the tando.conf here: without --app it stays cheap)
  [ -z "$app" ] || valid_app "$app" || usage_err "not an app name: $app (a-z, 0-9, -; 2-24 characters)" snapshot
  case ${range:-24h} in
    1h) SNAP_PTS=60 SNAP_BK=60;;
    24h) SNAP_PTS=144 SNAP_BK=600;;
    7d) SNAP_PTS=168 SNAP_BK=3600;;
    *) usage_err "--range is 1h, 24h or 7d" snapshot;;
  esac
  [ -z "$range" ] || [ -n "$app" ] || usage_err "--range goes with --app (the metrics are the app's)" snapshot
  SNAP_RANGE=${range:-24h}
  if [ -n "$ALL" ]; then
    [ -z "$HOST" ] || usage_err "-H or --all, not both" snapshot
    [ -z "$app" ] || usage_err "--app goes with one host (-H)" snapshot
    hosts=$(all_hosts)
    [ -n "$hosts" ] || die "no hosts registered: tando host add"
  else
    APP=""          # (resolve would take tando.conf's app; the snapshot only reads the one asked for)
    resolve 0
    hosts=$HOST
  fi
  for h in $hosts; do valid_host "$h" || die "bad host name: $h"; done
  # shellcheck disable=SC2086  # a list of host names
  snap_fetch "$app" $hosts
  for h in $hosts; do snap_render "$h" "$app"; done
}

# snap_cmd app: the one remote command (only words tando built: the app name is checked)
snap_cmd() {
  local a=$1 c="sudo -n $AGENT_BIN status"
  # the three load averages (builtins only: no process); the host row has the first one
  c="$c; read -r l1 l5 l15 _x < /proc/loadavg 2> /dev/null && printf 'loadavg\\t%s\\t%s\\t%s\\n' \"\$l1\" \"\$l5\" \"\$l15\""
  if [ -n "$a" ]; then
    c="$c; echo '@releases'; sudo -n $AGENT_BIN releases $a; echo '@history'; sudo -n $AGENT_BIN history $a 20"
    c="$c; echo '@metrics'; if [ -x /opt/tando/bin/tando-metrics ]; then"
    c="$c sudo -n /opt/tando/bin/tando-metrics read $a $SNAP_PTS $SNAP_BK; else echo 'mx	none'; fi"
    c="$c; echo '@health'; if [ -x $WATCH_BIN ]; then sudo -n $WATCH_BIN health $a; fi"
    c="$c; echo '@audit'; sudo -n $AGENT_BIN audit-read $a 300"
  fi
  printf '%s' "$c; printf 'clock\\t%s\\n' \"\$EPOCHREALTIME\""
}
WATCH_BIN=${WATCH_BIN:-/opt/tando/bin/tando-watch}

# snap_fetch app host...: the command on every host in parallel -> $TMPD/s.<host>.{out,err,rc}
snap_fetch() {
  local a=$1 h missing end pids cmd
  shift
  cmd=$(snap_cmd "$a")
  for h; do
    (
      host_use "$h"
      local try=0 rc
      while :; do
        ssh -n "${SSHO[@]}" "$TARGET" "$cmd" > "$TMPD/s.$h.out" 2> "$TMPD/s.$h.err"
        rc=$?
        # turned away before the command started (sshd MaxSessions): nothing ran, safe to retry
        [ "$rc" = 255 ] && [ $try -lt 3 ] && ssh_busy "$TMPD/s.$h.err" || break
        try=$((try + 1)); sleep "0.$((RANDOM % 8 + 2))$try"
      done
      echo "$rc" > "$TMPD/s.$h.rc.tmp" && mv "$TMPD/s.$h.rc.tmp" "$TMPD/s.$h.rc"
    ) < /dev/null > /dev/null 2>&1 &
  done
  end=$((SECONDS + SNAP_TIMEOUT))
  while [ $SECONDS -lt $end ]; do
    missing=0
    for h; do [ -f "$TMPD/s.$h.rc" ] || { missing=1; break; }; done
    [ $missing = 0 ] && break
    sleep 0.05
  done
  for h; do
    [ -f "$TMPD/s.$h.rc" ] && continue
    echo 124 > "$TMPD/s.$h.rc"; echo "no answer within $SNAP_TIMEOUT s" > "$TMPD/s.$h.err"
  done
  pids=$(jobs -p)
  # shellcheck disable=SC2086  # a list of pids
  [ -n "$pids" ] && { pkill -P "$(echo $pids | tr ' ' ',')" 2> /dev/null; kill $pids 2> /dev/null; }
  return 0
}

# snap_err host: the reason it did not answer, in a few words (host_err's rules)
snap_err() {
  cp "$TMPD/s.$1.err" "$TMPD/h.$1.err" 2> /dev/null
  host_err "$1"
}

# snap_render host app: one line of JSON
snap_render() {
  local h=$1 a=$2 rc clk srv
  NOW=$(now)
  rc=$(cat "$TMPD/s.$h.rc")
  # the sections: status rows (and loadavg, clock) -> st; each @section -> its own file
  : > "$TMPD/st"; : > "$TMPD/s.releases"; : > "$TMPD/s.history"; : > "$TMPD/s.metrics"; : > "$TMPD/s.health"; : > "$TMPD/s.audit"
  [ "$rc" = 0 ] && awk -v d="$TMPD" '
    /^@(releases|history|metrics|health|audit)$/ { f = d "/s." substr($0, 2); next }
    /^clock\t/ { print > (d "/st"); next }
    { print > (f == "" ? d "/st" : f) }' "$TMPD/s.$h.out"
  if [ "$rc" != 0 ] || ! grep -q "^host$TAB" "$TMPD/st"; then
    local e; e=$(snap_err "$h")
    printf '{"host":%s,"reachable":false,"error":%s,"checked_at":%s}\n' "$(json_str "$h")" \
      "$(json_str "${e:-unreachable}")" "$NOW"
    return 0
  fi
  HOST=$h
  # the server's clock: the clock row (bash's EPOCHREALTIME), else the server row of status
  clk=$(awk -F '\t' '$1 == "clock" { split($2, p, /[.,]/); c = p[1] } $1 == "server" && s == "" { s = $2 }
    END { print (c != "" ? c : s) }' "$TMPD/st")
  ui_int "$clk" && [ ${#clk} -le 12 ] || clk=""
  srv=${clk:-null}
  printf '{"host":%s' "$(json_str "$h")"; json_meta
  printf ',"server_now":%s' "$srv"
  system_json
  printf ',"apps":'; app_json_rows | to_json "$APP_JSON"
  printf ',"alerts":'; alerts_json
  if [ -n "$a" ]; then
    printf ',"app":'; snap_app "$a" "${clk:-$NOW}"
  fi
  printf '}\n'
}

# snap_app app server-now: the app object
snap_app() {
  local a=$1 sn=$2 row
  row=$(app_json_rows | awk -F '\t' -v a="$a" '$1 == a' | to_json "$APP_JSON" | sed 's/^\[//; s/\]$//')
  printf '{"name":%s,"status":%s' "$(json_str "$a")" "${row:-null}"
  # releases and history: the rows of their sections, read by the same functions as status --json
  cp "$TMPD/st" "$TMPD/st.keep"
  grep "^rel$TAB" "$TMPD/s.releases" > "$TMPD/st"
  printf ',"releases":'; rel_json
  printf ',"history":'; snap_history "$a"
  cp "$TMPD/st.keep" "$TMPD/st"
  printf ',"metrics":'; snap_metrics "$sn"
  printf ',"health":'; snap_health "$a" "$sn"
  pg_json "$TMPD/s.health" "$a"
  printf '}'
}

# snap_history app: history --json's objects plus "deployer", the audit line's who of that deploy
# (the activation's line "release <id>") or rollback ("from X to <id>"); null when the audit log
# no longer has it (rotated: 4 MB x 5) or the history row is older than the audit log.
snap_history() {
  awk -F '\t' -v OFS='\t' -v A="$1" '
    FILENAME ~ /s\.audit$/ {
      # audit <time> <who> <from> <verb> <app> <result> <note>
      if ($1 != "audit" || $6 != A) next
      if ($5 == "deploy" && $8 ~ /^release [0-9]+-[0-9]+/) { split($8, w, /[ :]/); who["deploy" SUBSEP w[2]] = $3 }
      if ($5 == "rollback" && $8 ~ / to [0-9]+-[0-9]+/) { n = split($8, w, " "); who["rollback" SUBSEP w[n]] = $3 }
      next }
    $1 == "hist" {
      k = (kind = $5) SUBSEP $4
      d = (k in who) ? who[k] : "-"
      if (d !~ /^[A-Za-z0-9._@-]+$/) d = "-"
      print $3, $2, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, d }' \
    "$TMPD/s.audit" "$TMPD/s.history" | sort -t "$TAB" -k1,1nr | to_json "$HIST_JSON,deployer:s"
}

# snap_metrics server-now: the range's buckets, every one present (null where no sample), oldest
# first. mx row: bucket seconds and the server's now; m rows: start, memory, cpu per mille of a core,
# restarts (the unit's counter, its maximum in the bucket), last state letter. restarts here is the
# per-bucket delta, clamped at 0 (a counter reset), null for a bucket without samples and 0 for
# the first bucket with samples (nothing before it to compare with).
snap_metrics() {
  awk -F '\t' -v P="$SNAP_PTS" -v B="$SNAP_BK" -v R="$SNAP_RANGE" -v SN="$1" '
    function n(v) { return (v ~ /^[0-9]+$/) ? v + 0 : "" }
    $1 == "mx" { if ($2 == "none") none = 1; else { if (n($3) != "") now = n($3) }; next }
    $1 == "m" { t = n($2); if (t == "") next; M[t] = n($3); C[t] = n($4); S[t] = n($5)
      st = $6; ST[t] = (st ~ /^[a-z]$/) ? st : ""; if (first == "" || t < first) first = t; next }
    END {
      if (none) { printf "null"; exit }
      if (now == "") now = SN + 0
      from = (int(now / B) - P + 1) * B
      printf "{\"range\":\"%s\",\"bucket_s\":%d,\"points\":%d,\"from\":%d,\"to\":%d,\"data_since\":%s,\"series\":[", R, B, P, from, from + (P - 1) * B, (first == "" ? "null" : first)
      prev = ""
      for (i = 0; i < P; i++) {
        t = from + i * B
        if (t in M) {
          r = (prev == "" || S[t] == "") ? 0 : S[t] - prev; if (r < 0) r = 0
          if (S[t] != "") prev = S[t]
          c = C[t]; cs = (c == "") ? "null" : sprintf("%d.%d", int(c / 10), c % 10)
          printf "%s{\"t\":%d,\"memory_bytes\":%s,\"cpu_percent\":%s,\"restarts\":%d,\"state\":%s}", (i ? "," : ""), t,
            (M[t] == "" ? "null" : M[t]), cs, r, (ST[t] == "" ? "null" : "\"" ST[t] "\"")
        } else printf "%s{\"t\":%d,\"memory_bytes\":null,\"cpu_percent\":null,\"restarts\":null,\"state\":null}", (i ? "," : ""), t
      }
      printf "]}" }' "$TMPD/s.metrics"
}

# snap_health app server-now: tando health --json's numbers for the app, its incidents, and the
# probe series: the average probe time of each of the last 24 hours (tando-watch's sparkline),
# hour i starting at now - 86400 + i * 3600. null without tando-watch (alerts not enabled).
snap_health() {
  awk -F '\t' -v A="$1" -v SN="$2" '
    function n(v) { return (v ~ /^[0-9]+$/) ? v + 0 : "null" }
    function pct(v) { return (v ~ /^[0-9]+$/) ? sprintf("%d.%02d", int(v / 100), v % 100) : "null" }
    function s(v) { if (v == "-" || v == "") return "null"; gsub(/\\/, "\\\\", v); gsub(/"/, "\\\"", v); return "\"" v "\"" }
    $1 == "up" && $2 == A { up = 1; u1 = pct($3); u7 = pct($4); m1 = n($5); m7 = n($6); ni = n($7); p50 = n($8); p95 = n($9)
      sp = $10; last = s($11); lm = n($12); fir = s($13) }
    $1 == "inc" && $2 == A { inc = inc (inc == "" ? "" : ",") sprintf("{\"start\":%s,\"end\":%s,\"check\":%s,\"cause\":%s}", n($3), n($4), s($5), s($6)) }
    END {
      if (!up) { printf "null"; exit }
      printf "{\"uptime_24h_pct\":%s,\"uptime_7d_pct\":%s,\"minutes_24h\":%s,\"minutes_7d\":%s,\"incidents_7d\":%s,\"p50_ms\":%s,\"p95_ms\":%s,\"last\":%s,\"last_ms\":%s,\"firing\":%s", u1, u7, m1, m7, ni, p50, p95, last, lm, fir
      from = SN - 86400
      printf ",\"series\":{\"bucket_s\":3600,\"stat\":\"avg_ms\",\"points\":["
      k = split(sp, v, ",")
      for (i = 1; i <= 24; i++) printf "%s{\"t\":%d,\"avg_ms\":%s}", (i > 1 ? "," : ""), from + (i - 1) * 3600, (i <= k ? n(v[i]) : "null")
      printf "]},\"incidents\":[%s]}", inc }' "$TMPD/s.health"
}
