# tando

Deploy web apps from your laptop to your own Linux server with one command. No Docker, no
registry, no control panel, no build on the server. tando is a single bash command on your laptop
and a few small Go programs that it installs on the server over ssh.

    tando go admin@203.0.113.10

That takes an empty Ubuntu server to a live app with a link and monitoring. Add a domain and you have HTTPS.

## Why tando

Measured against Kamal 2 and Dokku with the same Next.js app on the same 1 CPU, 2 GB server.
Medians of 3 to 9 runs. Full method, raw tables and the places where tando loses are in
[bench/RESULTS.md](bench/RESULTS.md).

| | tando | Kamal 2 | Dokku |
|---|---|---|---|
| Empty server to first live app | **121 s** | 175 s | 610 s |
| Commands to get there / files you write by hand | **3 / 0** | 3 / 2 | 9 / 2 |
| Memory used by the whole server with one app | **78 MB** | 190 MB | 148 MB |
| Data sent to the server per deploy | **238 KB** | 11,212 KB | 324 KB |
| Peak memory during a deploy | **118 MB** | 276 MB | 754 MB |
| Rollback | **1.5 s** | 3.2 s | 28.5 s |
| Failed requests per deploy | 0 | 0 | 0 |

On a real 1 CPU, 2 GB server: 8,599 requests at 50 connections while a deploy, a rollback and
another deploy ran. None failed.

On that server, with 3 apps: monitoring (checks, metrics and the log scan every minute) takes 8 MB
of memory and 0.1% of the CPU, and a status call costs 24 ms of server CPU.

What that means in practice:

- **A 5 dollar server is enough.** tando adds almost nothing on top of your app. There is no
  Docker daemon and no proxy container, and monitoring runs in 8 MB on the real server.
- **Deploys are small and fast.** Only changed files travel (rsync), so a deploy sends kilobytes,
  not an image.
- **The server never builds.** The build runs on your laptop or in CI, so a deploy cannot run a
  small server out of memory.

Where tando is not the best choice: Kamal switches traffic with a shorter pause (about 0.1 s
against 0.4 to 1.7 s, during which tando holds requests instead of failing them; docs/COMMANDS.md,
"What the hold covers, exactly", lists what a hold cannot save), and each app
runs on one server. tando does not do clusters or load balancing across servers.

## Features

Deploy and run:

- **Deploys that cannot break the live app.** The new release starts on a spare port and must
  pass its health check, then stay up for a soak period, before it counts. A release that fails is
  rolled back by itself, and the old one keeps answering (requests are held for a moment during the
  switch, not failed). `tando rollback` takes 1.5 to 3 s.
- **Zero config.** `tando up` detects Node, Next.js, static sites, Python and container apps and
  writes the config for you (`tando recipes`, [docs/RECIPES.md](docs/RECIPES.md)). One package of a
  pnpm or npm monorepo deploys from its own directory.
- **Workers and jobs.** Long-running workers beside the web process, and scheduled jobs (cron or
  systemd calendar syntax) whose start times are spread so 100 apps do not fire in the same second.
- **Compression and caching.** Caddy compresses text answers; fingerprinted files get a long cache
  lifetime and stay reachable after the next release.
- **HTTPS and domains.** Caddy and Let's Encrypt, with a free `sslip.io` link until you add your
  own domain.
- **Scale to zero.** `idle_stop = 6h` stops an app's web process when nobody uses it and starts it
  on the next request (0.1 to 0.3 s for a small app). Workers and jobs keep running.

Data:

- **PostgreSQL per app**, sized from the server's RAM, with one pgbouncer in front of all apps.
  SQLite works too. `tando db studio` opens a read-only database browser (one always-on service
  per server).
- **Backups you can restore from.** Daily backups in a scheduled window, one at a time, and
  encrypted offsite copies to Cloudflare R2 or any S3-compatible storage. A new server can be
  rebuilt from the bucket.

Watching:

- **Monitoring built in (`tandod`).** Per-minute checks for app down, failing health, error
  spikes, new error types after a release, memory, disk and certificates. Alerts go to ntfy,
  Slack, Telegram, e-mail or a webhook. A hung app is restarted for you.
- **Metrics like a cloud console.** Host, app and database series per minute (CPU including steal
  and iowait, memory, pressure, disk, network, OOM kills, throttling), live 5 second views
  (`tando status --follow`, `tando ls --follow`, `tando top`), and `tando-status cost` on the
  server shows what the monitoring itself costs.
- **Dashboard add-on.** A web app on your laptop (`tando addon install dashboard`, then
  `tando dashboard`) with apps, deploys, logs, traffic, jobs, alerts, a server page and a database
  tab. It can deploy, roll back, restart and set variables, each with a confirmation. On a Mac the
  menu bar app (`tando menubar install`) opens it in a window of its own and shows a problem badge
  that also watches your servers.
- **Logs, requests and host care.** `tando logs`, `tando errors`, `tando requests`; the server
  itself is watched for security updates, pending reboots, open ports, ssh settings, failed units,
  disk and clock.

Around it:

- **Per-app limits.** Memory, CPU, processes, /tmp, connections, DNS, logs and disk, so one app
  cannot take the others down (see "App limits and isolation").
- **CI deploy keys.** A key that can deploy one app and nothing else, with a ready GitHub Actions
  workflow.
- **Servers.** `tando host rename` renames a server on your laptop. Everything tando creates is
  prefixed `tando-` and lives under `/opt/tando`, and it refuses to touch anything it did not
  create.

## Requirements

- Laptop: macOS or Linux, with bash 3.2+, ssh and rsync.
- Server: Ubuntu 24.04 or newer, with sshd and a login that has passwordless sudo.
- Nothing else has to be installed on the server.

## Install

From a release archive (see the Releases page; the `.sha256` file is checked for you):

    ./install.sh --from tando-0.2.2.tar.gz

From a checkout (needs Go to build the server programs):

    git clone https://github.com/rasisbuldan/tando && cd tando && ./install.sh

Both put `tando` in `~/.local/bin`. Use `--prefix DIR` or `--system` to install elsewhere.
Homebrew, npm and apt packages are planned. They do not exist yet.

## Quickstart

1. Register your server: `tando host add vps admin@203.0.113.10`
2. Set it up, once: `tando host setup vps`
3. Deploy from your app's directory: `cd my-app && tando up`
4. Open the link `tando up` prints.
5. Optional, your own domain with HTTPS: `tando domain add example.com`

Or let a wizard do all of it: `tando go admin@203.0.113.10`.
The full walkthrough is in [docs/QUICKSTART.md](docs/QUICKSTART.md).

After that: `tando deploy`, `tando rollback`, `tando logs -f`, `tando status`,
`tando env set KEY`, `tando alerts`. `tando help` lists every command. If something is wrong,
run `tando doctor`.

## Your app

- Listen on `process.env.PORT`. tando picks the port.
- Keep files that change in `$TANDO_DATA_DIR` (set `data = data` in `tando.conf`). The release is read-only.
- Next.js needs `output: "standalone"`. `tando up` offers to add it.
- `tando.conf` holds the app's settings. `tando init` writes it; every setting is in [docs/CONFIG.md](docs/CONFIG.md) (or `tando help conf`).

## How it scales

One server, many apps. tando is meant for the server you already have, from a 1 CPU, 2 GB box with
a few apps to 100 apps and more on 4 CPUs and 8 GB. There is no cluster: for more room, make the
server bigger or add another one.

- **Per app, its own unit, slice and user.** Each app runs as its own user (ids 30000 to 39999) in
  its own systemd slice, with its own limits and its own log namespace.
- **Ports.** Apps get ports 4100 to 4999 (pre-flight releases 14100 to 14999), so port numbers
  allow 900 apps. Memory runs out long before that.
- **Memory is checked at deploy.** A deploy is refused when the sum of the apps' memory caps would
  pass RAM x 1.5 (`mem_overcommit`; `--force` overrides it). Caps are ceilings, not reservations,
  so most apps use far less than their cap.
- **Priorities.** `priority = high|low` sets which app the kernel keeps under memory pressure, and
  its CPU weight.
- **Shared work is queued or spread.** Backups run one at a time in a window, jobs start spread
  over a part of their period with a host-wide limit on runs at once, and host setup reloads
  systemd and Caddy once for all apps.
- **`idle_stop`** is the biggest lever: an app that is stopped costs about 2 MB, so many rarely
  used apps fit where as many always-on ones do not.

What fits in 4 GB, measured with hello-world style apps. The always-on rows are hard limits; real
apps are bigger.

| App | Per app | Hard limit on 4 GB |
|---|---|---|
| Static site | about 0.6 MB (its Caddy site) | about 2,000 and more (extrapolated) |
| Go, always on | about 4 MB process | about 400 (200 measured) |
| Node hello, always on | about 14 MB process | about 230 (235 apps used 3.95 GB) |
| Next.js, always on | 80 to 300 MB | about 20 to 45 (research estimate) |
| Any web app with `idle_stop` | about 2 MB while idle | limited by what is awake at once |

Cold start after idle, median / 95th percentile: Node 0.16 / 0.17 s, Go 0.16 / 0.25 s,
Next.js 0.32 / 0.39 s. Overhead outside the app: journald 1.2 MB, a Caddy site 0.6 MB per app.
Monitoring at 25 apps on a test server: about 80 ms of CPU a minute (0.13%), and the 5 second live
loop 0.1%. `tando ls` renders 200 apps in 0.17 s. Method and raw numbers are in the squeeze and
spike audits kept with the project; the design is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
"Many apps on one server".

On a real 1 CPU, 2 GB server (this tree, 0.3.0 unreleased, against 0.2.2 where it was measured):

| | 0.2.2 | now |
|---|---|---|
| `tando status` | 0.63 to 0.78 s | 0.25 s |
| Redeploy with no change | 7.3 s | 2.0 to 2.2 s |
| Restart | | 1.45 to 1.65 s |
| Rollback | | 2.3 to 2.8 s |
| Deploy with a change | | 11 s |
| Monitoring CPU | 3.8 s a minute | 0.9 to 1.45 s a minute |

Load test over the internet against a minimal Node app on that server: 840 to 890 requests a
second at 20 to 50 concurrent connections (95th percentile 45 to 101 ms). Through pgbouncer, about
147 transactions a second at 20 concurrent (95th percentile 219 ms). These measure the network and
one core as much as tando. The monitoring figure was taken before the latest fsync fix.

## App limits and isolation

Each app is contained by the kernel, in its own cgroup. Defaults and how to change them:
[docs/COMMANDS.md](docs/COMMANDS.md), "Limits and load", and [docs/CONFIG.md](docs/CONFIG.md).

Contained per app:

- **Memory:** a hard cap (`memory`, default 256M); over it the process is killed and restarted,
  inside the app's own cgroup. `/tmp` is a tmpfs of its own (`tmp_size`, 64M) counted in that cap.
- **CPU and processes:** a CPU weight by `priority`, an optional `cpu` quota, and a `tasks` cap
  (1024 processes and threads).
- **Logs:** a size cap on the journal (default the smaller of 256M and 5% of the disk, within
  `log_budget`) and a rate limit (5000 lines per 30 s), so a log flood stays in that app.
- **Network:** at most 2048 connections at once (`conn_out`), 200 DNS packets a second
  (`dns_rate`) and 100 database connections per app, and `max_conns` and `max_requests` at the
  front door.
- **Crash loops:** a crashing app hits systemd's start limit, gets a down page and an alert.
- **Broken releases:** a release that fails the pre-flight, the health check or the soak is refused
  or rolled back, and the running one is not touched.

"Bounded shared fate" is what apps still share, each with a limit that keeps one app from owning
it: Caddy (with connection limits per client), PostgreSQL and pgbouncer (per-app pools, statement
and temp-file limits; a deploy is refused when the pools together pass `max_connections`), the
disk (a per-app `disk` alert and reserved room for the database and Caddy, not a hard quota), and
the kernel's connection tables. The core (Caddy, sshd, tandod, PostgreSQL) is protected from memory
reclaim before apps are. `test/e2e-neighbours.sh` runs a misbehaving app (CPU spin, memory leak,
fork bomb, log flood, crash loop, slow responses, thousands of connections, a full disk) next to
an always-on app and a scaled-to-zero one, and checks that they kept answering. A limit it finds
missing is reported as a finding, not hidden.

## Limits of tando and of the frameworks

- **One server per app.** No clusters, no load balancing across servers.
- **Next.js:** needs `output: "standalone"` (`tando up` offers to add it); expect 80 to 300 MB per
  app, so use `idle_stop` when you host many. A Next.js package inside a monorepo is not supported
  yet.
- **Node and Python:** listen on `$PORT`. `idle_stop` works through a socket tando holds, so the
  app needs no change; the first request after idle waits for the start. Monorepos: pnpm and npm
  workspaces only; Yarn and Bun workspaces are refused.
- **Static sites and containers:** no `idle_stop` (a static site has no process), and no workers
  for containers yet.
- **pgbouncer uses transaction pooling.** These do not work through it: `LISTEN`/`NOTIFY`,
  session advisory locks, session `SET` (use `SET LOCAL`), temporary tables kept across
  transactions, `WITH HOLD` cursors, and prepared statements on a driver that needs pgbouncer
  1.21 or newer. An app that needs one sets `db_direct = true` and talks to PostgreSQL itself;
  migrations always get `DATABASE_URL_DIRECT`. See "Database connections and pgbouncer" in
  [docs/COMMANDS.md](docs/COMMANDS.md).
- **The server never builds.** Build on your laptop or in CI; native packages are swapped for the
  server's platform ([docs/CROSS-ARCH.md](docs/CROSS-ARCH.md)).
- **The database studio is read-only;** writes go through `tando db psql`.
- **The dashboard is for one laptop** and needs `tando` on the same machine.

Coming, not merged yet: per-app Caddy timeouts and body limits, a deploy that replaces a release
still soaking, preview apps and a backup restore drill, a lighter Node runtime and a workerd
recipe, and a server that stops an idle app's journald.

## Alerts

Per-app checks include `offsite`, which fires when a backup has not reached the bucket. Host
checks are `care`, `updates`, `reboot`, `exposed`, `ssh`, `units`, `readonly`, `ioerr`, `clock`,
`eol` and `boot`. See [docs/MONITORING.md](docs/MONITORING.md).

## Status

Pre-1.0 (released 0.2.2; this tree is 0.3.0, unreleased). Tested on Ubuntu 26.04. Offsite backup is tested against a fake S3 only.
See [docs/STATUS.md](docs/STATUS.md) for what is verified and what is open.

## Documentation

- [Quickstart](docs/QUICKSTART.md) and the [index of all docs](docs/README.md)
- Setup guides: [laptop](docs/SETUP-LAPTOP.md), [empty server](docs/SETUP-EMPTY-VM.md), [server with existing services](docs/SETUP-EXISTING-VM.md)
- [Commands](docs/COMMANDS.md), [tando.conf settings](docs/CONFIG.md), [Monitoring](docs/MONITORING.md), [Backups](docs/BACKUP.md)
- [Host care](docs/HOSTCARE.md), [CI](docs/CI.md), [Logging](docs/LOGGING.md)
- [Changelog](CHANGELOG.md), [Security policy](SECURITY.md)

## License

Free for personal and other noncommercial use under the
[PolyForm Noncommercial License 1.0.0](LICENSE). Commercial use needs written approval first:
see [COMMERCIAL.md](COMMERCIAL.md).
