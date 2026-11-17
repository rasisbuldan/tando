# tando: release management and a small app platform for your own VMs

> **Status of this document (14 Nov 2026).** This is the pre-build design draft (draft 3, 13 Nov).
> The build superseded it: docs/ARCHITECTURE.md describes what exists, and docs/ (STATUS.md,
> COMMANDS.md, CI.md, LOGGING.md, MONITORING.md, MIGRATION.md) describe the rest. Kept as history.
> The main places where the build differs:
> - Layout: everything lives under `/opt/tando/apps/<app>/` (not `/opt/<app>`, `/etc/tando`,
>   `/usr/local/lib/tando`); no `staging/`; `incoming/` is one directory per app.
> - Roles: the admin's ssh login + sudo runs the agent. There is no shared `deploy` user, and
>   there is no `tando apply`: `up`/`deploy` apply tando.conf. Per-app CI keys came later as
>   `tando ci` with `tando-gate` (user `tando-d-<app>`), not `tando key add`.
> - Language: all of it is shell, server side included (§16 recommended Go for it); about 13,400
>   lines, not 4,700.
> - Not resident: a per-minute timer (tando-watch, metrics) does exist, and `tando top` is a
>   full-screen dashboard (§2 ruled both out). `tando up` was built.
> - Availability: request holding (Caddy, 15 s or health_timeout) and a 30 s soak. `instances = N`
>   and runtimes side by side were not built.
> - Extra: `adopt`, alerts and notifiers, the `go` wizard, the per-uid nftables loopback rules.

Status: draft 3, for review. Nothing here is built except where marked "exists today".
`tando` is a working name. Earlier drafts: `SPEC-v1.md`, `SPEC-v2.md`. Review of draft 2: `REVIEW.md`.
Why this exists and how it compares to other tools: `WHY.md`.

Changes from draft 2:

- Security model redesigned after the review: two roles, one key per app, a gate script, uploads
  isolated before root touches them, activation detached from the ssh session (sections 3, 8).
- Platform features approved on 13 Nov: zero-config `init`, HTTPS link per app, environment variables,
  database, scheduled jobs, logs, rollback, health checks (section 9).
- Gap closers for larger machines: request-holding restarts, several instances per app, runtime
  versions side by side (sections 10, 11).
- Interactive dashboard replaced by boxed tables that refresh themselves (section 12).
- Honest size estimates, and with them a reopened language decision (section 16).

Server facts used below were checked on the VM on 13 Nov 2026: Ubuntu 26.04, systemd 259, Caddy 2.6.2,
rsync 3.4.1 with `rrsync`, `nft`, `setpriv`, `systemd-run`, `systemd-creds` present; `sqlite3` and
PostgreSQL not installed (PostgreSQL 18 available from apt); ufw allows 22, 80, 443 only.

## 1. Goals

1. One command deploys an app: build off the server, upload changes, activate, health-check, roll back
   on failure.
2. A new project goes from an empty config to a live HTTPS link with three commands.
3. One view per host of every app: version, state, uptime, CPU, memory against its cap, health.
4. Environment variables, a database, scheduled jobs, logs and rollback are each one command.
5. Nothing resident on the server. tando adds no daemon and, by default, no periodic job of its own.
6. A stolen deploy key for one app cannot reach another app or root.

## 2. Non-goals

- Building on the server. A container daemon. A web dashboard. An interactive full-screen dashboard.
- A global network, autoscaling, or high availability across machines.
- Managing DNS records (one wildcard record is created by hand, once).
- Preview links per branch, sleep-when-idle, and `tando up` (single-command first deploy): deferred,
  not approved yet (section 17).

## 3. Roles and trust

| Role | Who | Identity | Can do |
|---|---|---|---|
| admin | the server owner | personal ssh login with sudo (exists today) | install tando on a host, `apply` an app's runtime config, create databases, issue and revoke deploy keys |
| deploy | a laptop or a CI job, for one app | one ssh key per (app, source), login user `deploy` | upload a release for that app, activate it, roll back, read status and logs, set that app's environment variables |
| app | the running service | system user named after the app, no login | read its release, write its data and cache directories |

Rules that follow:

- Deploy rights on an app equal that app's secrets and data, because deployed code runs with them. A
  deploy key must never give more than that.
- Only admin changes what runs as root or how an app is sandboxed: the unit, timers, firewall rules,
  Caddy config, hooks, memory caps, run-as user. These come from `tando apply`.
- Nothing the deploy role uploads is executed by root. Nothing the app user can write is read by root
  as anything but data.

### How the deploy role is confined

```
authorized_keys of user `deploy`, one line per key:
restrict,command="/usr/local/lib/tando/gate bakery laptop-alice" ssh-ed25519 AAAA...
```

- The app name and key label are fixed on the server in that line. The client cannot choose them.
- `gate` reads `SSH_ORIGINAL_COMMAND` and accepts exactly two shapes:
  1. an rsync server command, which it replaces with `rrsync -wo /opt/<app>/incoming` (write-only,
     confined to that directory, link munging on);
  2. `tando <verb> [args]` with `<verb>` from a fixed list (`begin`, `activate`, `rollback`, `status`,
     `releases`, `history`, `logs`, `restart`, `stop`, `start`, `env-set`, `env-unset`, `env-list`).
     Arguments are matched against per-verb patterns; anything else is refused and logged.
- For verbs that need root, `gate` runs `sudo /usr/local/lib/tando/agent <verb> <app> <args>`. The
  sudoers entry allows `deploy` to run that one path. The agent re-validates everything and has no
  verb that takes a path, a unit name or a command from the caller.
- Read-only verbs (`status`, `releases`, `history`) run without sudo.
- Admin-only verbs (`apply`, `host-setup`, `key-add`, `key-revoke`, `db-create`, `adopt`) live in a
  second file, `/usr/local/lib/tando/admin`, which is not in the deploy sudoers entry.

### Threats considered

| Threat | Outcome with this design |
|---|---|
| CI key for app A leaks | Attacker can deploy to A and read A's secrets. B and root are out of reach |
| Malicious upload (symlinks, devices, setuid, swap during copy) | Upload is renamed into a root-only directory before inspection; non-regular files are rejected; root never executes it (section 8) |
| Compromised app process | Confined by its unit and firewall rules (section 10). Cannot write its own code. Cannot reach other apps' ports or Caddy's admin interface |
| Compromised server attacks the laptop | CLI parses a fixed list of fields and strips control characters; nothing from the server is evaluated |
| Laptop stolen | Per-app deploy keys are revocable one by one; the admin key should have a passphrase |

Not defended: a kernel exploit from inside an app, a malicious admin, a compromised build machine.

## 4. Architecture

```
laptop or CI                              server
┌──────────────────────────┐  ssh     ┌───────────────────────────────────────────┐
│ tando  CLI               │ ───────► │ gate    forced command, validates, routes │
│  recipes: build + pack   │  rsync   │ agent   deploy verbs, root via sudo       │
│  ui: boxed tables        │ ───────► │ admin   setup verbs, admin login only     │
│  tando.conf per project  │          │ systemd, Caddy, nftables, journald        │
└──────────────────────────┘          └───────────────────────────────────────────┘
```

- All rendering is on the laptop. Server programs print `key=value` records only.
- `agent` and `admin` live in `/usr/local/lib/tando/`, owned by root, with a `protocol` number. The CLI
  refuses to talk to a server outside its supported protocol range and says which side to upgrade.
- Repository: `~/github/tando` (exists today, spec only).

## 5. Server layout

Per app `<app>` (`[a-z][a-z0-9-]{1,30}`):

| Path | Owner, mode | Purpose |
|---|---|---|
| `/opt/<app>/incoming/<upload>/` | `deploy`, 700 | One directory per upload, named by a token from `begin` |
| `/opt/<app>/staging/` | root, 700 | Uploads are renamed here before root inspects them |
| `/opt/<app>/releases/<id>/` | root:`<app>`, dirs 750, files 640 | Immutable releases. Other apps cannot read them |
| `/opt/<app>/current` | root | Symlink to the active release |
| `/opt/<app>/state` | root | Deploy state file, lock, `previous` and `last_good` pointers |
| `/var/lib/<app>/` | `<app>`, 700 | Data, including SQLite files |
| `/var/cache/<app>/` | `<app>`, 700 | Caches that survive releases (image cache) |
| `/etc/tando/apps/<app>/env` | root, 600 | Environment variables |
| `/etc/tando/apps/<app>/runtime.conf` | root, 644 | Runtime config as applied by admin, with its hash |
| `/var/lib/tando/history/<app>.tsv` | root, 644 | Deploy history |
| `/etc/systemd/system/<app>.service`, `<app>-cron-*.{service,timer}` | root | Rendered by `apply` |
| `/etc/caddy/sites/<app>.caddy` | root | Rendered by `apply` |
| `/etc/nftables.d/tando-<app>.nft` | root | Rendered by `apply` |
| `/opt/tando/runtimes/node/<version>/` | root | Runtime versions side by side |

Exists today: bakery and magazine use `releases/`, `current`, a unit per app and `/etc/<app>.env`.
`adopt` (admin) moves an existing app onto this layout without a redeploy and tolerates old release
names that have no metadata.

## 6. Configuration

One file per project, `tando.conf`, one `key = value` per line, full-line `#` comments only. Keys are
in two classes, and the class decides who may change them.

Build keys, used on the laptop or CI and free to change with any deploy:

```ini
app     = notes
host    = vm1
type    = next-standalone          # next-standalone | node | static | custom
node    = 24                       # must match a runtime installed on the host
build   = npm run build            # set by `init`, run on the build machine only
test    = npm test                 # optional
build_env = NEXT_PUBLIC_SITE_URL   # names of variables read from the local environment at build
```

Runtime keys, applied to the server only by admin with `tando apply`:

```ini
domain     = auto                  # auto = <app>.<apps domain of the host>; or a full hostname
port       = auto                  # allocated from the host's range at first apply
instances  = 1
memory_max = 400M
health     = /                     # one or more lines; each must return 200
health     = /_next/image?url=%2Flogo.png&w=96&q=75
writable   = .next/cache -> cache  # release path mapped onto /var/cache/<app>
database   = sqlite                # none | sqlite | postgres
outbound   = yes                   # no = block all outgoing connections
keep       = 3
cron.digest  = *-*-* 20:00 UTC | POST /api/cron/digest
cron.cleanup = Mon 03:00 | exec node scripts/cleanup.js
pre_activate = backup              # built-in names only: backup
```

- `tando deploy` sends a hash of the runtime keys. If it differs from the applied one, the agent
  refuses with "runtime config changed; run `tando apply` as admin". A deploy can never change them.
- Nothing in this file is executed on the server except `cron.* = ... | exec <command>`, which runs as
  the app user inside the app's sandbox from the release directory, and only after admin applied it.
- Hosts are defined on the laptop in `~/.config/tando/hosts.conf` (`vm1.addr`, `vm1.admin_user`,
  `vm1.apps_domain`, one key per line). Keys are stored in `~/.config/tando/keys/<host>/<app>`.
  In CI the host address, known_hosts entry and key come from three secrets.

## 7. Commands

| Command | Role | Does |
|---|---|---|
| `tando init` | local | Detect the framework, write `tando.conf` (section 9.1) |
| `tando host add` / `host setup` | admin | Register a host; install gate, agent, admin, `deploy` user, base firewall table, Caddy admin socket |
| `tando apply` | admin | Create or update the app on the server from the runtime keys; issue this machine's deploy key on first run |
| `tando key add <label>` / `key revoke <label>` | admin | Issue or revoke a deploy key (for CI or a second laptop) |
| `tando deploy` | deploy | Build and ship (section 8). `--no-build` re-ships the last stage as a new release |
| `tando rollback [id]` | deploy | Activate the previous good release, or a named one |
| `tando releases` / `history` | deploy | Releases on the server; past deploys with per-phase seconds |
| `tando status` / `ls [host]` / `hosts` | deploy / admin | Boxed tables (section 12). `ls` and `hosts` across apps need the admin login |
| `tando logs [-f] [-n N] [--since T]` | deploy | App log; `-f` follows |
| `tando restart` / `stop` / `start` | deploy | Take the app lock, act, health-check on restart and start |
| `tando env set K=V` / `unset K` / `list` | deploy | Environment variables (section 9.3) |
| `tando db create` / `db backup` / `db shell` | admin | Database (section 9.4) |
| `tando doctor` | any | Local tools, connectivity, protocol match, disk, runtime version, DNS for the domain |

With stdout not a terminal, or `--plain`, every command prints plain aligned text.

## 8. Deploy pipeline

| # | Phase | Where | What |
|---|---|---|---|
| 1 | check | local, server | Config valid; `begin` on the server takes the app lock with a 15-minute expiry, verifies the runtime hash, free disk (1 GB plus twice the last release size), Node version, and returns an upload token |
| 2 | test | local | If `test` is set |
| 3 | build | local | Recipe. In a clean checkout of the commit being deployed when started by the hook or CI |
| 4 | pack | local | Stage directory, platform binaries for the server's architecture, precompression (cached by file hash), manifest of paths and sizes, guard |
| 5 | send | local to server | rsync into `incoming/<token>/` with `--copy-dest` pointing at the current release |
| 6 | activate | server | Below |
| 7 | prune | server | Below |

Guard at the end of `pack`, repeated by the agent on the server: no `.env*`, no `data` directory, every
`*.node` file is an ELF for the server's architecture.

### Activate, on the server

Runs as a transient systemd unit (`systemd-run --unit tando-activate-<app> --wait --pipe`), so it
continues if the ssh session dies. Steps, each recorded in `/opt/<app>/state`:

1. Verify the caller holds the lock from `begin`. Rename `incoming/<token>` into `staging/` (same
   filesystem, atomic). From here the deploy user cannot reach the files.
2. Inspect: only regular files, directories and symlinks that resolve inside the tree; no setuid or
   setgid bits; manifest matches paths and sizes; guard passes. Otherwise delete and fail.
3. Copy into `releases/<id>/` as new files owned root:`<app>`. The id is assigned here:
   `<server UTC time>-<sequence>`; the commit, dirty flag, builder and tool versions sent by the client
   are stored in `release.json` as validated strings.
4. Run `pre_activate` if set (`backup`: snapshot `/var/lib/<app>` and keep 14 days).
5. Switch `current` atomically (`ln -s` to a temporary name, `mv -T`). Record `previous`.
6. Restart the service (section 11 for how requests are held).
7. Health: every `health` line returns 200 three times in a row, 1 s apart, within 60 s, and the
   unit's restart counter has not increased. Success sets `last_good`.
8. On failure: switch back to `previous`, restart, run health once; write the failing lines of the
   journal to the state file; delete the failed release. If the previous release also fails health,
   stop and report both failures; do not loop.
9. Append to history; release the lock.

Any later mutating verb first reads the state file. If it shows an activation that never finished
(server reboot mid-deploy), the agent completes the rollback before doing anything else.

In CI, failure output is limited to "unhealthy" and the failing check; journal lines are not printed
there because they can contain customer data.

### Rollback and prune

- `rollback` with no argument targets `last_good` other than the current release, not simply the
  next-older directory. Rollback does not touch data; a release that migrated a database must ship its
  own way back. The CLI prints this warning when `database` is not `none`.
- Prune keeps `keep` releases, never removes `current`, `previous` or `last_good`, and removes
  releases marked failed first.

### History

`/var/lib/tando/history/<app>.tsv`, append-only, one start record and one end record per deploy or
rollback: time, release id, commit, key label (from the gate, not from the client), source, result,
total seconds, seconds per phase, bytes staged and sent. Client-side timings are accepted as
integers only. Trimmed to 500 records by rewrite-and-rename under the app lock.

## 9. Platform features

### 9.1 Zero config: `tando init`

Detects, in order: `next.config.*` with `output: "standalone"` or able to set it (`next-standalone`);
a `package.json` with a `start` script (`node`); an `index.html` or a build that emits one (`static`).
It writes `tando.conf` with `domain = auto`, `port = auto`, the Node major from `.nvmrc`, `engines` or
the local version, and a first `health = /`. It asks one question: which host. It changes nothing on
any server. Unknown project types get `type = custom` with the keys to fill in.

First deploy is then `tando init`, `tando apply`, `tando deploy`.

### 9.2 HTTPS link

- One-time, by hand: a wildcard DNS record `*.apps.<your domain>` pointing at the host, recorded as
  `apps_domain` for that host.
- `apply` writes `/etc/caddy/sites/<app>.caddy` with an explicit site address
  (`notes.apps.example.com`) and reloads Caddy. Caddy obtains the certificate for a named site by
  itself; on-demand TLS is not used, so nobody can make the server request certificates for arbitrary
  names.
- A custom `domain` works the same way once its DNS points at the host. Several apps under paths of
  one domain (as bakery at `/bakery`) are expressed with `domain = example.com/path`; `apply` merges
  them into one site block per hostname.
- `apply` runs `caddy validate` before reload and restores the previous file if validation fails.
- Limit: Let's Encrypt issues a bounded number of certificates per registered domain per week
  (50 at the time of writing, recalled, not re-checked). `doctor` counts sites per domain.

### 9.3 Environment variables

- `tando env set KEY=value` sends the value on stdin, never in the command line. The agent accepts
  names matching `[A-Z][A-Z0-9_]*`, rejects names in a reserved list (`PORT`, `HOSTNAME`, `NODE_OPTIONS`,
  `LD_*`, `PATH`), rejects values containing newlines or NUL, writes the file atomically with mode
  600, then restarts and health-checks. A failed health check restores the previous file.
- `env list` prints names only. Values are never printed, logged or stored in history.
- Variables needed at build time are a separate matter: they are named in `build_env`, read from the
  build machine's environment (or CI secrets), and are by nature public once compiled into a
  browser bundle. `init` explains this for `NEXT_PUBLIC_*`.

### 9.4 Database

- `database = sqlite` (default for new apps): the app gets `DATABASE_URL=file:/var/lib/<app>/app.db`
  in its environment. `apply` adds a nightly timer that takes a consistent copy with
  `sqlite3 .backup`, keeps 14 days in `/var/backups/<app>/`, and installs the `sqlite3` package if
  missing. Cost: none while idle.
- `database = postgres`: one PostgreSQL instance per host from the distribution package, managed by
  systemd, listening on a unix socket only. `tando db create` (admin) creates a role and a database
  named after the app, with peer authentication for the app's system user, and sets
  `DATABASE_URL`. Nightly `pg_dump` per database, 14 days kept. `host setup --postgres` installs it
  with settings sized to the machine (`shared_buffers` at 1/16 of RAM, capped connections).
  Memory cost on the 2 GB VM is not measured yet; it must be measured before this is offered there.
- `tando db backup` runs the backup now; `tando db shell` opens the database client as admin.
- Restores are manual and documented; no automatic restore on rollback.

### 9.5 Scheduled jobs

Each `cron.<name>` line becomes a systemd timer and a oneshot service, rendered by `apply`:

- `POST /path`: a local request to the app with a per-app secret header taken from its environment
  (`TANDO_CRON_SECRET`, generated at first apply), as magazine does today.
- `exec <command>`: runs as the app user, in the app's sandbox and release directory, with its
  environment.

Schedules use systemd calendar syntax, validated with `systemd-analyze calendar` at apply. Jobs get a
runtime limit (default 5 minutes) and do not overlap with themselves. `tando status` shows each job's
last run, result and next run. Job output goes to the app's log.

### 9.6 Logs

- `tando logs` builds its own `journalctl` invocation for the app's unit and its job units:
  `--no-pager`, `-n` numeric with a ceiling, `--since` matching `-N[smhd]` or an ISO date. The unit
  names come from the applied config.
- `-f` follows until interrupted. Lines are stripped of control characters before display.
- Retention is journald's, capped per host at setup (default 200 MB).

### 9.7 Rollback

As section 8. One command, health-checked, never targets a release marked failed.

### 9.8 Health checks

- At deploy, restart, start, rollback and `env set`: section 8, step 7.
- On demand: `tando status` runs the checks once and shows the status code and time for each.
- Continuous checking with a notification is the optional watch timer (section 12). Without it, tando
  learns of an outage only when asked. systemd restarts a crashed process on its own in either case.

## 10. Runtime hardening

Unit template rendered by `apply` (the values are a starting point to verify with
`systemd-analyze security`, target score below 3.0):

- Own user and group; `MemoryMax`, `MemoryHigh` at 85% of it, `TasksMax`, `CPUWeight`.
- `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`,
  `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`, `ProtectProc=invisible`,
  `RestrictNamespaces`, `RestrictSUIDSGID`, `LockPersonality`, `CapabilityBoundingSet=` (empty),
  `SystemCallFilter=@system-service`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`.
- `TemporaryFileSystem=/opt` with `BindReadOnlyPaths=/opt/<app>` and the app's runtime directory, so
  other apps' code is not visible. `StateDirectory`, `CacheDirectory` for data and cache.
- `writable` mappings become `BindPaths` from `/var/cache/<app>/...` onto the release path. The
  release itself stays read-only. Apps that rewrite their own build output (magazine's regenerated
  pages) declare those paths the same way.
- `outbound = no` adds `IPAddressDeny=any` and `IPAddressAllow=localhost`.

Between apps on loopback, rendered into `/etc/nftables.d/tando-<app>.nft`: connections to an app's
port on 127.0.0.1 are accepted only from Caddy's user and root, and dropped otherwise. This uses the
kernel's socket-owner match on locally generated traffic. It has to be proven on the VM alongside the
existing ufw rules before the spec relies on it.

Caddy: `host setup` moves the admin interface from 127.0.0.1:2019 (open to every local process today,
checked) to a unix socket readable by root only, and points reloads at it.

Runtimes: `host setup --node 24` unpacks the official Node build into
`/opt/tando/runtimes/node/24.x.y/` and verifies its published checksum. The unit's `ExecStart` uses
the version pinned by `node =`. `check` compares the build machine's major version with it.

What this still does not give: a private root filesystem per app, or protection from a kernel exploit.

## 11. Availability

- Request holding (default): the app's Caddy block uses `lb_try_duration 10s` and
  `lb_try_interval 250ms`. While the app restarts, new requests wait for the port instead of failing.
  Requests already in progress when the process stops are still cut unless the app finishes them on
  SIGTERM; the unit gives it `TimeoutStopSec=15`. To be measured with a load test during a deploy.
- `instances = N`: `apply` renders `<app>@.service` and N ports; Caddy balances across them with
  active health checks. Deploys restart instances one at a time, so with N of 2 or more there is no
  gap. Memory caps apply per instance and are counted N times.
- Two releases side by side (start new, switch, stop old) is not planned while `instances` covers the
  need.

## 12. Monitoring and terminal UI

Rule: no resident process. Costs measured on the VM on 13 Nov with prototypes:

| Action | Server CPU | When |
|---|---|---|
| Status of 2 services | 43 ms | per refresh, only while a view is open; default interval 5 s (0.9% of one core) |
| Optional watch sample, per app | 18 ms | once a minute if enabled (0.03%) |
| Host history from sysstat | 24 ms | on request; sysstat is used if present, not required |

- Status reads `systemctl show` and the unit's cgroup files without sudo. CPU "now" is computed on
  the laptop from two cumulative readings. Health is cached for 30 s.
- The per-app log size metric from draft 2 is dropped. `ls` shows the journal's total disk use.
- Optional watch timer, off by default, enabled per host by admin: once a minute it appends one
  line per app to a 7-day ring file (about 373 KB per app) and, after two consecutive failed health
  checks, sends one POST to a configured URL. It is the only periodic job tando ever installs for
  itself.

UI: boxed, colour, same drawing code as the author's earlier sync script (a 39-row frame renders in 12 ms under
macOS bash 3.2, measured). Screens are static tables: `hosts`, `ls`, `status`, `history`, `releases`,
and a live phase list during `deploy`. `--watch [N]` redraws a table every N seconds until Ctrl-C.
There is no key handling beyond Ctrl-C and no two-pane layout. Tables drop low-priority columns below
100 columns and fall back to plain text below 80. Upload progress shows files sent, not bytes, because
macOS ships an rsync without byte progress.

`tando status notes`, sketch:

```
╭─ notes on vm1 ─────────────────────────────────────────────── ● running 2h 10m ─╮
│ url       https://notes.apps.example.com                                        │
│ version   20261113-165416-0042   commit 1ba87ba   deployed by laptop-alice      │
│ memory    206M now · 234M peak · cap 400M   ━━━━━━━━━━━━━━──────────────        │
│ cpu       0.4% now · 0.6% average since start        restarts 0                 │
│ health    /  200 41ms     /_next/image…  200 63ms                               │
│ database  sqlite 3.2M · last backup 02:00 ok                                    │
│ jobs      digest   last 20:00 ok   next 20:00      cleanup  last Mon ok         │
│ deploys   13 Nov 16:54 ok 91s (build 8s)   11 Nov 21:40 ok 312s                 │
╰─ tando status notes --watch ───────────────────────────────────── refreshed 5s ─╯
```

## 13. Automatic deploys

- GitHub Actions (primary): `tando init --ci` writes a workflow that checks out the project and a
  pinned tag of tando, restores dependency and build caches, and runs `tando deploy --plain` with a
  deploy key issued by `tando key add ci`. The runner matches the server's architecture.
- Pre-push hook (optional, for projects without a remote CI): on pushing the configured branch it
  builds the pushed commit in a temporary worktree, never the working directory; refuses if that
  commit is not what `HEAD` of the branch will be; runs after tests; and can be skipped with
  `TANDO_SKIP=1`. It still deploys before the remote has accepted the push; the hook prints that. If a
  tando workflow file exists in the project, the hook does nothing and says so.

## 14. Known limits

- A single-instance app drops requests that are in flight at the moment of restart unless it shuts
  down gracefully.
- One server per app. No fleet view across hosts in one table beyond `hosts`.
- Rollback does not undo data changes.
- Postgres on a 2 GB machine may not be affordable; unmeasured.
- Apps share the host kernel and loopback device; isolation is by policy, not by separate machines.
- An outage is noticed only on request unless the watch timer is enabled.
- bakery is not a git repository of its own today, so commit and dirty fields will be empty for it
  until it is.

## 15. Rollout

| Phase | Scope | Exit test, on a throwaway VM unless stated |
|---|---|---|
| 0 | Prototype the four unproven mechanisms: gate with rrsync, nftables loopback rule beside ufw, Caddy admin on a unix socket, request holding under load | Each works or the spec is changed |
| 1 | `host setup`, `apply` (unit, Caddy site, no cron, no db), `adopt`, gate, agent with `begin`, `activate`, `rollback`, `status`, `releases`, `history`, `logs`. CLI `deploy` plain output, `next-standalone` recipe | bakery adopted and deployed on the real VM; killed-ssh deploy recovers; hostile uploads rejected; a second app's key cannot touch bakery; rollback to a pre-tando release works |
| 2 | `init`, HTTPS link with `domain = auto`, `env`, health lists, `restart/stop/start`, hardened unit template | A new Next project reaches a live HTTPS link with three commands; security score below 3.0 |
| 3 | Scheduled jobs, SQLite database with backups, boxed tables and `--watch`, deploy phase display, performance work on pack and warm-up | magazine's six jobs expressed in config; bakery deploy under 30 s |
| 4 | Actions workflow, `key add/revoke`, `instances`, Node runtimes side by side, `node` and `static` recipes | One app deploying from CI with its own key |
| 5 | Postgres, watch timer and notification, pre-push hook, magazine adopted with its owner | On request |

## 16. Size and language

Estimates, not measurements: gate about 120 lines, agent about 900, admin about 700, CLI about 3,000
including about 500 of UI. That is roughly 4,700 lines, against draft 2's tripwire of 2,500 for the
CLI alone and 400 for the agent.

Shell was chosen on 13 Nov when the scope was a deploy script with a status table. The scope is now a
small platform with a root-privileged agent that parses hostile input. The comparison:

| | Shell | Go |
|---|---|---|
| Root code handling hostile input (gate, agent, admin: about 1,700 lines) | Each unquoted expansion is a potential escalation; POSIX sh has no arrays or local variables | Typed, no quoting class of bug, ordinary unit tests |
| Install on server | Copy three scripts | Copy one static binary, built on laptop or CI for the server's architecture |
| Toolchain | None | Go on the laptop and in CI (not installed today) |
| Existing code reused | Two working deploy scripts, 224 lines of UI | None; UI from a library |
| Editing in place on the server | Easy, and also a risk | Rebuild |

Recommendation: write the three server programs in Go as one binary, because that is where a bug costs
root. Keep the CLI in shell for phases 1 to 3 to reuse the existing scripts and UI code, and revisit
when it passes 2,500 lines. This reverses part of an earlier decision and needs the owner's agreement.

## 17. Decisions

Decided by the owner: own repository; dedicated `deploy` user; boxed UI; Actions and pre-push both
supported; approved features of section 9.

Open:

1. Language for the server programs: Go (recommended) or shell.
2. The apps domain for HTTPS links (for example `apps.example.com`) and who creates the wildcard
   DNS record.
3. Is the static boxed UI with `--watch` acceptable in place of an interactive dashboard?
4. Postgres: wanted on the current 2 GB VM, or only on larger hosts?

Deferred until asked for: preview links per branch, sleep-when-idle, `tando up`, Podman-run services,
two-release switching, encrypted secrets with systemd credentials, per-app resource priorities.
