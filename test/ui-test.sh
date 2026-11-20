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

# ---- swap_native and guard (lib/build.sh, lib/native.js) on fixture node_modules trees: a stub npm
# and a local fake registry, no network (test/native-test.sh, one FAIL line per failed check)
nt=$("$BASH_BIN" "$here/test/native-test.sh" 2>&1)
printf '%s\n' "$nt" | grep '^FAIL' || true
nt_n=$(printf '%s\n' "$nt" | sed -n 's/^native: \([0-9]*\) checks, \([0-9]*\) failed$/\1 \2/p')
if [[ -z $nt_n ]]; then bad "native-test.sh did not finish: $(printf '%s\n' "$nt" | tail -3)"
else
    checks=$((checks + ${nt_n% *})); fails=$((fails + ${nt_n#* }))
    echo "native: ${nt_n% *} checks, ${nt_n#* } failed"
fi

# ---- tando.conf: the client's parser, the server's configure, docs/CONFIG.md and `tando help conf`
# list the same keys. The keys are read from the code (the arms of the two `case $k in`), not from
# a list kept here: a key added to either without a row in docs/CONFIG.md and a line in
# lib/help-conf.txt fails; so does a documented key the parser rejects.
conf_arms() { # file start-regex end-regex: the labels of the 6-space case arms in that range, one key per line
    sed -n "/$2/,/$3/p" "$1" | perl -0777 -ne 's/\\\n\s*//g; for (/^ {6}([a-z][^\n) "]*)\)/mg) { print "$_\n" }' |
        tr '|' '\n' | sed 's/^job\.\*$/job.<name>/; s/^job\.\*\.timeout$/job.<name>.timeout/; s/^worker\.\*$/worker.<name>/' |
        sed 's/^worker\.\*\.\([a-z_]*\)$/worker.<name>.\1/' | sort -u
}
conf_client=$(conf_arms "$here/lib/common.sh" '^conf_load() {' '^  done < "\$f"')
# check, origin and force are words of the client's request to configure, not tando.conf keys
conf_server=$(conf_arms "$here/server/tando-agent" '^cmd_configure() {' '^  done <<< "\$input"' | grep -vx -e check -e origin -e force)
conf_doc=$(grep -o '^| `[^`]*`' "$here/docs/CONFIG.md" | sed 's/^| `//; s/`$//' | sort -u)
conf_code=$(printf '%s\n%s\n' "$conf_client" "$conf_server" | sort -u)
if [[ $(printf '%s\n' "$conf_code" | wc -l) -lt 40 ]]; then bad "tando.conf keys: read only $(printf '%s\n' "$conf_code" | wc -l) from the code"; else ok; fi
d=$(comm -13 <(echo "$conf_client") <(echo "$conf_server"))
if [[ -z $d ]]; then ok; else bad "tando.conf: configure accepts keys the client parser rejects: $(echo $d)"; fi
d=$(comm -23 <(echo "$conf_code") <(echo "$conf_doc"))
if [[ -z $d ]]; then ok; else bad "docs/CONFIG.md lacks keys the code accepts: $(echo $d)"; fi
d=$(comm -13 <(echo "$conf_code") <(echo "$conf_doc"))
if [[ -z $d ]]; then ok; else bad "docs/CONFIG.md lists keys the code rejects: $(echo $d)"; fi
d=""
while IFS= read -r k; do grep -q "^  $k " "$here/lib/help-conf.txt" || d="$d $k"; done <<< "$conf_code"
if [[ -z $d ]]; then ok; else bad "lib/help-conf.txt (tando help conf) lacks keys:$d"; fi
d=""
while IFS= read -r k; do   # the parser itself, on each documented key: none may be "unknown key"
    printf '%s = x\n' "${k/<name>/x}" > "$tmp/conf.t"
    r=$("$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; conf_load "$2"' _ "$here" "$tmp/conf.t" 2>&1)
    [[ $r != *"unknown key"* ]] || d="$d $k"
done <<< "$conf_doc"
if [[ -z $d ]]; then ok; else bad "the client parser rejects keys docs/CONFIG.md lists:$d"; fi
printf 'nokey = x\n' > "$tmp/conf.t"
r=$("$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; conf_load "$2"' _ "$here" "$tmp/conf.t" 2>&1)
if [[ $r == *"unknown key"* ]]; then ok; else bad "the parser check above cannot fail: an unknown key was not refused ($r)"; fi
# domain = takes host names only: nothing else reaches DNS lookups, the server or a Caddy site
d=""
for v in 'shop.example.org;id' 'shop.example.org/x' 'Shop.example.org' 'shop' '-shop.example.org' 'shop..example.org' \
         'shop.example.org.' '*.example.org' 'shop.example.org $(id)' 'shop-.example.org'; do
    printf 'domain = %s\n' "$v" > "$tmp/conf.t"
    r=$("$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; conf_load "$2" && echo "C_domain=$C_domain"' _ "$here" "$tmp/conf.t" 2>&1)
    [[ $r == *"not a domain name"* && $r != *C_domain=* ]] || d="$d [$v]"
done
printf 'domain = shop.example.org, www.example.co.uk\n' > "$tmp/conf.t"
r=$("$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; conf_load "$2" && echo "C_domain=$C_domain"' _ "$here" "$tmp/conf.t" 2>&1)
[[ $r == *"C_domain=shop.example.org www.example.co.uk" ]] || d="$d good:[$r]"
if [[ -z $d ]]; then ok; else bad "tando.conf domain = accepts what is not a host name, or refuses one:$d"; fi
out=$(TANDO_CONFIG_DIR=$tmp/cfg "$BASH_BIN" "$here/bin/tando" help conf 2>&1)
if [[ $out == *"docs/CONFIG.md"* && $out == *"release_timeout"* ]]; then ok; else bad "tando help conf: $out"; fi
mkdir -p "$tmp/proj" && printf '{"name":"x","scripts":{"start":"node a.js"}}\n' > "$tmp/proj/package.json"
(cd "$tmp/proj" && TANDO_CONFIG_DIR=$tmp/cfg "$BASH_BIN" "$here/bin/tando" init --yes > /dev/null 2>&1)
if grep -q 'tando help conf' "$tmp/proj/tando.conf" && ! grep -q 'README.md lists' "$tmp/proj/tando.conf"; then ok
else bad "tando init: its tando.conf does not point at tando help conf: $(cat "$tmp/proj/tando.conf" 2>&1)"; fi
d=$(grep -rn 'Docs vs code mismatches' "$here/docs/COMMANDS.md" "$here/README.md" "$here/docs/README.md" | head -2)
if [[ -z $d && -f $here/docs/DEV-NOTES.md ]]; then ok; else bad "docs/COMMANDS.md still has the developer notes: $d"; fi

# ---- www handling of a domain: the client's default_www (lib/cmd-domain.sh) and the server's
# (tando-agent) over one table, with a two-level public suffix (example.co.uk) like a plain apex
www_table="example.com:apex app.example.com:sub a.b.example.com:sub www.example.com:www
example.io:apex shop.example.io:sub example.co.uk:apex www.example.co.uk:www shop.example.co.uk:sub
example.org.uk:apex example.com.au:apex app.example.com.au:sub www.example.com.au:www
example.co.id:apex blog.example.co.id:sub example.web.id:apex example.my.id:apex
example.co.nz:apex example.co.jp:apex example.com.br:apex example.co.za:apex x.y.example.co.za:sub"
www_cli=$("$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; . "$1/lib/cmd-domain.sh"
    for e in $2; do printf "%s:%s:%s\n" "${e%%:*}" "$(www_kind "${e%%:*}")" "$(default_www "${e%%:*}")"; done' _ "$here" "$www_table")
www_sed='/^WWW_SFX2=/,/^"$/p; /^www_kind() {$/,/^}$/p; /^default_www() {/,/^}$/p'
www_srv=$("$BASH_BIN" -c 'eval "$(sed -n "$3" "$1/server/tando-agent")"
    for e in $2; do printf "%s:%s:%s\n" "${e%%:*}" "$(www_kind "${e%%:*}")" "$(default_www "${e%%:*}")"; done' _ "$here" "$www_table" "$www_sed")
www_want=""
for e in $www_table; do
    case ${e#*:} in sub) m=off;; *) m=redirect;; esac
    www_want="$www_want${e%%:*}:${e#*:}:$m
"
done
www_want=${www_want%$'\n'}
if [[ $www_cli == "$www_want" ]]; then ok; else bad "default_www (client) over the table: $(diff <(echo "$www_want") <(echo "$www_cli") | head -6)"; fi
if [[ $www_srv == "$www_want" ]]; then ok; else bad "default_www (server) over the table: $(diff <(echo "$www_want") <(echo "$www_srv") | head -6)"; fi
if [[ $www_cli == "$www_srv" ]]; then ok; else bad "client and server default_www disagree"; fi
if diff <(sed -n '/^WWW_SFX2=/,/^"$/p' "$here/lib/cmd-domain.sh") <(sed -n '/^WWW_SFX2=/,/^"$/p' "$here/server/tando-agent") > /dev/null &&
   [[ $(sed -n '/^WWW_SFX2=/,/^"$/p' "$here/lib/cmd-domain.sh") == *" co.uk "* ]]; then ok
else bad "the two-level suffix lists of lib/cmd-domain.sh and server/tando-agent differ"; fi
why=$("$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; . "$1/lib/cmd-domain.sh"; www_why example.co.uk; www_why app.example.co.uk; www_why www.example.com' _ "$here")
if [[ $why == *"example.co.uk is a registered name"*"app.example.co.uk is a sub-domain"*"www.example.com starts with www."* ]]; then ok
else bad "www_why: $why"; fi

# ---- tando doctor: programs that differ from the client's are one row (--verbose: each), the rest
# are untouched. The agent is a stub that answers with check rows.
doctor_run() { # verbose-or-empty differing-programs...: the rendered box
    local v=$1; shift
    "$BASH_BIN" -c '
        . "$1/lib/ui.sh"; . "$1/lib/common.sh"; . "$1/lib/deploy.sh"; . "$1/lib/views.sh"
        TMPD=$(mktemp -d); TAB=$(printf "\t"); HOST=vps; ARGS=(doctor); VERBOSE=$2; shift 2; ui_init 100
        resolve() { :; }; server_sums() { echo 1; }; client_version() { echo 1.2.3; }
        D=" $* "
        agent_raw() {
            printf "check\tok\tconnection\tssh ok\n"
            for p in agent gate logs metrics watch status daemon offsite host; do
                case $D in *" $p "*) printf "check\twarn\t%s\t1.0.0 here, 1.2.3 on the laptop: tando host setup <host>\n" "$p";;
                    *) printf "check\tok\t%s\t1.2.3, same as the client\n" "$p";; esac
            done
            printf "check\twarn\tdns\t*.example.co.uk does not resolve\n"
        }
        cmd_doctor; rm -rf "$TMPD"' _ "$here" "$v" "$@" 2>&1
}
out=$(doctor_run "" agent gate logs status)
flat=$(printf '%s' "$out" | tr -d '│\n' | tr -s ' ')
if [[ $flat == *"programs"*"4 of 9 programs differ from the client's 1.2.3: tando host setup vps"* ]] &&
   ! grep -Eq '^│ (agent|gate|logs|status) ' <<< "$out" && grep -Eq '^│ dns +.*warn' <<< "$out" &&
   grep -Eq '^│ metrics +.*ok' <<< "$out" && [[ $out == *"2 warnings"* ]]; then ok
else bad "doctor with 4 of 9 programs differing: not one row ($out)"; fi
out=$(doctor_run 1 agent gate logs status)
n=$(grep -Ec '^│ (agent|gate|logs|status) +.*warn' <<< "$out")
if [[ $n = 4 ]] && ! grep -Eq '^│ programs ' <<< "$out" && [[ $out == *"5 warnings"* ]]; then ok
else bad "doctor --verbose: want the 4 programs on their own rows ($n) and no collapsed row ($out)"; fi
out=$(doctor_run "")
if ! grep -Eq '^│ programs ' <<< "$out" && [[ $out == *"1 warning"* ]]; then ok; else bad "doctor with nothing differing shows a programs row ($out)"; fi
out=$(doctor_run "" agent)
if grep -Eq '^│ programs +.*warn' <<< "$out" && [[ $out == *"1 of 9 programs differ"* ]]; then ok; else bad "doctor with one program differing ($out)"; fi

echo "$checks checks, $fails failed"
[[ $fails == 0 ]]
