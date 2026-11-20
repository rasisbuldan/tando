# shellcheck shell=bash
# help: go [user@address] [--port N] [--key FILE] [--domain D] [--dns wait|skip]
# help: go ... [--yes] [--forget] [public_port=N ...]   the setup wizard (docs/EASE.md)
#
# lib/cmd-go.sh: `tando go`, a step-by-step wizard over the real commands (host add, host setup,
# init, up, domain add, alerts, ci). The screens only ask and check (read-only); nothing changes
# until Run, which prints each command before running it and runs only what is missing, so the
# wizard is safe to run again. Answers are kept in $CFG/go/<checksum of the directory> so a new
# run resumes where the last one stopped, with the old answers as defaults (--forget drops them).
# A terminal gets full screens (arrows or numbers move, enter accepts, b back, s skip, q quit);
# no terminal or TERM=dumb gets numbered prompts; --yes takes every default. Every answer can be
# given as a flag. bash 3.2.

. "$TANDO_HOME/lib/cmd-next.sh"     # nx_probe: the server's state in one ssh call
. "$TANDO_HOME/lib/cmd-domain.sh"   # dns_lookup, dns_ok, default_www

GO_KEYS="host user addr port key setup name memory start health link domain www dns backup alerts ci at care"
GO_QS=(q_host q_addr q_user q_key q_setup q_app q_link q_domain q_www q_dns q_extras q_review)
GO_STEP=(1 1 1 1 2 3 4 4 4 4 5 6)
GO_NAMES=(Server Setup App Link Extras Review Run Done)

go_given() { case $GO_GIVEN in *" $1 "*) return 0;; esac; return 1; }
# shellcheck disable=SC2088 # a path shown to the user
go_tilde() { case $1 in "$HOME"/*) printf '~/%s' "${1#"$HOME"/}";; *) printf '%s' "$1";; esac; }

go_load() {
  local k v
  for k in $GO_KEYS; do printf -v "A_$k" '%s' ""; done
  [ -f "$GO_F" ] || return 0
  while IFS='=' read -r k v; do
    case " $GO_KEYS " in *" $k "*) printf -v "A_$k" '%s' "$v";; esac
  done < "$GO_F"
}
go_save() {
  local k v
  [ -n "$GO_YES" ] && return 0
  mkdir -p "$CFG/go" && chmod 700 "$CFG/go"
  for k in $GO_KEYS; do v="A_$k"; printf '%s=%s\n' "$k" "${!v}"; done > "$GO_F.tmp"
  mv "$GO_F.tmp" "$GO_F"
}

# ---- one screen: a question with options (or a text field), drawn and answered ----------------

go_reset() { GO_QT=$1; GO_INFO=() O_V=() O_L=() O_H=() GO_TEXT="" GO_DEF=0 GO_REC=0; }
go_info() { GO_INFO[${#GO_INFO[@]}]=$1; }
go_opt() { O_V[${#O_V[@]}]=$1; O_L[${#O_L[@]}]=$2; O_H[${#O_H[@]}]=${3:-}; }
go_text() { GO_TEXT=1 GO_TLABEL=$1 GO_TDEF=$2; }
go_pick() { local i; for ((i = 0; i < ${#O_V[@]}; i++)); do [ "${O_V[i]}" = "$1" ] && GO_DEF=$i; done; }

go_crumb() {
  local i s="" g
  for ((i = 1; i <= 8; i++)); do
    if [ $i -lt "$1" ]; then g="${UI_GREEN}${UI_G_OK} ${UI_NC}${GO_NAMES[i - 1]}"
    elif [ $i = "$1" ]; then g="${UI_ACCENT}${UI_G_DOT} ${GO_NAMES[i - 1]}${UI_NC}"
    else g="${UI_DIM}${UI_G_ODOT} ${GO_NAMES[i - 1]}${UI_NC}"; fi
    s="$s${s:+  }$g"
  done
  ui_box_line "$s"
}
go_head() { # step: box title, breadcrumb
  ui_box_open "tando go ${UI_G_MID} Step $1 of 8 ${UI_G_MID} ${GO_NAMES[$1 - 1]}" "${PWD##*/}"
  go_crumb "$1"
  ui_box_sep
}

go_draw() { # selected index
  local i l p
  [ "$GO_MODE" = tui ] && ui_frame_begin
  go_head "$GO_SN"
  ui_box_line "${UI_BOLD}$GO_QT${UI_NC}"
  for l in ${GO_INFO[@]+"${GO_INFO[@]}"}; do ui_box_wrap "$l"; done
  ui_box_line ""
  if [ -n "$GO_TEXT" ]; then
    if [ "$GO_MODE" = tui ]; then
      ui_box_line "$GO_TLABEL ${UI_DIM}[${GO_TDEF:-none}]${UI_NC}"
      ui_box_line "${UI_ACCENT}${UI_G_PTR}${UI_NC} $GO_BUF${UI_ACCENT}_${UI_NC}"
    fi
  else
    for ((i = 0; i < ${#O_V[@]}; i++)); do
      p="  " l="$((i + 1))  ${O_L[i]}"
      [ $i = "$GO_REC" ] && l="$l ${UI_DIM}(recommended)${UI_NC}"
      [ "$GO_MODE" = tui ] && [ $i = "$1" ] && p="${UI_ACCENT}${UI_G_PTR}${UI_NC} " l="${UI_BOLD}$l${UI_NC}"
      ui_box_line "$p$l"
      [ -n "${O_H[i]}" ] && ui_box_line "      ${UI_DIM}${O_H[i]}${UI_NC}"
    done
  fi
  if [ -n "$GO_ERR" ]; then
    ui_box_line ""
    p="${UI_G_ERR} "   # not through a pipe: inside a frame, lines drawn in a subshell are lost
    while IFS= read -r l; do ui_box_line "${UI_RED}$p$l${UI_NC}"; p="  "; done <<< "$GO_ERR"
  fi
  if [ "$GO_MODE" != tui ]; then ui_box_close
  elif [ -n "$GO_TEXT" ]; then ui_keys_v enter ok esc back ctrl-c quit; ui_box_close "$UI_RET"
  else ui_keys_v "${UI_G_UP}${UI_G_DOWN}/1-9" move enter ok b back s skip q quit; ui_box_close "$UI_RET"; fi
  [ "$GO_MODE" = tui ] && ui_frame_end
  return 0
}

# go_ask: GO_NAV next (answer in GO_ANS), back or quit; returns 1 unless next. --yes and the replay
# of a resumed run take the default without drawing; a check that failed stops the replay.
go_ask() {
  local sel=$GO_DEF k rc line n=${#O_V[@]}
  GO_NAV=next GO_BUF=""
  if [ -n "$GO_ERR" ] && [ "$GO_MODE" = yes ]; then die "$GO_ERR"; fi
  [ -n "$GO_ERR" ] && GO_REPLAY=0
  if [ "$GO_MODE" = yes ] || [ "$GO_I" -lt "$GO_REPLAY" ]; then
    if [ -n "$GO_TEXT" ]; then GO_ANS=$GO_TDEF; else GO_ANS=${O_V[GO_DEF]}; fi
    return 0
  fi
  if [ "$GO_MODE" = plain ]; then
    while :; do
      go_draw -1; GO_ERR=""
      if [ -n "$GO_TEXT" ]; then printf '%s [%s] (b back, q quit): ' "$GO_TLABEL" "$GO_TDEF" >&2
      else printf 'Choice [%s] (1-%s, b back, s skip, q quit): ' "$((GO_DEF + 1))" "$n" >&2; fi
      if ! IFS= read -r line; then
        [ -z "$GO_EOF" ] || die "no answer (stdin ended): run with --yes to take the defaults"
        GO_EOF=1 line=""
      fi
      case $line in
        b) GO_NAV=back; return 1;; q) GO_NAV=quit; return 1;;
        s) [ -z "$GO_TEXT" ] && { GO_ANS=${O_V[GO_REC]}; return 0; };;
      esac
      if [ -n "$GO_TEXT" ]; then GO_ANS=${line:-$GO_TDEF}; return 0; fi
      [ -z "$line" ] && line=$((GO_DEF + 1))
      if is_num "$line" && [ "$line" -ge 1 ] && [ "$line" -le "$n" ]; then GO_ANS=${O_V[line - 1]}; return 0; fi
      GO_ERR="type a number from 1 to $n"
    done
  fi
  while :; do
    go_draw "$sel"
    if [ -n "$GO_TEXT" ]; then go_tkey; else ui_key 1; fi; rc=$?
    [ $rc = 2 ] && { GO_NAV=quit; return 1; }
    [ $rc = 0 ] || continue
    k=$UI_KEY GO_ERR=""
    if [ -n "$GO_TEXT" ]; then
      case $k in
        enter) GO_ANS=${GO_BUF:-$GO_TDEF}; return 0;;
        esc) GO_NAV=back; return 1;;
        backspace) GO_BUF=${GO_BUF%?};;
        space) GO_BUF="$GO_BUF ";;
        left) [ -z "$GO_BUF" ] && { GO_NAV=back; return 1; };;
        q) [ -z "$GO_BUF" ] && { GO_NAV=quit; return 1; }; GO_BUF=${GO_BUF}q;;
        b) [ -z "$GO_BUF" ] && { GO_NAV=back; return 1; }; GO_BUF=${GO_BUF}b;;
        ignore) ;;
        ?) GO_BUF=$GO_BUF$k;;
      esac
      continue
    fi
    case $k in
      up|k) sel=$(((sel + n - 1) % n));;
      down|j|tab) sel=$(((sel + 1) % n));;
      [1-9]) [ "$k" -le "$n" ] && sel=$((k - 1));;
      enter|right|space) GO_ANS=${O_V[sel]}; return 0;;
      left|b|esc) GO_NAV=back; return 1;;
      q) GO_NAV=quit; return 1;;
      s) GO_ANS=${O_V[GO_REC]}; return 0;;
    esac
  done
}

# go_tkey -> UI_KEY: one key for a text field, read byte by byte so a paste is kept whole
# (ui_key keeps 8 keys of a burst); 1 on timeout, 2 when the input is closed
go_tkey() {
  local k="" rc   # bash 3.2: a read that times out leaves k unset (and returns 1, not >128)
  IFS= read -rsn1 -t 1 k; rc=$?
  [ $rc -gt 128 ] && return 1
  if [ $rc != 0 ] && [ -z "$k" ]; then
    [ "${GO_EOF_T:-}" = "$SECONDS" ] && GO_EOFN=$((GO_EOFN + 1)) || GO_EOFN=1 GO_EOF_T=$SECONDS
    [ "$GO_EOFN" -gt 20 ] && return 2; return 1
  fi
  case $k in
    ""|$'\r'|$'\n') UI_KEY=enter;;
    $'\177'|$'\b') UI_KEY=backspace;;
    $'\033') IFS= read -rsn1 -t 1 k || k=""; UI_KEY=esc
              [ "$k" = "[" ] && { IFS= read -rsn1 -t 1 k; [ "$k" = D ] && UI_KEY=left || UI_KEY=ignore; };;
    " ") UI_KEY=space;;
    [[:print:]]) UI_KEY=$k;;
    *) UI_KEY=ignore;;
  esac
  return 0
}

# ---- the questions: each sets GO_NAV (auto = not asked, the loop goes on in its direction) ----

q_host() {
  local f n=0
  [ -n "$A_host" ] && [ ! -f "$CFG/hosts/$A_host" ] && A_host=""
  if go_given host || go_given addr; then GO_NAV=auto; return; fi
  for f in "$CFG"/hosts/*; do [ -f "$f" ] && [ "$(host_get "${f##*/}" kind)" != deploy ] && n=$((n + 1)); done
  [ $n -gt 0 ] || { A_host=""; GO_NAV=auto; return; }
  go_reset "Which server?"
  go_info "Servers you registered before, or a new one."
  for f in "$CFG"/hosts/*; do
    [ -f "$f" ] && [ "$(host_get "${f##*/}" kind)" != deploy ] || continue
    go_opt "${f##*/}" "${f##*/}  $(host_get "${f##*/}" target)" "registered with tando host add"
  done
  go_opt + "A new server" "an Ubuntu 24.04+ server you can ssh into"
  # the server of the last answer, else the most recently registered one (not "a new server")
  f=$(ls -t "$CFG"/hosts 2> /dev/null | while IFS= read -r f; do
    [ "$(host_get "$f" kind)" != deploy ] && { echo "$f"; break; }; done)
  go_pick "${A_host:-$f}"; GO_REC=$GO_DEF
  go_ask || return
  if [ "$GO_ANS" = + ]; then A_host=""; else A_host=$GO_ANS; fi
}

go_scan() { # the address answers on its ssh port: its host keys into $TMPD/kh
  scan_keys "$A_addr" "${A_port:-22}" > "$TMPD/kh"   # lib/common.sh: one connection, usually
  [ -s "$TMPD/kh" ]
}

q_addr() {
  local a
  [ -n "$A_host" ] && { GO_NAV=auto; return; }
  while :; do
    go_reset "Your server's address"
    go_info "The IP address or name of a server with Ubuntu 24.04 or newer and ssh."
    go_info "tando installs what it needs there. You can paste user@address."
    go_text "Address" "${A_user:+$A_user@}$A_addr"
    if go_given addr && [ -z "$GO_ERR" ]; then GO_ANS=$GO_TDEF; else go_ask || return; fi
    a=$GO_ANS
    case $a in *@*) A_user=${a%@*} a=${a#*@}; GO_GIVEN="$GO_GIVEN user ";; esac
    case $a in
      "") GO_ERR="type the server's address, like 203.0.113.7 (q quits)"; continue;;
      *[!A-Za-z0-9_.-]*) GO_ERR="not an address: $a"; continue;;
    esac
    A_addr=$a
    [ -n "$A_port" ] || A_port=$(ssh -G "$a" 2> /dev/null | awk '$1 == "port" { print $2; exit }')
    go_scan && return
    GO_ERR="no ssh answer from $a on port ${A_port:-22} within 5 s.
Is the address right, and is the port open?"
    [ "$GO_MODE" = yes ] && die "$GO_ERR"
  done
}

q_user() {
  local u
  { [ -n "$A_host" ] || go_given user; } && { GO_NAV=auto; return; }
  u=$(ssh -G "$A_addr" 2> /dev/null | awk '$1 == "user" { print $2; exit }')
  [ "$u" = "$(id -un)" ] && u=root   # not from ~/.ssh/config: a fresh server's login is root
  go_reset "The login on $A_addr"
  go_info "It needs passwordless sudo (root has it). Detected from ~/.ssh/config when set there."
  go_text "SSH user" "${A_user:-$u}"
  go_ask || return
  case $GO_ANS in *[!A-Za-z0-9_.-]*) GO_ERR="not a user name: $GO_ANS"; q_user; return;; esac
  A_user=$GO_ANS
}

# go_target: TARGET and SSHO for the answers: a registered host, or the new address checked
# against the host keys just scanned (nothing is written)
go_target() {
  if [ -n "$A_host" ]; then host_use "$A_host"; return; fi
  TARGET=$A_user@$A_addr
  SSHO=(-p "${A_port:-22}" -o BatchMode=yes -o ConnectTimeout=5)
  [ -n "$A_key" ] && SSHO+=(-i "$A_key" -o IdentitiesOnly=yes)
  if [ -n "$GO_INSECURE" ]; then
    SSHO+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
  else SSHO+=(-o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$TMPD/kh"); fi
}

# go_probe: the server's state (nx_probe), once per screen that needs it fresh; sets GO_ERR
go_probe() {
  local e
  go_target
  if nx_probe "${1:-}" 0 && [ "$K_sudo" = 1 ]; then return 0; fi
  # a failure that says nothing (a dropped connection): once more before asking the user
  if [ "${K_login:-}" != 1 ] && [ ! -s "$TMPD/nx.err" ]; then
    sleep 1
    if nx_probe "${1:-}" 0 && [ "$K_sudo" = 1 ]; then return 0; fi
  fi
  e=$(strip < "$TMPD/nx.err" | grep . | tail -1)
  if [ -z "$e" ] && [ "${NX_RC:-0}" = 255 ]; then
    e="the server closed the connection at once (sshd may refuse this address for a while after many attempts: try again in a minute)"
  elif [ -z "$e" ] && [ "${NX_RC:-0}" != 0 ]; then e="no answer (exit status $NX_RC)"; fi
  if [ "$K_login" = 1 ]; then GO_ERR="$TARGET has no passwordless sudo. On the server, run:
echo '${TARGET%@*} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/tando"
  else
    case $e in
      *"Permission denied"*) GO_ERR="$A_addr refused the login $TARGET. Another key below, another user
(b goes back), or add your public key to ~${TARGET%@*}/.ssh/authorized_keys there.";;
      *) GO_ERR="cannot log in to $TARGET: ${e:-no answer}";;
    esac
  fi
  return 1
}

q_key() {
  local f
  if [ -n "$A_host" ] || go_given key; then
    go_probe && { GO_NAV=auto; return; }
    [ -n "$A_host" ] && die "$GO_ERR"
  fi
  while :; do
    go_reset "Which ssh key logs in to $A_user@$A_addr?"
    go_info "Host key: $(ssh-keygen -lf "$TMPD/kh" 2> /dev/null | awk '{ print $2 }' | head -1)"
    go_opt "" "ssh's own choice" "your ~/.ssh/config, ssh-agent and ~/.ssh/id_* (what plain ssh uses)"
    case " ${O_V[*]} " in *" $A_key "*) ;; *)
      [ -n "$A_key" ] && go_opt "$A_key" "$(go_tilde "$A_key")" "given with --key";; esac
    for f in "$HOME"/.ssh/id_*; do
      case $f in *.pub|*'*'*) continue;; esac
      [ -f "$f.pub" ] && go_opt "$f" "$(go_tilde "$f")" "$(cut -d' ' -f1,3 < "$f.pub" | cut -c1-60)"
    done
    go_pick "$A_key"
    go_ask || return
    A_key=$GO_ANS
    go_probe && return
    [ "$GO_MODE" = yes ] && die "$GO_ERR"
  done
}

q_setup() {
  local m
  go_probe || die "$GO_ERR"
  GO_READY=""; nx_ready && GO_READY=1
  go_given setup && { GO_NAV=auto; return; }
  m=$(ui_bytes "${K_mem:-0}")
  go_reset "Set up the server"
  if [ -n "$GO_READY" ]; then
    go_info "${A_host:-$A_addr} is set up by this tando ($(client_version)): nothing to install."
    go_opt skip "Leave it as it is" "tando go only deploys"
    go_opt all "Run the setup again" "checks every piece; changes only what differs"
  else
    go_info "Installs Caddy (HTTPS), rsync, curl and nftables from apt, the tando programs,"
    go_info "a firewall unit and alert checks every minute. Takes 1-2 minutes. RAM: $m."
    go_opt all "Install everything" "and a swap file if the server has less than 2 GB of RAM"
    go_opt noswap "Install everything but the swap file" "for servers that must not swap"
    go_opt skip "Skip: I will run tando host setup myself" "deploying fails until it has run"
  fi
  [ -n "$GO_READY" ] || [ "$A_setup" != skip ] || A_setup=""   # an earlier answer, not for now
  go_pick "${A_setup:-${O_V[0]}}"; [ -n "$GO_READY" ] && GO_DEF=0
  go_ask || return
  A_setup=$GO_ANS
}

# go_detect: what tando init would write (it runs on links to this directory's files, so nothing
# here changes), or the existing tando.conf -> D_* and the A_* defaults
go_detect() {
  local d f
  [ -n "${GO_DETECTED:-}" ] && return 0
  GO_DETECTED=1 D_conf="" D_none="" D_next=""
  if [ -f tando.conf ]; then
    conf_load || exit 1
    D_conf=1 D_name=$C_app D_memory=${C_memory:-256M} D_start=$C_start D_health=${C_health:-/}
    D_recipe=$C_recipe
  else
    d=$TMPD/detect/$(basename "$PWD")
    mkdir -p "$d"
    for f in "$PWD"/* "$PWD"/.[!.]*; do [ -e "$f" ] && [ "${f##*/}" != .tando ] && ln -s "$f" "$d/"; done
    (YES="" HOST=""; cd "$d" && cmd_init) < /dev/null > /dev/null 2> "$TMPD/init.err"
    if ! conf_load "$d/tando.conf" 2> /dev/null; then
      D_none=$(grep . "$TMPD/init.err" | head -1 | sed 's/^tando: //'); return 0
    fi
    D_name=$C_app D_memory=$C_memory D_start=$C_start D_health=$C_health D_recipe=$C_recipe
    [ "$C_recipe" = next ] && ! grep -qs "output:[[:space:]]*['\"]standalone" next.config.* && D_next=1
  fi
  C_data_go=$C_data C_db_go=$C_database
  [ -n "$A_name" ] || A_name=$D_name
  [ -n "$A_memory" ] || A_memory=$D_memory
  [ -n "$A_start" ] || A_start=$D_start
  [ -n "$A_health" ] || A_health=$D_health
  [ -n "$D_conf" ] && A_name=$D_name A_memory=$D_memory A_start=$D_start A_health=$D_health
  return 0
}

q_app() {
  local f
  go_detect
  if [ -n "$D_none" ]; then
    go_reset "No app in this directory"
    go_info "$D_none."
    go_info "tando go can set up the server now; then cd into your app and run tando go again."
    go_opt none "Only set up the server" ""
    go_ask; return
  fi
  if [ -n "$D_conf" ]; then
    go_reset "Your app (from tando.conf)"
    go_info "$A_name: ${D_recipe}${A_start:+, $A_start}, health $A_health, memory $A_memory"
    go_opt ok "Use tando.conf" "edit tando.conf to change it"
    go_ask; return
  fi
  while :; do
    go_reset "Your app"
    go_info "Detected: a $D_recipe app in ${PWD##*/}/$([ -n "$D_next" ] && printf ' (adds output: standalone)')"
    go_opt ok "Continue with these settings" "tando init writes them to tando.conf"
    go_opt name "Name          $A_name" "the app's name on the server and in its link"
    [ "$D_recipe" = static ] ||
      go_opt memory "Memory cap    $A_memory" "the app is restarted when it uses more"
    [ "$D_recipe" = static ] || go_opt start "Start command $A_start" "it must listen on \$PORT"
    go_opt health "Health check  $A_health" "must answer before a new release goes live"
    go_given name && GO_REPLAY=$((GO_I + 1))
    go_ask || return
    f=$GO_ANS
    case $f in
      ok) return;;
      memory)
        go_reset "Memory cap of $A_name"
        go_opt 128M 128M "small Node or Python apps"; go_opt 256M 256M "most apps (tando's default)"
        go_opt 512M 512M "Next.js, apps with images"; go_opt 1G 1G "big apps"
        go_pick 256M; GO_REC=$GO_DEF; go_pick "$A_memory"
        go_ask && A_memory=$GO_ANS;;
      *)
        while :; do
          go_reset "Your app"
          case $f in name) go_text "Name (a-z, 0-9, -)" "$A_name";; start) go_text "Start command" "$A_start";;
            health) go_text "Health check path" "$A_health";; esac
          go_ask || break
          case $f in
            name) valid_app "$GO_ANS" && { A_name=$GO_ANS; break; }
                  GO_ERR="2-24 of a-z, 0-9 and -, starting with a letter";;
            start) [ -n "$GO_ANS" ] && { A_start=$GO_ANS; break; }; GO_ERR="the app needs a start command";;
            health) case $GO_ANS in /*) A_health=$GO_ANS; break;; esac; GO_ERR="a path, starting with /";;
          esac
        done;;
    esac
    GO_NAV=next
  done
}

# go_set_differs: a setting given on the command line (public_port=, apps_domain=, tls=,
# domain_tls=) that the set-up server does not have yet: host setup runs again to apply it
go_set_differs() {
  local kv v
  for kv in ${GO_SET:-}; do
    v=${kv#*=}
    case $kv in
      public_port=*) [ "$v" = "${K_public_port:-}" ] || return 0;;
      apps_domain=*) [ "$v" = "${K_apps_domain:-}" ] || return 0;;
      tls=*) [ "$v" = "${K_tls:-}" ] || return 0;;
      domain_tls=*) [ "$v" = "${K_domain_tls:-}" ] || return 0;;
    esac
  done
  return 1
}

go_free_url() { # the app's link before any domain
  local s=" ${GO_SET:-} " dom="" scheme=https port=""
  if [ -n "$GO_READY" ]; then
    dom=$K_apps_domain; [ "$K_tls" = off ] && scheme=http; port=$K_public_port
  else
    case $s in *" apps_domain="*) dom=${s#* apps_domain=}; dom=${dom%% *};; esac
    case $s in *" public_port="*) port=${s#* public_port=}; port=${port%% *};; esac
    if [ -z "$dom" ]; then
      if dom=$(public_ip "$A_addr"); then dom="$(printf '%s' "$dom" | tr . -).sslip.io"
      else dom=localhost scheme=http; fi
    fi
  fi
  [ "$scheme" = http ] || port=""
  printf '%s://%s.%s%s' "$scheme" "$A_name" "$dom" "${port:+:$port}"
}

q_link() {
  [ -n "$D_none" ] && { GO_NAV=auto; return; }
  go_given link && { GO_NAV=auto; return; }
  go_reset "Where should $A_name answer?"
  go_opt free "$(go_free_url)" "a free link that works now; you can add a domain any time"
  go_opt domain "My own domain" "you create one DNS record; HTTPS comes from Let's Encrypt"
  go_pick "${A_link:-free}"
  go_ask || return
  A_link=$GO_ANS
}

q_domain() {
  local d
  { [ -n "$D_none" ] || [ "$A_link" != domain ]; } && { GO_NAV=auto; return; }
  while :; do
    go_reset "Your domain"
    go_info "The name visitors type, like shop.example.com or example.com."
    go_text "Domain" "$A_domain"
    if go_given domain && [ -z "$GO_ERR" ]; then GO_ANS=$GO_TDEF; else go_ask || return; fi
    d=$(printf '%s' "$GO_ANS" | tr '[:upper:]' '[:lower:]'); d=${d%.}
    case $d in *.*) case $d in *[!a-z0-9.-]*|.*|*..*) ;; *) A_domain=$d; return;; esac;; esac
    GO_ERR="not a domain name: ${d:-(empty)}"
    go_given domain && die "$GO_ERR"
  done
}

q_www() {
  local d=$A_domain t
  { [ -n "$D_none" ] || [ "$A_link" != domain ]; } && { GO_NAV=auto; return; }
  case $d in www.*) t=${d#www.};; *) t=www.$d;; esac
  go_given www && { GO_NAV=auto; return; }
  go_reset "And $t?"
  go_opt redirect "$t redirects to $d" "visitors who type either name get there"
  go_opt off "Only $d" "nothing is set up for $t"
  go_opt serve "Serve both names" "the same site on both, without a redirect"
  go_pick "$(default_www "$d")"; GO_REC=$GO_DEF; go_pick "${A_www:-${O_V[GO_REC]}}"
  go_ask || return
  A_www=$GO_ANS
}

go_dns() { # DNS of the domain (and its twin) points at the server -> 0; else the records in $TMPD/dns
  local t=${TARGET#*@} tip
  case $t in *[!0-9.]*) tip=$(dns_lookup "$t" | head -1);; *) tip=$t;; esac
  SRV_IP=$(public_ip "$tip") || SRV_IP=${K_ip:-$tip}
  SRV_ADDRS=" $tip ${K_addrs:-} $SRV_IP "
  : > "$TMPD/dns"
  dns_ok "$A_domain"
  [ "$A_www" = off ] || case $A_domain in www.*) dns_ok "${A_domain#www.}";; *) dns_ok "www.$A_domain";; esac
  [ ! -s "$TMPD/dns" ]
}

q_dns() {
  local l
  { [ -n "$D_none" ] || [ "$A_link" != domain ]; } && { GO_NAV=auto; return; }
  while :; do
    go_dns && { A_dns=ok; GO_NAV=auto; return; }
    go_given dns && { GO_NAV=auto; return; }
    go_reset "$A_domain does not point at this server yet"
    go_info "At your DNS provider, create:"
    while IFS= read -r l; do go_info "${UI_ACCENT}$l${UI_NC}"; done < "$TMPD/dns"
    go_opt wait "Wait for DNS during the run" "checks every 10 s for up to 30 min; Ctrl-C skips the domain"
    go_opt check "Check again now" "after you created the records"
    go_opt skip "Use the free link for now" "later: tando domain add $A_domain"
    go_pick "${A_dns:-wait}"; [ "$A_dns" = check ] && go_pick wait
    go_ask || return
    A_dns=$GO_ANS
    [ "$GO_ANS" = check ] || return
    [ "$GO_MODE" = tui ] || GO_REPLAY=0
  done
}

q_extras() {
  local bk=""
  [ -n "$D_none" ] && { GO_NAV=auto; return; }
  [ -n "$C_data_go$C_db_go" ] && bk=1
  [ "$A_alerts" = ntfy ] && [ -z "${GO_NTFY:-}" ] && A_alerts=off   # the topic URL is never saved
  while :; do
    go_reset "Extras"
    go_info "All optional; each can be added later with the command shown on the Done screen."
    go_opt ok "Continue" ""
    [ -n "$bk" ] && go_opt backup "Backups       ${A_backup:-daily}" "the app's data and database, on the server"
    go_opt alerts "Alerts        ${A_alerts:-off}" "a push message when the app goes down or the disk fills"
    go_opt ci "CI deploys    ${A_ci:-off}" "a deploy key and a GitHub Actions workflow"
    go_opt care "Server care   ${A_care:-default}" "security updates install themselves (tando host care)"
    go_ask || return
    case $GO_ANS in
      ok) return;;
      backup) go_reset "Backups"; go_opt daily "Daily" "every night, and before every deploy"
              go_opt off "Off" "nothing is backed up"; go_pick "${A_backup:-daily}"
              go_ask && A_backup=$GO_ANS;;
      alerts) go_reset "Alerts"; go_opt off "Off for now" "tando alerts notifier add ... any time"
              go_opt ntfy "Push to your phone with ntfy" "free app; you pick a topic name"
              go_pick "${A_alerts:-off}"
              if go_ask && A_alerts=$GO_ANS && [ "$A_alerts" = ntfy ]; then
                go_reset "Alerts by ntfy"; go_info "Install the ntfy app, subscribe to a hard-to-guess topic."
                go_info "The URL is a secret: it is not saved by tando go."
                go_text "Topic URL" "https://ntfy.sh/tando-$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
                if go_ask; then GO_NTFY=$GO_ANS; else A_alerts=off; fi
              fi;;
      ci) go_reset "CI deploys"; go_opt off "Off" "deploy from this laptop"
          go_opt github "GitHub Actions" "tando ci setup prints a key for the repo's secrets"
          go_pick "${A_ci:-off}"; go_ask && A_ci=$GO_ANS;;
      care) go_reset "Server care"
            go_info "tando can look after the server: Ubuntu's unattended-upgrades installs"
            go_info "security updates every day (no service restarts). Reboots stay yours:"
            go_info "tando host reboot, or tando host care on --reboot for a nightly window."
            go_opt default "As host setup decides" "on for a server tando set up; hints only beside other sites"
            go_opt on "Security updates on" "tando host care on --updates"
            go_opt off "Off: I update the server myself" "tando host status still shows what is pending"
            go_pick "${A_care:-default}"; go_ask && A_care=$GO_ANS;;
    esac
    GO_NAV=next
  done
}

# ---- the plan: the real commands for what is missing ----------------------------------------

go_add() { P_CMD[${#P_CMD[@]}]=$1; }
go_newname() {
  local n=prod i=2
  while [ -f "$CFG/hosts/$n" ]; do n=prod$i; i=$((i + 1)); done
  printf '%s' "$n"
}

go_plan() {
  local h=$A_host w="" k a c
  P_CMD=()
  if [ -z "$h" ]; then
    h=$(go_newname)
    a="tando host add $h $A_user@$A_addr"
    [ "${A_port:-22}" = 22 ] || a="$a --port $A_port"
    [ -n "$A_key" ] && a="$a --key $A_key"
    [ -n "$GO_INSECURE" ] && a="$a --insecure-test"
    go_add "$a --yes"
  fi
  GO_HNAME=$h
  if [ "$A_setup" = all ] || { [ -z "$GO_READY" ] && [ "$A_setup" != skip ]; } ||
     { [ -n "$GO_READY" ] && go_set_differs; }; then
    a="tando host setup $h"; [ "$A_setup" = noswap ] && a="$a swap=no"
    go_add "$a${GO_SET:-}"
  fi
  [ -n "$D_none" ] && return 0
  if [ -z "$D_conf" ]; then
    go_add "tando init -H $h${D_next:+ --yes}"
    for k in name memory start health; do
      a="A_$k" w="D_$k" c=$k
      [ $k = name ] && c=app
      [ "${!a}" = "${!w}" ] || go_add "@conf $c ${!a}"
    done
  fi
  [ -n "$C_data_go$C_db_go" ] && [ "$A_backup" = off ] && go_add "@conf backup off"
  if ! nx_app "$A_name" || [ -z "$N_rel" ]; then
    if [ -n "$D_conf" ] && [ -z "$C_host" ]; then go_add "tando up -H $h"; else go_add "tando up"; fi
  elif [ "$A_backup" = off ] && [ "$N_bk" != off ] && [ -n "$C_data_go$C_db_go" ]; then go_add "tando deploy"
  fi
  if [ "$A_link" = domain ] && [ "$A_dns" != skip ]; then
    case ",$N_doms," in *",$A_domain,"*) ;; *)
      a="tando domain add $A_domain"
      [ "$A_www" = "$(default_www "$A_domain")" ] || a="$a --www $A_www"
      [ "$A_dns" = ok ] || a="$a --wait"
      go_add "$a";;
    esac
  fi
  [ "$A_alerts" = ntfy ] && ! grep -q "^notifier${TAB}phone${TAB}" "$TMPD/nx" &&
    go_add "tando alerts notifier add phone ntfy"
  [ "$A_ci" = github ] && [ "$K_ci" != 1 ] && { go_add "tando ci setup"; go_add "tando ci github"; }
  case ${A_care:-default} in
    on) go_add "tando host care on $h --updates";;
    off) go_add "tando host care off $h --updates";;
  esac
  return 0
}

go_show() { # a command as the user would type it (@conf: the line written to tando.conf)
  local a=$1 o=""
  case $a in "@conf "*) a=${a#@conf }; printf 'tando.conf: %s = %s' "${a%% *}" "${a#* }"; return;; esac
  while case $a in *" $HOME/"*) true;; *) false;; esac; do
    o="$o${a%%" $HOME/"*} ~/"; a=${a#*" $HOME/"}
  done
  printf '%s' "$o$a"
}

q_review() {
  local c l
  go_probe "$A_name" || die "$GO_ERR"
  go_plan
  [ ${#P_CMD[@]} = 0 ] && [ "$A_at" = "done" ] && { GO_ANS=run; return; }
  go_reset "Review"
  go_info "server   ${A_host:-$GO_HNAME}  $TARGET"
  if [ -n "$D_none" ]; then go_info "app      none here (server only)"
  else
    go_info "app      $A_name ($D_recipe), memory $A_memory, health $A_health"
    l=$(go_free_url); [ "$A_link" = domain ] && l="$A_domain (DNS: ${A_dns:-?}), else $l"
    go_info "link     $l"
    l="alerts ${A_alerts:-off}, CI ${A_ci:-off}"
    [ -n "$C_data_go$C_db_go" ] && l="backups ${A_backup:-daily}, $l"
    go_info "extras   $l"
  fi
  go_info ""
  if [ ${#P_CMD[@]} = 0 ]; then go_info "Everything is done already: nothing to run."
  else
    go_info "These run, in this order:"
    for c in "${P_CMD[@]}"; do go_info "  ${UI_ACCENT}$(go_show "$c")${UI_NC}"; done
  fi
  go_opt run "Run now" "nothing has changed anywhere until now"
  go_opt back "Go back and change something" ""
  go_ask || return
  [ "$GO_ANS" = back ] && { GO_NAV=back; return; }
  return 0
}

# ---- run and done ------------------------------------------------------------------------------

go_print_cmd() { # n total command: "[n/t] $ command", wrapped at the box width
  local w line plain
  line="${UI_DIM}[$1/$2]${UI_NC} ${UI_BOLD}\$" plain="[$1/$2] \$"
  case $3 in "@conf "*) line="${UI_DIM}[$1/$2]${UI_NC}${UI_BOLD}" plain="[$1/$2]";; esac
  set -f
  for w in $(go_show "$3"); do
    if [ $((${#plain} + ${#w} + 3)) -gt "$UI_W" ]; then
      printf '%s \\%s\n' "$line" "$UI_NC"; line="${UI_BOLD}     " plain="     "
    fi
    line="$line $w" plain="$plain $w"
  done
  set +f
  printf '%s%s\n' "$line" "$UI_NC"
}

go_exec() { # one plan entry
  local a
  # shellcheck disable=SC2086 # the plan's words: names, paths without spaces and flags
  case $1 in
    "@conf "*) a=${1#@conf }; go_conf "${a%% *}" "${a#* }";;
    "tando alerts notifier add phone ntfy")   # the topic URL on stdin, then no token
      printf '%s\n\n' "$GO_NTFY" | "$TANDO_HOME/bin/tando" alerts notifier add phone ntfy;;
    tando*) a=${1#tando }; set -f; "$TANDO_HOME/bin/tando" $a; a=$?; set +f; return $a;;
  esac
}

go_conf() { # key value: set it in tando.conf (replacing an uncommented line, else appended)
  awk -v k="$1" -v v="$2" '{ x = $0; sub(/[ \t]*=.*/, "", x); gsub(/[ \t]/, "", x) }
    x == k && $0 !~ /^[ \t]*#/ && !d { print k " = " v; d = 1; next } { print }
    END { if (!d) print k " = " v }' tando.conf > tando.conf.go && mv tando.conf.go tando.conf
}

go_run() {
  local i n=${#P_CMD[@]} rc
  GO_T0=$(clock) GO_SKIPPED=""
  ui_box_open "tando go ${UI_G_MID} Step 7 of 8 ${UI_G_MID} Run" "${PWD##*/}"
  go_crumb 7
  ui_box_sep
  for ((i = 0; i < n; i++)); do
    ui_box_wrap "${UI_DIM}${UI_G_PEND} $((i + 1))/$n${UI_NC}  $(go_show "${P_CMD[i]}")"
  done
  ui_box_close "each command is shown before it runs"
  for ((i = 0; i < n; i++)); do
    echo
    go_print_cmd $((i + 1)) "$n" "${P_CMD[i]}"
    case ${P_CMD[i]} in *" --wait")
      note "${UI_DIM}waiting for DNS; Ctrl-C skips the domain (later: tando domain add $A_domain)${UI_NC}"
      GO_INT=""; trap 'GO_INT=1' INT;; esac
    go_exec "${P_CMD[i]}"; rc=$?
    trap 'exit 130' INT
    if [ $rc != 0 ] && [ -n "${GO_INT:-}" ]; then GO_SKIPPED=1; GO_INT=""; continue; fi
    case ${P_CMD[i]} in "tando host add "*) [ $rc = 0 ] && { A_host=$GO_HNAME; go_save; };; esac
    if [ $rc != 0 ]; then
      [ $rc = 130 ] && exit 130
      A_at=q_review; go_save
      echo
      ui_box_open "tando go ${UI_G_MID} stopped" "${PWD##*/}"
      ui_box_wrap "${UI_RED}${UI_G_ERR}${UI_NC} $(go_show "${P_CMD[i]}") failed: what it printed above says why."
      ui_box_line "Fix that, then run tando go again: it continues with what is still missing."
      ui_box_close "tando doctor checks the server"
      exit 1
    fi
  done
  A_at="done"; go_save
}

go_done() {
  local url=""
  host_use "${A_host:-$GO_HNAME}"
  [ -n "$D_none" ] && A_name=""
  nx_probe "$A_name" 0 > /dev/null 2>&1
  echo
  ui_box_open "tando go ${UI_G_MID} Step 8 of 8 ${UI_G_MID} Done" "$HOST"
  go_crumb 9
  ui_box_sep
  if [ -n "$D_none" ]; then
    ui_box_line "${UI_GREEN}${UI_G_OK}${UI_NC} $HOST is ready. In your app's directory: ${UI_ACCENT}tando go${UI_NC}"
  elif nx_app "$A_name" && [ -n "$N_rel" ] && url=$(nx_url "$A_name"); then
    ui_box_wrap "${UI_GREEN}${UI_G_OK}${UI_NC} ${UI_BOLD}$A_name is live${UI_NC}  $url"
    [ -n "$N_doms" ] && ui_kv "also" "$N_link"
  else
    ui_box_line "${UI_YELLOW}$A_name is not live yet${UI_NC}: tando status"
  fi
  [ -n "${GO_T0:-}" ] && ui_kv took "$(ui_dur "$(since "$GO_T0")")"
  { [ -n "$GO_SKIPPED" ] || { [ "$A_link" = domain ] && [ "$A_dns" = skip ]; }; } &&
    ui_kv domain "skipped; when DNS is ready: tando domain add $A_domain"
  ui_box_sep "next"
  [ -f tando.conf ] && conf_load 2> /dev/null
  nx_items "$A_name"
  [ ${#NX_T[@]} -gt 4 ] && NX_T=("${NX_T[@]:0:4}") NX_C=("${NX_C[@]:0:4}")
  nx_render
  ui_box_close "tando next: every suggestion ${UI_G_MID} tando cheat: the commands that matter"
}

go_quit() {
  go_leave
  note "tando go: quit at ${GO_NAMES[GO_SN - 1]}; nothing was changed on the server or here."
  note "  tando go continues there (your answers are kept; tando go --forget drops them)."
  exit 0
}

go_leave() { # the normal screen and stderr back (and what was written to it meanwhile)
  [ "${UI_ALT:-0}" = 1 ] || return 0
  ui_frame_cleanup
  exec 2>&3
  [ -s "$TMPD/go.err" ] && cat "$TMPD/go.err" >&2
  : > "$TMPD/go.err"
}

# ---- flags and the main loop -----------------------------------------------------------------

go_flags() {
  local need
  while [ $# -gt 0 ]; do
    need=""
    case $1 in
      --domain|--www|--name|--memory|--port|--key|--dns|-a|-H|-n|--watch)
        need=1; [ $# -ge 2 ] || usage_err "$1 needs a value";;
    esac
    case $1 in
      --domain) A_domain=$2 A_link=domain; GO_GIVEN="$GO_GIVEN domain link ";;
      --www) case $2 in redirect|serve|off) ;; *) usage_err "--www is redirect, serve or off";; esac
             A_www=$2; GO_GIVEN="$GO_GIVEN www ";;
      --name) valid_app "$2" || usage_err "bad app name: $2"; A_name=$2; GO_GIVEN="$GO_GIVEN name ";;
      --memory) A_memory=$2;;
      --port) is_num "$2" || usage_err "--port needs a number"; A_port=$2;;
      --key) A_key=$2; case $A_key in /*) ;; *) A_key=$PWD/$A_key;; esac
             [ -f "$A_key" ] || die "no such key: $2"; GO_GIVEN="$GO_GIVEN key ";;
      --dns) case $2 in wait|skip) ;; *) usage_err "--dns is wait or skip";; esac
             A_dns=$2; GO_GIVEN="$GO_GIVEN dns ";;
      --free-link) A_link=free; GO_GIVEN="$GO_GIVEN link ";;
      --no-swap) A_setup=noswap; GO_GIVEN="$GO_GIVEN setup ";;
      --ci) A_ci=github;;
      --insecure-test) GO_INSECURE=1;;
      --yes) GO_MODE=yes GO_YES=1;;
      --plain) [ "$GO_MODE" = yes ] || GO_MODE=plain;;
      --forget|--force|--json) ;;
      -a|-H|-n|--watch) ;;   # read by bin/tando
      apps_domain=*|tls=*|public_port=*|domain_tls=*|swap=*|ufw=*)
        case $1 in *[!A-Za-z0-9_.=-]*) usage_err "bad setting: $1";; esac; GO_SET="${GO_SET:-} $1";;
      -*) usage_err "tando go does not take $1.$(printf '%s\n' --domain --www --name --memory --port --key --dns \
            --free-link --no-swap --ci --yes --plain --forget | nearest "$1" | sed 's/^/ Did you mean /; s/$/?/')
  (tando go --help; every option: docs/EASE.md)";;
      *:[0-9]*) usage_err "the port goes in --port: tando go ${1%:*} --port ${1##*:}";;
      *@*|*.*|*[0-9]*) A_addr=$1 A_host=""; GO_GIVEN="$GO_GIVEN addr "
        case $1 in *@*) A_user=${1%@*} A_addr=${1#*@}; GO_GIVEN="$GO_GIVEN user ";; esac;;
      *) usage_err "not a server address: $1 (tando go user@203.0.113.7)";;
    esac
    [ -n "$need" ] && shift; shift
  done
}

cmd_go() {
  local f
  GO_MODE=tui GO_YES="" GO_GIVEN=" " GO_INSECURE="" GO_REPLAY=0 GO_EOF="" GO_ERR="" GO_READY="" GO_SKIPPED=""
  GO_SN=1 P_CMD=()
  { [ -t 0 ] && [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; } || GO_MODE=plain
  GO_F="$CFG/go/$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)"
  case " $* " in *" --forget "*) rm -f "$GO_F"; note "tando go: forgot the answers for this directory";; esac
  go_load
  go_flags "$@"
  [ -n "$YES" ] && GO_MODE=yes
  [ "$GO_MODE" = yes ] && GO_YES=1
  if [ -n "$HOST" ]; then A_host=$HOST; GO_GIVEN="$GO_GIVEN host "
  elif [ -f tando.conf ] && conf_load 2> /dev/null && [ -n "$C_host" ] && ! go_given addr; then
    A_host=$C_host; GO_GIVEN="$GO_GIVEN host "
  fi
  if go_given addr; then   # an address already registered: that host
    for f in "$CFG"/hosts/*; do
      [ -f "$f" ] && [ "$(host_get "${f##*/}" target)" = "$A_user@$A_addr" ] &&
        [ "$(host_get "${f##*/}" port)" = "${A_port:-22}" ] && A_host=${f##*/}
    done
    [ -z "$A_user" ] && [ -z "$A_host" ] && [ "$GO_MODE" = yes ] && A_user=root
  fi
  [ "$GO_MODE" = yes ] && [ -z "$A_host" ] && [ -z "$A_addr" ] &&
    die "tando go --yes needs the server: tando go user@address --yes"
  for ((f = 0; f < ${#GO_QS[@]}; f++)); do [ "${GO_QS[f]}" = "${A_at:-}" ] && GO_REPLAY=$f; done
  [ "$A_at" = "done" ] && GO_REPLAY=${#GO_QS[@]}
  if [ "$GO_MODE" = tui ]; then   # messages while the screen is ours are shown after leaving it
    exec 3>&2 2> "$TMPD/go.err"
    trap 'go_leave; rm -rf "$TMPD"' EXIT
    ui_term_enter
  fi
  GO_I=0
  local dir=1
  while [ $GO_I -lt ${#GO_QS[@]} ]; do
    GO_SN=${GO_STEP[GO_I]} GO_NAV=next
    "${GO_QS[GO_I]}"
    case $GO_NAV in
      next) dir=1 GO_I=$((GO_I + 1))   # the first unanswered screen is where a new run resumes
            [ "$GO_I" -ge "$GO_REPLAY" ] && [ "$A_at" != "done" ] && { A_at=${GO_QS[GO_I]:-q_review}; go_save; };;
      auto) GO_I=$((GO_I + dir)); [ $GO_I -lt 0 ] && GO_I=0 dir=1;;
      back) dir=-1 GO_REPLAY=0 GO_I=$((GO_I - 1)); [ $GO_I -lt 0 ] && GO_I=0 dir=1
            [ "$A_at" = "done" ] && A_at=q_review;;
      quit) go_quit;;
    esac
  done
  go_leave
  [ "$GO_MODE" = yes ] && [ ${#P_CMD[@]} -gt 0 ] && { GO_MODE=plain; GO_SN=6; GO_ERR=""; O_V=(); go_draw; }
  [ ${#P_CMD[@]} -gt 0 ] && go_run
  go_done
}
