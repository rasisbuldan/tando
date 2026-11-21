# shellcheck shell=bash
# help: top [host] [--watch N] [--read-only]  live dashboard: hosts, apps, graphs, logs, history
#
# lib/cmd-top.sh: `tando top`, a full-screen dashboard. bin/tando sources it and calls cmd_top
# with the original arguments. Runs on macOS /bin/bash 3.2.
#
# Design:
# - One loop: read a key (bash 3.2 has whole-second read timeouts only, so the loop wakes at
#   least once a second and at once on a key), look at the background jobs, repaint when
#   something changed. Nothing in the loop waits on the network.
# - Every server call runs in the background into $TD files. One ssh call per host per refresh,
#   over the ControlMaster connection: `tando-agent status` for every host; on the selected host
#   also the selected app's releases and history (every 10 s, or when the selection changes)
#   and its metric history (when the graphs need it) while the detail pane is shown, and the
#   long history list only while the history view is open. A fetch that runs longer than
#   TOP_TIMEOUT seconds is killed and the host is shown as not answering, with its last data
#   greyed and aged.
# - Server output is read with `read` into whitelisted row types and only ever printed.
# - The terminal is restored on every exit path (q, Ctrl-C, SIGTERM, SIGHUP, errors): the EXIT
#   trap leaves the alternate screen, shows the cursor and restores the saved stty modes.

TOP_TIMEOUT=12

top_usage() { usage_err "usage: tando top [host] [--watch N] [--read-only]"; }

cmd_top() {
  local h i
  TOP_INT=2 TOP_RO=0 TOP_FIRST=""
  while [ $# -gt 0 ]; do
    case $1 in
      top) shift;;
      --watch) { is_num "${2:-}" && [ "$2" -ge 1 ]; } || top_usage; TOP_INT=$2; shift 2;;
      --read-only) TOP_RO=1; shift;;
      -H) TOP_FIRST=${2:-}; shift 2;;
      -*) top_usage;;
      *) TOP_FIRST=$1; shift;;
    esac
  done
  [ -t 0 ] && [ -t 1 ] || die "tando top needs a terminal; without one: tando ls --all"
  TH_NAME=()
  for h in $(all_hosts); do TH_NAME[${#TH_NAME[@]}]=$h; done
  [ ${#TH_NAME[@]} -gt 0 ] || die "no hosts registered: tando host add"
  TOP_H=0
  if [ -n "$TOP_FIRST" ]; then
    TOP_H=-1
    for ((i = 0; i < ${#TH_NAME[@]}; i++)); do [ "${TH_NAME[i]}" = "$TOP_FIRST" ] && TOP_H=$i; done
    [ $TOP_H -ge 0 ] || die "unknown host: $TOP_FIRST"
  fi
  TD=$TMPD/top
  mkdir -p "$TD" || die "no temp dir"
  # ssh options per host, worked out once (host_use forks; fetches run every few seconds)
  for ((i = 0; i < ${#TH_NAME[@]}; i++)); do
    host_use "${TH_NAME[i]}"
    ssh_wrapper; TH_SSH[i]=$SSH_WRAPPER   # lib/common.sh: ssh with this host's options
    TH_TARGET[i]=$TARGET TH_GOOD[i]=""
  done
  for ((i = 0; i < ${#TH_NAME[@]}; i++)); do
    TH_ST[i]=new TH_ERR[i]="" TH_OKAT[i]=-1 TH_PID[i]="" TH_T0[i]=0 TH_DUE[i]=0 TH_CLK[i]=0
    TH_LOAD[i]=0 TH_CPUS[i]=1 TH_MT[i]=0 TH_MU[i]=0 TH_DT[i]=0 TH_DU[i]=0 TH_NAPPS[i]=0 TH_NBAD[i]=0 TH_NFIRE[i]=0 TH_FIRING[i]=""
  done
  TOP_KEYED=1 TOP_VIEW=main TOP_DETAIL=1 TOP_CDETAIL=0 TOP_MODAL="" SEL_APP="" SEL=0 TOP_DIRTY=1 AP_N=0
  D_APP="" D_NEED=1 D_DUE=0 D_REL=() D_HIST=() HV_ROWS=() HV_TOP=0 LOG_TOP=0 LOG_FOLLOW=1
  G_BK=60 G_NEED=1 G_W=60 G_KEY="" LOG_PID="" TOP_ACT_PID="" TOP_LAST_RENDER=-1 TOP_LAST_W=0
  TOP_ACT="" TOP_ACT_APP="" TOP_ACT_HOST="" TOP_RESULT=() APPS_TOP=0

  # stderr goes to a file while the screen is ours; its tail is shown after leaving
  exec 3>&2 2> "$TD/stderr"
  trap 'top_cleanup' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  trap 'UI_WINCH=1' WINCH
  UI_MAX_W=${TANDO_TOP_MAX_W:-160}
  ui_term_enter
  top_loop
}

top_cleanup() {
  local p
  trap - EXIT INT TERM HUP WINCH
  for p in "${TH_PID[@]}" $LOG_PID $TOP_ACT_PID; do
    [ -n "$p" ] || continue
    pkill -P "$p" 2> /dev/null; kill "$p" 2> /dev/null
  done
  ui_frame_cleanup
  exec 2>&3
  if [ -s "$TD/stderr" ]; then
    printf 'tando top: messages while running:\n' >&2; tail -5 "$TD/stderr" >&2
  fi
  if [ -n "${TANDO_TOP_KEEP:-}" ]; then rm -rf "$TANDO_TOP_KEEP"; cp -R "$TD" "$TANDO_TOP_KEEP"; fi
  rm -rf "$TMPD"
}

top_loop() {
  local rc
  while :; do
    [ "$UI_WINCH" = 1 ] && TOP_DIRTY=1
    top_poll
    # new data repaints at most once a second; a key repaints at once
    if [ "$TOP_KEYED" = 1 ] || [ "$SECONDS" != "$TOP_LAST_RENDER" ] && { [ "$TOP_DIRTY" = 1 ] || top_ticking; }; then
      top_render
    fi
    TOP_KEYED=0
    ui_key 1; rc=$?
    [ $rc = 2 ] && exit 0
    [ $rc = 1 ] && continue
    top_on_key "$UI_KEY"
    TOP_DIRTY=1 TOP_KEYED=1
  done
}

# Something on screen changes by itself every second: a spinner, a slow or failing host.
top_ticking() {
  local i
  [ -n "$TOP_ACT_PID" ] && return 0
  for ((i = 0; i < ${#TH_NAME[@]}; i++)); do
    if [ -n "${TH_PID[i]}" ] && [ $((SECONDS - TH_T0[i])) -ge 2 ]; then return 0; fi
    [ "${TH_ST[i]}" = err ] && return 0
  done
  return 1
}

# ---- background jobs ------------------------------------------------------------------------

top_poll() {
  local i rc
  for ((i = 0; i < ${#TH_NAME[@]}; i++)); do
    if [ -n "${TH_PID[i]}" ]; then
      rc=""
      [ -f "$TD/h$i.rc" ] && read -r rc < "$TD/h$i.rc"
      if [ -n "$rc" ]; then
        : > "$TD/h$i.rc"              # consumed (truncate: no fork)
        TH_PID[i]=""
        top_take "$i" "$rc"
        TH_DUE[i]=$((SECONDS + TOP_INT)); TOP_DIRTY=1
      elif [ $((SECONDS - TH_T0[i])) -ge $TOP_TIMEOUT ]; then
        pkill -P "${TH_PID[i]}" 2> /dev/null; kill "${TH_PID[i]}" 2> /dev/null
        TH_PID[i]="" TH_ST[i]=err TH_ERR[i]="no answer within $TOP_TIMEOUT s"
        TH_DUE[i]=$((SECONDS + TOP_INT)); TOP_DIRTY=1
      fi
    fi
    if [ -z "${TH_PID[i]}" ] && [ "$SECONDS" -ge "${TH_DUE[i]}" ]; then top_fetch "$i"; fi
  done
  if [ -n "$TOP_ACT_PID" ] && [ -f "$TD/act.rc" ]; then top_act_done; fi
  if [ "$TOP_VIEW" = log ]; then top_log_read; fi
  return 0
}

# The remote command for host i: status, plus what the visible views need.
top_fetch() {
  # read verbs through sudo: an app's metadata is readable by root and the app's group only
  local i=$1 cmd="sudo -n $AGENT_BIN status" f="$TD/h$1" a=$SEL_APP
  if [ "$i" = "$TOP_H" ] && [ -n "$a" ] && valid_app "$a"; then
    if [ "$TOP_DETAIL" = 1 ] || [ "$TOP_CDETAIL" = 1 ] || [ "$TOP_VIEW" != main ]; then
      if [ "$D_NEED" = 1 ] || [ "$SECONDS" -ge "$D_DUE" ]; then
        cmd="$cmd; echo '@detail	$a'; sudo -n $AGENT_BIN releases $a; sudo -n $AGENT_BIN history $a 6"
        D_NEED=0 D_DUE=$((SECONDS + 10))
      fi
      if [ "$G_NEED" = 1 ]; then
        cmd="$cmd; echo '@metrics	$a'; if [ -x /opt/tando/bin/tando-metrics ]; then"
        cmd="$cmd sudo -n /opt/tando/bin/tando-metrics read $a $G_W $G_BK; else echo 'mx	none'; fi"
        G_NEED=0
      fi
    fi
    if [ "$TOP_VIEW" = history ]; then cmd="$cmd; echo '@hist	$a'; sudo -n $AGENT_BIN history $a 60"; fi
  fi
  cmd="$cmd; printf 'clock\t%s\n' \"\$EPOCHREALTIME\""
  # write into the data file that does not hold the last good answer (no mv: one fork less)
  local out="$f.A"; [ "${TH_GOOD[i]}" = "$f.A" ] && out="$f.B"
  TH_OUT[i]=$out
  (
    "${TH_SSH[i]}" -n "${TH_TARGET[i]}" "$cmd" > "$out" 2> "$f.err"
    echo $? > "$f.rc"
  ) < /dev/null > /dev/null 2> "$f.err2" &
  TH_PID[i]=$! TH_T0[i]=$SECONDS
}

# A fetch finished.
top_take() {
  local i=$1 rc=$2 l
  if [ "$rc" != 0 ]; then
    TH_ST[i]=err TH_ERR[i]=""
    while IFS= read -r l; do [ -n "$l" ] && TH_ERR[i]=$l; done < "$TD/h$i.err"
    [ -n "${TH_ERR[i]}" ] || TH_ERR[i]="ssh failed ($rc)"
    _ui_vis "${TH_ERR[i]}"; TH_ERR[i]=$_UP
    return 0
  fi
  TH_ST[i]=ok TH_ERR[i]="" TH_OKAT[i]=$SECONDS TH_GOOD[i]=${TH_OUT[i]}
  top_parse "$i" 1
}

# top_parse i fresh: read $TD/h<i>.data (rows: host, app, rel, hist, mx, m, clock, @section).
# fresh=1 for a new sample (cpu %, live graph points, detail sections); 0 to re-read the last.
top_parse() {
  local i=$1 fresh=$2 f=${TH_GOOD[$1]} r v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15
  local sect="" clk=0 ms=0 na=0 nbad=0 pv tv cv key nfire=0 fl=""
  [ -n "$f" ] && [ -f "$f" ] || return 0
  # the server clock first (last row): cpu % and graph buckets use it
  while IFS=$TAB read -r r v1 v2; do
    if [ "$r" = clock ]; then
      clk=${v1%%.*}; ms=${v1#*.}; ms=${ms:0:3}
      ui_int "$clk" || clk=0
      case $ms in [0-9][0-9][0-9]) ;; *) ms=000;; esac
    fi
  done < "$f"
  [ "$clk" = 0 ] || TH_CLK[i]=$clk
  local clkms=$((clk * 1000 + 10#$ms))
  [ "$i" = "$TOP_H" ] && AP_N=0
  # app rows have more fields after v15 (logs: bytes, cap, lines, hourly); they are not used here
  while IFS=$TAB read -r r v1 v2 v3 v4 v5 v6 v7 v8 v9 v10 v11 v12 v13 v14 v15 _; do
    # every field that can reach arithmetic is checked here, at the boundary: server output is
    # data, never part of an expression ($(( )) runs a[$(cmd)]; SECURITY-REVIEW-2 N4)
    case $r in
      host) ui_nums v2 v4 v5 v6 v7; ui_nums -d v3;;
      app) valid_app "$v1" || continue      # the name builds variable names below
           ui_nums v3 v6 v7 v8 v9 v10; ui_int "$v14" || v14=-;;
      hist) ui_int "$v2" || v2=-;;
      m) ui_nums v1 v2 v3;;
    esac
    case $r in
      @detail|@metrics|@hist)
        sect=""
        [ "$fresh" = 1 ] && [ "$i" = "$TOP_H" ] && [ "$v1" = "$SEL_APP" ] && sect=$r
        case $sect in
          @detail) D_REL=() D_HIST=() D_APP=$v1;;
          @metrics) GH_M=() GH_C=();;
          @hist) HV_ROWS=();;
        esac;;
      host)  # name cpus load mem_total mem_used disk_total disk_used uptime
        TH_CPUS[i]=$v2 TH_LOAD[i]=$v3 TH_MT[i]=$v4 TH_MU[i]=$v5 TH_DT[i]=$v6 TH_DU[i]=$v7;;
      app)   # name state port release rel_status mem max cpu_ns restarts up link recipe backup last_backup db
        na=$((na + 1))
        [ "$v2" = failed ] && nbad=$((nbad + 1))
        key="${i}_${v1//[!a-zA-Z0-9]/_}"
        pv="TCN_$key" tv="TCT_$key" cv="TCP_$key"
        if [ "$fresh" = 1 ] && is_num "$v8" && [ "$clk" -gt 0 ]; then
          if [ -n "${!pv:-}" ] && [ "$clkms" -gt "${!tv}" ] && [ "$v8" -ge "${!pv}" ]; then
            printf -v "$cv" '%s' $(( (v8 - ${!pv}) / (clkms - ${!tv}) / 1000 ))   # permille of a core
          fi
          printf -v "$pv" '%s' "$v8"; printf -v "$tv" '%s' "$clkms"
        fi
        if [ "$i" = "$TOP_H" ]; then
          AP_NAME[AP_N]=$v1 AP_STATE[AP_N]=$v2 AP_PORT[AP_N]=$v3 AP_REL[AP_N]=$v4 AP_RST[AP_N]=$v5
          AP_MEM[AP_N]=$v6 AP_MAX[AP_N]=$v7 AP_RS[AP_N]=$v9 AP_UP[AP_N]=$v10 AP_LINK[AP_N]=$v11
          AP_RECIPE[AP_N]=$v12 AP_BK[AP_N]=$v13 AP_LAST[AP_N]=$v14 AP_DB[AP_N]=$v15
          AP_PCT[AP_N]=${!cv:--}
          AP_N=$((AP_N + 1))
          if [ "$fresh" = 1 ] && [ "$v1" = "$SEL_APP" ] && [ "$clk" -gt 0 ]; then
            top_graph_live "$clk" "$v6" "${!cv:-}"
          fi
        fi;;
      rel) [ "$sect" = @detail ] && D_REL[${#D_REL[@]}]="$v1$TAB$v2$TAB$v3$TAB$v4";;
      hist)
        if [ "$sect" = @detail ]; then D_HIST[${#D_HIST[@]}]="$v2$TAB$v3$TAB$v4$TAB$v5$TAB$v6"
        elif [ "$sect" = @hist ]; then
          HV_ROWS[${#HV_ROWS[@]}]="$v2$TAB$v3$TAB$v4$TAB$v5$TAB$v6$TAB$v7$TAB$v8$TAB$v9$TAB$v10$TAB$v11$TAB$v12$TAB$v13"
        fi;;
      m) [ "$sect" = @metrics ] && [ "$v1" != 0 ] && top_graph_hist "$v1" "$v2" "$v3";;
      alert) # app check state since detail; only plain words reach the list (it is word-split)
        case $v1$v2 in *[!a-z0-9_.-]*) continue;; esac
        [ "$v3" = firing ] && nfire=$((nfire + 1)) fl="$fl $v1:$v2";;
      mx) [ "$sect" = @metrics ] && [ "$v1" = none ] && G_NOMETRICS=1;;
    esac
  done < "$f"
  TH_NAPPS[i]=$na TH_NBAD[i]=$nbad TH_NFIRE[i]=$nfire TH_FIRING[i]=$fl
  [ "$i" = "$TOP_H" ] && top_select_fix
  return 0
}

# Keep the selection on the same app name when rows move.
top_select_fix() {
  local j
  if [ "$AP_N" = 0 ]; then SEL=0; SEL_APP=""; return 0; fi
  for ((j = 0; j < AP_N; j++)); do
    if [ "${AP_NAME[j]}" = "$SEL_APP" ]; then SEL=$j; return 0; fi
  done
  [ "$SEL" -ge "$AP_N" ] && SEL=$((AP_N - 1))
  top_select "$SEL"
}

top_select() {
  SEL=$1
  if [ "${AP_NAME[SEL]:-}" != "$SEL_APP" ]; then
    SEL_APP=${AP_NAME[SEL]:-}
    D_NEED=1 G_NEED=1 D_REL=() D_HIST=() HV_ROWS=() HV_TOP=0 G_NOMETRICS=0
    top_graph_reset "$SEL_APP"
    TH_DUE[TOP_H]=0
  fi
}

# ---- graph series: buckets of G_BK seconds, sparse arrays indexed by bucket number ----------

top_graph_reset() {
  GH_M=() GH_C=() GL_M=() GL_C=() GL_N=()
  G_KEY="$TOP_H/$1"
}
top_graph_hist() { # bucket_start mem cpu_permille: from tando-metrics
  local b=$(($1 / G_BK))
  GH_M[b]=$2 GH_C[b]=$3
}
top_graph_live() { # server_epoch mem cpu_permille: a live sample from status
  local b=$(($1 / G_BK)) n
  is_num "$2" || return 0
  n=${GL_N[b]:-0}
  GL_M[b]=$(( ${GL_M[b]:-0} + $2 ))
  if is_num "$3"; then GL_C[b]=$(( ${GL_C[b]:-0} + $3 )); fi
  GL_N[b]=$((n + 1))
}
# top_graph_series width -> G_MEM, G_CPU: space-separated values, oldest first ("-" = no data)
top_graph_series() {
  local w=$1 now b last k=0
  now=$(( (TH_CLK[TOP_H] + SECONDS - TH_OKAT[TOP_H]) / G_BK ))
  G_MEM="" G_CPU="" G_PEAKC=0 G_PEAKM=0
  for ((b = now - w + 1; b <= now; b++)); do
    if [ -n "${GL_N[b]:-}" ]; then
      G_MEM+="$((GL_M[b] / GL_N[b])) "
      if [ -n "${GL_C[b]:-}" ]; then G_CPU+="$((GL_C[b] / GL_N[b])) "; else G_CPU+="- "; fi
    elif [ -n "${GH_M[b]:-}" ]; then
      G_MEM+="${GH_M[b]} " G_CPU+="${GH_C[b]} "
    else
      G_MEM+="- " G_CPU+="- "
    fi
  done
  for k in $G_CPU; do [ "$k" != - ] && [ "$k" -gt "$G_PEAKC" ] && G_PEAKC=$k; done
  for k in $G_MEM; do [ "$k" != - ] && [ "$k" -gt "$G_PEAKM" ] && G_PEAKM=$k; done
  return 0
}

# ---- actions (restart, stop/start, rollback): confirmed, run in the background ---------------

top_ask() { # action
  local verb=$1 st=${AP_STATE[SEL]:-}
  [ -n "$SEL_APP" ] || return 0
  if [ "$TOP_RO" = 1 ]; then TOP_MODAL=ro; return 0; fi
  if [ -n "$TOP_ACT_PID" ]; then TOP_MODAL=busy; return 0; fi
  if [ "$verb" = toggle ]; then
    case $st in active|activating|deploying) verb=stop;; *) verb=start;; esac
  fi
  TOP_ACT=$verb TOP_ACT_APP=$SEL_APP TOP_ACT_HOST=${TH_NAME[TOP_H]} TOP_MODAL=confirm
  ui_key_flush    # keys typed or pasted before the question are not answers
}

top_act_start() {
  local f=$TD/act a=$TOP_ACT_APP verb=$TOP_ACT
  rm -f "$f.rc" "$f.out" "$f.err"
  valid_app "$a" || return 0
  (
    host_use "$TOP_ACT_HOST"
    ERRF=$f.err
    agent_raw sudo "$verb" "$a" > "$f.out" 2> /dev/null
    echo $? > "$f.rc.tmp" && mv -f "$f.rc.tmp" "$f.rc"
  ) < /dev/null > /dev/null 2> "$f.err2" &
  TOP_ACT_PID=$! TOP_ACT_T0=$SECONDS TOP_MODAL=busy
}

top_act_done() {
  local rc l k v healthy="" cur="" last=""
  read -r rc < "$TD/act.rc"; rm -f "$TD/act.rc"
  TOP_ACT_PID=""
  while IFS='=' read -r k v; do
    case $k in healthy) healthy=$v;; current) cur=$v;; esac
  done < "$TD/act.out"
  while IFS= read -r l; do [ -n "$l" ] && last=$l; done < "$TD/act.err"
  _ui_vis "$last"; last=$_UP
  TOP_RESULT=()
  if [ "$rc" = 0 ]; then
    case $TOP_ACT in
      rollback) TOP_RESULT=("${UI_GREEN}${UI_G_OK}${UI_NC} $TOP_ACT_APP rolled back" "now on release $cur");;
      stop) TOP_RESULT=("${UI_GREEN}${UI_G_OK}${UI_NC} $TOP_ACT_APP stopped");;
      *) if [ "$healthy" = 1 ]; then TOP_RESULT=("${UI_GREEN}${UI_G_OK}${UI_NC} $TOP_ACT_APP: ${TOP_ACT}ed, health check passes")
         else TOP_RESULT=("${UI_YELLOW}!${UI_NC} $TOP_ACT_APP: ${TOP_ACT}ed, but the health check through Caddy fails"
                          "see the log (l)"); fi;;
    esac
  else
    TOP_RESULT=("${UI_RED}${UI_G_ERR}${UI_NC} $TOP_ACT on $TOP_ACT_APP failed" "${last:-exit status $rc}")
  fi
  TOP_MODAL=result D_NEED=1 TOP_DIRTY=1
  local i
  for ((i = 0; i < ${#TH_NAME[@]}; i++)); do [ "${TH_NAME[i]}" = "$TOP_ACT_HOST" ] && TH_DUE[i]=0; done
}

# ---- log view: journal of the app, followed in the background into a file --------------------

top_log_open() {
  [ -n "$SEL_APP" ] && valid_app "$SEL_APP" || return 0
  local a=$SEL_APP h=${TH_NAME[TOP_H]}
  top_log_close
  : > "$TD/log"
  (
    host_use "$h"
    valid_app "$a" || exit 1
    # lint: allow RL04 $a is a checked app name, AGENT_BIN a constant path
    exec ssh -n "${SSHO[@]}" "$TARGET" "sudo -n $AGENT_BIN logs $a 300 follow"
  ) < /dev/null > "$TD/log" 2> "$TD/log.err" &
  LOG_PID=$! LOG_APP=$a LOG_HOST=$h
  LOG_N=0 LOG_PART="" LOG_TOP=0 LOG_FOLLOW=1 LOG_L=()
  exec 7< "$TD/log"
  TOP_VIEW=log
}

top_log_close() {
  if [ -n "$LOG_PID" ]; then pkill -P "$LOG_PID" 2> /dev/null; kill "$LOG_PID" 2> /dev/null; LOG_PID=""; fi
  exec 7<&- 2> /dev/null
  LOG_L=() LOG_N=0
}

LOG_CAP=2000
top_log_read() {
  local l got=0
  while :; do
    if IFS= read -r -u 7 l; then
      l="$LOG_PART$l" LOG_PART=""
    else
      [ -n "$l" ] && LOG_PART="$LOG_PART$l"     # a line still being written
      break
    fi
    _ui_vis "$l"
    LOG_L[LOG_N % LOG_CAP]=$_UP
    LOG_N=$((LOG_N + 1)) got=1
  done
  [ $got = 1 ] && TOP_DIRTY=1
  return 0
}

# ---- keys -----------------------------------------------------------------------------------

top_on_key() {
  local k=$1
  case $TOP_MODAL in
    confirm)
      TOP_MODAL=""
      [ "$k" = y ] || [ "$k" = Y ] && top_act_start
      return 0;;
    busy) case $k in esc|q|enter|space) TOP_MODAL="";; esac; return 0;;
    result|help|ro) TOP_MODAL=""; return 0;;
  esac
  case $TOP_VIEW in
    log) top_key_log "$k"; return 0;;
    history) top_key_hist "$k"; return 0;;
  esac
  case $k in
    q) exit 0;;
    up|k) [ "$SEL" -gt 0 ] && top_select $((SEL - 1));;
    down|j) [ $((SEL + 1)) -lt "$AP_N" ] && top_select $((SEL + 1));;
    home|g) [ "$AP_N" -gt 0 ] && top_select 0;;
    end|G) [ "$AP_N" -gt 0 ] && top_select $((AP_N - 1));;
    left|backtab) top_host $((TOP_H - 1));;
    right|tab) top_host $((TOP_H + 1));;
    enter|space)
      if [ "$UI_COLS" -lt 80 ] || [ "$UI_ROWS" -lt 20 ]; then
        if [ "$TOP_CDETAIL" = 1 ]; then TOP_CDETAIL=0; else TOP_CDETAIL=1; D_NEED=1; G_NEED=1; TH_DUE[TOP_H]=0; fi
        return 0
      fi
      if [ "$TOP_DETAIL" = 1 ]; then TOP_DETAIL=0; else TOP_DETAIL=1; D_NEED=1; G_NEED=1; TH_DUE[TOP_H]=0; fi;;
    l) top_log_open;;
    h) [ -n "$SEL_APP" ] && { TOP_VIEW=history; HV_TOP=0; TH_DUE[TOP_H]=0; };;
    r) top_ask restart;;
    s) top_ask toggle;;
    b) top_ask rollback;;
    t) case $G_BK in 60) G_BK=300;; 300) G_BK=1800;; *) G_BK=60;; esac
       top_graph_reset "$SEL_APP"; G_NEED=1; TH_DUE[TOP_H]=0;;
    '?') TOP_MODAL=help;;
  esac
  return 0
}

top_host() {
  local n=${#TH_NAME[@]} i=$1
  ((n <= 1)) && return 0
  ((i < 0)) && i=$((n - 1))
  ((i >= n)) && i=0
  TOP_H=$i SEL=0 SEL_APP="" APPS_TOP=0
  top_parse "$i" 0
  top_select 0
  TH_DUE[i]=0
}

top_key_log() {
  local h=$((UI_ROWS - 2)) total=$LOG_N
  ((total > LOG_CAP)) && total=$LOG_CAP
  case $1 in
    q|esc|l) top_log_close; TOP_VIEW=main;;
    up|k) LOG_FOLLOW=0; LOG_TOP=$((LOG_TOP - 1));;
    down|j) LOG_TOP=$((LOG_TOP + 1)); top_log_end "$h" "$total";;
    pgup) LOG_FOLLOW=0; LOG_TOP=$((LOG_TOP - h + 1));;
    pgdn|space) LOG_TOP=$((LOG_TOP + h - 1)); top_log_end "$h" "$total";;
    home|g) LOG_FOLLOW=0; LOG_TOP=0;;
    end|G|f) LOG_FOLLOW=1;;
  esac
  [ "$LOG_TOP" -lt 0 ] && LOG_TOP=0
  return 0
}

# scrolling down past the end follows the log again
top_log_end() { if [ $((LOG_TOP + $1)) -gt "$2" ]; then LOG_FOLLOW=1; fi; }

top_key_hist() {
  case $1 in
    q|esc|h) TOP_VIEW=main;;
    up|k) HV_TOP=$((HV_TOP - 1));;
    down|j) HV_TOP=$((HV_TOP + 1));;
    pgup) HV_TOP=$((HV_TOP - UI_ROWS + 4));;
    pgdn|space) HV_TOP=$((HV_TOP + UI_ROWS - 4));;
    home|g) HV_TOP=0;;
  esac
  [ "$HV_TOP" -lt 0 ] && HV_TOP=0
  return 0
}

# ---- rendering ------------------------------------------------------------------------------

top_render() {
  TOP_DIRTY=0 TOP_LAST_RENDER=$SECONDS
  ui_frame_begin
  if [ "$UI_W" != "$TOP_LAST_W" ]; then TOP_LAST_W=$UI_W; G_NEED=1; fi
  case $TOP_VIEW in
    log) top_draw_log;;
    history) top_draw_hist;;
    *) if [ "$UI_COLS" -lt 80 ] || [ "$UI_ROWS" -lt 20 ]; then top_draw_compact; else top_draw_main; fi;;
  esac
  top_draw_modal
  ui_frame_end
}

# "3m ago" against host i's clock -> UI_RET
top_ago() {
  local t=$1 now
  if ! is_num "$t"; then UI_RET=-; return 0; fi
  now=$((TH_CLK[TOP_H] + SECONDS - TH_OKAT[TOP_H]))
  ui_dur_v $((now > t ? now - t : 0)); UI_RET="$UI_RET ago"
}

# top_state_word state release recipe: the word ls and status use (views.sh state_word), no fork
top_state_word() {
  case $1:${2:-x}:${3:-} in
    *:-:*|*::*) UI_RET="not deployed";;
    active:*:static) UI_RET=static;;
    active:*) UI_RET=running;; inactive:*) UI_RET=down;; *) UI_RET=$1;;
  esac
}

# Badge of host i -> UI_RET
top_host_badge() {
  local i=$1
  if [ -n "${TH_PID[i]}" ] && [ $((SECONDS - TH_T0[i])) -ge 2 ]; then
    if [ "${TH_ST[i]}" = err ] || [ "${TH_OKAT[i]}" -ge 0 ]; then ui_badge_v deploying reconnecting
    else ui_badge_v pending connecting; fi
  else
    case ${TH_ST[i]} in
      ok) ui_badge_v ok "${TH_NAME[i]}"; return 0;;
      err) ui_badge_v failed unreachable;;
      *) ui_badge_v pending connecting;;
    esac
  fi
}

# Host strip fragments -> TOP_FRAGS
top_host_frags() {
  local i f nm bw=5 mt mu
  TOP_FRAGS=()
  for ((i = 0; i < ${#TH_NAME[@]}; i++)); do
    if [ $i = "$TOP_H" ]; then nm="${UI_BOLD}${UI_G_PTR} ${TH_NAME[i]}${UI_NC}"; else nm="  ${TH_NAME[i]}"; fi
    top_host_badge "$i"
    if [ "${TH_ST[i]}" = ok ] && { [ -z "${TH_PID[i]}" ] || ((SECONDS - TH_T0[i] < 2)); }; then
      f="$nm  ${UI_GREEN}${UI_G_DOT}${UI_NC}"
      ui_meter_v load "${TH_LOAD[i]}" "${TH_CPUS[i]}" $bw "${TH_LOAD[i]}"; f+="  $UI_RET"
      mt=$((TH_MT[i] / 1048576)) mu=$((TH_MU[i] / 1048576))
      ui_bytes_v "${TH_MU[i]}"; local mus=$UI_RET; ui_bytes_v "${TH_MT[i]}"
      ui_meter_v mem "$mu" "$mt" $bw "$mus/$UI_RET"; f+="  $UI_RET"
      f+="  ${UI_DIM}apps${UI_NC} ${TH_NAPPS[i]}"
      [ "${TH_NBAD[i]}" -gt 0 ] && f+=" ${UI_RED}(${TH_NBAD[i]} failed)${UI_NC}"
      [ "${TH_NFIRE[i]:-0}" -gt 0 ] && { [ "${TH_NFIRE[i]}" = 1 ] && f+="  ${UI_RED}1 alert${UI_NC}" || f+="  ${UI_RED}${TH_NFIRE[i]} alerts${UI_NC}"; }
    else
      f="$nm  $UI_RET"
      if [ "${TH_OKAT[i]}" -ge 0 ]; then
        ui_dur_v $((SECONDS - TH_OKAT[i])); f+="  ${UI_DIM}data ${UI_RET} old${UI_NC}"
      fi
      if [ "${TH_ST[i]}" = err ] && [ $i = "$TOP_H" ]; then f+="  ${UI_DIM}${TH_ERR[i]}${UI_NC}"; fi
    fi
    TOP_FRAGS[i]=$f
  done
}

# Apps table rows into UI_TROWS; stale data is shown without colour.
top_apps_rows() {
  local j st mem max cpu up rs bar memtxt stale=$1 name fx x
  UI_TROWS=()
  UI_TROWS[0]="APP${TAB}STATE${TAB}RELEASE${TAB}MEMORY${TAB}CPU${TAB}UP${TAB}RST${TAB}LINK"
  for ((j = APPS_TOP; j < AP_N && j < APPS_TOP + $2; j++)); do
    top_state_word "${AP_STATE[j]}" "${AP_REL[j]}" "${AP_RECIPE[j]}"; st=$UI_RET
    ui_badge_v "$st"; st=$UI_RET
    # the checks firing for the app, red after its state (the alert rows of status)
    fx=""; for x in ${TH_FIRING[TOP_H]:-}; do [ "${x%%:*}" = "${AP_NAME[j]}" ] && fx="${fx:+$fx,}${x#*:}"; done
    [ -n "$fx" ] && st="$st ${UI_RED}$fx${UI_NC}"
    mem=${AP_MEM[j]} max=${AP_MAX[j]}
    is_num "$mem" || mem=0
    if is_num "$max" && [ "$max" -gt 0 ]; then
      ui_bar_v "$mem" "$max" 6; bar=$UI_RET
      memtxt="$bar $((mem / 1048576))/$((max / 1048576))M"
    elif [ "$mem" -gt 0 ]; then
      ui_bytes_v "$mem"; memtxt=$UI_RET
    else
      memtxt=-          # nothing measured (a static site served by Caddy, a stopped app)
    fi
    cpu=${AP_PCT[j]}
    if is_num "$cpu"; then cpu="$((cpu / 10)).$((cpu % 10))%"; else cpu=-; fi
    up=-
    if [ "${AP_STATE[j]}" = active ] && is_num "${AP_UP[j]}" && [ "${AP_UP[j]}" -gt 0 ]; then
      ui_dur_v "${AP_UP[j]}"; up=$UI_RET
    fi
    rs=${AP_RS[j]}
    is_num "$rs" && [ "$rs" -gt 0 ] && rs="${UI_YELLOW}$rs${UI_NC}"
    name=${AP_NAME[j]}
    local row="$name$TAB$st$TAB${AP_REL[j]}$TAB$memtxt$TAB$cpu$TAB$up$TAB$rs$TAB${AP_LINK[j]}"
    if [ "$stale" = 1 ]; then _ui_vis "$row"; row=$_UP; fi
    UI_TROWS[${#UI_TROWS[@]}]=$row
  done
}

# Apps table, h rows (header included), w wide -> TOP_PL lines
top_apps_lines() {
  local w=$1 h=$2 stale=0 j n
  TOP_PL=()
  [ "${TH_ST[TOP_H]}" = ok ] || stale=1
  if [ "$AP_N" = 0 ]; then
    if [ "${TH_OKAT[TOP_H]}" -lt 0 ]; then TOP_PL[0]="${UI_DIM}waiting for ${TH_NAME[TOP_H]}${UI_NC}"
    else TOP_PL[0]="no apps on ${TH_NAME[TOP_H]} yet: tando up in a project directory"; fi
    return 0
  fi
  n=$((h - 1)); [ $n -lt 1 ] && n=1
  # keep the selection in the window
  [ "$SEL" -lt "$APPS_TOP" ] && APPS_TOP=$SEL
  [ "$SEL" -ge $((APPS_TOP + n)) ] && APPS_TOP=$((SEL - n + 1))
  [ $((APPS_TOP + n)) -gt "$AP_N" ] && APPS_TOP=$((AP_N - n))
  [ "$APPS_TOP" -lt 0 ] && APPS_TOP=0
  top_apps_rows "$stale" "$n"
  ui_table_lines "l,l,l!3,l,r!2,r!4,r!5,l:10-40!6" "$w" $((SEL - APPS_TOP + 1))
  for ((j = 0; j < ${#UI_TLINES[@]}; j++)); do
    if [ $stale = 1 ] && [ $j -gt 0 ]; then TOP_PL[j]="${UI_DIM}${UI_TLINES[j]}${UI_NC}"
    else TOP_PL[j]=${UI_TLINES[j]}; fi
  done
  if [ "$AP_N" -gt "$n" ] && [ ${#TOP_PL[@]} -gt 1 ]; then
    TOP_PL[0]="${TOP_PL[0]}"
  fi
}

# Facts about the selected host appended to TOP_PL, when at least 4 rows are free.
top_host_lines() {
  local w=$1 h=$2 i=$TOP_H bw=12 j
  [ "$h" -ge 5 ] || return 0
  [ "${TH_OKAT[i]}" -ge 0 ] || return 0
  TOP_PL[${#TOP_PL[@]}]=""
  top_rule "$w" "host ${TH_NAME[i]}"; TOP_PL[${#TOP_PL[@]}]=$UI_RET
  ui_meter_v "load    " "${TH_LOAD[i]}" "${TH_CPUS[i]}" $bw "${TH_LOAD[i]} on ${TH_CPUS[i]} cpus"
  TOP_PL[${#TOP_PL[@]}]=$UI_RET
  ui_bytes_v "${TH_MU[i]}"; j=$UI_RET; ui_bytes_v "${TH_MT[i]}"
  ui_meter_v "memory  " $((TH_MU[i] / 1048576)) $((TH_MT[i] / 1048576)) $bw "$j of $UI_RET"
  TOP_PL[${#TOP_PL[@]}]=$UI_RET
  ui_bytes_v "${TH_DU[i]}"; j=$UI_RET; ui_bytes_v "${TH_DT[i]}"
  ui_meter_v "disk    " $((TH_DU[i] / 1048576)) $((TH_DT[i] / 1048576)) $bw "$j of $UI_RET"
  TOP_PL[${#TOP_PL[@]}]=$UI_RET
  [ "${TH_ST[i]}" = ok ] || for ((j = ${#TOP_PL[@]} - 4; j < ${#TOP_PL[@]}; j++)); do
    _ui_vis "${TOP_PL[j]}"; TOP_PL[j]="${UI_DIM}${_UP}${UI_NC}"; done
  return 0
}

# A dim rule with a label, w wide -> UI_RET
top_rule() {
  local w=$1 l=$2
  ui_fit $((w - 3)) "$l"; l=$UI_RET
  UI_RET="${UI_DIM}${UI_G_H} ${l} ${UI_HL:0:w-_UV-3}${UI_NC}"
}

# Detail pane of the selected app, w wide, at most h lines -> TOP_PR
top_detail_lines() {
  local w=$1 h=$2 j=$SEL st mem max t ch cw rest n x line stale=0
  TOP_PR=()
  [ -n "$SEL_APP" ] && [ "$AP_N" -gt 0 ] || return 0
  [ "${TH_ST[TOP_H]}" = ok ] || stale=1
  top_state_word "${AP_STATE[j]}" "${AP_REL[j]}" "${AP_RECIPE[j]}"; st=$UI_RET; ui_badge_v "$st"; st=$UI_RET
  local kw=9
  if [ "${AP_STATE[j]}" = active ] && is_num "${AP_UP[j]}"; then
    ui_dur_v "${AP_UP[j]}"; st+="  ${UI_DIM}up${UI_NC} $UI_RET"
  fi
  st+="  ${UI_DIM}restarts${UI_NC} ${AP_RS[j]}"
  top_kv state "$st"
  t="${AP_REL[j]}"; [ "${AP_RST[j]}" != - ] && { ui_badge_v "${AP_RST[j]}"; t+="  $UI_RET"; }
  top_kv release "$t"
  mem=${AP_MEM[j]} max=${AP_MAX[j]}; is_num "$mem" || mem=0
  ui_bytes_v "$mem"; t=$UI_RET
  if is_num "$max" && [ "$max" -gt 0 ]; then
    local bw=$((w - kw - 26)); [ $bw -gt 24 ] && bw=24; [ $bw -lt 4 ] && bw=4
    ui_bar_v "$mem" "$max" "$bw"; local b=$UI_RET; ui_bytes_v "$max"
    t="$b $t of $UI_RET  ${UI_DIM}$((mem * 100 / max))%${UI_NC}"
  fi
  top_kv memory "$t"
  x=${AP_PCT[j]}; if is_num "$x"; then t="$((x / 10)).$((x % 10))%"; else t="-"; fi
  local cpct=$t
  top_kv cpu "$t   ${UI_DIM}port${UI_NC} ${AP_PORT[j]}   ${UI_DIM}recipe${UI_NC} ${AP_RECIPE[j]}"
  top_kv link "${AP_LINK[j]}"
  if [ "${AP_BK[j]}" = daily ]; then
    if is_num "${AP_LAST[j]}"; then top_ago "${AP_LAST[j]}"; t="daily, last $UI_RET"
    else t="daily, ${UI_YELLOW}none yet${UI_NC}"; fi
    top_kv backup "$t"
  fi
  [ "${AP_DB[j]}" != - ] && [ -n "${AP_DB[j]}" ] && top_kv database "${AP_DB[j]}"
  # graphs
  rest=$((h - ${#TOP_PR[@]}))
  # room: graphs first (at least 2 rows each), then a heading and one row of each list;
  # the lists get what the graphs leave (graphs stop growing at 10 rows)
  local nrel=${#D_REL[@]} nh=${#D_HIST[@]} lists=0 want=0
  ((nrel > 0)) && { lists=$((lists + 2)); want=$((want + 1 + (nrel > 3 ? 3 : nrel))); }
  ((nh > 0)) && { lists=$((lists + 2)); want=$((want + 1 + (nh > 4 ? 4 : nh))); }
  local side=0 gh
  [ "$w" -ge 70 ] && side=1
  # graphs come first (the lists are also in the history view), then the lists
  gh=$((rest - want - 1)); [ $side = 0 ] && gh=$(((rest - want - 1) / 2))
  [ $gh -lt 2 ] && gh=2
  [ $gh -gt 10 ] && gh=10
  if [ $side = 1 ] && [ $rest -lt 3 ]; then gh=0; fi
  if [ $side = 0 ] && [ $rest -lt 5 ]; then gh=0; fi
  if [ $gh -ge 2 ]; then
    cw=$w; [ $side = 1 ] && cw=$(((w - 3) / 2))
    G_W=$cw
    top_graph_series "$cw"
    local win=$((cw * G_BK / 60))
    if ((win < 120)); then win="${win}m"
    elif ((win < 2880)); then win="$((win / 60))h"
    else win="$((win / 1440))d"; fi
    local mlab clab mmax=${max:-0} cmax
    ui_bytes_v "$mem"; mlab="memory $UI_RET"
    # axis: a little above the peak, never above the cap
    local axis=$((G_PEAKM * 5 / 4)) ml
    [ "$axis" -lt 1048576 ] && axis=1048576
    if is_num "$mmax" && [ "$mmax" -gt 0 ] && [ "$axis" -gt "$mmax" ]; then axis=$mmax; fi
    ui_bytes_v "$axis"; ml="axis $UI_RET"
    if is_num "$mmax" && [ "$mmax" -gt 0 ] && [ "$cw" -ge 50 ]; then
      ui_bytes_v "$mmax"; ml="$ml ${UI_G_MID} cap $UI_RET"
    fi
    mmax=$axis
    ui_chart_v "$G_MEM" "$cw" "$gh" "$mmax" "$mlab" "$ml" "$UI_GREEN"
    local -a cm; for ((n = 0; n < ${#UI_CHART[@]}; n++)); do cm[n]=${UI_CHART[n]}; done
    cmax=$G_PEAKC; [ "$cmax" -lt 50 ] && cmax=50
    clab="cpu $cpct"
    ui_chart_v "$G_CPU" "$cw" "$gh" "$cmax" "$clab" "peak $((G_PEAKC / 10)).$((G_PEAKC % 10))%" "$UI_CYAN"
    if [ $side = 1 ]; then
      top_rule "$w" "last $win ${UI_G_MID} t changes"; TOP_PR[${#TOP_PR[@]}]=$UI_RET
      for ((n = 0; n < gh; n++)); do TOP_PR[${#TOP_PR[@]}]="${cm[n]}${UI_NC}   ${UI_CHART[n]}"; done
    else
      top_rule "$w" "last $win"; TOP_PR[${#TOP_PR[@]}]=$UI_RET
      for ((n = 0; n < gh; n++)); do TOP_PR[${#TOP_PR[@]}]=${cm[n]}; done
      for ((n = 0; n < gh; n++)); do TOP_PR[${#TOP_PR[@]}]=${UI_CHART[n]}; done
    fi
  fi
  # releases and recent deploys
  local id s c g
  local left=$((h - ${#TOP_PR[@]})) keep=0
  ((nh > 0 && left >= 4)) && keep=2          # leave room for a deploy
  if ((nrel > 0 && left >= 2)); then
    top_rule "$w" "releases"; TOP_PR[${#TOP_PR[@]}]=$UI_RET
    for ((n = 0; n < nrel && n < 3 && ${#TOP_PR[@]} < h - keep; n++)); do
      top_split "${D_REL[n]}"; id=${TF[0]} s=${TF[1]} c=${TF[2]} g=${TF[3]}
      case $s in rolledback) ui_badge_v rolled-back;; *) ui_badge_v "$s";; esac; line="$id  $UI_RET"
      [ "$c" = 1 ] && line+="  ${UI_ACCENT}current${UI_NC}"
      [ "$g" = 1 ] && line+="  ${UI_DIM}last good${UI_NC}"
      TOP_PR[${#TOP_PR[@]}]=$line
    done
  fi
  if ((nh > 0 && h - ${#TOP_PR[@]} >= 2)); then
    top_rule "$w" "recent deploys"; TOP_PR[${#TOP_PR[@]}]=$UI_RET
    local ts kind res tot
    UI_TROWS=()
    local room=$((h - ${#TOP_PR[@]}))
    for ((n = nh - 1; n >= 0 && n >= nh - 4 && n >= nh - room; n--)); do
      top_split "${D_HIST[n]}"; ts=${TF[0]} id=${TF[1]} kind=${TF[2]} res=${TF[3]} tot=${TF[4]}
      ui_utc_v "$ts"; local ag=$UI_RET
      case $res in rolledback) ui_badge_v rolled-back;; *) ui_badge_v "$res";; esac
      UI_TROWS[${#UI_TROWS[@]}]="$ag$TAB$id$TAB$kind$TAB$UI_RET$TAB${tot}s"
    done
    ui_table_lines "l,l!2,l!1,l,r" "$w"
    for ((n = 0; n < ${#UI_TLINES[@]}; n++)); do TOP_PR[${#TOP_PR[@]}]=${UI_TLINES[n]}; done
  fi
  if [ $stale = 1 ]; then
    for ((n = 0; n < ${#TOP_PR[@]}; n++)); do _ui_vis "${TOP_PR[n]}"; TOP_PR[n]="${UI_DIM}${_UP}${UI_NC}"; done
  fi
  return 0
}
# Split a tab-separated line into the array TF (no here-document: bash 3.2 writes those to disk).
top_split() {
  local l=$1 n=0
  TF=()
  while :; do
    TF[n]=${l%%"$TAB"*}; n=$((n + 1))
    case $l in *"$TAB"*) l=${l#*"$TAB"};; *) break;; esac
  done
}
top_kv() { ui_pad "$1" 9; TOP_PR[${#TOP_PR[@]}]="${UI_DIM}${UI_RET}${UI_NC} $2"; }

# Footer key hints for the main view -> TOP_KEYS_L, TOP_KEYS_R
top_keys_main() {
  if [ "$UI_W" -ge 150 ]; then
    ui_keys_v "${UI_G_UP}${UI_G_DOWN}" app "${UI_G_LEFT}${UI_G_RIGHT}" host enter detail l log h history \
      r restart s stop/start b rollback t range
  elif [ "$UI_W" -ge 80 ]; then
    ui_keys_v "${UI_G_UP}${UI_G_DOWN}" app "${UI_G_LEFT}${UI_G_RIGHT}" host enter detail l log h history
  else
    ui_keys_v "${UI_G_UP}${UI_G_DOWN}" app enter detail
  fi
  TOP_KEYS_L=$UI_RET
  ui_keys_v '?' help q quit; TOP_KEYS_R=$UI_RET
  [ "$TOP_RO" = 1 ] && TOP_KEYS_R="${UI_YELLOW}read-only${UI_NC} ${UI_DIM}${UI_G_MID}${UI_NC} $TOP_KEYS_R"
}

top_title_right() {
  local i=$TOP_H
  UI_RET="every ${TOP_INT}s"
  if [ "${TH_OKAT[i]}" -ge 0 ]; then
    ui_dur_v $((SECONDS - TH_OKAT[i])); UI_RET="updated $UI_RET ago ${UI_G_MID} every ${TOP_INT}s"
  fi
}

top_draw_main() {
  local rows=$UI_ROWS n j hs body lw rw tl dl split=0
  top_host_frags
  ui_flow_v "$UI_IN" "${TOP_FRAGS[@]}"
  hs=${#UI_FLOW[@]}; ((hs > 3)) && hs=3
  body=$((rows - hs - 3))
  top_title_right
  ui_box_open "tando top" "$UI_RET"
  for ((j = 0; j < hs; j++)); do ui_box_line "${UI_FLOW[j]}"; done
  top_keys_main
  if [ "$TOP_DETAIL" = 1 ] && [ -n "$SEL_APP" ] && [ "$UI_W" -ge 120 ]; then
    # side by side: apps left, detail right
    lw=$(((UI_W - 7) * 45 / 100)); [ $lw -gt 64 ] && lw=64
    rw=$((UI_W - lw - 7))
    top_apps_lines "$lw" "$body"
    top_host_lines "$lw" $((body - ${#TOP_PL[@]} - 1))
    top_detail_lines "$rw" "$body"
    ui_split_edge sep "$lw" "apps ${UI_G_MID} ${TH_NAME[TOP_H]}" "$SEL_APP"
    for ((j = 0; j < body; j++)); do ui_split_line "${TOP_PL[j]:-}" "${TOP_PR[j]:-}" "$lw"; done
    ui_split_edge bottom "$lw" "${UI_NC}$TOP_KEYS_R" "" "$TOP_KEYS_L"
    return 0
  fi
  if [ "$TOP_DETAIL" = 1 ] && [ -n "$SEL_APP" ]; then
    # stacked: apps on top, then the detail
    tl=$((AP_N + 1)); local cap=$((body / 3)); [ $cap -lt 3 ] && cap=3
    [ $tl -gt $cap ] && tl=$cap
    dl=$((body - tl - 1))
    top_apps_lines "$UI_IN" "$tl"
    top_detail_lines "$UI_IN" "$dl"
    ui_box_sep "apps ${UI_G_MID} ${TH_NAME[TOP_H]}"
    for ((j = 0; j < tl; j++)); do ui_box_line "${TOP_PL[j]:-}"; done
    ui_box_sep "$SEL_APP"
    for ((j = 0; j < dl; j++)); do ui_box_line "${TOP_PR[j]:-}"; done
  else
    top_apps_lines "$UI_IN" "$body"
    ui_box_sep "apps ${UI_G_MID} ${TH_NAME[TOP_H]}"
    for ((j = 0; j < body; j++)); do ui_box_line "${TOP_PL[j]:-}"; done
  fi
  _ui_edge "$UI_G_BL" "$UI_G_BR" "${UI_NC}$TOP_KEYS_L" "$TOP_KEYS_R"
  UI_BOX=0; _ui_emit "$UI_RET" c
}

# Small terminals (under 80x20): one pane, the app list or the selected app.
top_draw_compact() {
  local rows=$UI_ROWS body j st line i=$TOP_H
  body=$((rows - 2)); [ $body -lt 1 ] && body=1
  top_host_badge "$i"
  if [ "${TH_ST[i]}" = ok ]; then UI_RET="${UI_GREEN}${UI_G_DOT}${UI_NC} ${TH_NAPPS[i]} apps"; fi
  local t="tando top ${UI_G_MID} ${TH_NAME[i]}"
  [ "$TOP_CDETAIL" = 1 ] && [ -n "$SEL_APP" ] && t="$t ${UI_G_MID} $SEL_APP"
  ui_box_open "$t" "${UI_RET}"
  if [ "$TOP_CDETAIL" = 1 ] && [ -n "$SEL_APP" ]; then
    top_detail_lines "$UI_IN" "$body"
    for ((j = 0; j < body; j++)); do ui_box_line "${TOP_PR[j]:-}"; done
  else
    top_apps_lines "$UI_IN" "$body"
    for ((j = 0; j < body; j++)); do ui_box_line "${TOP_PL[j]:-}"; done
  fi
  ui_keys_v enter detail q quit
  ui_box_close "$UI_RET"
}

top_draw_log() {
  local h=$((UI_ROWS - 2)) total=$LOG_N first j idx foot
  [ $h -lt 1 ] && h=1
  ((total > LOG_CAP)) && total=$LOG_CAP
  first=$((LOG_N - total))
  ui_scroll_v "$total" "$h" "$LOG_TOP" "$LOG_FOLLOW"; LOG_TOP=$UI_RET
  if [ "$LOG_FOLLOW" = 1 ]; then foot="${UI_GREEN}following${UI_NC}"; else foot="${UI_YELLOW}paused${UI_NC}"; fi
  ui_box_open "logs $LOG_APP" "$LOG_HOST"
  for ((j = 0; j < h; j++)); do
    idx=$((first + LOG_TOP + j))
    if [ $idx -lt "$LOG_N" ]; then ui_box_line "${LOG_L[idx % LOG_CAP]}"
    elif [ $j = 0 ] && [ "$LOG_N" = 0 ]; then
      if [ -s "$TD/log.err" ]; then
        local e last=""
        while IFS= read -r e; do [ -n "$e" ] && last=$e; done < "$TD/log.err"
        ui_box_line "${UI_RED}$last${UI_NC}"
      else ui_box_line "${UI_DIM}waiting for the journal${UI_NC}"; fi
    else ui_box_line ""; fi
  done
  ui_keys_v "${UI_G_UP}${UI_G_DOWN}" scroll pgup/pgdn page f follow q back
  local r="$foot"
  [ "$total" -gt 0 ] && r="$foot ${UI_DIM}$((LOG_TOP + 1))-$((LOG_TOP + (h < total ? h : total)))/$total${UI_NC}"
  ui_box_close "$UI_RET" "$r"
}

top_draw_hist() {
  local h=$((UI_ROWS - 3)) n=${#HV_ROWS[@]} j ts id kind res tot b u c p s v note
  [ $h -lt 1 ] && h=1
  ui_box_open "history $SEL_APP" "${TH_NAME[TOP_H]}"
  if [ "$n" = 0 ]; then
    ui_box_line "${UI_DIM}loading${UI_NC}"
    for ((j = 1; j <= h; j++)); do ui_box_line ""; done
  else
    ui_scroll_v "$n" "$h" "$HV_TOP"; HV_TOP=$UI_RET
    local hd="TIME (GMT)${TAB}RELEASE${TAB}KIND${TAB}RESULT${TAB}TOTAL${TAB}BUILD${TAB}UPLOAD${TAB}COPY${TAB}PRE"
    UI_TROWS=("$hd${TAB}SWITCH${TAB}VERIFY${TAB}NOTE")
    for ((j = n - 1 - HV_TOP; j >= 0 && j > n - 1 - HV_TOP - h; j--)); do
      top_split "${HV_ROWS[j]}"
      ts=${TF[0]} id=${TF[1]} kind=${TF[2]} res=${TF[3]} tot=${TF[4]} b=${TF[5]} u=${TF[6]}
      c=${TF[7]} p=${TF[8]} s=${TF[9]} v=${TF[10]} note=${TF[11]}
      ui_utc_v "$ts"; local ag=$UI_RET
      case $res in rolledback) ui_badge_v rolled-back;; *) ui_badge_v "$res";; esac
      UI_TROWS[${#UI_TROWS[@]}]="$ag$TAB$id$TAB$kind$TAB$UI_RET$TAB$tot$TAB$b$TAB$u$TAB$c$TAB$p$TAB$s$TAB$v$TAB$note"
    done
    ui_table_a "l,l!2,l!3,l,r,r!6,r!7,r!8,r!5,r!9,r!4,l:4-30!10"
    for ((j = ${#UI_TROWS[@]}; j <= h; j++)); do ui_box_line ""; done
  fi
  ui_keys_v "${UI_G_UP}${UI_G_DOWN}" scroll q back
  ui_box_close "$UI_RET" "${UI_DIM}seconds per phase${UI_NC}"
}

top_draw_modal() {
  local sp=${UI_G_SPIN[SECONDS % ${#UI_G_SPIN[@]}]}
  case $TOP_MODAL in
    confirm)
      local what="$TOP_ACT $TOP_ACT_APP on $TOP_ACT_HOST"
      case $TOP_ACT in
        rollback) what="roll $TOP_ACT_APP on $TOP_ACT_HOST back to the previous verified release";;
      esac
      ui_modal "$TOP_ACT $TOP_ACT_APP" "y confirm ${UI_G_MID} any other key cancels" \
        "" "Really $what?" "" "Type ${UI_BOLD}y${UI_NC} to go ahead." "";;
    busy)
      ui_dur_v $((SECONDS - TOP_ACT_T0))
      ui_modal "$TOP_ACT $TOP_ACT_APP" "esc hides this; it keeps going" "" \
        "${UI_ACCENT}${sp}${UI_NC} ${TOP_ACT} $TOP_ACT_APP on $TOP_ACT_HOST ${UI_DIM}($UI_RET)${UI_NC}" "";;
    result) ui_modal "$TOP_ACT $TOP_ACT_APP" "any key" "" "${TOP_RESULT[@]}" "";;
    ro) ui_modal "read-only" "any key" "" "tando top was started with --read-only:" \
          "restart, stop/start and rollback are disabled." "";;
    help)
      ui_modal "keys" "any key closes" \
        "${UI_G_UP} ${UI_G_DOWN}  j k     select app" \
        "${UI_G_LEFT} ${UI_G_RIGHT}  tab     switch host" \
        "enter          show or hide the detail pane" \
        "l              log of the app (q back, f follow)" \
        "h              deploy history of the app" \
        "t              graph range: 1 min, 5 min, 30 min buckets" \
        "r              restart the app         (asks first)" \
        "s              stop or start the app   (asks first)" \
        "b              roll back               (asks first)" \
        "?              this help" \
        "q              quit (Ctrl-C works too)" "" \
        "Deploys run from a project directory: tando deploy";;
  esac
}
