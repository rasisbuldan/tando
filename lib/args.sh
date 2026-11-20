# lib/args.sh: help and argument checks for every command, from lib/help.txt. Nothing runs before
# the arguments of a command were checked: `<command> --help` only prints help, and an unknown
# flag or an extra argument is a usage error (exit 2) with the command's usage lines.

HELPF=$TANDO_HOME/lib/help.txt

# usage_err message [command]: a usage error; with a command, its usage lines follow
usage_err() {
  printf 'tando: %s\n' "$1" >&2
  if [ -n "${2:-}" ] && spec_has "$2"; then
    help_usage "$2" >&2
    printf 'tando help %s for details\n' "$2" >&2
  fi
  exit 2
}

# One read of help.txt per run: the command list and each command's flags, args and subs, in
# variables (HX_<field>_<command>, dashes as underscores). No fork per lookup.
HX_CMDS=" "
help_index() {
  local c f v
  while IFS='	' read -r c f v; do
    if [ "$f" = has ]; then HX_CMDS="$HX_CMDS$c "; continue; fi
    printf -v "HX_${f}_${c//-/_}" '%s' "$v"
  done < <(awk '/^@@ / { c = $2; if (c != "overview") print c "\thas\t"; next }
    c != "" && c != "overview" && /^(flags|args|subs):/ { f = $0; sub(/:.*/, "", f); v = $0; sub(/^[a-z]+: ?/, "", v)
      print c "\t" f "\t" v }' "$HELPF")
}
help_index
spec_has() { case $HX_CMDS in *" $1 "*) return 0;; esac; return 1; }
# spec cmd field: that field of the command's section ("" when absent)
spec() { local n="HX_${2}_${1//-/_}"; printf '%s' "${!n:-}"; }
help_usage() { # the usage lines of a command
  awk -v c="$1" '/^@@ / { s = ($2 == c); next }
    s && /^usage: / { sub(/^usage: /, ""); printf "%s%s\n", (n++ ? "       " : "usage: "), $0 }' "$HELPF"
}

# the commands: help.txt sections and plugins (lib/cmd-<name>.sh), logx being the logs command
known_cmds() {
  local f n
  printf '%s\n' $HX_CMDS
  for f in "$TANDO_HOME"/lib/cmd-*.sh; do
    [ -f "$f" ] || continue
    n=${f##*/cmd-}; n=${n%.sh}
    [ "$n" = logx ] || spec_has "$n" || echo "$n"
  done
}
# (grep reads everything: -q would close the pipe early, and with pipefail a slow known_cmds
# killed by SIGPIPE turned a real command into "unknown command")
is_cmd() { spec_has "$1" || { [ -f "$TANDO_HOME/lib/cmd-$1.sh" ] && [ "$1" != logx ]; }; }

# help_glyphs: help.txt's "·" as the terminal's middle dot ("-" with TANDO_ASCII or no UTF-8)
help_glyphs() { if [ "${UI_G_MID:-}" = "·" ]; then cat; else LC_ALL=C sed "s/·/${UI_G_MID:--}/g"; fi; }
help_overview() {
  awk '/^@@ / { s = ($2 == "overview"); next } s' "$HELPF" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | help_glyphs
  local f n more=""
  # plugins without a section here, by their "# help: <usage>  <description>" lines
  for f in "$TANDO_HOME"/lib/cmd-*.sh; do
    [ -f "$f" ] || continue
    n=${f##*/cmd-}; n=${n%.sh}
    [ "$n" = logx ] || spec_has "$n" && continue
    more="${more:+$more ${UI_G_MID} }$n"
  done
  # one line (the overview fits a screen): tando help <name> shows each one's "# help:" line
  [ -n "$more" ] && printf 'Plugins    %s\n' "$more" | fold -s -w 78
  return 0
}

# command_help cmd: usage lines, then the description
command_help() {
  if ! spec_has "$1"; then
    if [ -f "$TANDO_HOME/lib/cmd-$1.sh" ]; then sed -n 's/^# help: /usage: tando /p' "$TANDO_HOME/lib/cmd-$1.sh"; return 0; fi
    unknown_cmd "$1"
  fi
  help_usage "$1"
  awk -v c="$1" '/^@@ / { s = ($2 == c); next }
    s && !/^(flags|args|subs|usage):/ { print }' "$HELPF" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' |
    { IFS= read -r l && { echo; printf '%s\n' "$l"; cat; }; } | help_glyphs
  return 0
}

# nearest word < candidates: the candidate closest to word (edit distance <= 2, a swap of two
# letters counts once; a prefix of 2+ letters counts as 1), or nothing
nearest() {
  awk -v w="$1" '
    function dist(a, b,   i, j, la, lb, d, c, x) {
      la = length(a); lb = length(b)
      for (i = 0; i <= la; i++) d[i, 0] = i
      for (j = 0; j <= lb; j++) d[0, j] = j
      for (i = 1; i <= la; i++) for (j = 1; j <= lb; j++) {
        c = (substr(a, i, 1) == substr(b, j, 1)) ? 0 : 1
        x = d[i - 1, j] + 1; if (d[i, j - 1] + 1 < x) x = d[i, j - 1] + 1
        if (d[i - 1, j - 1] + c < x) x = d[i - 1, j - 1] + c
        if (i > 1 && j > 1 && substr(a, i, 1) == substr(b, j - 1, 1) && substr(a, i - 1, 1) == substr(b, j, 1) \
            && d[i - 2, j - 2] + 1 < x) x = d[i - 2, j - 2] + 1
        d[i, j] = x
      }
      return d[la, lb]
    }
    $0 != "" { k = dist(w, $0); if (index($0, w) == 1 && length(w) >= 2) k = 1
      if (best == "" || k < bk) { best = $0; bk = k } }
    END { if (best != "" && bk <= 2 && 2 * bk < length(w)) print best }'
}

# unknown_cmd word: the error, with the closest command when one is near
unknown_cmd() {
  local best
  best=$(known_cmds | nearest "$1")
  printf 'tando: unknown command "%s".' "$1" >&2
  [ -n "$best" ] && printf ' Did you mean "%s"?' "$best" >&2
  printf '\nRun tando help for the list of commands.\n' >&2
  exit 2
}

# flag_hint cmd flag: " Did you mean X?" for a mistyped flag of cmd (or the word other tools use)
flag_hint() {
  local f=$2 w best="" flags
  flags=" $(spec "$1" flags) "
  case $f in
    --app|--application) best=-a;; --host|--server) best=-H;; --follow) best=-f;;
    --lines|--number|--count|--tail) best=-n;; -y|--assume-yes) best=--yes;; -v|-V) best=--version;;
    -[a-z][a-z]*) best=-$f;;   # -all, -json, -wait: the long flag with one dash
  esac
  case $flags in *" $best "*|*" $best= "*) ;; *) best="";; esac
  if [ -z "$best" ]; then
    best=$(for w in $flags; do printf '%s\n' "${w%=}"; done | nearest "$f")
  fi
  [ -n "$best" ] && printf ' Did you mean %s?' "$best"
  return 0
}

# sub_hint cmd word: what the user probably meant by an unknown subcommand word (one line)
sub_hint() {
  local c=$1 w=$2 subs best="" s
  subs=$(for s in $(spec "$c" subs); do s=${s%%=*}; [ "$s" = default ] || printf '%s\n' "$s"; done)
  case $w in
    add|new|create|put) best="set";; rm|remov*|delet*|del|drop) best="unset";;
    list|show) best="ls";;
  esac
  case $c:$w in
    host:remov*|host:delet*|host:del|domain:remov*|domain:delet*|domain:del) best="rm";;
    backup:create|backup:make|backup:run) best="now";; backup:get|backup:download) best="pull";;
    ci:remove|ci:delete) best=revoke;;
  esac
  printf '%s\n' "$subs" | grepq -x -- "$best" || best=$(printf '%s\n' "$subs" | nearest "$w")
  if [ -n "$best" ]; then printf ' Did you mean "tando %s %s"?' "$c" "$best"
  else
    # tando domain example.com: the word is the argument of the one adding subcommand
    case $w in
      *.*) printf '%s\n' "$subs" | grepq -x add && printf ' Did you mean "tando %s add %s"?' "$c" "$w";;
      *) # tando env shop: an app name goes after the subcommand (tando host vps: a host name)
        if [ "$c" = host ]; then
          valid_app "$w" && printf ' A host name goes after the subcommand: "tando host status %s"?' "$w"
          return 0
        fi
        s=$(spec "$c" subs); s=${s##*default=}; s=${s%% *}
        case " $(spec "$c" subs) " in *" default="*) valid_app "$w" &&
          printf ' An app name goes after the subcommand: "tando %s %s %s"?' "$c" "$s" "$w";; esac;;
    esac
  fi
  return 0
}

# args_needed cmd [sub]: the <placeholders> its usage line names ("<domain>"), else ""
args_needed() {
  help_usage "$1" | sed -e 's/^usage: //' -e 's/^ *//' | grep "^tando $1 ${2:+$2 }" | head -1 |
    sed -e 's/\[[^]]*\]//g' | grep -o '<[^>]*>' | tr '\n' ' ' | sed 's/ $//'
}

# in_range n spec: spec is N, N-M, N+ or *
in_range() {
  case $2 in
    "*") return 0;;
    *+) [ "$1" -ge "${2%+}" ];;
    *-*) [ "$1" -ge "${2%-*}" ] && [ "$1" -le "${2#*-}" ];;
    *) [ "$1" -eq "$2" ];;
  esac
}

# check_args cmd args...: refuses unknown flags, missing flag values, unknown subcommands and a
# wrong number of arguments. Commands without a section (third-party plugins) are not checked.
check_args() {
  local cmd=$1 flags subs nargs a n=0 sub="" want w
  shift
  spec_has "$cmd" || return 0
  flags=" $(spec "$cmd" flags) " subs=$(spec "$cmd" subs) nargs=$(spec "$cmd" args)
  set -- "$@" --end--
  while [ "$1" != --end-- ]; do
    a=$1; shift
    case $a in
      --) while [ "$1" != --end-- ]; do n=$((n + 1)); [ $n = 1 ] && sub=$1; shift; done;;
      -?*)
        case $flags in
          *" $a= "*)
            if [ "$1" = --end-- ]; then
              case $a in
                -a) usage_err "-a needs an app name" "$cmd";;
                -H) usage_err "-H needs a host name (tando host ls)" "$cmd";;
                *) usage_err "$a needs a value" "$cmd";;
              esac
            fi
            shift;;
          *" $a "*) ;;
          *) usage_err "$cmd does not take $a.$(flag_hint "$cmd" "$a")" "$cmd";;
        esac;;
      *) n=$((n + 1)); [ $n = 1 ] && sub=$a;;
    esac
  done
  if [ -n "$subs" ]; then
    if [ $n = 0 ]; then
      case " $subs " in *" default="*) return 0;; esac
      usage_err "$cmd needs a subcommand" "$cmd"
    fi
    want=""
    for w in $subs; do [ "${w%%=*}" = "$sub" ] && [ "$sub" != default ] && want=${w#*=}; done
    [ -n "$want" ] || usage_err "$cmd has no subcommand \"$sub\".$(sub_hint "$cmd" "$sub")" "$cmd"
    if ! in_range $((n - 1)) "$want"; then
      w=$(args_needed "$cmd" "$sub")
      [ $((n - 1)) -lt "${want%%[!0-9]*}" ] && [ -n "$w" ] && usage_err "$cmd $sub needs $w" "$cmd"
      usage_err "wrong number of arguments for $cmd $sub" "$cmd"
    fi
  else
    in_range "$n" "${nargs:-0}" || {
      [ "$n" -gt 0 ] && [ "${nargs:-0}" = 0 ] && usage_err "$cmd takes no arguments (got \"$sub\")" "$cmd"
      w=$(args_needed "$cmd"); [ -n "$w" ] && [ "$n" -lt "${nargs%%[!0-9]*}" ] && usage_err "$cmd needs $w" "$cmd"
      case $nargs in *-[0-9]*) [ "$n" -gt "${nargs#*-}" ] &&
        usage_err "$cmd takes at most $(plural "${nargs#*-}" argument) (got $n)" "$cmd";; esac
      usage_err "wrong number of arguments for $cmd" "$cmd"
    }
  fi
  return 0
}

# confirm what word: data is about to be lost. Asks to type <word>; --yes skips the question.
# Without a terminal the answer is read from stdin (echo app | tando destroy).
confirm() {
  local typed
  [ -n "${YES:-}" ] && return 0
  note "$1"
  printf 'Type %s to confirm (or run with --yes): ' "$2" >&2
  IFS= read -r typed || typed=""
  [ "$typed" = "$2" ] || die "not confirmed; nothing was changed"
}
