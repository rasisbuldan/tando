#!/bin/bash
# End-to-end test of Caddy's limits per app (docs/COMMANDS.md, "Limits and load"): a slow app ties
# up only itself (another app answers at once while it holds every connection it may have), an
# answer slower than response_timeout is a 504 while an event stream runs on past it, a body over
# body_max is a 413 (also on Caddy 2.6, which says 502), and a websocket of one app survives a
# deploy of another app (and, on Caddy 2.7 and later, a reload for another app's site change).
#
#   test/e2e-proxy.sh [--reset]     --reset: recreate the server first (only one this suite owns)
#
# Server: TANDO_TEST_NAME / TANDO_TEST_SSH_PORT / TANDO_TEST_HTTP_PORT. About 3 minutes.
# Output: PASS/FAIL lines (docs/TESTING.md), summary, exit status.
set -u
# lint: allow RL03 the suite's own test/lib.sh, as docs/TESTING.md shows
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init proxy
W=$E/w

if [ "${1:-}" = --reset ]; then t_server_up --reset || exit 1; else t_server_up || exit 1; fi
t_host_add test
"$R" host setup test public_port="$T_HTTP_PORT" >&2 || exit 1

# pa: slow answers, an event stream, uploads and a websocket echo (a raw 101, no library);
# pb: hello with the default limits
mkdir -p "$W/pa"; cp -R "$ROOT/examples/hello" "$W/pb"
printf 'app = pb\n' >> "$W/pb/tando.conf"
cat > "$W/pa/server.js" <<'EOF'
const http = require('http');
const s = http.createServer((q, r) => {
  const m = q.url.match(/^\/slow\/(\d+)/);
  if (m) { setTimeout(() => r.end('slow done\n'), m[1] * 1000); return; }
  if (q.url === '/sse') {
    r.writeHead(200, { 'content-type': 'text/event-stream' });
    let i = 0; const t = setInterval(() => r.write('data: ' + i++ + '\n\n'), 500);
    q.on('close', () => clearInterval(t)); return;
  }
  if (q.method === 'POST') { let n = 0; q.on('data', (d) => { n += d.length; }); q.on('end', () => r.end('got ' + n + '\n')); return; }
  r.end('pa ok\n');
});
s.on('upgrade', (q, sock) => {
  sock.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n');
  sock.on('data', (d) => sock.write(d)); sock.on('error', () => {});
});
s.listen(Number(process.env.PORT), '127.0.0.1');
EOF
printf 'app = pa\nrecipe = node\nstart = node server.js\nhealth = /\nmemory = 128M\nmax_conns = 4\nresponse_timeout = 4\nbody_max = 1MB\nhold = 2\n' > "$W/pa/tando.conf"
(cd "$W/pa" && "$R" up --yes > "$E/up-pa.log" 2>&1); rc_a=$?
(cd "$W/pb" && "$R" up --yes > "$E/up-pb.log" 2>&1); rc_b=$?
check "P1 both apps deploy" eval "[ $rc_a = 0 ] && [ $rc_b = 0 ]"
site() { "$SSH" "sudo cat /etc/caddy/tando/$1.caddy"; }
check "P2 the site sets the dial timeout, the app's response timeout and body cap (pb: the defaults 60 s, 100MB)" eval '
  site pa | grep -q "dial_timeout 3s" && site pa | grep -q "response_header_timeout 4s" && site pa | grep -q "max_size 1MB" &&
  site pb | grep -q "response_header_timeout 60s" && site pb | grep -q "max_size 100MB"'
cv=$("$SSH" 'caddy version' 2> /dev/null | grep -o '[0-9][0-9]*\.[0-9][0-9]*' | head -1)
new=0; case $cv in 2.[0-6]|1.*|'') ;; *) new=1;; esac
if [ $new = 1 ]; then
  check "P3 Caddy $cv: streams survive a reload for 30 minutes (stream_close_delay)" eval 'site pa | grep -q "stream_close_delay 30m"'
else
  check "P3 Caddy $cv has no stream_close_delay: none is written (the site would not load)" eval '! site pa | grep -q stream_close_delay'
fi

# ---- a slow app ties up only itself --------------------------------------------------------------
# 12 requests that take 3 s each hold all 4 of pa's connections (max_conns) and queue the rest;
# meanwhile pb answers at once
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  curl -s -o /dev/null -w '%{http_code} %{time_total}\n' --max-time 30 "$(t_url pa /slow/3)" >> "$E/slow.out" &
done
pa_port=$("$SSH" 'sudo sed -n "s/^port=//p" /opt/tando/apps/pa/app.conf')
# (Caddy's connections to pa: all 4 in use)
pa_full() { [ "$("$SSH" "ss -Htn state established 'dport = :$pa_port'" | grep -c .)" -ge 4 ]; }
check "P4a the slow requests hold all of pa's connections (max_conns 4)" t_until 10 pa_full
worst=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  r=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 10 "$(t_url pb)")
  echo "pb while pa is slow: $r" >> "$E/numbers"
  [ "${r%% *}" = 200 ] || worst=99
  awk -v t="${r#* }" 'BEGIN { exit !(t > 0.5) }' && worst=99
done
check "P4 while a slow app holds all its connections, another app answers in under 0.5 s (10 of 10)" t_eq "$worst" 0
wait
check "P5 and the slow app's queued requests are answered as its connections free up (12 of 12 200)" eval '[ "$(grep -c "^200 " "$E/slow.out")" = 12 ]'

# ---- response_timeout, and a stream runs past it -------------------------------------------------
r=$(curl -s -o "$E/504.body" -w '%{http_code} %{time_total}' --max-time 30 "$(t_url pa /slow/10)")
echo "pa /slow/10 with response_timeout 4: $r" >> "$E/numbers"
check "P6 an answer slower than response_timeout (4 s) is a 504 after it, saying so" eval '
  [ "${r%% *}" = 504 ] && awk -v t="${r#* }" "BEGIN { exit !(t >= 3.5 && t < 8) }" && grep -q "pa took too long to answer" "$E/504.body"'
ev=$(curl -s -N --max-time 8 "$(t_url pa /sse)" | grep -c '^data:')
check "P7 an event stream runs on past response_timeout (8 s of it: over 12 events, got $ev)" eval '[ "$ev" -gt 12 ]'

# ---- body_max ------------------------------------------------------------------------------------
post() { head -c "$2" /dev/zero | curl -s -o "$E/post.body" -w '%{http_code}' --max-time 30 --data-binary @- "$(t_url "$1" /up)"; }
check "P8 a body over body_max (1MB) is a 413, saying so" eval '[ "$(post pa 2000000)" = 413 ] && grep -q "too large for pa" "$E/post.body"'
check "P8b also when it comes without a length (chunked)" eval '
  [ "$(head -c 2000000 /dev/zero | curl -s -o /dev/null -w "%{http_code}" --max-time 30 -H "Transfer-Encoding: chunked" --data-binary @- "$(t_url pa /up)")" = 413 ]'
check "P9 a body under it reaches the app" eval '[ "$(post pa 500000)" = 200 ] && grep -q "got 500000" "$E/post.body"'
check "P10 another app takes the same body (its default cap is 100MB)" eval '[ "$(post pb 2000000)" = 200 ]'

# ---- a websocket of pa and other apps' changes ---------------------------------------------------
# the client runs on the server (its node), on Caddy's port 80: one ping a second, a line per echo
"$SSH" 'cat > ~/wsc.js' <<'EOF'
const http = require('http');
const q = http.request({ host: '127.0.0.1', port: 80, path: '/ws', headers: { Host: 'pa.localhost', Connection: 'Upgrade', Upgrade: 'websocket' } });
q.on('upgrade', (res, sock) => { let n = 0; sock.on('data', () => console.log('alive', ++n)); sock.on('close', () => { console.log('dead'); process.exit(1); }); setInterval(() => sock.write('p'), 1000); });
q.on('response', (r) => { console.log('no upgrade', r.statusCode); process.exit(2); });
q.end();
EOF
ws_start() { "$SSH" "pkill -f '^node .*wsc[.]js'; rm -f ~/ws.out; nohup node ~/wsc.js > ~/ws.out 2>&1 < /dev/null & disown" > /dev/null 2>&1; }
ws_n() { "$SSH" 'tail -1 ~/ws.out' 2> /dev/null | sed -n 's/^alive //p'; }
ws_dead() { "$SSH" 'grep -q "^dead\|^no upgrade" ~/ws.out'; }
# alive: echoes still come (two more than <n>)
ws_more() { local m; m=$(ws_n); [ -n "$m" ] && [ "$m" -ge $(($1 + 2)) ]; }
ws_start
t_until 10 ws_more 0 > /dev/null
echo 2 > "$W/pb/VERSION"
(cd "$W/pb" && "$R" up --yes > "$E/up-pb2.log" 2>&1); rc=$?
wn=$(ws_n)
check "P11 a websocket of one app survives a deploy of another app" eval '[ $rc = 0 ] && [ -n "$wn" ] && t_until 10 ws_more "$wn" && ! ws_dead'
# a site change of pb (its body cap): Caddy reloads its whole config
printf 'body_max = 50MB\n' >> "$W/pb/tando.conf"
# shellcheck disable=SC2034 # read inside the eval'd checks below
wn=$(ws_n)
(cd "$W/pb" && "$R" up --yes > "$E/up-pb3.log" 2>&1); rc=$?
check "P12a the other app's site change is a reload (its file changed)" eval '[ $rc = 0 ] && site pb | grep -q "max_size 50MB"'
if [ $new = 1 ]; then
  check "P12 Caddy $cv: the websocket survives a reload for another app's site change" eval 't_until 10 ws_more "${wn:-0}" && ! ws_dead'
else
  if t_until 10 ws_dead 2> /dev/null; then
    skip "P12 Caddy $cv ends every websocket at a reload (no stream_close_delay before 2.7): as documented"
  else
    check "P12 Caddy $cv: the websocket survives a reload for another app's site change" eval 'ws_more "${wn:-0}"'
  fi
fi
"$SSH" "pkill -f '^node .*wsc[.]js'" > /dev/null 2>&1

cat "$E/numbers" >&2
t_done
