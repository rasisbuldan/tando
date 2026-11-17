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
UI_TROWS=()

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
    else
        UI_NC="" UI_BOLD="" UI_DIM="" UI_RED="" UI_GREEN="" UI_YELLOW=""
        UI_BLUE="" UI_CYAN="" UI_ACCENT="" UI_FRAME_C=""
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
    else
        UI_UTF8=0
        UI_G_TL='+' UI_G_TR='+' UI_G_BL='+' UI_G_BR='+' UI_G_H='-' UI_G_V='|'
        UI_G_LT='+' UI_G_RT='+' UI_G_ELL='~' UI_G_MID='-' UI_G_TO='->'
        UI_G_OK='+' UI_G_ERR='x' UI_G_PEND='o' UI_G_DOT='*' UI_G_ODOT='.' UI_G_SKIP='-'
        UI_G_FULL='#' UI_G_EMPTY='-'
        UI_G_SPARK=('_' '.' '-' '-' '=' '=' '#' '#')
        UI_G_SPIN=('|' '/' '-' '\')
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
    if [[ -z $cols && -n "${COLUMNS:-}" ]]; then cols=$COLUMNS; fi
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
    if ((UI_W > 120)); then UI_W=120; fi
    if ((UI_W < 30)); then UI_W=30; fi
    UI_IN=$((UI_W - 4))
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
ui_table_a() {
    local spec="$1" item rest nc=0 nr=${#UI_TROWS[@]} r c k v n line
    local -a al mn mx pr nat w on cell vis
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
    local avail total cnt want floor excess best bc slack
    _ui_avail; avail=$_UA
    while :; do
        total=0 cnt=0
        for ((c = 0; c < nc; c++)); do
            if ((on[c] == 0)); then continue; fi
            want=${nat[c]}
            if ((want > mx[c])); then want=${mx[c]}; fi
            w[c]=$want
            total=$((total + want)); cnt=$((cnt + 1))
        done
        if ((cnt > 1)); then total=$((total + 2 * (cnt - 1))); fi
        excess=$((total - avail))
        while ((excess > 0)); do
            best=-1 bc=0
            for ((c = 0; c < nc; c++)); do
                if ((on[c] == 0 || mn[c] < 0)); then continue; fi
                floor=${mn[c]}
                slack=$((w[c] - floor))
                if ((slack > bc)); then bc=$slack best=$c; fi
            done
            if ((best < 0)); then break; fi
            w[best]=$((w[best] - 1)); excess=$((excess - 1))
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
                if ((on[c] == 1 && w[c] > bc)); then bc=${w[c]} best=$c; fi
            done
            if ((best < 0)); then break; fi
            w[best]=$((w[best] - 1)); excess=$((excess - 1))
        done
        break
    done

    # Render.
    local out ow first wc pad
    for ((r = 0; r < nr; r++)); do
        out="" ow=0 first=1
        for ((c = 0; c < nc; c++)); do
            if ((on[c] == 0)); then continue; fi
            k=$((r * nc + c))
            v=${cell[k]}; n=${vis[k]}; wc=${w[c]}
            if ((n > wc)); then ui_fit "$wc" "$v"; v=$UI_RET; n=$_UV; fi
            if ((r == 0)) && [[ -n $v ]]; then v="${UI_DIM}${v}${UI_NC}"; fi
            pad=${UI_SP:0:wc-n}
            if ((first == 0)); then out+="  "; ow=$((ow + 2)); fi
            first=0
            if [[ ${al[c]} == r ]]; then out+="${pad}${v}"; else out+="${v}${pad}"; fi
            ow=$((ow + wc))
        done
        if ((ow > avail)); then ui_fit "$avail" "$out"; out=$UI_RET; ow=$_UV; fi
        _ui_body "$out" "$ow"
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
    local -a vals
    for x in ${1:-}; do _ui_x100 "$x"; vals[n]=$_UX; n=$((n + 1)); done
    if ((wd <= 0)); then wd=$n; fi
    i=0; if ((n > wd)); then i=$((n - wd)); fi
    if [[ -n "${3:-}" ]]; then _ui_x100 "$3"; max=$_UX; else
        for ((k = i; k < n; k++)); do if ((vals[k] > max)); then max=${vals[k]}; fi; done
    fi
    for ((; i < n; i++)); do
        idx=0
        if ((max > 0)); then idx=$((vals[i] * 7 / max)); fi
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
    if [[ ! $x =~ ^[0-9]*\.?[0-9]*$ || -z $x ]]; then UI_RET="-"; return 0; fi
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

# ui_bytes_v bytes -> UI_RET: "512 B", "8.2 KB", "234 MB", "1.4 GB".
ui_bytes_v() {
    local b="${1:-0}" d=1 u=B t
    if [[ ! $b =~ ^[0-9]+$ ]]; then b=0; fi
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
    if [[ $UI_ISTTY == 1 && $UI_ROWS -gt 2 ]]; then UI_FB_MAX=$((UI_ROWS - 1)); fi
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
        printf '%s' "${pre}"$'\033[H'"${UI_FB}"$'\033[J'
    else
        if ((UI_FRAME_N > 0)); then pre=$'\n'; fi
        printf '%s' "${pre}${UI_FB}"
    fi
    UI_FB="" UI_FRAME_N=$((UI_FRAME_N + 1))
    return 0
}

# Show the cursor again. Call from EXIT/INT traps (ui_frame_begin installs
# them on a terminal when the caller has none; ui_frame_trap installs them).
ui_frame_cleanup() {
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
