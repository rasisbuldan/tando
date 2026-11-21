# lib/hostcare.sh: host care on the laptop (docs/HOSTCARE.md): `tando host status | care | update |
# reboot`. The server side is tando-host (srv/hostcare), reached through `tando-agent host <verb>`.
# bash 3.2; every server field is only printed (through strip and the box), never evaluated.

# hc_host [name]: the server named, else -H, tando.conf or the only one
hc_host() {
  if [ -n "${1:-}" ]; then
    valid_host "$1" || usage_err "not a host name: $1 (tando host ls lists them)" host
    [ -f "$CFG/hosts/$1" ] || host_alias "$1" > /dev/null || die "no host \"$1\" here (tando host ls lists them; tando host add registers one)"
    host_use "$1"
  else resolve 0; fi
}

# hc_opts: the host subcommand's own flags from ARGS (lib/args.sh has checked them):
# HC_POS (the words), HC_UPDATES, HC_REBOOT, HC_WINDOW, HC_TZ, HC_LEAD, HC_OTHER, HC_NOW
hc_opts() {
  local i=2 a n=${#ARGS[@]}
  HC_POS=() HC_UPDATES="" HC_REBOOT="" HC_WINDOW="" HC_TZ="" HC_LEAD="" HC_OTHER="" HC_NOW=""
  while [ $i -lt "$n" ]; do
    a=${ARGS[i]}
    case $a in
      --updates) HC_UPDATES=1;;
      --reboot) HC_REBOOT=1;;
      --even-with-other-sites) HC_OTHER=1;;
      --now) HC_NOW=1;;
      --window) i=$((i + 1)); HC_WINDOW=${ARGS[i]:-}
        case $HC_WINDOW in [0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]) ;;
          *) usage_err "--window is like 02:00-04:00 (24-hour clock, the server's time zone or --tz)" host;; esac;;
      --tz) i=$((i + 1)); HC_TZ=${ARGS[i]:-}
        case $HC_TZ in ""|*[!A-Za-z0-9_/+-]*) usage_err "--tz is a time zone name like Asia/Jakarta or UTC" host;; esac;;
      --lead) i=$((i + 1)); HC_LEAD=${ARGS[i]:-}
        is_num "$HC_LEAD" || usage_err "--lead is minutes (0 to 120)" host;;
      *) HC_POS[${#HC_POS[@]}]=$a;;
    esac
    i=$((i + 1))
  done
}

hc_fetch() { agent_raw sudo host status > "$TMPD/hs.new" || return 1; mv "$TMPD/hs.new" "$TMPD/hs"; NOW=$(now); }

hc_mark() { # state -> a badge
  case $1 in ok) ui_badge ok ok;; warn) ui_badge deploying warn;; fail) ui_badge failed fail;;
    unknown) ui_badge pending "n/a";; *) ui_badge "$1";; esac
}

# the to-do list: warn and fail rows, most important first (the rank), each with its fix whole
hc_todo() {
  awk -F '\t' '$1 == "finding" && ($4 == "warn" || $4 == "fail") { print $7 "\t" $4 "\t" $8 "\t" $10 "\t" $6 }' "$TMPD/hs" |
    sort -t "$TAB" -k1,1n > "$TMPD/hs.todo"
}

hc_render() {
  local r a b c d e f g h i j k l m n o p q x n_todo=0 n_fail=0 st title fix auto sec
  if [ -n "$JSON" ]; then hc_json; return; fi
  hc_todo
  n_todo=$(grep -c . "$TMPD/hs.todo")
  n_fail=$(grep -c "^[^$TAB]*${TAB}fail$TAB" "$TMPD/hs.todo")
  ui_box_open "host status" "$HOST"
  watch_stale_line
  while IFS=$TAB read -r r a b c d e f g h i j k l m n o p q x; do
    [ "$r" = sys ] || continue
    ui_kv machine "$b ${UI_G_MID} kernel $c ${UI_G_MID} $d${e:+ ${UI_G_MID} $e}"
    ui_flow "$(ui_meter load "${h%%.*}" "$g" 8 "$h")" \
            "$(ui_meter mem "$j" "$i" 8 "$(mb "$j")/$(mb "$i")")" \
            "$(ui_meter disk "$l" "$k" 8 "$(mb "$l")/$(mb "$k")")" \
            "${UI_DIM}up${UI_NC} $(ui_dur "$f")"
    HC_AT=$o HC_APT=$p HC_OURS=$q
  done < "$TMPD/hs"
  for sec in updates security health; do
    ui_box_sep "$sec"
    {
      printf 'STATE\tCHECK\tDETAIL\n'
      while IFS=$TAB read -r r a b c d e f g h i; do
        [ "$r" = finding ] && [ "$a" = "$sec" ] || continue
        printf '%s\t%s\t%s\n' "$(hc_mark "$c")" "$g" "$h"
      done < "$TMPD/hs"
    } > "$TMPD/hs.rows"
    ui_table "l,l,l" < "$TMPD/hs.rows"
  done
  if grep -q "^upgraded$TAB" "$TMPD/hs"; then
    ui_box_sep "last upgrades"
    while IFS=$TAB read -r r a b c d; do
      [ "$r" = upgraded ] || continue
      ui_box_wrap "  $(when "$a")  ${UI_DIM}$b${UI_NC}  $(plural "$c" package): $d"
    done < "$TMPD/hs"
  fi
  ui_box_sep "tando"
  {
    printf 'STATE\tCHECK\tDETAIL\n'
    while IFS=$TAB read -r r a b c; do
      [ "$r" = check ] && printf '%s\t%s\t%s\n' "$(hc_mark "$a")" "$b" "$c"
    done < "$TMPD/hs"
  } > "$TMPD/hs.rows"
  [ "$(wc -l < "$TMPD/hs.rows")" -gt 1 ] && ui_table "l,l,l" < "$TMPD/hs.rows"
  box_say "$UI_DIM" "  versions, Caddy, the firewall rules and every app: tando doctor${HOST:+ $HOST}; certificates: tando alerts (tls)"
  ui_box_sep "to do ($n_todo)"
  if [ "$n_todo" = 0 ]; then ui_box_line "$(ui_badge ok "nothing to do")"
  else
    while IFS=$TAB read -r r st title fix auto; do
      [ "$auto" = 1 ] && fix="$fix  ${UI_DIM}[tando can do it]${UI_NC}"
      box_say "" "$(hc_mark "$st") $title: $fix"
    done < "$TMPD/hs.todo"
  fi
  local care="" cu cr cw cz
  while IFS=$TAB read -r r cu cr cw cz _; do
    [ "$r" = care ] || continue
    care="care: updates $cu ${UI_G_MID} reboots $cr"
    [ "$cr" = on ] && care="$care $cw $cz"
  done < "$TMPD/hs"
  ui_box_close "${care:+$care ${UI_G_MID} }checked $(when "${HC_AT:-}") ${UI_G_MID} $(watch_note)"
  [ "$n_fail" = 0 ]
}

hc_json() {
  local r a b c d e f g h i j k l m n o p q x
  printf '{"host":%s,"machine":' "$(json_str "$HOST")"
  awk -F '\t' -v OFS='\t' '$1 == "sys" { $1 = ""; sub(/^\t/, ""); print }' "$TMPD/hs" |
    to_json "hostname:s,os:s,kernel:s,arch:s,virt:s,uptime_s:n,cpus:n,load5:s,mem_total_bytes:n,mem_used_bytes:n,disk_total_bytes:n,disk_used_bytes:n,swap_total_bytes:n,swap_used_bytes:n,checked_at:n,apt_checked_at:n,caddy_ours:b" |
    sed 's/^\[//; s/\]$//'
  printf ',"care":'
  awk -F '\t' -v OFS='\t' '$1 == "care" { $1 = ""; sub(/^\t/, ""); print }' "$TMPD/hs" |
    to_json "updates:s,reboot:s,window:s,zone:s,lead_min:n,other_sites:s,proven:b,skip:b,next_window:n" | sed 's/^\[//; s/\]$//'
  printf ',"findings":'
  awk -F '\t' -v OFS='\t' '$1 == "finding" { $1 = ""; sub(/^\t/, ""); print }' "$TMPD/hs" |
    to_json "section:s,id:s,state:s,since:n,auto:b,rank:n,title:s,detail:s,fix:s"
  printf ',"upgraded":'
  awk -F '\t' -v OFS='\t' '$1 == "upgraded" { $1 = ""; sub(/^\t/, ""); print }' "$TMPD/hs" | to_json "at:n,by:s,count:n,packages:s"
  printf ',"tando":'
  awk -F '\t' -v OFS='\t' '$1 == "check" { $1 = ""; sub(/^\t/, ""); print }' "$TMPD/hs" | to_json "state:s,name:s,detail:s"
  printf '}\n'
}

host_status() {
  hc_opts
  hc_host "${HC_POS[0]:-}"
  # each refresh is a full collection on the server (sshd -T, systemctl, journalctl): at most one
  # a minute (the facts change hourly)
  if [ -n "$WATCH" ] && [ "$WATCH" -lt 60 ]; then WATCH=60; fi
  watch_loop hc_render hc_fetch
}

# ---- care -------------------------------------------------------------------------------------

hc_care_show() {
  kv_read "$TMPD/o" care_updates care_reboot window zone lead_min other_sites proven caddy_ours skip next_window planned changed
  ui_box_open "host care" "$HOST"
  if [ "$K_care_updates" = on ]; then ui_kv updates "$(ui_badge ok on): security updates install themselves (unattended-upgrades, security only, no service restarts)"
  else ui_kv updates "$(ui_badge stopped off): tando host care on --updates"; fi
  if [ "$K_care_reboot" = on ]; then
    ui_kv reboots "$(ui_badge ok on): in the window $K_window ($K_zone), $K_lead_min min after a notice"
    [ "$K_skip" = 1 ] && ui_kv "" "the next one is skipped (tando host care skip off takes that back)"
    ui_int "$K_next_window" && ui_kv next "window opens $(when "$K_next_window")"
  else ui_kv reboots "$(ui_badge stopped off): tando host care on --reboot (yours meanwhile: tando host reboot)"; fi
  [ "$K_caddy_ours" = 0 ] && box_say "$UI_YELLOW" "  Caddy here also serves sites tando does not manage: tando reboots only with --even-with-other-sites."
  [ -n "$K_changed" ] && box_say "$UI_DIM" "  changed: $K_changed"
  ui_box_close "docs/HOSTCARE.md says what care does and does not do"
}

host_care() {
  local op w=() a
  hc_opts
  op=${HC_POS[0]:-}
  case $op in on|off|skip) hc_host "${HC_POS[1]:-}";; "") hc_host "";; *) hc_host "$op"; op="";; esac
  case $op in
    "") agent sudo host care > "$TMPD/o"; hc_care_show;;
    skip) case ${HC_POS[2]:-} in off) a=off;; *) a="";; esac
      agent sudo host care-skip ${a:+"$a"} > "$TMPD/o"; kv_read "$TMPD/o" skip
      if [ "$K_skip" = 1 ]; then note "the next automatic reboot of $HOST is skipped (tando host care skip off takes that back)"
      else note "no reboot of $HOST is skipped"; fi;;
    off)
      [ -n "$HC_UPDATES" ] && w[${#w[@]}]=updates
      [ -n "$HC_REBOOT" ] && w[${#w[@]}]=reboot
      agent sudo host care-off ${w[@]+"${w[@]}"} > "$TMPD/o"; hc_care_show;;
    on)
      [ -n "$HC_UPDATES$HC_REBOOT$HC_WINDOW$HC_TZ$HC_LEAD" ] || HC_UPDATES=1
      [ -n "$HC_UPDATES" ] && w[${#w[@]}]=updates
      [ -n "$HC_WINDOW" ] && w[${#w[@]}]="window=$HC_WINDOW"
      [ -n "$HC_TZ" ] && w[${#w[@]}]="tz=$HC_TZ"
      [ -n "$HC_LEAD" ] && w[${#w[@]}]="lead=$HC_LEAD"
      if [ -n "$HC_REBOOT" ]; then
        w[${#w[@]}]=reboot
        agent sudo host care > "$TMPD/o"; kv_read "$TMPD/o" caddy_ours proven window
        if [ "$K_caddy_ours" = 0 ]; then
          [ -n "$HC_OTHER" ] || die "Caddy on $HOST also serves sites tando does not manage: an automatic reboot takes them down too. To allow it anyway: tando host care on --reboot --even-with-other-sites"
          confirm "Automatic reboots of $HOST also restart the sites tando does not manage there." "$HOST"
          w[${#w[@]}]=other-sites
        fi
        if [ "$K_proven" != 1 ]; then
          confirm "tando will reboot $HOST by itself when an update needs it, in the window ${HC_WINDOW:-$K_window} (after a notice; never during a deploy). tando host reboot $HOST once by hand is the other way to start this." "$HOST"
          w[${#w[@]}]=confirmed
        fi
      fi
      agent sudo host care-on ${w[@]+"${w[@]}"} > "$TMPD/o"; hc_care_show;;
  esac
}

# ---- update -----------------------------------------------------------------------------------

host_update() {
  local all="" r n o v s
  hc_opts
  hc_host "${HC_POS[0]:-}"
  [ -n "$ALL" ] && all=all
  note "refreshing the package lists on $HOST..."
  agent sudo host update-plan ${all:+"$all"} > "$TMPD/up"
  kv_read "$TMPD/up" security other held dpkg_broken error lists
  ui_box_open "host update${all:+ --all}" "$HOST"
  [ "$K_lists" = failed ] && box_say "$UI_YELLOW" "  apt-get update failed (sudo tail /var/log/tando-apt.log on the server); the lists may be old"
  [ -n "$K_error" ] && box_say "$UI_RED" "  $K_error"
  {
    printf 'PACKAGE\tFROM\tTO\tKIND\n'
    while IFS=$TAB read -r r n o v s; do
      [ "$r" = pkg ] || continue
      [ -z "$all" ] && [ "$s" != 1 ] && continue
      if [ "$s" = 1 ]; then s=security; else s=other; fi
      printf '%s\t%s\t%s\t%s\n' "$n" "$o" "$v" "$s"
    done < "$TMPD/up"
  } > "$TMPD/rows"
  local want=${K_security:-0}
  [ -n "$all" ] && want=$(( ${K_security:-0} + ${K_other:-0} ))
  if [ "$want" = 0 ] && [ "$K_dpkg_broken" != 1 ]; then
    ui_box_line "$(ui_badge ok "nothing to install")"
    [ -z "$all" ] && [ "${K_other:-0}" -gt 0 ] && box_say "$UI_DIM" "  $(plural "$K_other" "other update") (not security): tando host update --all"
    ui_box_close "the lists were refreshed; host care checks again within the hour"
    return 0
  fi
  [ "$want" -gt 0 ] && ui_table "l,l!3,l!2,l" < "$TMPD/rows"
  [ "$K_dpkg_broken" = 1 ] && box_say "$UI_YELLOW" "  an earlier install was cut off: dpkg --configure -a finishes it first"
  [ -n "$K_held" ] && box_say "$UI_DIM" "  held, not upgraded: $K_held"
  box_say "$UI_DIM" "  no service is restarted by the upgrade (tando host status lists what runs old code)"
  ui_box_close "$(plural "$want" package) to install"
  [ -n "$YES" ] || [ ! -t 0 ] || confirm "This installs them on $HOST now." "yes"
  note "installing on $HOST (apt's output: /var/log/tando-apt.log there)..."
  agent sudo host update-apply ${all:+"$all"} > "$TMPD/o"
  kv_read "$TMPD/o" upgraded packages left reboot restart autoremove
  note "installed $(plural "${K_upgraded:-0}" package)${K_packages:+: $K_packages}"
  [ -n "$K_autoremove" ] && note "$K_autoremove"
  [ "${K_left:-0}" != 0 ] && note "$(plural "$K_left" update) still pending (kept back or failed): tando host status $HOST"
  [ -n "$K_restart" ] && note "still running old code: $K_restart (a reboot, or sudo systemctl restart <unit>)"
  if [ "$K_reboot" = 1 ]; then note "a reboot is needed to finish: tando host reboot $HOST"; fi
  return 0
}

# ---- reboot -----------------------------------------------------------------------------------

host_reboot() {
  local w=() t0 i up id
  hc_opts
  hc_host "${HC_POS[0]:-}"
  [ -n "$HC_NOW" ] && w[${#w[@]}]=now
  [ -n "$HC_OTHER" ] && w[${#w[@]}]=other-sites
  agent sudo host reboot-plan ${w[@]+"${w[@]}"} > "$TMPD/o"
  kv_read "$TMPD/o" go wait at reason caddy_ours why zone window required backup_first boot_id
  id=$K_boot_id
  if [ "$K_caddy_ours" = 0 ]; then
    [ -n "$HC_OTHER" ] || die "Caddy on $HOST also serves sites tando does not manage: a reboot takes them down too. If that is fine: tando host reboot $HOST --even-with-other-sites"
    confirm "Rebooting $HOST also stops the sites tando does not manage there for a minute or two." "$HOST"
  fi
  if [ "$K_go" != 1 ] && [ "$K_wait" != 1 ]; then die "not rebooting $HOST: $K_reason"; fi
  if [ "$K_wait" = 1 ] && [ "${K_reason#outside}" != "$K_reason" ]; then
    agent sudo host reboot ${w[@]+"${w[@]}"} > "$TMPD/o"; kv_read "$TMPD/o" planned at
    note "planned for the maintenance window $K_window ($K_zone), $(when "$K_at"): tando checks first that nothing deploys"
    note "now instead: tando host reboot $HOST --now; cancel: tando host care skip $HOST"
    return 0
  fi
  [ "$K_wait" = 1 ] && die "not rebooting $HOST now: $K_reason"
  [ "$K_required" = 1 ] || note "$HOST does not need a reboot (no update asks for one)"
  confirm "This reboots $HOST now${K_why:+ for $K_why}: every app is down for a minute or two.${K_backup_first:+ Backups first: $K_backup_first.}" "$HOST"
  t0=$(clock)
  ui_box_open "host reboot" "$HOST"
  [ -n "$K_backup_first" ] && ui_step 1 4 backups run "$K_backup_first"
  # the answer can be lost with the connection when the server goes down: an ssh failure (255)
  # without a message from tando-host counts as "rebooting"; a refusal has its message
  ERRF=$TMPD/rerr agent_raw sudo host reboot ${w[@]+"${w[@]}"} > "$TMPD/o"; i=$?
  kv_read "$TMPD/o" rebooting boot_id
  if [ "$K_rebooting" != 1 ] && { [ "$i" != 255 ] || grepq 'tando-host:' "$TMPD/rerr"; }; then
    agent_msgs < "$TMPD/rerr" | while IFS= read -r i; do box_say "$UI_RED" "$i"; done
    ui_box_close "not rebooted"; exit 1
  fi
  [ -n "$K_boot_id" ] && id=$K_boot_id
  ui_step 1 4 reboot ok "asked${K_why:+ ($K_why)}; the notice went to your notifiers"
  # ssh drops, then comes back with a new boot id (at most 10 minutes)
  i=0 up=""
  while [ $i -lt 120 ]; do
    sleep 5; i=$((i + 1))
    agent_raw sudo host reboot-result > "$TMPD/rr" 2> /dev/null || continue
    kv_read "$TMPD/rr" boot_now state result secs failed
    [ -n "$K_boot_now" ] && [ "$K_boot_now" != "$id" ] && { up=1; break; }
  done
  [ -n "$up" ] || { ui_step 2 4 back fail "no answer within 10 minutes"; ui_box_close "check the provider's console for $HOST"; exit 1; }
  ui_step 2 4 back ok "ssh answers again after $(ui_dur "$(since "$t0")")"
  # the boot unit checks every app (at most 5 minutes)
  i=0
  while [ "$K_state" = rebooting ] && [ $i -lt 70 ]; do
    sleep 5; i=$((i + 1))
    agent_raw sudo host reboot-result > "$TMPD/rr" 2> /dev/null && kv_read "$TMPD/rr" boot_now state result secs failed
  done
  if [ "$K_result" = ok ]; then
    ui_step 3 4 apps ok "every app answers its health check"
    ui_step 4 4 "done" ok "$(ui_dur "${K_secs:-0}") from the reboot to healthy"
    ui_box_close "tando host status $HOST shows what is left to do"
  elif [ "$K_result" = failed ]; then
    ui_step 3 4 apps fail "not answering: $K_failed"
    ui_box_close "tando status ${K_failed%%,*} -H $HOST; tando logs ${K_failed%%,*} -H $HOST"
    exit 1
  else
    ui_step 3 4 apps fail "the check after the boot did not finish (sudo systemctl status tando-host-boot on the server)"
    ui_box_close "tando ls -H $HOST"; exit 1
  fi
}
