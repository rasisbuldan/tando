# lib/cmd-logx.sh: `tando logs` with filters, follow that reconnects, and `logs pull`.
# Sourced by bin/tando (cmd_logs calls logx_logs). bash 3.2.
#
#   tando logs [-n N] [-f] [--since T] [--until T] [--grep TEXT [--regex] [-i]] [--level L]
#              [--release ID | --deploy ID] [--worker NAME] [--json]
#   tando logs pull <file> [--since T] [--until T] [--grep ...] [--level L] [--json]
#
# T is relative (30s, 15m, 2h, 7d, 1w), absolute in GMT, as the lines are shown (2026-11-13,
# "2026-11-13 14:30", 2026-11-13T14:30:05, 14:30 = today), or @<epoch>.
# The query travels to the server as key=value lines on stdin (never in the ssh command line);
# the server checks every key and value, builds the journalctl argv itself and hands the pattern
# to awk through the environment. Lines come back with control characters already shown as ^X;
# they are filtered again here before reaching the terminal.

cmd_logx() { logx_logs; }

# relative or absolute time -> "-<seconds>" or "@<epoch>"
lx_time() {
  local v=$1 n u m d=""
  case $v in
    @[0-9]*) is_num "${v#@}" && printf '%s' "$v"; return;;
    now) printf -- '-0'; return;;
    [0-9]*[smhdw])
      n=${v%?} u=${v#"$n"}
      is_num "$n" || return 1
      case $u in s) m=1;; m) m=60;; h) m=3600;; d) m=86400;; w) m=604800;; esac
      printf -- '-%s' $((n * m)); return;;
  esac
  v=$(printf '%s' "$v" | tr 'T' ' ')
  case $v in
    [0-9][0-9]:[0-9][0-9]) v="$(date -u +%Y-%m-%d) $v:00";;
    [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) v="$(date -u +%Y-%m-%d) $v";;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) v="$v 00:00:00";;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]) v="$v:00";;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
    *) return 1;;
  esac
  # in GMT, the zone the lines are shown in
  d=$(TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "$v" +%s 2> /dev/null) || d=$(TZ=UTC date -d "$v" +%s 2> /dev/null) || return 1
  is_num "$d" && printf '@%s' "$d"
}

lx_level() {
  case $1 in
    emerg) echo 0;; alert) echo 1;; crit|fatal) echo 2;; err|error) echo 3;;
    warning|warn) echo 4;; notice) echo 5;; info) echo 6;; debug) echo 7;; *) return 1;;
  esac
}

# last line of defence before the terminal: no C0/C1 control characters, whatever the server sent
lx_clean() {
  LC_ALL=C awk '{ gsub(/[\001-\010\013-\037\177]/, ""); gsub(/\302[\200-\237]/, "?")
    gsub(/\342\200[\216\217\252-\256]|\342\201[\246-\251]|\330\234/, ""); print; fflush() }'
}

lx_ssh() { # spec file
  valid_app "$APP" || die "bad app name: $APP (a-z, 0-9, -; 2-24 characters)"   # it goes into the remote command line
  # shellcheck disable=SC2029
  # lint: allow RL04 AGENT_BIN is a constant and APP was checked just above
  ssh "${SSHO[@]}" "$TARGET" "sudo -n $AGENT_BIN logs $APP spec" < "$1" 2> "$TMPD/lx.err"
}
lx_refused() { # the server refused the query (as opposed to a lost connection)
  grep -Eq '^tando-(logs|agent|gate):' "$TMPD/lx.err" 2> /dev/null   # -E: BSD grep has no \| in BREs
}
lx_err() { strip < "$TMPD/lx.err" | sed -En 's/^tando-(logs|agent|gate): //p' | tail -3; }   # -E: BSD sed

logx_logs() {
  resolve 1
  local i=1 a v nl='
' fmt=text since="" until="" grep="" mode=fixed icase="" level="" rel="" dep="" wk="" pull="" spec n
  while [ "$i" -lt "${#ARGS[@]}" ]; do
    a=${ARGS[$i]} v=${ARGS[$((i + 1))]:-}
    case $a in
      pull) [ "$i" = 1 ] && [ -n "$v" ] || die "usage: tando logs pull <file> [--since T] [--until T]"
            pull=$v; i=$((i + 2));;
      --since) since=$(lx_time "$v") || die "bad --since: $v (15m, 2h, 7d, 2026-11-13 14:30, @epoch)"; i=$((i + 2));;
      --until) until=$(lx_time "$v") || die "bad --until: $v"; i=$((i + 2));;
      --grep) [ -n "$v" ] || die "--grep needs a text"; grep=$v; i=$((i + 2));;
      --regex|-E) mode=regex; i=$((i + 1));;
      -i) icase=i; i=$((i + 1));;
      --level) level=$(lx_level "$v") || die "bad --level: $v (err, warning, notice, info, debug)"; i=$((i + 2));;
      --release) valid_id "$v" || die "bad release id: $v"; rel=$v; i=$((i + 2));;
      --deploy) valid_id "$v" || die "bad release id: $v"; dep=$v; i=$((i + 2));;
      --worker) case $v in [a-z]*) ;; *) die "bad worker name: $v";; esac
                case $v in *[!a-z0-9-]*) die "bad worker name: $v";; esac
                wk=$v; i=$((i + 2));;
      --json) fmt=json; i=$((i + 1));;   # (kept in ARGS for plugins by bin/tando)
      *) die "logs: unknown argument: $a";;
    esac
  done
  case $grep in *"$nl"*) die "--grep cannot contain a newline";; esac
  [ ${#grep} -le 256 ] || die "--grep is limited to 256 characters"
  if LC_ALL=C printf '%s' "$grep" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    die "--grep cannot contain control characters"
  fi
  [ -n "$rel" ] && [ -n "$dep" ] && die "--release and --deploy cannot be combined"
  [ -n "$wk" ] && [ -n "$dep" ] && die "--worker and --deploy cannot be combined"
  [ -n "$FOLLOW" ] && [ -n "$rel$pull" ] && die "-f cannot be combined with --release or pull"
  n=$NLINES
  [ -n "$pull" ] && n=all
  spec=$TMPD/lx.spec
  {
    printf 'n=%s\nformat=%s\ntz=+0000\n' "$n" "$fmt"   # times in GMT, like every table
    [ -n "$since" ] && printf 'since=%s\n' "$since"
    [ -n "$until" ] && printf 'until=%s\n' "$until"
    [ -n "$grep" ] && printf 'grep=%s\ngrep_mode=%s%s\n' "$grep" "$icase" "$mode"
    [ -n "$level" ] && printf 'level=%s\n' "$level"
    [ -n "$rel" ] && printf 'release=%s\n' "$rel"
    [ -n "$dep" ] && printf 'deploy=%s\n' "$dep"
    [ -n "$wk" ] && printf 'worker=%s\n' "$wk"
  } > "$spec"
  # on a terminal, say which clock the lines use (never into a pipe or a pulled file)
  [ -z "$pull" ] && [ "$fmt" = text ] && [ -t 1 ] && printf '%s# times in GMT (UTC)%s\n' "$UI_DIM" "$UI_NC"
  if [ -n "$pull" ]; then lx_pull "$pull"
  elif [ -n "$FOLLOW" ]; then lx_follow
  else
    lx_ssh "$spec" | lx_clean
    [ "${PIPESTATUS[0]}" = 0 ] || die "logs: $(lx_err | tr '\n' ' ')"
  fi
}

lx_pull() { # file
  local f=$1 lines rc
  [ -e "$f" ] && die "$f exists"
  lx_ssh "$TMPD/lx.spec" | lx_clean > "$f"
  rc=${PIPESTATUS[0]}
  if [ "$rc" != 0 ]; then rm -f "$f"; die "pull failed: $(lx_err | tr '\n' ' ')"; fi
  lines=$(wc -l < "$f" | tr -d ' ')
  note "wrote $f: $lines lines, $(ui_bytes "$(wc -c < "$f" | tr -d ' ')")"
}

# -f: every line carries its journal cursor; when the connection drops, reconnect and resume
# after the last line shown, so nothing is repeated or lost while the journal still holds it.
lx_follow() {
  local cf=$TMPD/lx.cursor run=$TMPD/lx.run rc wait=1 t0
  : > "$cf"
  printf 'follow=1\ncursor=1\n' >> "$TMPD/lx.spec"
  while :; do
    cp "$TMPD/lx.spec" "$run"
    [ -s "$cf" ] && printf 'after=%s\n' "$(cat "$cf")" >> "$run"
    t0=$(date +%s)
    lx_ssh "$run" | LC_ALL=C awk -v cf="$cf" '
      { p = index($0, "\t"); if (p == 0) line = $0; else { last = substr($0, 1, p - 1); line = substr($0, p + 1) }
        gsub(/[\001-\010\013-\037\177]/, "", line); gsub(/\302[\200-\237]/, "?", line)
        gsub(/\342\200[\216\217\252-\256]|\342\201[\246-\251]|\330\234/, "", line); print line; fflush()
        if (last != "") { print last > cf; close(cf) } }'
    rc=${PIPESTATUS[0]}
    if lx_refused; then die "logs: $(lx_err | tr '\n' ' ')"; fi
    [ $(( $(date +%s) - t0 )) -gt 30 ] && wait=1
    note "tando: log stream ended (exit status $rc); reconnecting in ${wait}s (Ctrl-C to stop)"
    sleep "$wait"
    wait=$((wait * 2)); [ "$wait" -gt 30 ] && wait=30
  done
}
