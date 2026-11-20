# shellcheck shell=bash
# lib/studio.sh: `tando db studio [app] [--no-open] [--idle M] [--stop]` (sourced by cmd_db). bash 3.2.
#
# A read-only web UI and SQL editor for the app's database. tando-studio (srv/studio) runs on the
# server as the app's user, on a unix socket; this command opens its own ssh connection (not the
# shared master: a forward asked through it would outlive this command) that forwards
# 127.0.0.1:<port> here to that socket, sends a heartbeat on the session's stdin, waits for the
# studio's "ready" line, checks that the port answers as *this* studio (/healthz and the probe
# word), opens the browser and waits. Ctrl-C, Stop in the page, the idle time or a lost
# heartbeat end it; afterwards the server is asked whether anything is left. The URL carries a
# code that works once (the page trades it for its key), so a URL in the browser history or in
# open's arguments is worth nothing later. docs/COMMANDS.md "tando db studio".
#
# Test hooks (test/e2e-studio.sh): TANDO_STUDIO_TEST="hb=1 idle-s=3 timeout=2" (the studio's
# heartbeat, idle time in seconds and statement limit), TANDO_STUDIO_HB (seconds between this
# side's heartbeats, 10).

STUDIO_PORT0=47100 STUDIO_PORTS=300   # the stable port of an app: away from 543xx (local Supabase, PostgreSQL)

# studio_port_free port: nothing answers on 127.0.0.1:port
studio_port_free() { ! (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null; }

# studio_probe port probe: the forward reaches this studio (not another program on the port)
studio_probe() {
  local l=""
  (
    exec 3<> "/dev/tcp/127.0.0.1/$1" || exit 1
    printf 'GET /healthz HTTP/1.0\r\nHost: 127.0.0.1:%s\r\nConnection: close\r\n\r\n' "$1" >&3
    while IFS= read -r -t 5 l <&3; do
      case $l in "tando-studio $2"*) exit 0;; esac
    done
    exit 1
  ) 2> /dev/null
}

studio_msgs() { agent_msgs | sed -e 's/^tando-studio: /tando: /'; }

# studio_end: stop the ssh session (the studio sees EOF and stops) and wait for it
studio_end() {
  [ -n "${STUDIO_SSH:-}" ] || return 0
  kill "$STUDIO_SSH" 2> /dev/null
  wait "$STUDIO_SSH" 2> /dev/null
  STUDIO_SSH=""
}

# studio_after reason: what is left on the server (the agent's rows: is this session's unit gone?)
studio_after() {
  local i rows
  for i in 1 2 3 4 5 6 7 8 9 10; do   # (ExecStopPost runs after the process exits: up to a few seconds)
    rows=$(ERRF=$TMPD/sls.err agent_raw sudo db-studio-ls "$APP" 2> /dev/null) || break
    case $rows in *"	${STUDIO_SID:0:12}	"*) sleep 0.5;; *)
      note "studio stopped${1:+ ($1)}; nothing of it left running on $HOST"; return 0;; esac
  done
  note "warning: the studio of $APP may still be running on $HOST: tando db studio --stop -a $APP"
  return 1
}

# studio_pick: no app named and no tando.conf here: the apps of the host, from one agent call.
# One with a database: that one (said so). Several, at a terminal: a numbered list to pick from
# (apps without a database dimmed, not offered). Not at a terminal: the list and the command for
# each, exit 2. Sets APP.
studio_pick() {
  resolve 0
  [ -z "${DEPLOY_KEY:-}" ] || die "tando db studio needs the admin's login, not a deploy key"
  agent sudo db-studio-ls > "$TMPD/apps"
  local r a db sz st n=0 i cands="" pick
  while IFS=$TAB read -r r a db sz st; do
    [ "$r" = app ] && [ "$db" = 1 ] && { n=$((n + 1)); cands="$cands $a"; }
  done < "$TMPD/apps"
  [ $n -gt 0 ] || die "no app on $HOST has a database (database = postgres in its tando.conf, then tando up)"
  if [ $n = 1 ]; then
    APP=${cands# }
    note "the one app with a database on $HOST is $APP: opening its studio (another time: tando db studio $APP)"
    return 0
  fi
  local tty=""; [ -t 0 ] && [ -t 2 ] && tty=1
  { if [ -n "$tty" ]; then printf 'Which app'"'"'s database? (on %s; one studio shows one app'"'"'s data)\n' "$HOST"
    else printf 'tando: name the app: tando db studio <app>. The apps on %s:\n' "$HOST"; fi
    i=0
    while IFS=$TAB read -r r a db sz st; do
      [ "$r" = app ] || continue
      case $sz in ""|*[!0-9]*) sz=0;; esac
      if [ "$db" = 1 ]; then
        i=$((i + 1))
        if [ -n "$tty" ]; then printf '  %2s) %-26s %9s  %s\n' "$i" "$a" "$(ui_bytes "$sz")" "$st"
        else printf '  tando db studio %-26s -H %s   # %s, %s\n' "$a" "$HOST" "$(ui_bytes "$sz")" "$st"; fi
      else printf '  %s%s%-26s no database%s\n' "$UI_DIM" "$( [ -n "$tty" ] && printf '    ' )" "$a" "$UI_NC"; fi
    done < "$TMPD/apps"; } >&2
  [ -n "$tty" ] || exit 2
  pick_num "$n" app
  i=0; for a in $cands; do i=$((i + 1)); [ "$i" = "$PICK" ] && APP=$a; done
  valid_app "$APP" || die "bad app name"
}

cmd_db_studio() {
  local noopen="" stop="" idle=30 i=2 a knobs="${TANDO_STUDIO_TEST:-}" hb=${TANDO_STUDIO_HB:-10}
  while [ $i -lt ${#ARGS[@]} ]; do
    a=${ARGS[i]}
    case $a in
      --no-open) noopen=1;;
      --stop) stop=1;;
      --idle) i=$((i + 1)); idle=${ARGS[i]:-}
        { is_num "$idle" && [ "$idle" -ge 5 ] && [ "$idle" -le 240 ]; } || usage_err "--idle is 5 to 240 minutes" db;;
      *) usage_err "db studio takes an app name and --no-open, --idle M, --stop (got $a)" db;;
    esac
    i=$((i + 1))
  done
  for a in $knobs; do case $a in hb=[0-9]*|idle-s=[0-9]*|timeout=[0-9]*|conn-idle=[0-9]*|prio=off) ;; *) die "bad TANDO_STUDIO_TEST: $a";; esac; done
  is_num "$hb" || die "bad TANDO_STUDIO_HB"
  # which app: -a or a word, else tando.conf, else ask (studio_pick)
  if [ -z "$APP" ] && ! { conf_load 2> /dev/null && [ -n "$C_app" ]; }; then studio_pick; fi
  resolve 1
  [ -z "${DEPLOY_KEY:-}" ] || die "tando db studio needs the admin's login, not a deploy key"
  if [ -n "$stop" ]; then
    agent sudo db-studio-stop "$APP" > "$TMPD/o"; kv_read "$TMPD/o" stopped
    note "stopped ${K_stopped:-0} studio session(s) of $APP on $HOST"
    return 0
  fi
  agent sudo db-studio-ls "$APP" > "$TMPD/sls"
  kv_read "$TMPD/sls" database installed
  [ "$K_database" = 1 ] || die "$APP has no database (add database = postgres to tando.conf, then tando up)"
  [ "$K_installed" = 1 ] || die "the studio is not installed on $HOST: tando host setup $HOST"
  STUDIO_SID=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  case $STUDIO_SID in [0-9a-f]*) ;; *) die "could not make a session id";; esac
  local port n=0 out=$TMPD/studio.out err=$TMPD/studio.err code="" probe="" t
  port=$(( STUDIO_PORT0 + $(printf '%s/%s' "$HOST" "$APP" | cksum | cut -d' ' -f1) % STUDIO_PORTS ))
  STUDIO_SSH=""
  trap 'studio_end; exit 130' INT
  trap 'studio_end; exit 143' TERM
  trap 'studio_end; exit 129' HUP
  while :; do
    n=$((n + 1)); [ $n -le 10 ] || die "no free port between $((port - 10)) and $((port - 1)) on this computer"
    if ! studio_port_free "$port"; then port=$((port + 1)); continue; fi
    : > "$out"; : > "$err"
    # its own connection (ControlPath=none before SSHO: the first value wins), the forward to the
    # studio's socket, the heartbeat on stdin
    # shellcheck disable=SC2029 # the remote command is built here on purpose (checked words only)
    # lint: allow RL04 APP passed valid_app, the other words are checked digits/hex, AGENT_BIN is a constant path
    ssh -o ControlMaster=no -o ControlPath=none "${SSHO[@]}" -T -o ExitOnForwardFailure=yes \
      -L "127.0.0.1:$port:/run/tando-studio/$STUDIO_SID/s" "$TARGET" \
      "sudo -n $AGENT_BIN db-studio $APP ro $STUDIO_SID $idle $port $HOST $knobs" \
      < <(while printf '\n'; do sleep "$hb"; done) > "$out" 2> "$err" &
    STUDIO_SSH=$!
    t=0
    while [ $t -lt 300 ]; do   # 30 s for the ready line
      grep -q '^ready ' "$out" 2> /dev/null && break
      kill -0 "$STUDIO_SSH" 2> /dev/null || break
      sleep 0.1; t=$((t + 1))
    done
    grep -q '^ready ' "$out" 2> /dev/null && break
    if ! kill -0 "$STUDIO_SSH" 2> /dev/null && grep -qE 'Address already in use|cannot listen to port|Could not request local forwarding' "$err"; then
      wait "$STUDIO_SSH" 2> /dev/null; STUDIO_SSH=""; port=$((port + 1)); continue   # (lost a race for the port)
    fi
    studio_end
    ssh_explain "$err" && exit 1
    if grep -q 'tando-\(agent\|studio\):' "$err"; then studio_msgs < "$err" | grep -v '^$' >&2; exit 1; fi
    die "the studio did not start on $HOST within 30 s$( [ -s "$err" ] && printf ': %s' "$(strip < "$err" | tail -2 | tr '\n' ' ')")"
  done
  code=$(sed -n 's/^ready code=\([A-Za-z0-9_-]*\) .*/\1/p' "$out" | head -1)
  probe=$(sed -n 's/^ready .* probe=\([A-Za-z0-9_-]*\) .*/\1/p' "$out" | head -1)
  if [ -z "$code" ] || [ -z "$probe" ] || ! studio_probe "$port" "$probe"; then
    studio_end
    if grep -qE 'administratively prohibited|open failed' "$err"; then
      explain "sshd on $HOST does not allow forwarding to a unix socket, which the studio needs" \
        "allow it for your login: a file /etc/ssh/sshd_config.d/tando-studio.conf with  Match User ${TARGET%@*}  and  AllowStreamLocalForwarding local  (then sudo systemctl reload ssh)" \
        "or use tando db psql"
    else
      note "tando: the studio started on $HOST but 127.0.0.1:$port does not answer as it (another program on the port?)"
    fi
    studio_after "did not answer"
    exit 1
  fi
  local url="http://127.0.0.1:$port/#c=$code" opened="open it in your browser (the link works once)"
  if [ -z "$noopen" ] && open_url "$url"; then opened="opened"; fi
  ui_box_open "$APP" "database studio"
  ui_kv studio "read-only, port $port of this computer" 10
  ui_kv browser "$opened" 10
  ui_kv stops "Ctrl-C here, Stop in the page, or after $idle min unused" 10
  ui_box_close "tando_${APP//-/_} on $HOST · through this ssh session only"
  printf '%s\n' "$url"   # (whole, on a line of its own: it is copied)
  # until the session ends (a signal's trap stops it and exits; the post-check runs below)
  trap 'studio_end; studio_after "Ctrl-C"; exit 130' INT
  trap 'studio_end; studio_after "terminated"; exit 143' TERM HUP
  wait "$STUDIO_SSH" 2> /dev/null
  STUDIO_SSH=""
  trap - INT TERM HUP
  local why
  why=$(sed -n 's/^stopped reason=\([a-z]*\) .*/\1/p' "$out" | head -1)
  case $why in
    end) why="Stop in the page";; idle) why="unused for $idle min";; heartbeat) why="this computer stopped answering";;
    eof) why="the ssh session ended";; signal) why="stopped on the server";; "") why="the ssh connection ended";;
  esac
  studio_after "$why"
}
