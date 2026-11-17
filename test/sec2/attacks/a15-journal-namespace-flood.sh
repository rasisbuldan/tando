#!/bin/bash
# A15 (threat 1): every app can write into every other app's journal namespace (the sockets in
# /run/systemd/journal.tando-<app>/ are 0666 and visible in the unit). tando logs filters by
# _SYSTEMD_UNIT, so forged lines do not show, but they count against bravo's cap (log_max, 50M default)
# and evict bravo's real history; they also inflate bravo's log statistics (tando status/top).
. "$(dirname "$0")/lib.sh"
first() { rootsh 'journalctl --namespace=tando-bravo -u tando-bravo.service -o short-unix --no-pager -q | head -1 | cut -c1-80'; }
rootsh 'journalctl --namespace=tando-bravo --disk-usage'
b0=$(first); echo "bravo's oldest own line before: $b0"
XT=300 x 'for i in $(seq 1 1600); do head -c 45000 /dev/urandom | base64 -w0 | logger -u /run/systemd/journal.tando-bravo/dev-log -t tando-bravo --size 70000 2>/dev/null; done; echo sent'
sleep 3
rootsh 'journalctl --namespace=tando-bravo --disk-usage; journalctl --namespace=tando-bravo -o verbose -n1 --no-pager | grep -E "_SYSTEMD_UNIT|_UID"'
b1=$(first); echo "bravo's oldest own line after:  $b1"
[ -n "$b0" ] || inconclusive "bravo has no log line to watch"
[ "$b0" != "$b1" ] && succeeded "alpha evicted bravo's own log history"
# history kept: blocked only when none of alpha's lines reached bravo's namespace (the fix closes
# it); lines that landed without evicting anything mean the cap was not reached: inconclusive
forged=$(rootsh 'journalctl --namespace=tando-bravo _UID=$(id -u tando-alpha) -q --no-pager | wc -l' | tr -d ' ')
case $forged in ""|*[!0-9]*) inconclusive "could not count alpha's lines in bravo's namespace";; esac
[ "$forged" = 0 ] && blocked "nothing alpha wrote reached bravo's journal namespace"
inconclusive "$forged of alpha's lines in bravo's namespace, history still there (cap not reached?)"
