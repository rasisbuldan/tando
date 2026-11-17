#!/bin/bash
# Client side under long watching: run a tando command on a pty for <secs> seconds; record total
# client CPU (/usr/bin/time -l of the whole tree), RSS of the tando bash process every 15 s, and
# the number of ssh invocations (round trips) through a counting ssh shim.
# usage: test/load/client-watch.sh <label> <secs> <outdir> tando-args...
set -u
. "$(dirname "$0")/lib.sh"
. "$LROOT/test/lib.sh"          # t_pty
label=$1 secs=$2 out=$3; shift 3
mkdir -p "$out"
export SSH_COUNT_FILE=$out/$label.ssh PATH=$LROOT/test/load/shim:$PATH
: > "$SSH_COUNT_FILE"; : > "$out/$label.rss"
( t0=$(date +%s); sleep 5
  while [ $(( $(date +%s) - t0 )) -lt "$secs" ]; do
    pids=$(pgrep -f "bin/tando $1" | tr '\n' ',' | sed 's/,$//')
    [ -n "$pids" ] && printf '%s\t%s\t%s\n' "$(( $(date +%s) - t0 ))" "$(ps -o rss= -p "$pids" | awk '{s+=$1} END{print s}')" \
      "$(ps -o time= -p "$pids" | tr '\n' ' ')" >> "$out/$label.rss"
    sleep 15
  done ) &
sp=$!
/usr/bin/time -l /bin/bash -c '. "$1"; shift; t_pty 120 40 "$@"' _ "$LROOT/test/lib.sh" "$secs" "$R" "$@" > "$out/$label.pty" 2> "$out/$label.time"
kill $sp 2> /dev/null; wait $sp 2> /dev/null
printf '%s secs=%s ssh_calls=%s user_s=%s sys_s=%s maxrss_kb=%s rss_first_kb=%s rss_last_kb=%s load1=%s\n' "$label" "$secs" \
  "$(wc -l < "$SSH_COUNT_FILE" | tr -d ' ')" "$(awk '/ user /{print $3}' "$out/$label.time")" "$(awk '/ sys/{print $5}' "$out/$label.time")" \
  "$(awk '/maximum resident/{print int($1/1024)}' "$out/$label.time")" "$(head -1 "$out/$label.rss" | cut -f2)" "$(tail -1 "$out/$label.rss" | cut -f2)" "$(load1)" | tee -a "$out/summary.txt"
