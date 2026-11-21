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

## Notable features

- **Deploys that cannot break the live app.** The new release starts on a spare port and must
  pass its health check before traffic switches. A release that fails is rolled back by itself,
  and the old one keeps answering the whole time.
- **Zero config.** `tando up` detects Node, Next.js and static sites and writes the config for
  you. Python and container apps work too (`tando recipes`).
- **Monitoring built in.** Checks every minute for app down, failing health, error spikes, new
  error types after a release, memory, disk and certificates. Alerts go to ntfy, Slack, Telegram,
  e-mail or a webhook. A hung app is restarted for you.
- **Logs, requests and metrics without extra services.** `tando logs`, `tando errors`,
  `tando requests` and a live `tando top`.
- **Backups you can restore from.** PostgreSQL or SQLite per app, daily backups, and encrypted
  offsite copies to Cloudflare R2 or any S3-compatible storage. A new server can be rebuilt from
  the bucket.
- **Host care.** tando watches the server itself: security updates, pending reboots, open ports,
  ssh settings, failed units, disk and clock. It can install security updates for you.
- **CI deploy keys.** A key that can deploy one app and nothing else, with a ready GitHub
  Actions workflow.
- **HTTPS and domains.** Caddy and Let's Encrypt, with a free `sslip.io` link until you add your
  own domain.
- **Runs beside what you already have.** Everything tando creates is prefixed `tando-` and lives
  under `/opt/tando`. It refuses to touch anything it did not create.

## Requirements

- Laptop: macOS or Linux, with bash 3.2+, ssh and rsync.
- Server: Ubuntu 24.04 or newer, with sshd and a login that has passwordless sudo.
- Nothing else has to be installed on the server.

## Install

From a release archive (see the Releases page; the `.sha256` file is checked for you):

    ./install.sh --from tando-0.2.1.tar.gz

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

## Alerts

Per-app checks include `offsite`, which fires when a backup has not reached the bucket. Host
checks are `care`, `updates`, `reboot`, `exposed`, `ssh`, `units`, `readonly`, `ioerr`, `clock`,
`eol` and `boot`. See [docs/MONITORING.md](docs/MONITORING.md).

## Status

Pre-1.0 (version 0.2.1). Tested on Ubuntu 26.04. Offsite backup is tested against a fake S3 only.
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
