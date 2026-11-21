# shellcheck shell=bash
# help: addon install dashboard [--version V] [--from PATH|URL] [--sha256 HEX] | uninstall dashboard | status   the dashboard add-on (tando-dash)
#
# lib/cmd-addon.sh: `tando addon`. Installs the dashboard add-on, which ships as its own release
# asset (tando-dash-<v>-<darwin-universal|linux-amd64|linux-arm64>.tar.gz of the same GitHub
# release as the client; scripts/release-dashboard.sh builds it). The archive is checked against
# its SHA-256 before anything is unpacked, then installed as ~/.local/lib/tando-dash/<v>/ with a
# `current` link, and linked as ~/.local/bin/tando-dash. `tando dashboard` (lib/cmd-dashboard.sh)
# runs it. bash 3.2.

AD_REPO=${TANDO_REPO:-rasisbuldan/tando}
AD_LIB=$HOME/.local/lib/tando-dash
AD_BIN=$HOME/.local/bin/tando-dash

cmd_addon() {
  local sub=${1:-status} name="" ver="" from="" sum="" insecure=0
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case $1 in
      --version) [ $# -ge 2 ] || die "addon: --version needs a value"; ver=$2; shift;;
      --from) [ $# -ge 2 ] || die "addon: --from needs a path or URL"; from=$2; shift;;
      --sha256) [ $# -ge 2 ] || die "addon: --sha256 needs a checksum"; sum=$2; shift;;
      --insecure) insecure=1;;
      -*) die "addon: unknown argument: $1 (tando help addon)";;
      *) [ -z "$name" ] || die "addon: one add-on at a time"; name=$1;;
    esac
    shift
  done
  case $sub in
    install|uninstall|status) ;;
    *) die "addon: unknown subcommand: $sub (tando addon install dashboard | uninstall dashboard | status)";;
  esac
  [ -z "$name" ] || [ "$name" = dashboard ] || die "addon: no add-on called $name (there is: dashboard)"
  [ "$sub" = status ] || [ -n "$name" ] || die "addon: $sub which add-on? (tando addon $sub dashboard)"
  case $sub in
    install) ad_install "$ver" "$from" "$sum" "$insecure";;
    uninstall) ad_uninstall;;
    status) ad_status;;
  esac
}

ad_client() { tr -d ' \n' < "$TANDO_HOME/VERSION" 2> /dev/null || echo unknown; }
ad_installed() { [ -f "$AD_LIB/current/VERSION" ] && tr -d ' \n' < "$AD_LIB/current/VERSION"; }
ad_tilde() { local t='~'; printf '%s\n' "${1/#$HOME/$t}"; }

ad_platform() {
  case $(uname -s) in
    Darwin) echo darwin-universal;;
    Linux) case $(uname -m) in
             x86_64|amd64) echo linux-amd64;;
             aarch64|arm64) echo linux-arm64;;
             *) die "addon: no dashboard build for $(uname -m)";;
           esac;;
    *) die "addon: no dashboard build for $(uname -s)";;
  esac
}

ad_sha256() {
  if command -v shasum > /dev/null 2>&1; then shasum -a 256 "$1"
  elif command -v sha256sum > /dev/null 2>&1; then sha256sum "$1"
  elif command -v openssl > /dev/null 2>&1; then openssl dgst -sha256 -r "$1"
  else die "addon: no shasum, sha256sum or openssl to verify the download"
  fi | cut -d' ' -f1
}

# the dash.lock fields (JSON on one line): pid, port
ad_lock_get() { sed -n "s/.*\"$1\":\([0-9][0-9]*\).*/\1/p" "$CFG/dash.lock" 2> /dev/null | head -1; }
# the pid of a running tando-dash (the lock names a live process that is a tando-dash), else nothing
ad_running_pid() {
  local p
  p=$(ad_lock_get pid)
  [ -n "$p" ] && kill -0 "$p" 2> /dev/null || return 1
  case $(ps -p "$p" -o comm= 2> /dev/null) in *tando-dash*) printf '%s\n' "$p";; *) return 1;; esac
}

ad_install() {
  local ver=$1 from=$2 sum=$3 insecure=$4 plat client asset tmp got d v f proto="=https,file" pinned=0
  client=$(ad_client)
  plat=$(ad_platform)
  case $ver in v*) ver=${ver#v};; esac
  case $ver in *[!0-9.]*) die "addon: bad version: $ver";; esac
  [ -n "$ver" ] && pinned=1
  [ -n "$ver" ] || ver=$client
  asset=tando-dash-$ver-$plat.tar.gz
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/tando-addon.XXXXXX") || die "addon: mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  if [ -z "$from" ]; then
    pinned=1
    case $AD_REPO in OWNER/*) die "addon: set TANDO_REPO=<owner>/<repo>";; esac
    from=https://github.com/$AD_REPO/releases/download/v$ver/$asset
  fi
  case $from in
    http://*) [ "$insecure" = 1 ] || die "addon: refusing plain http: $from (use https://, a file path, or --insecure with --sha256 HEX)"
              proto="=https,file,http";;
  esac
  case $from in /*|file://*|http://*|https://*) ;; *) [ ! -f "$from" ] || from=$PWD/$from;; esac
  case $from in
    /*) cp "$from" "$tmp/a.tgz" 2> /dev/null || die "addon: cannot read $from"
        [ -n "$sum" ] || [ ! -f "$from.sha256" ] || sum=$(cut -d' ' -f1 < "$from.sha256");;
    file://*|http://*|https://*)
      command -v curl > /dev/null 2>&1 || die "addon: curl is needed to download $from"
      note "downloading $from"
      curl -fsSL --proto "$proto" --proto-redir "$proto" -o "$tmp/a.tgz" "$from" || die "addon: download failed: $from (is there a release v$ver with $asset?)"
      if [ -z "$sum" ]; then
        curl -fsSL --proto "$proto" --proto-redir "$proto" -o "$tmp/a.sha256" "$from.sha256" ||
          die "addon: no checksum: $from.sha256 not found (nothing was installed; pass --sha256 HEX if you have it)"
        sum=$(cut -d' ' -f1 < "$tmp/a.sha256")
      fi;;
    *) die "addon: --from takes a path, a file:// or an https:// URL";;
  esac
  [ -n "$sum" ] || die "addon: no checksum for $from: put $(basename "$from").sha256 next to it or pass --sha256 HEX (nothing was installed)"
  case $sum in *[!0-9a-fA-F]*|"") die "addon: bad checksum: $sum";; esac
  got=$(ad_sha256 "$tmp/a.tgz")
  [ "$got" = "$(printf '%s' "$sum" | tr 'A-F' 'a-f')" ] || die "addon: checksum mismatch: expected $sum, got $got (nothing was installed)"
  # only now is anything looked at: safe names, plain files, one directory
  tar -tzf "$tmp/a.tgz" > "$tmp/list" 2> /dev/null || die "addon: not a tar.gz archive"
  if grep -qE '^/|(^|/)\.\.(/|$)' "$tmp/list"; then die "addon: archive has unsafe paths (nothing was installed)"; fi
  tar -tvzf "$tmp/a.tgz" 2> /dev/null | grepq '^[lh]' && die "addon: archive has links (nothing was installed)"
  mkdir "$tmp/x" && tar -xzf "$tmp/a.tgz" -C "$tmp/x" || die "addon: cannot unpack the archive"
  [ "$(find "$tmp/x" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1 ] || die "addon: archive must hold one directory"
  d=$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)
  [ -n "$d" ] && [ -f "$d/tando-dash" ] && [ -f "$d/VERSION" ] || die "addon: archive has no tando-dash and VERSION"
  v=$(tr -d ' \n' < "$d/VERSION")
  case $v in [0-9]*.[0-9]*.[0-9]*) case $v in *[!0-9.]*) v="";; esac;; *) v="";; esac
  [ -n "$v" ] || die "addon: the archive's VERSION is not X.Y.Z"
  [ "$pinned" = 0 ] || [ "$v" = "$ver" ] || die "addon: the archive holds version $v, not $ver (nothing was installed)"
  chmod 755 "$d/tando-dash"
  "$d/tando-dash" --version > "$tmp/ver" 2>&1 || die "addon: the downloaded tando-dash does not run on this machine ($(head -1 "$tmp/ver")); nothing was installed"
  grep -q "tando-dash $v\$" "$tmp/ver" || die "addon: tando-dash says '$(head -1 "$tmp/ver")', the archive says $v (nothing was installed)"
  # install: <v>/ then the links
  mkdir -p "$AD_LIB" "$(dirname "$AD_BIN")" || die "addon: cannot create $AD_LIB"
  if [ -e "$AD_BIN" ] || [ -L "$AD_BIN" ]; then
    case $(readlink "$AD_BIN" 2> /dev/null) in
      *lib/tando-dash/*) ;;
      *) die "addon: $(ad_tilde "$AD_BIN") exists and is not the add-on's link: remove it first (nothing was changed)";;
    esac
  fi
  rm -rf "${AD_LIB:?}/.new" "${AD_LIB:?}/$v"
  mv "$d" "$AD_LIB/.new" && mv "$AD_LIB/.new" "$AD_LIB/$v" || die "addon: cannot put $AD_LIB/$v in place"
  # the quarantine attribute comes off the files that were just verified, nothing else
  if [ "$(uname -s)" = Darwin ] && command -v xattr > /dev/null 2>&1; then
    for f in "$AD_LIB/$v"/*; do [ -f "$f" ] && xattr -d com.apple.quarantine "$f" > /dev/null 2>&1; done
  fi
  ln -sfn "$v" "$AD_LIB/current" && ln -sfn ../lib/tando-dash/current/tando-dash "$AD_BIN" || die "addon: cannot make the links"
  for f in "$AD_LIB"/*; do
    case ${f##*/} in current|"$v") ;; *) [ -d "$f" ] && rm -rf "${f:?}";; esac
  done
  echo "dashboard $v installed: $(ad_tilde "$AD_BIN") -> $(ad_tilde "$AD_LIB")/$v (checksum ok)"
  [ "$v" = "$client" ] || echo "note: the client is $client and the dashboard is $v: use matching versions (tando addon install dashboard)"
  case ":$PATH:" in *":$(dirname "$AD_BIN"):"*) ;; *) echo "add $(ad_tilde "$(dirname "$AD_BIN")") to PATH to run tando-dash by name; \`tando dashboard\` works without it";; esac
  echo "Open it: tando dashboard   (or the menu bar's Open dashboard)"
}

ad_uninstall() {
  local p i did="" f
  if p=$(ad_running_pid); then
    kill "$p" 2> /dev/null
    i=0; while kill -0 "$p" 2> /dev/null && [ $i -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
    kill -0 "$p" 2> /dev/null && kill -9 "$p" 2> /dev/null
    echo "stopped tando-dash (pid $p)"
  fi
  if [ -L "$AD_BIN" ]; then
    case $(readlink "$AD_BIN") in *lib/tando-dash/*) rm -f "$AD_BIN"; echo "removed $(ad_tilde "$AD_BIN")"; did=1;; esac
  fi
  [ -d "$AD_LIB" ] && { rm -rf "${AD_LIB:?}"; echo "removed $(ad_tilde "$AD_LIB")"; did=1; }
  rmdir "$(dirname "$AD_LIB")" 2> /dev/null   # ~/.local/lib stays when anything else is in it
  for f in "$CFG/dash.lock" "$CFG/cache/ls-all.json" "$CFG/cache/dash-sessions.json" "$CFG/cache/dash-idem.json" \
           "$CFG/cache/dash-port" "$CFG/cache/dash-ops"; do
    [ -e "$f" ] && { rm -rf "${f:?}"; did=1; }
  done
  [ -z "$did" ] && echo "the dashboard is not installed" || echo "the dashboard add-on is removed (its lock, sessions and cache too)"
  return 0
}

ad_status() {
  local inst client p port
  inst=$(ad_installed); client=$(ad_client)
  ui_box_open "tando addon"
  if [ -n "$inst" ]; then
    ui_kv dashboard "$inst ($(ad_tilde "$AD_LIB")/current)"
    if [ "$inst" = "$client" ]; then ui_kv client "$client (same version)"
    else ui_kv client "$client: versions differ, run tando addon install dashboard"; fi
  else
    ui_kv dashboard "not installed (tando addon install dashboard)"
    ui_kv client "$client"
  fi
  if p=$(ad_running_pid); then
    port=$(ad_lock_get port)
    ui_kv running "yes (pid $p, http://127.0.0.1:$port/)"
  else ui_kv running no; fi
  ui_box_close
}
