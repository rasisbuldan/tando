#!/bin/bash
# Unit checks for the interactive parts of lib/ui.sh (charts, panes, modal, table selection,
# key parsing, scrolling). Called by test/ui-test.sh under each locale; prints one line per
# failure and nothing when all is well.
#   ui-test-top.sh <repo root> <width>
set -u
# lint: file-allow RL03 $RT is the repository root passed by test/ui-test.sh
RT=$1
. "$RT/lib/ui.sh"
W=$2
ui_init "$W"
fail() { echo "top-unit(LC_ALL=${LC_ALL:-} w=$W): $*"; }
eq() { if [[ "$2" != "$3" ]]; then fail "$1: got [$2] want [$3]"; fi; }
# visible width of every line of $1 (escape sequences removed) via perl, one per line
widths() { printf '%s\n' "$1" | perl -CSD -ne 'chomp; s/\e\[[0-9;?]*[A-Za-z]//g; print length, "\n"'; }
allw() { # label text width: every line exactly width
    local w
    for w in $(widths "$2"); do if [[ $w != "$3" ]]; then fail "$1: a line is $w wide, want $3"; return; fi; done
}

# --- charts: exactly width x height, any data, any locale
for spec in "20 5" "1 1" "7 2" "60 8" "$((W - 4)) 4"; do
    set -- $spec
    ui_chart_v "0 1 2 3 4 5 - 7 8 9 10 50 100 3.5 0" "$1" "$2" "" "memory 12 MB" "max 100"
    eq "chart $spec lines" "${#UI_CHART[@]}" "$2"
    allw "chart $spec" "$(printf '%s\n' "${UI_CHART[@]}")" "$1"
    ui_chart_v "" "$1" "$2"
    eq "empty chart $spec lines" "${#UI_CHART[@]}" "$2"
    allw "empty chart $spec" "$(printf '%s\n' "${UI_CHART[@]}")" "$1"
done
ui_chart_v "10 10" 4 2 10
_ui_vis "${UI_CHART[1]}"; eq "chart full bottom row" "$_UP" "  ${UI_G_CHART[8]}${UI_G_CHART[8]}"
ui_chart_v "0" 3 1 10
_ui_vis "${UI_CHART[0]}"; eq "chart zero baseline" "$_UP" "  ${UI_G_CHART[1]}"

# --- two panes: every edge and line exactly UI_W, long text cut
lw=$(((UI_W - 7) / 2))
out=$(
    ui_split_edge top "$lw" "a very long left pane title that will not fit anywhere at all" "right title" "right side text"
    ui_split_line "$(printf 'x%.0s' {1..300})" "$(printf 'y%.0s' {1..300})" "$lw"
    ui_split_line "" "" "$lw"
    ui_split_line "${UI_RED}red${UI_NC} text" "é ü ${UI_G_OK}" "$lw"
    ui_split_edge mid "$lw" "l" "r"
    ui_split_edge join "$lw"
    ui_split_edge sep "$lw" "" ""
    ui_split_edge bottom "$lw" "keys" "" "more keys on the right"
)
allw "split panes" "$out" "$UI_W"
eq "split pane line count" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 8
for lw in 1 5 $((UI_W - 12)); do
    out=$(ui_split_edge top "$lw" "x" "y"; ui_split_line "abc" "def" "$lw"; ui_split_edge bottom "$lw")
    allw "split lw=$lw" "$out" "$UI_W"
done

# --- table lines with a selection gutter
UI_TROWS=($'APP\tSTATE\tLINK' $'hello\tok\thttp://hello.localhost:8080' $'site\tdown\thttp://site.localhost:8080')
ui_table_lines "l,l,l:6-40!1" 24 2
for ((i = 0; i < ${#UI_TLINES[@]}; i++)); do
    _ui_vis "${UI_TLINES[i]}"
    if ((_UV > 24)); then fail "table_lines row $i is $_UV wide"; fi
done
_ui_vis "${UI_TLINES[2]}"; eq "selected row pointer" "${_UP:0:2}" "$UI_G_PTR "
_ui_vis "${UI_TLINES[1]}"; eq "unselected row gutter" "${_UP:0:2}" "  "
ui_sel_v "${UI_GREEN}hello${UI_NC} world" 12; _ui_vis "$UI_RET"; eq "sel_v width" "$_UV" 12

# --- flow into lines
ui_flow_v 20 "aaaa aaaa" "bbbbbbbbbbbbbbb" "cc" "$(printf 'd%.0s' {1..40})"
for l in "${UI_FLOW[@]}"; do ui_width "$l"; if ((UI_RET > 20)) && [[ $l != d* ]]; then fail "flow line $UI_RET wide"; fi; done
eq "flow lines" "${#UI_FLOW[@]}" 3

# --- modal: printed box outside a frame, overlay inside a frame
out=$(ui_modal "Confirm" "y yes" "Really restart hello on vps-1?" "" "$(printf 'z%.0s' {1..200})")
w1=$(widths "$out" | sort -u)
if [[ $(printf '%s\n' "$w1" | wc -l | tr -d ' ') != 1 ]] || ((w1 > UI_W)); then fail "modal widths: $w1"; fi
UI_CTRL=1 UI_ROWS=20 UI_COLS=$W
ui_frame_begin; ui_box_open t; ui_box_close
ui_modal "Confirm" "y yes" "line one" "$(printf 'z%.0s' {1..200})"
ovl=$UI_FB_OVL
UI_FRAMING=0 UI_FB=""
printf '%s' "$ovl" | perl -CSD -ne '
    BEGIN { ($rows, $cols) = @ARGV[0, 1]; @ARGV = () }
    for my $p (split /\e\[(?=\d+;\d+H)/) {
        next unless $p =~ /^(\d+);(\d+)H(.*)$/s;
        my ($r, $c, $t) = ($1, $2, $3); $t =~ s/\e\[[0-9;?]*[A-Za-z]//g;
        print "modal row $r col $c width ", length($t), " leaves the screen\n"
            if $r < 1 || $r > $rows || $c < 1 || $c + length($t) - 1 > $cols;
    }' 20 "$W" | while read -r l; do fail "$l"; done
eq "modal has 4 overlay lines" "$(printf '%s' "$ovl" | perl -ne 'print scalar(() = /\e\[\d+;\d+H/g)')" 4
UI_CTRL=0

# --- key parsing
k() { UI_KQ=(); _ui_kq_parse "$1"; local IFS=,; echo "${UI_KQ[*]+"${UI_KQ[*]}"}"; }
eq "keys arrows" "$(k $'\033[A\033[B\033[C\033[D')" "up,down,right,left"
eq "keys SS3 arrows" "$(k $'\033OA\033OB')" "up,down"
eq "keys paging" "$(k $'\033[5~\033[6~\033[H\033[F\033[1~\033[4~\033[Z')" "pgup,pgdn,home,end,home,end,backtab"
eq "keys lone esc" "$(k $'\033')" "esc"
eq "keys esc then q" "$(k $'\033q')" "esc,q"
eq "keys plain" "$(k $'jk\t \177\r?')" "j,k,tab,space,backspace,enter,?"
eq "keys queue capped" "$(k jjjjjjjjjjjjjjjjjjjj)" "j,j,j,j,j,j,j,j"
eq "keys unknown sequence ignored" "$(k $'\033[15~x')" "x"
UI_KQ=(a b c); _ui_kq_pop; eq "kq pop" "$UI_KEY:${UI_KQ[*]+"${UI_KQ[*]}"}" "a:b c"

# --- scrolling
ui_scroll_v 100 10 95; eq "scroll clamp end" "$UI_RET" 90
ui_scroll_v 100 10 -3; eq "scroll clamp start" "$UI_RET" 0
ui_scroll_v 5 10 3; eq "scroll short" "$UI_RET" 0
ui_scroll_v 100 10 4 1; eq "scroll follow" "$UI_RET" 90
# --- hostile numbers from a server never run code (SECURITY-REVIEW-2 N4) -----------------
HX=$(mktemp -d "${TMPDIR:-/tmp}/ui-hostile.XXXXXX")
M=$HX/PWNED
HOSTILE=("a[\$(touch $M)]" "AP_NAME[\$(touch $M)]" "UI_G_SPARK[\$(touch $M)]" '1+1' '0x10' '$(id)'
         "\$(touch $M)" '`touch '"$M"'`' "$(printf '9%.0s' {1..40})" '-5' '08' '1.2.3' '' ' 3' 'x')
for h in "${HOSTILE[@]}"; do
    if ui_int "$h"; then fail "ui_int accepts [$h]"; fi
    case $h in 1+1|0x10|-5|08|1.2.3) ui_dec "$h" && fail "ui_dec accepts [$h]" ;; esac
    hv=$h; ui_nums hv; eq "ui_nums [$h]" "$hv" 0
    hv=$h; ui_nums -d hv; [[ $hv == 0 ]] || fail "ui_nums -d [$h] -> [$hv]"
    ui_bar_v "$h" "$h" 6; ui_bar_v 5 "$h" 6; ui_meter_v cpu "$h" "$h" 6
    ui_spark_v "$h 1 $h" 6 "$h"; ui_chart_v "$h 1 2" 6 3 "$h" "x" "y"
    ui_dur_v "$h"; ui_bytes_v "$h"; _ui_x100 "$h"
done 2> /dev/null
for ok in 0 7 1794586225 123456789012345678; do ui_int "$ok" || fail "ui_int refuses $ok"; done
for ok in 0.42 3 12.5; do ui_dec "$ok" || fail "ui_dec refuses $ok"; done
v1=12 v2=0.5 v3=abc; ui_nums v1 v3; ui_nums -d v2; eq "ui_nums keeps numbers" "$v1 $v2 $v3" "12 0.5 0"

# tando top: a status/metrics answer with a hostile value in every field, parsed and drawn
(
    set +u      # lib/cmd-top.sh runs under bin/tando, without -u
    TAB=$'\t' AGENT_BIN=/opt/tando/bin/tando-agent
    is_num() { case $1 in ""|*[!0-9]*) return 1;; esac; }
    valid_app() { case $1 in [a-z]*) case $1 in *[!a-z0-9-]*) return 1;; esac; return 0;; esac; return 1; }
    . "$RT/lib/cmd-top.sh"
    UI_ROWS=30 UI_COLS=100 TOP_H=0 SEL=0 SEL_APP=hello AP_N=0 TOP_DETAIL=1 TOP_VIEW=main TOP_MODAL=""
    TOP_INT=2 TOP_RO=0 TOP_CDETAIL=0 APPS_TOP=0 G_BK=60 D_REL=() D_HIST=() HV_ROWS=() TOP_KEYS_L="" TOP_KEYS_R=""
    TH_NAME=(t) TH_ST=(ok) TH_ERR=("") TH_PID=("") TH_T0=(0) TH_OKAT=(0) TH_CLK=(0)
    TH_LOAD=(0) TH_CPUS=(1) TH_MT=(0) TH_MU=(0) TH_DT=(0) TH_DU=(0) TH_NAPPS=(0) TH_NBAD=(0)
    GH_M=() GH_C=() GL_M=() GL_C=() GL_N=()
    for h in "${HOSTILE[@]}"; do
        {
            printf 'host\tsrv\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$h" "$h" "$h" "$h" "$h" "$h" "$h"
            printf 'app\thello\tactive\t%s\trel\tverified\t%s\t%s\t%s\t%s\t%s\tlink\tnode\tdaily\t%s\t-\n' \
                "$h" "$h" "$h" "$h" "$h" "$h" "$h"
            printf 'app\tAP_NAME[$(touch %s)]\tactive\t1\tr\tv\t1\t1\t1\t1\t1\tl\tn\toff\t-\t-\n' "$M"
            printf '@detail\thello\nrel\t%s\t%s\t%s\t%s\n' "$h" "$h" "$h" "$h"
            printf 'hist\thello\t%s\tid\tdeploy\tok\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\n' "$h" "$h" "$h" "$h" "$h" "$h" "$h" "$h"
            printf '@metrics\thello\nmx\t%s\t%s\nm\t%s\t%s\t%s\t%s\t%s\n' "$h" "$h" "$h" "$h" "$h" "$h" "$h"
            printf 'm\t1794586200\t%s\t%s\t0\tr\n' "$h" "$h"
            printf 'clock\t%s\n' "$h"
        } > "$HX/data"
        TH_GOOD=("$HX/data")
        top_parse 0 1; top_parse 0 1
        ui_frame_begin; top_draw_main; ui_frame_end
        TOP_DETAIL=0; ui_frame_begin; top_draw_compact; ui_frame_end; TOP_DETAIL=1
        : > "$HX/done.top"
    done > /dev/null 2>&1
)
if [[ -e $M ]]; then fail "a hostile server field ran a command in tando top"; fi
[[ -e $HX/done.top ]] || fail "the hostile tando top run did not finish"

# views.sh cpu_min (tando ls / status): the last-minute cpu field of an app row
if [[ -f $RT/lib/views.sh && -f $RT/lib/common.sh ]]; then
    (
        set +u
        . "$RT/lib/common.sh"; . "$RT/lib/views.sh"
        NOW=1000
        for h in "${HOSTILE[@]}"; do cpu_min "$h"; done
        : > "$HX/done.views"
    ) > /dev/null 2>&1
    if [[ -e $M ]]; then fail "a hostile cpu field ran a command in views.sh cpu_min"; fi
    [[ -e $HX/done.views ]] || fail "the hostile cpu_min run did not finish"
fi
rm -rf "$HX"
exit 0
