# lib/cmd-alerts.sh: `tando alerts`, the client side of tando-watch (srv/watch) (see docs/MONITORING.md).
# help: alerts [--watch N] | enable | disable | test [name] | history [-n N]   alert state and delivery
# help: alerts set [key=value ...] | silence <app|all> <30m|2h|1d|off> | heartbeat [off]
# help: alerts backup-ping [off]                                  a URL called after whole daily backups
# help: alerts notifier add <name> webhook|slack|telegram|ntfy|email | notifier rm <name> | notifier ls
#
# bash 3.2. Secrets (webhook URLs, tokens) are read from the terminal without echo (or from stdin
# when it is not a terminal) and travel to the server on ssh's stdin; never in argv or on disk here.

WATCH_BIN=/opt/tando/bin/tando-watch

# watch_raw [sudo] verb args...: like agent_raw, for tando-watch; stdin passes through
watch_raw() {
  local s="" a rc
  [ "$1" = sudo ] && { s="sudo -n "; shift; }
  for a in "$@"; do
    case $a in ""|*[!A-Za-z0-9_.:=/@,+-]*) die "internal: unsafe argument '$a'";; esac
  done
  ssh "${SSHO[@]}" "$TARGET" "if [ ! -x $WATCH_BIN ]; then echo 'alerts are not set up on this host: tando alerts enable' >&2; exit 3; fi; $s$WATCH_BIN $*" \
    2> "$TMPD/werr" | strip
  rc=${PIPESTATUS[0]}
  [ -s "$TMPD/werr" ] && strip < "$TMPD/werr" >&2
  return "$rc"
}
watch_do() { watch_raw "$@" || bail 1; }

# read_secret "prompt" -> SECRET; no echo on a terminal, plain line from a pipe
read_secret() {
  SECRET=""
  if [ -t 0 ]; then
    printf '%s: ' "$1" >&2
    IFS= read -rs SECRET || SECRET=""
    printf '\n' >&2
  else
    IFS= read -r SECRET || SECRET=""
  fi
  case $SECRET in *[[:cntrl:]]*|*' '*) die "$1: no spaces or control characters";; esac
}
read_plain() { # "prompt" -> SECRET (echoed: not a secret)
  SECRET=""
  [ -t 0 ] && printf '%s: ' "$1" >&2
  IFS= read -r SECRET || SECRET=""
  case $SECRET in *[[:cntrl:]]*|*' '*) die "$1: no spaces or control characters";; esac
}

# "30m" "2h" "1d" "90s" "45" (minutes) -> seconds in SECS
parse_dur() {
  local n=${1%[smhd]} u=${1#"${1%[smhd]}"}
  is_num "$n" || return 1
  case $u in s) SECS=$n;; m|"") SECS=$((n * 60));; h) SECS=$((n * 3600));; d) SECS=$((n * 86400));; esac
  [ "$SECS" -le 2592000 ]
}

al_badge() { # state notified silenced flapping
  case $1 in
    firing) ui_badge failed firing;;
    pending) ui_badge pending pending;;
    *) ui_badge "$1";;
  esac
  [ "$3" = 1 ] && printf ' %s' "${UI_DIM}silenced${UI_NC}"
  [ "$4" = 1 ] && printf ' %s' "${UI_YELLOW}flapping${UI_NC}"
  return 0
}
ev_word() {
  case $1 in
    fire) ui_badge failed fired;; resolve) ui_badge ok resolved;; flap) ui_badge deploying flapping;;
    reboot) ui_badge deploying restarted;; rollback) ui_badge failed "rolled back";;
    restart) ui_badge deploying "restarted it";; newerror) ui_badge failed "new error";; *) printf '%s' "$1";;
  esac
}

fetch_alerts() {
  watch_raw sudo show 8 > "$TMPD/al.new" || return 1
  mv "$TMPD/al.new" "$TMPD/al"
  NOW=$(now)
}

# alerts --json: one object for scripts and the menu bar app: every firing or pending alert and
# every notifier (last delivery, failures in a row, the error), with reachable and checked_at
alerts_json() {
  printf '{"host":%s,"reachable":true,"checked_at":%s,"alerts":' "$(json_str "$HOST")" "$NOW"
  awk -F '\t' -v OFS='\t' '$1 == "alert" { print $2, $3, $4, $5, $6, $8 }' "$TMPD/al" |
    to_json "app:s,check:s,state:s,since:n,detail:s,silenced:b"
  printf ',"notifiers":'
  awk -F '\t' -v OFS='\t' '$1 == "notifier" { print $2, $3, $5, $6, $7, $9 }' "$TMPD/al" |
    to_json "name:s,type:s,last_ok:n,failures:n,queued:n,error:s"
  printf '}\n'
}
render_alerts() {
  [ -z "$JSON" ] || { alerts_json; return 0; }
  local r a b c d e f g h i j nf=0 np=0 nok=0 nbad=0 run_state="" run_detail="" sum="" hc hf hv
  # what the server's tando-watch would be after tando alerts enable: the script, or (a Go
  # program) the binary of either CPU
  for hc in amd64 arm64; do
    hf=$(helper_file tando-watch "$hc")
    [ -r "$hf" ] && sum="$sum $(cksum < "$hf" | cut -d' ' -f1)"
  done
  {
    printf 'APP\tCHECK\tSTATE\tSINCE\tDETAIL\n'
    while IFS=$TAB read -r r a b c d e f g h i; do
      [ "$r" = alert ] || continue
      case $c in firing) nf=$((nf + 1));; pending) np=$((np + 1));; esac
      printf '%s\t%s\t%s\t%s\t%s\n' "$a" "$b" "$(al_badge "$c" "$f" "$g" "$h")" "$(ago "$d")" "$e"
    done < "$TMPD/al"
  } > "$TMPD/al.rows"
  {
    printf 'NAME\tTYPE\tTARGET\tLAST OK\tSTATE\tQUEUED\n'
    while IFS=$TAB read -r r a b c d e f g h i; do
      [ "$r" = notifier ] || continue
      if [ "${e:-0}" = 0 ]; then nok=$((nok + 1)); g=$(ui_badge ok ok)
      else
        nbad=$((nbad + 1))
        g="$(ui_badge failed "failing x$e") $h"
      fi
      [ "${i:-0}" != 0 ] && [ "$i" != - ] && g="$g, $i dropped"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$a" "$b" "$c" "$( [ "$d" = - ] && echo never || ago "$d")" "$g" "$f"
    done < "$TMPD/al"
  } > "$TMPD/nf.rows"
  {
    printf 'TIME (GMT)\tEVENT\tAPP\tCHECK\tDETAIL\n'
    while IFS=$TAB read -r r a b c d e; do
      [ "$r" = hist ] || continue
      ui_utc_v "$a"; printf '%s\t%s\t%s\t%s\t%s\n' "$UI_RET" "$(ev_word "$b")" "$c" "$d" "$e"
    done < "$TMPD/al" | sed -n '1!G;h;$p'
  } > "$TMPD/hi.rows"
  while IFS=$TAB read -r r a b c; do
    [ "$r" = run ] && { run_state=$a; run_detail=$c; }
  done < "$TMPD/al"

  ui_box_open "alerts" "$HOST"
  watch_stale_line
  case $run_state in
    ok) ui_kv checks "$(ui_badge ok running)  $run_detail";;
    warn) ui_kv checks "$(ui_badge deploying warning)  $run_detail";;
    *) ui_kv checks "$(ui_badge failed "NOT RUNNING")  $run_detail";;
  esac
  local hb
  hb=$(awk -F '\t' '$1 == "heartbeat"' "$TMPD/al")
  if [ -n "$hb" ]; then
    printf '%s\n' "$hb" | {
      IFS=$TAB read -r r a b c d
      if [ "$c" != - ]; then ui_kv heartbeat "$(ui_badge failed failing) $a, last ok $(ago "$b")"
      elif [ "$b" = - ]; then ui_kv heartbeat "$a, every ${d}m, not pinged yet"
      else ui_kv heartbeat "$(ui_badge ok ok) $a, every ${d}m, last $(ago "$b")"; fi
    }
  elif [ -n "$(awk -F '\t' '$1 == "apps"' "$TMPD/al")" ]; then
    # a server with apps and nothing outside that would miss it: said in colour (tando doctor warns)
    ui_kv heartbeat "${UI_YELLOW}none: the server cannot report its own death; see tando alerts heartbeat${UI_NC}"
  else
    ui_kv heartbeat "${UI_DIM}none: the server cannot report its own death; see tando alerts heartbeat${UI_NC}"
  fi
  # the backup ping (tando alerts backup-ping): its last request, or why none is sent now
  hb=$(awk -F '\t' '$1 == "backup-ping"' "$TMPD/al")
  if [ -n "$hb" ]; then
    printf '%s\n' "$hb" | {
      IFS=$TAB read -r r a b c d
      [ "$d" = - ] && d=""
      if [ "$c" != - ]; then ui_kv_wrap backups "ping $(ui_badge failed failing) $a: ${d:-the request failed}, since $(ago "$c")"
      elif [ "$b" = - ]; then ui_kv_wrap backups "ping not sent yet${d:+: $d} ($a)"
      elif [ -n "$d" ]; then ui_kv_wrap backups "${UI_YELLOW}ping not sent now: $d${UI_NC} (last sent $(ago "$b"), $a)"
      else ui_kv backups "ping $(ui_badge ok ok) $a, sent after the last daily backups, $(ago "$b")"; fi
    }
  fi
  while IFS=$TAB read -r r a b; do
    [ "$r" = silence ] || continue
    if [ "$a" = all ]; then ui_kv silenced "all apps and host checks until $(when "$b")"
    else ui_kv silenced "$a until $(when "$b")"; fi
  done < "$TMPD/al"
  hv=$(awk -F '\t' '$1 == "version" { print $2; exit }' "$TMPD/al")
  case "$sum " in
    " "|*" $hv "*) ;;
    *) ui_kv version "${UI_YELLOW}the server's tando-watch differs from this client: tando alerts enable${UI_NC}";;
  esac

  ui_box_sep "active ($nf firing, $np pending)"
  if [ $((nf + np)) -gt 0 ]; then ui_table "l,l,l,r!2,l:10-!1" < "$TMPD/al.rows"
  else ui_box_line "$(ui_badge ok "all clear")"; fi
  ui_box_sep "notifiers"
  if [ $((nok + nbad)) -gt 0 ]; then ui_table "l,l!3,l:8-36!2,r!4,l:6-,r!1" < "$TMPD/nf.rows"
  else al_howto; fi
  ui_box_sep "recent"
  if [ "$(wc -l < "$TMPD/hi.rows")" -gt 1 ]; then ui_table "l,l,l,l,l:8-!1" < "$TMPD/hi.rows"
  else ui_box_line "no alerts yet"; fi
  ui_box_close "alerts history ${UI_G_MID} set ${UI_G_MID} silence ${UI_G_MID} test" "$(watch_note)"
}

# alerts_install: put tando-watch on the server and enable its timer (also used by host setup)
alerts_install() {
  # (host setup has just installed it with the other helpers: HELPERS_INSTALLED says so)
  if [ -z "${HELPERS_INSTALLED:-}" ] && ! install_helpers tando-watch tandod; then
    die "could not install tando-watch: $(strip < "$TMPD/err" | tail -2 | tr '\n' ' ')"
  fi
  watch_do sudo install > "$TMPD/o"
}
alerts_enable() {
  alerts_install
  ui_box_open "alerts enable" "$HOST"
  ui_step 1 2 install ok "/opt/tando/bin/tando-watch"
  ui_step 2 2 timer ok "tando-watch.timer: checks once a minute"
  ui_box_close "next: tando alerts notifier add phone ntfy, then tando alerts test"
}

# al_howto: what to do when nothing receives the alerts: the checks already run (host setup turned
# them on); only a place to send them is missing. One line per kind, ntfy first (no account needed)
al_howto() {
  ui_box_wrap "${UI_YELLOW}Alerts are already watching every app, but go nowhere yet:${UI_NC} they only show here. Pick where to send them (each asks for its URL or token, not shown):"
  ui_box_line "  tando alerts notifier add phone ntfy    ${UI_DIM}ntfy phone app, no account${UI_NC}"
  ui_box_line "  tando alerts notifier add team slack    ${UI_DIM}Slack incoming webhook${UI_NC}"
  ui_box_line "  tando alerts notifier add tg telegram   ${UI_DIM}bot token and chat id${UI_NC}"
  ui_box_line "  tando alerts notifier add hook webhook  ${UI_DIM}JSON POST to any URL${UI_NC}"
  ui_box_line "  tando alerts notifier add me email      ${UI_DIM}needs sendmail on the server${UI_NC}"
  ui_box_wrap "${UI_DIM}then tando alerts test. For ntfy: install the app, subscribe to a hard-to-guess topic, and give https://ntfy.sh/<that topic>.${UI_NC}"
}

# the settings of host care's alert checks (tando-host set; docs/HOSTCARE.md): sent there, not to
# tando-watch
HC_KEYS=" updates updates_days reboot reboot_days exposed allow_ports ssh units readonly ioerr clock clock_min eol eol_days boot boot_pct apt_hours "
alerts_set() {
  local kv hc=() w=()
  if [ $# -eq 0 ]; then
    watch_do sudo show 0 > "$TMPD/al"
    agent_raw sudo host settings >> "$TMPD/al" 2> /dev/null   # (a server without host care: none)
    {
      printf 'SETTING\tVALUE\n'
      awk -F '\t' '$1 == "conf" { print $2 "\t" $3 }' "$TMPD/al"
    } > "$TMPD/rows"
    ui_box_open "alerts settings" "$HOST"
    ui_table "l,l" < "$TMPD/rows"
    ui_box_close "tando alerts set key=value | <app>.key=value | <check>=off; key= resets"
    return
  fi
  for kv in "$@"; do
    case $kv in
      heartbeat|heartbeat=*) die "the heartbeat URL is a secret: use tando alerts heartbeat (it asks for it)";;
      backup-ping|backup-ping=*|backup_ping=*) die "the backup ping URL is a secret: use tando alerts backup-ping (it asks for it)";;
      allow_ports=*) case ${kv#*=} in *[!a-z0-9/,-]*) die "allow_ports is like tcp/5432,udp/51820";; esac;;
      *[!A-Za-z0-9_.=-]*) die "bad setting: $kv";;
      *=*) ;;
      *) die "expected key=value: $kv";;
    esac
    case $HC_KEYS in *" ${kv%%=*} "*) hc+=("$kv");; *) w+=("$kv");; esac
  done
  if [ ${#hc[@]} -gt 0 ]; then
    agent sudo host set < <(printf '%s\n' "${hc[@]}") > "$TMPD/o"
  fi
  [ ${#w[@]} -gt 0 ] && watch_do sudo set < <(printf '%s\n' "${w[@]}") > "$TMPD/o"
  note "alerts: set $*"
}

alerts_notifier() {
  local op=${1:-ls} name=${2:-} type=${3:-} f
  case $op in
    ls) fetch_alerts || exit 1; render_alerts;;
    rm)
      [ -n "$name" ] || die "usage: tando alerts notifier rm <name>"
      watch_do sudo notifier-rm "$name" > "$TMPD/o"; note "removed notifier $name";;
    add)
      [ -n "$name" ] && [ -n "$type" ] || die "usage: tando alerts notifier add <name> webhook|slack|telegram|ntfy|email [api=URL] [from=ADDR]"
      case $name in [a-z]*) ;; *) die "notifier names start with a-z";; esac
      case $name in *[!a-z0-9-]*) die "notifier names use a-z, 0-9, -";; esac
      : > "$TMPD/nf"; chmod 600 "$TMPD/nf"
      # the secret fields only ever live in shell variables and the ssh pipe
      case $type in
        webhook|slack)
          read_secret "$type URL (not shown)"; F1="url=$SECRET";;
        ntfy)
          read_secret "ntfy topic URL, e.g. https://ntfy.sh/<topic> (not shown)"; F1="url=$SECRET"
          read_secret "ntfy access token (empty for none; not shown)"; [ -n "$SECRET" ] && F2="token=$SECRET";;
        telegram)
          read_secret "Telegram bot token (not shown)"; F1="token=$SECRET"
          read_secret "Telegram chat id (not shown)"; F2="chat=$SECRET";;
        email)
          read_plain "send to (address)"; F1="to=$SECRET";;
        *) die "type must be webhook, slack, telegram, ntfy or email";;
      esac
      for f in "${@:4}"; do
        case $f in api=http*|from=*) ;; *) die "unknown option: $f (api=URL for a Telegram Bot API server, from=ADDR for email)";; esac
        case $f in *[!A-Za-z0-9_.:/@=+-]*) die "bad characters in $f";; esac
      done
      # never pipe into watch_do: in a pipeline its exit would only end the subshell
      watch_do sudo notifier-add "$name" "$type" > "$TMPD/o" \
        < <(printf '%s\n' "$F1" "${F2:-}"; [ $# -ge 4 ] && printf '%s\n' "${@:4}")
      F1="" F2="" SECRET=""
      note "added notifier $name ($type); send a test message with: tando alerts test $name";;
    *) die "notifier: add, rm or ls";;
  esac
}

alerts_test() {
  local r n s d ok=0 bad=0 title="" text=""
  watch_do sudo test ${1:+"$1"} > "$TMPD/o"
  {
    printf 'NOTIFIER\tRESULT\tTHE RECEIVER SAID\n'
    while IFS=$TAB read -r r n s d; do
      [ "$r" = sent ] && { title=$n text=$s; continue; }
      [ "$r" = test ] || continue
      # (an older tando-watch says "delivered" instead of the receiver's answer)
      if [ "$s" = ok ]; then ok=$((ok + 1)); printf '%s\t%s\t%s\n' "$n" "$(ui_badge ok delivered)" "$d"
      else bad=$((bad + 1)); printf '%s\t%s\t%s\n' "$n" "$(ui_badge failed failed)" "$d"; fi
    done < "$TMPD/o"
  } > "$TMPD/rows"
  ui_box_open "alerts test" "$HOST"
  if [ $((ok + bad)) -eq 0 ]; then al_howto; ui_box_close "nothing sent"; return 1; fi
  [ -n "$title" ] && ui_kv sent "$title: $text"
  ui_table "l,l,l" < "$TMPD/rows"
  if [ $bad -gt 0 ]; then
    ui_box_wrap "${UI_DIM}A failed notifier keeps its messages and retries them with a growing pause (1 min to 1 h); tando alerts and tando doctor show it as failing.${UI_NC}"
  fi
  ui_box_close "$ok delivered, $bad failed; check that the message arrived where you expect it"
  [ $bad -eq 0 ]
}

alerts_history() {
  local r a b c d e
  watch_do sudo history "$NLINES" > "$TMPD/o"
  {
    printf 'TIME (GMT)\tEVENT\tAPP\tCHECK\tDETAIL\n'
    sed -n '1!G;h;$p' "$TMPD/o" | while IFS=$TAB read -r r a b c d e; do
      [ "$r" = hist ] || continue
      [ -n "$APP" ] && [ "$c" != "$APP" ] && continue
      ui_utc_v "$a"; printf '%s\t%s\t%s\t%s\t%s\n' "$UI_RET" "$(ev_word "$b")" "$c" "$d" "$e"
    done
  } > "$TMPD/rows"
  ui_box_open "alerts history${APP:+ $APP}" "$HOST"
  if [ "$(wc -l < "$TMPD/rows")" -gt 1 ]; then ui_table "l,l,l,l,l:8-!1" < "$TMPD/rows"
  else ui_box_line "no alerts yet"; fi
  ui_box_close "newest first; -n N for more"
}

cmd_alerts() {
  local op=${ARGS[1]:-} want=$APP
  resolve 0
  APP=$want
  [ "$op" = history ] && [ -n "${ARGS[2]:-}" ] && APP=${ARGS[2]}
  NOW=$(now)
  case $op in
    ""|show) watch_loop render_alerts fetch_alerts;;
    enable) alerts_enable;;
    disable) watch_do sudo uninstall > "$TMPD/o"; note "alerts disabled on $HOST (settings, notifiers and state kept)";;
    test) alerts_test "${ARGS[2]:-}";;
    set) alerts_set "${ARGS[@]:2}";;
    notifier|notifiers) alerts_notifier "${ARGS[@]:2}";;
    history) [ "$NLINES" = 100 ] && NLINES=30; alerts_history;;
    heartbeat)
      if [ "${ARGS[2]:-}" = off ]; then
        watch_do sudo heartbeat < <(printf 'off\n') > "$TMPD/o"; note "heartbeat removed"
      else
        if [ -t 0 ]; then
          printf '%s\n' "The server cannot report its own death: if it is down, so is tando-watch. A heartbeat" \
            "turns that around: tando-watch calls a URL every few minutes, and an outside service (such as" \
            "healthchecks.io or Uptime Kuma, free) alerts you when the calls stop. Create a check there with a" \
            "period of 5 minutes and paste its ping URL." >&2
        fi
        read_secret "heartbeat URL, pinged after every check run (not shown)"
        watch_do sudo heartbeat < <(printf 'url=%s\n' "$SECRET") > "$TMPD/o"; SECRET=""
        note "heartbeat set: an outside service (such as healthchecks.io) now hears from $HOST every few minutes"
      fi;;
    backup-ping)
      if [ "${ARGS[2]:-}" = off ]; then
        watch_do sudo backup-ping < <(printf 'off\n') > "$TMPD/o"; note "backup ping removed"
      else
        if [ -t 0 ]; then
          printf '%s\n' "A backup that silently stopped is found out when it is needed. The backup ping turns that" \
            "around: after the daily backups, when every app's backup worked (and reached the offsite bucket," \
            "when that is on), tando calls a URL once. An outside service (such as healthchecks.io, free)" \
            "alerts you when a day passes without the call. Create a check there with a period of 1 day" \
            "and a grace of a few hours, and paste its ping URL." >&2
        fi
        read_secret "backup ping URL, called after the daily backups when all worked (not shown)"
        watch_do sudo backup-ping < <(printf 'url=%s\n' "$SECRET") > "$TMPD/o"; SECRET=""
        note "backup ping set: $HOST calls it after each whole run of the daily backups; tando alerts shows the last call"
      fi;;
    silence)
      local who=${ARGS[2]:-} d=${ARGS[3]:-}
      [ -n "$who" ] && [ -n "$d" ] || die "usage: tando alerts silence <app|all> <30m|2h|1d|off>"
      [ "$who" = all ] || valid_app "$who" || die "bad app name: $who (a-z, 0-9, -; 2-24 characters)"
      if [ "$d" = off ]; then SECS=0; else parse_dur "$d" || die "bad duration: $d (like 30m, 2h, 1d; at most 30d)"; fi
      watch_do sudo silence "$who" "$SECS" > "$TMPD/o"
      kv_read "$TMPD/o" until
      if [ "$SECS" = 0 ]; then note "alerts for $who are no longer silenced"
      else note "alerts for $who silenced until $(when "$K_until"); still recorded, sent afterwards if they keep firing"; fi;;
    *) die "alerts: (no argument), enable, disable, test, set, notifier, history, silence, heartbeat or backup-ping";;
  esac
}
