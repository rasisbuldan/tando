#!/bin/bash
# Run client commands against the hostile wrapper; report PWN markers, terminal-control bytes,
# time and output size per command. Usage: hostile-run.sh <label> <server verbs...> -- <tando args...>
set -u
. /tmp/tando-secb.ZyNr20/env.sh
label=$1; shift; vs=()
while [ "$1" != -- ]; do vs+=("$1"); shift; done; shift
printf '%s\n' "${vs[@]}" | rootsh 'cat > /opt/tando/hostile/verbs'
rm -f $W/PWN*
o=$W/out/h-$label.out
t0=$(date +%s)
(cd $W/w/alpha && TANDO_COLOR=never perl -e "alarm 120; exec @ARGV" "$R" "$@" > "$o" 2>&1 < /dev/null); rc=$?
t1=$(date +%s)
pw=$(ls $W/PWN* 2>/dev/null | tr '\n' ' ')
esc=$(LC_ALL=C grep -c $'[\x1b\x07\x9b]' "$o")
echo "$label rc=$rc secs=$((t1-t0)) bytes=$(wc -c < "$o") pwn=[${pw}] esc_lines=$esc  first: $(LC_ALL=C tr -d '\000' < "$o" | grep -v '^$' | head -1 | cut -c1-100)"
: | rootsh 'cat > /opt/tando/hostile/verbs'
