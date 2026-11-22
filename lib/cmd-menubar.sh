# shellcheck shell=bash
# help: menubar install [--dry-run] | uninstall [--dry-run] | status | build --out DIR   menu bar icon with a problem badge (macOS)
#
# lib/cmd-menubar.sh: `tando menubar`, the macOS menu bar app (macos/menubar/*.swift). bash 3.2.
# install compiles it with swiftc (Command Line Tools are enough), makes ~/Applications/tando.app
# (LSUIElement: no Dock icon) and ~/Applications/tando Dashboard.app (the dashboard as its own
# regular app: a WKWebView window on the system WebKit, macos/dashapp), signs it ad hoc, records which tando to run in
# $CFG/menubar.conf and starts it at login with a LaunchAgent. The app only runs this tando
# (`tando ls --all --json`) and requests the apps' links: no credentials, no listening socket.
# TANDO_MENUBAR_NO_LAUNCHCTL=1 (tests): files only, launchctl is not called.

MB_ID=local.tando.menubar
MB_APP=$HOME/Applications/tando.app
DA_ID=local.tando.dashboard
DA_APP="$HOME/Applications/tando Dashboard.app"
MB_PLIST=$HOME/Library/LaunchAgents/$MB_ID.plist
MB_CONF=$CFG/menubar.conf
MB_LOG=$HOME/Library/Logs/tando-menubar.log

cmd_menubar() {
  local sub=${1:-status} a out="" dry=""
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry=1;;
      --out) [ $# -ge 2 ] || die "menubar: --out needs a directory"; out=$2; shift;;
      *) die "menubar: unknown argument: $1 (tando menubar install|uninstall|status|build)";;
    esac
    shift
  done
  case $sub in
    install) mb_install "$dry";;
    uninstall) mb_uninstall "$dry";;
    status) mb_status;;
    build) [ -n "$out" ] || die "menubar build: --out DIR (where tando.app goes)"
           mb_build "$out/tando.app"; mb_build_dash "$out/tando Dashboard.app";;
    *) die "menubar: unknown subcommand: $sub (tando menubar install|uninstall|status|build)";;
  esac
}

mb_darwin() { [ "$(uname)" = Darwin ] || die "menubar: the menu bar app is for macOS"; }
mb_swiftc() {
  command -v swiftc > /dev/null 2>&1 ||
    die "menubar: swiftc not found. Install the Command Line Tools: xcode-select --install"
}
# the tando to run: the launcher this shell ran (a LaunchAgent's PATH has none of the user's dirs)
mb_launcher() {
  local p=$0
  case $p in /*) ;; */*) p=$PWD/$p;; *) p=$(command -v "$p" 2> /dev/null);; esac
  [ -n "$p" ] && [ -x "$p" ] || die "menubar: cannot tell where this tando is ($0)"
  printf '%s\n' "$p"
}
mb_version() { tr -d ' \n' < "$TANDO_HOME/VERSION" 2> /dev/null || echo 0; }

# mb_build <dir/tando.app>: compile the menu bar app, bundle, sign ad hoc; the old bundle is
# replaced at the end. mb_build_dash <dir/"tando Dashboard.app"> does the same for the dashboard app.
mb_build() {
  local src=$TANDO_HOME/macos/menubar
  mb_darwin; mb_swiftc
  [ -f "$src/main.swift" ] && [ -f "$src/Model.swift" ] && [ -f "$src/DashModel.swift" ] && [ -f "$src/DashCore.swift" ] && [ -f "$src/DashWindow.swift" ] || die "menubar: $src is missing (reinstall tando)"
  mb_bundle "$1" "$MB_ID" tando tando-menubar menu "$src"/*.swift
}
mb_build_dash() {
  local src=$TANDO_HOME/macos
  mb_darwin; mb_swiftc
  [ -f "$src/dashapp/main.swift" ] && [ -f "$src/menubar/DashCore.swift" ] || die "menubar: $src/dashapp is missing (reinstall tando)"
  mb_bundle "$1" "$DA_ID" "tando Dashboard" tando-dashboard dash "$src/dashapp/main.swift" \
    "$src/menubar/DashModel.swift" "$src/menubar/DashCore.swift" "$src/menubar/DashWindow.swift"
}
# mb_bundle <app> <bundle id> <name> <exe> <menu|dash> <swift files...>
mb_bundle() {
  local app=$1 id=$2 name=$3 exe=$4 kind=$5 new
  shift 5
  mkdir -p "$(dirname "$app")" || die "menubar: cannot create $(dirname "$app")"
  new=$(dirname "$app")/.tando-app.$$
  rm -rf "$new"; mkdir -p "$new/Contents/MacOS" "$new/Contents/Resources" || die "menubar: cannot write $new"
  # an explicit target: the toolchain default can be newer than the running macOS (Command Line Tools
  # for the next macOS stamp minos 28 on a 27 machine, and Launch Services refuses the app).
  # 13.0 matches LSMinimumSystemVersion in mb_info_plist.
  if ! swiftc -target "$(uname -m)-apple-macos13.0" -swift-version 5 -O -module-name "${exe//-/_}" -o "$new/Contents/MacOS/$exe" "$@" > "$TMPD/mb.err" 2>&1; then
    rm -rf "$new"; sed 's/^/  /' "$TMPD/mb.err" | tail -20 >&2
    die "menubar: $name did not compile (swiftc above)"
  fi
  mb_info_plist "$id" "$name" "$exe" "$kind" > "$new/Contents/Info.plist"
  codesign --force -s - "$new" > "$TMPD/mb.err" 2>&1 ||
    { rm -rf "$new"; cat "$TMPD/mb.err" >&2; die "menubar: codesign (ad hoc) failed"; }
  rm -rf "$app"
  mv "$new" "$app" || die "menubar: cannot put $app in place"
  echo "built $app ($(mb_version), signed ad hoc)"
}

# mb_info_plist <id> <name> <exe> <menu|dash>: the menu bar app is LSUIElement (no Dock icon); the
# dashboard app is a regular app
mb_info_plist() {
  local ui="  <key>LSUIElement</key><true/>"
  [ "$4" = menu ] || ui="  <key>NSHighResolutionCapable</key><true/>"
  cat << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$1</string>
  <key>CFBundleName</key><string>$2</string>
  <key>CFBundleDisplayName</key><string>$2</string>
  <key>CFBundleExecutable</key><string>$3</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$(mb_version)</string>
  <key>CFBundleVersion</key><string>$(mb_version)</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
$ui
</dict>
</plist>
EOF
}

# the LaunchAgent: start at login; a crash restarts it, Quit (exit 0) does not
mb_agent_plist() {
  local env=""
  [ -z "${TANDO_CONFIG_DIR:-}" ] ||
    env="  <key>EnvironmentVariables</key><dict><key>TANDO_CONFIG_DIR</key><string>$TANDO_CONFIG_DIR</string></dict>"
  cat << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$MB_ID</string>
  <key>ProgramArguments</key><array><string>$MB_APP/Contents/MacOS/tando-menubar</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardErrorPath</key><string>$MB_LOG</string>
$env
</dict>
</plist>
EOF
}

# menubar.conf: tando= is rewritten at every install, the other lines are kept
mb_conf() {
  local l
  {
    printf 'tando=%s\n' "$1"
    if [ -f "$MB_CONF" ]; then
      while IFS= read -r l; do case $l in tando=*) ;; *) printf '%s\n' "$l";; esac; done < "$MB_CONF"
    else
      printf '%s\n' '# tando menu bar app (tando menubar install). Seconds between checks (10 or more):' 'interval=60' \
        '# the most one check may take before it counts as failed:' 'timeout=45' \
        '# notifications: auto (the system'"'"'s, else osascript), osascript, off' 'notify=auto'
    fi
  } | write_file "$MB_CONF"
}

mb_launchctl() { [ -z "${TANDO_MENUBAR_NO_LAUNCHCTL:-}" ] && launchctl "$@"; }

mb_install() {
  local t
  mb_darwin
  t=$(mb_launcher)
  if [ -n "$1" ]; then
    command -v swiftc > /dev/null 2>&1 || echo "(swiftc not found: install would stop here; xcode-select --install)"
    echo "tando menubar install would:"
    echo "  compile $TANDO_HOME/macos/menubar/*.swift and macos/dashapp/*.swift with swiftc"
    echo "  create  $MB_APP (Info.plist with LSUIElement, signed ad hoc: codesign -s -)"
    echo "  create  $DA_APP (the dashboard: a regular app with a Dock icon, signed ad hoc)"
    echo "  write   $MB_CONF (tando=$t; interval, timeout, notify kept or defaulted)"
    echo "  write   $MB_PLIST (LaunchAgent $MB_ID, RunAtLoad: starts at login)"
    echo "  run     launchctl bootstrap gui/$(id -u) $MB_PLIST"
    echo "Nothing was changed."
    return 0
  fi
  mb_build "$MB_APP"
  mb_build_dash "$DA_APP"
  mkdir -p "$CFG" "$(dirname "$MB_PLIST")" "$(dirname "$MB_LOG")" || die "menubar: cannot create the directories"
  mb_conf "$t" || die "menubar: cannot write $MB_CONF"
  mb_agent_plist | write_file "$MB_PLIST" || die "menubar: cannot write $MB_PLIST"
  echo "wrote $MB_PLIST (starts at login)"
  if [ -n "${TANDO_MENUBAR_NO_LAUNCHCTL:-}" ]; then echo "launchctl skipped (TANDO_MENUBAR_NO_LAUNCHCTL)"; return 0; fi
  mb_launchctl bootout "gui/$(id -u)/$MB_ID" > /dev/null 2>&1
  if mb_launchctl bootstrap "gui/$(id -u)" "$MB_PLIST" 2> "$TMPD/mb.err"; then
    echo "started: the tando icon is in the menu bar (checks every $(mb_conf_get interval 60) s)"
  else
    echo "could not start it with launchctl ($(tail -1 "$TMPD/mb.err")): open $MB_APP"
  fi
  echo "It runs $t; settings in $MB_CONF. Remove it: tando menubar uninstall"
}

mb_uninstall() {
  local f did=""
  mb_darwin
  if [ -n "$1" ]; then
    echo "tando menubar uninstall would:"
    echo "  run     launchctl bootout gui/$(id -u)/$MB_ID"
    for f in "$MB_PLIST" "$MB_APP" "$DA_APP" "$MB_CONF"; do [ -e "$f" ] && echo "  remove  $f"; done
    echo "Nothing was changed."
    return 0
  fi
  mb_launchctl bootout "gui/$(id -u)/$MB_ID" > /dev/null 2>&1
  [ -f "$MB_PLIST" ] && { rm -f "$MB_PLIST"; echo "removed $MB_PLIST"; did=1; }
  if [ -d "$MB_APP" ]; then
    # only our bundle: an app of the same name from elsewhere stays
    if grep -q "<string>$MB_ID</string>" "$MB_APP/Contents/Info.plist" 2> /dev/null; then
      rm -rf "$MB_APP"; echo "removed $MB_APP"; did=1
    else echo "left $MB_APP: it is not the tando menu bar app"; fi
  fi
  if [ -d "$DA_APP" ]; then
    if grep -q "<string>$DA_ID</string>" "$DA_APP/Contents/Info.plist" 2> /dev/null; then
      rm -rf "$DA_APP"; echo "removed $DA_APP"; did=1
    else echo "left $DA_APP: it is not the tando dashboard app"; fi
  fi
  [ -f "$MB_CONF" ] && { rm -f "$MB_CONF"; echo "removed $MB_CONF"; did=1; }
  [ -n "$did" ] || echo "the menu bar app is not installed"
  return 0
}

mb_conf_get() { # key default
  local v=""
  [ -f "$MB_CONF" ] && v=$(sed -n "s/^$1=//p" "$MB_CONF" | tail -1)
  printf '%s\n' "${v:-$2}"
}

mb_tilde() { local t='~'; printf '%s\n' "${1/#$HOME/$t}"; }
mb_status() {
  local st="not installed (tando menubar install)" run="-"
  if [ -d "$MB_APP" ]; then
    st="$(mb_tilde "$MB_APP") ($(sed -n 's:.*<key>CFBundleShortVersionString</key><string>\(.*\)</string>.*:\1:p' "$MB_APP/Contents/Info.plist" 2> /dev/null))"
  fi
  if [ "$(uname)" = Darwin ] && [ -z "${TANDO_MENUBAR_NO_LAUNCHCTL:-}" ] &&
     launchctl print "gui/$(id -u)/$MB_ID" > "$TMPD/mb.st" 2> /dev/null; then
    run=$(awk -F' = ' '/^\tstate = / { s = $2 } /^\tpid = / { p = " (pid " $2 ")" } END { print s p }' "$TMPD/mb.st")
  elif [ -f "$MB_PLIST" ]; then run="not running (log in again, or: open $(mb_tilde "$MB_APP"))"
  fi
  ui_box_open "tando menubar"
  ui_kv app "$st"
  ui_kv dashboard "$([ -d "$DA_APP" ] && mb_tilde "$DA_APP" || echo "not installed (tando menubar install)")"
  ui_kv "at login" "$([ -f "$MB_PLIST" ] && mb_tilde "$MB_PLIST" || echo no)"
  ui_kv running "$run"
  ui_kv runs "$(mb_tilde "$(mb_conf_get tando -)")"
  ui_kv every "$(mb_conf_get interval 60) s, timeout $(mb_conf_get timeout 45) s, notify $(mb_conf_get notify auto)"
  ui_box_close
}
