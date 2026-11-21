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

# ---- what tando init detects for each framework fixture (test/detect-test.sh: test/fixtures/apps)
dt=$("$BASH_BIN" "$here/test/detect-test.sh" 2>&1)
printf '%s\n' "$dt" | grep '^FAIL' || true
dt_n=$(printf '%s\n' "$dt" | sed -n 's/^detect: \([0-9]*\) checks, \([0-9]*\) failed$/\1 \2/p')
if [[ -z $dt_n ]]; then bad "detect-test.sh did not finish: $(printf '%s\n' "$dt" | tail -3)"
else
    checks=$((checks + ${dt_n% *})); fails=$((fails + ${dt_n#* }))
    echo "detect: ${dt_n% *} checks, ${dt_n#* } failed"
fi

# ---- tando.conf: the client's parser, the server's configure, docs/CONFIG.md and `tando help conf`
# list the same keys. The keys are read from the code (the arms of the two `case $k in`), not from
# a list kept here: a key added to either without a row in docs/CONFIG.md and a line in
# lib/help-conf.txt fails; so does a documented key the parser rejects.
conf_arms() { # file start-regex end-regex: the labels of the 6-space case arms in that range, one key per line
    sed -n "/$2/,/$3/p" "$1" | perl -0777 -ne 's/\\\n\s*//g; for (/^ {6}([a-z][^\n) "]*)\)/mg) { print "$_\n" }' |
        tr '|' '\n' | sed 's/^job\.\*$/job.<name>/; s/^job\.\*\.\([a-z]*\)$/job.<name>.\1/; s/^worker\.\*$/worker.<name>/' |
        sed 's/^worker\.\*\.\([a-z_]*\)$/worker.<name>.\1/' | sort -u
}
conf_client=$(conf_arms "$here/lib/common.sh" '^conf_load() {' '^  done < "\$f"')
# check, origin and force are words of the client's request to configure, not tando.conf keys
conf_server=$(conf_arms "$here/server/tando-agent" '^cmd_configure() {' '^  done <<< "\$input"' | grep -vx -e check -e origin -e force -e 'job.<name>.cron')
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

# job schedules: the cron syntax becomes systemd's OnCalendar (cron_to_cal in lib/common.sh), exactly
# or not at all. One line per case: <cron text>|<OnCalendar>, or |!<the refusal, saying what to write>.
# The same expressions are checked against systemd-analyze and a reference of the cron rules by
# test/e2e-jobs.sh (J2).
cron_table() { cat <<'CRON'
* * * * *|*-*-* *:*:00
0 * * * *|*-*-* *:00:00
5 * * * *|*-*-* *:05:00
59 23 31 12 *|*-12-31 23:59:00
0 0 1 1 *|*-01-01 00:00:00
*/15 * * * *|*-*-* *:00/15:00
*/5 * * * *|*-*-* *:00/5:00
*/2 * * * *|*-*-* *:00/2:00
*/10 * * * *|*-*-* *:00/10:00
*/20 * * * *|*-*-* *:00/20:00
*/30 * * * *|*-*-* *:00,30:00
*/7 * * * *|*-*-* *:00/7:00
*/59 * * * *|*-*-* *:00,59:00
0,15,30,45 * * * *|*-*-* *:00/15:00
0,30 * * * *|*-*-* *:00,30:00
1,2 * * * *|*-*-* *:01,02:00
1-5 * * * *|*-*-* *:01..05:00
10-20 * * * *|*-*-* *:10..20:00
0-59 * * * *|*-*-* *:*:00
10-50/10 * * * *|*-*-* *:10/10:00
10-40/10 * * * *|*-*-* *:10,20,30,40:00
0-30/15 * * * *|*-*-* *:00,15,30:00
5-59/15 * * * *|*-*-* *:05/15:00
0 */2 * * *|*-*-* 00/2:00:00
0 */6 * * *|*-*-* 00/6:00:00
0 */5 * * *|*-*-* 00/5:00:00
0 8-17 * * *|*-*-* 08..17:00:00
0 9-17/2 * * *|*-*-* 09,11,13,15,17:00:00
0 0,12 * * *|*-*-* 00,12:00:00
0 22,23,0 * * *|*-*-* 00,22,23:00:00
30 2 1 * *|*-*-01 02:30:00
0 0 */2 * *|*-*-01/2 00:00:00
0 0 1-7 * *|*-*-01..07 00:00:00
0 0 1,15 * *|*-*-01,15 00:00:00
0 0 1,2,3 * *|*-*-01..03 00:00:00
0 0 */10 * *|*-*-01/10 00:00:00
0 0 31 * *|*-*-31 00:00:00
0 0 * * *|*-*-* 00:00:00
0 0 * 1 *|*-01-* 00:00:00
0 0 * jan *|*-01-* 00:00:00
0 0 * JAN,Jul *|*-01,07-* 00:00:00
0 0 * jan-mar *|*-01..03-* 00:00:00
0 0 * 1-3 *|*-01..03-* 00:00:00
0 0 * */3 *|*-01/3-* 00:00:00
0 0 * */2 *|*-01/2-* 00:00:00
0 0 * 2,5,8,11 *|*-02/3-* 00:00:00
0 0 * * 0|Sun *-*-* 00:00:00
0 0 * * 7|Sun *-*-* 00:00:00
0 0 * * sun|Sun *-*-* 00:00:00
0 0 * * SUN|Sun *-*-* 00:00:00
0 0 * * 1|Mon *-*-* 00:00:00
0 0 * * mon-fri|Mon..Fri *-*-* 00:00:00
0 0 * * 1-5|Mon..Fri *-*-* 00:00:00
0 0 * * MON-FRI|Mon..Fri *-*-* 00:00:00
0 0 * * sat,sun|Sat,Sun *-*-* 00:00:00
0 0 * * 6,0|Sat,Sun *-*-* 00:00:00
0 0 * * 0-2|Mon,Tue,Sun *-*-* 00:00:00
0 0 * * 5-7|Fri..Sun *-*-* 00:00:00
0 0 * * 1,3,5|Mon,Wed,Fri *-*-* 00:00:00
0 0 * * 1-3,5|Mon..Wed,Fri *-*-* 00:00:00
0 0 * * */2|Tue,Thu,Sat,Sun *-*-* 00:00:00
0 0 * * 0-6|*-*-* 00:00:00
0 0 * * 0-7|*-*-* 00:00:00
0 0 * * *|*-*-* 00:00:00
0 0 */2 * mon|Mon *-*-01/2 00:00:00
0 0 * * wed|Wed *-*-* 00:00:00
15 4 * jan,jul *|*-01,07-* 04:15:00
0 9 * * mon-fri|Mon..Fri *-*-* 09:00:00
30 8 1 1 *|*-01-01 08:30:00
  0   9  *  *  1  |Mon *-*-* 09:00:00
@hourly|*-*-* *:00:00
@daily|*-*-* 00:00:00
@midnight|*-*-* 00:00:00
@weekly|Sun *-*-* 00:00:00
@monthly|*-*-01 00:00:00
@yearly|*-01-01 00:00:00
@annually|*-01-01 00:00:00
@HOURLY|*-*-* *:00:00
@reboot|!@reboot is not a schedule: a job runs at times (a command to start at boot is not a job)
@every|!"@every" is not a schedule: @hourly, @daily, @weekly, @monthly, @yearly or five fields
5/15 * * * *|!"5/15" (minute): a step needs * or a range (cron does not take 5/15); write 5-59/15, or list the values
0 0 1 * mon|!day-of-month and weekday are both set: cron runs on either, a systemd schedule only when both match. Use two jobs (one with the day of month, one with the weekday), or put * in one of the two fields
0 0 1-31 * mon|!day-of-month and weekday are both set: cron runs on either, a systemd schedule only when both match. Use two jobs (one with the day of month, one with the weekday), or put * in one of the two fields
0 0 1 * 1-5|!day-of-month and weekday are both set: cron runs on either, a systemd schedule only when both match. Use two jobs (one with the day of month, one with the weekday), or put * in one of the two fields
61 * * * *|!"61" is outside the minute field's range 0-59
60 * * * *|!"60" is outside the minute field's range 0-59
* 24 * * *|!"24" is outside the hour field's range 0-23
0 0 0 * *|!"0" is outside the day-of-month field's range 1-31
0 0 32 * *|!"32" is outside the day-of-month field's range 1-31
0 0 * 0 *|!"0" is outside the month field's range 1-12
0 0 * 13 *|!"13" is outside the month field's range 1-12
0 0 * * 8|!"8" is outside the weekday field's range 0-7
0 0 * * 5-1|!"5-1" (weekday) goes backwards; cron has no wrap-around: write two ranges, like 22-23,0-5
0 0 5-1 * *|!"5-1" (day-of-month) goes backwards; cron has no wrap-around: write two ranges, like 22-23,0-5
*/0 * * * *|!"*/0" (minute): a step of 0
*/x * * * *|!the step in "*/x" (minute) is not a number
a * * * *|!"a" in the minute field is not a number
0 0 * foo *|!"foo" in the month field is not a number or name
0 0 * * funday|!"funday" in the weekday field is not a number or name
0 0 ? * *|!"?" (day-of-month) is a Quartz extension (L, W, #, ?), not cron: tando takes the 5-field cron of crontab(5)
0 0 L * *|!"l" in the day-of-month field is not a number
0 0 * * 1#2|!"1#2" (weekday) is a Quartz extension (L, W, #, ?), not cron: tando takes the 5-field cron of crontab(5)
0 0 15W * *|!"15w" in the day-of-month field is not a number
0 0 * * 5L|!"5l" in the weekday field is not a number or name
0,,5 * * * *|!the minute field "0,,5" has an empty item
,5 * * * *|!the minute field ",5" has an empty item
5, * * * *|!the minute field "5," has an empty item
1-2-3 * * * *|!"2-3" in the minute field is not a number
-5 * * * *|!"-5" in the minute field is not a number
* * * *|!cron has five fields (minute hour day-of-month month weekday), got 4
* * * * * *|!cron has five fields (minute hour day-of-month month weekday), got 6
0 0 * * * 2026|!cron has five fields (minute hour day-of-month month weekday), got 6
*/5 */2 * * *|*-*-* 00/2:00/5:00
0-5,10-15 * * * *|*-*-* *:00..05,10..15:00
0 0 1,3-5,9 * *|*-*-01,03..05,09 00:00:00
CRON
}
d="" n=0
while IFS='|' read -r e want; do
    n=$((n + 1))
    got=$("$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; if cron_to_cal "$2"; then echo "$CRON_CAL"; else echo "!$CRON_WHY"; fi' _ "$here" "$e")
    [[ $got == "$want" ]] || d="$d [$e: want $want, got $got]"
done < <(cron_table)
if [[ -z $d && $n -ge 100 ]]; then ok; else bad "cron schedules ($n cases):$d"; fi
# a cron schedule in tando.conf: translated before anything is sent, with what was written kept
# beside it; an OnCalendar one is left alone; a refused one names the file, the line and the job
printf 'app = x\njob.sync = */15 * * * * | node a.js | tee log\njob.nightly = daily | node b.js\njob.mon = 0 9 * * mon-fri | echo hi\n' > "$tmp/conf.t"
r=$("$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; conf_load "$2" && printf "%s" "$C_jobs"' _ "$here" "$tmp/conf.t" 2>&1)
want=$'job.sync=*-*-* *:00/15:00 | node a.js | tee log\njob.sync.cron=*/15 * * * *\njob.nightly=daily | node b.js\njob.mon=Mon..Fri *-*-* 09:00:00 | echo hi\njob.mon.cron=0 9 * * mon-fri'
if [[ $r == "$want" ]]; then ok; else bad "tando.conf job lines with cron schedules: $r"; fi
printf 'app = x\njob.sync = 0 0 1 * mon | node a.js\n' > "$tmp/conf.t"
r=$("$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; conf_load "$2"' _ "$here" "$tmp/conf.t" 2>&1)
if [[ $r == *"conf.t:2: job.sync: 0 0 1 * mon: day-of-month and weekday are both set"* ]]; then ok; else bad "a cron schedule cron cannot say in systemd: $r"; fi
d=""
for l in 'job.a = | echo hi' 'job.a = daily |' 'job.a = daily' 'job.a.spread = 5' 'job.a = daily | x
job.a.spread = 4000' 'job.a = daily | x
job.a.missed = maybe' 'job_spread = -1' 'job_missed = often' 'job.a = daily | x
job.a.timeout = 0'; do
    printf 'app = x\n%s\n' "$l" > "$tmp/conf.t"
    r=$("$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; conf_load "$2"' _ "$here" "$tmp/conf.t" 2>&1) && d="$d [accepted: $l]"
done
printf 'app = x\njob.a = daily | x\njob.a.spread = 0\njob.a.missed = skip\njob_spread = 30\njob_missed = run\n' > "$tmp/conf.t"
"$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; conf_load "$2"' _ "$here" "$tmp/conf.t" > /dev/null 2>&1 || d="$d [refused the good job settings]"
if [[ -z $d ]]; then ok; else bad "job settings in tando.conf:$d"; fi
# a job name the server cannot take (it is part of the unit names) is refused with the rule, at its line
d=""
for l in 'job.abcdefghijklmnopqrstuv = daily | x' 'job.9am = daily | x' 'job.a_b = daily | x' 'job.abcdefghijklmnopqrstuv.timeout = 5'; do
  printf 'app = x\n%s\n' "$l" > "$tmp/conf.t"
  r=$("$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; conf_load "$2"' _ "$here" "$tmp/conf.t" 2>&1) && d="$d [accepted: $l]"
  [[ $r == *"conf.t:2: bad job name: "*"(lower case letters, digits and dashes, starting with a letter, at most 21 characters)"* ]] || d="$d [$l: $r]"
done
printf 'app = x\njob.abcdefghijklmnopqrstu = daily | x\n' > "$tmp/conf.t"
"$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; conf_load "$2"' _ "$here" "$tmp/conf.t" > /dev/null 2>&1 || d="$d [refused a name of 21]"
if [[ -z $d ]]; then ok; else bad "job names in tando.conf:$d"; fi
# a time a day or more away: its date, with the year when that is not this year (a Feb 29 job)
r=$("$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; . "$1/lib/views.sh"; NOW=1795200000
  printf "%s|%s|%s|%s" "$(ago 1835481540)" "$(ago 1797000000)" "$(ago 1764000000)" "$(ago 1795198380)"' _ "$here" 2>&1)
if [[ $r == "2028-02-29 23:59 GMT|12-11 14:40 GMT|2025-11-24 16:00 GMT|27m ago" ]]; then ok; else bad "ago with the year: $r"; fi

# ---- monitoring views (lib/views.sh) on stub status rows: tando ls / status rendered from a file
# the stub agent prints; $tmp/mon.st holds the rows (host, app, alert, server, ...)
mon_rows() { # the default stub: one host, apps web (running) and api (running, an alert firing)
    local n; n=$(date +%s)
    printf 'host\tvps\t2\t0.40\t2000000000\t500000000\t40000000000\t10000000000\t86400\n'
    printf 'app\tweb\tactive\t3001\t20261101-101010\tok\t52428800\t134217728\t9000000000\t0\t3600\thttp://web.example.test\tnode\toff\t-\t-\t1000\t2000\t10\t0\t-\t-\t1024\t256\t-\t123\n'
    printf 'app\tapi\tactive\t3002\t20261101-101010\tok\t52428800\t134217728\t9000000000\t0\t3600\thttp://api.example.test\tnode\tdaily\t%s\t-\t1000\t2000\t10\t0\t-\t-\t1024\t256\t-\t-\n' $((n - 30 * 3600))
    printf 'alert\tapi\thttp\tfiring\t%s\t5xx 12%% of 300 requests\n' $((n - 120))
}
mon_run() { # code: run with the views loaded, the stub agent answering from $tmp/mon.st
    "$BASH_BIN" -c '
        . "$1/lib/ui.sh"; . "$1/lib/common.sh"; . "$1/lib/deploy.sh"; . "$1/lib/views.sh"
        TMPD=$(mktemp -d); CFG=$TMPD; HOST=vps; APP=""; JSON=""; WATCH=""; ui_init 80
        resolve() { :; }
        agent_raw() { cat "$MON_ST"; }
        fetch_status; eval "$2"; rc=$?; rm -rf "$TMPD"; exit $rc' _ "$here" "$1" 2>&1
}
export MON_ST=$tmp/mon.st
mon_rows > "$MON_ST"
# --watch: a refresh that hangs is cut after WATCH_TIMEOUT and the next frame says the data is
# stale and why; one that fails says so too (it used to repaint the old numbers silently)
out=$(mon_run 'WATCH=1 WATCH_TIMEOUT=2; n=0
  fetch() { [ -f "$TMPD/calls" ] || { : > "$TMPD/calls"; fetch_status; return; }; sleep 30; }
  rend() { n=$((n + 1)); [ $n -ge 3 ] && exit 0; render_ls; }
  s=$SECONDS; n=0; watch_loop rend fetch' | perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g')
if [[ $out == *"updated 0s ago"*"every 1s"*"not answering: no answer within 2 s"*"STALE: data "*" old, reconnecting"* ]]; then ok
else bad "ls --watch: a hung refresh does not show as stale ($out)"; fi
out=$(mon_run 'WATCH=1; n=0
  fetch() { [ -f "$TMPD/calls" ] || { : > "$TMPD/calls"; fetch_status; return; }; echo "ssh: connect to host vps port 22: Connection refused" >&2; return 255; }
  rend() { n=$((n + 1)); [ $n -ge 3 ] && exit 0; APP=web; render_status; }
  watch_loop rend fetch' | perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g')
if [[ $out == *"not answering: ssh: connect to host vps port 22: Connection refused"*"STALE: data "* ]]; then ok
else bad "status --watch: a failed refresh does not show as stale ($out)"; fi

# tando ls: an app with a firing alert has it in an ALERT column (a column only while one fires),
# the footer counts it; --json carries alerts_firing and firing per app
out=$(mon_run 'render_ls' | perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g')
if grep -Eq '^│ APP +STATE +ALERT ' <<< "$out" && grep -Eq '^│ api +● running +http ' <<< "$out" &&
   grep -Eq '^│ web +● running +- ' <<< "$out" && [[ $out == *"1 alert firing: tando alerts"* ]]; then ok
else bad "ls: the firing alert is not shown per app ($out)"; fi
out=$(mon_run 'JSON=1; render_ls')
if [[ $out == *'"app":"api",'*'"alerts_firing":1,"firing":"http"'* && $out == *'"app":"web",'*'"alerts_firing":0,"firing":null'* ]]; then ok
else bad "ls --json: no alerts_firing per app ($out)"; fi
grep -v '^alert' "$MON_ST" > "$tmp/mon.st2"
out=$(MON_ST=$tmp/mon.st2 mon_run 'render_ls')
if grep -Eq '^│ APP +STATE +DEPLOYED' <<< "$out"; then ok; else bad "ls: an ALERT column with nothing firing ($out)"; fi
# status: memory says what it counts (anon + shmem, the same in ls, top, the graph and the alert)
out=$(mon_run 'APP=web; render_status' | perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g')
if grep -Eq '^│ memory .* 50 MB of 128 MB  in use, not cache' <<< "$out"; then ok; else bad "status: memory without its label ($out)"; fi
# status: the backup age is judged by backup_hours (the alert's threshold, from the backupcfg row),
# red past it; 50 h without the row (an older tando-watch). The stub's api backed up 30 h ago.
out=$(mon_run 'APP=api; grep -v "^app${TAB}web" "$TMPD/st" > "$TMPD/x"; mv "$TMPD/x" "$TMPD/st"; render_status' | perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g')
if grep -Eq '^│ backup +daily, last .* GMT  late after 50 h' <<< "$out"; then ok; else bad "status: backup age without backup_hours ($out)"; fi
{ cat "$MON_ST"; printf 'backupcfg\tapi\t24\ton\n'; } > "$tmp/mon.st3"
out=$(TANDO_COLOR=always MON_ST=$tmp/mon.st3 mon_run 'APP=api; grep -v "^app${TAB}web" "$TMPD/st" > "$TMPD/x"; mv "$TMPD/x" "$TMPD/st"; render_status')
out=$(grep 'backup' <<< "$out")
if [[ $out == *"daily, "*"31m"*"last "*" GMT: over 24 h, the backup alert fires"* ]]; then ok
else bad "status: a backup older than backup_hours is not red ($out)"; fi
# health and requests say which p95 they show: the probe's (24 h) or real requests' (the window)
out=$("$BASH_BIN" -c '. "$1/lib/ui.sh"; . "$1/lib/common.sh"; . "$1/lib/views.sh"; . "$1/lib/cmd-health.sh"; ui_init 80
  TMPD=$(mktemp -d); HOST=vps; NOW=$(date +%s); found=""
  printf "up\tweb\t9990\t9990\t1440\t10080\t0\t12\t30\t5,6,7\tok\t11\t\n" > "$TMPD/hl"; hl_all; rm -rf "$TMPD"' _ "$here" 2>&1)
if [[ $out == *"PROBE P95"*"P95: tando-watch's probe, 24 h; real traffic: tando requests"* ]]; then ok
else bad "health: the p95 does not say it is the probe's ($out)"; fi
# CPU is the last minute's (the app row's 26th field, per mille) in ls, status and --json alike;
# "-" without a sample (it was the average since the app started, or a delta while watching)
out=$(mon_run 'render_ls' | perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g')
if grep -Eq '^│ APP .* MEMORY +CPU 1M ' <<< "$out" && grep -Eq '^│ web .* 50 MB +12% ' <<< "$out" &&
   grep -Eq '^│ api .* 50 MB +- ' <<< "$out"; then ok; else bad "ls: cpu is not the last minute's ($out)"; fi
out=$(mon_run 'APP=web; render_status' | perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g')
if grep -Eq '^│ cpu +12%  last minute' <<< "$out"; then ok; else bad "status: cpu is not the last minute's ($out)"; fi
out=$(mon_run 'JSON=1; render_ls')
if [[ $out == *'"app":"web",'*'"cpu_percent":12.3,'*'"app":"api",'*'"cpu_percent":null,'* ]]; then ok
else bad "ls --json: cpu_percent is not the last minute's ($out)"; fi
# tando top: the firing check after the app's state, the count in the host strip
out=$("$BASH_BIN" -c '
    . "$1/lib/ui.sh"; . "$1/lib/common.sh"; set +u; TAB=$(printf "\t"); AGENT_BIN=/opt/tando/bin/tando-agent; . "$1/lib/cmd-top.sh"
    ui_init 100; UI_ROWS=20 UI_COLS=100 TOP_H=0 SEL=0 SEL_APP=web AP_N=0 TOP_DETAIL=0 TOP_VIEW=main TOP_MODAL=""
    TOP_INT=2 TOP_RO=0 TOP_CDETAIL=0 APPS_TOP=0 G_BK=60 D_REL=() D_HIST=() HV_ROWS=() TOP_KEYS_L="" TOP_KEYS_R=""
    TH_NAME=(vps) TH_ST=(ok) TH_ERR=("") TH_PID=("") TH_T0=(0) TH_OKAT=(0) TH_CLK=(0)
    TH_LOAD=(0) TH_CPUS=(1) TH_MT=(0) TH_MU=(0) TH_DT=(0) TH_DU=(0) TH_NAPPS=(0) TH_NBAD=(0)
    GH_M=() GH_C=() GL_M=() GL_C=() GL_N=()
    { cat "$2"; printf "clock\t1795200000.5\n"; } > "$3"; TH_GOOD=("$3")
    top_parse 0 1; ui_frame_begin; top_draw_main; ui_frame_end' _ "$here" "$MON_ST" "$tmp/top.data" 2>&1 |
    perl -pe 's/\e\[[0-9;?]*[A-Za-z]//g')
if grep -Eq '│ +api +● running http ' <<< "$out" && [[ $out == *"apps 2  1 alert"* ]]; then ok
else bad "top: the firing alert is not shown ($out)"; fi

echo "$checks checks, $fails failed"
[[ $fails == 0 ]]
