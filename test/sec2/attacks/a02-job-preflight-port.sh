#!/bin/bash
# A02 (threat 1): alpha's job (no SocketBind limits) listens on bravo's pre-flight port 4201: every deploy
# of bravo is refused ("pre-flight port 4201 is in use by another process") for as long as it likes.
. "$(dirname "$0")/lib.sh"
jobrun 'exec node -e "require(\"http\").createServer((q,r)=>r.end(\"ok\")).listen(4201,\"127.0.0.1\"); setTimeout(()=>process.exit(0),60000)"' ||
  inconclusive "job did not start"
sleep 1
echo 2 > "$W/w/bravo/VERSION"
out=$(cd "$W/w/bravo" && "$R" deploy 2>&1 | grep -iE 'pre-?flight|live in|failed' | tail -3); echo "$out"
echo 1 > "$W/w/bravo/VERSION"
case $out in *"in use by another process"*) succeeded "bravo's deploy refused while alpha holds its pre-flight port";;
  *) blocked "bravo deployed";; esac
