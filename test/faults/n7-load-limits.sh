#!/bin/bash
# n7: limits under load. An app gets more requests at once than its limits allow (max_conns 2,
# max_requests 4, hold 5 s, each request takes 2 s); a neighbour app is used at the same time; one client
# opens more connections than conn_limit. Expect: the excess gets 503 "busy" from Caddy (not a
# hang), the neighbour answers normally, tando-watch does not restart the busy app (it is
# saturated, not hung), the app's slice carries its cpu/memory/tasks limits, and the client over
# conn_limit is refused while ssh keeps working.
. "$(dirname "$0")/lib-fault.sh"
f_init n7 "flood one app; one client over conn_limit" "load limits"
A=fn7 B=fn7b
gone() { srv "sudo test -d /opt/tando/apps/$1" 2> /dev/null && echo "$1" | (cd "$W" && "$R" destroy -a "$1" --purge > /dev/null 2>&1); true; }
gone $A; gone $B
f_app $A; f_app $B
# the busy app: every request takes 2 s
cat > "$W/$A/server.js" <<'JS'
const http = require('http'), v = require('fs').readFileSync(__dirname + '/VERSION', 'utf8').trim();
http.createServer((q, s) => q.url === '/health' ? s.end('ok\n') : setTimeout(() => s.end('v' + v + '\n'), 2000))
  .listen(Number(process.env.PORT), '127.0.0.1');
JS
deploy $A 1 ok up; ok "the busy app is up (rc=$DRC)" test "$DRC" = 0
deploy $B 1 ok up; ok "the neighbour is up (rc=$DRC)" test "$DRC" = 0
# limits set in app.conf (as tando.conf's max_conns/max_requests/cpu/tasks would), applied by a restart
srv "sudo bash -c 'printf \"max_conns=2\nmax_requests=4\nhold=5\ncpu=20%%\ntasks=200\n\" >> /opt/tando/apps/$A/app.conf'"
"$R" host setup test public_port="$HP" > /dev/null 2>&1      # (re-renders every app's units and slice)
srv "sudo /opt/tando/bin/tando-agent restart $A" > /dev/null 2>&1
ok "Caddy caps the busy app (max_conns_per_host 2, unhealthy_request_count 4)" \
  srv "sudo grep -q 'max_conns_per_host 2' /etc/caddy/tando/$A.caddy && sudo grep -q 'unhealthy_request_count 4' /etc/caddy/tando/$A.caddy"
sl=/sys/fs/cgroup/tando.slice/tando-$A.slice
ok "its slice holds the app's units with cpu 20%, tasks 200, memory 3x 128M" \
  srv "grep -q '^20000 100000' $sl/cpu.max && grep -qx 200 $sl/pids.max && grep -qx 402653184 $sl/memory.max && test -d $sl/tando-$A.service"
pid=$(srv "systemctl show -P MainPID tando-$A")
# 40 requests at once: 4 in flight, about one served a second, the rest shed with 503 busy after the hold
curl -s -i --parallel --parallel-immediate --parallel-max 40 -m 40 -o "$W/fb_#1" -w '%{http_code} %{time_total}\n' \
  "$(url $A)?n=[1-40]" > "$W/flood" &
fl=$!
sleep 1
nb=$(for i in 1 2 3 4 5; do curl -s -o /dev/null -m 5 -w '%{http_code}:%{time_total} ' "$(url $B)"; done)
log "neighbour during the flood: $nb"
srv "sudo /opt/tando/bin/tando-watch run" > /dev/null 2>&1
wait $fl
log "flood: $(awk '{print $1}' "$W/flood" | sort | uniq -c | tr -s ' \n' ' ')"
ok "the neighbour answers during the flood, each within 1 s" sh -c "! printf '%s' '$nb' | tr ' ' '\n' | grep -v '^200:0\.' | grep -q ."
ok "some requests to the busy app are served" grep -q '^200 ' "$W/flood"
ok "the excess gets 503, none waits much past the hold of 5 s (max 12 s)" sh -c "grep -q '^503 ' '$W/flood' && awk '\$2 > 12 { exit 1 }' '$W/flood'"
b=$(grep -l '^HTTP/1.1 503' "$W"/fb_* 2> /dev/null | head -1)
ok "a shed request's 503 says busy and has Retry-After" sh -c "[ -n '$b' ] && tr -d '\r' < '$b' | grep -qi '^retry-after: 5' && grep -q 'is busy' '$b'"
ok "tando-watch did not restart the busy app" test "$(srv "systemctl show -P MainPID tando-$A")" = "$pid"
# B: one client over conn_limit (this laptop, through the published port) is refused; ssh is not limited
# (the agent's setup verb: what `tando host setup test rate_limit=on conn_limit=5` sends)
srv "sudo /opt/tando/bin/tando-agent setup public_port=$HP rate_limit=on conn_limit=5" > "$W/setup-rl.out" 2>&1
ok "host setup rate_limit=on conn_limit=5" grep -q '^ok=1' "$W/setup-rl.out"
for i in 1 2 3 4 5 6 7 8 9; do ( exec 3<>/dev/tcp/127.0.0.1/$HP && sleep 1 && printf 'GET /health HTTP/1.1\r\nHost: %s.localhost\r\n\r\n' $B >&3 && read -r -t 3 l <&3 && echo "$l"; sleep 2 ) > "$W/c$i" 2>&1 & done
sleep 0.5; ok "ssh still works while this client is at its limit" srv true
wait
n=$(cat "$W"/c? | grep -c 'HTTP/1.1 200')
ok "5 connections of this client are served, the others refused ($n served)" test "$n" = 5
"$R" doctor > "$W/doctor.out" 2>&1
ok "doctor shows the refused connections" grep -q 'client limits.*refused [1-9]' "$W/doctor.out"
srv "sudo /opt/tando/bin/tando-agent setup public_port=$HP rate_limit=auto conn_limit=200" > /dev/null 2>&1
gone $A; gone $B
f_end
