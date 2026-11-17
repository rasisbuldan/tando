# Set up a fresh server

From a new Ubuntu VPS to a live app. Your laptop must be ready first: [SETUP-LAPTOP.md](SETUP-LAPTOP.md).
The server already runs other things? Read [SETUP-EXISTING-VM.md](SETUP-EXISTING-VM.md) instead.

## What the provider must give you

| Need | Detail |
|---|---|
| Ubuntu 24.04 or newer | `host setup` only checks that `apt-get` exists (Debian and Ubuntu). It was tested end to end on Ubuntu 26.04 only. x86_64 or aarch64. |
| sshd and a login with your key | A user such as `admin` (or `root`). Key login: tando never sends a password. |
| **Passwordless sudo** for that user | Required. tando runs everything as `sudo -n`. Its own hint for the rule: `echo 'admin ALL=(ALL) NOPASSWD:ALL' \| sudo tee /etc/sudoers.d/tando`, then `sudo chmod 440 /etc/sudoers.d/tando`. A narrower rule is not documented. |
| Internet access from the server | apt, `nodejs.org` (Node, installed when an app needs it), Let's Encrypt, and `sslip.io` for the free links. |
| Size | tando is developed on 1 vCPU and 2 GB RAM. Under 2 GB (and not in a container) `host setup` adds a 2 GB swap file. |

## DNS and firewall, before you start

Open TCP **22** (or your ssh port), **80** and **443** in the provider's firewall. Ports 80 and 443 must
be reachable from the internet or certificates fail. Apps listen only on `127.0.0.1`, in ports
4100-4199 (4200-4299 for the pre-flight copy of a release), so nothing else is opened.
If `ufw` is active, `host setup` opens 80 and 443 in it (`ufw=no` skips this). It never turns `ufw` on.

Pick how apps get a name:

| Choice | DNS record | `host setup` | App link |
|---|---|---|---|
| Nothing (default) | none | no `apps_domain` | `https://<app>.203-0-113-10.sslip.io` |
| Your own apps domain | `*.apps.example.com` A record to `203.0.113.10` | `apps_domain=apps.example.com tls=auto` | `https://<app>.apps.example.com` |
| One domain per app, later | `example.com` and `www.example.com` A records | `tando domain add example.com` | `https://example.com` |

The sslip.io default needs a public IPv4 address (a private or loopback address gives
`apps_domain=localhost` and plain http). With your own `apps_domain` and no `tls=`, links are plain
**http**: add `tls=auto`. Remove any AAAA record that does not point at the server.

## Steps

1. `ssh -i ~/.ssh/id_ed25519 admin@203.0.113.10 sudo -n true`

   Prints nothing and returns at once. A password prompt or `sudo: a password is required` means the
   sudo rule above is missing.

2. `tando host add vps admin@203.0.113.10 --key ~/.ssh/id_ed25519`

   Shows the server's host keys; compare with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the
   server (provider console), type `y`. You should see `added host vps (admin@203.0.113.10, port 22)`.

3. `tando host setup vps`

   Add `apps_domain=apps.example.com tls=auto` for your own domain. About 1 to 2 minutes. You should see
   nine steps with a check mark: `agent`, `packages`, `caddy`, `config`, `firewall`, `system`, `apps`,
   `checks`, `care`; then `links`, `dns`, `runtimes`, and `next: cd your-app && tando up`. Run it again
   any time: it changes only what differs.

4. `tando doctor vps`

   A table of checks, ending `0 failed, N warnings`. A `dns` warning means `*.apps.example.com` does not
   resolve yet. A `swap` or `disk` row tells you about memory and space.

5. `cd my-app && tando up`

   With no `tando.conf` it detects the app and writes one (`tando init`). For Next.js it offers
   `output: "standalone"` (`--yes` accepts). The first Node app installs Node 24 on the server
   (`installing node 24 on vps ...`, up to a minute). You should see `live in ...s` and the link. Your app
   must listen on `process.env.PORT`; keep files that change in `$TANDO_DATA_DIR` (`data = data` in
   `tando.conf`). `tando go admin@203.0.113.10` does steps 2 to 5 as a wizard.

6. `tando domain add example.com`  (optional)

   Checks DNS first and prints the records to create if they are wrong (`--wait` polls). Then it waits up
   to 90 s for the certificate: `example.com is live`. `www.example.com` redirects to it by default.

7. `tando alerts notifier add phone ntfy`

   Checks run every minute since `host setup`, but go nowhere until you add a notifier. It asks for the
   ntfy topic URL (`https://ntfy.sh/<hard-to-guess-topic>`) and an optional token, not shown. Others: `slack`, `telegram`,
   `webhook`, `email`. Then `tando alerts test` sends a test notice. See [MONITORING.md](MONITORING.md).

8. Backups. Apps with `data = <dir>` or `database = postgres|sqlite` in `tando.conf` are backed up daily
   on the server (7 daily, 4 weekly kept). `tando backup now` makes one; `tando backup ls` lists them.
   Those go with the server if it dies. For copies elsewhere: `tando backup offsite set` (Cloudflare R2
   or any S3 store, encrypted before upload; it shows a recovery key once). Steps in
   [BACKUP.md](BACKUP.md).

9. `tando host status`

   Host care: updates, reboots, open ports, ssh settings, with a to-do list and the fix for each item.
   On a server where `host setup` itself installed Caddy, security updates are already on (`care=off`
   at setup keeps them off). Reboots stay yours: `tando host care on --reboot --window 02:00-04:00`
   lets tando reboot in a window after a notice, never during a deploy. See [HOSTCARE.md](HOSTCARE.md).

## What `host setup` installs and changes

On the server, as root through sudo. Everything of tando's is named `tando` or `tando-*`.

| Area | What |
|---|---|
| tando files | `/opt/tando/bin/` (`tando-agent`, `tando-logs`, `tando-metrics`, `tando-watch`, `tandod`, `tando-status`, `tando-offsite`, `tando-host`, `tando-gate`, `tando-install-recover`), `/opt/tando/VERSION`, `host.conf` (apps domain, TLS, port range 4100-4199), `/opt/tando/apps/` for apps, `/var/lib/tando`, `/var/log/tando`, `/var/log/tando-apt.log`. |
| apt packages | The missing ones of `rsync curl nftables ca-certificates openssl`, and `caddy`. |
| Caddy | Enabled and started. Drop-in `/etc/systemd/system/caddy.service.d/tando.conf` (restart on failure). In `/etc/caddy/Caddyfile`: the line `import /etc/caddy/tando/*.caddy`, a global block `admin unix//run/caddy/admin.sock` (the admin API leaves TCP 2019, so no app can reach it; `/etc/tmpfiles.d/tando-caddy.conf` makes `/run/caddy`), the stock "Caddy works!" site on `:80` replaced by a `no app here` 404, and on a Caddy tando installed: slow-client timeouts and `GOMEMLIMIT` (a drop-in `tando-memory.conf`). Each app later gets `/etc/caddy/tando/<app>.caddy`. |
| Firewall | `tando-firewall.service` loads the nftables table `inet tando` (`/opt/tando/firewall.nft`): an app's user may reach only its own ports on `127.0.0.1`; per-address limits on ports 80 and 443 (200 connections, 100 new per second) on a Caddy tando owns. ufw: 80/tcp and 443/tcp, only if ufw is active. |
| systemd units | `tando-recover.service` (finishes interrupted deploys at boot), `tando.slice`, `tando-down@.service`, `tando-watch.timer` (every minute) with `tando-watch.service` and `tando-watch-fallback.service`, `tandod.service`, `tando-host.timer` (hourly) and `tando-host-boot.service`. |
| Logs | `/etc/systemd/journald.conf.d/tando.conf` (main journal capped at 200M; journald restarts once). Each app gets its own journal namespace later. |
| Memory | `/swapfile` (2 GB, in `/etc/fstab`) if RAM is under 2000 MB, no swap is active and it is not a container (`swap=yes` or `swap=no` overrides). An 8 MB reserve file `/opt/tando/.reserve`. |
| CI keys | User `tando-keys` and `/etc/ssh/sshd_config.d/50-tando-ci.conf`, which applies only to users named `tando-d-*`; sshd is reloaded. |
| Security updates | On a fresh server only: `/etc/apt/apt.conf.d/52tando-care` and an `apt-daily-upgrade` drop-in (see HOSTCARE.md). |

Not installed yet: Node, Python, Podman, PostgreSQL. `tando up` installs what an app needs (Node comes from
`nodejs.org` into `/usr/local`); `node=yes`, `python=yes`, `podman=yes`, `postgres=yes` on `host setup` do it up front.
Each app (at its first `tando up`) adds a system user `tando-<app>`, its unit `tando-<app>.service`,
and the Caddy file above.

TLS modes (`tls=`): `auto` is Let's Encrypt through Caddy. `internal` is Caddy's own CA (for a server the internet
cannot reach; browsers do not trust it). `off` is plain http. `domain_tls=` sets the same for `tando domain add`
names; it defaults to `auto` (to `internal` when `tls=internal`).

## Check it worked

1. `tando doctor vps`: `0 failed`.
2. `tando ls`: your app is listed.
3. Open the link from `tando up` in a browser: HTTPS, no warning.
4. `tando status`: state, memory, backups and alerts of the app.

## Common errors

| Message | Cause and fix |
|---|---|
| `... cannot use sudo without a password, and tando needs it on vps` | The sudo rule is missing: the `echo ... \| sudo tee /etc/sudoers.d/tando` line in the message. |
| `vps refused the login admin@...` | Your key is not in `~/.ssh/authorized_keys` of that user. Add it, or `--key ~/.ssh/<key> --force`. |
| `cannot reach vps (...): no answer within 5 s` | Server down, wrong address, or the ssh port is closed in a firewall. |
| `... connection refused` | sshd is on another port: `tando host add vps ... --port N --force`. |
| `not trusted (no terminal to ask): run again with --yes to trust them` | Run `host add` in a terminal, or add `--yes` after checking the fingerprint. |
| `the host key of vps CHANGED since you trusted it` | The server was reinstalled (or someone is in the middle). tando prints the `ssh-keygen -R` command, then `host add ... --force`. |
| `could not install ... with apt: sudo tail -20 /var/log/tando-apt.log` | apt failed (lock, network, full disk). Read that log on the server, fix, run `host setup` again. |
| `Caddy is installed but does not start` | Something else holds port 80 or 443. `sudo journalctl -u caddy -n 20`. |
| `this server has no apt: tando sets up Debian and Ubuntu servers` | Wrong OS. |
| `tando runs on x86_64 and aarch64 servers, not ...` | Other CPU: not supported. |
| `another tando host setup has been installing for 5 minutes` | Two setups at once. Wait, run again. |
| `Next.js needs output: "standalone" ...` | Add it to `next.config`, or `tando up --yes`. |
| `no tando.conf here: cd into your app's directory` | Run `tando up` in the project, not above it. |
| Links start with `http://` | `apps_domain=` was given without `tls=auto`: `tando host setup vps apps_domain=... tls=auto`. |
| `example.com ... does not answer with a valid certificate yet` | DNS not pointing at the server yet, or 80/443 closed at the provider. Caddy keeps retrying; `tando domain ls` shows the certificate. |
| `host vps runs agent X, this client is Y: tando host setup vps updates it` | Laptop updated: run `tando host setup vps`. |
