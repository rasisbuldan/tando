# lib/cmd-restore.sh: `tando restore`, a backup back into an app (help: lib/help.txt).
#   tando restore <backup id> [-a app] [--yes]          as tando backup restore: fetched from offsite
#                                                       storage first when only the bucket has it
#   tando restore --from-host <host id> [app...|--all]  disaster recovery onto this server
#                                                       (lib/offsite.sh, docs/BACKUP.md)
cmd_restore() {
  local i=1 from="" all="" words=() a
  while [ $i -lt ${#ARGS[@]} ]; do
    a=${ARGS[i]}
    case $a in
      --from-host) i=$((i + 1)); from=${ARGS[i]:-};;
      --all) all=1;;
      --yes) ;;
      -*) usage_err "restore does not take $a" restore;;
      *) words+=("$a");;
    esac
    i=$((i + 1))
  done
  [ -n "$ALL" ] && all=1
  if [ -n "$from" ]; then
    [ -n "$all" ] && [ ${#words[@]} -gt 0 ] && usage_err "give app names or --all, not both" restore
    resolve 0
    . "$TANDO_HOME/lib/offsite.sh"
    restore_from_host "$from" "$all" ${words[@]+"${words[@]}"}
    return
  fi
  [ -z "$all" ] || usage_err "--all goes with --from-host <host id>" restore
  [ ${#words[@]} = 1 ] || usage_err "wrong number of arguments for restore: one backup id (tando backup ls lists them), or --from-host <host id> [app...|--all]" restore
  valid_backup_id "${words[0]}" || usage_err "bad backup id: ${words[0]} (tando backup ls lists them)" restore
  ARGS=(backup restore "${words[0]}")
  cmd_backup
}
