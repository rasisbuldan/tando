#!/bin/bash
# Approach C server setup (run as root on the server): a piku/Dokku-style "build on the server"
# host. Source is pushed to /srv/app/src (owned by the login user), built there with npm ci +
# next build, staged into /srv/app/releases/<n>, run by systemd unit bench.service as user `app`
# behind Caddy (bench.localhost -> 127.0.0.1:3000). Activation is a symlink switch + restart.
set -eu
id app >/dev/null 2>&1 || useradd --system --user-group --no-create-home --shell /usr/sbin/nologin app
install -d -o vmadmin -g vmadmin /srv/app /srv/app/src /srv/app/releases /srv/app/.npm
cat > /etc/systemd/system/bench.service <<'U'
[Unit]
Description=bench app (approach C)
After=network.target
[Service]
User=app
Group=app
WorkingDirectory=/srv/app/current
Environment=PORT=3000 NODE_ENV=production NEXT_TELEMETRY_DISABLED=1
ExecStart=/usr/local/bin/node server.js
Restart=on-failure
MemoryMax=512M
[Install]
WantedBy=multi-user.target
U
printf 'http://bench.localhost {\n\treverse_proxy 127.0.0.1:3000\n}\n' > /etc/caddy/tando/bench.caddy
systemctl daemon-reload && systemctl enable -q bench.service && systemctl reload caddy
