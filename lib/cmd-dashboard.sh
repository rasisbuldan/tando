# shellcheck shell=bash
# help: dashboard [--no-open] [--idle 30m] [--port N]   open the dashboard in the browser (the add-on: tando addon install dashboard)
#
# lib/cmd-dashboard.sh: `tando dashboard` runs tando-dash (the add-on) with these arguments and
# this tando. tando-dash reuses a running one: it asks it for a fresh one-time link. bash 3.2.

cmd_dashboard() {
  local bin=$HOME/.local/lib/tando-dash/current/tando-dash
  [ -x "$bin" ] || bin=$(command -v tando-dash 2> /dev/null) || bin=""
  [ -n "$bin" ] && [ -x "$bin" ] ||
    die "the dashboard is not installed. Install it: tando addon install dashboard"
  if [ -z "${TANDO_DASH_TANDO:-}" ] && [ -x "$TANDO_HOME/bin/tando" ]; then
    export TANDO_DASH_TANDO=$TANDO_HOME/bin/tando
  fi
  exec "$bin" "$@"
}
