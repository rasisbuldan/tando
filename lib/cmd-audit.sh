# lib/cmd-audit.sh: `tando audit [app] [-n N]`, the host's audit trail (boxed). bash 3.2.
# help: audit [app] [-n N]      who changed what on the host: one row per mutating action
#
# The server keeps /var/log/tando/audit.log (root:adm 640, rotated at 4 MB, 4 old files kept),
# one line per agent verb that changes something or reveals a secret: when, who (sudo user, or
# "system" for timers and boot), from (the ssh client address), verb, app, result, note.

cmd_audit() {
  local want=${ARGS[1]:-$APP} n=$NLINES r ts who from verb app res note
  [ -z "$want" ] || valid_app "$want" || die "bad app name: $want (a-z, 0-9, -; 2-24 characters)"
  APP=$want
  resolve 0
  [ "$n" = 100 ] && n=40             # -n not given
  agent_raw sudo audit-read "${want:--}" "$n" > "$TMPD/audit" || exit 1
  {
    printf 'TIME (GMT)\tWHO\tFROM\tACTION\tAPP\tRESULT\tNOTE\n'
    while IFS='	' read -r r ts who from verb app res note; do
      [ "$r" = audit ] || continue
      case $res in
        ok) res=$(ui_badge ok);;
        rolledback) res=$(ui_badge rolled-back);;
        started) res=$(ui_badge pending started);;
        *) res=$(ui_badge failed "$res");;
      esac
      ui_utc_v "$ts" s
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$UI_RET" "$who" "$from" "$verb" "$app" "$res" "$note"
    done < "$TMPD/audit"
  } > "$TMPD/rows"
  ui_box_open "audit${want:+ $want}" "$HOST"
  if [ "$(wc -l < "$TMPD/rows")" -le 1 ]; then ui_box_line "no actions recorded yet"
  else ui_table "l,l!4,l!3,l,l!5,l,l:6-!1" < "$TMPD/rows"; fi
  ui_box_close "newest last; /var/log/tando/audit.log on $HOST"
}
