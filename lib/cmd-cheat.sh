# shellcheck shell=bash
# help: cheat   the commands that matter, on one screen
#
# lib/cmd-cheat.sh: `tando cheat`. No server calls. bash 3.2.

cmd_cheat() {
  local l
  ui_box_open "tando cheat sheet" "tando help <command> for more"
  while IFS='|' read -r l; do
    case $l in -*) ui_box_sep "${l#-}";; *) ui_box_line "  ${UI_ACCENT}${l%%  *}${UI_NC}  ${l#*  }";; esac
  done <<'EOF2'
-start
tando go user@1.2.3.4       empty server to a live link
tando up                    deploy this directory (creates the app)
tando domain add shop.com   your own domain, with HTTPS
-every day
tando deploy                ship the code (and tando.conf changes)
tando status                the app: state, memory, releases, deploys
tando logs -f               follow the app's log
tando rollback              back to the previous good release
tando env set KEY=value     a setting for the app (restarts it)
-when something is off
tando next                  what you could do next, with the command
tando doctor                check the server end to end
tando top                   live dashboard of every server and app
tando ssh [app]             a shell on the server
EOF2
  ui_box_close "tando link ${UI_G_MID} tando open ${UI_G_MID} tando backup now ${UI_G_MID} tando alerts"
}
