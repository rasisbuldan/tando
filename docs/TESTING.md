# Testing tando

| Command | What it runs | Needs |
|---|---|---|
| `test/all.sh` (`make test`) | every suite below, in parallel where safe, with a boxed summary | Docker |
| `test/lint.sh` (`make lint`) | shellcheck + tando checks on every shell file, the no-shell rule on `srv/**/*.go`, against a baseline | shellcheck or Docker, perl |
| `test/go.sh` | the Go server programs (srv/): gofmt, go vet, go test, race detector, no-shell lint (srvlint), layering, static builds for amd64 and arm64 | Go |
| `test/install-test.sh` | install from the checkout and from a release archive into temp prefixes: every `$TANDO_HOME` path the code reads is installed, every command's `--help` and `ci github --help` work, uninstall | perl |
| `test/addon-test.sh` | `tando addon` and `tando dashboard`: scripts/release-dashboard.sh builds the archive for this platform (`--skip-web`), twice the same bytes, modes and owners; install from a local archive in a temp HOME, status, the binary runs, quarantine removed only from verified files (a stub `xattr`), checksum mismatch, missing checksum, wrong `--sha256`, unsafe paths, wrong version and a foreign `tando-dash` refused with nothing installed, `file://` download, uninstall of a running tando-dash leaves nothing | Go, perl |
| `test/ui-test.sh` | lib/ui.sh at 5 widths, 2 locales, colour on/off; render speed; the `tando.conf` keys of the client parser and the server's configure against docs/CONFIG.md and `tando help conf`; `default_www` of client and server over one table of names; `tando doctor`'s collapsed program row on a stub agent; the platform-package swap and the native-code guard on fixture trees (`test/native-test.sh`: a stub `npm`, a local fake registry and a stub download host, no network); what `tando init` detects for every framework fixture in test/fixtures/apps (`test/detect-test.sh`: framework, recipe, build, start, output, message); the macOS menu bar app (`test/menubar-test.sh`: `ls --all --json` with alerts on a stub ssh, the app compiled with swiftc into a temp dir and its bundle, the badge and notification logic on canned JSON in test/fixtures/menubar (`test/menubar-model.swift`), the dashboard window logic (`test/menubar-dash-model.swift`: dash.lock, stale lock, launch decision tree, address policy, cache freshness), the shared `ls-all.json` cache, "Open dashboard" without the window (`--dash-url`) against a real tando-dash started in the temp HOME, the app's `--once` against the real CLI with a local web server, `menubar install --dry-run`, install, status and uninstall in a temp HOME without launchctl; SKIP lines without swiftc) | perl, node, openssl; swiftc (Command Line Tools) for the menu bar app |
| `test/e2e.sh`, `test/e2e-*.sh` | end-to-end against a throwaway Ubuntu+systemd container | Docker (OrbStack), some need npm |
| `test/portability.sh` (`make portability`) | macOS bash 3.2, Debian, Linux and BusyBox clients | Docker |

## Tiers

What to run when. [AGENTS.md](../AGENTS.md) has the short version and the rules.

| Tier | Command | When | What runs |
|---|---|---|---|
| check | `test/check.sh` | after every edit | on the changed files only: `bash -n` (3.2, and the server's bash for `server/`), lint, gofmt/vet/test of the changed Go packages, the secret scan, and that `test/suites.map` knows the change. No server. |
| quick | `test/all.sh --tier quick` | before saying a change works | the suites `test/select.sh` maps the changed files to (`test/suites.map`), plus `e2e-trial` as a smoke deploy. Go without the race detector; lint and Go may reuse cached results. A core file, or a file no rule knows, selects every suite. |
| full | `test/all.sh` | before a push to main and before a tag | every suite, nothing cached, the fault scenarios as six parallel shards (`e2e-faults-q1` to `q6`) and the fault matrix's quick cells (`e2e-matrix-quick`: node, container, static). The map is not read. |
| nightly | `test/all.sh --tier nightly` | by hand, when the machine is free for half an hour (not in CI) | full, with the fault scenarios as two chains (`e2e-faults-h1`, `h2`) whose split moves every day, so over a week every scenario runs right after every neighbour; the matrix's weekly cells of the other kinds of app (`e2e-matrix-weekly`). |
| weekly | `test/all.sh --tier weekly` | by hand, about once a week and before a release that touched deploys (not in CI) | full, with the fault scenarios as one chain (`e2e-faults`) and the 25 s soak on every deploy (`FAULT_SETUP_SOAK=25`): the suite as it was before it was made faster, with every scenario file (`--all`, 49 more than the shards run) and `e2e-matrix-weekly`. |

Why the fault scenarios differ by tier: they are independent by design, but a scenario that leaves
something behind is only found by the one that runs after it (the upload lease left by a refused
activation was found that way). Shards are fast and lose most neighbours; the chains keep them.
Anything a faster tier skips still runs in a slower one.

`test/select.sh` prints what a change selects (`--why`: which file selected what; `--base REF`;
`--files a b`). By default the change is everything since the upstream branch, plus uncommitted and
untracked files. `test/suites.map` holds the rules: every rule that matches a file adds its
suites, a file no rule matches selects everything, and a suite named there that does not exist is
an error. When a suite starts using another part of the tree, add the rule.

`test/all.sh --failed` reruns the suites that failed in the last run. `test/all.sh --slow [N]`
shows where the last run's time went: the suites by duration and the N longest waits before a
check or a section line (from `<suite>.times`, written beside each log).

## test/all.sh

```
test/all.sh                      every suite once (the full tier)
test/all.sh --tier quick         see Tiers; also nightly, weekly; --base REF, --files a b
test/all.sh --failed             the suites that failed in the last run
test/all.sh --slow 30            where the last run's time went
test/all.sh --only e2e,lint      some suites (names without .sh); --skip e2e-next
test/all.sh --repeat 3           three rounds; lists checks that did not pass every time
test/all.sh --list               the plan: how and where each suite will run
test/all.sh --keep               leave the test servers running
test/all.sh --report .tando/all/<run>   the summary and flaky checks of an earlier run
test/all.sh --portability        include test/portability.sh
test/all.sh --allow-skip         a suite whose checks were all SKIP does not fail (TANDO_ALLOW_SKIP=1)
```

Suites are found by name: `ui-test`, `lint`, `go`, `install-test`, `e2e`, `e2e-next`, then every
other `test/e2e-*.sh`.
**One server per suite.** Every server suite gets its own test server, never shared with another
suite (a server keeps the apps a suite left, which the next suite would trip over): container
`<prefix><n>` (prefix `tando-test-q` by default, `TANDO_ALL_PREFIX`), ssh port `<ssh base>+n` and http
port `<http base>+n` (2310 and 8310 by default, `TANDO_ALL_SSH_BASE`, `TANDO_ALL_HTTP_BASE`), where n
is the suite's place among all server suites, the same n with `--only`/`--skip`. A suite that uses a
second server (`TANDO_TEST_NAME2`, e2e-ease) gets `<name>b` on ports +50. At most
`TANDO_ALL_SLOTS` server suites run at once (default: the CPUs less two, at most 8, at least 2),
the longest first, by `test/durations.tsv` (the same order in every run; `--save-durations`
rewrites it from the last passing run, and a run warns about a suite that took over 1.5 times its
line there); a
suite's server is created when it starts and removed when it ends (unless `--keep`). A suite marked `# all.sh: own-server` creates its server
itself; all.sh only picks its name and ports. The plan is checked first: two suites that would share
a name or a port stop the run. Suites may reset (`TANDO_TEST_OWNED=1`) only the servers this run
created. One all.sh per user and prefix runs at a time (lock
`$TMPDIR/tando-all-<uid>-<prefix>.lock`): a second run is refused, because two runs would reset each
other's servers mid-suite.

**Skips.** The summary has a SKIPPED column. A suite whose checks in a round were all SKIP (none
passed or failed) fails that round, unless `--allow-skip` or `TANDO_ALLOW_SKIP=1`; a skip never
counts as a pass. `t_done` in test/lib.sh applies the same rule to a suite on its own. Logs: `.tando/all/<run>/<suite>.log`
(`.tando/all/latest` is the last run; `.tando/` is git-ignored).

How a suite runs depends on what it supports (`--list` shows it):

- **local** (ui-test, lint, go, install-test): no server. They start at once, beside the server
  suites. (They used to run first, alone: ui-test's frame-time check read 73-82 ms of wall clock
  next to busy test servers, against a limit of 50. It now measures CPU time, about 28 ms with the
  machine idle or at load 20.) `portability` uses a server, so it runs with the server suites.
- **param**: the suite reads `TANDO_TEST_NAME` / `TANDO_TEST_SSH_PORT` / `TANDO_TEST_HTTP_PORT`
  (or uses `test/lib.sh`). In parallel, each on its own server, with `TANDO_TEST_OWNED=1` and
  `T_WORK=test/.all-<suite>`.
- **fixed**: the suite still hard-codes `tando-testvm`, 2222 and 8080. all.sh runs a copy
  (`.tando/all-<suite>.sh`) with those three replaced by its server's values, so a server someone
  else is using is never reset; these run one after the other unless `--fast`. `--as-is` runs them
  unmodified on tando-testvm instead.
- **pinned**: the suite assigns `TANDO_TEST_NAME`/`TANDO_TEST_SSH_PORT` outright (no `:-` default).
  all.sh skips it: it cannot move it, and running it would reset a server it does not own.
- A suite whose work directory ignores `T_WORK` is flagged "WARNING fixed work dir": two runs of it
  at the same time (all.sh and a person, or two agents) delete each other's files mid-run.

The summary counts `PASS`/`FAIL` lines (ui-test and lint print their own totals) and exits non-zero
if any suite failed. With `--repeat N` every check is keyed by its id and text (numbers that change
between runs are masked) and reported as `flaky` (failed in some rounds) or `always fails`, with the
log of each failing round.

## Conventions for a suite

New suites and changes to existing ones should follow these, so that all.sh can run them side by
side and two people (or agents) never break each other's runs:

1. **Server from the environment, with defaults.** `TANDO_TEST_NAME` (default `tando-testvm`),
   `TANDO_TEST_SSH_PORT` (2222), `TANDO_TEST_HTTP_PORT` (8080). Never write 2222, 8080 or the
   container name anywhere else: links are `http://<app>.localhost:$TANDO_TEST_HTTP_PORT`,
   `host add ... --port "$TANDO_TEST_SSH_PORT"`, `host setup ... public_port=$TANDO_TEST_HTTP_PORT`,
   `docker restart "$TANDO_TEST_NAME"`. `test/server/up.sh`, `down.sh` and `ssh.sh` already read them.
2. **Own state.** Work directory `${T_WORK:-$ROOT/test/.<suite>-$TANDO_TEST_NAME}` and
   `TANDO_CONFIG_DIR=$E/cfg` inside it. Never a fixed `test/.<suite>` shared by every run.
3. **Never reset a server you did not start.** `up.sh --reset` only when you created the container,
   when `TANDO_TEST_OWNED=1` (all.sh sets it for the servers it creates), or on the default `tando-testvm` when a
   person runs the suite by hand. Otherwise reuse it (`up.sh` without `--reset`) and clean up your
   own apps instead.
4. **Output contract.** One line per check on stdout: `PASS <id> <text>` / `FAIL <id> <text>` /
   `SKIP <id> <text>`; the id is the first word and stable between runs (`3a`, `N2b`); put changing
   numbers after the text. Diagnostics go to stderr. Exit non-zero when anything failed.
5. **Nothing leaves the machine** unless the suite says so in its header (npm registry for
   `e2e-next`/`e2e-data`), so all.sh users can `--skip` it offline.
6. **Laptop-side code runs under /bin/bash 3.2:** suites start with `#!/bin/bash` and `set -u`;
   under `set -u`, bash 3.2 treats `"${arr[@]}"` of an empty array as unbound: use
   `${arr[@]+"${arr[@]}"}`.

## Suites added in round 6

| Suite | Server | What |
|---|---|---|
| `e2e-cli` | none (ssh/rsync are stubs; all.sh still gives it a server name) | `--help`/`--bogus`/extra arguments for every command of lib/help.txt, typos with the suggested command, the error messages a newcomer meets (E*), `domain add --wait` polling, global flags, `strip`, host setup under /bin/bash 3.2 |
| `e2e-bootstrap` | the bare image (`TANDO_TEST_BARE=1`), needs `TANDO_TEST_OWNED=1` | empty VM → host setup → up of a static site, hello and Next.js → domains (tls internal, `TANDO_TEST_RESOLVE` fake DNS) → setup again changes nothing → doctor green; prints the empty-VM-to-live-link time |
| `e2e-frameworks` | own | a bare `tando up` (no tando.conf) of framework fixtures from test/fixtures/apps: Express with pnpm (installed from pnpm-lock.yaml, corepack when pnpm is missing), NestJS (`nest build`, `node dist/main`), Next.js without standalone output refused before anything is installed, a Vite + Vue SPA (a deep link gets index.html: `spa = true`), SvelteKit with adapter-node, one package of a pnpm and of an npm workspace from a fresh clone (installed at the root, the `workspace:*` package and its own dependency in the release and used at run time). Needs npm, corepack and the network |
| `e2e-live` | param | the live views (docs/MONITORING.md, "Live views"): tandod's 5 s loop answers `live` and `ring` on its socket with 25 app units (one deployed app, 24 written by hand that only sleep), `tando-agent status-follow` pushes a status frame every 5 s, `tando status --follow` paints every 5 s over one ssh session (an ssh shim counts them), `ls --follow` shows an app that died within 12 s, and with tandod stopped `--follow` polls as `--watch 5`. The budget: tandod's CPU averaged over `TANDO_LIVE_BUDGET_S` (300 s) under 1% of a core with the minute ticks running, its anonymous memory under 20 MB, systemd's own CPU (init.scope) printed, and, with the minute ticks paused, no child reaped by tandod (its children's fault count unchanged). About 8 minutes |
| `e2e-workers` | own | workers (`worker.<name>` in tando.conf): one and two workers run the new release as the app's user with its env; a second deploy replaces them (no older process left, the old worker's 5 s graceful stop ends before the new one starts, the worker is its unit's main process); a worker that crashes at start fails the deploy and the old workers run again; rollback (a worker the older release lacks goes); stop, start; env set; status, `logs --worker`; memory and stop_timeout on the unit and in the slice; a removed worker's unit goes; a worker that keeps crashing is restarted and reported while the web process serves; names, settings and recipes refused (client and server); destroy leaves no unit, link or process. About 3 minutes |
| `e2e-upgrade` | own | the upgrade from 0.1.1 (`git archive v0.1.1` of this checkout): 0.1.1 sets up the host (postgres) and deploys six apps (two releases, a database, a job, a static site, a stopped app, a failed last deploy) and the matrix's app; this client refuses the 0.1.1 server before a change (protocol check); `host setup` with this tree: no request fails, no app restarts, the stopped app stays stopped, doctor, ls, status; then deploy, rollback to a 0.1.1 release, env set, stop/start, jobs, backup and restore with this client; a 0.1.1 activation stopped in its pre-flight across the setup and killed: the new agent's recovery passes the matrix's checker; the 0.1.1 client against the new server. About 4 minutes |
| `e2e-sec2` | own | the attacks of docs/SECURITY-REVIEW-2.md (test/sec2) plus N8/N9/N11/N13 checks, the third review (test/sec2/sec3.sh), and L/J (test/sec2/lease-jobs.sh): an upload found by its receiver, never by a command line; job units of apps alpha, alpha-job, alpha-job-tick kept apart, renamed from the old form by host setup |
| `e2e-faults` | own, `--memory 2g --cpus 1` | the fault scenarios of docs/FAULT-REVIEW.md (test/faults); the 27 that failed there and the baseline by default, plus m1-m6, a21 (the activation killed while the release command runs; a22, the restart, with `--all`) and n1-n5 (jobs follow the verified release, env revert, same-user upload lease, concurrent domain add, idempotent re-runs and resumed interrupted up/destroy), `--all` for all (about two hours) |
| `e2e-offsite` | param + a second server (`TANDO_TEST_NAME2`) + an S3 container | offsite backups (docs/BACKUP.md): set/test/status, wrong and revoked credentials, a key that may not delete and a bucket lock (the test's rows, retention left to the bucket), every backup uploaded and encrypted (no plaintext in the bucket), offsite-only restore and pull, a failed upload retried and the alert state file, retention, a 300 MB backup in parts and a push killed mid-way, and the disaster recovery of a PostgreSQL app onto the second server. The S3 target is `srv/offsite/testdata/fakes3` (our own, std lib, it checks every SigV4 signature) in an `ubuntu:24.04` container with TLS, because MinIO's image could not be pulled where it was written; it needs npm (examples/notes) and apt for PostgreSQL. `test/offsite-r2-check.sh` runs the provider subset against a real R2 bucket |
| `e2e-jobs` | param | scheduled jobs (docs/COMMANDS.md, jobs): J1 schedules refused before anything is built, J2 40 cron schedules translated and checked against `systemd-analyze calendar` and `test/cron-ref.py` (the cron rules), J3 `tando jobs` (next runs, zone, results in words, durations) and `jobs log` (each run's own output), J4 the bounded history and the alert in `status`/`ls`, J5 spread and missed-run settings, J6 jobs follow the release (a failed deploy, rollback, removal), J7 a real timer and no second copy of a run going on, J8 pause and resume across a deploy and a host restart, no run made up on resume. About 4 minutes |
| `e2e-trial` | param (the standard image: Caddy with its default admin on 2019) | what the first real-server trial found: host add with the key only in `~/.ssh/known_hosts`, a failed add always says why, host setup moves Caddy's admin to its socket without a restart, doctor at 80 columns; run it again with `TANDO_TEST_CADDY=ubuntu` |
| `e2e-studio` | param (PostgreSQL from apt) | `tando db studio` (docs/COMMANDS.md): drives the page's API with curl through the client's own ssh forward, with the hidden test options (`TANDO_STUDIO_TEST="hb=1 timeout=4 idle-s=3 conn-idle=2"`) so the lifecycle takes seconds. S1 start (the socket's directory and modes, the app's user, no capabilities, no TCP listener), S2 the HTTP edge (token, one-time code, Host/Origin/Sec-Fetch-Site, content type), S3 every known read-only bypass, each followed by a write only PostgreSQL can refuse and the data checked as the superuser, S4 limits and the studio's own clock, S5 cancel, S6 browsing, S7 every way a session ends with nothing left, S8 CI keys at four layers, S9 the refusals and connection slots, S10 the password and a secret cell in no journal, audit line or process list, S11 the Go live tests (pgwire, the studio) built for the server's CPU and run as the app's user, S12 doctor, S13 the backend's scoping (settings, priority, a heavy query's memory, a migration's lock wait, no snapshot between requests), S14 two apps isolated, S15 the app picker, S16 the scope guard (no system schema listed or served, every known way to a system relation refused in the editor, the demo's customers, items, orders and big_orders and everyday SQL still working). The UI is not driven: see the checklist below |
| `e2e-adopt` | param | `tando adopt` on a synthetic hand-deployed app ("bakery": a small Node server in the layout of a Next.js standalone release, run by a hand-written unit as its own user with an env file and a data directory, behind a hand-written Caddy site with one plain `reverse_proxy` line, with a backup script in cron; nothing from the network). Under a request loop through Caddy: the plan and its missing-hold section, `apply` refused without the hold (client and server), the site shapes `adopt site` does not edit, an edit Caddy rejects, a Caddyfile whose port another program holds (refused before any reload, nothing of it served) and a reload that fails while Caddy starts (the previous Caddyfile stays, `tando doctor` asks for the restart), `adopt site --apply` before adoption, `apply`, `tando deploy` and `rollback` with zero failed requests (new connections, one kept-alive client connection, the app keeping its connections alive, and POSTs during the rollback: held and stored once), a Caddy reload under tando's lock during a restart (it waits until the app listens), the request log after adoption and `tando requests`, `undo` back to the recorded state, and a control: the same adoption with `--accept-502` and no hold, where requests do fail (the app takes 1.5 s to listen, so the loop always meets the restart). Not in it: timers that become jobs, a real Next.js build, TLS, and a POST sent on a kept-alive connection the stopping app closes at that instant (not retried, by design; not provoked) |

`e2e-status` (param, needs the network once for PostgreSQL; its db app is skipped without;
status is compared through tandod (0b checks it answers) and again with tandod stopped (6*), and
7* checks that a stop, start and deploy show in the very next `tando ls`/`status`):
`tando-status`, the agent's read-only verbs in Go, against their shell versions on the same server
state. It deploys apps in every state the verbs distinguish (running, a redeploy, static, stopped,
crash-looping, PostgreSQL, a domain with an internal-CA certificate, a job), writes an adopted
app's app.conf, a damaged app and a directory without app.conf by hand, and makes a copy of the
installed agent without its exec block as the reference. Then, for every verb and argument form
(as root and as the login user, the error forms, and mid-activation: a 60 s soak holding the lock
with a queued release), one ssh call runs shell, Go, shell: exit status and stderr must be the
same bytes, stdout the same line by line and field by field, except numbers that change between
two calls (uptime, cpu time, memory, load, disk, log counts, seconds left), which must lie within
what the two shell runs bracket (cpu time strictly; a small margin for the others). Known, listed
differences are checked as such (`3e`: the shell died of `set -u` without an app argument; user
`status <app>`: the shell's `C[port]: unbound variable` row). `--reuse` compares again without
setting up. `test/load/status-bench.sh <app> [id]` times the same verbs on a server (medians of
`RUNS`, wall and CPU of the process tree, systemd's own CPU, peak RSS, and the floor: sudo, an
empty process, systemctl show, tando-logs log-stats, tando-watch brief);
`test/load/status-scale.sh <outdir> [3 20 100]` grows a server's apps to each count and runs it,
plus `tando ls` and `tando status` from the laptop with and without tando-status.

`TANDO_SOAK` (seconds) is sent as the apps' soak when tando.conf has none; test/lib.sh and the
older suites set 2 to stay fast, e2e-faults 25 for the deploy a scenario tests and
`FAULT_SETUP_SOAK` (2) for the deploys that only prepare or close it. test/all.sh runs them all,
each on its own server.

### The fault scenarios in shards

`test/e2e-faults.sh` runs the whole list in order on one server (the weekly tier, with
`FAULT_SETUP_SOAK=25`: every deploy soaks 25 s, the suite as it was). `--shard i/K` runs the i-th
of K chunks of the list, balanced by the scenarios' known durations, s00 first in each;
`--rotate N` (or `auto`: by the day of the year) rotates the list before it is cut; `--plan`
prints the chunks and runs nothing. `test/e2e-faults-q1.sh` to `q6.sh` are the six shards (full
and quick tiers), `test/e2e-faults-h1.sh` and `h2.sh` the two halves with `--rotate auto`
(nightly). The script fails at once when a scenario of the list has no file or would be in no
shard. Scenarios that need the long soak everywhere say so themselves (n5 compares the settings of
two deploys; m1, m2 and m5 set `soak =` in tando.conf).

Measured on 19 Nov 2026 with the four quarters at once, on a machine that was also running other
suites: 824 to 1081 s per quarter, 41 of 41 scenarios passed. One chain with the long soak took
5749 s on 17 Nov. One chain with the short setup soak was not measured (about 3100 s by the sum of
its scenarios).

### The fault matrix

`test/e2e-matrix.sh` puts one fault at one point of an operation and checks the result with one
checker. The points are in the agent: `fp <name>` before external actions of the deploy state
machine and, inside `save`, before and after every write of a state file (`pre:state`,
`post:activation`...). The hook fires only when both markers are root's: `/etc/tando-test-server`
(made by the driver through `docker exec`, never by tando) and the one-shot spec
`/run/tando-test/fault`; on a real server it costs one builtin test. Actions: kill (SIGKILL of the
agent there), fail (that action fails, as on a full disk), reboot (the agent waits there, then
`docker restart`), race (the agent waits there while a second client configures the app with
the next version's tando.conf, then goes on)). A trace of the operation without a fault lists its
points. After the fault,
recovery runs as on a server (ExecStopPost, then what tando-watch's minute does) and `mx_inv`
checks the invariants and names the one that broke: one intended release serves; link, state and
app.conf's start and health agree with it; its status; one history line with the right result and
nothing "running"; idle and the lock free; no leftover unit, lease, temp file or reservation; a
rollback target exists; stopped stays stopped; data and database untouched; no failed visitor
request. The operations `restore` (of a backup taken before the data and rows changed) and
`destroy` have their own: 13, a restore's data and rows are all the backup's or all as before,
anything else recorded in the state (`restore_cut`) and named by `tando doctor`; 14, after a
destroy nothing of the app is left (directory, unit files and units with its timers, workers and
slice, Caddy site, journal settings, user and groups, firewall rules of its uid, database and role)
and its final backup is there, once and complete. The node and static apps ship a fingerprinted file per version
(`assets = assets`; docs/ARCHITECTURE.md "Assets"): invariant 12 is that the serving
release's file answers through Caddy with its bytes and the immutable header, and that no half-made
link or list is left in the shared directory (the cells `k` kill the activation just before and just
after the files are linked). `--selftest` breaks each invariant on purpose and expects it named.

A deploy queued behind another (`--queue`, the cells `QUEUE_CELLS`: queue-fail and queue-kill at
a point). A second admin client never queues on the server: its configure takes the app's lock
and its begin follows at once, and the first deploy holds the upload lease from its begin until
its copy ends, after it took the lock; so the second waits in configure (fault scenario m2) or is
refused at begin (c1). A deploy key's deploy has no configure and does queue at run-activation's
lock. The cell stages the second deploy's settings first (configure with the next version's,
`conf=`), holds the first at its pre-flight's spawn (past the copy: the lease is free), then
begins, uploads and activates the second with its own settings id until the agent reports it
waiting for the lock (`busy_waiting=1`, `phase=queued`); then the first fails or is killed at the
point. The queued release must serve with its own settings (inv2 names the first's left in
app.conf, the unit or the site), and history must have the first's failed or rolled-back line
followed by the queued one's ok line (inv4).

Versions alternate their health path, start command, memory, `max_conns`, a job's schedule and
(kind data) the role's `db_statement_timeout` (odd and even), so a unit file, Caddy site, job
timer, role or app.conf left with the other version's settings is named (inv2). Each version also
has its own `domain =` (`v<n>.mx.test`, resolved by `TANDO_TEST_RESOLVE`; the matrix's host has
`domain_tls=off`): the serving release's domain must be in app.conf and the site, and a domain of
a version that never served (refused, reverted, a second client's) in neither. Cell `o` rolls
back to a release whose settings record is edited to look older than `assets` (no `keys=`, no
`assets=`): the app must keep `assets=` (inv2).

`--kind worker` gives the app workers (odd versions `a` and `b`, even ones `a` only) and adds
invariant 11: the workers that run are exactly the serving release's, each running it, enabled;
none when the app is stopped (`--selftest` breaks it twice: a worker stopped behind tando's back,
a stray worker unit).

`test/e2e-matrix-quick.sh` (full and quick tiers, about 8 minutes) runs `--cells`: one cell for
each defect fixed in milestone 1, 2a and 2b (the list `CELLS` in the driver: two clients' settings, nothing of a deploy that does not go live reaching the live app, job units that could not be written, a queue that gave up, a site file that was not replaced, a rollback cut before its first state write, an upload lease left by a killed begin or activate, a destroy killed after its units went and before its Caddy site, a deploy queued behind one that is refused before its switch, a deploy killed just before its release's manifest is written and between its flushed temp file and the mv: recovery drops the release with its manifest, temp file and work directory),
node; two cells of
the container recipe (the switch failure, a kill at its spawn) and two of a static site (a kill at
Caddy's file site, after the link moved), and for the kind `worker` a kill in the middle of the
workers' switch (`wk.start`) and a failed start of the old workers when a bad release goes back
(`bad.workers`), and for the kind `data` (PostgreSQL) a deploy refused in the pre-flight, which
must leave the role's limits and the domains as the live release has them, and a restore killed
just before pg_restore (the app runs again, `tando doctor` names the cut). `test/e2e-matrix-weekly.sh` (nightly and weekly tiers,
about 15 minutes) runs `--weekly` for static, container, python, next and data (a `destroy --purge` killed at the database drop and at the user removal, and a restart at the drop): the cells of each kind's
`WEEKLY_CELLS`, the points where its path differs from node's. Everything else only by name:
`test/e2e-matrix.sh --ops deploy,rollback --actions kill --points '(^|/)(pre|post):'` (a kill at
every state write of a deploy and a rollback), or any `--kind`, `--ops`, `--actions`, `--quick`.
Not covered: a real power cut (a container keeps the page cache) and a real reboot.

The grid of each kind was run in milestone 2b: static in full (deploy, deploy-pre, rollback: 274
cells, kill, fail and reboot at every point), container (deploy and deploy-bad: 204 cells; its
rollback and restart not yet), python and next (deploy and deploy-bad at the `--quick` points,
kill and fail: 50 cells each, all passed). What did not
pass is either fixed or listed in `MX_KNOWN` in the driver with the invariant and the reason: such a
cell prints as `SKIP KNOWN failure ...`, and fails when it starts to pass (remove it from the list
then). The list is empty now. The last class, an agent killed after it took the upload lease and
before the lease got its release id (invariant 6), was fixed in state machine 3a: the client gives
the lease back when begin or activate fails, and recovery clears a lease with no release id whose
holder is gone (taken in an earlier boot, or its activate no longer runs). (A failed write of
app.conf inside `start_back` was a second class; state machine 2a fixed it.)

### The alerts suites

`test/e2e-alerts.sh` was one suite of 25 minutes, most of it waiting for real minutes. It is three
suites on three servers now, sharing `test/alerts-lib.sh` (helpers, fixtures, setup):
`e2e-alerts` (sections 1-20, 23-28, 30 and 31: checks started by hand; 30 scheduled jobs that fail, 31
PostgreSQL, which it installs from the network), `e2e-alerts-timer` (22, then 21:
`e2e-alerts` (sections 1-20, 23-28 and 30, the heartbeat finding and the backup ping: checks started by hand), `e2e-alerts-timer` (22, then 21:
the reboot, boot grace and the real timer) and `e2e-alerts-daemon` (29, then 27h and 27i: tandod
and its fallback). Every check id is in exactly one of them. Waits that prove a quiet period, a
grace period or a real timer were kept and say so in a comment; waits for an event became polls
or runs started by hand. Measured the same day: 493, 600 and 261 s.

## tando db studio: the manual UI checklist

No headless browser is in the repository, so the page (srv/studio/ui) is checked by hand before a
release that changes it, in Chrome and Safari, light and dark (the system's and the toggle):
`tando db studio <app>` on a test server with the e2e-studio data (`KEEP` a server of that suite).

1. The link opens the page; the address bar loses `#c=` at once; a reload keeps working; the same
   link in a second tab says it was already used.
2. The top bar names the app, its database and the server; the tab's title too; nothing names
   another app anywhere; the sidebar has no pg_catalog, information_schema or other system schema,
   and `SELECT * FROM pg_roles` in the editor shows the scope message with `pg_roles` selected.
3. Tables: filter (`/` focuses it), kinds and estimates, a click opens rows; sort a column (asc,
   desc, none); page « ‹ ›, 50/100/500; NULL dim italic, `''` dim; numbers right-aligned;
   `items_v` notes that a view may page unstably.
4. A cell: the side panel with the value, a long one cut with the note, JSON pretty-printed, a
   bytea as hex with its size, Copy works, Esc closes.
5. Structure: columns, defaults, identity, the key; indexes; "Open in SQL" fills a query.
6. SQL: Cmd/Ctrl+Enter runs the statement at the cursor, with a selection the selection,
   Shift+Cmd/Ctrl+Enter all; Tab indents, Esc then Tab leaves; the line:column indicator; one tab
   per statement; an error selects its position (try a typo after a multi-byte character); notices
   listed; `SELECT pg_sleep(20)` then Cmd/Ctrl+. cancels; 10,000 rows show 1,000 and "Show 1,000
   more"; a refused statement (`DELETE ...`) says read-only and names tando db psql.
7. CSV: a cell `=1+1` comes out as `'=1+1`, Shift-click gives the raw file; the file name has no
   odd characters; a truncated result's name says so.
8. History: queries listed newest first, a click puts one back; Clear; after Stop and a new
   session the history and the editor text are back; in the browser's storage only ciphertext
   (devtools: localStorage `tando.studio.<app>.history` is not readable SQL).
9. Stop: the "studio of <app> ended" screen with the command; Ctrl-C in the terminal and a
   laptop sleep of a minute give the same screen within a minute (the ping); a markup value in a
   table (`<img src=x onerror=alert(1)>`) shows as text.
10. Narrow window (720 px): the sidebar shrinks, nothing overlaps.

## test/go.sh

Modes: by default Go's own test cache is used (an unchanged package is not run again) and g7, g8
run beside g3. `--no-cache` or `GO_NOCACHE=1` adds `-count=1` (the full, nightly and weekly tiers
set it); `--quick` or `GO_QUICK=1` skips g8, the race detector, with a SKIP line (the quick tier);
`GO_SERIAL=1` runs one check after the other. The cache does not see the clock, the network or
Docker: a test that depends on those must not be trusted from a cached pass.

The Go server programs (srv/README.md), one check each: `g1` `gofmt -l` prints nothing, `g2`
`go vet ./...`, `g3` `go test ./...` (table-driven unit tests of every package: parsers, file
formats, rotation, the fake machine of `metrics`, the fake host of `watch`: a clock moved a
minute per run, systemctl/journalctl/tando-logs answered by a `run.Func`, fake probes and receivers;
the golden tests of `logs`, which hold its parsers to the bytes the shell version's own awk printed
for the same hostile input, `srv/logs/testdata/golden`), `g4` no shell and a closed set of programs (`test/lint.sh` RL15/RL16
on the Go files as a first line, then `srv/tools/srvlint` on the syntax trees: `os/exec` only in
`srv/internal/run` under any import name, no `os.StartProcess`/`syscall.Exec`, raw syscalls only
with the numbers of its list, no shell in a call into `run` after folding constants, every program
a constant and in `srv/tools/srvlint/programs.txt`, every argument constant, validated or after `--` (`args.txt`), the fixed forms of rsync, nft, du, sendmail, crontab, caddy, python3 and node, systemd-run properties on a list, no module outside the standard library; its own
tests are in `srv/tools/srvlint` with fixtures in `testdata/`), `g5` the layering (srvlint: `internal/*`
imports no domain package, no domain package imports another, only `cmd/*` imports `daemon`, one
listed exception), `g8` `go test -race ./...` (SKIP, with the reason, where the race
detector does not work: it needs cgo and a C compiler), `g6` every `srv/cmd/*` builds as a static ELF for
linux/amd64 and linux/arm64. Runs with `GOTOOLCHAIN=local` (nothing is downloaded); without Go it
is one SKIP. The programs' behaviour on a server is covered by the end-to-end suites
(`tando-metrics`: e2e-top check 7, e2e status sparkline, e2e 1b installed files; `tando-watch`:
e2e-alerts, all of it (its check 27b runs `go test -run TestMemstat` when the installed program
is the Go binary), and the faults j1-j3, m1, n6, n7; `tandod`: the same e2e-alerts (tandod is the
default; its section 29: running after setup, a SIGKILL in the middle of a run, the timer's
fallback when it is stopped, an upgrade from a timer-only host), and e2e-alerts with
`TANDO_TEST_NO_DAEMON=1` (tandod disabled after every host setup: the one-shot path); `tando-gate`:
e2e-ci, all of it, and the gate attacks of e2e-sec2: a08, a09, a10, f4; `tando-logs`: e2e-logs, all
of it (its check 13e reads a value ending in `=` through `caddy-log`), e2e-alerts 28 (`watch-scan`,
`errors`, the journald drops note), and the audit lines every mutating verb of e2e writes;
`tando-status`: e2e-status, all of it (against the shell versions), every `tando ls`, `status`,
`top`, deploy and rollback of the other suites, the CI key's read verbs of e2e-ci, and the faults
that check what status says during a broken activation).

The parsers of `srv/logs` have fuzz targets (`FuzzReader`, `FuzzEntry`, `FuzzRequest`, `FuzzQuick`,
`FuzzFast`, `FuzzDecimal`, `FuzzScanner`, `FuzzWord`); g3 runs their seeds. A minute each finds
nothing today: `cd srv && go test -run '^$' -fuzz '^FuzzFast$' -fuzztime 60s ./logs/reqlog/`.
`TestIndexMatchesScan` holds the request index to a full scan; `TestNoAllocations` fails when the
request-log hot path allocates per line; `go test -run '^$' -bench . ./logs/...` prints the
benchmarks of the parser, the summary and the index (srv/README.md).

`srv/gate` has more than g3 runs. Its root side (root mode, admin mode, rx mode, users, sudoers,
sshd) is tested on a fake host (`root_test.go`: a temp root and /etc, a fake /proc with the key's
ssh session above the test, a cgroup tree, and a runner that answers systemctl, systemd-run,
tando-agent, visudo, sshd, useradd... and records every argv, compared whole), as a normal user
(those tests skip as root). `source_test.go` checks on the AST that the gate has no exec path.
Coverage: about 87% of statements (`go test -cover ./gate`, macOS and Linux alike).

`fs_linux_test.go` holds the Linux-only tests: the descriptor walk, link removal, setuid
stripping, a directory swapped for a symlink to `/` and to `.` while the watchdog and the scan walk
it, and a 000 directory in an upload. **g7** of test/go.sh runs them, with the whole package, from a
test binary for this machine's CPU in a throwaway `ubuntu:24.04` container, as a user and as root;
without Docker or that image it is a SKIP that says so. By hand:

```sh
cd srv && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go test -c -o /tmp/gate.test ./gate
docker run --rm -v /tmp/gate.test:/gate.test:ro ubuntu:24.04 sh -c \
  'useradd -m u && su u -c "cd /tmp && /gate.test" && cd /tmp && /gate.test'
```

The fuzz targets, a few minutes each:

```sh
for f in FuzzParseRequest FuzzKeyMode FuzzReadParams FuzzParsePublicKey FuzzKeyList FuzzParsePasswd FuzzResolve; do
  go test ./gate -run "^$f\$" -fuzz "^$f\$" -fuzztime 3m
done
```

e2e-ci section 10 is the regression for the receiver's unit name: `TANDO_CI_RACE_N` (200) uploads
back to back in one lease, and a quarter as many rounds of begin, upload, end (an upload right
after `end`); 10d/10e: after `end` returns nothing more is written into `incoming/` and the
receiver's ticket is gone. A slow unit start can be reproduced with the test-only build tag
`tandogatedelay` (`go build -tags tandogatedelay ./cmd/tando-gate`: systemd-run starts 6 s late;
never set by scripts/build-server.sh).

## test/lib.sh

Shared helpers for suites; bash 3.2, safe under `set -u`. Source it and call `t_init`:

```bash
#!/bin/bash
set -u
. "$(cd "$(dirname "$0")" && pwd -P)/lib.sh"
t_init mysuite                       # ROOT, R=bin/tando, E=work dir, SSH, TANDO_CONFIG_DIR, ports
t_server_up --reset                  # reset only if owned (see convention 3)
t_host_add test                      # host add with the suite's port and the test key
"$R" host setup test public_port="$T_HTTP_PORT" >&2
t_loop_start up "$(t_url hello)"     # ~10 requests/s in the background
"$R" up >&2
t_loop_stop up                       # T_LOOP_N, T_LOOP_BAD (non-200), T_LOOP_MAX, T_LOOP_STALL
check "1a no failed request during up ($T_LOOP_BAD of $T_LOOP_N)" t_eq "$T_LOOP_BAD" 0
t_pty 80 24 3 "$R" ls > "$E/ls.out"  # run on a pty of 80x24 for 3 s
check "1b ls fits 80 columns" t_assert_width "$E/ls.out" 80
t_done                               # "<suite>: N passed, N failed, N skipped", exit status
```

| Helper | |
|---|---|
| `pass`, `fail`, `skip`, `check "<id> <text>" cmd...` | counters `T_PASS`, `T_FAIL`, `T_SKIP`; failed ids in `T_FAILED_IDS` |
| `t_eq <got> <want>`, `t_until <secs> cmd...` | assertion with a diff on stderr (fails when both are empty); retry once a second |
| `t_free_ports <ssh> <http>` | first free pair from those ports (nothing listening, no container publishing it) |
| `t_server_up [--reset]`, `t_host_add [name]`, `t_srv cmd`, `t_url app [path]` | the suite's server |
| `t_loop_start name url [interval]`, `t_loop_stop name` | request loop: non-200 count, slowest request, longest stall between two 200s |
| `t_pty cols rows secs cmd...` | run on a pseudo-terminal of that size (python3) |
| `t_assert_width file width` (fails on a missing or empty file) | escape-free visible width per line; box lines exactly `width` |

## test/lint.sh

```
test/lint.sh                    new findings; exit 1 on a new error
test/lint.sh --all              also baseline entries, info findings and stale baseline entries
test/lint.sh --strict           new warnings fail too (combines with --all)
test/lint.sh --update-baseline  accept every current finding (then review the diff of the file)
test/lint.sh lib/deploy.sh      some files only
test/lint.sh --list             files and their side (laptop / linux)
test/lint.sh --no-cache         run shellcheck on every file again (LINT_NO_CACHE=1; the full tiers)
```

shellcheck runs once per batch of files (`LINT_JOBS` batches at a time, default 8), from a native
`shellcheck` or `$SHELLCHECK` when there is one, else in Docker. Its findings per file are kept in
`.tando/lint-cache`, keyed by the file's path and content, the options, `.shellcheckrc`, the
shellcheck version or image, and the content of the files it sources; cached and fresh runs give
the same bytes (compared on the whole tree).

Files: `bin/`, `lib/`, `server/`, `test/` (not `test/.*`), `install.sh`, `uninstall.sh`,
`completions/`, `scripts/`; shell files by extension or shebang. zsh files get `zsh -n`. Go files
under `srv/` get only RL15/RL16 (`// lint: allow RL16 <reason>` silences one line; `srv/tools/` is
not read: srvlint checks it);
`server/legacy/` is not linted (not shipped).
**Laptop side** is everything except `server/`, `test/server/files/`, `test/replica/files/` and files
marked `# lint: side=linux`; bash-4 and GNU-only checks apply to it only.

shellcheck runs with `.shellcheckrc` (every disabled code has its reason there); `lib/*.sh` also
skip SC2034 because they are fragments of one program. shellcheck errors and warnings count as
errors; info and style as info. It uses `$SHELLCHECK`, else `shellcheck` on PATH, else Docker
`koalaman/shellcheck:stable` (CI pins v0.11.0: other versions find different things).

The tando checks (test/lint.pl), line-based over code with single-quoted text, comments and heredoc
bodies masked:

| Code | Severity | Finds | Why it matters |
|---|---|---|---|
| RL01 | error | bash 4+ on the laptop side: `declare -A`/`-n`/`-g`/`-l`, `${x,,}` `${x^^}`, `${x@Q}`, mapfile/readarray, `&>>`, `\|&`, `wait -n`, `read -t 0.5`, `printf -v a[i]`, `${a[-1]}`, `${x:0:-1}`, coproc, `;;&` `;&`, globstar/lastpipe, `$EPOCHREALTIME`, `%(..)T`, `test -v`, `{1..9..2}`, `{fd}>` | macOS ships /bin/bash 3.2.57; any of these is a syntax error or silently wrong there |
| RL02 | error/warn | GNU-only tools and flags on the laptop side: `sed -i` without an attached suffix, `date -d`, `%N`, `readlink -f`, `stat -c` (and BSD-only `stat -f`), `grep -P`, `mktemp -p`/`-t`/`-u`, `timeout`, `sort -V`, `find -printf`, `tac`, `nproc`, `sha256sum`, `cp -T`, `install -D`, `xargs -d`, `base64 -w`, `du -b`, `head -n -N`, gawk functions, GNU long options | the client must work with BSD tools on macOS *and* GNU or BusyBox tools on Linux (CI runners) |
| RL03 | error/warn | `eval` of command output or files; `source` of a computed path or command output | server output must never become code on the laptop |
| RL04 | warn (info in tests) | `$var` / `$(...)` inside a double-quoted ssh command string, unless remote-quoted or a literal constant | the remote shell parses the string again: spaces, `;`, `$()` in the value run on the server |
| RL05 | error | `rm -r "$X/..."` / `"$X"/*` where X could be empty (not `${X:?}`, not a literal constant) | an empty X turns it into `rm -rf /...` |
| RL06 | warn (error on the server or with `$$`) | fixed names under `/tmp` outside mktemp | another local user can pre-create or symlink the name |
| RL07 | warn (info in tests) | a password/secret/token variable passed on an ssh/curl/psql/docker command line | arguments are visible in `ps` on both machines and in the remote shell |
| RL08 | info | lines over 120 characters | review diffs and the project style |
| RL09 | error (warn in tests) | an executable script without `set -u` | a misspelt variable silently expands to "" |
| RL10 | warn | `"${a[@]}"` under `set -u` where `a` can be empty | bash 3.2 aborts with "unbound variable" |
| RL11 | info | `#!/usr/bin/env bash` on the laptop side | picks Homebrew bash 5 and hides 3.2 bugs |
| RL12 | error | completions out of date with the command list | `completions/gen.sh` |
| RL13 | error | `apt-get install` in `server/` without `NEEDRESTART_SUSPEND=1` | Ubuntu's needrestart would restart services tando does not manage after an install |
| RL14 | error | a pipe into `grep -q` outside `test/` | grep exits at the first match, the writer gets SIGPIPE, and `pipefail` turns a match into a failure; use `grepq` |
| RL15 | error | Go (`srv/`), first line only (srvlint checks the syntax tree, test/go.sh g4): `os/exec`, `os.StartProcess`, `syscall.Exec`/`ForkExec` outside `srv/internal/run` | every program starts through `run`: argv, timeout, explicit environment |
| RL16 | error | Go (`srv/`; not `internal/run`), first line only (srvlint, g4): the string literal `"sh"`, `"bash"`, `"dash"`, `"zsh"`, `"/bin/sh"`, `"/bin/bash"`, `"/usr/bin/env"` or `"-c"` | no shell, ever: a value that reaches a shell is parsed again and becomes code |

Silence one line with a comment on it or on the line above: `# lint: allow RL05 <reason>` (for
shellcheck codes, shellcheck's own `disable=` directive). A whole file: `# lint: file-allow RL06 <reason>`.

**Baseline.** `test/lint-baseline.txt` records known errors and warnings as
`file TAB code TAB source line` (no line numbers, so edits elsewhere in a file do not invalidate it).
Info findings (RL08 line length, shellcheck style notes such as SC2086/SC2015) are never recorded and
never fail; `--all` lists them. A run fails only on errors that are not in the baseline; entries that
no longer match are counted as stale and listed with `--all`. Identical lines share one count.

Known shellcheck false positives are dropped before the baseline: SC1010 where `done` is a word
argument (`pg phase done`), and SC2178/SC2179/SC2128 on a name that is a nameref (`local -n`) or a
`local` variable (shellcheck does not track function scope). RL03 accepts sourcing a file next to
the script (`. "$(dirname "$0")/lib.sh"`) and eval of a single-quoted literal, also one spanning
lines; RL09 accepts a script that sources a file with `set -u` (faults/*.sh and lib-fault.sh) or
only `exec`s another script. When you fix findings, run
`--update-baseline` and commit the shrunk file; never update it to hide a new error.

## test/portability.sh

`test/portability.sh [mac] [debian] [linux] [busybox]` (all by default):

- **mac**: `/bin/bash -n` on every laptop-side file; `test/ui-test.sh` under /bin/bash 3.2; `help`,
  `init` on every example, `host add` under /bin/bash.
- **debian** (`debian:stable-slim`: bash 5.2, mawk, GNU tools, perl-base without Time::HiRes):
  `bash -n`, ui-test, help, `init` must give the same tando.conf (or refusal) as on macOS, and the
  `clock`/`since` helpers.
- **linux**: a client container from the test server image (bash 5.3, GNU coreutils, rsync 3.4,
  OpenSSH 10) against a test server on the Docker network: host add/setup, `up` of examples/hello,
  a redeploy, then every read-only command (`host ls`, `ls`, `ls --all`, `status`, `history`,
  `releases`, `env ls`, `logs`, `jobs`, `doctor`), `env set`, width of `ls`.
  Read-only plugin commands (`audit`, `requests`) run too when present; they are SKIP while the
  agent has no verb for them.
- **busybox**: the same with BusyBox 1.37 (from alpine:3.22) in front of every GNU tool and perl
  removed; bash, ssh, rsync and curl stay because tando requires them.

Client commands run with xtrace on a separate descriptor, so any tool error ("illegal option",
"invalid option", "not found", "unbound variable", ...) is printed as
`INCOMPAT <part> <file>:<line> (<command>): <error>`. The server is `tando-test-q3` on 2313/8313
unless `TANDO_TEST_*` are set.

## CI

Small on purpose (`.github/workflows/test.yml`): the tiers are run on the developer's machine.
Every push and pull request gets two jobs:

- **checks** (no server): the secret scan and its own test, lint with shellcheck v0.11.0 pinned,
  test/go.sh, ui-test, install-test, the reproducible-release check, and that the suite map and
  every tier's plan are sound.
- **smoke**: builds the test server image and runs `e2e-trial` and `e2e-next`.

By hand only (Actions, "Run workflow"): **tier** runs a whole tier (`full`, `nightly` or `weekly`)
and the Linux/BusyBox portability checks on the runner, and **macos** runs the laptop side under
macOS's bash 3.2. Nothing is scheduled: the nightly and weekly tiers are local commands
(`test/all.sh --tier nightly`), run when the machine is free.

This layout first ran on GitHub on 19 Nov 2026 (commit 441265e): **checks** passed in 5 min 5 s and
**smoke** in 2 min 15 s; **tier** and **macos** were skipped, as they should be on a push. The
manual jobs have not been run there yet. The assumptions about the runners (systemd boots in a privileged container, x86_64,
network for the image build, `*.localhost`) held on the runs of 17 Nov 2026.
