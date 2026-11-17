# tando: lightweight release management for small VMs

Status: draft 2, for review. Nothing here is built except where marked "exists today".
`tando` is a working name. Draft 1 is kept as `SPEC-v1.md`.

Changes from draft 1: boxed terminal UI, dedicated deploy user (decided), shell (decided), own repo
(decided), both pre-push and GitHub Actions, per-phase deploy timing and history, host list, a stricter
monitoring budget, a container section, and a survey of existing projects.

## 0. Should this exist? Survey of existing projects

Checked November 2026. Star counts and versions are as shown on each project's page that day.

| Project | Model | Fit |
|---|---|---|
| Kamal 2 | Docker images, registry, own proxy | Mature. Needs Docker on the VM (daemon holds roughly 140 MB idle) and a registry. Guides give 1 GB as the floor, 2 GB recommended, for one app |
| Haloy, Sidekick, Uncloud | Docker, CLI-first | Same Docker cost. Sidekick builds locally. All assume a container per app |
| Coolify, Dokploy, Dokku, CapRover | Docker, build on server or panel | Build on the VM, the thing being removed |
| piku | git push, no Docker | Builds on the server |
| fujin | systemd + Caddy, no Docker | Closest in spirit ("Kamal without Docker"). Python packages and single binaries only, no Node directory releases. README calls it work in progress; 14 stars |
| tow-cli | Local build, scp, symlink releases | Has Node handler, status, logs, history, multi-host. Runs apps through start/stop scripts, not systemd. v0.4, 1 star, no tagged release |
| Capistrano, Deployer, Mina | Symlink releases | Deploy only. No status, no monitoring. Mina builds on the server |
| systemctl-tui | Terminal UI for systemd | Manages a remote host over ssh with nothing installed there. One host at a time, knows nothing about releases |
| lazyjournal, btop | Log and resource viewers | Useful next to this tool, not a replacement |

Conclusions:

1. The mature tools all require Docker. On a 2 GB VM shared by several apps that is a real cost, and
   it would replace a setup that already works.
2. The tools without Docker are either the wrong shape (fujin: no Node) or unproven (tow-cli). Depending
   on a 1-star project is a larger risk than owning a few hundred lines of shell that already exist in
   two working scripts.
3. Nobody combines local build, systemd, release history and a multi-app view. That combination is the
   only part worth writing.
4. What is not rebuilt: supervision, limits, logs and metrics (systemd, cgroups, journald), TLS and
   routing (Caddy), host history (sysstat, already running on the VM), transfer (rsync), the UI drawing
   code (lifted from the author's earlier sync script).

If containers per app become a hard requirement (see 11), this conclusion flips: use Kamal and do not
build tando.

## 1. Problem

One 1 vCPU / 2 GB VM hosts two apps and will host more. Each has a hand-written deploy script doing
nearly the same thing. There is no single place to see what runs where, at which version, and at what
cost. Building on the VM is ruled out: one `next build` took about 850 MB and the whole CPU for minutes.

## 2. Goals

1. One command deploys any app: build off the VM, upload, activate, health-check, roll back on failure.
2. One screen lists hosts, and per host every service: version, uptime, CPU, memory, restarts, log size.
3. Start, stop, restart, roll back, tail logs: same words on laptop and server.
4. Deploy manually, on `git push` (hook), or from GitHub Actions. All three run the same code.
5. Every deploy is timed per phase and recorded; history is browsable.
6. Zero resident processes on the server. Idle cost of tando on the VM is 0 MB and 0 CPU.

## 3. Non-goals

- Building on the server. A container daemon on the server. A web dashboard.
- Zero-downtime switching (restart gap of 1 to 2 s is accepted; see 14).
- DNS, TLS, databases inside apps, alert routing beyond one optional webhook.

## 4. Shape

```
laptop or CI runner                        VM
┌───────────────────────────┐  ssh     ┌──────────────────────────────────────┐
│ tando        bash 3.2+    │ ───────► │ tando-agent   POSIX sh, runs on call │
│  ui.sh       boxed screens│  rsync   │  activate / rollback / status / ...  │
│  recipes/    build steps  │ ───────► │  reads systemd, cgroup, sysstat      │
│  tando.conf  per app repo │          │  prints key=value, never draws UI    │
└───────────────────────────┘          └──────────────────────────────────────┘
```

- All drawing happens on the laptop. The agent prints plain `key=value` records; a status call costs
  the server a few file reads.
- Languages: the CLI is bash and must run on macOS's stock bash 3.2 (no associative arrays, no
  `mapfile`), as the author's earlier sync script already does. The agent is POSIX `sh` plus `awk`.
- Repository: `~/github/tando`, its own git repo. Layout:

```
bin/tando            CLI entry
lib/ui.sh            frame, rows, table, bar, sparkline (from the author's earlier sync script)
lib/ssh.sh           one multiplexed connection per host (ControlMaster)
lib/build.sh         phases, timing, history records
recipes/next-standalone.sh, static.sh, custom.sh
agent/tando-agent    the only file installed on servers
agent/templates/     service unit, sudoers line, Caddy snippet
ci/deploy.yml        GitHub Actions workflow to copy into an app repo
hooks/pre-push
test/                bats-free shell tests with stubbed systemctl, curl, ssh
```

- Size budget: agent under 400 lines, CLI under 1,500 including about 300 of UI code. If the CLI
  passes 2,500 lines, stop and reconsider Go rather than keep growing shell.

## 5. Server conventions

Per app `<app>` (`[a-z0-9-]+`):

| Path | Purpose |
|---|---|
| `/opt/<app>/incoming/` | rsync target, owned by `deploy`. Persistent, so only changed files travel |
| `/opt/<app>/releases/<id>/` | Immutable copies. Newest `keep` (default 3) kept |
| `/opt/<app>/current` | Symlink to the active release (or a subdirectory of it) |
| `/var/lib/<app>/` | App data. Never inside a release |
| `/etc/<app>.env` | Secrets, mode 600. Never in a repo or a release |
| `/etc/tando/apps/<app>.conf` | Server copy of the app config. The registry |
| `/var/lib/tando/history.tsv` | One line per deploy or rollback (see 9) |
| `/etc/systemd/system/<app>.service` | Rendered at `provision`, or supplied by the repo |
| `/etc/caddy/sites/<app>.caddy` | Site snippet imported by the main Caddyfile |

Exists today: both apps already use `releases/` + `current` + `/etc/<app>.env` + a unit named after
the app. bakery already uploads to `incoming/`; magazine calls it `staging`.

Release id: `<UTC yyyymmdd-hhmmss>-<git short sha>`, plus `-dirty` for uncommitted changes. Each
release carries `release.json` (app, id, commit, dirty, branch, built_at, built_on, tool versions).

## 6. Configuration

`tando.conf` at the app repo root, flat `key = value`, parsed and never executed:

```ini
app        = bakery
host       = vm1
type       = next-standalone      # next-standalone | static | custom
port       = 3100
health     = /bakery/order/new
keep       = 3
user       = bakery
memory_max = 400M
# optional
subdir = ; build = ; test = npm test
pre_activate  = /usr/local/bin/bakery-backup
post_activate = warm-images
auto   = off                      # off | push
branch = main
```

`~/.config/tando/hosts` on the laptop, never committed:

```ini
vm1 = deploy@<address>   key=~/.ssh/<key>   label="Jakarta 1 vCPU / 2 GB"
```

## 7. Commands

| Command | Does |
|---|---|
| `tando` | Dashboard: hosts on the left, services of the selected host, live (see 8) |
| `tando hosts` | Table of hosts: reachable, uptime, load, memory, disk, number of apps |
| `tando ls [host]` | Table of services on a host, tando apps first, then other notable units (Caddy) |
| `tando status [app]` | Detail box for one app: version, limits, graphs, last deploys |
| `tando deploy` | Build and ship with a live phase display (see 9). `--no-build` re-ships the stage |
| `tando history [app]` | Past deploys: when, who, commit, result, total and per-phase seconds |
| `tando releases` | Releases present on the server and which is active |
| `tando rollback [id]` | Switch to previous or named release, restart, health-check |
| `tando logs [-f] [-n N] [--since T]` | journald passthrough |
| `tando restart` / `stop` / `start` | systemctl passthrough; restart and start end with a health check |
| `tando provision` | First-time setup of one app on a host. Idempotent |
| `tando host add` / `host setup` | Register a host; install agent, `deploy` user, sudoers line |
| `tando auto on` / `off` | Install or remove the pre-push hook |
| `tando doctor` | Local tools, ssh, agent version match, disk, port clashes, memory caps over RAM |

Every command also works non-interactively: when stdout is not a terminal, or with `--plain`, output is
plain aligned text with no frame and no colour, so it can be piped and used in CI. `--json` is not
planned.

On the server, `tando-agent <verb>` offers the same verbs except `deploy`, `auto` and `host`, with
plain-text output.

## 8. Terminal UI

Drawing code comes from the author's earlier sync script: one rounded frame redrawn in place without flicker, title
and hints in the borders, colour-aware width maths, ASCII fallback without UTF-8, progress bar and
sparkline. New pieces: a column table helper and a two-pane layout. Single-width glyphs only.

Dashboard (`tando`):

```
╭─ tando ──────────────────────────────────────────────────── vm1 · up 12d · load 0.21 ─╮
│ HOSTS            SERVICES on vm1                                                      │
│ ❯ vm1  ● 2 apps  APP       VERSION          STATE   UP     CPU   MEM / CAP     HEALTH │
│   vm2  ○ down    bakery    1113-1654 1ba87  ● run   2h10m  0.4%  206M / 400M   200    │
│                  magazine  1113-1550 9c2e7  ● run   3h02m  1.2%  410M / 850M   200    │
│                  caddy     system           ● run   12d    0.1%   38M / -      -      │
│                                                                                       │
│ mem  ━━━━━━━━━━━━──────────────  742M / 1962M     caps 1250M / 1962M    swap 21M      │
│ cpu  ▁▁▂▁▁▃▂▁▁▁▅▂▁▁▁▁▂▁▁▁  last 24h (sysstat)      disk ━━──────────── 13%            │
╰─ ↑/↓ select · enter details · d deploy · l logs · r restart · q quit ──── refreshed 2s ─╯
```

App detail (`tando status bakery`):

```
╭─ bakery on vm1 ───────────────────────────────────────────────────── ● running 2h 10m ─╮
│ version   20261113-165416-1ba87ba   built on laptop, 13 Nov 16:54                       │
│ memory    206M now · 234M peak · cap 400M   ━━━━━━━━━━━━━━──────────────                │
│ cpu       0.4% now · 0.6% average since start                                           │
│ restarts  0     health 200 in 41 ms     logs 3.1M in 7 days     data 12M   releases 183M│
│                                                                                         │
│ RECENT DEPLOYS                         total  build  pack  send  activate  warm         │
│ 13 Nov 16:54  1ba87ba  ok                91s     8s   21s    6s       14s   42s         │
│ 11 Nov 21:40  (dirty)  ok               312s   251s     -     -         -     -         │
│ deploy time  ▇▇▆▇▂  last 5                                                              │
╰─ d deploy · b rollback · l logs · r restart · s stop · esc back ────────────────────────╯
```

The phase numbers in the sketch are illustrative. Only the 91 s total and 8 s build are measured.

Destructive keys (`s` stop, `b` rollback, `r` restart) ask for confirmation in the footer line.

## 9. Deploy pipeline, progress and history

Phases, each timed on the side where it runs:

| # | Phase | Where | Notes |
|---|---|---|---|
| 1 | check | laptop | config valid, host reachable, agent version, disk, lock free |
| 2 | test | laptop | only if `test` is set |
| 3 | build | laptop | recipe; output streamed into a log pane, last lines visible |
| 4 | pack | laptop | stage, platform binaries, precompression, guard |
| 5 | send | laptop → VM | rsync with byte progress |
| 6 | activate | VM | copy, `pre_activate`, symlink switch, restart, health |
| 7 | warm | VM | `post_activate` |
| 8 | prune | VM | old releases |

Live display: one row per phase with a spinner, then a tick and its seconds; a bar for `send`; the tail
of the build log underneath. On failure the frame turns red and shows the failing phase's last 20 lines.
In CI the same phases print as plain lines (`[3/8] build ... 8s`).

Guard (end of `pack`): the stage must not contain `.env*`, a `data` directory, or binaries for another
platform. Exists today in bakery's script.

Activate sequence on the server: per-app `flock`; refuse under 1 GB free disk; real copy of `incoming`
(not hard links); `pre_activate`; atomic symlink switch; restart; poll health up to 60 s; on failure
print logs, switch back, restart, delete the failed release; `post_activate`; prune.

History: the CLI sends its laptop-side timings with the activate call, and the agent appends one line to
`/var/lib/tando/history.tsv`:

```
time  app  id  commit  dirty  who  source(laptop|hook|actions)  result  total_s  check test build pack send activate warm prune  stage_bytes  sent_bytes
```

The server holds the history because deploys can come from several laptops and from CI. The file is
trimmed to the last 500 lines per app. `tando history` reads it; `status` shows the last five.

### Performance work

Measured baseline for bakery (13 Nov): build 8 s of a 91 s deploy. The build is not the slow part, so
tuning starts by measuring phases, then fixes the largest one. Candidates, in expected order of gain:

1. `warm` requests every optimised image on a single CPU (296 requests). Carry the image cache over
   from the previous release when the source image is unchanged, and warm only new ones.
2. `pack` recompresses every asset with `brotli -q 11` and `zstd -19` each time. Hashed filenames mean
   unchanged content: keep a cache keyed by filename and compress only new files, in parallel.
3. `activate` copies the whole release (61 MB). Fine today; revisit only if it shows up.
4. `send` already transfers only changed files.
5. `build`: keep `.next/cache` between builds (already the case locally; in Actions, cache it keyed on
   the lockfile and source hash), skip `npm ci` when the lockfile hash is unchanged.

Target after tuning: under 30 s for a typical bakery deploy from the laptop. This is a goal, not a
measurement.

## 10. Monitoring budget

Rule: tando adds no resident process and no periodic job on the server by default.

| Data | Source | Cost on server |
|---|---|---|
| State, uptime, restarts | `systemctl show` | one call per refresh |
| Memory now, peak, cap | cgroup `memory.current`, `memory.peak`, `memory.max` | file reads |
| CPU now | two reads of cgroup `cpu.stat` across the refresh interval | file reads |
| CPU average since start | `cpu.stat` usage ÷ uptime | arithmetic |
| Memory or CPU pressure | `/proc/pressure/*` (kernel keeps 10 s, 60 s, 300 s averages) | file reads |
| Host CPU, memory, load over 24 h | `sar` files written by sysstat, exists today | none added |
| Log volume | `journalctl -u <app> --since -7d -o cat \| wc -c`, cached 1 h in `/run/tando` | one scan per hour at most, only when asked |
| Health | one local HTTP request | one request |

- One refresh of the dashboard is one ssh round-trip over a kept-alive connection running one agent
  call for all apps. Default refresh 2 s while the dashboard is open, nothing when it is closed.
- Per-app history graphs are the one thing the above cannot give. Option, off by default:
  `tando host setup --history` installs a systemd timer that runs the agent once a minute to append
  about 40 bytes per app to a ring file (7 days, under 1 MB per app). Cost is one short `sh` process per
  minute. Without it, per-app sparklines show only what was sampled while the dashboard was open.
- Optional and off by default: on two consecutive failed health checks from that same timer, POST to
  one webhook URL (ntfy or Telegram).

## 11. Containers

Current state of the VM: no Docker, no Podman. Each app runs as its own user under systemd with a
memory cap and a read-only view of the system.

A container is three kernel features: namespaces, cgroups and a private filesystem view. systemd
applies the same features directly to a service, with no runtime in between. So the default answer is:

- `isolation = systemd` (default). The unit template applies: own user, `MemoryMax`, `CPUWeight`,
  `TasksMax`, `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`,
  `ProtectKernelTunables`, `RestrictAddressFamilies`, explicit `ReadWritePaths`, and optionally
  `IPAddressDeny` for apps that need no outbound network. Overhead: none.
- `isolation = podman` (optional, phase 4). For software that only ships as an image (a database, a
  third-party service). tando writes a Quadlet `.container` file, which makes the container an
  ordinary systemd unit, so `ls`, `status`, `logs`, `restart` and the memory figures work unchanged.
  Podman has no daemon, so idle cost is the container's own processes. Images are pulled by digest or
  loaded from the laptop with `podman save | ssh podman load`; never built on the VM.
- Docker is not supported: its daemon would be the single largest idle process on the VM.

What systemd isolation does not give: a private root filesystem with its own libraries. Apps share the
host's Node. That is acceptable while all apps run on the same Node major; it is the main reason to
ever move one app to `podman`.

This section is the least certain part of the spec; see decision 1.

## 12. Auto deploy

- Pre-push hook: `tando auto on` installs `hooks/pre-push`. Pushing `branch` runs `test`, then
  `tando deploy`. A failed deploy prints the failure and does not block the push. Bypass with
  `TANDO_SKIP=1 git push`.
- GitHub Actions: `ci/deploy.yml` is copied into the app repo. It checks out the app and tando, restores
  the dependency and build caches, and runs `tando deploy --plain`. The runner is x86_64 Linux, so no
  platform binary swap is needed. Secrets: `TANDO_SSH_KEY`, `TANDO_HOST`, `TANDO_KNOWN_HOSTS`.
- An app uses one or the other. If both are active, the hook detects the workflow file and steps aside,
  so a push never deploys twice.
- Requirement not yet met: bakery has no GitHub remote. Actions cannot be used for it until it has one.

## 13. Security

- `deploy` user (decided). Created by `tando host setup`. Owns only `/opt/*/incoming`. One sudoers line:
  `deploy ALL=(root) NOPASSWD: /usr/local/bin/tando-agent`. No shell access is needed beyond that.
- Laptop key and CI key are separate. The CI key is restricted in `authorized_keys` with
  `restrict,command="/usr/local/bin/tando-ssh-entry"`, which permits only rsync into `incoming/` and
  `sudo tando-agent` with validated arguments.
- The agent validates every argument against `[a-z0-9-]+`, the registry and the release listing.
  Nothing from the client is evaluated.
- `pre_activate` and `post_activate` come from the server registry, written only by `provision`.
  A deploy cannot introduce a new root command.
- Host keys are pinned (`StrictHostKeyChecking=yes` with a known_hosts entry recorded at `host add`).
- Secrets stay in `/etc/<app>.env`. tando never reads, prints or transfers them.

## 14. Known limits

- Restart gap of 1 to 2 s per deploy.
- Per-app history graphs need the optional timer.
- The dashboard needs a terminal at least 80 columns wide; below that it falls back to plain tables.
- Flat config keys only.
- bash 3.2 compatibility rules out some conveniences and keeps the UI code verbose.

## 15. Rollout

| Phase | Scope | Done when |
|---|---|---|
| 1 | Agent core (`activate`, `rollback`, `releases`, `status`, `ls`, `logs`, `restart/stop/start`, history file). CLI `deploy` with phase timing and plain output, `ls`, `status`, `history`, `rollback`. `next-standalone` recipe. `host setup` with `deploy` user. bakery migrated | bakery deploys and rolls back through tando as `deploy`; history shows per-phase seconds |
| 2 | Boxed UI: dashboard, detail, live deploy screen, `hosts`. Performance items 1 and 2 | Dashboard shows both apps live; bakery deploy under 30 s |
| 3 | `provision`, `doctor`, pre-push hook, Actions workflow, magazine adopted with its owner | Old per-app scripts deleted; one app deploying from Actions |
| 4 | On request: history timer and webhook, `static` recipe, `isolation = podman` | - |

Tests: agent against a throwaway tree with `systemctl`, `curl` and `flock` stubbed (good deploy, failed
health with rollback, failed `pre_activate`, concurrent deploy, pruning, hostile arguments). CLI: config
parser, stage guard with planted files, table and frame rendering compared to golden text at 80 and 120
columns, all under bash 3.2.

## 16. Decisions

Decided: shell; own repo at `~/github/tando`; dedicated `deploy` user; both pre-push and Actions.

Open:

1. Containers: is systemd isolation as the default, with Podman as a later option, what was meant by
   "integrate with the server containerization"? If a container per app is required, stop here and
   adopt Kamal instead.
2. Name: keep `tando`?
3. Per-app history timer: leave off by default (recommended), or on?
4. magazine: adopt in phase 3, or leave on its own script?
