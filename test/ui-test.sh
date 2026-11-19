#!/bin/bash
# Automated checks for lib/ui.sh. Run with /bin/bash (macOS bash 3.2) and bash 5.
# Also covers the interactive parts (test/ui-test-top.sh, the tando top mock from
# test/ui-demo.sh, and ui_key in a pseudo-terminal driven by test/top-pty.py).
#
#   /bin/bash test/ui-test.sh
#
# Renders every demo screen at widths 60, 80, 100, 120, under a UTF-8 locale
# and LC_ALL=C, with colour forced and not; strips ANSI (perl, independent of
# the bash code under test) and checks every line's visible width. Exits
# non-zero on any failure.
set -uo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
demo="$here/test/ui-demo.sh"
BASH_BIN=${BASH_BIN:-$BASH}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ui-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fails=0 checks=0

ok() { checks=$((checks + 1)); }
bad() { checks=$((checks + 1)); fails=$((fails + 1)); echo "FAIL: $*"; }

utf8="" locales=$(locale -a 2>/dev/null)
for l in en_US.UTF-8 C.UTF-8 C.utf8 en_US.utf8; do
    if printf '%s\n' "$locales" | grep -qix "$l"; then utf8=$l; break; fi
done
[[ -n $utf8 ]] || { echo "no UTF-8 locale found"; exit 1; }

# check_widths file width label: every non-empty line, ANSI stripped, is at
# most width columns; lines of a box (starting with a border glyph) are
# exactly width. Prints offending lines.
check_widths() {
    local out
    [[ -s $1 ]] || { bad "$3: no output ($1 missing or empty)"; return; }
    out=$(perl -CSD -Mutf8 -ne '
        BEGIN { $w = shift @ARGV; $n = 0 }
        chomp; s/\e\[[0-9;?]*[A-Za-z]//g; $n++;
        next if $_ eq "";
        $l = length($_);
        if (/^[╭│├╰+|]/) { print "line $n: width $l != $w: $_\n" if $l != $w }
        elsif ($l > $w) { print "line $n: width $l > $w: $_\n" }
        print "line $n: control char\n" if /[\x00-\x08\x0b-\x1f\x7f]/;
    ' "$2" "$1")
    if [[ -n $out ]]; then bad "$3"; echo "$out" | head -5; else ok; fi
}

has_esc() { LC_ALL=C grep -q $'\033' "$1"; }
non_ascii() { LC_ALL=C grep -q $'[\x80-\xff]' "$1"; }

# --- every screen, every width, both locales, colour forced and not ----------
for loc in "$utf8" C; do
    for w in 40 60 80 100 120; do
        for col in always auto; do
            for scr in ls status history deploy watch; do
                f="$tmp/$scr-$w-$loc-$col.out"
                label="$scr w=$w LC_ALL=$loc colour=$col"
                if ! env LC_ALL=$loc TANDO_COLOR=$col DEMO_DELAY=0 COLUMNS= \
                        "$BASH_BIN" "$demo" "$scr" "$w" > "$f" 2> "$f.err"; then
                    bad "$label: demo exited non-zero: $(head -3 "$f.err")"; continue
                fi
                if [[ -s $f.err ]]; then bad "$label: stderr: $(head -3 "$f.err")"; fi
                if [[ ! -s $f ]]; then bad "$label: no output"; continue; fi
                check_widths "$f" "$w" "$label"
                if [[ $col == auto ]]; then
                    if has_esc "$f"; then bad "$label: escape sequence in piped output"; else ok; fi
                else
                    if has_esc "$f"; then ok; else bad "$label: colour forced but no escapes"; fi
                fi
                if [[ $loc == C ]]; then
                    # Strip escapes, then the rest must be plain ASCII.
                    if perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g' "$f" | LC_ALL=C grep -q $'[\x80-\xff]'; then
                        bad "$label: non-ASCII output under LC_ALL=C"
                    else ok; fi
                fi
                if [[ $scr == watch ]]; then
                    n=$(grep -c 'frame [0-9]*/10' "$f" || true)
                    if [[ $n == 10 ]]; then ok; else bad "$label: expected 10 frames, got $n"; fi
                    if [[ $col == always ]]; then
                        n=$(perl -0ne 'print scalar(() = /\e\[H/g)' "$f")
                        if [[ $n == 10 ]]; then ok; else bad "$label: expected 10 cursor-home, got $n"; fi
                        if LC_ALL=C grep -q $'\033\\[2J' "$f"; then bad "$label: frame cleared the screen"; else ok; fi
                        if LC_ALL=C grep -q $'\033\\[?25h' "$f"; then ok; else bad "$label: cursor not restored"; fi
                    fi
                fi
            done
        done
    done
done

# --- tando top mock: every size from compact to wide, both locales, colour on/off
# The frame must fill the height exactly and every line must be the box width.
for loc in "$utf8" C; do
    for size in 40x12 60x18 79x30 80x19 80x24 100x30 120x40 120x60; do
        w=${size%x*} h=${size#*x}
        for col in always auto; do
            for scr in top top-log; do
                f="$tmp/$scr-$size-$loc-$col.out"
                label="$scr ${w}x$h LC_ALL=$loc colour=$col"
                if ! env LC_ALL=$loc TANDO_COLOR=$col COLUMNS= "$BASH_BIN" "$demo" "$scr" "$w" "$h" \
                        > "$f" 2> "$f.err"; then
                    bad "$label: demo exited non-zero: $(head -3 "$f.err")"; continue
                fi
                if [[ -s $f.err ]]; then bad "$label: stderr: $(head -3 "$f.err")"; fi
                check_widths "$f" "$w" "$label"
                n=$(perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g' "$f" | grep -c .)
                if [[ $n == "$h" ]]; then ok; else bad "$label: $n lines, want exactly $h"; fi
                if [[ $col == auto ]] && has_esc "$f"; then bad "$label: escape sequence in piped output"; fi
                if [[ $loc == C ]] && perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g' "$f" | LC_ALL=C grep -q $'[\x80-\xff]'; then
                    bad "$label: non-ASCII output under LC_ALL=C"
                fi
            done
        done
    done
    # unit checks of charts, panes, modal, table selection, keys, scrolling
    for w in 40 60 80 100 120; do
        for col in always never; do
            out=$(env LC_ALL=$loc TANDO_COLOR=$col COLUMNS= "$BASH_BIN" "$here/test/ui-test-top.sh" "$here" "$w" 2>&1)
            if [[ -n $out ]]; then bad "interactive unit checks w=$w LC_ALL=$loc colour=$col"; echo "$out" | head -5; else ok; fi
        done
    done
done
f="$tmp/top-modal.out"
env LC_ALL=$utf8 TANDO_COLOR=never COLUMNS= "$BASH_BIN" "$demo" top-modal 100 30 > "$f" 2>&1
# outside a terminal the modal box is printed after the frame, at its own width
head -n 30 "$f" > "$f.frame"; check_widths "$f.frame" 100 "top-modal 100x30 frame"
tail -n +31 "$f" > "$f.modal"
widths=$(perl -CSD -ne 's/\e\[[0-9;?]*[A-Za-z]//g; chomp; print length, "\n"' "$f.modal" | sort -u)
if [[ $(printf '%s\n' "$widths" | grep -c .) == 1 ]]; then ok
else bad "top-modal: modal lines differ in width"; fi
if grep -q 'Really restart hello' "$f"; then ok; else bad "top-modal shows no question"; fi
if grep -q 'compact\|tando top · vps-1 · hello' "$tmp/top-60x18-$utf8-auto.out"; then ok; else bad "60x18 is not the compact view"; fi
if grep -q '┬' "$tmp/top-120x40-$utf8-auto.out"; then ok; else bad "120x40 has no side-by-side panes"; fi

# --- ui_key in a pseudo-terminal (python3 drives the pty; skipped without it) -----
if command -v python3 > /dev/null; then
    cat > "$tmp/keys.sh" <<'EOF'
. "$1/lib/ui.sh"
ui_init
trap 'ui_frame_cleanup' EXIT
ui_term_enter
printf 'ready\r\n'
while :; do
    ui_key 1; rc=$?
    ((rc == 2)) && break
    ((rc == 1)) && continue
    printf 'key[%s]\r\n' "$UI_KEY"
    [[ $UI_KEY == q ]] && break
done
EOF
    printf '%s\n' 'wait ready' 'send j' 'send \e[A' 'send \e' 'sleep 0.3' 'send \eOB\e[6~' \
        'send \r' 'send jjjjjjjjjjjjjjjjjjjj' 'sleep 0.5' 'dump keys' 'send q' 'exit 5' > "$tmp/keys.steps"
    python3 "$here/test/top-pty.py" 30 60 "$tmp/keys.steps" -- /bin/bash -c \
        "$BASH_BIN $tmp/keys.sh $here; stty -a > $tmp/keys.stty" > "$tmp/keys.out" 2>&1
    got=$(grep -o 'key\[[^]]*\]' "$tmp/keys.out" | tr '\n' ' ')
    want="key[j] key[up] key[esc] key[down] key[pgdn] key[enter] key[j] key[j] key[j] key[j] key[j] key[j] key[j] key[j] "
    if [[ $got == "$want" ]]; then ok; else bad "ui_key in a pty: got [$got]"; fi
    if grep -q 'final: exit=0 cursor=visible altscreen=off' "$tmp/keys.out" &&
       grep -q '[^-]icanon' "$tmp/keys.stty" && ! grep -q -- '-echo ' "$tmp/keys.stty"; then ok
    else bad "ui_term_leave did not restore the terminal: $(grep final "$tmp/keys.out")"; fi
else
    echo "note: python3 missing, ui_key pty check skipped"
fi

# --- TANDO_ASCII=1 under a UTF-8 locale ----------------------------------------
f="$tmp/ascii.out"
env LC_ALL=$utf8 TANDO_ASCII=1 TANDO_COLOR=never COLUMNS= "$BASH_BIN" "$demo" all 72 > "$f" 2>&1
check_widths "$f" 72 "TANDO_ASCII=1 all w=72"
# Only the demo's own UTF-8 cell text (café) may be non-ASCII here.
if perl -ne 's/caf\xc3\xa9//g; exit 1 if /[\x80-\xff]/' "$f"; then ok; else bad "TANDO_ASCII=1 drew non-ASCII glyphs"; fi

# --- column dropping -----------------------------------------------------------
hdr() { grep -m1 'APP' "$tmp/ls-$1-$utf8-auto.out"; }
if hdr 120 | grep -q RESTARTS && hdr 120 | grep -q LINK; then ok; else bad "ls at 120 should show all columns: $(hdr 120)"; fi
if hdr 60 | grep -q RESTARTS; then bad "ls at 60 should drop RESTARTS: $(hdr 60)"; else ok; fi
if hdr 60 | grep -q LINK; then bad "ls at 60 should drop LINK: $(hdr 60)"; else ok; fi
if hdr 60 | grep -q MEMORY; then ok; else bad "ls at 60 must keep MEMORY (no priority)"; fi

# --- unit checks (run in a child bash so the library is tested under BASH_BIN) --
# No set -e: every check runs and reports. The last line is a sentinel, so a child that dies
# early (set -u, a syntax error, a helper that exits) cannot pass with empty output.
unit=$(env LC_ALL=$utf8 TANDO_COLOR=always COLUMNS= "$BASH_BIN" -c '
set -uo pipefail
. "$1/lib/ui.sh"
ui_init 40
fail() { echo "unit: $*"; }
eq() { if [[ "$2" != "$3" ]]; then fail "$1: got [$2] want [$3]"; fi; }
ui_dur_v 91;       eq dur91 "$UI_RET" "1m 31s"
ui_dur_v 45;       eq dur45 "$UI_RET" "45s"
ui_dur_v 3.24;     eq dur3.2 "$UI_RET" "3.2s"
ui_dur_v 7380;     eq dur2h "$UI_RET" "2h 03m"
ui_dur_v 270000;   eq dur3d "$UI_RET" "3d 3h"
ui_bytes_v 245366784; eq bytes234 "$UI_RET" "234 MB"
ui_bytes_v 1503238553; eq bytes1.4 "$UI_RET" "1.4 GB"
ui_bytes_v 512;    eq bytes512 "$UI_RET" "512 B"
eq dur_print "$(ui_dur 91)" "1m 31s"
ui_utc_v 1794675675;  eq utc "$UI_RET" "11-14 17:01"
ui_utc_v 1794675675 s; eq utc_s "$UI_RET" "11-14 17:01:15"
ui_utc_v 1709208000.5 s; eq utc_leap "$UI_RET" "02-29 12:00:00"
ui_utc_v -;           eq utc_none "$UI_RET" "-"
ui_utc_v 089;         eq utc_zero "$UI_RET" "-"
ui_utc_v 99999999999999999; eq utc_huge "$UI_RET" "-"
eq utc_print "$(ui_utc 0)" "01-01 00:00"
ui_width "${UI_RED}héllo${UI_NC}"; eq width "$UI_RET" 5
ui_fit 4 "${UI_GREEN}abcdef${UI_NC}"; eq fitc "$UI_RET" "${UI_GREEN}abc…"$'"'"'\033[0m'"'"'
ui_fit 3 "abcdef"; eq fit "$UI_RET" "ab…"
ui_fit 0 "abcdef"; eq fit0 "$UI_RET" ""
ui_width $'"'"'a\tb\rc\033[2Jd\033]0;x'"'"'; eq ctrl "$UI_RET" 10
ui_bar_v 75 100 4; eq bar75 "$UI_RET" "${UI_YELLOW}━━━${UI_NC}${UI_DIM}─${UI_NC}"
ui_bar_v 95 100 4; [[ $UI_RET == "$UI_RED"* ]] || fail "bar95 not red"
ui_bar_v 1 1000 4; eq bartiny "$UI_RET" "${UI_GREEN}━${UI_NC}${UI_DIM}───${UI_NC}"
ui_bar_v 0.5 2 4; eq bardec "$UI_RET" "${UI_GREEN}━${UI_NC}${UI_DIM}───${UI_NC}"
ui_spark_v "0 7 14" 5 14; eq spark "$UI_RET" "${UI_DIM}▁▁${UI_NC}${UI_ACCENT}▁▄█${UI_NC}"
ui_badge_v running; eq badge "$UI_RET" "${UI_GREEN}● running${UI_NC}"
# Column dropping and shrinking at width 40 (inside 36).
UI_TROWS=($'"'"'NAME\tSTATE\tLONG\tA\tB'"'"' $'"'"'hello\tok\tabcdefghijklmnopqrstuvwxyz\taaaaaaa\tbbbbbbb'"'"')
{ ui_box_open t; ui_table_a "l,l,l:6-30,l!1,l!2"; ui_box_close; } > /dev/null
eq dropB "$UI_TABLE_SHOWN" "11110"
# Nothing droppable left: widest columns shrink, the border holds.
UI_TROWS=($'"'"'NAME\tSTATE\tLONG\tA\tB'"'"' $'"'"'hello\tok\tabcdefghijklmnopqrstuvwxyz\taaaaaaaaaaaaaaaaaaaaaaaa\tbbbbbbb'"'"')
out=$(ui_box_open t; ui_table_a "l,l,l,l,l"; ui_box_close)
w=$(printf "%s\n" "$out" | sed -n 3p | perl -CSD -ne "chomp; s/\e\[[0-9;?]*[A-Za-z]//g; print length")
eq tablew "$w" 40
# Frame buffering: nothing is printed until ui_frame_end, one write.
f=$(ui_frame_begin; ui_box_open x; ui_box_line y; ui_box_close; echo -n "[mid]"; ui_frame_end)
[[ $f == "[mid]"* ]] || fail "frame printed before frame_end"
# Very long title and right text keep the border.
l=$(ui_box_open "$(printf "%080d" 0)" "$(printf "%080d" 0)" | perl -CSD -pe "s/\e\[[0-9;?]*[A-Za-z]//g")
eq titlew "${#l}" 40
# ui_box_wrap: commands, ids and links wrap between words, never cut, every line the box width
out=$(ui_box_open t; ui_box_wrap "  back to it: tando rollback 20261114-133723 --then something longer"
  ui_box_wrap "${UI_ACCENT}tando host add prod vmadmin@127.0.0.1 --port 2612 --key /tmp/k/id --yes${UI_NC}"
  ui_box_wrap "  https://a-long-name-that-keeps-going.apps.example.com/x"; ui_box_close)
plain=$(printf "%s\n" "$out" | perl -CSD -pe "s/\e\[[0-9;?]*[A-Za-z]//g")
[[ $plain == *"…"* ]] && fail "wrap: a line was cut with …"
for wd in 20261114-133723 /tmp/k/id --yes "tando host add prod"; do
  [[ $plain == *"$wd"* ]] || fail "wrap: \"$wd\" not shown whole"
done
[[ $(printf "%s\n" "$plain" | tr -d "│╭╰─╮╯ \n") == *"https://a-long-name-that-keeps-going.apps.example.com/x"* ]] ||
  fail "wrap: the long link is not all there"
w=$(printf "%s\n" "$plain" | perl -CSD -ne "chomp; print length(\$_), \" \"")
[[ $w == "40 "* && $w != *[!04\ ]* ]] || fail "wrap: line widths [$w], want all 40"
# ui_kv_wrap: the dns line of host setup at 80 columns wraps (it was cut with …); the command is
# on a line of its own, whole
out=$(ui_init 80; ui_box_open t
  ui_kv_wrap dns "none needed (sslip.io); your own domain: tando domain add example.com"; ui_box_close)
plain=$(printf "%s\n" "$out" | perl -CSD -pe "s/\e\[[0-9;?]*[A-Za-z]//g")
[[ $plain != *"…"* && $plain == *"│             tando domain add example.com "* ]] || fail "kv_wrap: dns line: $plain"
w=$(printf "%s\n" "$plain" | perl -CSD -ne "chomp; print length(\$_), \" \"")
[[ $w == "80 80 80 80 " ]] || fail "kv_wrap: line widths [$w], want 4 x 80"
# tando ls: the LINK column stays whole; other columns are dropped first
UI_TROWS=($'"'"'APP\tSTATE\tDEPLOYED\tMEMORY\tCPU\tUP\tLOGS\tLINK'"'"' $'"'"'hello\trunning\t3m ago\t40 MB\t1%\t2d 4h\t1 MB\thttps://hello.example.com'"'"')
out=$(ui_init 60; ui_box_open t; ui_table_a "l,l,l!3,r!2,r!4,r!5,r!6,l"; ui_box_close)
[[ $out == *"https://hello.example.com"* ]] || fail "ls table: LINK cut at 60 columns"
echo "unit checks: end"
' _ "$here" 2>&1)
if [[ $unit != "unit checks: end" ]]; then bad "unit checks"; echo "$unit"; else ok; fi

# --- timing: 40-row table frame -----------------------------------------------
timing=$(env LC_ALL=$utf8 TANDO_COLOR=always COLUMNS= "$BASH_BIN" -c '
. "$1/lib/ui.sh"
ui_init 120
UI_TROWS=($'"'"'APP\tSTATE\tRELEASE\tUPTIME\tCPU\tMEMORY\tRESTARTS\tLINK'"'"')
for ((i = 0; i < 40; i++)); do
    ui_badge_v running; b=$UI_RET; ui_bar_v $((i * 6)) 256 8
    UI_TROWS[${#UI_TROWS[@]}]="app-$i	$b	20261113-1015$i	2d 4h	1.$i%	$UI_RET $((i*6))/256 MB	$i	http://app-$i.localhost:8080"
done
rows=("${UI_TROWS[@]}")
frame() { UI_TROWS=("${rows[@]}"); ui_frame_begin; ui_box_open "tando ls" "vps-1"; ui_table_a "l,l,l!4,r!3,r!5,l,r!6,l:16-40!2"; ui_box_close "40 apps"; ui_frame_end; }
TIMEFORMAT="%U %S"   # CPU time, not wall clock: the same on a machine busy with test servers
t=$( { time { for ((k = 0; k < 20; k++)); do frame; done > /dev/null; } ; } 2>&1 )
echo "$t"
' _ "$here")
ms=$(perl -e '@t = split " ", $ARGV[0]; printf "%.1f", ($t[0] + $t[1]) * 1000 / 20' "$timing")
echo "timing: 40-row table frame at 120 columns, colour on: ${ms} ms per frame ($("$BASH_BIN" -c 'echo $BASH_VERSION'))"
if perl -e 'exit($ARGV[0] < 50 ? 0 : 1)' "$ms"; then ok; else bad "40-row frame took ${ms} ms of CPU (limit 50)"; fi

# ---- tando adopt site: the scan and the edit of a hand-written Caddyfile (server/tando-adopt) ----
# (the two functions are plain bash and awk: run here on fixtures, with this machine's awk)
AS=$(mktemp -d)
eval "$(sed -n '/^site_scan() {$/,/^}$/p; /^site_edit() {$/,/^}$/p' "$here/server/tando-adopt")"
# shellcheck disable=SC2034  # A is read by site_scan
A=shop
printf '\tlog {\n\t\toutput file /var/log/tando/shop/./access.log\n\t}\n' > "$AS/snip"
as_case() { # name want-scan file-body
  printf '%b' "$3" > "$AS/$1"
  site_scan "$AS/$1" 3100
  if [[ "$SP $SPB $SPHOLD $SO $SLOG $SLOGT" == "$2" ]]; then ok; else bad "adopt site scan $1: got '$SP $SPB $SPHOLD $SO $SLOG $SLOGT', want '$2'"; fi
}
as_case block "8 1 0 4 0 0" '{\n\tadmin off\n}\nexample.com, www.example.com {\n\tencode gzip\n\t# a comment {\n\thandle {\n\t\treverse_proxy 127.0.0.1:3100 {\n\t\t\theader_up X-Real-IP {remote_host}\n\t\t}\n\t}\n}\nother.example {\n\treverse_proxy 127.0.0.1:3200\n}\n'
site_edit "$AS/block" "$AS/snip" 1 1 > "$AS/block.new"
site_scan "$AS/block.new" 3100
if [[ "$SPHOLD $SLOGT" == "1 1" ]] && [[ $(grep -c lb_try_duration "$AS/block.new") == 1 ]] &&
   [[ $(sed -n 5p "$AS/block.new") == *"log {"* ]] && diff <(grep -v -e lb_try -e 'tando adopt site' -e 'log {' -e 'output file' -e '^	}$' "$AS/block.new") \
     <(grep -v '^	}$' "$AS/block") > /dev/null; then ok
else bad "adopt site edit (block form): $(cat "$AS/block.new")"; fi
as_case oneline "2 0 0 1 0 0" 'example.com {\n\treverse_proxy localhost:3100\n}\n'
site_edit "$AS/oneline" "$AS/snip" 1 0 > "$AS/oneline.new"
if [[ $(cat "$AS/oneline.new") == $'example.com {\n\treverse_proxy localhost:3100 {\n\t\t# added by tando adopt site: requests wait while the app restarts instead of 502\n\t\tlb_try_duration 15s\n\t\tlb_try_interval 100ms\n\t}\n}' ]]; then ok
else bad "adopt site edit (one-line form): $(cat "$AS/oneline.new")"; fi
as_case have "6 1 1 1 1 1" 'example.com {\n\tlog {\n\t\toutput file /var/log/tando/shop/./access.log\n\t}\n\thandle {\n\t\treverse_proxy 127.0.0.1:3100 {\n\t\t\tlb_try_duration 15s\n\t\t}\n\t}\n}\n'
as_case ownlog "3 0 0 1 1 0" 'example.com {\n\tlog\n\treverse_proxy 127.0.0.1:3100\n}\n'
as_case two "-1 0 0 0 0 0" 'a.example {\n\treverse_proxy 127.0.0.1:3100\n}\nb.example {\n\treverse_proxy 127.0.0.1:3100\n}\n'
# several reverse_proxy lines to the port are never edited; they count as held only when each holds
as_case twoheld "-1 0 1 0 0 0" 'a.example {\n\thandle /api/* {\n\t\treverse_proxy 127.0.0.1:3100 {\n\t\t\tlb_try_duration 15s\n\t\t}\n\t}\n\treverse_proxy 127.0.0.1:3100 {\n\t\tlb_try_duration 5s\n\t}\n}\n'
as_case twohalf "-1 0 0 0 0 0" 'a.example {\n\thandle /api/* {\n\t\treverse_proxy 127.0.0.1:3100 {\n\t\t\tlb_try_duration 15s\n\t\t}\n\t}\n\treverse_proxy 127.0.0.1:3100\n}\n'
as_case none "0 0 0 0 0 0" 'a.example {\n\treverse_proxy 127.0.0.1:31000\n\timport sites/*\n}\n'
rm -rf "$AS"

echo "$checks checks, $fails failed"
[[ $fails == 0 ]]
