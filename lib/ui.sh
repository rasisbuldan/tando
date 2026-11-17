# shellcheck shell=bash
# lib/ui.sh: boxed terminal UI for tando.
#
# Source it, call ui_init once, then draw:
#
#   ui_box_open "hello" "vps-1"
#   ui_kv "state" "$(ui_badge running)"
#   ui_box_sep "releases"
#   ui_table "l,l,r!1" < rows.tsv      # tab-separated, first row is the header
#   ui_box_close "q quit"
#
# Rules this file keeps:
# - bash 3.2 (macOS /bin/bash): no associative arrays, no ${v,,}, no mapfile,
#   no negative substring lengths. Safe under `set -euo pipefail`.
# - Pure bash in the render path: no forks per line. ui_init forks once
#   (stty or tput) when stdout is a terminal; nothing else forks.
# - Widths are visible widths: SGR colour sequences (ESC [ ... m) are skipped,
#   other escape sequences and control characters are removed or shown as "?".
#   Under a UTF-8 locale ${#s} counts characters, so box glyphs, "…" and
#   accented UTF-8 text measure one column each. Without a UTF-8 locale (or
#   with TANDO_ASCII=1) all glyphs are ASCII and non-ASCII bytes in text are
#   shown as "?" so byte counts and columns agree.
# - Out of scope: double-width characters (CJK, emoji). They count as one
#   column but take two, so a line holding them can push its right border out.
#   Geometric glyphs used here (● ○ ◌ ✓ ✗) are single width in Western fonts.
# - No line is ever wider than the box: text is cut with "…".
#
# Output: every line goes through _ui_emit. Normally it is printed at once;
# between ui_frame_begin and ui_frame_end it is appended to UI_FB and the whole
# frame is written with one printf. Functions that build a fragment for use in
# a cell come in two forms: ui_bar prints it (for "$(ui_bar ...)"), ui_bar_v
# sets UI_RET (no fork). Same for ui_spark, ui_badge, ui_dur, ui_bytes,
# ui_meter, ui_fit, ui_pad.
#
# Note: `cmd | ui_table spec` runs ui_table in a subshell (bash 3.2 has no
# lastpipe), so inside a frame its lines would be lost. Inside frames use
# `ui_table spec < file`, `ui_table spec <<< "$rows"`, `ui_table spec < <(cmd)`
# or fill the UI_TROWS array and call ui_table_a spec.

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

UI_FRAMING=0 UI_FB="" UI_FB_N=0 UI_FB_MAX=0 UI_FRAME_N=0 UI_CURSOR_HIDDEN=0
UI_BOX=0 UI_BOX_DROP=0 UI_WINCH=0 UI_RET="" UI_KV_W=10 UI_STEP_W=10
UI_TROWS=() UI_KQ=() UI_FB_OVL="" UI_ALT=0

# ui_init [width]: measure, choose colours and glyphs. Width order: argument,
# $COLUMNS, the terminal (only when stdout is a terminal), 80. Capped at 120.
# Colour: TANDO_COLOR=always|never, else on only for a tty without NO_COLOR.
# ASCII glyphs: TANDO_ASCII=1 or a locale that is not UTF-8.
ui_init() {
    UI_ARG_W="${1:-}"
    if [ -t 1 ]; then UI_ISTTY=1; else UI_ISTTY=0; fi
    UI_ROWS=0
    _ui_measure

    local color=0
    case "${TANDO_COLOR:-auto}" in
        always) color=1 ;;
        never) color=0 ;;
        *) if [[ $UI_ISTTY == 1 && -z "${NO_COLOR:-}" ]]; then color=1; fi ;;
    esac
    UI_COLOR=$color
    # Cursor control (frame repaint) only on a terminal, or when forced.
    UI_CTRL=0
    if [[ $UI_ISTTY == 1 || "${TANDO_COLOR:-}" == always ]]; then UI_CTRL=1; fi

    if [[ $color == 1 ]]; then
        UI_NC=$'\033[0m' UI_BOLD=$'\033[1m' UI_DIM=$'\033[2m'
        UI_RED=$'\033[31m' UI_GREEN=$'\033[32m' UI_YELLOW=$'\033[33m'
        UI_BLUE=$'\033[34m' UI_CYAN=$'\033[36m' UI_ACCENT=$'\033[1;36m'
        case "${TERM:-}:${COLORTERM:-}" in
            *256color*|*truecolor*|*24bit*|*kitty*|*wezterm*|*alacritty*) UI_FRAME_C=$'\033[38;5;242m' ;;
            *) UI_FRAME_C=$'\033[90m' ;;
        esac
        case "${TERM:-}:${COLORTERM:-}" in
            *256color*|*truecolor*|*24bit*|*kitty*|*wezterm*|*alacritty*) UI_SEL=$'\033[1;97;48;5;24m' ;;
            *) UI_SEL=$'\033[1;7m' ;;
        esac
    else
        UI_NC="" UI_BOLD="" UI_DIM="" UI_RED="" UI_GREEN="" UI_YELLOW=""
        UI_BLUE="" UI_CYAN="" UI_ACCENT="" UI_FRAME_C="" UI_SEL=""
    fi

    local probe="─"
    if [[ "${TANDO_ASCII:-0}" != 1 && ${#probe} -eq 1 ]]; then
        UI_UTF8=1
        UI_G_TL='╭' UI_G_TR='╮' UI_G_BL='╰' UI_G_BR='╯' UI_G_H='─' UI_G_V='│'
        UI_G_LT='├' UI_G_RT='┤' UI_G_ELL='…' UI_G_MID='·' UI_G_TO='→'
        UI_G_OK='✓' UI_G_ERR='✗' UI_G_PEND='◌' UI_G_DOT='●' UI_G_ODOT='○' UI_G_SKIP='–'
        if [[ "${UI_BAR_STYLE:-line}" == block ]]; then UI_G_FULL='█' UI_G_EMPTY='░'
        else UI_G_FULL='━' UI_G_EMPTY='─'; fi
        UI_G_SPARK=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')
        UI_G_SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        UI_G_CHART=(' ' '▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')
        UI_G_TT='┬' UI_G_TB='┴' UI_G_TX='┼' UI_G_PTR='❯' UI_G_UP='↑' UI_G_DOWN='↓'
        UI_G_LEFT='←' UI_G_RIGHT='→' UI_G_ENTER='⏎' 
    else
        UI_UTF8=0
        UI_G_TL='+' UI_G_TR='+' UI_G_BL='+' UI_G_BR='+' UI_G_H='-' UI_G_V='|'
        UI_G_LT='+' UI_G_RT='+' UI_G_ELL='~' UI_G_MID='-' UI_G_TO='->'
        UI_G_OK='+' UI_G_ERR='x' UI_G_PEND='o' UI_G_DOT='*' UI_G_ODOT='.' UI_G_SKIP='-'
        UI_G_FULL='#' UI_G_EMPTY='-'
        UI_G_SPARK=('_' '.' '-' '-' '=' '=' '#' '#')
        # shellcheck disable=SC1003 # a backslash glyph, not an escaped quote
        UI_G_SPIN=('|' '/' '-' '\')
        UI_G_CHART=(' ' '_' '_' '_' '+' '+' '+' '#' '#')
        UI_G_TT='+' UI_G_TB='+' UI_G_TX='+' UI_G_PTR='>' UI_G_UP='^' UI_G_DOWN='v'
        UI_G_LEFT='<' UI_G_RIGHT='>' UI_G_ENTER='enter' 
    fi
    printf -v UI_SP '%256s' ''
    UI_HL="${UI_SP// /$UI_G_H}"
    UI_FULL_S="${UI_SP// /$UI_G_FULL}"
    UI_EMPTY_S="${UI_SP// /$UI_G_EMPTY}"
    UI_SPARK_LO="${UI_SP// /${UI_G_SPARK[0]}}"
    UI_LB="${UI_FRAME_C}${UI_G_V}${UI_NC} "
    UI_RB=" ${UI_FRAME_C}${UI_G_V}${UI_NC}"
    if [[ $UI_CTRL == 1 ]]; then UI_EOL=$'\033[K\n'; else UI_EOL=$'\n'; fi
    return 0
}

# Width/height -> UI_COLS, UI_ROWS, UI_W (box width), UI_IN (inside width).
_ui_measure() {
    local cols="$UI_ARG_W" s=""
    UI_WIDTH_FIXED=1
    if [[ -z $cols && -n "${COLUMNS:-}" && "${UI_TTY_SIZE:-0}" != 1 ]]; then cols=$COLUMNS; fi
    if [[ $UI_ISTTY == 1 ]]; then
        s=$(stty size < /dev/tty 2>/dev/null) || s=""
        if [[ $s == *' '* ]]; then UI_ROWS=${s% *}; else UI_ROWS=0; fi
        if [[ -z $cols ]]; then
            UI_WIDTH_FIXED=0
            if [[ $s == *' '* ]]; then cols=${s#* }; else cols=$(tput cols 2>/dev/null) || cols=""; fi
        fi
    fi
    if [[ -z $UI_ROWS || $UI_ROWS == *[!0-9]* ]]; then UI_ROWS=0; fi
    if [[ $UI_ROWS == 0 && "${LINES:-}" =~ ^[0-9]+$ ]]; then UI_ROWS=$LINES; fi
    if [[ ! $cols =~ ^[0-9]+$ ]]; then cols=80; fi
    UI_COLS=$((10#$cols))
    UI_W=$UI_COLS
    if ((UI_W > ${UI_MAX_W:-120})); then UI_W=${UI_MAX_W:-120}; fi
    if ((UI_W < 30)); then UI_W=30; fi
    UI_IN=$((UI_W - 4))
    return 0
}

# ---------------------------------------------------------------------------
# Numbers from outside (the server)
# ---------------------------------------------------------------------------
#
# Bash arithmetic evaluates names and array subscripts inside the text it is
# given: $(( x )), (( )), [[ x -gt y ]], ${a[x]} and let all run the command in
# a value like "a[$(cmd)]". A field that came from the server may reach any of
# these only after one of the checks below.

# ui_int value: a plain integer, 0 to 18 digits, no sign, no leading zero.
ui_int() {
    case $1 in ""|*[!0-9]*|0?*) return 1 ;; esac
    ((${#1} <= 18))
}

# ui_dec value: ui_int with an optional fraction of 1 to 9 digits ("0.42").
ui_dec() {
    local i=${1%%.*} f=0
    case $1 in *.*) f=${1#*.} ;; esac
    case $f in ""|*[!0-9]*) return 1 ;; esac
    ((${#f} <= 9)) && ui_int "$i"
}

# ui_nums [-d] name...: every named variable that does not hold a number is
# set to 0 (-d: decimals allowed). Works on the caller's local variables.
ui_nums() {
    local __uin_d=0 __uin_n
    if [[ ${1:-} == -d ]]; then __uin_d=1; shift; fi
    for __uin_n in "$@"; do
        if ((__uin_d == 1)); then ui_dec "${!__uin_n}" && continue
        else ui_int "${!__uin_n}" && continue; fi
        printf -v "$__uin_n" '%s' 0
    done
    return 0
}

# ---------------------------------------------------------------------------
# Measuring and fitting text
# ---------------------------------------------------------------------------

# $1 -> _US (safe text: SGR kept, control chars and other escapes removed),
# _UP (plain text) and _UV (visible width).
_ui_vis() {
    case $1 in
        *[![:print:]]*) ;;
        *) _US=$1 _UP=$1 _UV=${#1}; return 0 ;;
    esac
    local s=$1 c n q
    _US="" _UP=""
    while [[ -n $s ]]; do
        c=${s%%$'\033'*}
        if [[ -n $c ]]; then
            n=${#c}
            case $c in
                *[![:print:]]*) c=${c//$'\t'/ }; c=${c//[![:print:]]/?} ;;
            esac
            _US+=$c _UP+=$c
            s=${s:n}
            if [[ -z $s ]]; then break; fi
        fi
        s=${s:1}                          # the ESC
        if [[ ${s:0:1} == '[' ]]; then
            q=${s%%[[:alpha:]]*}
            if [[ $q == "$s" ]]; then break; fi           # unterminated
            case ${q:1} in
                *[!0-9\;:?]*) continue ;;                 # not a CSI: show the rest
            esac
            if [[ ${s:${#q}:1} == m ]]; then _US+=$'\033'"${q}m"; fi
            s=${s:${#q}+1}
        fi
    done
    _UV=${#_UP}
    return 0
}

# ui_width text -> UI_RET = visible width.
ui_width() { _ui_vis "$1"; UI_RET=$_UV; }

# ui_fit max text -> UI_RET: text cut to at most max columns, ending in "…".
# Colours survive the cut (a reset is added after the "…").
ui_fit() {
    local max=$1
    _ui_vis "$2"
    if ((_UV <= max)); then UI_RET=$_US; return 0; fi
    if ((max <= 0)); then UI_RET="" _UV=0; return 0; fi
    if [[ $_US == "$_UP" ]]; then
        UI_RET="${_UP:0:max-1}${UI_G_ELL}" _UV=$max
        return 0
    fi
    local s=$_US b=$((max - 1)) c out="" q
    while ((b > 0)) && [[ -n $s ]]; do
        if [[ ${s:0:1} == $'\033' ]]; then
            q=${s%%m*}; out+="${q}m"; s=${s:${#q}+1}
            continue
        fi
        c=${s%%$'\033'*}
        if ((${#c} > b)); then c=${c:0:b}; fi
        out+=$c; b=$((b - ${#c})); s=${s:${#c}}
    done
    UI_RET="${out}${UI_G_ELL}"$'\033[0m' _UV=$max
    return 0
}

# ui_pad text width [l|r] -> UI_RET: fitted and padded to exactly width.
ui_pad() {
    local w=$2
    if ((w < 0)); then w=0; fi
    ui_fit "$w" "$1"
    if [[ "${3:-l}" == r ]]; then UI_RET="${UI_SP:0:w-_UV}${UI_RET}"
    else UI_RET="${UI_RET}${UI_SP:0:w-_UV}"; fi
    _UV=$w
    return 0
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

# One finished line. $2: o = box top, c = box bottom, empty = body. Inside a
# frame on a terminal, lines past the screen are dropped but a box that was
# started always gets its bottom border.
_ui_emit() {
    if [[ $UI_FRAMING != 1 ]]; then printf '%s\n' "$1"; return 0; fi
    if ((UI_FB_MAX > 0)); then
        case "${2:-}" in
            o) if ((UI_FB_N >= UI_FB_MAX - 1)); then UI_BOX_DROP=1; return 0; fi ;;
            c) if [[ $UI_BOX_DROP == 1 ]]; then UI_BOX_DROP=0; return 0; fi ;;
            *) if [[ $UI_BOX_DROP == 1 ]]; then return 0; fi
               if [[ $UI_BOX == 1 ]]; then
                   if ((UI_FB_N >= UI_FB_MAX - 1)); then return 0; fi
               elif ((UI_FB_N >= UI_FB_MAX)); then return 0; fi ;;
        esac
    fi
    UI_FB+="$1$UI_EOL"
    UI_FB_N=$((UI_FB_N + 1))
    return 0
}

# A body line whose visible width ($2) is known and fits.
_ui_body() {
    if [[ $UI_BOX == 1 ]]; then
        _ui_emit "${UI_LB}$1${UI_NC}${UI_SP:0:UI_IN-$2}${UI_RB}"
    else
        _ui_emit "$1"
    fi
}

# Width available for a line: inside the box, or the whole box width.
_ui_avail() { if [[ $UI_BOX == 1 ]]; then _UA=$UI_IN; else _UA=$UI_W; fi; }

# A border line -> UI_RET: c1 ─ left ─────── right ─ c2.
_ui_edge() {
    local c1=$1 c2=$2 left=$3 right=$4 lv=0 rv=0 rmax lmax fill out
    if [[ -n $left ]]; then _ui_vis "$left"; lv=$_UV; fi
    if [[ -n $right ]]; then
        rmax=$((UI_W - 7))
        if ((lv > 0)); then
            if ((lv < 16)); then rmax=$((rmax - lv - 2)); else rmax=$((rmax - 18)); fi
        fi
        ui_fit "$rmax" "$right"; right=$UI_RET; rv=$_UV
        if ((rv == 0)); then right=""; fi
    fi
    if ((lv > 0)); then
        lmax=$((UI_W - 7))
        if ((rv > 0)); then lmax=$((lmax - rv - 2)); fi
        ui_fit "$lmax" "$left"; left=$UI_RET; lv=$_UV
    fi
    fill=$((UI_W - 4))
    if ((lv > 0)); then fill=$((fill - lv - 2)); fi
    if ((rv > 0)); then fill=$((fill - rv - 2)); fi
    out="${UI_FRAME_C}${c1}${UI_G_H}${UI_NC}"
    if ((lv > 0)); then out+=" ${UI_BOLD}${left}${UI_NC} "; fi
    out+="${UI_FRAME_C}${UI_HL:0:fill}${UI_NC}"
    if ((rv > 0)); then out+=" ${UI_DIM}${right}${UI_NC} "; fi
    UI_RET="${out}${UI_FRAME_C}${UI_G_H}${c2}${UI_NC}"
}

# ---------------------------------------------------------------------------
# Boxes
# ---------------------------------------------------------------------------

# ui_box_open "Title" ["right-side text"]
ui_box_open() {
    _ui_edge "$UI_G_TL" "$UI_G_TR" "${1:-}" "${2:-}"
    UI_BOX=1
    _ui_emit "$UI_RET" o
}

# ui_box_line "text" ["right-aligned text"]. Outside a box: a line at box width.
# ui_box_wrap text: a box line wrapped at the inside width between words, never cut with "…"
# (commands, ids and links the user copies). Continuation lines keep the leading indent plus two
# spaces and the colour that was on at the break; a word longer than a line (a long link
# without colour) is split. Escapes do not count towards the width.
ui_box_wrap() {
    local t=$1 ind word line lw ww avail cur="" e=$'\033' ci fresh=1
    _ui_avail; avail=$_UA
    if [[ $t != *$'\033'* ]] && ((${#t} <= avail)); then ui_box_line "$t"; return 0; fi
    ind=${t%%[! ]*}; t=${t#"$ind"}
    ci=$((${#ind} + 2)); ((ci < avail / 2)) || ci=0
    line=$ind lw=${#ind}
    local IFS=' ' f=$-
    set -f
    for word in $t; do
        _ui_vis "$word"; ww=$_UV
        if ((fresh == 0)) && ((lw + 1 + ww > avail)); then   # next line
            ui_box_line "$line${cur:+$UI_NC}"; line="${UI_SP:0:ci}$cur" lw=$ci fresh=1
        fi
        # a word longer than the rest of the line (a long plain link): split it
        while ((ww > avail - lw - (1 - fresh))) && [[ $word != *$e* ]] && ((avail - lw - 1 > 0)); do
            ((fresh == 0)) && { line="$line "; lw=$((lw + 1)); }
            ui_box_line "$line${word:0:avail-lw}"
            word=${word:avail-lw}; ww=${#word}; line=${UI_SP:0:ci} lw=$ci fresh=1
        done
        if ((fresh == 1)); then line="$line$word" lw=$((lw + ww))
        else line="$line $word" lw=$((lw + 1 + ww)); fi
        fresh=0
        # the colour on at the end of this word: its last escape, unless that is a reset
        if [[ $word == *$e* ]]; then
            cur=$e${word##*$e}; cur=${cur%%m*}m
            [[ $cur == "$UI_NC" || $cur == $'\033[0m' || $cur == $'\033[m' ]] && cur=""
        fi
    done
    [[ $f == *f* ]] || set +f
    ((fresh == 0)) && ui_box_line "$line"
    return 0
}

ui_box_line() {
    local left="${1:-}" right="${2:-}" lv rv
    _ui_avail
    if [[ -z $right ]]; then
        ui_fit "$_UA" "$left"
        _ui_body "$UI_RET" "$_UV"
        return 0
    fi
    ui_fit "$_UA" "$right"; right=$UI_RET; rv=$_UV
    if [[ -z $left ]] || ((rv >= _UA - 1)); then
        _ui_body "${UI_SP:0:_UA-rv}${right}" "$_UA"
        return 0
    fi
    ui_fit $((_UA - rv - 1)) "$left"; lv=$_UV
    _ui_body "${UI_RET}${UI_NC}${UI_SP:0:_UA-lv-rv}${right}" "$_UA"
}

# ui_box_sep ["label"] ["right text"]
ui_box_sep() {
    if [[ $UI_BOX != 1 ]]; then return 0; fi
    _ui_edge "$UI_G_LT" "$UI_G_RT" "${1:-}" "${2:-}"
    _ui_emit "$UI_RET"
}

# ui_box_close ["footer"] ["right text"]
ui_box_close() {
    if [[ $UI_BOX != 1 ]]; then return 0; fi
    local f="${1:-}"
    if [[ -n $f ]]; then f="${UI_NC}${UI_DIM}${f}"; fi
    _ui_edge "$UI_G_BL" "$UI_G_BR" "$f" "${2:-}"
    UI_BOX=0
    _ui_emit "$UI_RET" c
}

# ui_kv "Key" "value" [key width]: dim key column, then the value.
ui_kv() {
    local kw="${3:-$UI_KV_W}" val
    ui_pad "$1" "$kw"
    val="${UI_DIM}${UI_RET}${UI_NC}  ${2:-}"
    ui_box_line "$val"
}

# ui_kv_wrap "Key" "plain value" [key width]: ui_kv, but a value too long for the line wraps
# between words, continued under itself (never cut). A command after ": " ("...: tando domain
# add x") starts its own line, so it is never broken in two.
ui_kv_wrap() {
    local kw="${3:-$UI_KV_W}" pre word line="" w v=$2 seg f=$-
    _ui_avail; w=$((_UA - kw - 2))
    if ((${#v} <= w)); then ui_kv "$@"; return 0; fi
    ui_pad "$1" "$kw"; pre="${UI_DIM}${UI_RET}${UI_NC}  "
    [[ $v == *": tando "* ]] && v="${v%%: tando *}:"$'\n'"tando ${v#*: tando }"
    set -f
    while IFS= read -r seg; do
        [[ -n $line ]] && { ui_box_line "$pre$line"; pre=${UI_SP:0:kw+2} line=""; }
        for word in $seg; do
            if [[ -n $line ]] && ((${#line} + 1 + ${#word} > w)); then
                ui_box_line "$pre$line"; pre=${UI_SP:0:kw+2} line=$word
            else line="${line:+$line }$word"; fi
        done
    done <<< "$v"
    [[ $f == *f* ]] || set +f
    ui_box_line "$pre$line"
}

# ui_flow "frag" "frag" ...: fragments on one line separated by three spaces,
# wrapping to further lines when the next one does not fit.
ui_flow() {
    local line="" lw=0 f
    _ui_avail
    local fs fv
    for f in "$@"; do
        _ui_vis "$f"; fs=$_US fv=$_UV
        if ((lw > 0 && lw + 3 + fv > _UA)); then
            ui_box_line "$line"; line="" lw=0
        fi
        if ((lw > 0)); then line+="   "; lw=$((lw + 3)); fi
        line+="$fs${UI_NC}"; lw=$((lw + fv))
    done
    if ((lw > 0)); then ui_box_line "$line"; fi
    return 0
}

# ---------------------------------------------------------------------------
# Tables
# ---------------------------------------------------------------------------

# ui_table "spec" < rows: tab-separated rows, the first is the header.
# spec, one item per column, comma-separated: l or r, then optional :min-max
# (":N" = at most N, ":N-" = no maximum), then optional !N drop priority.
#   "l,l,r:4-8,l:12-40!1,r!2"
# Columns get their natural width (widest cell) clamped to max. When the row
# is too wide: flexible columns shrink toward their min, then columns are
# dropped, highest !N first (rightmost first on ties), then as a last resort
# the widest columns shrink further. Cells that do not fit end in "…".
ui_table() {
    local line
    UI_TROWS=()
    while IFS= read -r line || [[ -n $line ]]; do
        UI_TROWS[${#UI_TROWS[@]}]=$line
    done
    ui_table_a "$1"
}

# Same as ui_table, rows taken from the array UI_TROWS (no stdin, no fork).
# Optional sel: data row (1 = first row under the header) shown as selected;
# any sel value (0 = none) adds a two-column pointer gutter.
ui_table_a() {
    _ui_avail
    _ui_table "$1" "$_UA" "${2:-}"
    local r
    for ((r = 0; r < ${#UI_TLINES[@]}; r++)); do _ui_body "${UI_TLINES[r]}" "${UI_TLW[r]}"; done
    return 0
}

# ui_table_lines spec width [sel]: like ui_table_a but the lines go to the array
# UI_TLINES (visible widths in UI_TLW, every line at most width), for panes.
ui_table_lines() { _ui_table "$1" "$2" "${3:-}"; }

_ui_table() {
    local spec="$1" item rest nc=0 nr=${#UI_TROWS[@]} r c k v n line sel="${3:-}" gut=0
    UI_TLINES=() UI_TLW=()
    local -a al mn mx pr nat colw on cell vis
    if ((nr == 0)); then return 0; fi
    if [[ $UI_FRAMING == 1 && $BASH_SUBSHELL != "$UI_FB_SUB" ]]; then
        echo "ui_table: called in a subshell inside a frame (use < file or <<< instead of a pipe)" >&2
    fi
    rest="$spec,"
    while [[ -n $rest ]]; do
        item=${rest%%,*}; rest=${rest#*,}
        al[nc]=l; mn[nc]=0; mx[nc]=9999; pr[nc]=0
        if [[ ${item:0:1} == r ]]; then al[nc]=r; fi
        if [[ $item == *'!'* ]]; then
            v=${item##*!}; item=${item%%!*}
            if [[ $v =~ ^[0-9]+$ ]]; then pr[nc]=$v; fi
        fi
        if [[ $item == *:* ]]; then
            v=${item#*:}
            if [[ $v == *-* ]]; then
                mn[nc]=${v%%-*}; mx[nc]=${v#*-}
                if [[ -z ${mx[nc]} ]]; then mx[nc]=9999; fi
            else
                mn[nc]=$v; mx[nc]=$v
            fi
            if [[ ! ${mn[nc]} =~ ^[0-9]+$ ]]; then mn[nc]=0; fi
            if [[ ! ${mx[nc]} =~ ^[0-9]+$ ]]; then mx[nc]=9999; fi
        else
            mn[nc]=-1                 # rigid: min = its width
        fi
        nat[nc]=0; on[nc]=1
        nc=$((nc + 1))
    done

    # Split cells, measure once.
    for ((r = 0; r < nr; r++)); do
        line=${UI_TROWS[r]}
        for ((c = 0; c < nc; c++)); do
            if [[ $line == *$'\t'* ]]; then v=${line%%$'\t'*}; line=${line#*$'\t'}
            else v=$line; line=""; fi
            case $v in
                *[![:print:]]*) _ui_vis "$v"; v=$_US; n=$_UV ;;
                *) n=${#v} ;;
            esac
            k=$((r * nc + c))
            cell[k]=$v; vis[k]=$n
            if ((n > nat[c])); then nat[c]=$n; fi
        done
    done

    # Fit columns.
    local avail=$2 total cnt want floor excess best bc slack
    if [[ -n $sel ]]; then gut=2; avail=$((avail - 2)); fi
    while :; do
        total=0 cnt=0
        for ((c = 0; c < nc; c++)); do
            if ((on[c] == 0)); then continue; fi
            want=${nat[c]}
            if ((want > mx[c])); then want=${mx[c]}; fi
            colw[c]=$want
            total=$((total + want)); cnt=$((cnt + 1))
        done
        if ((cnt > 1)); then total=$((total + 2 * (cnt - 1))); fi
        excess=$((total - avail))
        while ((excess > 0)); do
            best=-1 bc=0
            for ((c = 0; c < nc; c++)); do
                if ((on[c] == 0 || mn[c] < 0)); then continue; fi
                floor=${mn[c]}
                slack=$((colw[c] - floor))
                if ((slack > bc)); then bc=$slack best=$c; fi
            done
            if ((best < 0)); then break; fi
            colw[best]=$((colw[best] - 1)); excess=$((excess - 1))
        done
        if ((excess <= 0)); then break; fi
        best=-1 bc=0
        for ((c = 0; c < nc; c++)); do
            if ((on[c] == 1 && pr[c] > 0 && pr[c] >= bc)); then bc=${pr[c]} best=$c; fi
        done
        if ((best >= 0)); then on[best]=0; continue; fi
        # Last resort: shrink the widest columns.
        while ((excess > 0)); do
            best=-1 bc=1
            for ((c = 0; c < nc; c++)); do
                if ((on[c] == 1 && colw[c] > bc)); then bc=${colw[c]} best=$c; fi
            done
            if ((best < 0)); then break; fi
            colw[best]=$((colw[best] - 1)); excess=$((excess - 1))
        done
        break
    done

    # Render.
    local out ow first wc pad hi
    for ((r = 0; r < nr; r++)); do
        out="" ow=0 first=1 hi=0
        if [[ -n $sel ]] && ((r > 0 && r == sel)); then hi=1; fi
        for ((c = 0; c < nc; c++)); do
            if ((on[c] == 0)); then continue; fi
            k=$((r * nc + c))
            v=${cell[k]}; n=${vis[k]}; wc=${colw[c]}
            if ((hi == 1)) && [[ -n $UI_SEL ]]; then _ui_vis "$v"; v=$_UP; fi
            if ((n > wc)); then ui_fit "$wc" "$v"; v=$UI_RET; n=$_UV; fi
            if ((r == 0)) && [[ -n $v ]]; then v="${UI_DIM}${v}${UI_NC}"; fi
            pad=${UI_SP:0:wc-n}
            if ((first == 0)); then out+="  "; ow=$((ow + 2)); fi
            first=0
            if [[ ${al[c]} == r ]]; then out+="${pad}${v}"; else out+="${v}${pad}"; fi
            ow=$((ow + wc))
        done
        if ((ow > avail)); then ui_fit "$avail" "$out"; out=$UI_RET; ow=$_UV; fi
        if ((gut == 2)); then
            if ((hi == 1)); then
                if [[ -n $UI_SEL ]]; then
                    out="${UI_SEL}${UI_G_PTR} ${out}${UI_SP:0:avail-ow}${UI_NC}"; ow=$((avail + 2))
                else
                    out="${UI_G_PTR} ${out}"; ow=$((ow + 2))
                fi
            else
                out="  ${out}"; ow=$((ow + 2))
            fi
        fi
        UI_TLINES[r]=$out UI_TLW[r]=$ow
    done
    UI_TABLE_SHOWN=""
    for ((c = 0; c < nc; c++)); do UI_TABLE_SHOWN+="${on[c]}"; done
    return 0
}

# ---------------------------------------------------------------------------
# Fragments (print, or *_v to set UI_RET)
# ---------------------------------------------------------------------------

# Decimal string -> _UX = value * 100 as an integer (negative/garbage -> 0).
_ui_x100() {
    local x="${1:-0}" i f
    if [[ ! $x =~ ^[0-9]*\.?[0-9]*$ ]]; then _UX=0; return 0; fi
    i=${x%%.*}; f=""
    if ((${#i} > 15)); then _UX=0; return 0; fi     # nonsense, and would overflow
    if [[ $x == *.* ]]; then f=${x#*.}; fi
    f="${f}00"; f=${f:0:2}
    _UX=$((10#0$i * 100 + 10#$f))
}

# ui_bar_v value max width -> UI_RET: green below 70%, yellow below 90%, red.
ui_bar_v() {
    local v m wd="${3:-10}" filled=0 pct=0 col
    _ui_x100 "${1:-0}"; v=$_UX
    _ui_x100 "${2:-0}"; m=$_UX
    if ((m > 0)); then
        filled=$(((v * wd + m / 2) / m)); pct=$((v * 100 / m))
        if ((v > 0 && filled == 0)); then filled=1; fi
    fi
    if ((filled > wd)); then filled=$wd; fi
    if ((pct >= 90)); then col=$UI_RED; elif ((pct >= 70)); then col=$UI_YELLOW; else col=$UI_GREEN; fi
    UI_RET="${col}${UI_FULL_S:0:filled}${UI_NC}${UI_DIM}${UI_EMPTY_S:0:wd-filled}${UI_NC}"
}
ui_bar() { ui_bar_v "$@"; printf '%s' "$UI_RET"; }

# ui_meter_v "label" value max width ["text"] -> UI_RET: "cpu ━━━━──── 23%".
# Without text the percentage is shown.
ui_meter_v() {
    local t="${5:-}"
    if [[ -z $t ]]; then
        _ui_x100 "${2:-0}"; local v=$_UX; _ui_x100 "${3:-0}"
        if ((_UX > 0)); then t="$((v * 100 / _UX))%"; else t="-"; fi
    fi
    ui_bar_v "$2" "$3" "$4"
    UI_RET="${UI_DIM}$1${UI_NC} ${UI_RET} ${t}"
}
ui_meter() { ui_meter_v "$@"; printf '%s' "$UI_RET"; }

# ui_spark_v "v1 v2 ..." [width] [max] -> UI_RET. Scaled 0..max (default: the
# largest value). With width, shows the last width values, padded on the left.
ui_spark_v() {
    local IFS=$' \t\n' x n=0 i k max=0 wd="${2:-0}" out="" idx
    local -a sv
    for x in ${1:-}; do _ui_x100 "$x"; sv[n]=$_UX; n=$((n + 1)); done
    if ((wd <= 0)); then wd=$n; fi
    i=0; if ((n > wd)); then i=$((n - wd)); fi
    if [[ -n "${3:-}" ]]; then _ui_x100 "$3"; max=$_UX; else
        for ((k = i; k < n; k++)); do if ((sv[k] > max)); then max=${sv[k]}; fi; done
    fi
    for ((; i < n; i++)); do
        idx=0
        if ((max > 0)); then idx=$((sv[i] * 7 / max)); fi
        if ((idx > 7)); then idx=7; fi
        out+=${UI_G_SPARK[idx]}
    done
    if ((n < wd)); then out="${UI_DIM}${UI_SPARK_LO:0:wd-n}${UI_NC}${UI_ACCENT}${out}"
    else out="${UI_ACCENT}${out}"; fi
    UI_RET="${out}${UI_NC}"
}
ui_spark() { ui_spark_v "$@"; printf '%s' "$UI_RET"; }

# ui_badge_v state [label] -> UI_RET: coloured glyph and word.
ui_badge_v() {
    local s="${1:-}" g c
    case $s in
        running|active|ok|healthy|success|up) g=$UI_G_DOT c=$UI_GREEN ;;
        verified) g=$UI_G_OK c=$UI_GREEN ;;
        stopped|inactive|down|dead) g=$UI_G_ODOT c=$UI_DIM ;;
        failed|fail|error|bad) g=$UI_G_ERR c=$UI_RED ;;
        deploying|activating|starting|restarting|reloading|rollback|rolled-back) g=$UI_G_DOT c=$UI_YELLOW ;;
        current) g=$UI_G_DOT c=$UI_ACCENT ;;
        pending|queued|new) g=$UI_G_PEND c=$UI_DIM ;;
        *) g=$UI_G_MID c=$UI_DIM ;;
    esac
    UI_RET="${c}${g} ${2:-$s}${UI_NC}"
}
ui_badge() { ui_badge_v "$@"; printf '%s' "$UI_RET"; }

# ui_dur_v seconds -> UI_RET: "45s", "3.2s", "1m 31s", "2h 05m", "3d 4h".
ui_dur_v() {
    local x="${1:-0}" s
    if [[ ! $x =~ ^[0-9]{0,15}\.?[0-9]*$ || -z $x ]]; then UI_RET="-"; return 0; fi
    s=$((10#0${x%%.*}))
    if ((s < 10)) && [[ $x == *.* ]]; then
        _ui_x100 "$x"; UI_RET="$((_UX / 100)).$((_UX % 100 / 10))s"
    elif ((s < 60)); then UI_RET="${s}s"
    elif ((s < 3600)); then UI_RET="$((s / 60))m $((s % 60))s"
    elif ((s < 86400)); then printf -v UI_RET '%dh %02dm' $((s / 3600)) $((s % 3600 / 60))
    else UI_RET="$((s / 86400))d $((s % 86400 / 3600))h"
    fi
}
ui_dur() { ui_dur_v "$@"; printf '%s' "$UI_RET"; }

# ui_utc_v epoch [s] -> UI_RET: the time in UTC, "11-14 17:01" ("11-14 17:01:15" with s); "-"
# when not a number. A fraction is ignored. Pure arithmetic (civil-from-days), never forks date.
ui_utc_v() {
    local x="${1:-}" t z doe yoe doy mp
    x=${x%%.*}
    if [[ ! $x =~ ^(0|[1-9][0-9]{0,14})$ ]]; then UI_RET="-"; return 0; fi
    t=$((10#$x)) z=$((t / 86400 + 719468))
    doe=$((z % 146097)) yoe=$(((doe - doe / 1460 + doe / 36524 - doe / 146096) / 365))
    doy=$((doe - (365 * yoe + yoe / 4 - yoe / 100))) mp=$(((5 * doy + 2) / 153))
    t=$((t % 86400))
    if [ "${2:-}" = s ]; then
        printf -v UI_RET '%02d-%02d %02d:%02d:%02d' $((mp < 10 ? mp + 3 : mp - 9)) \
            $((doy - (153 * mp + 2) / 5 + 1)) $((t / 3600)) $((t % 3600 / 60)) $((t % 60))
    else
        printf -v UI_RET '%02d-%02d %02d:%02d' $((mp < 10 ? mp + 3 : mp - 9)) \
            $((doy - (153 * mp + 2) / 5 + 1)) $((t / 3600)) $((t % 3600 / 60))
    fi
}
ui_utc() { ui_utc_v "$@"; printf '%s' "$UI_RET"; }

# ui_bytes_v bytes -> UI_RET: "512 B", "8.2 KB", "234 MB", "1.4 GB".
ui_bytes_v() {
    local b="${1:-0}" d=1 u=B t
    if [[ ! $b =~ ^[0-9]{1,18}$ ]]; then b=0; fi
    b=$((10#$b))
    if ((b >= 1099511627776)); then d=1099511627776 u=TB
    elif ((b >= 1073741824)); then d=1073741824 u=GB
    elif ((b >= 1048576)); then d=1048576 u=MB
    elif ((b >= 1024)); then d=1024 u=KB; fi
    if ((d == 1)); then UI_RET="$b B"; return 0; fi
    t=$(((b * 10 + d / 2) / d))
    if ((t < 100)); then UI_RET="$((t / 10)).$((t % 10)) $u"
    else UI_RET="$(((t + 5) / 10)) $u"; fi
}
ui_bytes() { ui_bytes_v "$@"; printf '%s' "$UI_RET"; }

# ui_step n total "label" state ["detail"]: one deploy phase line.
# state: pending, run, ok, fail (also skip). Inside or outside a box.
ui_step() {
    local n="${1:-0}" t="${2:-0}" label="${3:-}" st="${4:-pending}" d="${5:-}"
    local g lc dc cnt
    case $st in
        ok|done) g="${UI_GREEN}${UI_G_OK}${UI_NC}" lc="" dc=$UI_DIM ;;
        fail|failed) g="${UI_RED}${UI_G_ERR}${UI_NC}" lc="${UI_BOLD}${UI_RED}" dc=$UI_RED ;;
        run|running) g="${UI_ACCENT}${UI_G_SPIN[SECONDS % ${#UI_G_SPIN[@]}]}${UI_NC}" lc=$UI_BOLD dc="" ;;
        skip|skipped) g="${UI_DIM}${UI_G_SKIP}${UI_NC}" lc=$UI_DIM dc=$UI_DIM ;;
        *) g="${UI_DIM}${UI_G_PEND}${UI_NC}" lc=$UI_DIM dc=$UI_DIM ;;
    esac
    local tok="${d%% *}" rest=""
    cnt="$n/$t"
    ui_pad "$cnt" $((${#t} * 2 + 1)) r; cnt=$UI_RET
    # A leading time ("4s", "18.2s", "1m") gets its own right-aligned column.
    if [[ $tok =~ ^[0-9][0-9.]*(s|m|ms|h)$ ]]; then
        if [[ $d == *' '* ]]; then rest=${d#* }; rest="  ${rest#"${rest%%[! ]*}"}"; fi
        ui_pad "$tok" 6 r; d="${UI_RET}${rest}"
    elif [[ -n $d ]]; then
        d="${UI_SP:0:6}  $d"
    fi
    ui_pad "$label" "$UI_STEP_W"
    ui_box_line "${g} ${UI_DIM}${cnt}${UI_NC}  ${lc}${UI_RET}${UI_NC}  ${dc}${d}${UI_NC}"
}

# ---------------------------------------------------------------------------
# Frames (--watch)
# ---------------------------------------------------------------------------

# Start buffering a frame: every ui_* line goes to UI_FB until ui_frame_end.
# On a terminal the size is re-read after a resize (SIGWINCH).
ui_frame_begin() {
    if [[ $UI_WINCH == 1 && $UI_WIDTH_FIXED == 0 ]]; then
        UI_WINCH=0; _ui_measure
    fi
    UI_FRAMING=1 UI_FB="" UI_FB_N=0 UI_BOX=0 UI_BOX_DROP=0
    UI_FB_SUB=$BASH_SUBSHELL
    UI_FB_MAX=0
    if [[ $UI_ISTTY == 1 && $UI_ROWS -gt 2 ]]; then
        if [[ ${UI_ALT:-0} == 1 ]]; then UI_FB_MAX=$UI_ROWS; else UI_FB_MAX=$((UI_ROWS - 1)); fi
    fi
    UI_FB_OVL=""
    if ((UI_FRAME_N == 0)); then
        UI_LAST_W=$UI_W
        if [[ $UI_ISTTY == 1 ]]; then
            if [[ -z $(trap -p EXIT) ]]; then trap 'ui_frame_cleanup' EXIT; fi
            if [[ -z $(trap -p INT) ]]; then trap 'ui_frame_cleanup; exit 130' INT; fi
            if [[ -z $(trap -p TERM) ]]; then trap 'ui_frame_cleanup; exit 143' TERM; fi
            if [[ -z $(trap -p WINCH) ]]; then trap 'UI_WINCH=1' WINCH; fi
        fi
    fi
    return 0
}

# Write the frame at once: cursor home, the lines (each clears to its end),
# clear the rest of the screen. Hides the cursor on the first frame. Without
# cursor control (not a terminal) frames are printed one after another.
ui_frame_end() {
    local pre=""
    UI_FRAMING=0
    if [[ $UI_CTRL == 1 ]]; then
        if ((UI_FRAME_N == 0)); then pre=$'\033[?25l'; UI_CURSOR_HIDDEN=1; fi
        if [[ $UI_W != "${UI_LAST_W:-0}" ]]; then pre+=$'\033[2J'; UI_LAST_W=$UI_W; fi
        # In the alternate screen the last line has no newline, so all rows are usable.
        if [[ ${UI_ALT:-0} == 1 ]]; then UI_FB=${UI_FB%$'\n'}; fi
        printf '%s' "${pre}"$'\033[H'"${UI_FB}"$'\033[J'"${UI_FB_OVL:-}"
    else
        if ((UI_FRAME_N > 0)); then pre=$'\n'; fi
        printf '%s' "${pre}${UI_FB}${UI_FB_OVL:-}"
    fi
    UI_FB_OVL=""
    UI_FB="" UI_FRAME_N=$((UI_FRAME_N + 1))
    return 0
}

# Show the cursor again. Call from EXIT/INT traps (ui_frame_begin installs
# them on a terminal when the caller has none; ui_frame_trap installs them).
ui_frame_cleanup() {
    if [[ ${UI_ALT:-0} == 1 ]]; then ui_term_leave; fi
    if [[ $UI_CURSOR_HIDDEN == 1 ]]; then printf '\033[?25h'; UI_CURSOR_HIDDEN=0; fi
    return 0
}

# Install EXIT/INT/TERM/WINCH traps for a watch loop (replaces existing ones).
ui_frame_trap() {
    trap 'ui_frame_cleanup' EXIT
    trap 'ui_frame_cleanup; exit 130' INT
    trap 'ui_frame_cleanup; exit 143' TERM
    trap 'UI_WINCH=1' WINCH
}

# ---------------------------------------------------------------------------
# Full-screen interactive programs (tando top)
# ---------------------------------------------------------------------------
#
# ui_term_enter: alternate screen, cursor hidden, keys unbuffered and not
# echoed (VMIN=0 VTIME=0, so `dd` can drain what is pending without waiting).
# ui_term_leave (also called by ui_frame_cleanup) restores all of it. Callers
# install traps: trap 'ui_frame_cleanup' EXIT; INT/TERM/HUP exit through it.

ui_term_enter() {
    UI_STTY=$(stty -g 2> /dev/null) || UI_STTY=""
    stty -echo -icanon min 0 time 0 2> /dev/null
    UI_TTY_SIZE=1 UI_WIDTH_FIXED=0
    _ui_measure
    UI_ALT=1 UI_CURSOR_HIDDEN=1 UI_LAST_W=$UI_W UI_KQ=()
    printf '\033[?1049h\033[?25l\033[H\033[2J'
}

ui_term_leave() {
    if [[ ${UI_ALT:-0} != 1 ]]; then return 0; fi
    UI_ALT=0 UI_CURSOR_HIDDEN=0
    printf '\033[0m\033[?25h\033[?1049l'
    if [[ -n ${UI_STTY:-} ]]; then stty "$UI_STTY" 2> /dev/null; else stty sane 2> /dev/null; fi
    return 0
}

# ui_key [seconds=1] -> UI_KEY: one key, or "" on timeout (returns 1). Returns
# 2 when the input is closed. Names: up down left right home end pgup pgdn
# enter tab backtab esc space backspace, else the character itself. bash 3.2
# only has whole-second read timeouts, so the wait is in seconds; a key ends
# it at once. After ESC the rest of an escape sequence is taken from what is
# already pending (dd, no wait), so a lone ESC is seen at once and arrows are
# not mistaken for ESC. Pending keys queue up to 8; ui_key_flush drops them.
ui_key() {
    local t="${1:-1}" k="" rc rest
    UI_KEY=""
    if ((${#UI_KQ[@]} > 0)); then _ui_kq_pop; return 0; fi
    if ((t <= 0)); then
        rest=$(dd bs=4096 count=1 2> /dev/null; echo .); rest=${rest%.}
        if [[ -z $rest ]]; then return 1; fi
        _ui_kq_parse "$rest"; _ui_kq_pop; return 0
    fi
    IFS= read -rsn1 -t "$t" k; rc=$?
    if ((rc > 128)); then return 1; fi
    if ((rc != 0)); then
        if [[ -z $k ]]; then
            # A signal (a background job ending) also ends the read early, so only
            # many early ends within the same second count as a closed input.
            if [[ ${UI_KEY_EOF_T:-} == "$SECONDS" ]]; then UI_KEY_EOF=$((${UI_KEY_EOF:-0} + 1))
            else UI_KEY_EOF=1 UI_KEY_EOF_T=$SECONDS; fi
            if ((UI_KEY_EOF > 20)); then return 2; fi
            return 1
        fi
    fi
    # Take whatever else is pending in one go (dd, no wait): the rest of an
    # escape sequence, or a paste / held key, of which only 8 keys are kept.
    rest=$(dd bs=4096 count=1 2> /dev/null; echo .); rest=${rest%.}
    if [[ $k == $'\033' ]]; then
        case $rest in
            '['|'O'|\[[0-9]|\[[0-9][0-9]|\[[0-9]\;*)
                # sequence split in transit: one more byte, waiting at most a second
                IFS= read -rsn1 -t 1 k && rest+=$k
                case $rest in \[[0-9]|\[[0-9][0-9]) IFS= read -rsn1 -t 1 k && rest+=$k ;; esac ;;
        esac
        _ui_kq_parse $'\033'"$rest"; _ui_kq_pop; return 0
    fi
    if [[ -z $k ]]; then k=$'\n'; fi
    _ui_kq_parse "$k$rest"; _ui_kq_pop
    return 0
}

ui_key_flush() {
    UI_KQ=()
    dd bs=4096 count=1 > /dev/null 2>&1
    return 0
}

_ui_kq_pop() {
    local n=${#UI_KQ[@]} i
    UI_KEY=${UI_KQ[0]}
    for ((i = 1; i < n; i++)); do UI_KQ[i-1]=${UI_KQ[i]}; done
    unset "UI_KQ[$((n - 1))]"
}

_ui_kq_add() { if ((${#UI_KQ[@]} < 8)); then UI_KQ[${#UI_KQ[@]}]=$1; fi; }

# Bytes -> key names appended to UI_KQ.
_ui_kq_parse() {
    local s=$1 c seq=""
    if [[ -z $s ]]; then _ui_kq_add enter; return 0; fi
    while [[ -n $s ]]; do
        c=${s:0:1}; s=${s:1}
        case $c in
            $'\033')
                if [[ ${s:0:1} == O && -n ${s:1:1} ]]; then
                    seq=${s:0:2}; s=${s:2}              # SS3: ESC O <letter>
                elif [[ ${s:0:1} == '[' ]]; then
                    seq=${s:1}; seq=${seq%%[A-Za-z~]*}
                    if [[ $seq == "${s:1}" ]]; then s=""; continue; fi
                    seq=${s:0:${#seq}+2}; s=${s:${#seq}}
                fi
                if [[ -n $seq ]]; then
                    case $seq in
                        '[A'|OA) _ui_kq_add up ;;
                        '[B'|OB) _ui_kq_add down ;;
                        '[C'|OC) _ui_kq_add right ;;
                        '[D'|OD) _ui_kq_add left ;;
                        '[H'|OH|'[1~'|'[7~') _ui_kq_add home ;;
                        '[F'|OF|'[4~'|'[8~') _ui_kq_add end ;;
                        '[5~') _ui_kq_add pgup ;;
                        '[6~') _ui_kq_add pgdn ;;
                        '[Z') _ui_kq_add backtab ;;
                        *) ;;                       # other keys: ignored
                    esac
                    seq=""
                else
                    _ui_kq_add esc
                fi ;;
            $'\n'|$'\r') _ui_kq_add enter ;;
            $'\t') _ui_kq_add tab ;;
            ' ') _ui_kq_add space ;;
            $'\177'|$'\b') _ui_kq_add backspace ;;
            [[:print:]]) _ui_kq_add "$c" ;;
            *) ;;
        esac
    done
    return 0
}

# ui_chart_v "values" width height [max] [label] [maxlabel] [colour] -> the
# array UI_CHART: height lines, each exactly width columns. With a label the
# first line is a caption: label on the left, maxlabel (default "max <max>")
# on the right; the other lines are the plot, 8 levels per row (block
# characters; ASCII _ + # without UTF-8). Values are numbers (decimals ok) or
# "-" for no data; the last width values are shown, right-aligned. max
# defaults to the largest value. Zero shows as a dim baseline.
ui_chart_v() {
    local IFS=$' \t\n' vals="${1:-}" wd="${2:-20}" ht="${3:-4}" max="${4:-}" label="${5:-}"
    local ml="${6:-}" col="${7:-$UI_ACCENT}" x n=0 i j lv rows top base g line mode
    local -a cv
    UI_CHART=()
    if ((wd < 1)); then wd=1; fi
    if ((ht < 1)); then ht=1; fi
    for x in $vals; do
        if [[ $x == - ]]; then cv[n]=-1; else _ui_x100 "$x"; cv[n]=$_UX; fi
        n=$((n + 1))
    done
    local m=0
    if [[ -n $max ]]; then _ui_x100 "$max"; m=$_UX; fi
    if ((m <= 0)); then
        for ((i = 0; i < n; i++)); do if ((cv[i] > m)); then m=${cv[i]}; fi; done
    fi
    rows=$ht
    if [[ -n $label ]]; then
        rows=$((ht - 1))
        if [[ -z $ml ]]; then ml="max $((m / 100))"; fi
        ui_box_line_v "$label" "${UI_DIM}${ml}${UI_NC}" "$wd"
        UI_CHART[0]=$UI_RET
    fi
    if ((rows < 1)); then return 0; fi
    # level of each shown column, 0..rows*8; -1 = no data
    local -a lvl
    local first=$((n - wd)) k=0
    for ((i = first; i < n; i++)); do
        if ((i < 0)); then lvl[k]=-1
        elif ((cv[i] < 0)); then lvl[k]=-1
        elif ((m <= 0)); then lvl[k]=0
        else
            lv=$(((cv[i] * rows * 8 + m / 2) / m))
            if ((cv[i] > 0 && lv == 0)); then lv=1; fi
            if ((lv > rows * 8)); then lv=$((rows * 8)); fi
            lvl[k]=$lv
        fi
        k=$((k + 1))
    done
    for ((j = rows - 1; j >= 0; j--)); do
        base=$((j * 8)) line="" mode=""
        for ((i = 0; i < wd; i++)); do
            lv=${lvl[i]}
            if ((lv < 0)); then g=" " x=n
            elif ((lv - base >= 8)); then g=${UI_G_CHART[8]} x=c
            elif ((lv - base > 0)); then g=${UI_G_CHART[lv - base]} x=c
            elif ((j == 0)); then g=${UI_G_CHART[1]} x=d
            else g=" " x=n
            fi
            if [[ $x != "$mode" && $x != n ]]; then
                if [[ $x == c ]]; then line+="${UI_NC}${col}"; else line+="${UI_NC}${UI_DIM}"; fi
                mode=$x
            fi
            line+=$g
        done
        UI_CHART[${#UI_CHART[@]}]="${line}${UI_NC}"
    done
    return 0
}

# ui_chart "values" width height [max] [label] [maxlabel] [colour]: the chart's
# lines as box lines.
ui_chart() {
    local i
    ui_chart_v "$@"
    for ((i = 0; i < ${#UI_CHART[@]}; i++)); do ui_box_line "${UI_CHART[i]}"; done
    return 0
}

# ui_box_line_v left [right] [width] -> UI_RET: left and right-aligned text in
# exactly width columns (default: the inside of the box). No border.
ui_box_line_v() {
    local left="${1:-}" right="${2:-}" w="${3:-$UI_IN}" lv rv
    if [[ -z $right ]]; then
        ui_fit "$w" "$left"; lv=$_UV
        UI_RET="${UI_RET}${UI_NC}${UI_SP:0:w-lv}"; _UV=$w
        return 0
    fi
    ui_fit "$w" "$right"; right=$UI_RET; rv=$_UV
    if [[ -z $left ]] || ((rv >= w - 1)); then UI_RET="${UI_SP:0:w-rv}${right}"; _UV=$w; return 0; fi
    ui_fit $((w - rv - 1)) "$left"; lv=$_UV
    UI_RET="${UI_RET}${UI_NC}${UI_SP:0:w-lv-rv}${right}"; _UV=$w
}

# ui_sel_v text width -> UI_RET: a selected line, exactly width columns:
# pointer, plain text on the selection colour.
ui_sel_v() {
    local w=$2
    _ui_vis "$1"
    ui_fit $((w - 2)) "$_UP"
    UI_RET="${UI_SEL}${UI_G_PTR} ${UI_RET}${UI_SP:0:w-2-_UV}${UI_NC}"; _UV=$w
}

# ---- two panes: "│ left │ right │" -------------------------------------------
#
# The left pane is lw columns; the right pane gets UI_W - lw - 7.
# ui_split_edge kind lw ["left label"] ["right label"] ["right-side text"]
#   kind: top ╭┬╮, sep ├┬┤ (split starts under a full line), mid ├┼┤,
#         join ├┴┤ (split ends, full width follows), bottom ╰┴╯.
ui_split_edge() {
    local kind=$1 lw=$2 a b c rw=$((UI_W - $2 - 5)) seg
    case $kind in
        top) a=$UI_G_TL b=$UI_G_TT c=$UI_G_TR ;;
        sep) a=$UI_G_LT b=$UI_G_TT c=$UI_G_RT ;;
        mid) a=$UI_G_LT b=$UI_G_TX c=$UI_G_RT ;;
        join) a=$UI_G_LT b=$UI_G_TB c=$UI_G_RT ;;
        *) a=$UI_G_BL b=$UI_G_TB c=$UI_G_BR ;;
    esac
    _ui_hseg $((lw + 2)) "${3:-}" ""; seg=$UI_RET
    _ui_hseg "$rw" "${4:-}" "${5:-}"
    UI_RET="${UI_FRAME_C}${a}${UI_NC}${seg}${UI_FRAME_C}${b}${UI_NC}${UI_RET}${UI_FRAME_C}${c}${UI_NC}"
    case $kind in
        top) UI_BOX=1; _ui_emit "$UI_RET" o ;;
        bottom) UI_BOX=0; _ui_emit "$UI_RET" c ;;
        *) _ui_emit "$UI_RET" ;;
    esac
}

# ui_split_line "left" "right" lw: one line of both panes.
ui_split_line() {
    local lw=$3 rw=$((UI_W - $3 - 7)) l
    ui_box_line_v "${1:-}" "" "$lw"; l=$UI_RET
    ui_box_line_v "${2:-}" "" "$rw"
    _ui_emit "${UI_LB}${l}${UI_RB} ${UI_RET}${UI_RB}"
}

# A run of border line exactly w wide: "─ left ──── right ─" -> UI_RET.
_ui_hseg() {
    local w=$1 left=$2 right=$3 lv=0 rv=0 fill out
    if ((w < 1)); then UI_RET=""; return 0; fi
    if [[ -n $right ]] && ((w > 8)); then
        if [[ -n $left ]]; then ui_fit $((w / 2 - 3)) "$right"; else ui_fit $((w - 4)) "$right"; fi
        right=$UI_RET; rv=$_UV
    fi
    if [[ -n $left ]]; then
        local lmax=$((w - 4)); if ((rv > 0)); then lmax=$((lmax - rv - 2)); fi
        if ((lmax > 0)); then ui_fit "$lmax" "$left"; left=$UI_RET; lv=$_UV; fi
    fi
    fill=$((w - 2))
    if ((lv > 0)); then fill=$((fill - lv - 2)); fi
    if ((rv > 0)); then fill=$((fill - rv - 2)); fi
    if ((w < 2)); then UI_RET="${UI_FRAME_C}${UI_HL:0:w}${UI_NC}"; return 0; fi
    out="${UI_FRAME_C}${UI_G_H}${UI_NC}"
    if ((lv > 0)); then out+=" ${UI_BOLD}${left}${UI_NC} "; fi
    out+="${UI_FRAME_C}${UI_HL:0:fill}${UI_NC}"
    if ((rv > 0)); then out+=" ${UI_DIM}${right}${UI_NC} "; fi
    UI_RET="${out}${UI_FRAME_C}${UI_G_H}${UI_NC}"
}

# ---- modal box over a frame --------------------------------------------------
#
# ui_modal "title" "footer" line...: a box centred on the screen, drawn over
# the frame (cursor positioning, after the frame). Outside a frame, or without
# cursor control, it is printed as an ordinary box.
ui_modal() {
    local title=$1 foot=$2 i w=0 n h r c sw=$UI_W si=$UI_IN cols rows line
    shift 2
    for line in "$@"; do _ui_vis "$line"; if ((_UV > w)); then w=$_UV; fi; done
    _ui_vis "$title"; if ((_UV + 8 > w)); then w=$((_UV + 8)); fi
    w=$((w + 4))
    cols=${UI_COLS:-$UI_W}; rows=${UI_ROWS:-0}
    if ((w > cols - 4)); then w=$((cols - 4)); fi
    if ((w > 76)); then w=76; fi
    if ((w < 24)); then w=24; fi
    if [[ $UI_FRAMING != 1 || $UI_CTRL != 1 ]] || ((rows < 5)); then
        UI_W=$w UI_IN=$((w - 4))
        ui_box_open "$title"; for line in "$@"; do ui_box_line "$line"; done; ui_box_close "$foot"
        UI_W=$sw UI_IN=$si
        return 0
    fi
    n=$#; h=$((n + 2))
    if ((h > rows)); then n=$((rows - 2)); h=$rows; fi
    r=$(((rows - h) / 2 + 1)); c=$(((cols - w) / 2 + 1))
    UI_W=$w UI_IN=$((w - 4))
    _ui_edge "$UI_G_TL" "$UI_G_TR" "$title" ""
    UI_FB_OVL+=$'\033['"${r};${c}H${UI_RET}"
    i=0
    for line in "$@"; do
        if ((i >= n)); then break; fi
        ui_box_line_v "$line" "" "$UI_IN"
        UI_FB_OVL+=$'\033['"$((r + 1 + i));${c}H${UI_LB}${UI_RET}${UI_RB}"
        i=$((i + 1))
    done
    if [[ -n $foot ]]; then foot="${UI_NC}${UI_DIM}${foot}"; fi
    _ui_edge "$UI_G_BL" "$UI_G_BR" "$foot" ""
    UI_FB_OVL+=$'\033['"$((r + 1 + n));${c}H${UI_RET}"
    UI_W=$sw UI_IN=$si
    return 0
}

# ui_keys_v key text key text ... -> UI_RET: "key text · key text" for hints.
ui_keys_v() {
    UI_RET=""
    while (($# >= 2)); do
        if [[ -n $UI_RET ]]; then UI_RET+=" ${UI_DIM}${UI_G_MID}${UI_NC} "; fi
        UI_RET+="${UI_NC}${UI_BOLD}$1${UI_NC}${UI_DIM} $2${UI_NC}"
        shift 2
    done
    return 0
}

# ui_scroll_v total height top [follow] -> UI_RET = first visible index, clamped;
# follow (1) pins the window to the end.
ui_scroll_v() {
    local total=$1 h=$2 top=$3 maxtop
    maxtop=$((total - h)); if ((maxtop < 0)); then maxtop=0; fi
    if [[ "${4:-0}" == 1 ]] || ((top > maxtop)); then top=$maxtop; fi
    if ((top < 0)); then top=0; fi
    UI_RET=$top
}

# ui_flow_v width frag... -> the array UI_FLOW: like ui_flow, but the lines are
# returned (each at most width columns) instead of drawn.
ui_flow_v() {
    local w=$1 line="" lw=0 f fs fv
    shift
    UI_FLOW=()
    for f in "$@"; do
        _ui_vis "$f"; fs=$_US fv=$_UV
        if ((lw > 0 && lw + 3 + fv > w)); then
            UI_FLOW[${#UI_FLOW[@]}]=$line; line="" lw=0
        fi
        if ((lw > 0)); then line+="   "; lw=$((lw + 3)); fi
        line+="$fs${UI_NC}"; lw=$((lw + fv))
    done
    if ((lw > 0)); then UI_FLOW[${#UI_FLOW[@]}]=$line; fi
    return 0
}
