# tando status: one page for the owner

The project was renamed to tando shortly before its first publication. It is licensed under the PolyForm Noncommercial License 1.0.0 (LICENSE, COMMERCIAL.md). Status: pre-1.0, tested on Ubuntu 26.04.

17 Nov 2026. This page was written from the tree as it is, the review reports in `docs/`,
`bench/`, the full test run of 15 Nov, the exercise on the real server of 14 and 15 Nov, and the
work of 16 and 17 Nov (the Go server programs, offsite backup, host care). The 15 Nov sections are
kept as they were; "Round of 16-17 Nov" says what changed since and what is not verified.

**Verification labels.**

- **dev**: verified by the developer's own run of a suite in `test/`.
- **indep**: verified by an independent reviewer (the report says it was run).
- **fix present, not independently re-verified**: the code has the fix, and the only test run
  after it is the developer's.
- **open**: no fix in the code.
- **dropped tonight**: the work was deliberately not done.

## Done

| Area | State | Verified by |
|---|---|---|
| Deploy pipeline: build on laptop, rsync, pre-flight, switch, verify, soak, rollback, recovery | built | dev: e2e 95/95, e2e-faults 41/41. indep: FAULT-REVIEW (all 27 earlier failures confirmed fixed) |
| Recipes node, next, static, python, container | built | dev: e2e-recipes 27/27, e2e-next 24/24 |
| Env, jobs, backups, PostgreSQL, SQLite | built | dev: e2e-data 56/56 (role limits, OOM score, recorded version) |
| CI deploy keys (tando-gate) | built | dev: e2e-ci 406/406. indep: SECURITY-REVIEW-2 |
| App shell, sandbox, third security round | built | dev: e2e-sec2 60/60 (20 of them the third round's attacks) |
| Logs, requests, audit, log retention (`log_keep`, `log_max`) | built | dev: e2e-logs 113/113 |
| Alerts, health, app errors, liveness restart | built | dev: e2e-alerts 138 pass, 1 skip |
| Empty VM to live, domains (internal CA, fake DNS) | built | dev: e2e-bootstrap 22/22; real server below |
| CLI argument checking, help, guided setup | built | dev: e2e-cli 263/263, e2e-ease 27/27, ui-test 463/463 |
| `top` | built | dev: e2e-top 25/25 |
| `adopt` | built | rehearsed on a private replica of a real server (61/61 on 15 Nov; that suite needs private data and is not in this repository), then run on that server on 19 Nov: one app adopted and deployed. `adopt undo` and timers only on the replica. dev: `test/e2e-adopt.sh` (a synthetic app, no timers): plan, site, apply, deploy, rollback, undo |
| Install, release archive | built | dev: install-test 17/17; lint 0 new errors or warnings |
| Real-server regressions | built | dev: e2e-trial 11/11 |
| Limits and load: per-app slice, `max_conns`, `max_requests`, per-client limits | built | load tester (test/load, bench/RESULTS.md); in e2e and e2e-faults |
| Benchmarks v1 and v2 (tando, Kamal, build on server, Podman, Dokku) | measured | bench/RESULTS.md, including the real-server numbers |
| Server programs in Go: `tando-metrics`, `tando-logs`, `tando-watch`, `tando-gate`, `tando-status`, `tandod` (srv/) | built | dev: `test/go.sh` (gofmt, vet, unit tests, race detector, srvlint, both CPUs); e2e-status 121 checks against the shell versions; e2e-alerts, e2e-logs, e2e-ci, e2e-top, e2e-sec2 on the Go programs. Test container only: **not yet run on the real x86-64 VM** |
| No-shell rule and crash-safe helper install | built | dev: `srv/tools/srvlint` run by `test/go.sh`; install and recovery in e2e and e2e-faults. Test container only |
| Offsite backup (`tando backup offsite`, `tando restore --from-host`) | built | dev: srv/offsite unit tests, `test/e2e-offsite.sh`. **Against a fake S3 only, never real R2** (`test/offsite-r2-check.sh` has not been run) |
| Host care (`tando host status|care|update|reboot`) | built | dev: srv/hostcare unit tests, `test/e2e-host.sh`. Reboot and real kernel updates **untested** (containers cannot do them) |
| Alerts for offsite (`offsite`, per app) and host care (`updates`, `reboot`, `exposed`, `ssh`, `units`, `readonly`, `ioerr`, `clock`, `eol`, `boot`) | built | dev: srv/watch unit tests (hostcare_test.go), e2e-alerts, e2e-host |

Last full run: 15 Nov 2026 16:54 to 18:39, `TANDO_TEST_CADDY=ubuntu test/all.sh`, 18 suites.
15 passed at once; three failed on one check each (two messages wider than 80 columns, one
timing check on a busy laptop). After those fixes, and three more found on the real server, the
suites that cover the changed code were run again and passed. Per suite, latest run:
18 of 18 suites, 1,824 checks passed, 0 failed, 1 skipped.

That run was before the Go rewrite, offsite backup and host care. `test/all.sh` now has 22 suites.
Result of the full suite on the final tree of 17 Nov:

Full suite on this tree, 17 Nov 2026 (`test/all.sh`, 21 suites, test containers on Ubuntu 26.04):
17 suites passed, 4 had one failing check each (2,113 checks passed, 4 failed, 2 skipped).

| Failing check | What it was | State |
|---|---|---|
| e2e-trial T3b | a doctor row wider than 80 columns | fixed, suite passes again |
| e2e-faults m3 | the test expected 8 setup steps, there are 9 | test fixed, check passes again |
| e2e 19j | stopped journal units that systemd had not unloaded yet were counted as leftovers of `destroy` | test fixed, check passes again |
| e2e-alerts 27i | the check asked for the last run before the first run after the daemon tests | test fixed, suite passes (154 passed, 1 skipped) |

Test environment: with other test containers starting and stopping beside it (Docker on OrbStack),
a container sometimes comes back from `docker restart` with systemd up and sshd listening but its
published ports reaching nothing. The alerts and fault suites restart it once more when that
happens. This cost several runs; it is not a tando fault (no connection arrives in the container,
and tando's firewall does not touch port 22).

The rerun of the fault suite then failed one other check, h2 (40 passed, 1 failed). That one was
tando's: a deploy refused for lack of disk space kept its upload lease, so a second deploy within
5 seconds was told "another deploy is uploading". The agent now gives the lease back when it refuses
an activation; h2 passes alone. The whole fault suite has not been rerun since.

On GitHub's runners (x86-64, the first place the amd64 server programs ran): lint, Go, the secret
scan and the laptop-side jobs pass. The server job (18 suites; the fault suite
is not run there) took six runs to pass: its failing checks were tests written for the laptop (an
ssh client option OpenSSH 9.6 on Linux ignores, a fake ssh that did not read its input, `nc` not
half-closing on Linux, a newer Caddy logging an aborted request as 499, runners without swap, a
pseudo-terminal). It passed as a whole on 17 Nov. GitHub's macOS runners were not always
available: a job cancelled after 15 minutes in the queue is that, not a test.

Release check, 16 Nov (before the Go binaries were part of the archive; not repeated since): `test/portability.sh` 53 passed, 0 incompatibilities;
`scripts/release.sh --check` reproducible (40 files, 292 KB); installed from the archive into an
empty prefix, the installed copy is byte-identical to the tree, ran `ls` and `doctor` against the
real server, uninstall left nothing. Before a public release: set the owner in
`install.sh` (`TANDO_REPO`) and README.md, make the first commit and tag (docs/RELEASING.md); the
GitHub workflow in `.github/` has never run.

## Round of 16-17 Nov: Go server programs, offsite backup, host care

What changed (details in CHANGELOG.md, "Unreleased"):

- **Server programs in Go.** `tando-metrics`, `tando-logs`, `tando-watch`, `tando-gate` and the
  agent's read-only verbs (`tando-status`) were rewritten from bash to Go (srv/, standard library
  only). Verbs, output, files and modes are meant to be identical; the shell originals are kept in
  `server/legacy/` (not shipped) and e2e-status compares the two byte for byte. New: `tandod`, one
  daemon that runs the metrics sample, the alert checks and the log scan each minute instead of
  three timer-started programs; `tando-watch.timer` stays as the fallback. `tando-agent` and
  `tando-adopt` stay shell.
- **No-shell rule.** No Go program starts a shell, and only a fixed list of programs with fixed
  argument forms (`srv/tools/srvlint`, run by `test/go.sh` and `test/lint.sh`).
- **Crash-safe helper install.** `tando host setup` stages and verifies every file, journals the
  switch and finishes or undoes a cut-off one at the next setup, at boot, or before a mutating agent
  verb. `tando doctor` shows a pending switch.
- **Offsite backup.** Encrypted copies of every backup in Cloudflare R2 or any S3-compatible store,
  retry timer, recovery key, `tando restore --from-host` for a lost server (docs/BACKUP.md).
- **Host care.** `tando host status`, `care`, `update`, `reboot` and the hourly `tando-host` checks
  (docs/HOSTCARE.md).
- **Alerts.** An `offsite` check per app and host checks `updates`, `reboot`, `exposed`, `ssh`,
  `units`, `readonly`, `ioerr`, `clock`, `eol`, `boot` (docs/MONITORING.md).

**Performance** (bench/RESULTS.md, "Go server programs, 16-17 Nov 2026"). These come from a 1-CPU
arm64 test container, not from a real server. On that container: a metrics read of 2,000 points
362 -> 3.2 ms, a 7-day request summary 2,197 -> 44 ms, `status` through the daemon at 20 apps
113 -> 3.0 ms, one monitoring tick at 20 apps 758 -> 7.9 ms, tandod 9-11.4 MB resident and flat over a
65-minute soak. The log scan under heavy load is only 1.4 times faster, because journalctl is the
floor. From the laptop `tando ls` went 582 -> 478 ms: ssh and rendering dominate.

**Not verified. Read this before relying on the new parts.**

1. **The real server now runs the Go versions, set up fresh.** On 17 Nov the old install was removed
   from the x86-64 VM by hand and `tando host setup` run from this code: 24 s, the other site on the
   same Caddy untouched (0 failed requests, same processes). Three apps deployed (Node, static, Node
   with PostgreSQL), a deploy, a rollback, `ls`, `status`, `health`, `requests`, `history`, `host
   status`, `doctor`, and an alert that fired and restarted a frozen app. Not done there: the upgrade
   path over an existing shell install (containers only), host care with updates or reboots on,
   offsite backup, CI deploy keys, a day-long soak.
2. **The VM's numbers are in bench/RESULTS.md** ("Go server programs on the real server"): a status
   call 372 -> 24 ms of server CPU, the monitoring daemon 58 ms of CPU per minute and 8 MB. The
   figures above this list are still the container's.
3. **Offsite is tested against a fake S3 only.** The fake (`srv/offsite/testdata/fakes3`) checks
   every SigV4 signature and the unit tests use AWS's published vectors, but no run against real R2
   has been made: `test/offsite-r2-check.sh` exists and has not been run. Real-provider behaviour
   (multipart limits, eventual consistency, error bodies, rate limits) is unknown. The
   disaster-recovery path ran between two test containers.
4. **Host care: reboot and real kernel updates are untested.** Containers cannot reboot or install
   a kernel. The reboot rules (window, never during a deploy, backups first, every app checked
   after) and the kernel and reboot-needed findings are tested with fixtures and fake hosts. Whether
   a real reboot of the VM brings every app back is not shown. `unattended-upgrades` on a real
   server was not run either.
5. **Ubuntu versions.** Only Ubuntu 26.04 ran end to end. 24.04, the oldest release README.md
   promises, is covered by fixtures (and by the 24.04 container the fake S3 runs in), not by a
   server that ran tando.
6. **The full suite on the final tree** is running at the time of writing; see the placeholder under
   "Done".
7. **Fuzzing and races.** The fuzz targets were run for about a minute each and found nothing; that
   is a short run. The race detector needs cgo and a C compiler and is skipped where there is none
   (`go.sh` g8 says so).
8. **Nothing is committed.** The tree is not under a commit for any of this work, and `.github/`
   has never run.
9. **License and owner are set.** PolyForm Noncommercial 1.0.0 (LICENSE, COMMERCIAL.md); the repository is
   `rasisbuldan/tando`. Nothing is pushed yet.

**New things to do on the real server**, in this order: take a backup; `tando host setup` over the
existing install; `tando doctor` (rows `daemon`, `status`, `install`); `tando ls` and
`tando status` against what the shell versions showed; a deploy and a rollback; `tando alerts`;
`tando backup offsite set` with a real R2 bucket, then `test/offsite-r2-check.sh`; `tando host
status`; only then `tando host care on --updates`, and `--reboot` in a window you are awake for.

## Round of 15 Nov: security, concurrency, load

- **Security (third round).** Three testers ran about 130 live attacks (test/sec3). No route to
  root and no escape from the sandbox. 18 findings (1 high: PostgreSQL connection slots; the rest
  medium or low), all fixed, each attack re-run by the developer: e2e-sec2 S3-01..S3-20.
  the architecture notes, "Third review", lists the fixes and what stays open. Not independently
  re-verified.
- **Breaking change from it.** HOME of an app is read-only (`<app>/home`). Apps and jobs write to
  `$TANDO_DATA_DIR` (shared/data); caches go to shared/.cache.
- **Concurrency.** 8 races found (test/race), all fixed; every reproducer re-run on the final
  code by the orchestrator: 0 bad outcomes in 8 to 20 rounds each.
- **Load** (1 CPU, 2 GB container on a busy laptop; bench/RESULTS.md). hello through Caddy: 7.4k
  requests/s at 50 connections, 4.1k at 5,000, 0 errors. Deploy, rollback and restart under
  about 2,500 requests/s: 0 failed. 10,000 open connections: 0 errors. With `max_requests` and
  `hold`, an overloaded app keeps answering at its capacity instead of timing out.
- **Open after this round.** No real disk quota. No requests-per-second limit per
  app. A fast 503 needs `hold`. No alert when the per-client limit trips all the time. Quiet
  hours for alerts are not built. tando-watch's config and tando-gate's key list were not
  audited for read-before-lock.

## Open findings, by report

"Test" means a check in `test/` for the finding exists and passed in the latest developer run.

### SECURITY-REVIEW-CI.md (F1-F11) and SECURITY-REVIEW-2.md (N1-N15)

| id | sev | finding | state |
|---|---|---|---|
| F1-F5, F7-F11 | crit-low | Caddy admin API, symlink chown/restore to root, rsync write-through, end kills upload, image-ref read, C1 names, revoke, locale, key_active | fixed, **indep** (SECURITY-REVIEW-2 re-ran them) |
| F6 / N10 | med | disk amplification | fix present (failed releases deleted, `app_max_mb` caps incoming + releases), not independently re-verified; dev test a09 pass |
| N1, N2 | crit/med | a job binds another app's port | fixed for native and adopted apps (`props - job` → `SocketBindDeny=any`; `own_listener`); dev test a01/a02 pass; independent verifier re-ran the attack: blocked |
| N3 | high | job survives `destroy` | fix present (units stopped and killed, kill loop, userdel checked, uid retired), dev test a03 pass |
| N4 | high | laptop RCE through arithmetic on server fields | fix present (`ui_int`/`ui_nums` at the parse boundary in lib/views.sh and lib/cmd-top.sh), no test re-runs a11/a12 |
| N5 | high | adopted env file symlink swap | fix present (values copied into `$D/env`, `root_safe` check), no re-run in repo |
| N6 | high | `eval` in adopt plan gives root | fix present (`unit_env` reads character by character, no eval; unit files must be root-safe), no re-run in repo |
| N7 | med | Host with a port is unlogged on Caddy 2.6.2 | fix present (`respond @tandoport 400`), dev test a07 pass |
| N8 | med | journal namespace flood | fix present (namespace dirs 0750 per app group); dev: socket write refused (pass), a15 flood SKIP (inconclusive) |
| N9 | med | shared /dev/shm, uid reuse | fix present (`PrivateIPC`, 16 MB private /dev/shm, uid files deleted, uids retired), dev pass |
| N11 | low | probe UA unlogged | fix present (root-only `X-Tando-Probe` header), dev pass |
| N12 | med | adopt accepts privileged users | fix present (groups, shell, crontab, other units checked), no test |
| N13 | low | backup tar follows a data symlink | fix present (`shared_ok`, tar in a sandboxed unit), dev pass |
| N14 | low | lone C1 bytes reach the terminal | fix present (`strip`, `san_v` on `log=`), no test |
| N15 | low | tando.conf retargets a deploy | fix present (`out` must be inside the project; target guard asks), no test |
| residual | - | containers under root Podman have no `props` sandbox | open (by design for now, the architecture notes) |

### FAULT-REVIEW.md (F1-F21)

All the scenarios of the 27 failures, plus the baseline, passed in the dev run (28/28). The other
48 scenarios (`--all`) were not re-run.

| id | finding | state |
|---|---|---|
| F1, F3 | killed activation / full disk: hung client, lying state | fix present, not independently re-verified (ExecStopPost recover, deploy-status liveness, client deadline, disk gate, reserve file) |
| F2 | stale upload lease for 15 min | fix present, not independently re-verified (30 s staleness check, same client takes over, message names `tando unlock`) |
| F4-F6 | empty state, missing rollback target, missing `current` link | fix present, not independently re-verified |
| F7 | Caddy not supervised | fix present, not independently re-verified (`Restart=on-failure` drop-in, check before the switch, alert) |
| F8-F11, F13-F17, F19, F20 | probe message, stop before Caddy accepts, stray listener, no soak, history line, prune, clock order, doctor, half-deleted app, rollback message, lease token | fix present, not independently re-verified |
| F12 | slow cold start drops requests | partly: hold = max(15 s, health_timeout); blue/green **dropped tonight** |
| F18 | failed pre-deploy backup marks the release bad | partly: stderr now shown, release still marked bad |
| F21 | pre-flight shares the live data dir | documented (README) |

### CODE-REVIEW.md

| id | finding | state |
|---|---|---|
| B1, B2, T1 | `host add` fails after trusting; every upload to a trusted host fails; no test of that path | fix present, dev (e2e.sh registers with `--yes`) |
| B3, B6, R1, R3, R6, S-B1, S-B2, S-B4-S-B11, S-R4, T5 | see the report | fix present, not independently re-verified |
| S-B3 | `destroy hello` kills `hello-2` | fixed (`app_units` matches the exact name or `tando-<x>.`); independent verifier confirmed `hello-2` survives |
| B4 | trailing `=` dropped by `IFS='=' read` | partly: still in lib/cmd-top.sh:360 and lib/cmd-go.sh:29 |
| B5 | `ls --all` ignores `--watch`, no single JSON | fixed (watch_loop; one `{"hosts":[...]}` object; e2e-cli 9i) |
| R2 | silent wait behind a soaking deploy | fixed (agent `busy` verb; `agent_wait` in lib/deploy.sh says what it waits for; used by env, start/stop/restart, rollback) |
| R4 | `LINES` reused for `-n` | fixed (`NLINES`) |
| R5 | three ways to pass ssh options | fixed: one `ssh_wrapper` script (lib/common.sh) used by `tando top` and by the upload (`rsync -e`); `user@host:port` and `ssh://` refused with the `--port` command |
| S-R1, S-R3 | watch timeout headroom; Caddy 2.6.2 directives | partly; no Caddy 2.6.2 lane in all.sh |
| S-R2 | logs follow survives disconnect | fixed (`tando logs -f` reconnects with backoff and resumes after the last cursor, lib/cmd-logx.sh; e2e-logs) |
| T2, T4, T7 | SKIP counted as success; inverted check; empty file passes | partly |
| T3, T6, T8, T9, T10 | negated ssh checks, ui-test unit block, unused `shipped`, a16 empty = PASS, swallowed timeout | open |
| D3, D5, D8 | TOP.md `-n`; MONITORING.md "30 s" hold; README "flags may come before the command" | D8 fixed (README matches; a flag before the command gets the line reordered); D3, D5 open |
| Duplication (P-1..P-14) | five server copies of the helpers, four ssh wrappers, six time formatters | open: nothing consolidated. Shipped shell was 13,405 lines on 15 Nov, before the Go rewrite (the prototype ceiling was 2,000) |
| docs/*.patch | applied patches kept as docs | all removed (`docs/ease-integration.patch` is gone too) |
| `tando ssh <app>` | no sandboxed shell | built: agent verb `shell` (interactive, or `-- <command>` one-shot; `tando ssh -- <command>` uses this directory's app), with 21 sandbox checks (reported by the server developer) |

### UX reviews (UX-REVIEW.md, UX-REVIEW-2.md)

These were not part of the four reports above. Their blockers are fixed: B-1/B-2 are the same as
CODE-REVIEW B1/B2, and B-4 is fixed because install.sh now ships `templates/`. The "major" items
(M-1..M-8) were not re-checked one by one.

## Real server (14 and 15 Nov 2026)

tando ran on the owner's x86-64 test VPS (1 vCPU, 2 GB, Ubuntu 26.04, sudo-rs, Caddy 2.6.2) next
to a live site that tando does not manage. Numbers are in bench/RESULTS.md, "Real server trial".

- 14 Nov: x86-64 (including the `linux-x64` sharp swap for Next), real Let's Encrypt
  certificates on the sslip.io link and on a custom domain with real DNS, node, static, python
  and next recipes, env, rollback, a refused broken release, jobs, the app shell, destroy.
- 15 Nov, morning: PostgreSQL app with backup, restore and pull; a CI deploy key (deploys in
  38 s; refused a shell, sudo, sftp, forwarding and another app); an alert to a webhook;
  `adopt plan` of the live site (read-only).
- 15 Nov, evening, on the final code: `host setup` over the older install (Caddyfile unchanged,
  Caddy not restarted); doctor prints the Caddy timeouts, memory and client-limit settings as
  hints only; deploy, rollback, `env set` refused by the pre-flight; a frozen app found, alerted
  and restarted by tando-watch in 3.5 minutes; `tando health`, `tando errors`, `alerts history`;
  backup; CI key deploy and revoke; 60 s of load (8,599 requests, 0 failed) through a deploy, a
  rollback and a deploy.
- The exercise found nine bugs, all fixed: five on 14 Nov, then the sudoers rule under sudo-rs,
  `alerts history` without sudo, a missing `shared/data`, and exception names after a log prefix.
- The live site answered every check of the monitor during the work and its process and Caddy
  were never restarted. (One 5 s timeout of 11,175 checks on 14 Nov, cause unproven.)

- 19 Nov: `adopt apply` on the live site (a Next.js shop with real orders), then four deploys, a
  rollback, a refused release, a hard kill, `host setup` three times over the running install, and
  12,000 requests of load. It found four bugs, all fixed (docs/MIGRATION.md, "On the real
  server"). One of them took the site's pages down for about 50 s during the test.

Not exercised on the real server: the container recipe (the image must be built for x86-64, and
this laptop cannot), `adopt undo`, adopting an app with timers, a reboot.

## Still to do on a real server

1. **sslip.io dependency.** Without `apps_domain=`, links rely on the outside sslip.io service and
   on public certificates for those names. Set `apps_domain=` to a domain you control to avoid it.
2. **Loopback ports of other services.** A tando app can reach a port on 127.0.0.1 that belongs to
   a service tando does not manage (the architecture notes).
3. **Cost on a slow core.** About 9 s of server CPU per Next deploy and about 0.5 s per status call
   on the 1-vCPU VPS (the shell version; the Go one is measured only in the test container).
4. **Caddy settings where tando does not own Caddy.** `tando doctor` prints three hints
   (timeouts, GOMEMLIMIT, per-client limits). tando applies none of them by itself there.
5. Walk through docs/MIGRATION.md "Before you start" (read-only) on the VPS, and correct its
   guessed assumptions before `tando adopt plan`.
