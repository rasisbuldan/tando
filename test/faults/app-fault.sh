#!/bin/bash
# app-fault.sh <id> <behaviour of v3> <want: version that should serve 60 s later> [current behaviour]
# Deploy a misbehaving release v3 over a good v2 under load; watch 60 s more.
. "$(dirname "$0")/lib-fault.sh"
ID=$1 BEH=$2 WANT=$3 CURB=${4:-ok}
f_init "$ID" "app: $BEH" "deploy${4:+ over current '$CURB'}"
A=f$(echo "$ID" | tr -cd 'a-z0-9' | cut -c1-12)
f_fresh $A ${EXTRA:+"$EXTRA"}
[ "$CURB" = ok ] || { deploy $A 2 "$CURB" || exit 1; }
loop_start $A
T0=$(date +%s)
deploy $A 3 "$BEH"
log "deploy rc=$DRC in $(( $(date +%s) - T0 ))s: $(grep -E 'live in|rolled|failed|pre-flight|after the switch|crash|exited|answer' "$W/$A.d3.out" | head -3 | tr '\n' ' ')"
sleep 60
loop_stop
case $WANT in
  2) ok "deploy reports failure" test "$DRC" != 0;;
  3) ok "deploy reports success" test "$DRC" = 0;;
esac
ok "no failed request ($F_BAD of $F_N, longest gap ${F_GAP}s)" test "$F_BAD" = 0
truth $A "$WANT"
srv "sudo journalctl --namespace=tando-$A --disk-usage 2>/dev/null; sudo du -sh /var/log/journal 2>/dev/null; df -h / | tail -1" >&2
next_deploy $A 4
f_end
