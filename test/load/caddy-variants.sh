#!/bin/bash
# What does tando's site config cost? Adds two temporary Caddy sites on the server (removed at the
# end): :8091 plain reverse_proxy, :8092 the same plus tando's JSON request log; then wrk keep-alive
# 50 conns against :8091, :8092, the tando site (:80, Host <app>.localhost) and the app's port.
# usage: test/load/caddy-variants.sh <app> <port> <out.tsv> [reps]
set -u
. "$(dirname "$0")/lib.sh"
APP=$1 PORT=$2 OUT=$3 REPS=${4:-3} C=${CONNS:-50}
sx "cat > /etc/caddy/loadtest-variants.caddy <<EOC
:8091 {
	reverse_proxy 127.0.0.1:$PORT
}
:8092 {
	log {
		output file /var/log/loadtest-variant.log {
			roll_size 4MiB
			roll_keep 3
		}
		format filter {
			wrap json
			fields {
				request>headers delete
			}
		}
	}
	reverse_proxy 127.0.0.1:$PORT
}
EOC
grep -q loadtest-variants /etc/caddy/Caddyfile || echo 'import /etc/caddy/loadtest-variants.caddy' >> /etc/caddy/Caddyfile
systemctl reload caddy"
docker cp "$LROOT/test/load/wrk-report.lua" "$GEN:/root/r.lua"
for rep in $(seq 1 "$REPS"); do
  for v in bare:8091: log:8092: tando:80:$APP.localhost direct:$PORT:; do
    name=${v%%:*} rest=${v#*:} p=${rest%%:*} h=${rest#*:}
    c0=$(cg_cpu system.slice/caddy.service)
    res=$(gx "ulimit -n 100000; cd /root; WRK_HOST=$h wrk -t2 -c$C -d15s --timeout 10s -s r.lua http://127.0.0.1:$p/ | grep RESULT")
    c1=$(cg_cpu system.slice/caddy.service)
    printf '%s\t%s\t%s\t%s\tcaddy_cpu_s=%s\t%s\n' "$(date +%T)" "$(load1)" "$rep" "$name" "$(( (c1 - c0) / 1000000 ))" "$res" | tee -a "$OUT"
    sleep 5
  done
done
sx "sed -i '/loadtest-variants/d' /etc/caddy/Caddyfile; rm -f /etc/caddy/loadtest-variants.caddy /var/log/loadtest-variant.log*; systemctl reload caddy"
