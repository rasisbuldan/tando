# Why tando

14 Nov 2026. tando exists and runs end to end on test servers: Ubuntu 26.04 containers with
systemd, on an arm64 laptop. It has not yet run on a real server. Every number below has a label:

- **measured**: from a file in this repository, named next to the number
- **cited**: from someone else's published measurement (none are used below)
- **projected**: arithmetic or a target that nobody has measured

The benchmark files are under `bench/raw/` (v1: 13 Nov, v2: 14 Nov), and the summary is
`bench/RESULTS.md`. The review reports are in `docs/`. Current status: `docs/STATUS.md`.

## The case in one paragraph

A 1 vCPU / 2 GB server runs short of memory and CPU before it runs short of features. Docker with
Kamal keeps about 140 MB of daemon and proxy memory resident, and building on the server takes
about 700 MB of anon memory and 8-10 CPU-seconds per deploy, even for a small Next.js app (both
measured, below). tando keeps only what the server already runs (systemd, Caddy, journald). It
builds on the laptop, uploads changed files with rsync, and starts each release on a spare port
before switching to it. It also gives you a status view and deploy history. Two other approaches
win on specific points: a hand-written Podman quadlet uses less memory, and Kamal had zero failed
requests per deploy in every benchmark run. tando is also new, large for a shell tool, and still
has open security and robustness findings.

## What it does

Status labels: **built+tested** means an end-to-end suite in `test/` exercises the feature and
passed in the developer's latest run (`.tando/all/20261114-124836`). **built, weakly tested**
means the feature works only in reduced conditions, or its test did not run cleanly.
**not built** means there is no code.

| Capability | Status | Where |
|---|---|---|
| Build on the laptop, rsync deltas, pre-flight on a spare port, atomic switch, verify through Caddy, automatic rollback | built+tested | test/e2e.sh |
| Soak after going live: a crash or OOM within 30 s rolls back | built+tested | test/faults e4, e5 |
| Recovery after a reboot, a power loss or a killed activation | built+tested | test/e2e-faults.sh (28 of 28 in the developer's run) |
| Recipes node, next, static, python, container (root Podman) | built+tested | test/e2e-recipes.sh, test/e2e-next.sh |
| Env vars, scheduled jobs, backups and restore, PostgreSQL, SQLite | built+tested | test/e2e-data.sh |
| Per-app sandbox, per-uid loopback firewall, Caddy admin API on a unix socket | built+tested | test/e2e-sec2.sh (it re-runs the reviewer's attack scripts) |
| CI deploy keys confined to one app (tando-gate), GitHub workflow | built+tested on test servers; a real GitHub runner was never used | test/e2e-ci.sh |
| Per-app logs (journald namespaces), request log, audit trail | built+tested | test/e2e-logs.sh |
| Alerts (tando-watch timer) to webhook, Slack, Telegram, ntfy, email | built+tested with local endpoints | test/e2e-alerts.sh |
| `tando top` dashboard | built, weakly tested | test/e2e-top.sh failed at setup in the latest run (app collision with another suite) |
| `tando adopt` (take over a hand-deployed app) | built, weakly tested | rehearsed on a replica only; e2e-adopt could not build its replica in the latest run (port in use) |
| Own domain with HTTPS | built, weakly tested | only with Caddy's internal CA and fake DNS (`TANDO_TEST_RESOLVE`); real Let's Encrypt never issued |
| Default link `<app>.<ip-with-dashes>.sslip.io` | built, weakly tested | never tried with a public IP; depends on the outside sslip.io service |
| `tando go` wizard, `next`, `link`, `open`, `ssh`, `cheat` | built, weakly tested | test/e2e-ease.sh exists but is not in any recorded all.sh run |
| Pre-push hook deploy | built, weakly tested | not tested against a real remote (SECURITY-REVIEW-2 "Not tested") |
| Install script, reproducible release archive | built+tested locally | test/install-test.sh; the real GitHub download URL was never tested |
| x86-64 server | not tested | every run used arm64 containers |
| Zero-downtime switch between two running copies (blue/green) | not built | FAULT-REVIEW F12: only the cheap fix, longer request holding |
| Several instances per app, log forwarding, web UI | not built | SPEC.md §11, docs/LOGGING.md §6 |

## Benchmarks

The setup was the same for every approach: a Next.js 16 standalone app (34 MB release), and
Ubuntu 26.04 containers limited to 2 GB and 1 CPU on an Apple M1 Pro. The format is median
[range] (n). The rival numbers come from v2 (`bench/raw/v2/summary.txt`), measured while the
laptop was heavily loaded (load average 8-41), so v2 wall times are inflated.

The tando column for v2 is still empty. The final tando v2 run waits for a frozen snapshot of the
tree (`bench/run-a-tando.sh`). The **tando v1** column comes from 13 Nov (`bench/raw/v1/summary.txt`,
`bench/raw/v1/a/`). That run used an older tree (`bench/snapshot`) and needed a Next.js wrapper
script. It had no soak and no `MALLOC_ARENA_MAX=2` default. The laptop was mostly idle. **v1 and v2
numbers are not directly comparable.**

| Metric | tando v2 | tando v1 (older tree, other load) | Kamal 2 (v2) | Build on server (v2) | Podman quadlet (v2) |
|---|---|---|---|---|---|
| Idle anon, whole server, 1 app | 78 MB [76-81] (3) | 68.0 MB (`a-extra/mem-one-app-no-ssh.tsv`) | 190 MB [182-190] (3) | 71 MB [70-72] (3) | 51 MB [51-54] (3) |
| Idle anon, whole server, 3 apps | 152 MB [150-154] (3) | 169 MB (`a/mem-3-three-apps.tsv`) | 267 MB [266-271] (3) | not run | 127 MB [127-131] (3) |
| Idle anon, 5 and 10 apps | 225 MB / 411 MB (3) | not measured | not measured | not measured | not measured |
| Cold deploy | 54 s to live [48-91] (3); verified 87 s | 7.1 s (1), plus 3.6 s laptop `npm ci` | 96 s [88-103] (3) | 36 s [35-39] (3) | 72 s [71-75] (3) |
| Warm deploy (one-line change) | 11.4 s to live [6.3-25.3] (9); verified 41.9 s | 5.5 s [5.4-6.0] (5) | 11.9 s [10.3-13.8] (9) | 12.8 s [10.8-16.1] (9) | 8.9 s [7.9-11.7] (9) |
| Bytes to the server, warm | 238 KB [170-435] (9), includes harness polling | 405 KB [402-410] (5) | 11,212 KB (9) | 14 KB (9) | 11,052 KB (9) |
| Server CPU per warm deploy | 3.85 s [2.32-7.63] (9), includes about 1.5-2 s of harness polling | 0.90 s [0.88-0.92] (5) | 1.57 s [1.35-1.77] (9) | 10.4 s [9.9-13.2] (9) | 1.23 s [1.09-1.69] (9) |
| Peak anon during a warm deploy | 118 MB (+41) (3) | not sampled in v1 | 276 MB (+56) (3) | 775 MB (+697) (3) | 113 MB (+50) (3) |
| Peak incl. page cache (sum of slices) | 394 MB [378-428] (9) | 311 MB [254-352] (5) | 598 MB [586-662] (9) | 1,327 MB [1,298-1,457] (9) | 437 MB [377-482] (9) |
| Failed requests per warm deploy, ~10 req/s | 0 [0-2] (9); the 4 failures were client timeouts at host load 70-93 | 2 [2-2] (5), gap 331 ms | 0 [0-0] (9) | 2 [2-2] (9) | 1 [0-6] (9), gap 704 ms |
| Zero failures over 3 deploys under load | yes, 3 of 3 runs (5,655 requests) | no (see row above) | yes (row above) | no | no |
| Rollback time / failed requests | 1.5 s [1.0-8.3] (9) / 0 (3) | 0.8 s (3) / 1 [0-2] (2) | 3.2 s [0.9-3.6] (15) / 0 (6) | none | 0.8 s [0.8-1.2] (6) / 4 [0-5] (3) |
| Broken release (health 500) | went live with init's `health = /`; with `health = /api/version` old kept, 0 failed, 37 s (3) | old kept, 0 failed, reported after 34.3 s (1) | old kept, 0 failed, 39.9 s (3) | no gate | went live: 360 failed (3) |
| Status query, server CPU | `tando ls` 68 ms [42-400] (30); 224 ms with 10 apps | `tando ls` 15 ms [15-37] (10) | `kamal details` 63 ms (9) | - | `podman ps` 55 ms (9) |
| tando-watch CPU per minute | 260 ms [185-423] (3) | not measured | - | - | - |
| Empty VM to first live app | 121 s [96-275] (3); `tando go --yes` 89 s (1) | not in v1 | 175 s [173-277] (3) | 88 s (1) | 292 s (1; apt 274 s) |
| Commands / hand-written files | 3 / 0 (`tando go`: 1 / 0) | 3 / 0 (README quick start, counted, not timed) | 3 / 2 | 7 / 2 | 7 / 3 |

There are other measurements outside the benchmark harness. They come from the developer's own
test runs, not from an independent check:

- **Empty VM to a live link.** test/e2e-bootstrap.sh took 242 s, with the laptop loaded
  (`.tando/all/20261114-124836/e2e-bootstrap.log`). That breaks down as 125 s to start the VM,
  72 s for `host setup` and 45 s for the first `up` including the Node install.
- **Zero failed requests at about 10 req/s.** test/e2e.sh check 18 used the small hello app. It
  had 0 failed requests during deploy (46 requests), rollback, env set and restart. The same log
  has container and python deploys under load with 0 failed. This contradicts v1's "2 per
  deploy", but it is a different app (not Next.js), a different load generator and a newer tree.
  v2 settles it for the Next app: no HTTP errors in 9 warm deploys, 3 rollbacks and three
  runs of 3 deploys in a row; requests are held for 0.5-10 s instead. The only 4 failures were
  5 s client timeouts at host load 70-93.

## Where the rivals are better

- **Zero failed requests (Kamal).** Kamal had 0 failed requests in every warm deploy and rollback
  (v2, n=9 and n=6). tando v1 dropped 2 requests per deploy. tando now holds requests in Caddy
  while the app restarts. It has no blue/green switch, and an app whose start takes longer than
  the hold period still drops requests (FAULT-REVIEW e10, fixed only by a longer hold).
- **Memory (Podman quadlet).** The quadlet used the least memory measured: 51 MB for one app and
  127 MB for three (v2). tando v1 used 68 and 169 MB, partly because of glibc Node against Alpine
  Node (46 MB against 32 MB per app, v1). `MALLOC_ARENA_MAX=2` brought that to 34 MB
  (`a-extra/mem-one-app-arena2.tsv`), and it is now the default. It still does not beat the
  quadlet: 78 against 51 MB with one app and 152 against 127 MB with three (v2). Per extra app
  they are even; the gap is tando's Caddy (23 against 10 MB).
- **Bytes (build on server).** Uploading the source sends 14 KB, against tando's 405 KB (v1).
  The cost moves to the server: 10.4 CPU-seconds and +697 MB anon per deploy.
- **Isolation.** A container has its own filesystem and its own runtime. tando apps share the
  host's Node and the host's loopback. They are separated by systemd sandboxing and nftables rules
  that the reviewers have already broken once (see below).
- **Maturity.** Kamal and Podman have years of production use. tando was built in one night by
  several developers, and no real server has run it.
- **Portability of the artefact.** An image runs anywhere. A tando release depends on the server
  having the right runtime, and native npm modules are swapped for the server's architecture at
  build time.

## When to choose something else

- You want a deploy that drops no requests, and the server has 4 GB or more: Kamal. The roughly
  140 MB resident cost of Docker plus kamal-proxy (`bench/RESULTS.md` §1) is about 3.5% of 4 GB.
- The app ships as an image anyway and you can live without a health gate: a Podman quadlet.
- You want a web panel, one-click databases or a team-facing UI: Coolify or Dokku. Neither was
  measured here (Dokku installed in 5 m 34 s, `raw/v2-trial-dokku-install.log`, nothing more).
- The server runs code from several mutually untrusting parties: no tando. Its isolation is policy
  on one kernel, and its review history is short.
- Production use today, before the "before the first real server" list in `docs/STATUS.md` is
  done.

## Known weaknesses

Taken from the review reports in `docs/` and checked against the code on 14 Nov. The details are
in `docs/STATUS.md`.

**Security (SECURITY-REVIEW-CI.md, SECURITY-REVIEW-2.md).**

- F1-F11 of the first review were independently re-tested and found fixed by the second reviewer,
  except F6, which was partly open.
- The second review found that a compromised app was not contained (N1-N3, N8, N9) and that a
  malicious server could run code on the admin's laptop (N4). For N1-N15 the fixes are in the
  code, and the developer's test/e2e-sec2.sh re-runs the reviewer's attacks. No independent
  reviewer has re-verified them.
- Still open, or only partly fixed:
  - Jobs of **adopted** apps still get no socket-bind limit (`server/tando-adopt` `sync_jobs_one`
    strips every `SocketBind` line). This is N1 for adopted apps.
  - The N8 journal-flood check came back inconclusive in the latest run (SKIP).
  - Container apps run under root Podman without tando's own sandbox (docs/ARCHITECTURE.md
    "Residual").
- `tando.conf` from a repository chooses the build command, the app and the server. tando asks
  before deploying to a different target (N15), but a build runs the repository's code.

**Faults (FAULT-REVIEW.md).**

- 27 of 76 scenarios failed in the review. Fixes for 19 of the 21 findings are in the code, and
  the developer's e2e-faults run passed all 27 plus the baseline (28/28). Nobody has re-run them
  independently, and the other 48 scenarios were not re-run (`--all` takes about two hours).
- Partly fixed: F12 (request holding instead of blue/green) and F18 (a failed pre-deploy backup
  still marks a good release bad).

**Code (CODE-REVIEW.md).**

- `tando destroy hello` still stops and deletes the unit of an app named `hello-2`. The S-B3 fix
  is incomplete in `server/tando-agent` `app_units`, and e2e check 19l failed in the latest run.
- Also open: `ls --all` ignores `--watch` and does not produce one JSON object (B5), a silent wait
  behind a soaking deploy (R2), the `LINES` name clash (R4), and several test checks that cannot
  fail (T3, T6, T8-T10).

**Size and duplication.**

- The ceiling in PROTOTYPE.md was about 2,000 lines of shell. CODE-REVIEW.md counted about
  11,400 product lines at its snapshot (01:50 UTC). `wc -l` on 14 Nov 13:55 WIB gives
  **13,405** lines:
  - bin/tando and lib/*.sh: 6,599
  - server/tando-*: 6,492
  - install, uninstall and release scripts: 314
- The completions and lib/help.txt (329 lines) come on top of that.
- CODE-REVIEW estimated 1.9-2.6k duplicated or dead lines:
  - five server programs, each with its own `die`, `valid_app`, `now`, `load` and `save`
  - four ssh wrappers on the client
  - six time formatters

  None of that has been consolidated.
- The server side that handles hostile input is still shell. SPEC.md §16 had recommended Go for
  it.

**Never tested:**

- a real Let's Encrypt certificate
- a real x86-64 VPS: every run was arm64, and the 1 vCPU there is slower than one M1 core
- real DNS: only fake resolution through `TANDO_TEST_RESOLVE`
- the sslip.io default link against a public IP
- a real GitHub Actions runner
- the GitHub release download
- `adopt` on the owner's real server: only the replica, whose details are partly guessed
  (docs/MIGRATION.md "Assumptions")
