# shellcheck shell=bash
# lib/cmd-assets.sh: `tando assets purge <release>`: one release's shared fingerprinted files
# (the skew window's, docs/ARCHITECTURE.md "Skew protection") go now. One ssh call. bash 3.2.

cmd_assets() {
  local sub=${ARGS[1]:-} id=${ARGS[2]:-}
  [ "$sub" = purge ] || usage_err "tando assets purge <release>" assets
  valid_id "$id" || usage_err "bad release id: ${id:-(none)} (like 20261113-171442; tando releases lists them)" assets
  resolve 1
  agent sudo assets-purge "$APP" "$id" < /dev/null > "$TMPD/o"
  kv_read "$TMPD/o" removed
  note "release $id's shared files are gone from $APP's site (${K_removed:-0} files no other release shares)"
}
