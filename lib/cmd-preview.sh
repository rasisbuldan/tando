# lib/cmd-preview.sh: `tando preview up|ls|rm`, a temporary copy of the app for a branch
# (help: lib/help.txt; docs/COMMANDS.md "Preview apps"; docs/PREVIEWS.md).
#   tando preview up [--branch B] [--ttl 7d]   deploy this project as <app>-<branch> and print its link
#   tando preview ls [--json]                  the previews of this app
#   tando preview rm [--branch B]              remove one now
# The server makes the preview from the parent's own settings (tando-agent preview-up): no database,
# no jobs, no backups, idle_stop on, the parent's env (minus preview_skip), an expiry. With a CI deploy
# key (TANDO_DEPLOY_KEY) the same calls go through the gate, which allows only <app>-<name> of the
# key's own app. bash 3.2.

# preview_branch: the branch to preview: --branch, else CI's (a pull request's head branch, then the
# pushed ref), else this checkout's
preview_branch() {
  local b=${PV_BRANCH:-}
  [ -n "$b" ] || b=${GITHUB_HEAD_REF:-}
  [ -n "$b" ] || b=${GITHUB_REF_NAME:-}
  [ -n "$b" ] || b=$(git symbolic-ref --short -q HEAD 2> /dev/null) || b=""
  [ -n "$b" ] || die "which branch? this directory is not on one: tando preview $1 --branch <name>"
  printf '%s' "$b"
}

# preview_name parent branch -> PV_NAME: <parent>-<slug>, 24 characters at most. The slug is the
# branch lower-cased with every other character as "-"; a branch that changed in that (or is too
# long) gets a 4-hex checksum of the real name at its end, so two branches never share an app
preview_name() {
  local parent=$1 raw=$2 s lossy="" h avail keep
  s=$(printf '%s' "$raw" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//')
  [ "$s" = "$raw" ] || lossy=1
  [ -n "$s" ] || { s=branch; lossy=1; }
  avail=$((24 - ${#parent} - 1))
  [ "$avail" -ge 6 ] || die "the app name $parent is too long for previews: <app>-<branch> is at most 24 characters, so the app name may have 18 at most"
  [ ${#s} -le "$avail" ] || lossy=1
  if [ -n "$lossy" ]; then
    h=$(printf '%s' "$raw" | cksum | cut -d' ' -f1)
    h=$(printf '%04x' $((h % 65536)))
    keep=$((avail - 5))
    s=${s:0:keep}; s=${s%-}; [ -n "$s" ] || s=b
    s=$s-$h
  fi
  PV_NAME=$parent-$s
}

preview_args() { # sub: PV_BRANCH, PV_TTL from the arguments after the subcommand
  local i=2 a
  PV_BRANCH="" PV_TTL=""
  while [ $i -lt ${#ARGS[@]} ]; do
    a=${ARGS[i]}
    case $a in
      --branch) i=$((i + 1)); PV_BRANCH=${ARGS[i]:-};;
      --ttl) i=$((i + 1)); PV_TTL=${ARGS[i]:-};;
      *) usage_err "preview $1 takes no argument \"$a\"" preview;;
    esac
    i=$((i + 1))
  done
  case $PV_BRANCH in -*|*[!A-Za-z0-9._/+@#=:,-]*) [ -z "$PV_BRANCH" ] || die "bad --branch: $PV_BRANCH";; esac
  case $PV_TTL in ""|[1-9][smhd]|[1-9][0-9][smhd]|[1-9][0-9][0-9][smhd]|[1-9][0-9][0-9][0-9][smhd]) ;;
    *) die "bad --ttl: $PV_TTL (a time like 7d, 12h or 90m)";; esac
}

# preview_sync_keys name: the parent's deploy keys also work for the preview (only when the parent
# has some): the admin's login does it here, a deploy key's gate did it with preview-up
preview_sync_keys() {
  [ -z "${DEPLOY_KEY:-}" ] || return 0
  . "$TANDO_HOME/lib/cmd-ci.sh"
  gate_admin preview-keys "$1" > /dev/null 2>&1 || true
}

preview_up() {
  local parent pv link
  conf_load || no_conf
  resolve 1
  parent=$APP
  preview_name "$parent" "$(preview_branch up)"; pv=$PV_NAME
  agent sudo preview-up "$parent" "$pv" ${PV_TTL:+"$PV_TTL"} > "$TMPD/pv"
  kv_read "$TMPD/pv" preview created expires env_copied env_skipped link
  link=$K_link
  if [ "$K_created" = 1 ]; then
    note "preview $pv of $parent: no database, no jobs, no backups; stops after ${C_idle_stop:-6h} idle; expires $(preview_when "$K_expires")"
    note "its env: copied $K_env_copied variable(s) of $parent$([ "${K_env_skipped:-0}" = 0 ] || printf ', left out %s' "$K_env_skipped"); secrets it must not get: preview_skip = NAME in tando.conf, then tando deploy"
  else
    note "preview $pv exists: expiry now $(preview_when "$K_expires"); deploying to it"
  fi
  preview_sync_keys "$pv"
  APP=$pv
  # a deploy key logs in as the user of the app it deploys: the preview's (the gate mirrored the keys)
  if [ -n "${DEPLOY_KEY:-}" ]; then TARGET="tando-d-$pv@$HOST"; fi
  PREVIEW_DEPLOY=1
  do_deploy
  note "preview $pv: ${link:-see tando preview ls}"
}

preview_when() { # epoch -> "in 6d 23h" / "in 3h 5m" / "in 4m" / "now"
  local d=$(( $1 - $(now) ))
  if [ "$d" -le 0 ]; then printf 'now'
  elif [ "$d" -ge 86400 ]; then printf 'in %sd %sh' $((d / 86400)) $((d % 86400 / 3600))
  elif [ "$d" -ge 3600 ]; then printf 'in %sh %sm' $((d / 3600)) $((d % 3600 / 60))
  else printf 'in %sm' $(( (d + 59) / 60 )); fi
}

preview_ls() {
  resolve 1
  agent_raw sudo preview-ls "$APP" > "$TMPD/st" || exit 1
  if [ -n "$JSON" ]; then
    printf '{"host":%s,"app":%s,"previews":' "$(json_str "$HOST")" "$(json_str "$APP")"
    awk -F '\t' -v OFS='\t' '$1 == "preview" { print $2, $4, $5, $6, $7 }' "$TMPD/st" |
      to_json "name:s,expires:n,created:n,release:s,link:s"
    printf '}\n'
    return 0
  fi
  preview_render
}

# preview_render: the box of tando preview ls from the rows in $TMPD/st: a line per preview (name,
# expiry, release) and its link below, wrapped (a link is longer than a table column)
preview_render() {
  local r name parent exp created cur link n=0
  ui_box_open "previews $APP" "$HOST"
  while IFS=$TAB read -r r name parent exp created cur link; do
    [ "$r" = preview ] || continue
    n=$((n + 1))
    [ "$cur" = - ] && cur="not deployed yet"
    ui_box_line "$name  ${UI_DIM}expires $(preview_when "$exp"), release $cur${UI_NC}"
    ui_box_wrap "  $link"
  done < "$TMPD/st"
  [ "$n" -gt 0 ] || ui_box_line "No previews. tando preview up deploys this branch as $APP-<branch>."
  ui_box_close "they stop when idle and are removed when they expire (preview_ttl, 7d)"
}

preview_rm() {
  local parent pv
  conf_load 2> /dev/null || true
  resolve 1
  parent=$APP
  preview_name "$parent" "$(preview_branch rm)"; pv=$PV_NAME
  agent sudo preview-rm "$parent" "$pv" < /dev/null > "$TMPD/o"
  note "removed preview $pv"
}

cmd_preview() {
  local sub=${ARGS[1]:-ls}
  preview_args "$sub"
  case $sub in
    up) preview_up;;
    ls) preview_ls;;
    rm) preview_rm;;
    *) usage_err "preview has no subcommand \"$sub\"" preview;;
  esac
}
