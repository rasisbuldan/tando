# shellcheck shell=bash
# help: open [app]   open the app in the browser (prints the address when there is none)
#
# lib/cmd-open.sh: `tando open`. macOS `open`, else xdg-open with a display, else print. bash 3.2.
# TANDO_NO_BROWSER=1 always prints.

. "$TANDO_HOME/lib/cmd-link.sh"

cmd_open() {
  link_get
  if [ -z "${TANDO_NO_BROWSER:-}" ]; then
    if [ "$(uname)" = Darwin ] && command -v open > /dev/null; then
      open "$LINK" && { note "opened $LINK"; return 0; }
    elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open > /dev/null; then
      xdg-open "$LINK" > /dev/null 2>&1 && { note "opened $LINK"; return 0; }
    fi
  fi
  printf '%s\n' "$LINK"
}
