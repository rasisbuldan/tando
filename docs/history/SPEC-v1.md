# tando: lightweight release management for small VMs

Status: draft for review. Nothing in this document is built yet, except where marked "exists today".
`tando` is a working name.

## 1. Problem

One 1 vCPU / 2 GB VM now hosts two apps (bakery, magazine) and will host more. Each app has its own
hand-written deploy script. They do nearly the same thing with different names, and there is no single
place to see what is running, which version, and how much memory it takes.

Building on the VM is no longer acceptable: one `next build` took about 850 MB and the whole CPU for
minutes, slowing every other app.

## 2. Goals

1. One command deploys any app: build off the VM, upload, activate, health-check, roll back on failure.
2. One command shows every app on a host: version, uptime, CPU, memory, restarts, log and disk size.
3. Start, stop, restart, roll back and tail logs from the laptop or on the server, with the same words.
4. Manual deploy by default; automatic deploy on push as an opt-in per app.
5. Costs nothing while idle: no daemon, no container runtime, no database, no web panel.
6. Adopting it for bakery and magazine changes file names, not how they run.

## 3. Non-goals

- Containers, image registries, Kubernetes-style orchestration.
- Building on the server, in any form.
- Zero-downtime switching. A restart takes 1 to 2 seconds; that is accepted for now (see 12).
- A web dashboard. Terminal only.
- Managing DNS, TLS certificates (Caddy does this) or the database inside an app.

## 4. Why not an existing framework

| Tool | Why it does not fit |
|---|---|
| Kamal | Needs Docker on the VM and an image registry. Docker's daemon takes memory a 2 GB VM cannot spare |
| Coolify, Dokku, CapRover | Build on the server. Coolify alone asks for about 2 GB |
| PM2 deploy | Pulls git and builds on the server; adds a resident Node process |
| Capistrano, Shipit | Same release-and-symlink model as below, but no status or monitoring, plus a Ruby or Node dependency |
| systemd + Caddy (in use today) | Already supervises, restarts, caps memory, collects logs and measures CPU and memory per app |

Decision: keep systemd and Caddy as the runtime and add a thin layer of conventions and two small
programs on top. Everything `tando` reports comes from systemd and the filesystem at the moment you ask.

## 5. Shape

```
laptop (or CI)                            VM
┌──────────────────────────┐   ssh    ┌───────────────────────────────────────┐
│ tando  (CLI)             │ ───────► │ tando-agent (root, via sudo, on call) │
│  build recipe            │  rsync   │  /opt/<app>/incoming → releases/<id>  │
│  stage + release.json    │ ───────► │  symlink switch, systemctl, health    │
│  tando.conf in each repo │          │  reads systemd + cgroup for status    │
└──────────────────────────┘          └───────────────────────────────────────┘
```

- `tando` runs wherever the build runs. It never needs root locally.
- `tando-agent` is one file at `/usr/local/bin/tando-agent`. It runs only for the duration of a command.
- Every laptop command that touches the server is `ssh host sudo tando-agent <verb> <app> ...`.
  Logged in on the server, you type `sudo tando-agent <verb>` (aliased to `tando`) and get the same output.

### Implementation language

Recommended: POSIX shell/bash for both programs.

- Both existing deploy scripts are shell; most of the agent is a generalisation of magazine's `remote.sh`
  (`activate`, `rollback`, health loop, keep 3 releases) and bakery's `deploy-vps.sh` (sharp swap,
  precompression, backup hook, image warm-up). This is a refactor, not a rewrite.
- No runtime to install or keep in step on either side.
- Alternative considered: a single Go binary (nicer tables, real config parsing), at the price of a
  toolchain and cross-compilation. Worth revisiting only if the shell version passes about 600 lines.

## 6. Conventions on the server

Per app, name `<app>` (lowercase, `[a-z0-9-]`):

| Path | Purpose |
|---|---|
| `/opt/<app>/incoming/` | rsync target, owned by the deploy user. Persistent, so only changed files travel |
| `/opt/<app>/releases/<id>/` | Immutable copies of `incoming`. Newest `keep` (default 3) are kept |
| `/opt/<app>/current` | Symlink to the active release (or a subdirectory of it, for monorepo output) |
| `/var/lib/<app>/` | App data. Never inside a release |
| `/etc/<app>.env` | Secrets, mode 600. Never in a repo, never in a release |
| `/etc/tando/apps/<app>.conf` | Server-side copy of the app's config, written at deploy. This is the registry |
| `/etc/systemd/system/<app>.service` | Rendered from a template at `provision`, or supplied by the repo |
| `/etc/caddy/sites/<app>.caddy` | Site snippet, imported by the main Caddyfile |

Exists today: bakery and magazine already use `releases/` + `current` + `/etc/<app>.env` + a systemd
unit named after the app. magazine calls the upload directory `staging`; bakery calls it `incoming`.

Release id: `<UTC yyyymmdd-hhmmss>-<git short sha>`, with `-dirty` appended when the tree had
uncommitted changes. Each release carries `release.json`:

```json
{ "app": "bakery", "id": "20261113-165416-1ba87ba", "commit": "1ba87ba", "dirty": false,
  "branch": "main", "built_at": "2026-11-13T09:54:16Z", "built_on": "laptop", "node": "24.19.0" }
```

## 7. App config: `tando.conf`

One file at the repo root, plain `key = value` (parsed, never executed):

```ini
app        = bakery
host       = vm1                  # name from ~/.config/tando/hosts, not an address
type       = next-standalone      # next-standalone | static | custom
port       = 3100
health     = /bakery/order/new    # must return 200 on 127.0.0.1:<port>
keep       = 3
user       = bakery
memory_max = 400M                 # written into the unit; summed across apps in `tando ls`
# optional
subdir        =                   # app directory inside the release (monorepo standalone output)
build         =                   # type=custom: command that fills .deploy/stage
pre_activate  = /usr/local/bin/bakery-backup     # runs on the server before the switch
post_activate = warm-images       # built-in or a path on the server
auto          = off               # off | push
```

Host addresses and key paths live only on the laptop, in `~/.config/tando/hosts`
(`vm1 = user@address  key=~/.ssh/...`). They are not committed anywhere.

### Build recipes

- `next-standalone` (exists today inside bakery's script): `next build` with standalone output, copy
  `public` and `.next/static`, replace `sharp` with the target platform's binary at the exact pinned
  version, precompress static assets with zstd, brotli and gzip.
- `static`: run the build command, ship one directory, no service (Caddy serves it).
- `custom`: the repo provides the command; `tando` only requires that `.deploy/stage` ends up complete.

Every recipe ends with the same guard: the stage must not contain `.env*`, a `data` directory, or
binaries for another platform. A hit aborts the deploy before upload.

## 8. Commands

Laptop, run inside a repo with `tando.conf` (or with `-a <app> -H <host>` from anywhere):

| Command | Does |
|---|---|
| `tando deploy` | build → stage → guard → rsync → activate → health → post hooks → prune |
| `tando deploy --no-build` | re-ship the existing stage (retry after a network failure) |
| `tando rollback [id]` | switch to the previous (or named) release, restart, health-check |
| `tando releases` | list releases on the server: id, commit, built at, size, which is active |
| `tando status` | one app in detail (see 9) |
| `tando ls` | all apps on the host, one row each (see 9) |
| `tando top` | `ls`, refreshed every 2 seconds until Ctrl-C |
| `tando logs [-f] [-n N] [--since T]` | `journalctl -u <app>` passthrough |
| `tando restart` / `stop` / `start` | `systemctl` passthrough, followed by a health check for restart and start |
| `tando provision` | first-time setup: user, directories, unit, Caddy snippet. Idempotent |
| `tando auto on` / `off` | install or remove the push hook (see 10) |
| `tando doctor` | check local tools, ssh access, agent version match, disk space, port clashes |

Server: the same verbs minus `deploy` and `auto`, as `tando-agent <verb> [app]`.

### Deploy sequence on the server (`tando-agent activate`)

1. Take a per-app lock (`flock`); a second deploy of the same app fails fast.
2. Refuse if free disk is under 1 GB or `incoming/release.json` is missing.
3. Copy `incoming` to `releases/<id>` (a real copy, not hard links: apps may rewrite files in place).
4. Run `pre_activate` (bakery: data backup). A failure aborts with nothing changed.
5. Switch `current` atomically (`ln -sfn` to a temp name, then `mv -T`).
6. Restart the unit; poll `health` for up to 60 seconds.
7. On failure: print the last 40 log lines, switch back, restart, delete the failed release, exit non-zero.
8. Run `post_activate`; for Next apps this requests every optimised image once, which also proves the
   native image library loads. A failure here is treated like step 7.
9. Prune to `keep` releases, never deleting the active one.
10. Append one line to `/var/log/tando/deploys.log`: time, app, id, commit, who, result, seconds.

## 9. Status and monitoring

No collector runs. Values are read when asked:

| Field | Source |
|---|---|
| Version, commit, built at | `current` symlink → `release.json` |
| State, uptime | `systemctl show -p ActiveState,ActiveEnterTimestamp` |
| Restarts since boot | `NRestarts` |
| Memory now / peak / cap | `MemoryCurrent`, `MemoryPeak`, `MemoryMax` |
| CPU % | two reads of `CPUUsageNSec` one second apart |
| Health | one request to the configured health path |
| Log size | bytes the unit wrote to the journal in the last 7 days, plus journal total against its cap |
| Disk | size of `releases/`, `/var/lib/<app>/` |
| Last deploy | last line for the app in `deploys.log` |

`tando ls` sketch:

```
HOST vm1   up 12d   load 0.21   mem 742M / 1962M   swap 21M   disk 13%   caps 1250M / 1962M
APP       VERSION                    STATE    UPTIME   CPU   MEM / CAP     RST  LOGS 7d  HEALTH
bakery    20261113-165416-1ba87ba    active   2h 10m   0.4%  206M / 400M   0    3.1M     200
magazine  20261113-155012-9c2e77f    active   3h 02m   1.2%  410M / 850M   0    11M      200
```

`caps` is the sum of every app's `memory_max` against physical RAM. `provision` and `doctor` warn
when it exceeds RAM, since that is the condition under which one app can push another into swap.

Optional, later (phase 3): a systemd timer that appends one line per app every 5 minutes to a
7-day ring file, enabling `tando status --history`, and a notification (ntfy or Telegram) when a
health check fails twice in a row. Off by default; it is the only part that would run unattended.

## 10. Manual and automatic deploy

- Manual (default): `tando deploy` from the laptop.
- `auto = push`: `tando auto on` installs a git `pre-push` hook. Pushing the configured branch runs
  tests (if a `test` command is set) and then `tando deploy`; a failed deploy does not block the push,
  it prints the failure. This needs no service anywhere.
- CI: the same `tando deploy` runs in GitHub Actions on an x86_64 runner, given a deploy key as a
  secret. It is a 15-line workflow calling the same script, so it can be added per repo at any time.
- The server never polls a repository and never builds.

## 11. Security

- A dedicated `deploy` user on the VM replaces personal logins for deploys. Its sudo rights are one
  line: `deploy ALL=(root) NOPASSWD: /usr/local/bin/tando-agent`. It owns only `/opt/*/incoming`.
- The agent validates every argument: app names against `[a-z0-9-]+` and the registry, release ids
  against the directory listing. No argument is ever passed to a shell unquoted or evaluated.
- `pre_activate` and `post_activate` are taken from the server-side registry copy, which only
  `provision` (run by an admin) may change. A deploy cannot introduce a new root command.
- Each app runs as its own unprivileged user under the hardening already used for magazine
  (`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, explicit `ReadWritePaths`).
- Secrets stay in `/etc/<app>.env`. `tando` never reads, prints or transfers them; `status` and
  `logs` never show the environment.
- A CI deploy key, if used, is a separate key for the `deploy` user, restricted with
  `command="sudo tando-agent ssh-entry"` so it can deploy but not open a shell.

## 12. Known limits

- Restart gap of 1 to 2 seconds per deploy. Removing it needs two ports per app and a Caddy upstream
  switch; deferred until an app needs it.
- One host per app. The config allows several hosts later, but there is no fleet view across hosts.
- CPU and memory are point-in-time unless the optional history timer is enabled.
- Shell parsing of `tando.conf` supports flat keys only. That is deliberate.

## 13. Rollout

| Phase | Scope | Done when |
|---|---|---|
| 1 | Agent: `activate`, `rollback`, `releases`, `status`, `ls`, `logs`, `restart/stop/start`. CLI: `deploy`, passthroughs. `next-standalone` recipe. bakery migrated | bakery deploys and rolls back through `tando`; `tando ls` shows it with correct numbers |
| 2 | `provision`, `doctor`, `deploy` user and sudoers, magazine adopted (with its owner), `auto`, deploy log | Both apps in `tando ls`; old per-app scripts deleted |
| 3 | `top`, optional history timer and health notifications, GitHub Actions example, `static` recipe | On request |

Tests: the agent runs against a throwaway directory tree with `systemctl` and `curl` stubbed, covering
a good deploy, a failed health check with rollback, a failed `pre_activate`, a concurrent deploy, and
pruning. The CLI's stage guard is tested with planted `.env`, `data` and wrong-platform files.

## 14. Decisions needed

1. Name: `tando`, or something else?
2. Shell (recommended) or Go?
3. Where the tool lives: its own repo (recommended, since several app repos depend on it) or inside
   `ai-playground`?
4. Is a dedicated `deploy` user acceptable, or keep deploying as the current admin user?
5. magazine is managed in another session. Adopt it in phase 2, or leave it on its own script?
6. Auto deploy: is the `pre-push` hook enough, or is GitHub Actions wanted from the start?
