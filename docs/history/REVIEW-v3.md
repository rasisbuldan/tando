# Deep adversarial review of SPEC.md draft 3

13 Nov 2026. Three independent reviewers read the spec with different briefs: security, reliability and
operations, feasibility and scope. None touched a server. Items resting on recalled tool behaviour are
marked "to confirm". 63 findings in total; the ones that change the design are below, grouped by theme.

## Verdict

All three say: do not build draft 3 as written.

- **Security:** the role split is the right shape, but the boundary between apps is enforced by one
  script's argument handling, not by the operating system. Goal 6 (a stolen key for app A cannot reach
  app B) does not hold.
- **Reliability:** the deploy core that works today is being replaced by mechanisms that are mostly
  unverified, and six are wrong as written. The first tando deploy of bakery would serve a site with no
  CSS, JS or photos and mark it healthy.
- **Feasibility:** real size is 6,000 to 7,500 lines of shell (8,500 to 11,000 of Go) plus about 2,000
  of tests, to save roughly 150 MB against an existing tool. A cut-down tool of about 1,600 lines meets
  both stated goals.

## Critical findings

| # | Area | Finding | Fix |
|---|---|---|---|
| S1 | Security | Root inspects, then copies, an upload the uploader can still change through a held open session; a file swapped for a symlink after inspection is copied into the release with root's read access (other apps' secrets, TLS keys) | Copy first using no-follow opens, inspect the root-owned copy; end the key's sessions before the rename |
| S2 | Security | `cron.x = ... \| exec +/path` rendered into a systemd `ExecStart=` runs as full root (the `+` prefix ignores the sandbox) | Fixed root-owned job runner as `ExecStart`; reject special first characters; `apply` shows a diff and asks for confirmation |
| S3 | Security | App name is used raw as system user, unit and directory names: `app = caddy` takes over Caddy's user and TLS keys, `app = ssh` overrides the ssh unit | Prefix everything `tando-`; refuse names tando did not create; allocate ports server-side only |
| R1 | Reliability | Releases are root:app 750/640, so Caddy cannot read static files it serves from disk today; health checks hit Node directly and pass. No config key can express bakery's current Caddy block (precompressed assets, redirect, headers) | Decide who serves static files; health check through Caddy for a static asset; `caddy = external` for adopted apps |
| R2 | Reliability | A `writable` bind mount replaces the directory instead of overlaying it; magazine's regenerated-page directory would hide its compiled pages and every route returns 500 | Per-release writable copies seeded from the release; share only content-addressed caches |
| R3 | Reliability | The lock is a 15-minute timer taken before the build: a rollback during someone's build is refused for minutes; expiry mid-activation lets two activations fight | Lock is an `flock` held only by the activation process; `begin` hands out a token without locking |
| R4 | Reliability | `systemd-run --wait --pipe` with a fixed unit name: a failed activation blocks all later deploys, and a dropped ssh kills the activation on its next write (to confirm) | Unique unit name, `--collect`, output to the journal, client re-attaches |
| F1 | Scope | Two apps, one admin, 1 to 2 VMs; the spec describes a multi-tenant platform | Cut to the small tool below |

## High findings, by theme

**The boundary between apps**
- One shared `deploy` user: any bug in the gate or rsync gives every app (S5). Fix: one login user per
  app, app derived from the caller's uid, never from an argument.
- Nothing stops app A binding app B's port during B's restart and receiving its traffic, cookies and
  cron secret (S4). Fix: `SocketBindAllow` for the app's own port only.
- The sandbox still shows `/etc`, `/var`, `/run`: other apps' runtime config, history, possibly
  backups, the Postgres and D-Bus sockets (S8). Fix: allow-listed filesystem view per unit.
- The loopback firewall rule misses `::1` and other local addresses, covers only tando-rendered ports,
  may wipe ufw's rules at boot if loaded the obvious way, and blocks tando's own health checks and cron
  jobs (S9, R15). Fix: default-deny by source uid, loaded by its own unit.
- Root backup jobs read app-owned files; planted symlinks or journals redirect root's writes (S6).
  Fix: back up as the app user, root moves the result.
- The env deny-list protects the wrong thing; the danger is any root process loading that file (S7).

**Upload**
- `--copy-dest` at the current release is outside the restricted directory and unreadable by the
  deploy user, so every upload is the full release; symlink munging defeats the "resolves inside the
  tree" rule; rrsync's per-user lock blocks two apps uploading at once; Apple's rsync against rrsync is
  untested (S10, R6, F7). Fix: keep one persistent deploy-owned upload directory per app, as today.

**State machine**
- Reboot mid-deploy leaves an unverified release serving until someone runs a command; state file has
  no write discipline; first deploy has nothing to roll back to and crash-loops (R5).
- `rollback` twice rolls forward into the release just abandoned (R13).
- `apply` is not transactional: a bad unit change fails the next deploy, which rolls back code, which
  fails again under the same unit (R7).
- `env set` is unlocked, restarts once per variable, and systemd's parser silently corrupts values with
  quotes, backslashes or trailing spaces (R11, R12).

**Migration**
- `adopt` changes ports, memory settings, Node path, env location, cache location, file ownership and
  the Caddy block; several cause downtime. magazine's timers would fire twice or not at all, and its
  cron secret would not match (R8).
- bakery stores JSON, so `database = sqlite` (the default) would report "backup ok" on an empty
  database while the order file gets no nightly backup (R9).

**Features that do not survive**
- `instances = N` loses orders with bakery's JSON store, serves two builds at once during a roll, and
  needs a unit rename (R10). Cut.
- Request holding does not protect requests in flight, and a bad release is still about 70 s of errors
  (R17). Better: start the new release on a spare port and health-check it before switching.
- "Database in one command" has no migration step, and SQLite drivers built on the Mac fail the
  architecture guard (F6).

**Scope, language, claims**
- Estimates in section 16 are low by 30 to 55%; tests are not budgeted; about 40 scenarios need a real
  x86-64 VM (F2).
- Go server plus shell CLI is the worst of the three options: two toolchains, duplicated parsing, and
  the CLI's own rewrite scheduled by phase 3. Use one language (F3).
- The gate, agent and admin split defends principals that do not exist until a CI key or a second
  owner is real. An admin-only first version keeps today's trust model and removes every root parser of
  hostile input (F4).
- "Three commands to a live link" is 5 to 8 steps per project and about 12 the first time (F5).
- With draft 3's feature list, an existing tool wins unless 150 MB is truly unaffordable; tando is
  justified only as the small tool (F14). Prototypes without disk state could simply use a hosted free
  tier (F15).
- WHY.md has 18 lines that are overstated or contradicted by draft 3 (F9), for example "adopting
  renames one directory" and "small enough to read".

## What must be proven on a throwaway VM before any code

1. The hardened unit running Next standalone with image optimisation and one regenerated page.
2. Caddy reading static files under the chosen ownership, reproducing today's Caddyfile.
3. Apple's rsync to the restricted server side, with real deltas.
4. Detached activation: kill ssh at each step, fail one and run another, reboot mid-deploy.
5. Env file round trip through systemd 259 with awkward values.
6. Wildcard-domain certificate issuance timing.
7. A timing breakdown of today's 91 s deploy.

## Recommended plan (feasibility reviewer; the other two agree on the cuts)

Build only the small tool: one language (shell), admin-only, ceiling 2,000 lines.

- In: `host setup`; `up` (init, apply, deploy in one, subdomain sites only); `deploy` with detached
  activation, state file, atomic switch, verified/bad status per release, automatic rollback;
  `rollback`, `releases`, `logs`, `env set/list`; `status` and `ls` as tables with a simple `--watch`;
  history with total seconds.
- Out for now: per-app keys and the gate, GitHub Actions, pre-push hook, instances, side-by-side
  runtimes, Postgres and the database feature, the cron config syntax, per-app firewall rules, boxed UI
  with column dropping, `doctor`, extra recipes, the watch timer.
- bakery keeps its hand-written Caddy block, its unit and its backup script when adopted.
- Tripwire: when a CI key or a second owner is real, or the tool passes 2,000 lines, stop and choose
  between one Go binary for everything and Podman with CI-built images. Do not grow the shell.

## Conflicts with what the owner approved

The owner approved database, zero config, HTTPS link, env vars, scheduled jobs, logs, rollback and
health checks. The reviewers would keep zero config, HTTPS link, env vars, logs, rollback and health
checks in the first version, and defer database and scheduled jobs. They would also drop the boxed UI,
Actions and the dedicated deploy user for now, all of which the owner asked for. These are the owner's
calls.
