# lib/offsite.sh: `tando backup offsite ...` and `tando restore --from-host`, the client side of
# tando-offsite (srv/offsite, docs/BACKUP.md). Sourced by bin/tando and lib/cmd-restore.sh.
#
# bash 3.2. The secret access key and the recovery key are read from the terminal without echo
# (or from stdin when it is not a terminal) and travel to the server on ssh's stdin: never in
# argv, never in a file here, never in a message.

OFFSITE_BIN=/opt/tando/bin/tando-offsite

# offsite_raw [sudo] verb args...: like agent_raw, for tando-offsite; stdin passes through
offsite_raw() {
  local s="" a rc
  [ "$1" = sudo ] && { s="sudo -n "; shift; }
  for a in "$@"; do
    case $a in ""|*[!A-Za-z0-9_.:=/@,+-]*) die "internal: unsafe argument '$a'";; esac
  done
  # lint: allow RL04 every word was checked above
  ssh "${SSHO[@]}" "$TARGET" "if [ ! -x $OFFSITE_BIN ]; then echo 'tando-offsite: offsite backups need a newer tando on <host>: tando host setup <host>' >&2; exit 3; fi; $s$OFFSITE_BIN $*" \
    2> "$TMPD/oerr" | strip
  rc=${PIPESTATUS[0]}
  if [ "$rc" != 0 ] && ssh_explain "$TMPD/oerr"; then return "$rc"; fi
  [ -s "$TMPD/oerr" ] && sed 's/^tando-offsite: /tando: /' "$TMPD/oerr" | agent_msgs >&2
  return "$rc"
}
offsite_do() { offsite_raw "$@" || bail 1; }

# os_read prompt [secret]: one line into SECRET (no echo for a secret on a terminal)
os_read() {
  SECRET=""
  if [ -t 0 ]; then
    printf '%s: ' "$1" >&2
    if [ -n "${2:-}" ]; then IFS= read -rs SECRET || SECRET=""; printf '\n' >&2
    else IFS= read -r SECRET || SECRET=""; fi
  else
    IFS= read -r SECRET || SECRET=""
  fi
  case $SECRET in *[[:cntrl:]]*|*' '*) die "$1: no spaces or control characters";; esac
  [ -n "$SECRET" ] || die "$1: nothing given"
}

# the settings a command line may carry (never a secret: those come on stdin)
os_arg_ok() {
  case $1 in
    endpoint=https://*|endpoint=http://127.0.0.1*|account_id=*|bucket=*|region=*|prefix=*|access_key_id=*|\
    encrypt=on|encrypt=off|alert_hours=*|keep_daily=*|keep_weekly=*|keep_monthly=*|keep_other=*|keep_min=*) ;;
    secret_access_key=*) die "the secret access key is never given on the command line (it would stay in your shell history): tando asks for it, or reads it on stdin";;
    *) die "unknown setting: ${1%%=*} (endpoint|account_id, bucket, region, prefix, access_key_id, encrypt, alert_hours, keep_daily, keep_weekly, keep_monthly, keep_other, keep_min)";;
  esac
  case $1 in *[!A-Za-z0-9_.:/=+-]*) die "bad characters in ${1%%=*}";; esac
}

# os_steps file: the server's step=<name> ok|warn|fail <detail> lines as box steps (warn: the step
# passed and found something the owner should know: said whole, in colour, under the step)
os_steps() {
  local n=0 total l name st d
  total=$(grep -c '^step=' "$1")
  while IFS= read -r l; do
    case $l in step=*) ;; *) continue;; esac
    l=${l#step=}; name=${l%% *}; l=${l#"$name"}; l=${l# }; st=${l%% *}; d=${l#"$st"}; d=${d# }
    n=$((n + 1))
    case $name:$st in
      overwrite:ok|delete:ok) ui_step "$n" "$total" "$name" ok "${d%%:*}"; ui_box_wrap "${UI_DIM}${d#*: }${UI_NC}";;
      *:warn) ui_step "$n" "$total" "$name" ok "${d%%:*}"; ui_box_wrap "${UI_YELLOW}${d#*: }${UI_NC}";;
      *) ui_step "$n" "$total" "$name" "$st" "$d";;
    esac
  done < "$1"
}

# offsite_key_box key id: the recovery key, shown once, with what it is for
offsite_key_box() {
  ui_box_open "recovery key ${2:+$2 }(shown once)" "$HOST"
  ui_box_wrap "${UI_YELLOW}Without this key the offsite backups cannot be read, not by you, not by anyone.${UI_NC} If this server is lost, the key is what turns the bucket back into your data. Store it now outside this server (a password manager, or on paper). It is below, on a line of its own, to copy whole."
  ui_box_wrap "${UI_DIM}$HOST keeps it in /opt/tando/offsite.key (root only); tando backup offsite key --show prints it again.${UI_NC}"
  ui_box_close "then: tando backup offsite key --saved"
  # (outside the box: a box line would cut it, and a copy must be whole)
  printf '\n  %s\n\n' "$1"
}

offsite_set() {
  local a f="$TMPD/os.in"
  : > "$f"; chmod 600 "$f"
  for a; do os_arg_ok "$a"; done
  {
    for a; do printf '%s\n' "$a"; done
    if [ -t 0 ]; then
      # the four values every store needs (what is given as an argument is not asked again)
      case " $* " in *" account_id="*|*" endpoint="*) ;; *)
        printf '%s\n' "Cloudflare R2: your account id (R2 overview page). Another S3 store: its https:// endpoint." >&2
        os_read "Account id or endpoint"
        case $SECRET in https://*|http://*) printf 'endpoint=%s\n' "$SECRET";; *) printf 'account_id=%s\n' "$SECRET";; esac;;
      esac
      case " $* " in *" bucket="*) ;; *) os_read "Bucket"; printf 'bucket=%s\n' "$SECRET";; esac
      case " $* " in *" access_key_id="*) ;; *) os_read "Access key id"; printf 'access_key_id=%s\n' "$SECRET";; esac
      os_read "Secret access key (not shown)" secret; printf 'secret_access_key=%s\n' "$SECRET"
    else
      # CI and scripts: key=value lines on stdin (the secret among them)
      while IFS= read -r a || [ -n "$a" ]; do
        case $a in ""|"#"*) continue;; secret_access_key=*) ;; *) os_arg_ok "$a";; esac
        case $a in *[[:cntrl:]]*) die "control characters in the settings";; esac
        printf '%s\n' "$a"
      done
    fi
  } > "$f" || exit 1
  SECRET=""
  # never pipe into offsite_raw: in a pipeline its exit would only end the subshell
  offsite_raw sudo set < "$f" > "$TMPD/o"; a=$?
  rm -f "$f"
  ui_box_open "offsite backups" "$HOST"
  os_steps "$TMPD/o"
  if [ "$a" != 0 ]; then
    ui_box_close "nothing was saved: fix it, then set again"
    exit 1
  fi
  kv_read "$TMPD/o" key key_id key_new host_id queued encrypt
  ui_kv saved "/opt/tando/offsite.conf (root only)"
  ui_kv "host id" "$K_host_id (this server's directory in the bucket)"
  if [ "$K_encrypt" = off ]; then ui_kv encryption "${UI_YELLOW}off${UI_NC} (encrypt=off): the bucket holds your data in the clear"
  else ui_kv encryption "on, recovery key $K_key_id"; fi
  ui_kv uploads "every backup from now on; ${K_queued:-0} app(s) queued now (the newest backup of each)"
  ui_box_close "tando backup offsite status ${UI_G_MID} tando backup ls"
  if [ "$K_key_new" = 1 ]; then
    printf '\n' >&2
    offsite_key_box "$K_key" "$K_key_id" >&2
  fi
  K_key=""
}

offsite_status() {
  local r a p fl lu op e n=0
  offsite_do sudo status > "$TMPD/o"
  kv_read "$TMPD/o" configured endpoint provider bucket prefix region access_key_id host_id hostname encrypt \
    key_id key_saved keys alert_hours keep creds creds_error creds_since checked timer \
    key_overwrite key_delete key_checked prune_refused
  ui_box_open "offsite backups" "$HOST"
  if [ "$K_configured" != 1 ]; then
    ui_box_line "Off: backups stay on $HOST only, and go with it if the server is lost."
    [ -n "$K_key_id" ] && ui_kv "recovery key" "$K_key_id (kept for when it is on again)"
    ui_box_close "tando backup offsite set (Cloudflare R2 or any S3 storage; docs/BACKUP.md)"
    return 0
  fi
  NOW=$(now)
  ui_kv storage "${K_provider:+$K_provider, }bucket $K_bucket${K_prefix:+, prefix $K_prefix/}"
  ui_kv_wrap endpoint "$K_endpoint (key id $K_access_key_id)"
  ui_kv "host id" "$K_host_id ($K_hostname)"
  if [ "$K_encrypt" = off ]; then ui_kv encryption "${UI_YELLOW}off${UI_NC}: the bucket holds your data in the clear"
  elif [ "${K_key_saved:-0}" = 0 ]; then ui_kv encryption "on, key $K_key_id ${UI_YELLOW}not confirmed saved${UI_NC}: tando backup offsite key --show"
  else ui_kv encryption "on, key $K_key_id, saved $(ago "$K_key_saved")${K_keys:+ ($K_keys kept)}"; fi
  case $K_creds in
    ok) ui_kv credentials "$(ui_badge ok working), checked $(ago "$K_checked")";;
    failing) ui_kv_wrap credentials "failing since $(ago "$K_creds_since"): $K_creds_error";;
    *) ui_kv credentials "not checked yet";;
  esac
  [ "$K_timer" = active ] || ui_kv timer "${UI_RED}tando-offsite.timer is not active${UI_NC}: tando backup offsite set installs it"
  # what the last test (or set) found this key may do to an object it wrote
  case $K_key_delete in
    refused) ui_kv "this key" "$(ui_badge ok "cannot delete") what it wrote$([ "$K_key_overwrite" = refused ] && echo " or replace it"), checked $(ago "$K_key_checked")";;
    allowed) ui_kv_wrap "this key" "${UI_YELLOW}can delete the backups in the bucket${UI_NC} (checked $(ago "$K_key_checked")): a break-in on $HOST could erase them; docs/BACKUP.md, Backups the server cannot erase";;
    versions) ui_kv_wrap "this key" "the bucket keeps versions; whether this key may delete a version is not tested (docs/BACKUP.md)";;
  esac
  ui_kv_wrap keeps "$K_keep"
  [ "${K_prune_refused:-0}" -gt 0 ] 2> /dev/null &&
    ui_kv_wrap pruning "${UI_YELLOW}not done by tando${UI_NC} since $(ago "$K_prune_refused"): the storage refuses this key's deletes. Old copies stay until a lifecycle rule of the bucket expires them (docs/BACKUP.md)"
  ui_kv alert "a backup not offsite after $K_alert_hours h"
  {
    printf 'APP\tWAITING\tFAILED\tLAST UPLOAD\n'
    while IFS=$TAB read -r r a p fl lu op e; do
      [ "$r" = app ] || continue
      n=$((n + 1))
      if [ "${lu:-0}" = 0 ] || [ "$lu" = - ]; then lu=never; else lu=$(ago "$lu"); fi
      printf '%s\t%s\t%s\t%s\n' "$a" "$p" "$fl" "$lu"
    done < "$TMPD/o"
  } > "$TMPD/rows"
  if [ $n -gt 0 ]; then ui_box_sep apps; ui_table "l,r,r,l" < "$TMPD/rows"; fi
  ui_box_close "test ${UI_G_MID} key ${UI_G_MID} hosts ${UI_G_MID} sync ${UI_G_MID} off" "tando backup offsite ..."
}

offsite_key() {
  local op=${1:-}
  [ -n "$SHOW" ] && op=--show   # (the shared flag parser keeps --show for itself)
  case $op in
    --show)
      confirm "This prints the recovery key(s) of $HOST: anyone who has one and the bucket can read the backups." "$HOST"
      offsite_do sudo key-show > "$TMPD/o"
      local r id k role saved
      while IFS=$TAB read -r r id k role saved; do
        [ "$r" = key ] || continue
        if [ "$role" = current ]; then offsite_key_box "$k" "$id"
        else
          ui_box_open "older key $id" "$HOST"
          ui_box_wrap "Still needed to read the backups made before the last rotation; keep it too."
          ui_box_close
          printf '\n  %s\n\n' "$k"
        fi
      done < "$TMPD/o";;
    --saved)
      offsite_do sudo key-saved > "$TMPD/o"; kv_read "$TMPD/o" saved
      note "noted: the recovery key is stored safely ($K_saved key(s)); tando doctor stops reminding you";;
    --import)
      os_read "Recovery key (tando-key-..., not shown)" secret
      offsite_raw sudo key-import < <(printf '%s\n' "$SECRET") > "$TMPD/o" || { SECRET=""; bail 1; }
      SECRET=""
      kv_read "$TMPD/o" key_id
      note "imported recovery key $K_key_id on $HOST: it reads the old server's backups and encrypts new ones";;
    --rotate)
      confirm "This makes a new recovery key for new uploads (the old one stays on $HOST to read older backups; keep both)." "$HOST"
      offsite_do sudo key-rotate > "$TMPD/o"; kv_read "$TMPD/o" key key_id
      offsite_key_box "$K_key" "$K_key_id"; K_key="";;
    *) usage_err "backup offsite key needs --show, --saved, --import or --rotate" backup;;
  esac
}

offsite_hosts() {
  local r id hn up ver kid this apps
  offsite_do sudo hosts > "$TMPD/o"
  NOW=$(now)
  {
    printf 'HOST ID\tHOSTNAME\tUPDATED\tAPPS\tKEY\n'
    while IFS=$TAB read -r r id hn up ver kid this apps; do
      [ "$r" = host ] || continue
      [ "$this" = 1 ] && hn="$hn (this server)"
      if ui_int "$up"; then up=$(ago "$up"); else up=-; fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$hn" "$up" "$(printf '%s' "$apps" | tr ',' ' ')" "$kid"
    done < "$TMPD/o"
  } > "$TMPD/rows"
  ui_box_open "servers in the bucket" "$HOST"
  if [ "$(wc -l < "$TMPD/rows")" -gt 1 ]; then ui_table "l,l,l,l,l" < "$TMPD/rows"
  else ui_box_line "None yet (a server appears after its first daily inventory, or its first upload)."; fi
  ui_box_close "recreate one's apps here: tando restore --from-host <host id> --all"
}

cmd_backup_offsite() {
  local op=${ARGS[2]:-status} a
  # the words are checked before anything else (nothing reaches the server for a typo)
  case $op in
    set) for a in ${ARGS[@]+"${ARGS[@]:3}"}; do os_arg_ok "$a"; done;;
    status|test|off|hosts|sync) [ ${#ARGS[@]} -le 3 ] || usage_err "backup offsite $op takes no arguments" backup;;
    key) case ${ARGS[3]:-}:$SHOW in --saved:|--import:|--rotate:|:1) ;; *)
           usage_err "backup offsite key needs one of --show, --saved, --import, --rotate" backup;; esac;;
    *) a=$(printf '%s\n' set status test off key hosts sync | nearest "$op")
       usage_err "backup offsite has no subcommand \"$op\".${a:+ Did you mean \"tando backup offsite $a\"?}" backup;;
  esac
  resolve 0
  case $op in
    set) offsite_set ${ARGS[@]+"${ARGS[@]:3}"};;
    status) offsite_status;;
    test)
      offsite_raw sudo test > "$TMPD/o"; a=$?
      ui_box_open "offsite test" "$HOST"; os_steps "$TMPD/o"
      if [ "$a" != 0 ]; then ui_box_close "fix it with tando backup offsite set"; exit 1; fi
      if grep -q '^step=delete ok refused' "$TMPD/o"; then ui_box_close "the bucket works; this key cannot delete from it"
      elif grep -q '^step=delete warn allowed' "$TMPD/o"; then ui_box_close "the bucket takes, gives back, lists and deletes objects"
      else ui_box_close "the bucket takes, gives back and lists objects"; fi;;
    off)
      confirm "This stops copying backups of $HOST offsite (what is in the bucket stays, and so does the recovery key)." "$HOST"
      offsite_do sudo off > /dev/null
      note "offsite copies are off on $HOST; the bucket and the recovery key are untouched (tando backup offsite set turns them on)";;
    key) offsite_key ${ARGS[@]+"${ARGS[@]:3}"};;
    hosts) offsite_hosts;;
    sync)
      offsite_raw sudo sync now > "$TMPD/o"; a=$?
      kv_read "$TMPD/o" uploaded failed deleted retention
      note "offsite sync: ${K_uploaded:-0} uploaded, ${K_failed:-0} failed, ${K_deleted:-0} old ones deleted${K_retention:+; retention $K_retention}"
      [ "$a" = 0 ] || exit 1;;
    *) usage_err "backup offsite has no subcommand \"$op\" (set, status, test, off, key, hosts, sync)" backup;;
  esac
}

# ---- disaster recovery: tando restore --from-host <host id> [app...|--all] ------------------

restore_from_host() {
  local src=$1 all=$2 r a recipe db newest doms origin adopted n=0 skipped="" done_apps="" d w
  shift 2
  case $src in ""|*[!a-z0-9]*) usage_err "bad host id: $src (tando backup offsite hosts lists them)" restore;; esac
  for a; do valid_app "$a" || usage_err "not an app name: $a" restore; done
  [ -n "$all" ] || [ $# -gt 0 ] || {
    offsite_do sudo dr-plan "$src" > "$TMPD/plan"
    note "server $src has: $(awk -F '\t' '$1 == "app" { printf "%s ", $2 }' "$TMPD/plan")"
    usage_err "name the apps to recreate, or --all: tando restore --from-host $src --all" restore
  }
  offsite_do sudo dr-plan "$src" "$@" > "$TMPD/plan"
  {
    printf 'APP\tRECIPE\tDATA FROM\tDOMAINS\n'
    while IFS=$TAB read -r r a recipe db newest doms origin adopted; do
      [ "$r" = app ] || continue
      [ "$db" = - ] && db=""; [ "$doms" = - ] && doms=""
      printf '%s\t%s\t%s\t%s\n' "$a" "${recipe:--}${db:+ + $db}" "$( [ "$newest" = - ] && echo "no backup" || echo "$newest")" "$(printf '%s' "$doms" | sed 's/|[a-z]*//g; s/,/ /g')"
    done < "$TMPD/plan"
  } > "$TMPD/rows"
  ui_box_open "restore from server $src" "onto $HOST"
  ui_table "l,l,l,l" < "$TMPD/rows"
  ui_box_close "settings, env, domains; data from the newest backup"
  confirm "This recreates these apps on $HOST and restores their newest backup." "$HOST"
  # (the plan on descriptor 3: every ssh below has its own stdin)
  while IFS=$TAB read -r r a recipe db newest doms origin adopted <&3; do
    [ "$r" = app ] || continue
    n=$((n + 1))
    # (an empty field arrives as "-")
    [ "$doms" = - ] && doms=""; [ "$origin" = - ] && origin=""; [ "$recipe" = - ] && recipe=""; [ "$db" = - ] && db=""
    ui_box_open "$a" "$n"
    # an app that exists here already is not overwritten
    printf 'check=1\n' | agent_raw sudo configure "$a" > "$TMPD/chk" || bail 1
    kv_read "$TMPD/chk" exists needs node
    if [ "$K_exists" = 1 ]; then
      ui_step 1 1 exists skip "$a is already on $HOST: tando backup ls -a $a, then tando restore <id> -a $a"
      ui_box_close; skipped="$skipped $a"; continue
    fi
    if [ "$adopted" = 1 ]; then
      ui_step 1 1 adopted skip "an adopted app (its own user and directories): set it up again with tando adopt"
      ui_box_close; skipped="$skipped $a"; continue
    fi
    offsite_do sudo dr-conf "$src" "$a" < /dev/null > "$TMPD/conf"
    printf 'check=1\n' | cat - "$TMPD/conf" | agent_raw sudo configure "$a" > "$TMPD/chk" || bail 1
    kv_read "$TMPD/chk" needs node
    C_recipe=$recipe
    if [ -n "$K_needs" ]; then runtimes 2>&1 | sed 's/^/  /' >&2; fi
    ui_step 1 4 runtimes ok "${K_needs:-already here}"
    # the env: from the bucket into the agent, on the server (the values never reach this laptop)
    # lint: allow RL04 src was checked above, a by valid_app
    ssh "${SSHO[@]}" "$TARGET" "set -o pipefail; sudo -n $OFFSITE_BIN dr-env $src $a | sudo -n $AGENT_BIN env-set $a" \
      < /dev/null > /dev/null 2> "$TMPD/err" || { ui_step 2 4 env fail "$(agent_msgs < "$TMPD/err" | tail -1)"; ui_box_close; bail 1; }
    ui_step 2 4 env ok "set on $HOST"
    agent sudo configure "$a" < "$TMPD/conf" > "$TMPD/cfg"
    kv_read "$TMPD/cfg" link
    for d in $(printf '%s' "$doms" | tr ',' ' '); do
      w=${d#*|}; d=${d%|*}
      valid_host "$d" || continue
      case $w in redirect|serve|off) ;; *) w=redirect;; esac
      agent_raw sudo domain-add "$a" "$d" "$w" < /dev/null > /dev/null || note "  $d: not added (above); tando domain add $d -a $a"
    done
    ui_step 3 4 app ok "created: $K_link${doms:+ + $(printf '%s' "$doms" | sed 's/|[a-z]*//g; s/,/ /g')}"
    if [ "$newest" = - ]; then
      ui_step 4 4 data skip "no backup of $a in the bucket"
    else
      offsite_raw sudo fetch "$a" "$newest" "$src" < /dev/null > /dev/null || { ui_box_close; bail 1; }
      agent sudo backup-restore "$a" "$newest" < /dev/null > "$TMPD/o"
      ui_step 4 4 data ok "$newest restored (verified)"
    fi
    ui_box_close
    done_apps="$done_apps $a|${origin#*:}"
  done 3< "$TMPD/plan"
  [ -n "$done_apps" ] || { note "nothing recreated${skipped:+ (skipped:$skipped)}"; return 0; }
  ui_box_open "next: deploy the code" "$HOST"
  ui_box_wrap "Releases (the built code) are not in the backups: deploy each app from its project directory (the commands below). The data is in place and waits for it."
  ui_box_wrap "${UI_DIM}--yes: tando remembers that the directory deployed to the old server; or set host = $HOST in its tando.conf. Then point the domains' DNS at $HOST, and check: tando ls -H $HOST, tando doctor $HOST.${UI_NC}"
  ui_box_close "${skipped:+skipped:$skipped}"
  # (outside the box: a box line would cut a long path, and these are to be copied)
  printf '\n'
  for d in $done_apps; do
    a=${d%%|*}; w=${d#*|}
    if [ -n "$w" ] && [ "$w" != "$d" ]; then printf '  cd %s && tando up -H %s --yes\n' "$w" "$HOST"
    else printf '  cd <the project of %s> && tando up -H %s --yes\n' "$a" "$HOST"; fi
  done
  printf '\n'
}
