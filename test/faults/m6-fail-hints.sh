#!/bin/bash
# m6: the client's explanation of a failed release (lib/deploy.sh fail_report) for app output it
# recognises, and the python start's server package (lib/build.sh python_server_pkg). Runs the
# client functions under /bin/bash 3.2 on fixed server output: no server needed.
. "$(dirname "$0")/lib-fault.sh"
f_host() { :; }
f_init m6 "app output: missing env, file, command" "client fail_report"
drv() { # recipe message log-lines... -> the report
  local rc=$1 msg=$2; shift 2
  /bin/bash -c '
    set -u; TANDO_HOME=$1; shift
    . "$TANDO_HOME/lib/ui.sh"; . "$TANDO_HOME/lib/common.sh"; . "$TANDO_HOME/lib/build.sh"; . "$TANDO_HOME/lib/deploy.sh"
    TMPD=$(mktemp -d); trap "rm -rf \"\$TMPD\"" EXIT
    TANDO_COLOR=never COLUMNS=100 ui_init
    C_recipe=$1 K_message=$2 K_port=4101 HOST=test APP=x C_out="" C_container_port="" C_dockerfile=""; shift 2
    for l; do printf "log=%s\n" "$l"; done > "$TMPD/ds"
    ui_box_open "deploy x" test; fail_report; ui_box_close end' _ "$ROOT" "$rc" "$msg" "$@" 2>&1 | tr -s ' '
}
o=$(drv node "after the switch: no answer" "Error: STRIPE_SECRET is not set" "    at main (/x/server.js:3)")
ok "a missing env variable names it and tando env set" sh -c "printf '%s' \"\$1\" | grep -q 'environment variable STRIPE_SECRET' && printf '%s' \"\$1\" | grep -q 'tando env set STRIPE_SECRET=...'" _ "$o"
o=$(drv python "pre-flight: no healthy answer" "Traceback (most recent call last):" "KeyError: 'API_TOKEN'")
ok "a Python KeyError on os.environ names the variable" sh -c "printf '%s' \"\$1\" | grep -q 'tando env set API_TOKEN=...'" _ "$o"
o=$(drv node "pre-flight: no healthy answer" "node:internal/modules/cjs/loader:1228" "Error: Cannot find module './lib/util.js'" "code: 'MODULE_NOT_FOUND'")
ok "a missing relative file is not an npm install problem" sh -c "printf '%s' \"\$1\" | grep -q 'the file ./lib/util.js is not in the release' && ! printf '%s' \"\$1\" | grep -q 'npm install'" _ "$o"
o=$(drv node "pre-flight: no healthy answer" "Error [ERR_MODULE_NOT_FOUND]: Cannot find module '/opt/tando/apps/x/releases/20261114-101010/lib/db.js' imported from /opt/tando/apps/x/releases/20261114-101010/server.js")
ok "an ESM import of a missing file names it relative to the release" sh -c "printf '%s' \"\$1\" | grep -q 'the file ./lib/db.js is not in the release'" _ "$o"
o=$(drv node "pre-flight: no healthy answer" "Error: Cannot find module 'express'" "code: 'MODULE_NOT_FOUND'")
ok "a missing package still says npm install" sh -c "printf '%s' \"\$1\" | grep -q \"Cannot find module 'express'\" && printf '%s' \"\$1\" | grep -q 'npm install'" _ "$o"
o=$(drv python "pre-flight: no healthy answer" "/bin/sh: 1: gunicorn: not found")
ok "python: <command>: not found says add it to requirements.txt" sh -c "printf '%s' \"\$1\" | grep -q 'add gunicorn to requirements.txt, then tando up'" _ "$o"
# the uploaded requirements.txt gets the server package the start command runs
mkdir -p "$W/py/stage"; printf 'flask==3.0.0' > "$W/py/stage/requirements.txt"
o=$(cd "$W/py" && /bin/bash -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; . "$1/lib/build.sh"; STAGE=$2 STAGE_NOTE=""
  C_start="gunicorn -b 127.0.0.1:\$PORT app:app"; python_server_pkg; echo "note=$STAGE_NOTE"
  python_server_pkg; cat "$STAGE/requirements.txt"' _ "$ROOT" "$W/py/stage" 2>&1)
log "python_server_pkg: $(echo "$o" | tr '\n' '|')"
ok "gunicorn is added once to the uploaded requirements.txt, with a note" \
  sh -c "[ \"\$(printf '%s' \"\$1\" | grep -c '^gunicorn\$')\" = 1 ] && printf '%s' \"\$1\" | grep -q '^flask==3.0.0\$' && printf '%s' \"\$1\" | grep -q 'note=gunicorn added to the uploaded requirements.txt'" _ "$o"
printf 'Flask\nGunicorn==22.0\n' > "$W/py/stage/requirements.txt"
o=$(cd "$W/py" && /bin/bash -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; . "$1/lib/build.sh"; STAGE=$2 STAGE_NOTE=""
  C_start="gunicorn app:app"; python_server_pkg; echo "note=$STAGE_NOTE"; cat "$STAGE/requirements.txt"' _ "$ROOT" "$W/py/stage" 2>&1)
ok "a requirements.txt that has it is left alone" sh -c "[ \"\$(printf '%s' \"\$1\" | grep -ci gunicorn)\" = 1 ] && printf '%s' \"\$1\" | grep -qx 'note='" _ "$o"
F_TRUTH=y
f_end
