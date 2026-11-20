# lib/common.sh: tando client core: messages, validation, host registry, ssh, tando.conf,
# and calls to the server agent.
#
# bash 3.2: no associative arrays, no mapfile. Nothing the server prints is ever evaluated
# or sourced: agent output is stripped of control characters and read through whitelists.

CFG=${TANDO_CONFIG_DIR:-$HOME/.config/tando}
AGENT_BIN=/opt/tando/bin/tando-agent
APP="" HOST="" TARGET="" SSHO=()

# ---- messages ------------------------------------------------------------------------------

note() { printf '%s\n' "$*" >&2; }
# grepq: grep -q for the end of a pipeline. grep -q exits at the first match, the writer can
# then die of SIGPIPE, and with pipefail a match reads as "no match". This one reads to the end.
grepq() { grep "$@" > /dev/null; }
bail() { [ "${UI_BOX:-0}" = 1 ] && ui_box_close; exit "${1:-1}"; }   # close an open box, exit
die() { [ "${UI_BOX:-0}" = 1 ] && ui_box_close; printf 'tando: %s\n' "$*" >&2; exit 1; }
# strip: drop control characters except tab and newline, C0, DEL and UTF-8 C1 (\302\200-\237)
# and any byte 0x80-0x9f that does not continue a UTF-8 sequence (a lone 8-bit C1 such as CSI 0x9b)
# strip: control characters out, C1 as "?", and bidi controls (U+200E/F, U+202A-E, U+2066-9,
# U+061C) out, so a log line or a server field cannot reorder what the terminal shows
strip() {
  # (ssh's own notice when two commands start the shared connection at once is not the user's)
  LC_ALL=C awk '/^ControlSocket .* already exists, disabling multiplexing/ { next }
    { gsub(/[\001-\010\013-\037\177]/, ""); gsub(/\302[\200-\237]/, "?")
    gsub(/\342\200[\216\217\252-\256]|\342\201[\246-\251]|\330\234/, "")
    while (match($0, /(^|[\001-\177])[\200-\237]/)) {
      p = RSTART + RLENGTH - 1; $0 = substr($0, 1, p - 1) substr($0, p + 1) }
    print; fflush() }'
}
now() { date +%s; }
# write_file file: stdin into file through a temporary file in the same directory and a rename,
# so a parallel tando never reads it empty or half-written
write_file() {
  local t
  t=$(mktemp "$(dirname "$1")/.${1##*/}.XXXXXX") || return 1   # (a dot name: no hosts/* glob sees it)
  if cat > "$t" && mv -f "$t" "$1"; then return 0; fi
  rm -f "$t"; return 1
}
# box_say colour text...: one box line (the words joined by spaces), wrapped at the box width and
# never cut (lib/ui.sh ui_box_wrap); continuation lines keep the indent plus two spaces. colour may
# be "". Hints, fixes, commands and ids go through it (ui_box_line cuts with …)
box_say() {
  local c=$1 t ind
  shift; t=$*; ind=${t%%[! ]*}; t=${t#"$ind"}
  ui_box_wrap "$ind$c$t${c:+$UI_NC}"
}

# clock: seconds with one decimal when perl is there (it is on macOS), else whole seconds
if perl -MTime::HiRes -e1 > /dev/null 2>&1; then
  clock() { perl -MTime::HiRes=time -e 'printf "%.1f\n", time'; }
else
  clock() { date +%s; }
fi
since() { awk -v a="$1" -v b="$(clock)" 'BEGIN { d = b - a; if (d < 0) d = 0; printf "%.1f", d }'; }

# ---- validation ----------------------------------------------------------------------------

valid_app() {   # letters spelled out: [a-z] matches capitals too in some locales (bash 3.2, en_US)
  local l=abcdefghijklmnopqrstuvwxyz
  case $1 in ["$l"]*) ;; *) return 1;; esac
  case $1 in *[!"$l"0123456789-]*) return 1;; esac
  [ ${#1} -ge 2 ] && [ ${#1} -le 26 ]
}
valid_host() { case $1 in ""|*[!A-Za-z0-9_.-]*) return 1;; esac; }
valid_id() { # YYYYMMDD-HHMMSS with an optional -N suffix
  case $1 in *[!0-9-]*) return 1;; esac
  case ${#1} in 15) ;; 17|18) case $1 in ???????????????-*) ;; *) return 1;; esac;; *) return 1;; esac
  case ${1:8:1} in -) ;; *) return 1;; esac
  case ${1:0:8}${1:9:6} in *[!0-9]*) return 1;; esac
  return 0
}
valid_backup_id() {
  case $1 in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*) ;;
    *) return 1;;
  esac
  case ${1#*-*-} in daily|predeploy|manual|safety|final|adopt) return 0;; esac
  return 1
}
# pick_num count noun [default]: the terminal picker's question (a numbered list was just printed:
# db studio's apps, env log's entries). Reads a number 1..count from stdin into PICK; an empty
# answer takes the default when there is one; anything else is refused, nothing opened.
pick_num() {
  local p
  printf 'Open which? [1-%s] ' "$1" >&2
  IFS= read -r p || p=""
  [ -z "$p" ] && p=${3:-}
  { is_num "$p" && [ "$p" -ge 1 ] && [ "$p" -le "$1" ]; } || die "no $2 number $p; nothing opened"
  PICK=$p
}
is_num() { case $1 in ""|*[!0-9]*) return 1;; esac; }

# ---- host registry: $CFG/hosts/<name>, key=value lines we wrote ourselves ------------------

host_add() { # name user@host [--port N] [--key path] [--insecure-test] [--deploy] [--force]
  local name=$1 tgt=$2 port=22 key="" insecure=0 kind=admin force="" nocheck=""
  shift 2
  valid_host "$name" || usage_err "bad host name: $name (letters, digits, . _ -)" host
  # one way to give the port: --port (user@host:port and ssh://... are refused with the command)
  case $tgt in
    ssh://*) tgt=${tgt#ssh://}; tgt=${tgt%/}
      case $tgt in *:[0-9]*) usage_err "the port goes in --port: tando host add $name ${tgt%:*} --port ${tgt##*:}" host;; esac
      usage_err "the address is user@host, without ssh://: tando host add $name $tgt" host;;
    *@*:[0-9]*) usage_err "the port goes in --port: tando host add $name ${tgt%:*} --port ${tgt##*:}" host;;
    *@*) ;;
    *) usage_err "the address needs the user you log in as: tando host add $name root@$tgt (or ubuntu@, admin@...)" host;;
  esac
  case $tgt in *[!A-Za-z0-9_.@-]*) usage_err "bad address: $tgt (user@host, like admin@203.0.113.7)" host;; esac
  while [ $# -gt 0 ]; do
    case $1 in
      --port) is_num "${2:-}" || usage_err "--port needs a number" host; port=$2; shift 2;;
      --key)
        key=$2; shift 2
        case $key in /*) ;; *) key="$PWD/$key";; esac
        [ -f "$key" ] || die "no such key: $key";;
      --insecure-test) insecure=1; shift;;
      --no-check) nocheck=1; shift;;
      --deploy) kind=deploy; shift;;
      --force) force=1; shift;;
      *) shift;;
    esac
  done
  local entry old=""
  entry=$(printf 'target=%s\nport=%s\nkey=%s\ninsecure=%s\nkind=%s' "$tgt" "$port" "$key" "$insecure" "$kind")
  if [ -f "$CFG/hosts/$name" ]; then
    old=$(cat "$CFG/hosts/$name")
    # the same command again just continues; a different server under this name needs --force
    [ "$old" = "$entry" ] || [ -n "$force$FORCE" ] ||
      die "host $name is already $(host_get "$name" target), port $(host_get "$name" port): tando host add $name ... --force replaces it"
  fi
  case "$key$CFG" in *" "*) die "paths with spaces are not supported (key or TANDO_CONFIG_DIR)";; esac
  mkdir -p "$CFG/hosts" && chmod 700 "$CFG"
  printf '%s\n' "$entry" | write_file "$CFG/hosts/$name" || die "cannot write $CFG/hosts/$name"
  if [ "$kind" = deploy ]; then note "added host $name ($tgt, port $port, a deploy key)"; return 0; fi
  if [ -n "$nocheck" ]; then note "added host $name ($tgt, port $port), not checked: tando doctor $name checks it"; return 0; fi
  # the entry stays only once tando can log in with it (a failed add leaves the old one, or none)
  host_use "$name"
  # (host_trust and host_check say why they fail; host_use alone is silent, so it gets a line here:
  # "not saved" must never be the only line of a failed add)
  if [ $insecure = 1 ] || host_trust; then
    if ! host_use "$name"; then
      note "tando: could not prepare the ssh options for $name (a bug in tando: please report it)"
    elif host_check; then
      note "added host $name ($tgt, port $port$( [ $insecure = 1 ] && printf ', host key NOT checked'))"
      return 0
    fi
  fi
  if [ -n "$old" ]; then printf '%s\n' "$old" | write_file "$CFG/hosts/$name"; else rm -f "$CFG/hosts/$name"; fi
  note "  (not saved; run the same command again once that is fixed)"
  return 1
}

# scan_keys addr port: the server's host keys (known_hosts lines). ed25519 alone first: ssh-keyscan
# opens one connection per key type, and each one counts against sshd's PerSourcePenalties
scan_keys() {
  local k
  k=$(ssh-keyscan -T 5 -p "$2" -t ed25519 "$1" 2> /dev/null | grep -v '^#')
  [ -n "$k" ] || k=$(ssh-keyscan -T 5 -p "$2" -t ecdsa,rsa "$1" 2> /dev/null | grep -v '^#')
  [ -n "$k" ] && printf '%s\n' "$k"
  return 0
}

# host_trust: the server's host key, once: known already, or shown and trusted (--yes) into
# $CFG/known_hosts, which ssh reads next to ~/.ssh/known_hosts
host_trust() {
  local addr=${TARGET#*@} port fp hk
  port=$(host_get "$HOST" port)
  hk=$addr; [ "$port" = 22 ] || hk="[$addr]:$port"
  if ssh-keygen -F "$hk" -f "$CFG/known_hosts" > /dev/null 2>&1 ||
     ssh-keygen -F "$hk" > /dev/null 2>&1; then return 0; fi
  # one connection in the usual case: OpenSSH 10's sshd refuses an address for a while after a
  # few connections that do not log in (PerSourcePenalties noauth), and a key scan is one
  scan_keys "$addr" "$port" > "$TMPD/keys"
  if [ ! -s "$TMPD/keys" ]; then
    # why not? the server's own error says it: refused, timeout, unknown name
    if ! ssh -p "$port" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
         -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o PasswordAuthentication=no \
         -o PreferredAuthentications=none "$TARGET" true 2> "$TMPD/probe"; then
      case $(cat "$TMPD/probe") in
        *"Permission denied"*|*"No more authentication methods"*) ;;
        "") note "tando: $addr (port $port) closed the connection at once: sshd may refuse this address for" \
              "a while after many attempts (OpenSSH 10 PerSourcePenalties); try again in a minute"; return 1;;
        *) ssh_explain "$TMPD/probe" || note "tando: cannot reach $addr (port $port): $(strip < "$TMPD/probe" | tail -1)"
           return 1;;
      esac
    fi
    note "tando: $addr (port $port) answers, but does not show an ssh host key: is it an ssh server?"
    return 1
  fi
  fp=$(ssh-keygen -lf "$TMPD/keys" 2> /dev/null | awk '{ print $4, $2 }' | sed 's/[()]//g' | head -3)
  note "$HOST ($addr, port $port) presents these host keys:"
  printf '%s\n' "$fp" | sed 's/^/  /' >&2
  if [ -z "${YES:-}" ]; then
    if [ -t 0 ]; then
      printf 'Trust them? Compare with ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on the server [y/N] ' >&2
      local a; IFS= read -r a || a=""
      case $a in y|Y|yes) ;; *) note "not trusted; nothing saved"; return 1;; esac
    else
      note "tando: not trusted (no terminal to ask): run again with --yes to trust them"; return 1
    fi
  fi
  cat "$TMPD/keys" >> "$CFG/known_hosts" && chmod 600 "$CFG/known_hosts"
  note "trusted; saved in $CFG/known_hosts"
}

# host_check: one ssh call: login, passwordless sudo, tando installed and its version
host_check() {
  local out
  out=$(ssh "${SSHO[@]}" "$TARGET" 'echo login=1; sudo -n true 2> /dev/null && echo sudo=1;
    test -x /opt/tando/bin/tando-agent && echo agent=1; cat /opt/tando/VERSION 2> /dev/null | sed "s/^/version=/"' \
    2> "$TMPD/err" | strip)
  case $out in *login=1*) ;; *) ssh_explain "$TMPD/err" || note "tando: cannot connect to $HOST: $(strip < "$TMPD/err" | grep . | tail -1)"; return 1;; esac
  case $out in *sudo=1*) ;; *) explain_sudo; return 1;; esac
  case $out in
    *agent=1*) note "$(ui_badge ok connected) sudo ok, tando ${out##*version=} installed: tando doctor $HOST";;
    *) note "$(ui_badge ok connected) sudo ok, not set up yet: tando host setup $HOST";;
  esac
}

host_rm() {
  valid_host "$1" && [ -f "$CFG/hosts/$1" ] || die "no host named $1 (tando host ls)"
  rm -f "$CFG/hosts/$1" "$CFG/cache/apps.$1"
  note "forgot host $1 (nothing on the server changed)"
}

host_get() { # name key
  local l
  while IFS= read -r l; do   # (IFS='=' read drops a trailing "=")
    [ "${l%%=*}" = "$2" ] && { printf '%s' "${l#*=}"; return 0; }
  done < "$CFG/hosts/$1"
}

# ctl_dir: a short private directory for ssh control sockets when $CFG/cm is too long for one.
# Made with mktemp -d (700, ours) and remembered in $CFG/ctl-dir; reused only while it is still a
# real directory owned by this user with mode 700 (another user could otherwise take it over).
ctl_dir() {
  local d="" perm
  [ -f "$CFG/ctl-dir" ] && d=$(cat "$CFG/ctl-dir")
  if [ -n "$d" ] && [ -d "$d" ] && [ ! -L "$d" ]; then
    perm=$(ls -ldn "$d" | awk '{print substr($1, 1, 10), $3}')
    [ "$perm" = "drwx------ $(id -u)" ] && { CTL_DIR=$d; return 0; }
  fi
  d=$(mktemp -d /tmp/tando.XXXXXX) || die "cannot create a private directory for ssh sockets"
  printf '%s\n' "$d" | write_file "$CFG/ctl-dir"
  CTL_DIR=$d
}

# host_use name: sets HOST, TARGET and the ssh options SSHO
host_use() {
  if ! { valid_host "$1" && [ -f "$CFG/hosts/$1" ]; }; then
    local f hs=""; for f in "$CFG"/hosts/*; do [ -f "$f" ] && hs="${hs:+$hs, }${f##*/}"; done
    if [ -n "$hs" ]; then die "unknown host: $1 (servers here: $hs; tando host ls). A new one: tando host add $1 <user@address>"
    else die "unknown host: $1 (none registered yet): tando host add $1 <user@address>, or tando go <user@address>"; fi
  fi
  HOST=$1
  TARGET=$(host_get "$1" target)
  # One control socket per host entry: %C (user, host, port) plus a checksum of the entry's name,
  # key file and host-key policy. Two entries for the same server never share a connection, so
  # each one's own key and host-key check are used (a shared master would skip both).
  local key cp tag
  key=$(host_get "$1" key)
  tag=s; [ "$(host_get "$1" insecure)" = 1 ] && tag=i
  tag="$tag$(printf '%s|%s|%s' "$1" "$key" "$tag" | cksum | cut -d' ' -f1)"
  cp="$CFG/cm/%C-$tag"
  mkdir -p "$CFG/cm" && chmod 700 "$CFG/cm"
  # unix socket paths are limited to 104 bytes: %C is 40 characters, ssh adds 17 while creating it
  if [ $((${#CFG} + 4 + 40 + ${#tag} + 1 + 17)) -gt 103 ]; then
    ctl_dir
    cp="$CTL_DIR/%C-$tag"
  fi
  SSHO=(-p "$(host_get "$1" port)" -o BatchMode=yes -o ControlMaster=auto -o "ControlPath=$cp"
        -o ControlPersist=60 -o ServerAliveInterval=10 -o ConnectTimeout=5)
  [ -n "$key" ] && SSHO+=(-i "$key" -o IdentitiesOnly=yes)
  if [ "$(host_get "$1" kind)" = deploy ]; then   # a deploy key's host entry (tando ci)
    . "$TANDO_HOME/lib/cmd-ci.sh"; ci_key_ui
  fi
  if [ "$(host_get "$1" insecure)" = 1 ]; then
    SSHO+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
  else
    SSHO+=(-o StrictHostKeyChecking=yes)
    # keys trusted by `tando host add` live in $CFG/known_hosts, read with the user's own
    # (GlobalKnownHostsFile: one path per option, no space that rsync -e or a string could split)
    [ -f "$CFG/known_hosts" ] && SSHO+=(-o "GlobalKnownHostsFile=$CFG/known_hosts")
  fi
  return 0   # (a server already in ~/.ssh/known_hosts has no $CFG/known_hosts: not a failure)
}

# ssh_wrapper: a script $TMPD/ssh-<host> that runs ssh with this host's options (SSHO) and its
# arguments -> SSH_WRAPPER. The one way to hand the options to another program or to a later
# command line (rsync -e "$SSH_WRAPPER", tando top's background fetches) without flattening the
# array into a string that is split again. Paths with spaces are refused at host add.
ssh_wrapper() {
  SSH_WRAPPER=$TMPD/ssh-$HOST
  [ -x "$SSH_WRAPPER" ] && return 0
  { printf '#!/bin/sh\nexec ssh'; printf ' %q' "${SSHO[@]}"; printf ' "$@"\n'; } > "$SSH_WRAPPER.tmp" &&
    chmod 700 "$SSH_WRAPPER.tmp" && mv "$SSH_WRAPPER.tmp" "$SSH_WRAPPER" || die "cannot write $SSH_WRAPPER"
}

# ---- tando.conf: "key = value" lines with whitelisted keys --------------------------------

C_app="" C_host="" C_recipe="" C_build="" C_out="" C_start="" C_start_shell="" C_health=""
C_memory="" C_timeout="" C_path="" C_data="" C_jobs="" C_writable="" C_backup="" C_database=""
C_soak=""
C_logs=""   # log_max, log_keep, log_rate, access_log as key=value lines (checked by the server)
C_image="" C_container_port="" C_build_memory="" C_dockerfile="" C_node="" C_domain="" C_www=""
C_assets=""   # fingerprinted files served from Caddy: off, or <dir>[, <url prefix>] (checked by the server too)
C_job_timeout=""   # seconds a scheduled job may run (the server's default: 3600)
C_job_spread="" C_job_missed=""   # the spread of a job's start (default 15 s), run or skip a run missed while the server was off
C_workers=""       # worker.<name> = <command> and their .memory, .stop_timeout as key=value lines
C_release="" C_release_shell="" C_release_timeout=""   # the release command (lib/deploy.sh; checked by the server too)
C_cpu="" C_tasks="" C_max_conns="" C_max_requests="" C_stop_timeout="" C_hold=""   # limits (checked by the server too)

# trim_v text -> TRIM: without leading and trailing white space (no fork; conf_load runs it per line)
trim_v() { TRIM=${1#"${1%%[![:space:]]*}"}; TRIM=${TRIM%"${TRIM##*[![:space:]]}"}; }
trim() { trim_v "$1"; printf '%s' "$TRIM"; }

# conf_chk_extra key value: the settings the server checks again (logs, health); CHK_MSG says why not
conf_chk_extra() {
  local n=${2%?}
  case $1 in
    log_keep) CHK_MSG="log_keep is hours or days, like 12h, 30d"
      case $2 in *h|*d|*w) ui_int "$n" && [ "$n" -ge 1 ];; *) false;; esac;;
    log_max|request_log_max) CHK_MSG="$1 is a size of at least 4M, like 500M or 2G"
      case $2 in *K) ui_int "$n" && [ "$n" -ge 4096 ];; *M) ui_int "$n" && [ "$n" -ge 4 ];;
        *G) ui_int "$n" && [ "$n" -ge 1 ];; *) false;; esac;;
    log_rate) CHK_MSG="log_rate is lines/seconds like 5000/30s, or off"
      case $2 in off) true;; */*s) n=${2%%/*}; ui_int "$n" && [ "$n" -ge 1 ] && ui_int "$(printf '%s' "${2#*/}" | tr -d s)";;
        *) false;; esac;;
    access_log) CHK_MSG="access_log is on or off"; case $2 in on|off) true;; *) false;; esac;;
    health_expect) CHK_MSG="health_expect is a status (200, 2xx) and/or a text the answer contains"
      local st=${2%% *} tx=""
      case $2 in *' '*) tx=${2#* };; esac
      case $st in [1-5][0-9][0-9]|[1-5]xx) ;; *) st="" tx=$2;; esac
      case $tx in *'"'*|*\\*|*[![:print:]]*) return 1;; esac
      [ -n "$st$tx" ] && [ ${#tx} -le 100 ];;
    health_fails|health_recover) CHK_MSG="$1 is a number of checks in a row, 1 to 99"
      ui_int "$2" && [ "$2" -ge 1 ] && [ "$2" -le 99 ];;
    # limits of the app's PostgreSQL role (docs/COMMANDS.md "Database limits"); n: digits allowed
    db_statement_timeout|db_idle_tx_timeout) CHK_MSG="$1 is a time like 500ms, 30s, 5m or 2h (up to 99h), or off"
      case $2 in off) return 0;; *ms) n=${2%ms}; set -- "$n" 9;; *s) set -- "$n" 6;; *m) set -- "$n" 4;;
        *h) set -- "$n" 2;; *) return 1;; esac
      ui_int "$1" && [ "${1#0}" = "$1" ] && [ ${#1} -le "$2" ];;
    db_temp_limit) CHK_MSG="db_temp_limit is a size like 512M or 2G (up to 999G), or off"
      case $2 in off) return 0;; *M) set -- "$n" 6;; *G) set -- "$n" 3;; *) return 1;; esac
      ui_int "$1" && [ "${1#0}" = "$1" ] && [ ${#1} -le "$2" ];;
  esac
}
# ---- job schedules: the 5-field cron syntax as systemd's OnCalendar ---------------------------
# job.<name> = <schedule> | <command>. The schedule is a systemd calendar expression (daily,
# *-*-* 03:00, Mon..Fri 09:00) or the cron syntax people know: five fields, minute hour day-of-month
# month weekday, with *, lists, ranges, steps (*/15, 10-50/10) and month and weekday names; or
# @hourly @daily @weekly @monthly @yearly. A cron schedule becomes an OnCalendar one here, before
# anything is sent (the server only knows OnCalendar), and only when the two mean exactly the same:
# what cannot be said that way is refused with what to write instead (cron_why).
# cron_looks_like text: five words and no ":" (an OnCalendar time has one), or one word with "@"
cron_looks_like() {
  local w
  set -f; set -- $1; set +f
  w=$#
  [ "$w" = 1 ] && { case $1 in @*) return 0;; esac; return 1; }
  [ "$w" = 5 ] || return 1
  case " $* " in *:*) return 1;; esac
  return 0
}
# cron_field <name> <min> <max> <text> [names]: CRON_SET[min..max] = 1 for the values the text
# selects; CRON_STAR=1 when it starts with "*"; fails with CRON_WHY. names: words for 0.. (month
# jan..dec from 1, weekday sun..sat from 0)
cron_num() { # word names -> CRON_N (a number or a name), 1 on failure
  local w=$1 i=0 x
  case $w in ""|*[!0-9]*)
    for x in $2; do
      [ "$x" = "$w" ] && { CRON_N=$((i + CRON_NAME0)); return 0; }
      i=$((i + 1))
    done
    return 1;;
  esac
  [ ${#w} -le 3 ] || return 1
  CRON_N=$((10#$w)); return 0
}
cron_field() {
  local what=$1 min=$2 max=$3 text=$4 names=${5:-} item rng step a b i lo hi
  CRON_SET=(); CRON_STAR=0
  i=$min; while [ "$i" -le "$max" ]; do CRON_SET[$i]=0; i=$((i + 1)); done
  case $text in \**) CRON_STAR=1;; esac
  case $text in ""|,*|*,|*,,*) CRON_WHY="the $what field \"$text\" has an empty item"; return 1;; esac
  local IFS=,
  set -f; set -- $text; set +f
  IFS=$' \t\n'
  for item in "$@"; do
    rng=${item%%/*} step=1
    case $item in
      */*) step=${item#*/}
        case $step in ""|*[!0-9]*) CRON_WHY="the step in \"$item\" ($what) is not a number"; return 1;; esac
        step=$((10#$step))
        [ "$step" -ge 1 ] || { CRON_WHY="\"$item\" ($what): a step of 0"; return 1; };;
    esac
    case $rng in
      \*) lo=$min hi=$max;;
      ?*-?*) a=${rng%%-*} b=${rng#*-}
        cron_num "$a" "$names" && lo=$CRON_N || { CRON_WHY="\"$a\" in the $what field is not a number${names:+ or name}"; return 1; }
        cron_num "$b" "$names" && hi=$CRON_N || { CRON_WHY="\"$b\" in the $what field is not a number${names:+ or name}"; return 1; }
        [ "$lo" -le "$hi" ] || { CRON_WHY="\"$item\" ($what) goes backwards; cron has no wrap-around: write two ranges, like 22-23,0-5"; return 1; };;
      *) cron_num "$rng" "$names" && lo=$CRON_N || {
           case $rng in *[LW#?]*) CRON_WHY="\"$item\" ($what) is a Quartz extension (L, W, #, ?), not cron: tando takes the 5-field cron of crontab(5)";;
             *) CRON_WHY="\"$rng\" in the $what field is not a number${names:+ or name}";; esac
           return 1; }
        hi=$lo
        case $item in */*) CRON_WHY="\"$item\" ($what): a step needs * or a range (cron does not take 5/15); write $lo-$max/${item#*/}, or list the values"; return 1;; esac;;
    esac
    [ "$lo" -ge "$min" ] && [ "$hi" -le "$max" ] ||
      { CRON_WHY="\"$item\" is outside the $what field's range $min-$max"; return 1; }
    i=$lo; while [ "$i" -le "$hi" ]; do CRON_SET[$i]=1; i=$((i + step)); done
  done
  return 0
}
# cron_render <min> <max> <pad> [names]: CRON_SET as an OnCalendar field: * when it is all, a/n when
# it is exactly a, a+n, ... up to the maximum, else a list with runs of three or more as a..b
cron_render() {
  local min=$1 max=$2 pad=$3 names=${4:-} i cnt=0 first=-1 last=-1 step=0 prev=-1 ok=1 out="" run=0 start=-1 v
  local vals=""
  i=$min; while [ "$i" -le "$max" ]; do
    if [ "${CRON_SET[$i]}" = 1 ]; then
      cnt=$((cnt + 1)); vals="$vals $i"
      [ "$first" = -1 ] && first=$i
      if [ "$prev" != -1 ]; then
        if [ "$step" = 0 ]; then step=$((i - prev)); elif [ $((i - prev)) != "$step" ]; then ok=0; fi
      fi
      prev=$i; last=$i
    fi
    i=$((i + 1))
  done
  CRON_OUT=""
  [ "$cnt" = $((max - min + 1)) ] && { CRON_OUT='*'; return 0; }
  if [ "$cnt" -ge 3 ] && [ "$ok" = 1 ] && [ "$step" -ge 2 ] && [ $((last + step)) -gt "$max" ] && [ -z "$names" ]; then
    printf -v CRON_OUT "%0${pad}d/%d" "$first" "$step"; return 0
  fi
  prev=-1; start=-1
  for v in $vals X; do
    if [ "$v" != X ] && [ "$prev" != -1 ] && [ "$v" = $((prev + 1)) ]; then prev=$v; continue; fi
    if [ "$start" != -1 ]; then   # close the run start..prev
      if [ $((prev - start)) -ge 2 ]; then CRON_OUT="$CRON_OUT,$(cron_name "$start" "$pad" "$names")..$(cron_name "$prev" "$pad" "$names")"
      else
        CRON_OUT="$CRON_OUT,$(cron_name "$start" "$pad" "$names")"
        [ "$prev" != "$start" ] && CRON_OUT="$CRON_OUT,$(cron_name "$prev" "$pad" "$names")"
      fi
    fi
    start=$v prev=$v
  done
  CRON_OUT=${CRON_OUT#,}
}
cron_name() { # value pad names
  local i=0 x
  if [ -n "$3" ]; then for x in $3; do [ "$i" = "$1" ] && { printf '%s' "$x"; return; }; i=$((i + 1)); done; fi
  printf "%0${2}d" "$1"
}
# cron_to_cal "<cron schedule>": CRON_CAL (the OnCalendar expression), or fails with CRON_WHY
cron_to_cal() {
  local s f mi h dom mon dow dowstar domstar wd d i
  s=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  set -f; set -- $s; set +f
  if [ $# = 1 ]; then
    case $1 in
      @hourly) set -- 0 '*' '*' '*' '*';;
      @daily|@midnight) set -- 0 0 '*' '*' '*';;
      @weekly) set -- 0 0 '*' '*' 0;;
      @monthly) set -- 0 0 1 '*' '*';;
      @yearly|@annually) set -- 0 0 1 1 '*';;
      @reboot) CRON_WHY="@reboot is not a schedule: a job runs at times (a command to start at boot is not a job)"; return 1;;
      *) CRON_WHY="\"$1\" is not a schedule: @hourly, @daily, @weekly, @monthly, @yearly or five fields"; return 1;;
    esac
  fi
  [ $# = 5 ] || { CRON_WHY="cron has five fields (minute hour day-of-month month weekday), got $#"; return 1; }
  # (cron_field uses these names as its own: keep the five results apart)
  CRON_NAME0=0
  cron_field minute 0 59 "$1" || return 1; cron_render 0 59 2; mi=$CRON_OUT
  cron_field hour 0 23 "$2" || return 1; cron_render 0 23 2; h=$CRON_OUT
  cron_field day-of-month 1 31 "$3" || return 1; cron_render 1 31 2; dom=$CRON_OUT; domstar=$CRON_STAR
  CRON_NAME0=1
  cron_field month 1 12 "$4" "jan feb mar apr may jun jul aug sep oct nov dec" || return 1; cron_render 1 12 2; mon=$CRON_OUT
  CRON_NAME0=0
  cron_field weekday 0 7 "$5" "sun mon tue wed thu fri sat" || return 1; dowstar=$CRON_STAR
  # (7 is Sunday too; then the weekdays in systemd's order, Monday first)
  [ "${CRON_SET[7]}" = 1 ] && CRON_SET[0]=1
  wd=(); i=0
  for d in 1 2 3 4 5 6 0; do wd[$i]=${CRON_SET[$d]}; i=$((i + 1)); done
  CRON_SET=(); i=0; while [ "$i" -lt 7 ]; do CRON_SET[$i]=${wd[$i]}; i=$((i + 1)); done
  cron_render 0 6 1 "Mon Tue Wed Thu Fri Sat Sun"; dow=$CRON_OUT
  if [ "$domstar" = 0 ] && [ "$dowstar" = 0 ]; then
    CRON_WHY="day-of-month and weekday are both set: cron runs on either, a systemd schedule only when both match. Use two jobs (one with the day of month, one with the weekday), or put * in one of the two fields"
    return 1
  fi
  CRON_CAL="*-$mon-$dom $h:$mi:00"
  [ "$dow" = '*' ] || CRON_CAL="$dow $CRON_CAL"
  return 0
}
# job_sched_norm <name> <value> <file:line>: the value of a job.<name> line with a cron schedule
# written as OnCalendar (JOB_V); dies with what to write when it cannot
job_sched_norm() {
  local sched cmd
  case $2 in *'|'*) ;; *) die "$3: job.$1 needs a schedule and a command: job.$1 = daily | node scripts/$1.js";; esac
  trim_v "${2%%|*}"; sched=$TRIM; trim_v "${2#*|}"; cmd=$TRIM
  [ -n "$sched" ] || die "$3: job.$1 has no schedule before the |"
  [ -n "$cmd" ] || die "$3: job.$1 has no command after the |"
  JOB_V=$2 JOB_CRON=""
  if cron_looks_like "$sched"; then
    cron_to_cal "$sched" || die "$3: job.$1: $sched: $CRON_WHY"
    JOB_V="$CRON_CAL | $cmd" JOB_CRON=$sched   # (kept, so that tando jobs shows what was written)
  fi
}

conf_load() { # [file]; a file already loaded in this run is not read again
  local f=${1:-tando.conf} line k v n=0 x
  [ -f "$f" ] || return 1
  [ "${CONF_LOADED:-}" = "$f" ] && return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case $line in
      ""|"#"*) continue;;
      *=*) ;;
      *) die "$f:$n: expected key = value";;
    esac
    trim_v "${line%%=*}"; k=$TRIM; trim_v "${line#*=}"; v=$TRIM
    case $k in
      app) C_app=$v;;
      host) C_host=$v;;
      recipe) C_recipe=$v
        case $v in node|next|static|python|container) ;;
          *) die "$f:$n: recipe must be node, next, static, python or container (got \"$v\")";; esac;;
      build) C_build=$v;;
      out) C_out=$v   # inside the project: a tando.conf cannot publish files from elsewhere
        case /$v/ in //*|*/../*) die "$f:$n: out must be a directory inside the project (got \"$v\")";; esac;;
      start) C_start=$v;;
      start_shell) C_start_shell=$v;;
      release) C_release=$v
        [ -n "$v" ] || die "$f:$n: release is a command, like node scripts/migrate.js";;
      release_shell) C_release_shell=$v
        case $v in true|false) ;; *) die "$f:$n: release_shell must be true or false (got \"$v\")";; esac;;
      release_timeout) C_release_timeout=$v
        ui_int "$v" && [ "$v" -ge 1 ] && [ "$v" -le 3600 ] || die "$f:$n: release_timeout is 1 to 3600 seconds (got \"$v\")";;
      health) C_health=$v;;
      memory) C_memory=$v;;
      cpu) C_cpu=$v
        case $v in [1-9]%|[1-9][0-9]%|[1-9][0-9][0-9]%|[0-9]|[0-9].[0-9]|[0-9].[0-9][0-9]|[1-9][0-9]|[1-9][0-9].[0-9]) ;;
          *) die "$f:$n: cpu is a share like 50% or cores like 1.5 (got \"$v\")";; esac;;
      tasks) C_tasks=$v
        ui_int "$v" && [ "$v" -ge 10 ] && [ "$v" -le 999999 ] || die "$f:$n: tasks is 10 to 999999 processes and threads (got \"$v\")";;
      max_conns) C_max_conns=$v
        ui_int "$v" && [ "$v" -ge 1 ] && [ "$v" -le 99999 ] || die "$f:$n: max_conns is 1 to 99999 connections (got \"$v\")";;
      max_requests) C_max_requests=$v
        ui_int "$v" && [ "$v" -ge 1 ] || die "$f:$n: max_requests is a number of requests in flight (got \"$v\")";;
      hold) C_hold=$v
        ui_int "$v" && [ "$v" -ge 1 ] && [ "$v" -le 999 ] || die "$f:$n: hold is 1 to 999 seconds (got \"$v\")";;
      stop_timeout) C_stop_timeout=$v
        ui_int "$v" && [ "$v" -ge 1 ] && [ "$v" -le 999 ] || die "$f:$n: stop_timeout is 1 to 999 seconds (got \"$v\")";;
      assets) C_assets=$v
        case $v in off) ;;
          *[!A-Za-z0-9_./,\ ~-]*|""|/*|*..*) die "$f:$n: assets is off, or a directory in the release like assets and optionally the URL prefix: assets, /static/ (got \"$v\")";; esac
        [ "$C_recipe" != container ] || [ "$v" = off ] || die "$f:$n: assets is not supported for a container app (its files are inside the image)";;
      health_timeout) C_timeout=$v;;
      soak) C_soak=$v; is_num "$v" || die "$f:$n: soak is seconds (got \"$v\")";;
      path) C_path=$v;;
      data) C_data=$v;;
      writable) C_writable=$v;;
      backup) C_backup=$v;;
      database) C_database=$v;;
      log_max|log_keep|log_rate|access_log|request_log_max|health_expect|health_fails|health_recover|\
      db_statement_timeout|db_idle_tx_timeout|db_temp_limit)
        conf_chk_extra "$k" "$v" || die "$f:$n: $CHK_MSG (got \"$v\")"
        C_logs="$C_logs$k=$v
";;
      image) C_image=$v;;
      container_port) C_container_port=$v;;
      build_memory) C_build_memory=$v;;
      dockerfile) C_dockerfile=$v;;
      node) C_node=$v
        case $v in [0-9][0-9]) ;; *) die "$f:$n: node is a major version, like 24 (got \"$v\")";; esac;;
      domain) # host names before they go anywhere (the server checks them again)
        case $v in *[!abcdefghijklmnopqrstuvwxyz0123456789.,\ -]*) die "$f:$n: not a domain name: $v (lowercase, like shop.example.org)";; esac
        C_domain=$(printf '%s' "$v" | tr ',' ' ' | tr -s ' ')
        for x in $C_domain; do
          case $x in
            .*|*.|*..*|-*|*-|*-.*|*.-*) die "$f:$n: not a domain name: $x (lowercase, like shop.example.org)";;
            *.*) ;;
            *) die "$f:$n: not a domain name: $x (lowercase, like shop.example.org)";;
          esac
        done;;
      www) C_www=$v
        case $v in redirect|serve|off) ;; *) die "$f:$n: www must be redirect, serve or off";; esac;;
      job_timeout) C_job_timeout=$v
        ui_int "$v" && [ "$v" -ge 1 ] && [ "$v" -le 86400 ] || die "$f:$n: job_timeout is 1 to 86400 seconds (got \"$v\")";;
      job_spread) C_job_spread=$v
        ui_int "$v" && [ "$v" -le 3600 ] || die "$f:$n: job_spread is 0 to 3600 seconds (got \"$v\")";;
      job_missed) C_job_missed=$v
        case $v in run|skip) ;; *) die "$f:$n: job_missed is run or skip (got \"$v\")";; esac;;
      job.*.timeout|job.*.spread|job.*.missed)
        case $k in
          *.timeout) ui_int "$v" && [ "$v" -ge 1 ] && [ "$v" -le 86400 ] || die "$f:$n: $k is 1 to 86400 seconds (got \"$v\")";;
          *.spread) ui_int "$v" && [ "$v" -le 3600 ] || die "$f:$n: $k is 0 to 3600 seconds (got \"$v\")";;
          *) case $v in run|skip) ;; *) die "$f:$n: $k is run or skip (got \"$v\")";; esac;;
        esac
        C_jobs="$C_jobs$k=$v
";;
      job.*) job_sched_norm "${k#job.}" "$v" "$f:$n"
        C_jobs="$C_jobs$k=$JOB_V
${JOB_CRON:+$k.cron=$JOB_CRON
}";;
      worker.*.memory|worker.*.stop_timeout|worker.*)   # processes beside the web one (the server checks them again)
        x=${k#worker.}; x=${x%%.*}
        case $x in [a-z]*) ;; *) die "$f:$n: bad worker name: $x (it starts with a lower case letter)";; esac
        case $x in *[!a-z0-9-]*) die "$f:$n: bad worker name: $x (lower case letters, digits and -)";; esac
        [ ${#x} -le 21 ] || die "$f:$n: worker name $x is longer than 21 characters"
        case $k in
          worker.*.memory) case $v in [1-9]*K|[1-9]*M|[1-9]*G) ui_int "${v%?}" || die "$f:$n: $k is a size like 256M (got \"$v\")";;
                             *) die "$f:$n: $k is a size like 256M (got \"$v\")";; esac;;
          worker.*.stop_timeout) ui_int "$v" && [ "$v" -ge 1 ] && [ "$v" -le 3600 ] || die "$f:$n: $k is 1 to 3600 seconds (got \"$v\")";;
          worker.*.*) die "$f:$n: unknown key: $k (a worker has .memory and .stop_timeout)";;
          *) [ -n "$v" ] || die "$f:$n: $k is a command, like node worker.js";;
        esac
        C_workers="$C_workers$k=$v
";;
      *) die "$f:$n: unknown key: $k";;
    esac
  done < "$f"
  # the release command: where it can run, and no shell syntax without a shell (it would reach
  # the program as literal words: a migration run with the wrong arguments)
  if [ -n "$C_release" ]; then
    case $C_recipe in
      static) die "$f: release is not supported for a static site: it has no process to run a command as (a build step belongs in build =)";;
      container) die "$f: release is not supported for recipe = container: run the migration in the image's entrypoint, before the server starts";;
    esac
    [ "$C_release_shell" = true ] || case $C_release in
      *['|&;<>$`"()*?~{}#'\'\\]*) die "$f: release has shell syntax (quotes, &&, |, \$VAR ...) but runs without a shell:" \
        "set release_shell = true to run it with sh -c, or put it in a script";;
    esac
  elif [ -n "$C_release_shell$C_release_timeout" ]; then
    die "$f: release_shell and release_timeout need release = <command>"
  fi
  # a job's setting needs the job
  local jt
  for jt in $(printf '%s' "$C_jobs" | sed -n 's/^\(job\.[^=.]*\)\.[a-z]*=.*/\1/p'); do
    printf '%s' "$C_jobs" | grepq "^$jt=" || die "$f: $jt.* is set but there is no $jt = <schedule> | <command>"
  done
  # workers: where they can run, their settings need them, a job has another name
  if [ -n "$C_workers" ]; then
    case $C_recipe in
      static) die "$f: workers are not supported for a static site: it has no process (recipe = static)";;
      container) die "$f: workers are not supported for recipe = container yet: run the process in its own app";;
    esac
    for jt in $(printf '%s' "$C_workers" | sed -n 's/^worker\.\([^.=]*\)\.[a-z_]*=.*/\1/p'); do
      printf '%s' "$C_workers" | grepq "^worker\.$jt=" || die "$f: worker.$jt.* is set but there is no worker.$jt = <command>"
    done
    for jt in $(printf '%s' "$C_workers" | sed -n 's/^worker\.\([^.=]*\)=.*/\1/p'); do
      printf '%s' "$C_jobs" | grepq "^job\.$jt=" && die "$f: worker $jt has the name of a job: give one of them another name"
    done
  fi
  CONF_LOADED=$f
  return 0
}

# resolve need_app: -a/-H win over tando.conf; a single registered host is the default
resolve() {
  if [ -n "${RESOLVED:-}" ]; then   # a second call (one command calling another): same answer
    [ "$1" = 1 ] && [ -z "$APP" ] && no_conf
    return 0
  fi
  RESOLVED=1
  if [ -z "$APP" ] && conf_load 2> /dev/null; then APP=$C_app; fi
  # CI: a deploy key from the environment instead of a registered host (lib/cmd-ci.sh)
  if [ -n "${TANDO_DEPLOY_KEY:-}" ] && [ -z "$HOST" ]; then
    DEPLOY_KEY=1
    . "$TANDO_HOME/lib/cmd-ci.sh"; ci_key_resolve; return
  fi
  [ -z "$HOST" ] && HOST=$C_host
  if [ -z "$HOST" ]; then
    set -- "$1" "$CFG"/hosts/*
    [ $# -eq 2 ] && [ -f "$2" ] && HOST=${2##*/}
  fi
  if [ -z "$HOST" ]; then
    local hs="" f
    for f in "$CFG"/hosts/*; do [ -f "$f" ] && hs="${hs:+$hs, }${f##*/}"; done
    [ -n "$hs" ] || die "no server registered yet: tando go <user@address> sets one up (or tando host add <name> <user@address>)"
    [ -f tando.conf ] || die "which server? pass -H <name> (servers: $hs)"
    die "$(printf '%s' "$hs" | tr ',' '\n' | grep -c .) servers are registered ($hs):" \
      "add  host = <name>  to tando.conf, or pass -H <name>"
  fi
  host_use "$HOST"
  [ "$(cat "$CFG/last-host" 2> /dev/null)" = "$HOST" ] || { printf "%s\n" "$HOST" | write_file "$CFG/last-host"; } 2> /dev/null
  case $(host_get "$HOST" kind) in deploy) DEPLOY_KEY=1;; esac
  if [ "$1" = 1 ]; then
    [ -n "$APP" ] || no_conf
    valid_app "$APP" || die "bad app name: $APP (a-z, 0-9, -, 2-26 chars)"
  fi
}

# pick_host: tando up with 2+ servers and no host = in tando.conf: ask which one (the one used last
# is the default) and write  host = <name>  into tando.conf, so it is asked once
pick_host() {
  local hs=() f i=0 def=1 last a
  for f in "$CFG"/hosts/*; do [ -f "$f" ] && hs+=("${f##*/}"); done
  [ ${#hs[@]} -ge 2 ] || return 0
  if [ ! -t 0 ] || [ ! -t 2 ]; then
    die "${#hs[@]} servers are registered (${hs[*]}): say which with" \
      "tando up -H <name> (it is then saved in tando.conf)"
  fi
  last=$(cat "$CFG/last-host" 2> /dev/null)
  printf 'Deploy to which server?' >&2
  for f in "${hs[@]}"; do
    i=$((i + 1)); [ "$f" = "$last" ] && def=$i
    printf '  %s) %s' "$i" "$f" >&2
  done
  printf '  [%s] ' "$def" >&2
  IFS= read -r a || a=""
  [ -n "$a" ] || a=$def
  is_num "$a" && [ "$a" -ge 1 ] && [ "$a" -le ${#hs[@]} ] || die "no server number $a; nothing changed"
  HOST=${hs[$((a - 1))]}
}
# conf_set_host name: write  host = <name>  into tando.conf (after the app line)
conf_set_host() {
  awk -v h="$1" '{ print } /^app[[:space:]]*=/ && !d { print "host = " h; d = 1 } END { if (!d) print "host = " h }' \
    tando.conf > tando.conf.tando-tmp && mv tando.conf.tando-tmp tando.conf && C_host=$1 &&
    note "wrote host = $1 into tando.conf"
}

# no_conf: no app given and no tando.conf here; points at one in a parent directory
no_conf() {
  local d=$PWD c=${ARGS[0]:-status} alt
  # deploy and up upload this directory: -a cannot stand in for the project
  case $c in deploy|up) alt="";; *) alt=", or name the app: tando $c -a <app> (tando ls lists them)";; esac
  while [ "$d" != / ] && [ -n "$d" ]; do
    d=$(dirname "$d")
    [ -f "$d/tando.conf" ] && die "no tando.conf here, but $d has one: cd $d && tando $c$alt"
  done
  case $c in deploy) die "no tando.conf here: cd into your app's directory, then tando up (it writes tando.conf)";; esac
  die "no tando.conf here: cd into your app's directory$alt"
}

# ---- helpers on the server: server/<name> or a Go binary, to /opt/tando/bin/<name> -----------

# sha256_of file: its SHA-256 (shasum on macOS, sha256sum elsewhere)
# lint: allow RL02 shasum first (macOS); sha256sum only where there is no shasum (Linux, BusyBox)
sha256_of() { { shasum -a 256 "$1" 2> /dev/null || sha256sum "$1"; } | cut -d' ' -f1; }

# helper_file name cpu: the file installed as /opt/tando/bin/<name>. A shell program is
# server/<name>; a Go program (srv/cmd/<name>) is a binary per CPU (amd64, arm64): in a release or
# an install server/linux-<cpu>/<name>, in a checkout dist/server/linux-<cpu>/<name>
# (scripts/build-server.sh)
helper_file() {
  if [ -f "$TANDO_HOME/server/$1" ]; then printf '%s\n' "$TANDO_HOME/server/$1"
  elif [ -f "$TANDO_HOME/srv/go.mod" ]; then printf '%s\n' "$TANDO_HOME/dist/server/linux-$2/$1"
  else printf '%s\n' "$TANDO_HOME/server/linux-$2/$1"; fi
}

# helpers_build: in a checkout with Go, build the Go programs (a build with nothing to do takes a
# quarter of a second, and a binary older than its source would be installed otherwise)
helpers_build() {
  [ -f "$TANDO_HOME/srv/go.mod" ] && command -v go > /dev/null 2>&1 || return 0
  # (test/all.sh has built this checkout's programs once for its whole run and says so by naming
  # the checkout: its suites make some fifty host setups, each of which would build again)
  [ "${TANDO_HELPERS_BUILT:-}" = "$TANDO_HOME" ] && return 0
  "$TANDO_HOME/scripts/build-server.sh" -q 2> "$TMPD/build.err" ||
    die "could not build the server programs: $(tail -3 "$TMPD/build.err" | tr '\n' ' ')"
}

# install_helpers name...: under a host-wide lock (/opt/tando/.install.lock), so two `host setup`s
# queue instead of mixing files. One ssh call asks for the server's CPU and the checksums of what
# is installed; a second streams every helper that differs (Go binaries are megabytes; unchanged
# ones are not sent again). Each file is staged as /opt/tando/bin/.<name>.new (root, 600 from
# creation) and checked against the size and SHA-256 computed here, then a script with bash -n and
# a binary by running `<binary> version`. Only when every one is good does the switch start
# (tando-adopt 644, sourced by the agent; the others 755), and the programs call each other, so it
# must not end half done. The choice, and why:
#   - A symlink flip (/opt/tando/bin -> bin.<id>) would be atomic, but /opt/tando/bin is a real
#     directory on every installed server that sudoers rules, units and sshd config name by path;
#     turning a live directory into a symlink is itself not atomic (rename over a non-empty
#     directory is refused, so there is a moment with no directory) and it breaks a server where
#     only one helper is installed on demand. Rejected.
#   - So the files stay where they are and the switch is made crash-safe: every staged file gets
#     its final owner and mode and is fsynced, each file being replaced is hard-linked to
#     .<name>.old, a journal (.install.pending: name mode sum had_old) is written whole and renamed
#     into place, then one rename(2) per file (a running program never sees a half-written file),
#     then the journal is dropped. A kill, a full disk or a failed rename between renames leaves
#     the journal; a failed rename is rolled back at once from the .old links, and the next
#     install_helpers (any `host setup`, or `tando adopt` / `ci setup` on demand) completes the
#     switch when every staged file is still there and has its checksum, else restores the old
#     files. `tando doctor` fails while a journal exists and warns for each file that differs.
install_helpers() {
  local n f a=() m cpu="" kind send=() l sum
  helpers_build
  # shellcheck disable=SC2029
  # lint: allow RL04 the names are the callers' constants (tando-<word>)
  ssh "${SSHO[@]}" "$TARGET" "echo arch=\$(uname -m); cd /opt/tando/bin 2> /dev/null && sha256sum -- $* 2> /dev/null; true" \
    > "$TMPD/probe" 2> "$TMPD/err" || return 1
  l=$(strip < "$TMPD/probe")
  case $l in *arch=x86_64*) cpu=amd64;; *arch=aarch64*|*arch=arm64*) cpu=arm64;; esac
  [ -n "$cpu" ] || { printf 'tando runs on x86_64 and aarch64 servers, not %s\n' \
    "$(printf '%s\n' "$l" | sed -n 's/^arch=//p')" > "$TMPD/err"; return 1; }
  for n; do
    f=$(helper_file "$n" "$cpu")
    if [ ! -r "$f" ]; then
      case $f in
        */dist/server/*) die "missing $f: build it with scripts/build-server.sh (needs Go, see srv/README.md)";;
        *) die "missing $f";;
      esac
    fi
    m=755; [ "$n" = tando-adopt ] && m=644
    kind=script; [ "$f" = "$TANDO_HOME/server/$n" ] || kind=binary
    sum=$(sha256_of "$f")
    if printf '%s\n' "$l" | grepq -xF "$sum  $n"; then
      a+=("$n" - "$sum" "$m" "$kind")
    else
      a+=("$n" "$(wc -c < "$f" | tr -d ' ')" "$sum" "$m" "$kind"); send+=("$f")
    fi
  done
  # shellcheck disable=SC2016,SC2029
  # lint: allow RL04 names are fixed, sizes and sums are computed here from the tree
  for f in ${send[@]+"${send[@]}"}; do cat "$f"; done | ssh "${SSHO[@]}" "$TARGET" "sudo -n bash -c '$(install_helpers_script)' _ ${a[*]}" 2> "$TMPD/err"
  m=${PIPESTATUS[1]}   # ssh's status (the server checks that every byte arrived)
  # killed or disconnected (not one of the script's own messages): it may have stopped between renames
  if [ "$m" -ge 128 ] && [ ${#send[@]} -gt 0 ]; then
    printf 'tando: the install on %s was cut off and may have stopped between files, so some programs may be old and some new: tando host setup %s finishes or undoes it (tando doctor %s shows what differs)\n' \
      "$HOST" "$HOST" "$HOST" >> "$TMPD/err"
  fi
  # (an earlier cut-off install was finished or undone first: say so)
  # (a repair at the start of the script can change a file the probe saw as current: once more)
  if [ "$m" = 1 ] && [ -z "${IH_RETRY:-}" ] && grepq 'changed on the server during the install' "$TMPD/err"; then
    IH_RETRY=1 install_helpers "$@"; return $?
  fi
  [ "$m" = 0 ] && grepq '^note=' "$TMPD/err" && note "$HOST: $(sed -n 's/^note=//p' "$TMPD/err" | head -1)"
  return "$m"
}
install_helpers_script() { # the server side (bash 5); no single quotes in it (not even in comments)
  cat <<'EOS'
install -d -m 755 /opt/tando /opt/tando/bin || exit 1   # (before the umask: a new /opt/tando must be 755)
umask 077; set -u
exec 9> /opt/tando/.install.lock
flock -w 300 9 || { echo "another tando host setup has been installing for 5 minutes; try again" >&2; exit 1; }
tmps=(); names=(); modes=(); sums=(); olds=(); keep=(); keepm=(); all=" "
fail() { rm -f "${tmps[@]}"; echo "$*" >&2; exit 1; }
EOS
  # the recovery code is server/tando-install-recover (the same file runs at boot and before agent verbs)
  sed -n '/^# >>> shared/,/^# <<< shared/p' "$TANDO_HOME/server/tando-install-recover"
  cat <<'EOS'
if [ -f "$J" ]; then   # an earlier install was cut off between renames: finish it or undo it
  recover || fail "run tando host setup again once that is fixed"
  echo "note=$RECOVERED" >&2
fi
rm -f "$B"/.*.new "$B"/.*.old "$J.tmp"   # (staged copies of an install that never reached its journal)
while [ $# -ge 5 ]; do
  n=$1 sz=$2 sum=$3 m=$4 kind=$5; shift 5; all="$all$n "
  if [ "$sz" = - ]; then   # not sent: the client saw this checksum installed; it still must be
    [ "$(sha "$B/$n")" = "$sum" ] ||
      fail "$n changed on the server during the install; run tando host setup again"
    keep+=("$n"); keepm+=("$m"); continue
  fi
  t=$B/.$n.new
  tmps+=("$t"); names+=("$n"); modes+=("$m"); sums+=("$sum")
  head -c "$sz" > "$t" || fail "could not write $t (disk full?)"
  [ "$(stat -c %s "$t")" = "$sz" ] || fail "$n arrived incomplete ($(stat -c %s "$t") of $sz bytes)"
  [ "$(sha "$t")" = "$sum" ] || fail "$n arrived damaged (checksum differs)"
  case $kind in
    script) bash -n "$t" 2> /dev/null || fail "$n does not parse (bash -n)";;
    *) chmod 700 "$t" && timeout 20 "$t" version > /dev/null 2>&1 ||
         fail "$n does not run on this server ($(uname -m)): $n version failed";;
  esac
done
# Everything is verified. The switch: final owner and mode on every staged file, the data on disk,
# a hard link .name.old to each file being replaced, then the journal (written whole and renamed,
# so it is there complete or not at all), then one rename per file. Killed anywhere, the next
# install finishes or undoes it from the journal; before the journal nothing in place has changed.
for i in "${!tmps[@]}"; do
  chown root:root "${tmps[i]}" && chmod "${modes[i]}" "${tmps[i]}" || fail "could not set the mode of ${names[i]}"
  if [ -e "$B/${names[i]}" ]; then
    ln -f "$B/${names[i]}" "$B/.${names[i]}.old" || fail "could not keep a copy of ${names[i]}"; olds[i]=1
  else olds[i]=0; fi
done
if [ ${#tmps[@]} -gt 0 ]; then
  sync "${tmps[@]}" 2> /dev/null || sync
  for i in "${!tmps[@]}"; do echo "${names[i]} ${modes[i]} ${sums[i]} ${olds[i]}"; done > "$J.tmp" ||
    fail "could not write the install journal (disk full?)"
  sync "$J.tmp" 2> /dev/null || sync
  mv -f "$J.tmp" "$J" || fail "could not write the install journal"
  sync "$B" 2> /dev/null || sync
  trap "" HUP PIPE INT TERM   # a dropped connection must not cut the renames short
  for i in "${!tmps[@]}"; do
    if ! mv -f "${tmps[i]}" "$B/${names[i]}"; then
      bad=${names[i]}; tmps=()
      if rollback; then finish; fail "could not move $bad into place: every file is back to its old version"
      else fail "could not move $bad into place and the old versions could not be restored ($(mixed)): run tando host setup again"; fi
    fi
  done
  sync "$B" 2> /dev/null || sync
  finish
fi
for i in "${!keep[@]}"; do   # (an unchanged file still gets its owner and mode)
  chown root:root "$B/${keep[i]}" && chmod "${keepm[i]}" "$B/${keep[i]}" ||
    fail "could not set the mode of ${keep[i]}"
done
# a full set (the agent and tando-status together) is installed and consistent: record it, so the
# agent may hand its read verbs to tando-status (an install of one helper on demand does not)
case $all in *" tando-agent "*" tando-status "*|*" tando-status "*" tando-agent "*) manifest_refresh;; esac
EOS
}

# ---- agent calls: argv tokens are checked here; free text only travels on stdin -----------

# agent_raw [sudo] verb args...: stdout and stderr are stripped of control characters
agent_raw() {
  local s="" a rc
  [ "$1" = sudo ] && { s="sudo -n "; shift; }
  for a in "$@"; do
    case $a in ""|*[!A-Za-z0-9_.:=/@,+-]*) die "internal: unsafe argument '$a'";; esac
  done
  local try=0
  while :; do
    ssh "${SSHO[@]}" "$TARGET" "$s$AGENT_BIN $*" 2> "${ERRF:-$TMPD/err}" | strip
    rc=${PIPESTATUS[0]}
    # the server turned the session away before the command started (sshd MaxSessions on the
    # shared connection, or MaxStartups): nothing ran, so trying again is safe for every verb
    [ "$rc" = 255 ] && [ $try -lt 3 ] && ssh_busy "${ERRF:-$TMPD/err}" || break
    try=$((try + 1))
    sleep "0.$((RANDOM % 8 + 2))$try"
  done
  if [ "$rc" != 0 ] && ssh_explain "${ERRF:-$TMPD/err}"; then return "$rc"; fi
  [ -s "${ERRF:-$TMPD/err}" ] && agent_msgs < "${ERRF:-$TMPD/err}" >&2
  return "$rc"
}

# ssh_busy errfile: the server refused a session before the command started
ssh_busy() { grep -qE 'Session open refused by peer|kex_exchange_identification|MaxStartups' "$1" 2> /dev/null; }

# the agent's messages as the user's: "tando-agent: x" reads "tando: x", <host> is the host's
# name, and "no such app" names the way out
agent_msgs() {
  strip | sed -E -e 's/^tando-(agent|logs|watch|gate|metrics|adopt): /tando: /' -e "s/<host>/$HOST/g" \
    -e "s/^tando: no such app: ([a-z0-9-]+)\$/tando: no app \"\\1\" on $HOST (tando ls -H $HOST lists them; tando up creates it)/" \
    -e "s/^tando: (unknown verb|unknown setting: (check|origin|force)).*/tando: the tando agent on $HOST is older than this client: tando host setup $HOST updates it/"
}

# ---- failures of ssh, sudo and a missing agent, in one sentence with the next step ----------

explain() { # message hint...: "tando: message." and each hint indented below
  local h   # (a caller's $h, such as fetch_hosts' host name, must survive)
  printf 'tando: %s\n' "$1" >&2; shift
  for h; do printf '  %s\n' "$h" >&2; done
}
explain_sudo() {
  explain "$TARGET cannot use sudo without a password, and tando needs it on $HOST" \
    "on the server run:  echo '${TARGET%@*} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/tando"
}
# ssh_explain errfile: explains a known failure (and returns 0), else returns 1
ssh_explain() {
  local e port k addr=${TARGET#*@} who=${TARGET%@*}
  e=$(strip < "$1" 2> /dev/null | grep . | tail -4)
  port=$(host_get "$HOST" port 2> /dev/null); port=${port:-22}
  case $e in
    *"Session open refused by peer"*)
      explain "too many tando commands at once to $HOST (the server allows 10 ssh sessions per connection)" \
        "run fewer at once, or raise MaxSessions in the server's /etc/ssh/sshd_config";;
    *"kex_exchange_identification"*|*"MaxStartups"*)
      explain "$HOST closed the connection during login: too many logins at once (sshd MaxStartups), or sshd is overloaded" \
        "run fewer tando commands at once; if it keeps happening: tando doctor $HOST";;
    *"connect to host "*"Connection refused"*)   # (ssh's own line: a command's "Connection refused" is its own)
      explain "cannot reach $HOST ($TARGET, port $port): connection refused" \
        "is sshd listening on that port? check with: ssh -p $port $TARGET" \
        "another port: tando host add $HOST $TARGET --port N --force";;
    *"Could not resolve hostname"*|*"nodename nor servname"*|*"Name or service not known"*)
      explain "cannot reach $HOST: the name $addr does not resolve" \
        "check the spelling, or use the IP address: tando host add $HOST $who@<ip> --force";;
    *"timed out"*|*"No route to host"*|*"Network is unreachable"*|*"Connection closed by remote host"*)
      explain "cannot reach $HOST ($addr, port $port): no answer within 5 s" \
        "is the server up, and is port $port open in its firewall? (you may be offline)";;
    *"REMOTE HOST IDENTIFICATION HAS CHANGED"*)
      explain "the host key of $HOST CHANGED since you trusted it: someone may be in the middle" \
        "if the server was reinstalled: ssh-keygen -R '[$addr]:$port' -f $CFG/known_hosts, then tando host add $HOST $TARGET --port $port --force";;
    *"Host key verification failed"*|*"host key is known"*|*"No matching host key"*)
      explain "the host key of $HOST is not trusted yet" \
        "tando host add $HOST $TARGET --port $port --force  shows its fingerprint and asks";;
    *"Permission denied"*|*"Too many authentication failures"*)
      if [ -n "${TANDO_DEPLOY_KEY:-}" ]; then
        explain "$HOST refused the deploy key ($TARGET): it was revoked, or is for another app or server" \
          "make a new one: tando ci setup, in the app's directory on your laptop (then update the CI secrets)"
        return 0
      fi
      k=$(host_get "$HOST" key 2> /dev/null || true)
      explain "$HOST refused the login $TARGET${k:+ (key $k)}" \
        "add your public key to ~$who/.ssh/authorized_keys on the server, or pick a key: tando host add $HOST $TARGET$( [ "$port" = 22 ] || printf ' --port %s' "$port") --key ~/.ssh/<key> --force";;
    *"a password is required"*|*"a terminal is required"*|*"no tty present"*) explain_sudo;;
    *"tando-agent: No such file"*|*"tando-agent: command not found"*|*"tando-gate: No such file"*)
      explain "$HOST is reachable but not set up for tando yet" "tando host setup $HOST";;
    *"mux_client"*|*"Broken pipe"*|*"Connection reset"*|*"Connection to "*" closed"*)
      explain "lost the connection to $HOST" "try again; if it keeps happening: tando doctor $HOST";;
    *) return 1;;
  esac
  return 0
}
agent() { agent_raw "$@" || bail 1; }

# kv_read file keys...: sets K_<key> for each whitelisted key found in key=value output
kv_read() {
  local f=$1 k v w l
  shift
  for w; do printf -v "K_$w" '%s' ""; done
  while IFS= read -r l; do   # (IFS='=' read drops a trailing "=")
    case $l in *=*) ;; *) continue;; esac
    k=${l%%=*} v=${l#*=}
    for w; do [ "$k" = "$w" ] && printf -v "K_$w" '%s' "$v"; done
  done < "$f"
}

# checksum of the local agent; `doctor` compares it with the installed one
agent_sum() { cksum < "$TANDO_HOME/server/tando-agent" | cut -d' ' -f1; }
# checksums of the agent, gate, logs helper, metrics sampler and alert checks (or of the programs
# named), as doctor expects them; a Go program has one binary per CPU, so its word lists both
# ("123,456": either is current)
server_sums() {
  local n c s f k
  [ $# -gt 0 ] || set -- tando-agent tando-gate tando-logs tando-metrics tando-watch
  for n; do
    s=""
    for c in amd64 arm64; do
      f=$(helper_file "$n" "$c")
      [ -r "$f" ] || continue
      k=$(cksum < "$f" | cut -d' ' -f1)
      case ,$s, in *,$k,*) ;; *) s=${s:+$s,}$k;; esac   # (a shell program is one file for both)
    done
    printf '%s ' "${s:-none}"
  done
}

# open_url url: in the browser (macOS open; xdg-open with a display); 1 when there is none or
# TANDO_NO_BROWSER=1 (tando open, tando db studio)
open_url() {
  [ -z "${TANDO_NO_BROWSER:-}" ] || return 1
  if [ "$(uname)" = Darwin ] && command -v open > /dev/null; then
    open "$1" > /dev/null 2>&1
  elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open > /dev/null; then
    xdg-open "$1" > /dev/null 2>&1
  else return 1; fi
}
