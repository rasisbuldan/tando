# Set up on a server that already runs things

tando is built for an empty server. On one with other sites, services and settings it still works,
but it shares Caddy, the firewall, journald and apt with what is there. Read the first two sections
before `tando host setup`. Laptop first: [SETUP-LAPTOP.md](SETUP-LAPTOP.md). Fresh server:
[SETUP-EMPTY-VM.md](SETUP-EMPTY-VM.md), which also lists everything setup installs.

## What tando touches and what it never touches

**Its own namespace** (created by tando, named `tando` or `tando-*`):

| Where | What |
|---|---|
| `/opt/tando`, `/var/lib/tando`, `/var/log/tando`, `/var/cache/tando-logs`, `/var/log/tando-apt.log`, `/var/backups/tando` | Programs, host and app settings, state, logs, backups. One app is `/opt/tando/apps/<app>`. |
| Users `tando-<app>`, `tando-keys`, `tando-d-<app>` (CI) and their groups | System users, no login shell. CI also adds `/etc/sudoers.d/tando-d-<app>`. |
| Units `tando-<app>.service`, `tando-<app>.slice`, `tando-<app>-backup.*`, `tando-<app>_job-*`, `tando-recover`, `tando-firewall`, `tando.slice`, `tando-down@`, `tando-watch*`, `tandod`, `tando-host*` | systemd. Also `/etc/systemd/journald@tando-<app>.conf`. |
| `/etc/caddy/tando/<app>.caddy` | One Caddy site per app. |
| nftables table `inet tando` | Loopback rules and, on a Caddy tando owns, per-address limits. |

**Files that were there before, and that `host setup` edits** (back them up first, see below):

| File | Edit |
|---|---|
| `/etc/caddy/Caddyfile` | Appends `import /etc/caddy/tando/*.caddy` if the line is missing. Puts `admin unix//run/caddy/admin.sock` in the global block (adds a block at the top if there is none; replaces your own `admin ...` line). Replaces a stock `:80` "Caddy works!" site by a 404 answer; any other `:80` site is kept (`kept (yours)`). Your site blocks are never edited. |
| `caddy.service` | New drop-in `caddy.service.d/tando.conf` (restart on failure). Enables and starts Caddy if it is not running. |
| `/etc/systemd/journald.conf.d/tando.conf` | Main journal capped at 200M (`journal_max=` changes it); journald restarts once. |
| `/etc/ssh/sshd_config.d/50-tando-ci.conf` | Applies only to users `tando-d-*`; checked with `sshd -t`, then sshd reloads. |
| ufw | `80/tcp` and `443/tcp` allowed, only if ufw is active and they are not (`ufw=no` skips it). |
| apt | Installs the missing of `rsync curl nftables ca-certificates openssl`, and `caddy` if there is no `caddy` command. Runs `apt-get update`. |
| `/swapfile`, `/etc/fstab` | Only if RAM is under 2000 MB, no swap is active and it is not a container. |

**Only when it is Caddy that tando installed** (a Caddyfile with only `:80` also counts): slow-client
timeouts and a `GOMEMLIMIT` drop-in for Caddy, per-address limits on 80/443, and security updates turned on.
Beside other sites it changes none of these. `tando doctor` and `tando host status` print the lines to add by
hand (`rate_limit=on` on `host setup` turns the limits on anyway).

**It never touches:** your site blocks and certificates, your units, users and cron jobs, nginx or Apache
config, other nftables tables, your Node (kept, even when the app asks for another major), your Docker
(tando's containers use Podman, installed only for the `container` recipe), Ubuntu's
`20auto-upgrades` and `50unattended-upgrades`, other apt files, `/etc/sudoers`.

**It refuses what it did not create:** a new app whose user `tando-<app>` already exists stops with
`user tando-<app> exists but was not created by tando`; `tando destroy` removes only the user, units and
files of that app; `tando adopt` refuses a name tando already has. Exception: a file or unit that already has
tando's own names (`/etc/caddy/tando/<app>.caddy`, `tando-<app>.service`) is overwritten. Do not create those by hand.

## Before you start

Run on the server. Nothing here changes anything.

1. `sudo ss -ltnp 'sport = :80 or sport = :443'`: anything listed is in the way (see the first conflict below).
2. `sudo ss -ltnp | awk '$4 ~ /:4[12][0-9][0-9]$/'`: services in tando's ports, 4100-4299. Nothing is best.
3. `systemctl is-active caddy nginx apache2 docker postgresql`: what runs. Then `caddy version; ls /etc/caddy`.
4. `sudo caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`: tando needs a valid file
   at exactly `/etc/caddy/Caddyfile`, run by a unit named `caddy` (the apt layout).
5. `sudo ufw status verbose; sudo nft list ruleset | head -40`: your firewall.
6. `free -m; swapon --show; df -h / /opt /var; df -i /opt`: memory and space (see Low memory and disk).
7. `ls /etc/apt/apt.conf.d /etc/ssh/sshd_config.d /etc/systemd/journald.conf.d`: settings tando may overlap.
8. `getent passwd | grep '^tando'`: prints nothing on a server tando has not touched.
9. `sudo tar -czf ~/pre-tando.tar.gz /etc/caddy /etc/ssh/sshd_config.d /etc/systemd/journald.conf.d /etc/apt/apt.conf.d`:
   a copy of what setup edits.
10. `sudo -n true`: must print nothing. tando needs passwordless sudo.

Then register and set up as on a fresh server: `tando host add vps admin@203.0.113.10 --key ~/.ssh/id_ed25519`,
`tando host setup vps`, `tando doctor vps`. `host setup` is safe to repeat after you fix a conflict.
tando uses only `sudo -n`; sudo-rs (Ubuntu 26.04) works, and an old Caddy (2.6.x) works.

## Common conflicts

| Symptom | Cause | What to do |
|---|---|---|
| `host setup` stops at `caddy`: `Caddy is installed but does not start` | nginx, Apache or another program holds port 80 or 443. tando needs Caddy on both, and has no setting to move it (`public_port` only changes the links it prints). | Free the ports (move that server behind Caddy, or stop it), then run `host setup` again. Your sites on that server go down while it is stopped: plan it. |
| Caddy is already installed and has your sites | Setup still appends the import line and moves the admin API to the socket (table above). The `caddy` step shows `timeouts not set (other sites: ...)`. | Validate the file first, keep the backup. Scripts that call Caddy's admin API on `localhost:2019` must use `/run/caddy/admin.sock`. Check `systemctl status caddy` after. Add the timeout and `GOMEMLIMIT` lines `tando doctor` prints, if you want them. |
| Setup dies: `caddy rejected the admin socket setting` or `the Caddyfile does not validate` | Your Caddyfile is invalid, or uses a layout tando does not handle (JSON config, Caddy in Docker or under another unit name). | Fix it with `caddy validate`, run `host setup` again. The import line may already be appended: harmless. |
| `tando up` or `domain add` fails: `caddy rejected the site config for <app>: ...` | Caddy refuses a second site for an address your Caddyfile already defines. tando rolls the app's file back. | Take that domain out of your own block first (`sudo caddy validate`, `sudo systemctl reload caddy`), then `tando domain add example.com -a shop`. |
| `no free port in 4100-4199` | The range is used up. Ports busy at creation (`ss` shows them) are skipped for the app and its pre-flight port (+100). | Edit `port_min` and `port_max` in `/opt/tando/host.conf`, then `tando host setup vps`. Existing apps keep their ports. |
| An app cannot reach your service: connection reset | nftables rules refuse an app user's loopback connections to ports 4100-4299, to 2019 and to `5432` (except its own `database = postgres`). | Move your service to another port, or use a remote one. Other loopback ports, such as redis, are open to apps. |
| App fails at start: port in use | A service of yours started later on a port tando gave an app. | Move your service out of 4100-4299 and restart the app: `tando restart shop`. |
| A systemd service you want tando to run | tando makes its own unit (`tando-<app>`) and does not take over a hand-written one by itself. | New app: `tando up` under a new name. Existing Next.js app: `tando adopt` (below). |
| `tando doctor`: `ufw ... ports 80/443 are closed` | ufw is active and setup ran with `ufw=no`, or rules changed later. | `sudo ufw allow 80/tcp` and `443/tcp`, or `tando host setup vps`. |
| `doctor`: `loopback rules: not loaded` | Something flushed nftables (`nft flush ruleset`, or a reload of your own firewall script). tando's table is gone. | `tando host setup vps` loads it again. `nftables.service` reloads are handled: tando's unit follows them. |
| Security updates behave differently after `tando host care on --updates` | tando writes `/etc/apt/apt.conf.d/52tando-care`. It sorts after Ubuntu's `20auto-upgrades` and `50unattended-upgrades`, so it wins over them: security origins only, no reboot, unused kernels removed. | Keep a setting of yours by naming its file `99-...` (apt reads later files last). `tando host care off` removes tando's two files. If Caddy was already there, nothing is on until you run `care on`. If tando installed Caddy, updates are on from setup. |
| `needrestart` restarts your services after upgrades | Ubuntu's default. tando sets `NEEDRESTART_SUSPEND=1` for its own apt runs and for care's upgrades; the old code keeps running until a restart. | `tando host status` lists what runs old code. Restart those units yourself. |
| `tando host care on --reboot` or `tando host reboot` is refused: `Caddy on vps also serves sites tando does not manage` | An automatic reboot takes your other sites down too. | Leave reboots manual, or accept it: `--even-with-other-sites` (asks you to confirm). |
| Docker: ports or memory clash | tando skips ports `ss` shows busy, but not ones Docker publishes later. Container memory is not in tando's caps. | Publish container ports outside 4100-4299. `doctor` row `memory caps` warns when app caps exceed RAM. |
| Low memory or disk (see below) | Each app has `memory` (default 256M); its slice allows 3x for the live app, the pre-flight copy and a job. | Lower `memory =` in `tando.conf`, or use a bigger server. |
| Your PostgreSQL changed | An app with `database = postgres` (or `postgres=yes` on `host setup`) makes tando write `/etc/postgresql/<version>/main/conf.d/tando.conf` (the cluster `main` on port 5432; the version is recorded and kept) (`max_connections = 20`, `shared_buffers = 32MB`, `listen_addresses = 'localhost'`), restart PostgreSQL when those settings changed, add `/etc/systemd/system/postgresql@.service.d/tando.conf` (`OOMScoreAdjust=-900`), and revoke `CONNECT` on `postgres` and `template1` from PUBLIC. | Do not use `database = postgres` beside a database you care about: use `sqlite`, or a database on another host. |
| Your cron jobs and backup scripts | tando never touches them. Its own backups cover only tando apps with `data =` or a database, in `/var/backups/tando`. | Keep both. Do not point two jobs at one directory. |
| Two alerts for one outage | Your uptime monitor and `tando-watch` both fire. tando sends only to notifiers you add. `exposed` fires on every public listener it does not know (your database, say). | `tando alerts silence all 2h`; `tando alerts set exposed=off` or `allow_ports=tcp/5432`; or add no notifier. |
| Main journal smaller than before | tando caps it at 200M. | `tando host setup vps journal_max=1G`. |

### Low memory and disk

- With under 2000 MB RAM tando adds a 2 GB swap file (`swap=no` skips it). Apps have no swap (`MemorySwapMax=0`).
- `doctor` warns at 90% disk used, fails at 97%. Apps share the disk and have no quota. tando keeps 5 releases per app (plus the current and last good one),
  each with its `node_modules`. A full disk stops deploys; tando keeps an 8 MB reserve so it can still write its state.
- An upload that runs out of space says `vps ran out of disk space during the upload`.

### Taking over a running Next.js app: `tando adopt`

For a hand-deployed **Next.js standalone** app that runs as a systemd unit. Details and a full runbook:
[MIGRATION.md](MIGRATION.md). Setup must have run first.

1. `tando adopt plan shop -H vps --health /health`

   Read-only. Shows what changes, what stays, downtime (one restart) and anything `blocked`. Blocked when: the unit is not
   running, has drop-ins, runs as root, its user can log in (a shell and ssh keys), has a crontab or a privileged group, or shares
   that user with other processes; the unit file is not root-owned (an env file that is not only raises a risk); the app is not a `releases/<id>` plus
   `current` symlink layout; no Caddy site proxies to its port.
2. `tando adopt apply shop -H vps --health /health`

   Backs up data, the unit, env file, `/etc/caddy`, timers and your backup script, then switches. Any failed check returns
   the server to the recorded state. You type the app name to confirm. Run it in the app's source directory: it writes `tando.conf` there.

**Changes:** the unit becomes `tando-shop.service` (yours is stopped and disabled, the file kept); releases move to
`/opt/tando/apps/shop`; env values are copied to tando's env file; timers that call the app become tando jobs; `incoming/`
becomes a file so the old deploy script stops at its first step. **Left alone:** port, user, data directory, the env
file, your Caddy site block (byte for byte), your backup script and cron.

3. Undo: `tando adopt undo shop -H vps`. It refuses while a newer tando release is live: `tando rollback` first.

## Running both side by side

1. Keep your old deploy script for the old apps. tando does not look at them.
2. Deploy one new or moved app with `tando up`. It answers on `https://<app>.203-0-113-10.sslip.io` (or your
   `apps_domain`) without touching your domains. Test it there.
3. Move the domain last: take it out of your Caddyfile, `sudo caddy validate`, `sudo systemctl reload caddy`, then
   `tando domain add example.com -a shop`. It checks DNS and waits for the certificate.
4. Then the next app. Keep your own backup running until `tando backup ls -a shop` shows tando's.
5. Do not run your old deploy script on an app that tando manages.

## Removing tando again

There is no server-wide uninstall command. What exists:

- `tando destroy shop` removes an app: unit, Caddy site, user, releases, data, database. It keeps a final backup unless
  `--purge`. An adopted app: `tando adopt undo shop`.
- `tando alerts disable` stops the checks (settings kept). `tando host care off` removes care's two apt files.
  `tando backup offsite off` stops offsite copies.
- `tando host rm vps` only forgets the server on your laptop. Nothing on the server changes.

After the last app is destroyed, setup's leftovers stay on the server until you remove them by hand: `/opt/tando`,
`/var/lib/tando`, `/var/log/tando`, `/var/backups/tando`, the units above, the nftables table `inet tando`,
`/etc/systemd/journald.conf.d/tando.conf`, the Caddy drop-ins in `caddy.service.d`, `/etc/tmpfiles.d/tando-caddy.conf`,
the sshd drop-in, users `tando-keys` and `tando-*`, `/swapfile`, and in your Caddyfile the `import` line and the `admin` line
(put your own back). Packages stay installed. This list comes from what setup writes; removing it is not tested.
