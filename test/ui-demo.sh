#!/bin/bash
# Demo of lib/ui.sh with fake data, so the look can be judged.
#
#   test/ui-demo.sh [all|ls|status|history|deploy|watch|top|top-modal|top-log] [width] [height]
#
# Width defaults to $COLUMNS, then the terminal, then 80. The top screens are a static
# mock of `tando top` drawn by the real lib/cmd-top.sh code with fake data; height
# defaults to 24 (below 80x20 the dashboard switches to its compact view). TANDO_COLOR=always
# forces colour (e.g. when piping into less -R). DEMO_DELAY sets the pause
# between watch frames (default 0.5 seconds).
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../lib/ui.sh
. "$here/lib/ui.sh"

screen=all width="" height=""
for a in "$@"; do
    case $a in
        [0-9]*) if [[ -z $width ]]; then width=$a; else height=$a; fi ;;
        *) screen=$a ;;
    esac
done
ui_init "$width"

# Append one tab-separated row to UI_TROWS.
row() { local IFS=$'\t'; UI_TROWS[${#UI_TROWS[@]}]="$*"; }

# Memory cell: bar against the cap, then "82/256 MB".
mem_cell() {
    ui_bar_v "$1" "$2" 8
    MEM_CELL="$UI_RET $1/$2 MB"
}

# --- 1. tando ls -------------------------------------------------------------
screen_ls() {
    local cpu="${1:-23}" mem="${2:-1430}" n=0 f1 f2 f3 bw=10
    if ((UI_IN < 90)); then bw=8; fi
    ui_box_open "tando ls" "vps-1 ${UI_G_MID} 5 apps"
    ui_meter_v cpu "$cpu" 100 "$bw"; f1=$UI_RET
    ui_meter_v mem "$mem" 2048 "$bw" "$((mem * 10 / 1024 / 10)).$((mem * 10 / 1024 % 10))/2.0 GB"; f2=$UI_RET
    ui_meter_v disk 41 100 "$bw"; f3=$UI_RET
    ui_flow "$f1" "$f2" "$f3" "${UI_DIM}load${UI_NC} 0.42 0.38 0.30"
    ui_box_sep
    UI_TROWS=()
    row APP STATE RELEASE UPTIME CPU MEMORY RESTARTS LINK
    ui_badge_v running; local b_run=$UI_RET
    mem_cell 82 256;  row hello  "$b_run" 20261113-101500 "2d 4h" "1.2%" "$MEM_CELL" 0 http://hello.localhost:8080
    mem_cell 41 128;  row site   "$b_run" 20261112-174203 "18h 03m" "0.1%" "$MEM_CELL" 0 http://site.localhost:8080
    mem_cell 233 256; ui_badge_v deploying; row api    "$UI_RET" 20261113-120944 "3m 12s" "38.5%" "$MEM_CELL" 2 http://api.localhost:8080
    mem_cell 0 512;   ui_badge_v failed;  row worker "$UI_RET" 20261110-090000 "-" "-" "$MEM_CELL" 5 http://worker.localhost:8080
    mem_cell 0 64;    ui_badge_v stopped; row blog   "$UI_RET" 20261101-080000 "-" "-" "$MEM_CELL" 0 http://blog.localhost:8080
    ui_table_a "l,l,l!3,r!4,r!2,l,r!6,l:16-40!5"
    ui_box_close "5 apps ${UI_G_MID} 2 running ${UI_G_MID} 1 failed" "updated 12:09:44"
}

# --- 2. tando status hello -------------------------------------------------------
screen_status() {
    local bw=24 samples="0.8 1.1 0.9 1.4 2.0 1.2 0.7 3.9 7.1 4.2 1.8 1.1 0.9 1.0 1.6 2.2 1.4 0.9 1.3 1.1 0.8 1.0 1.5 1.2"
    if ((UI_IN < 70)); then bw=14; fi
    ui_box_open "hello" "vps-1 ${UI_G_MID} node"
    ui_kv state "$(ui_badge running)  ${UI_DIM}since 11 Nov 08:02, 2d 4h${UI_NC}"
    ui_kv release "20261113-101500  $(ui_badge verified)"
    ui_kv link "http://hello.localhost:8080"
    ui_bar_v 82 256 "$bw"
    ui_kv memory "$UI_RET  82 MB / 256 MB  ${UI_DIM}32%${UI_NC}"
    ui_spark_v "$samples" "$bw"
    ui_kv cpu "$UI_RET  1.2%  ${UI_DIM}peak 7.1%${UI_NC}"
    ui_kv restarts "0"
    ui_kv port "4101  ${UI_DIM}tando-hello.service${UI_NC}"
    ui_box_sep "releases"
    UI_TROWS=()
    ui_badge_v current;  row "20261113-101500" "$(ui_badge verified)" "$UI_RET" "2h ago" "v14 add health endpoint"
    row "20261112-174203" "$(ui_badge bad)" "" "18h ago" "v13 caf$(printf '\303\251') menu (health check failed)"
    row "20261112-101115" "$(ui_badge verified)" "" "1d ago" "v12"
    row "20261110-090000" "$(ui_badge verified)" "" "3d ago" "v11"
    ui_table_a "l,l,l!2,r!3,l:10-60!1"
    ui_box_sep "recent deploys"
    ui_table "l,l,l,r,r!1" <<EOF
TIME (GMT)	RELEASE	RESULT	TOTAL	UPLOAD
11-13 10:15	20261113-101500	$(ui_badge verified)	$(ui_dur 41)	1.2 MB
11-12 17:42	20261112-174203	$(ui_badge bad rolled-back)	$(ui_dur 74)	88 KB
11-12 10:11	20261112-101115	$(ui_badge verified)	$(ui_dur 38)	$(ui_bytes 2457600)
EOF
    ui_box_close "tando logs -f ${UI_G_MID} tando history"
}

# --- 3. tando history ---------------------------------------------------------
screen_history() {
    local i
    ui_box_open "tando history hello" "last 8"
    UI_TROWS=()
    row "TIME (GMT)" RELEASE KIND RESULT TOTAL BUILD PACK UPLOAD COPY PREFLT SWITCH HEALTH
    row "11-13 10:15" 20261113-101500 deploy "$(ui_badge verified)" 41s 18.2 0.4 6.1 1.3 9.8 0.2 4.9
    row "11-12 17:51" 20261112-101115 rollback "$(ui_badge verified)" 7s - - - - - 0.2 6.4
    row "11-12 17:42" 20261112-174203 deploy "$(ui_badge bad)" "1m 14s" 17.9 0.4 0.9 1.1 52.0 - -
    row "11-12 10:11" 20261112-101115 deploy "$(ui_badge verified)" 38s 16.0 0.3 5.5 1.2 9.9 0.2 4.6
    row "11-10 09:00" 20261110-090000 deploy "$(ui_badge verified)" "2m 3s" 61.4 1.8 41.0 2.2 10.1 0.2 5.0
    row "11-09 22:14" 20261109-221400 deploy "$(ui_badge failed)" 12s 11.9 - - - - - -
    row "11-09 21:58" 20261109-215800 deploy "$(ui_badge verified)" 44s 19.0 0.4 7.7 1.3 10.2 0.2 5.1
    row "11-08 14:30" 20261108-143000 up "$(ui_badge verified)" "3m 41s" 70.2 2.0 121.4 3.1 12.0 0.3 11.8
    ui_table_a "l,l,l!7,l,r,r!3,r!6,r!2,r!5,r!1,r!8,r!4"
    ui_box_close "seconds per phase"
}

# --- 4. deploy in progress, then a failed one ----------------------------------
screen_deploy() {
    ui_box_open "deploy hello ${UI_G_TO} vps-1" "release 20261113-121530"
    ui_step 1 7 build ok "18.2s  npm run build"
    ui_step 2 7 pack ok "0.4s  214 files, 3.1 MB"
    ui_step 3 7 upload ok "6.1s  12 changed, 1.2 MB sent"
    ui_step 4 7 copy ok "1.3s"
    ui_step 5 7 preflight run "4s  starting on :4187, GET /health"
    ui_step 6 7 switch pending
    ui_step 7 7 health pending
    ui_box_close "Ctrl-C detaches, the server keeps going"
    ui_box_open "deploy hello ${UI_G_TO} vps-1" "release 20261113-121944"
    ui_step 1 7 build ok "17.9s"
    ui_step 2 7 pack ok "0.4s  214 files, 3.1 MB"
    ui_step 3 7 upload ok "0.9s  1 changed, 4 KB sent"
    ui_step 4 7 copy ok "1.1s"
    ui_step 5 7 preflight fail "52.0s  GET /health answered 502 for 30s, see tando logs"
    ui_step 6 7 switch skip
    ui_step 7 7 health skip
    ui_box_line ""
    ui_box_line "${UI_RED}${UI_G_ERR} release 20261113-121944 marked bad${UI_NC}; the running app was not touched"
    ui_box_close "still serving 20261113-101500"
}

# --- 5. --watch ----------------------------------------------------------------
screen_watch() {
    local i cpu mem
    for ((i = 0; i < 10; i++)); do
        cpu=$((15 + RANDOM % 70)) mem=$((1100 + RANDOM % 800))
        ui_frame_begin
        screen_ls "$cpu" "$mem"
        ui_box_line "${UI_DIM}frame $((i + 1))/10, Ctrl-C to stop${UI_NC}"
        ui_frame_end
        if ((i < 9)); then sleep "${DEMO_DELAY:-0.5}"; fi
    done
    ui_frame_cleanup
}

# --- 6. tando top: the real drawing code, fake data ------------------------------
screen_top() {
    local rows=${height:-24} i
    set +eu        # lib/cmd-top.sh runs under bin/tando, which uses neither -e nor -u
    TAB=$'\t' AGENT_BIN=/opt/tando/bin/tando-agent
    is_num() { case $1 in ""|*[!0-9]*) return 1;; esac; }
    valid_app() { case $1 in [a-z]*) return 0;; esac; return 1; }
    # shellcheck source=../lib/cmd-top.sh
    . "$here/lib/cmd-top.sh"
    UI_ROWS=$rows UI_COLS=$UI_W
    TOP_INT=2 TOP_RO=0 TOP_VIEW=main TOP_DETAIL=1 TOP_CDETAIL=1 TOP_MODAL="" TOP_H=0 SEL=2 SEL_APP=hello
    TH_NAME=(vps-1 vps-2) TH_ST=(ok err) TH_ERR=("" "ssh: connect to host 203.0.113.9 port 22: Connection refused")
    TH_PID=("" "") TH_T0=(0 0) TH_OKAT=($SECONDS -1) TH_CLK=(1794590000 1794589950)
    TH_LOAD=(0.42 1.10) TH_CPUS=(2 4) TH_MT=(2147483648 8589934592) TH_MU=(1503238553 2147483648)
    TH_DT=(42949672960 85899345920) TH_DU=(17609365913 21474836480) TH_NAPPS=(5 3) TH_NBAD=(1 0)
    AP_N=5 APPS_TOP=0
    AP_NAME=(api blog hello site worker) AP_STATE=(deploying inactive active active failed)
    AP_REL=(20261113-120944 20261101-080000 20261113-101500 20261112-174203 20261110-090000)
    AP_RST=(verified verified verified verified bad) AP_MEM=(244318208 0 85983232 42991616 0)
    AP_MAX=(268435456 67108864 268435456 134217728 536870912) AP_PCT=(385 - 12 1 -)
    AP_RS=(2 0 0 0 5) AP_UP=(192 0 187200 64980 0) AP_PORT=(4102 4104 4100 4101 4103)
    AP_LINK=(http://api.localhost:8080 http://blog.localhost:8080 http://hello.localhost:8080 http://site.localhost:8080 http://worker.localhost:8080)
    AP_RECIPE=(node static node static node) AP_BK=(off off daily off off) AP_LAST=(- - 1794560000 - -) AP_DB=(- - - - -)
    D_REL=("20261113-101500${TAB}verified${TAB}1${TAB}1" "20261112-174203${TAB}bad${TAB}0${TAB}0" "20261112-101115${TAB}verified${TAB}0${TAB}0")
    D_HIST=("1794500000${TAB}20261112-101115${TAB}deploy${TAB}ok${TAB}38.0" "1794530000${TAB}20261112-174203${TAB}deploy${TAB}rolledback${TAB}74.2"
            "1794545000${TAB}20261112-101115${TAB}rollback${TAB}ok${TAB}7.1" "1794580000${TAB}20261113-101500${TAB}deploy${TAB}ok${TAB}41.3")
    G_BK=60 GH_M=() GH_C=() GL_M=() GL_C=() GL_N=()
    local b0=$((1794590000 / 60)) k m c
    for ((k = 0; k < 160; k++)); do
        m=$(( 70000000 + (k * 37 % 23) * 400000 + (k > 120 ? (k - 120) * 300000 : 0) ))
        c=$(( 8 + (k * 13 % 17) + (k % 29 == 0 ? 60 : 0) + (k > 140 ? 30 : 0) ))
        GH_M[b0 - 160 + k]=$m GH_C[b0 - 160 + k]=$c
    done
    GL_M[b0]=85983232 GL_C[b0]=12 GL_N[b0]=1
    case $screen in
        top-modal) TOP_MODAL=confirm TOP_ACT=restart TOP_ACT_APP=hello TOP_ACT_HOST=vps-1 ;;
        top-log)
            TOP_VIEW=log LOG_APP=hello LOG_HOST=vps-1 LOG_FOLLOW=1 LOG_TOP=0 LOG_N=0 LOG_CAP=2000
            for ((k = 0; k < 40; k++)); do
                LOG_L[k]="2026-11-13T10:$((15 + k / 6)):$((10 + k)) vps-1 tando-hello[812]: GET /api/items/$k 200 $((3 + k % 7))ms"
            done
            LOG_N=40 ;;
    esac
    ui_frame_begin
    if [[ $TOP_VIEW == log ]]; then top_draw_log
    elif ((UI_W < 80 || rows < 20)); then top_draw_compact
    else top_draw_main; fi
    top_draw_modal
    ui_frame_end
}

case $screen in
    ls) screen_ls ;;
    status) screen_status ;;
    history) screen_history ;;
    deploy) screen_deploy ;;
    watch) screen_watch ;;
    top|top-modal|top-log) screen_top ;;
    all) screen_ls; echo; screen_status; echo; screen_history; echo; screen_deploy ;;
    *) echo "usage: $0 [all|ls|status|history|deploy|watch] [width]" >&2; exit 2 ;;
esac
