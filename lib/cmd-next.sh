# shellcheck shell=bash
# help: next [app] [-H host]   what you could do next on this app and server, with the command
#
# lib/cmd-next.sh: `tando next`, read-only. One ssh call (nx_probe) collects what the panel needs:
# setup state, agent info, status of every app, the app's releases and rollbacks, notifiers, CI
# keys and doctor's checks. lib/cmd-go.sh uses nx_probe for its own checks and nx_render on its
# Done screen. bash 3.2; server output is only read into whitelisted keys and rows.

# the remote half of nx_probe: arguments app (or -), doctor (1/0), then doctor's checksums
nx_script() {
  cat <<'EOF'
A=$1 DOC=$2; shift 2; [ "$A" = - ] && A=""
B=/opt/tando/bin
echo login=1
sudo -n true 2> /dev/null || exit 0
echo sudo=1
awk '/^MemTotal:/ { printf "mem=%d\n", $2 * 1024 }' /proc/meminfo
[ -x $B/tando-agent ] || exit 0
echo "version=$(cat /opt/tando/VERSION 2> /dev/null)"
echo "sum=$(cksum < $B/tando-agent | cut -d' ' -f1)"
command -v caddy > /dev/null && echo caddy=1
[ -f /etc/systemd/system/tando-watch.timer ] && echo watch=1
sudo -n $B/tando-agent info 2> /dev/null | grep -E '^(apps_domain|tls|public_port|ip|addrs|domain_tls)='
sudo -n $B/tando-agent status 2> /dev/null
if [ -n "$A" ] && sudo -n test -f /opt/tando/apps/$A/app.conf; then
  sudo -n $B/tando-agent releases $A 2> /dev/null
  sudo -n $B/tando-agent history $A 1000 2> /dev/null |
    awk -F '\t' '$5 == "rollback" { n++ } END { printf "rollbacks=%d\n", n }'
  sudo -n test -s /opt/tando/ci/$A/keys && echo ci=1
  sudo -n $B/tando-agent domain-ls $A 2> /dev/null
fi
[ -x $B/tando-watch ] && sudo -n $B/tando-watch show 1 2> /dev/null | grep '^notifier'
[ "$DOC" = 1 ] && sudo -n $B/tando-agent doctor "$@" 2> /dev/null | grep '^check'
exit 0
EOF
}

# nx_probe [app] [doctor]: the server's state into $TMPD/nx and K_*; fails when ssh does
nx_probe() {
  local a=${1:--} d=${2:-0}
  [ "$a" = - ] || valid_app "$a" || a=-
  case $d in 0|1) ;; *) d=0;; esac
  # shellcheck disable=SC2029 # expanded here on purpose: checked words, no spaces
  # lint: allow RL04 a is a valid app name or "-", d is 0/1, the sums are numbers
  nx_script | ssh "${SSHO[@]}" "$TARGET" "sh -s -- $a $d $(server_sums) $(client_version)" 2> "$TMPD/nx.err" | strip > "$TMPD/nx"
  NX_RC=${PIPESTATUS[1]}
  kv_read "$TMPD/nx" login sudo mem version sum caddy watch apps_domain tls public_port ip addrs domain_tls \
    rollbacks ci
  [ "$K_login" = 1 ]
}

# nx_ready: the server is set up by this client's version (nothing for host setup to do)
nx_ready() {
  [ "$K_version" = "$(client_version)" ] && [ "$K_sum" = "$(agent_sum)" ] && [ "$K_caddy" = 1 ] && [ "$K_watch" = 1 ]
}

# nx_app app: its row of $TMPD/nx into N_state N_rel N_link N_doms N_bk N_last N_db (fails if none)
nx_app() {
  local r a st port rel rst mem max cpu rs up link recipe bk last db x1 x2 x3 x4 doms rest
  N_state="" N_rel="" N_link="" N_doms="" N_bk="" N_last="" N_db=""
  while IFS=$TAB read -r r a st port rel rst mem max cpu rs up link recipe bk last db x1 x2 x3 x4 doms rest; do
    [ "$r" = app ] && [ "$a" = "$1" ] || continue
    N_state=$st N_rel=${rel#-} N_link=$link N_doms=${doms#-} N_bk=$bk N_last=${last#-} N_db=${db#-}
    return 0
  done < "$TMPD/nx"
  return 1
}

# nx_url app: the app's own domain (first one) or its link
nx_url() {
  nx_app "$1" || return 1
  if [ -n "$N_doms" ]; then
    case $K_domain_tls in off) printf 'http://%s\n' "${N_doms%%,*}";; *) printf 'https://%s\n' "${N_doms%%,*}";; esac
  else printf '%s\n' "$N_link"; fi
}

N_state="" N_rel="" N_link="" N_doms="" N_bk="" N_last="" N_db=""
nx_add() { NX_T[${#NX_T[@]}]=$1; NX_C[${#NX_C[@]}]=$2; }

# nx_items app: what could be done next -> NX_T (why) and NX_C (the command)
nx_items() {
  local app=$1 r a st port rel rst mem max x sum=0 n
  NX_T=() NX_C=()
  if ! nx_ready; then
    if [ -z "$K_version" ]; then nx_add "$HOST is not set up for tando yet" "tando host setup $HOST"
    elif [ "$K_version" != "$(client_version)" ]; then
      nx_add "$HOST runs tando $K_version, this laptop $(client_version): update the server" "tando host setup $HOST"
    elif [ "$K_caddy" != 1 ] || [ "$K_watch" != 1 ]; then
      nx_add "$HOST's setup did not finish (Caddy or the alert checks are missing)" "tando host setup $HOST"
    else
      nx_add "tando on this laptop changed since $HOST was set up (same version $K_version): update the server" \
        "tando host setup $HOST"
    fi
    return 0
  fi
  if [ -n "$app" ]; then
    if ! nx_app "$app"; then nx_add "$app is not on $HOST yet" "tando up"
    else
      case $N_state in failed) nx_add "$app has failed" "tando logs";; esac
      [ -z "$N_doms" ] && nx_add "$app has no domain of its own" "tando domain add example.com"
      # a domain with no certificate on file (DNS or ports 80/443 not there yet)
      [ "$K_domain_tls" = off ] || while IFS=$TAB read -r r a x x; do
        [ "$r" = domain ] || continue
        is_num "$x" || nx_add "$a has no certificate yet (DNS not pointing here, or ports 80/443 closed?)" \
          "tando domain add $a --wait"
      done < "$TMPD/nx"
      if [ -n "$N_db" ] || [ -n "${C_data:-}" ]; then
        if [ "$N_bk" = off ]; then
          nx_add "$app has data but backups are off: backup = daily in tando.conf" "tando deploy"
        elif [ -z "$N_last" ]; then
          nx_add "no backup of $app taken yet (the daily one runs at night)" "tando backup now"
        fi
      fi
      n=$(grep -c "^rel$TAB" "$TMPD/nx")
      [ "$n" -ge 2 ] && [ "${K_rollbacks:-0}" = 0 ] &&
        nx_add "rollback was never tried on $app ($n releases): it takes a second" "tando rollback"
    fi
  fi
  grep -q "^alert${TAB}[^${TAB}]*${TAB}[^${TAB}]*${TAB}firing" "$TMPD/nx" &&
    nx_add "alerts are firing" "tando alerts"
  grep -q "^notifier${TAB}" "$TMPD/nx" ||
    nx_add "no one is told when an app goes down" "tando alerts notifier add phone ntfy"
  case $K_apps_domain in *.sslip.io)
    nx_add "links use sslip.io (a free public DNS service); a wildcard of yours is sturdier" \
      "tando host setup $HOST apps_domain=apps.example.com";; esac
  while IFS=$TAB read -r r a st port rel rst mem max x; do
    [ "$r" = app ] && ui_int "$max" && sum=$((sum + max))
  done < "$TMPD/nx"
  if ui_int "$K_mem" && [ "$sum" -gt "$K_mem" ]; then
    nx_add "memory caps add up to $(ui_bytes "$sum"), $HOST has $(ui_bytes "$K_mem"): lower memory =" "tando ls"
  fi
  while IFS=$TAB read -r r st a x; do
    [ "$r" = check ] || continue
    case $st in warn|fail) nx_add "doctor: $a: ${x//<host>/$HOST}" "tando doctor";; esac
  done < "$TMPD/nx"
  [ -n "$app" ] && [ -n "$N_rel" ] && [ "$K_ci" != 1 ] &&
    nx_add "deploys of $app only run from this laptop" "tando ci setup && tando ci github"
  return 0
}

# nx_render: the items as lines of the open box
nx_render() {
  local i
  if [ ${#NX_T[@]} = 0 ]; then ui_box_line "Nothing to do. tando status shows how the app is doing."; return 0; fi
  for ((i = 0; i < ${#NX_T[@]}; i++)); do
    ui_box_wrap "${UI_YELLOW}${UI_G_DOT}${UI_NC} ${NX_T[i]}"
    ui_box_wrap "  ${UI_ACCENT}${NX_C[i]}${UI_NC}"
  done
}

cmd_next() {
  if [ -z "$(ls "$CFG"/hosts 2> /dev/null)" ] && [ -z "$HOST" ]; then
    ui_box_open "next"
    ui_box_line "No server yet. From an empty Ubuntu server to a live link:"
    ui_box_line "  ${UI_ACCENT}tando go user@address${UI_NC}"
    ui_box_close "tando cheat: the commands that matter"
    return 0
  fi
  resolve 0
  nx_probe "$APP" 1 || { ssh_explain "$TMPD/nx.err" || note "tando: cannot reach $HOST"; exit 1; }
  [ "$K_sudo" = 1 ] || { explain_sudo; exit 1; }
  nx_items "$APP"
  ui_box_open "next${APP:+ $UI_G_MID $APP}" "$HOST"
  [ -f tando.conf ] || [ -n "$APP" ] ||
    ui_box_line "${UI_DIM}(no tando.conf here: server only; cd into an app for more)${UI_NC}"
  nx_render
  ui_box_close "tando cheat: the commands that matter"
}
