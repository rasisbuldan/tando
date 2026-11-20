# shellcheck shell=bash
# help: open [app]   open the app in the browser (prints the address when there is none)
#
# lib/cmd-open.sh: `tando open`. open_url (lib/common.sh), else print. bash 3.2.

. "$TANDO_HOME/lib/cmd-link.sh"

cmd_open() {
  link_get
  open_url "$LINK" && { note "opened $LINK"; return 0; }
  printf '%s\n' "$LINK"
}
