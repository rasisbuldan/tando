# lib/common.sh: tando client core: messages, host registry, ssh, tando.conf, agent calls.
# bash 3.2: no associative arrays, no mapfile; never eval or source anything from the server.

CFG=${TANDO_CONFIG_DIR:-$HOME/.config/tando}
AGENT_BIN=/opt/tando/bin/tando-agent
APP="" HOST="" TARGET="" SSHO=()

die() { [ "${UI_BOX:-0}" = 1 ] && ui_box_close; printf 'tando: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
strip() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }     # drop control chars except tab, newline
valid_app() { case $1 in [a-z][a-z0-9-]*) ;; *) return 1;; esac
  case $1 in *[!a-z0-9-]*) return 1;; esac; [ ${#1} -ge 2 ] && [ ${#1} -le 26 ]; }
valid_host() { case $1 in ""|*[!A-Za-z0-9_.-]*) return 1;; esac; }
valid_id() { case $1 in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]|\
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9]|\
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9]) return 0;; esac; return 1; }
is_num() { case $1 in ""|*[!0-9]*) return 1;; esac; }
now() { date +%s; }

# ---- host registry: $CFG/hosts/<name>, key=value written by us ----------------------------
host_add() { # name user@host [--port N] [--key path] [--insecure-test]
  local name=$1 tgt=$2 port=22 key="" ins=0; shift 2 || die "usage: tando host add <name> <user@host> [--port N] [--key path]"
  valid_host "$name" || die "bad host name: $name"
  case $tgt in *@*) ;; *) die "target must be user@host";; esac
  case $tgt in *[!A-Za-z0-9_.@-]*) die "bad target: $tgt";; esac
  while [ $# -gt 0 ]; do case $1 in
    --port) is_num "${2:-}" || die "bad port"; port=$2; shift 2;;
    --key) key=$2; shift 2; case $key in /*) ;; *) key="$PWD/$key";; esac
           [ -f "$key" ] || die "no such key: $key";;
    --insecure-test) ins=1; shift;;
    *) die "unknown option: $1";; esac; done
  case "$key$CFG" in *" "*) die "paths with spaces are not supported (key or TANDO_CONFIG_DIR)";; esac
  mkdir -p "$CFG/hosts" && chmod 700 "$CFG"
  printf 'target=%s\nport=%s\nkey=%s\ninsecure=%s\n' "$tgt" "$port" "$key" "$ins" > "$CFG/hosts/$name"
  printf 'added host %s (%s, port %s%s)\n' "$name" "$tgt" "$port" "$([ $ins = 1 ] && echo ', host key NOT checked')"
}
host_get() { # name key
  local k v; while IFS='=' read -r k v; do [ "$k" = "$2" ] && { printf '%s' "$v"; return 0; }; done < "$CFG/hosts/$1"; }
host_ls() { local f; ui_box_open "hosts" "$CFG"
  { printf 'NAME\tTARGET\tPORT\tHOST KEY\n'
    for f in "$CFG"/hosts/*; do [ -f "$f" ] || continue; f=${f##*/}
      printf '%s\t%s\t%s\t%s\n' "$f" "$(host_get "$f" target)" "$(host_get "$f" port)" \
        "$([ "$(host_get "$f" insecure)" = 1 ] && echo 'not checked (test)' || echo strict)"; done; } > "$TMPD/h"
  ui_table "l,l,r,l!1" < "$TMPD/h"; ui_box_close; }
host_use() { # name -> TARGET, SSHO
  valid_host "$1" && [ -f "$CFG/hosts/$1" ] || die "unknown host: $1 (tando host add)"
  HOST=$1 TARGET=$(host_get "$1" target)
  local key; key=$(host_get "$1" key) cp="$CFG/cm/%C"
  mkdir -p "$CFG/cm" && chmod 700 "$CFG/cm"
  [ $((${#CFG} + 44)) -lt 100 ] || { cp="/tmp/tando-$(id -u)/%C"; mkdir -p "/tmp/tando-$(id -u)"; chmod 700 "/tmp/tando-$(id -u)"; }
  SSHO=(-p "$(host_get "$1" port)" -o BatchMode=yes -o ControlMaster=auto -o "ControlPath=$cp"
        -o ControlPersist=60 -o ServerAliveInterval=10 -o ConnectTimeout=10)
  [ -n "$key" ] && SSHO+=(-i "$key" -o IdentitiesOnly=yes)
  if [ "$(host_get "$1" insecure)" = 1 ]; then
    SSHO+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
  else SSHO+=(-o StrictHostKeyChecking=yes); fi
}

# ---- tando.conf: "key = value" lines, whitelisted keys --------------------------------------
C_app="" C_host="" C_recipe="" C_build="" C_out="" C_start="" C_health="" C_memory="" C_timeout="" C_jobs=""
conf_load() { # [file]
  local f=${1:-tando.conf} line k v n=0
  [ -f "$f" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do n=$((n + 1))
    case $line in ""|"#"*) continue;; *=*) ;; *) die "$f:$n: expected key = value";; esac
    k=${line%%=*} v=${line#*=}
    k=$(printf '%s' "$k" | tr -d ' \t') v=$(printf '%s' "$v" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    case $k in
      app) C_app=$v;; host) C_host=$v;; recipe) C_recipe=$v;; build) C_build=$v;; out) C_out=$v;;
      start) C_start=$v;; health) C_health=$v;; memory) C_memory=$v;; health_timeout) C_timeout=$v;;
      job.*) C_jobs="$C_jobs$k=$v
";;
      *) die "$f:$n: unknown key: $k";;
    esac
  done < "$f"
  return 0
}
# resolve app and host: -a/-H flags win over tando.conf; one registered host is the default
resolve() { # need_app(0/1)
  [ -z "$APP" ] && conf_load 2>/dev/null && APP=$C_app
  [ -z "$HOST" ] && HOST=$C_host
  if [ -z "$HOST" ]; then set -- "$1" "$CFG"/hosts/*
    [ $# -eq 2 ] && [ -f "$2" ] && HOST=${2##*/}; fi
  [ -n "$HOST" ] || die "no host: use -H <host> or set host in tando.conf"
  host_use "$HOST"
  if [ "$1" = 1 ]; then [ -n "$APP" ] || die "no app: run in a directory with tando.conf, or use -a <app>"
    valid_app "$APP" || die "bad app name: $APP (a-z, 0-9, -, 2-26 chars)"; fi
}

# ---- agent calls: argv tokens are validated here; free text only travels on stdin -----------
agent_raw() { # [sudo] verb args...   stdout/stderr stripped of control characters
  local s="" a; [ "$1" = sudo ] && { s="sudo -n "; shift; }
  for a in "$@"; do case $a in ""|*[!A-Za-z0-9_.:=/@,+-]*) die "internal: unsafe argument '$a'";; esac; done
  ssh "${SSHO[@]}" "$TARGET" "$s$AGENT_BIN $*" 2> "$TMPD/err" | strip
  local rc=${PIPESTATUS[0]}
  [ -s "$TMPD/err" ] && strip < "$TMPD/err" >&2
  return "$rc"
}
agent() { agent_raw "$@" || exit 1; }
# read key=value output into variables named K_<key>, for a whitelist of keys
kv_read() { # file keys...
  local f=$1 k v w; shift
  for w; do printf -v "K_$w" '%s' ""; done
  while IFS='=' read -r k v; do
    for w; do [ "$k" = "$w" ] && printf -v "K_$w" '%s' "$v"; done
  done < "$f"
}
