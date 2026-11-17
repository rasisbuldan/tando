#!/bin/bash
# s4-readers.sh <seconds> [app...]: hammer the read-only commands (laptop C) while other scenarios
# write. Every --json output must parse; no command may print a shell error or crash (exit > 1).
# Each finding goes to $E/log/s4-readers/violations with the command and the output kept.
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
race_init s4-readers
SECS=${1:-120}; shift
APPS=${*:-pr}
end=$(( $(date +%s) + SECS )); n=0
jsonok() { python3 -I -c 'import json,sys; json.load(sys.stdin)' < "$1" 2> /dev/null; }
# logs --json is JSON lines: every line one object
jsonlok() { python3 -I -c 'import json,sys
for l in sys.stdin:
    l = l.strip()
    if l: json.loads(l)' < "$1" 2> /dev/null; }
run() { # label json? cmd...
  local lab=$1 js=$2; shift 2
  local f=$LOG/cur.$$.$lab
  rX C "$@" > "$f" 2>&1; local rc=$?
  n=$((n + 1))
  local why=""
  [ $rc -gt 1 ] && why="exit $rc"
  bad_output "$f" > /dev/null && why="$why shell error: $(bad_output "$f" | head -1)"
  [ "$js" = 1 ] && [ $rc = 0 ] && ! jsonok "$f" && why="$why invalid JSON"
  [ "$js" = L ] && [ $rc = 0 ] && ! jsonlok "$f" && why="$why invalid JSON line"
  if [ -n "$why" ]; then
    RACE_V=$((RACE_V + 1))
    cp "$f" "$LOG/bad.$RACE_V.$lab"
    echo "[s4-readers] VIOL $* : $why (output: $LOG/bad.$RACE_V.$lab)" | tee -a "$LOG/violations" >&2
  fi
}
while [ "$(date +%s)" -lt "$end" ]; do
  run ls 0 ls; run lsj 1 ls --json; run lsall 0 ls --all; run lsallj 1 ls --all --json
  for a in $APPS; do
    run st 0 status "$a"; run stj 1 status "$a" --json
    run hi 0 history "$a"; run hij 1 history "$a" --json
    run re 0 releases "$a"; run rej 1 releases "$a" --json
    run lo 0 logs "$a" -n 20; run loj L logs "$a" -n 20 --json
    run env 0 env ls "$a"; run jobs 0 jobs ls "$a"; run bk 0 backup ls "$a"
  done
  run stall 0 status; run doc 0 doctor
done
echo "s4-readers: $n reads" >&2
race_result s4-readers "$n"
