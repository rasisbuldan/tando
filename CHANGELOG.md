# Changelog

All notable changes to tando. The version is in `VERSION`; releases are tagged `v<version>` and
built by `scripts/release.sh` (see docs/RELEASING.md). Format: one section per release, newest
first, grouped by area.

## Unreleased

- Fixed: a deploy whose server side was killed (or whose server restarted) after it took the
  upload lease and before the release got its id left the lease behind: the next deploy waited
  30 s for it or needed `tando unlock`. The client now gives the lease back when begin or activate
  fails, and recovery (tando-watch's minute, the boot, a queued deploy) clears a lease with no
  release id whose holder is gone: one taken before the server restarted, or whose activate no
  longer runs. A lease an upload is still writing into is never cleared.

- Added: fingerprinted assets of the last releases stay reachable. After a deploy, a browser still
  holding a page of the old release (or a CDN, or a slow client mid-load) asked for the old
  release's hashed files (`/_next/static/<build>/...`, `/assets/index-<hash>.js`) and got a 404,
  which broke the page until reload (measured before: HTTP 404 on a Next.js app and on a static
  site). Now every release's fingerprinted files are hard-linked into `/opt/tando/apps/<app>/assets/`
  (laid out like their URLs, no second copy on disk), Caddy answers a request for such a URL from
  there first with `Cache-Control: public, max-age=31536000, immutable` and hands a miss to the app
  (or the static `file_server`). What counts: the Next recipe's `.next/static`, the new key
  `assets = <dir>[, <url prefix>]` (any recipe but a container, whose files are inside the image),
  and for a static site the first of `assets`, `_astro`, `static`, `_next/static` whose files all
  have a hash in their names (`index-DiwrgTda.js`, `main.3f2a1c0b.js`); `assets = off` turns it off.
  Nothing else gets a header: HTML and every path that is not under such a prefix stay exactly as
  the app sends them, and an app that sends its own `Cache-Control` for its fingerprinted files (seen
  in the pre-flight on one of them) keeps it. The files are linked before the switch and removed
  by `prune` only when no kept release lists them (a per-release list in `assetlog/`), so they go
  with the releases tando already keeps; a rollback links its own again; a kill during the link
  leaves files nobody lists (the next prune takes them), never a release without its files.
  Cost: the link took 0.05 s for 12 files, 0.1 s for 300, 0.2 to 0.6 s for 1500 on the test server;
  disk is nothing (hard links); the deploy's copy, pre-flight and switch phases did not get longer
  (switch 0.4 to 0.5 s against 0.6 to 2 s before, on a busy machine). Served by Caddy instead of
  the app's Node process, a 229 KB script on one CPU: 5275 requests/s at 0.15 ms of Caddy CPU
  each, against 685 requests/s with 0.56 ms of the app's CPU and 0.53 ms of Caddy's (identity), or
  125 requests/s with 6.5 ms of the app's CPU when the client takes gzip and Next compresses it.
  Containers: not supported in v1 (`assets` is refused).
- Added: scheduled jobs mature. (1) `job.<name>` takes cron as well as systemd: `*/15 * * * *`,
  `0 9 * * mon-fri`, `@daily` (lists, ranges, steps, month and weekday names), translated on your
  machine to the exact OnCalendar text or refused with what to write instead (both day of month and
  weekday, `5/15`, wrap-around ranges, `@reboot`, `?` `L` `W` `#`); every schedule is checked before
  a deploy (`up`, `--dry-run`, `configure check`). `tando jobs` shows what you wrote, the next three
  run times by the server's clock and the server's time zone, how each job's last run ended (`ok`,
  `exit 3`, `timed out`, `killed (memory)`) and how long it took. (2) `job_spread` (default 15 s,
  `RandomizedDelaySec=`: 20 apps' hourly jobs no longer start in the same second) and `job_missed =
  run|skip` (default run: a run missed while the server was off is made up once, as before; skip
  drops it), each also per job (`job.<name>.spread`, `.missed`); a job still running at its next
  time is not started twice (now tested and documented). (3) `tando jobs log <name> [-n N]` shows the
  output of the last runs from the journal by cursor; the last 50 runs of each job (time, result,
  duration, never output) are kept on the server (`jobhist/`) for when the journal has rotated.
  (5) `tando jobs pause <name>` and `resume`: the timer is off until resumed, across deploys,
  rollbacks and reboots. Not done: retries of a failed run. The job units gain two root hooks
  (`ExecStartPre`/`ExecStopPost`, `job-begin`/`job-end`) that write the history; a hook that fails
  never changes the job's result.
- Fixed: a command that failed on the server with "Connection refused" in its own message (a
  `pg_dump` with PostgreSQL stopped, say) was reported as "cannot reach <host>: connection
  refused", as if ssh had failed. Only ssh's own "connect to host ... Connection refused" says
  that now.
- Fixed: tando-watch's minute now recovers a rollback that died after it wrote its progress file
  and before its first state write: the progress said "running" for ever and the rollback had no
  history line until the next command that changes the app.
- Added: workers. `worker.<name> = <command>` in tando.conf runs a long-lived process beside the web
  one (a queue consumer, a websocket server, a scheduler): its own unit
  `tando-<app>_worker-<name>.service`, as the app's user, with the app's sandbox, env and release,
  no port. `worker.<name>.memory` (default: `memory`, counted in the app's slice and the doctor's
  memory caps) and `worker.<name>.stop_timeout` (seconds after SIGTERM, default 30). Workers belong
  to the release: at a deploy they change once the new web process passed its check (the old ones
  stop and finish, then the new ones start; never both), the soak watches them, and a worker that
  does not stay up rolls the deploy back with the old workers running again; rollback, stop, start,
  restart, env set, backup restore, destroy and a reboot include them, and recovery after a kill at
  any point brings back exactly the serving release's. A worker that exits is restarted with a
  backoff, never stops the web process, and one that keeps exiting shows in `tando status` and
  `tando ls` and fires the `worker.<name>` alert (`worker=off`). `tando logs --worker NAME`.
  Refused for static sites and (for now) containers; at most 20, names like jobs', not a job's
  name. No `count` yet. An app without workers deploys as before (one glob per recover).
- Tests: `test/e2e-workers.sh` (new suite); the fault matrix has a kind `worker` (invariant 11:
  the workers that run are the serving release's; two cells in `e2e-matrix-quick`).

- Changed: `tando db studio` reads only the app's own tables. The sidebar no longer has "system
  schemas"; the table list, structure and rows never show or serve pg_catalog,
  information_schema or pg_toast (a request for one of their tables is a 404). In the SQL
  editor a statement that reaches a system table or view (`pg_roles`, `pg_stat_activity`,
  `information_schema.tables`, ...) by any route (quoted, in a CTE or subquery, through a view of
  the app's, after `SET search_path`, inside `EXPLAIN`), a catalog-reading function (`pg_*`,
  `current_setting`, `has_table_privilege`, `obj_description`, `txid_*`, `lo_*`, ...), a
  `regclass` cast or `SHOW ALL` is refused before it runs, with a message that names it. It is
  checked by name in the statement's text and by the server's own plan of the statement
  (`EXPLAIN (VERBOSE, FORMAT JSON)` in the same read-only transaction, about 0.3 ms per
  statement); no new dependency. Limits: a function the app defined that reads a catalog inside
  is not seen; an app column or table named `pg_...` is refused too (docs/COMMANDS.md).

- Added: `tando env log` (an env changelog). Every `env set`, `env unset` and `env import` (and the
  `DATABASE_URL` tando writes for `database = postgres`) adds one entry on the server: when, who
  (the audit log's identity), the verb, an optional `--note "text"` (one line, 200 characters) and
  three lists of key NAMES: added, changed, removed. Never a value, a length or a hash; a change
  that alters nothing writes nothing; a change the app's health check put back is not logged. The
  log is `env.log` in the app's directory (root 600, written whole and renamed like the env file,
  the newest 200 kept, removed with the app). `tando env log` prints `[time] [note] >` per entry,
  newest first (at a terminal you pick one and its page opens; piped it only prints), `env log 3`
  opens entry 3, `--json` gives names only. Read with the admin's login like `env ls`; a CI deploy
  key is refused (the gate lets a key run only deploy verbs, so the new verb needed no change).
- Fixed: a deploy's tando.conf settings changed the live app before its release existed:
  `configure` wrote the new memory, path, limits, hold and the like into the unit file and Caddy's
  site at once, and a deploy refused in pre-flight (or cut off, or whose upload failed) left them
  there, under the old release. They now wait on the server (`/opt/tando/apps/<app>/confs/<id>`,
  the id printed by configure and handed to `activate` by the client) and are applied at the
  switch; a deploy that does not go live leaves app.conf, the unit file, the site and the job units
  exactly as they were. Every setting now belongs to its release (`start/<id>` holds all of them,
  not only start and health): a rollback, and the automatic one after a failed check, bring back
  the older release's memory, path, limits and jobs with its code. Domains in tando.conf and the
  database's role settings still apply at configure.
- Fixed: two clients deploying the same app with different tando.conf files: the second one's
  configure, landing while the first was uploading, gave the first one's activation its start
  command and health check (pre-flight then failed, or the wrong settings went live). Each
  activation now runs with the settings its own configure staged, against what the one before it
  left. An activation without a settings id (an older client, a deploy key) takes the last
  configure's, as before.
- Fixed: job units that could not be written (a full disk) were reported as done: the unit files
  could be installed cut short, and a deploy's end was recorded with half its jobs old. Each file
  must be complete before it is installed; a failure leaves the operation's end unfinished, and
  recovery (tando-watch's minute, the next command) writes the jobs again.
- Fixed: tando-watch and `tando status` tested an app's lock by taking it exclusively for an
  instant: two probes at once saw each other as "busy" (a recovery skipped for a minute, a deploy
  told it waits when nothing held the app). They (and the agent's `busy` check) now try a shared
  lock: probes never see each other; a command's own try in that instant only waits for it to drop.
- Fixed: after the clock was set back, pre-deploy (and other) backups were pruned by name: backups
  named from the future kept their place and each new one was deleted at the next backup. Backups
  now carry their order (`seq` in meta) and are pruned by it.
- Fixed: a deploy queued behind another operation for the server's hour gave up as "interrupted
  before it started (activate was cut off, or its server restarted...)"; it now says it waited an
  hour for what, and that nothing was changed. The client waits as long as the server reports the
  release queued (its deadline counts from the end of the queue), instead of giving up after
  about 17 minutes while the release could still go live later.
- Tests: the fault matrix's versions alternate their memory, max_conns and a job's schedule too
  (the checker compares the unit file, the site and the job timer with the serving release); a
  `race` action (a second client's configure at the point); new cells g-j in `--cells`.

- Fixed: between an app's site being set up and its first release going live (a first `tando up`
  still running, or one that failed and left nothing live), a request to its address waited 15 s
  and got an empty 502 (and scanners that find a new certificate in the public logs filled the
  error rate). It now gets an instant 503 "<app> is being deployed" page with `Retry-After: 10`.
  Caddy checks for the app's `current` link on each request, so the page goes away by itself when
  the release switches in, adds no Caddy reload and no time to a deploy, and never shows for an
  app that has a release (a later failed deploy still serves the old one).
- Security (from an outside review): `domain =` in tando.conf gets the checks of `tando domain add`
  on the server (not under the server's `apps_domain`, not another app's domain or its www twin),
  and the client takes lowercase host names only (`tando.conf:N: not a domain name: ...`) before
  anything is looked up or sent.
- Security: with `tls=internal` and `domain_tls=auto` (or the other way round) an app's own domains
  no longer get Caddy's local CA with its link: the site is a snippet imported by two site blocks,
  each with its own TLS.
- Security: pg_dump and pg_restore (backups, restores) run in a scope of the app's slice: the app's
  memory limits, 512 MB at most, and oom_score_adj 500 like the app's units, instead of unbounded
  beside the ssh session (about 8 ms more per dump or restore). The SQLite snapshot names its files
  relative to the data directory instead of quoting the path into a sqlite3 command.
- Security: apps cannot reach the cloud metadata address (169.254.169.254, fd00:ec2::254; refused
  per app uid in table `inet tando`). An app that needs the instance's credentials cannot get them
  this way any more.
- Security: metrics samples are root's (/var/lib/tando/metrics 700, files 600; the directory is
  closed again on the next sample): an app could read every other app's memory, CPU and restarts.
  `tando top` reads them through sudo.
- Security: offsite with `encrypt=off`: a backup whose manifest is missing from the bucket is
  refused on fetch (the manifest's SHA-256 is the only check a plaintext object has).

- Added: `tando db studio [app]`: a small web page in your browser for the app's PostgreSQL
  database: the tables (rows, sort, structure, a value in a side panel) and a SQL editor
  (Cmd/Ctrl+Enter, cancel, a result tab per statement, the error's position, CSV, an encrypted
  history in the browser), light and dark. Read-only: each run is one read-only transaction whose
  snapshot is taken before your statements and which is always rolled back; statements that are
  not queries are refused before they run. Writes stay in `tando db psql`. One studio shows one
  app's database; without an app (and outside a project) it lists the apps that have one and asks.
  The server listens on no network port: the page goes through the command's own ssh connection
  to a unix socket; the database password never leaves the server; the link works once. It ends
  with Ctrl-C, Stop, 30 minutes unused or 45 s without the laptop, and leaves nothing running.
  The studio's database process is held small (2 MB per sort or hash, one process, no JIT) and at
  the lowest CPU priority, waits at most 2 s for a lock, stops a statement at 30 s (10 s when
  browsing), and does not connect when the app has fewer than 2 of its connections free. At most
  2 per server; CI deploy keys cannot open one. A new server program, `tando-studio` (srv/studio,
  about 7 MB per CPU type), installed by `tando host setup`; `tando doctor` checks it and lists
  open sessions (docs/COMMANDS.md "tando db studio", docs/ARCHITECTURE.md).
- Changed: every app's database is closed to PUBLIC (CONNECT, TEMPORARY) at each deploy and
  `tando host setup`, not only when it is created: a database left open by an older setup or by
  hand is closed again.
- Changed: `tando open` uses the shared `open_url`.
- Studio, found by opening it in a browser: table browsing headed every wide column "left",
  type text (now the table's own names and types); a link to the page followed from another
  site (a web terminal, a chat page) was refused with a line of JSON (a plain top-level link to
  the page is now served; every data request stays same-origin only); the SQL editor opts out
  of writing-assistant browser extensions.
- Tests: `test/e2e-studio.sh` (docs/TESTING.md), Go unit, fuzz and live tests of srv/studio,
  `bench/run-studio.sh`.
- `tando jobs run` always shows the job's output: a job that ended within milliseconds could be
  stored by the journal without its run id and came back empty; a run by hand is also no longer
  refused after the job failed several times in a row.
- New: docs/CONFIG.md lists every `tando.conf` key (type, default, unit, meaning, example), and
  `tando help conf` prints a compact version. `tando init`'s file, docs/COMMANDS.md and README.md
  point at them (the README section they named no longer existed). test/ui-test.sh reads the keys
  from the client's parser and the server's `configure` and fails when the doc, the help or either
  program disagree. The developer notes that opened docs/COMMANDS.md moved to docs/DEV-NOTES.md.
- Changed: `tando doctor` shows the programs that differ from the client's (after a client upgrade)
  as one row, "N of M programs differ from the client's X: tando host setup <host>", instead of up
  to nine; `tando doctor --verbose` lists each.
- Fixed: a name under a two-level public suffix (`example.co.uk`, `example.com.au`, `example.co.id`)
  was taken for a sub-domain and got no `www` redirect. Client and server share a list of the common
  suffixes (not the full Public Suffix List); `tando domain add` says which www mode it chose and why;
  `--www` overrides it.
- Changed: `tando up` on a new app says when no notifier is set, with the command to add one;
  `tando status` shows the lines of the last 24 hours first and the journal's size after them (a new
  app's pre-allocated journal read as "8 MB of logs").

- Fixed: deploys, rollbacks, env changes, stop and start end right after a crash, a failed command
  or a restart at any point (found by the fault matrix below; docs/TESTING.md, "Fault matrix"):
  a crash between the switch of `current` and the state write no longer brings the previous
  release back later (or puts a refused one live); a new release that cannot be started after the
  switch (a container that does not come up, a site Caddy refuses) is rolled back instead of being
  left live as "failed"; a rollback, and every recovery, puts back the start command and health
  path of the release that serves (a rollback across a changed `health =` no longer fails, and
  `tando.conf` changes of a deploy that never got activated no longer reach the live app); a
  recovery never starts an app that was stopped, and a deploy to a stopped app that does not go
  live leaves it stopped; a release reserved by an activation that never ran is given up (no more
  "queued" for ever, not offered for a rollback); a result is never left "running" and history
  has its line exactly once; `tando env set`, `stop`, `start` and `restart` cut off half-way are
  finished by recovery (a new env is checked and reverted if it breaks the app); a dropped ssh
  session no longer stops `backup restore`, `destroy`, `env set` or a rollback half-way; an
  activation and each long step in it (image pull or load, venv build, database dump, copy) have
  an upper bound, and so has the recovery after it; a down app that runs again after a reboot gets
  its link back; unit and Caddy site files are never installed empty or cut short by a full disk;
  an internal arithmetic error no longer ends a verb with success; a backup just taken is never
  pruned for its name after the clock was set back.
- Tests: `test/e2e-matrix.sh`, the fault matrix: a test-only fault hook in the agent (inert
  without root's test markers) puts one kill, failure or reboot at every point an operation passes
  (deploy, rollback, stop, start, restart, env set, recovery itself), and one checker asserts ten
  invariants after recovery. `e2e-matrix-quick` in the full tier, `e2e-matrix-n1` to `n4` (all of
  it, every app kind) nightly.
- Fixed: requests could get 502 at once while an app restarted, despite the request hold, after a
  Caddy reload had failed: Caddy keeps the servers it had started of a configuration it could not
  load, serving it without the hold, until it restarts (seen as A7e and A9e failing in
  test/e2e-adopt.sh). tando now refuses a Caddyfile that listens on a port another program holds
  before reloading (site changes and `tando adopt site`), restarts Caddy after a failed reload when
  the previous file loads, and `tando doctor` reports a failed reload since Caddy started
  (`caddy reload`) with the fix. A reload also ends the requests Caddy holds: tando's site changes
  now wait while an app restarts until it listens again. docs/COMMANDS.md says exactly what the
  hold covers.
- Tests: the stand-in app of `test/e2e-adopt.sh` keeps connections alive again; the suite adds a
  kept-alive client, POSTs during a rollback (held, stored once), a reload during a restart, and
  the failed-reload cases.
- Added: native modules that are not per-platform npm packages now run on the server without a
  container build (the measured container build is about 3 times slower under emulation; this takes
  about half the time of it). After the platform-package swap tando: accepts and trims packages that
  carry several platforms' binaries inside them (`prebuilds/`: better-sqlite3 13, bcrypt 6, argon2,
  bufferutil, utf-8-validate; the guard no longer refuses them as it did); restores such a package
  from your `node_modules` when Next's standalone output pruned the server's binary; downloads the
  server's binary for packages that fetch it at install with `prebuild-install` or `node-pre-gyp`
  (sqlite3, canvas, bcrypt 5), from the https host the package's own package.json declares, no
  redirects, a validated archive, never running the package's scripts (output: `not verified by
  the lockfile`; the glibc the binary needs is read, and checked against the server's once
  `tando-agent info` reports it); and stops before upload, naming the module, for packages that
  only compile on Linux (node-pty), with `tando ci github` as the way out. `@parcel/watcher`'s
  `-glibc` packages are swapped; `@tailwindcss/oxide` gets its Linux binary when only its
  WebAssembly fallback was installed. The deploy box and `--dry-run` list what was done per module;
  a Prisma note is printed when Prisma is in the release. docs/CROSS-ARCH.md has the coverage table,
  the trust statement and the timings.
- Security: a project `.npmrc` (it can carry a registry token) is never copied into a release for
  any recipe, and the guard refuses a release that has one.
- Fixed: platform-specific npm packages nested at any depth (Next's own sharp under
  `node_modules/next/node_modules`, when the project asks for another sharp version) are swapped for
  the server's platform in their own `node_modules`; before, only `node_modules/<pkg>` and
  `node_modules/@scope/<pkg>` were, and the guard then refused the deploy. Each swapped package is
  one line in the deploy box. More families by the same rule (`os`/`cpu` in package.json): the
  Next compiler, esbuild, Rollup, Lightning CSS, a Linux laptop of another CPU (docs/CROSS-ARCH.md).
- Security: the version of a swapped package must be exact (no range, tag, URL, git or file spec)
  and its name valid before `npm pack` runs (with `--ignore-scripts` and `--`). The fetched tarball
  is checked against the sha512 in package-lock.json/npm-shrinkwrap.json (nested paths too),
  yarn.lock (v1) or pnpm-lock.yaml; a mismatch stops the deploy. Without a lockfile tando can read
  the box says `not verified` and why. `.tando/cache` keeps each tarball with its sha512 and fetches
  again when the file changed.
- Fixed: the Next.js pre-flight loads sharp as Next resolves it (from Next's own directory, as the
  app's user in its sandbox), and every other copy in the release; the error names the copy that
  failed. Before, it tried the first top-level copy only: a broken nested copy passed when the image
  cache was warm, and a top-level copy that Next traced without its code (a devDependency of
  another version) failed a good release.
- Changed: when the guard refuses native code for another platform it lists every file, why tando
  could not swap it, and what to do (nested copies, `images: { unoptimized: true }`, Prisma
  `binaryTargets`, `tando ci github`); new docs/CROSS-ARCH.md.
- Added: `tando deploy --dry-run` builds and stages, swaps, and prints the file count, the size,
  the largest directories and what was swapped and verified; it uploads nothing, takes no lease,
  installs nothing and creates no app (it reads the server's platform and whether the app exists).
- Changed: `tando deploy` in a fresh clone (dependencies in package.json, no node_modules) stops
  before anything else with the lockfile's install command (`run npm ci first`, pnpm, yarn, bun);
  `tando up` and the pre-push hook's temporary checkout still install them.
- Changed: `tando init --yes` prints the lines it added to next.config. Outside a terminal (CI, a
  log) each deploy step prints a line when it starts. The stage line shows the release's size;
  over 50 MB the deploy names the three largest directories.
- Tests: fixture trees for the swap and the guard in `test/native-test.sh` (run by ui-test);
  e2e-next deploys a project with Next's sharp nested (dry run, deploy, broken nested copy);
  e2e and e2e-cli cover the dry run, the start lines, the size line and the fresh-clone stop.
- Security: a deploy no longer finds "another upload" by command line. The agent looked for any
  process whose command line had `apps/<app>/incoming` in it (`pgrep -f`) and, taking over a
  stale upload, killed every such process as root (`pkill -KILL -f`): any app could block every
  deploy of another app by putting that text in its own command line, and the admin's shell or
  editor with it was killed. An upload's receiver is now the rsync process whose executable is
  rsync, whose user owns the app's `incoming/` and whose working directory is it (read from
  `/proc`), or the deploy key's confined unit as before. No change for clients.
- Security: job units are named `tando-<app>_job-<name>` (was `tando-<app>-job-<name>`). With the
  old names, a deploy or `host setup` of app `foo` deleted the job timers of app `foo-job`, and
  app `x-job-y`'s own service had the name of job `y` of app `x`. `tando host setup` (and the next
  deploy) renames each app's units, recognising its own by the runner line in the unit file, and
  keeps each timer's last run. Destroy, adopt, `tando jobs`, `jobs run`, `tando logs` and the job
  alert use the new names; job output from before the rename stays in the journal under the old
  unit name.
- Added: `job_timeout = <seconds>` (default 3600) and `job.<name>.timeout`: a job that runs longer
  is stopped by systemd and reported as timed out (`tando jobs`, `tando jobs run`, the `job.<name>`
  alert). Before, a hung job ran for ever and was never alerted. Existing jobs get the one hour
  default with the next `host setup` or deploy: a job that needs longer needs `job_timeout`.
  `tando jobs` shows the last run whether its timer or `tando jobs run` started it (it showed the
  timer's only, so a run by hand stayed "never").
- Security: names that are another app's or tando's own are refused for a new app: `d-<x>` and
  `m-<x>` (app x's deploy user and settings group), `<x>-backup` (app x's backup unit), `rx-<x>`,
  `adopt-<x>`, `unadopt-<x>`, and `watch`, `host`, `metrics`, `offsite`, `recover`, `firewall`,
  `down` (tando's units). Apps that exist keep working; the agent kills or adds to the settings
  group only a deploy user `tando-d-<app>` that tando-gate made (not app `d-<app>`'s user), and
  keeps an app's settings root's when `tando-m-<app>` is app `m-<app>`'s user group. Destroying a
  container app no longer removes another app's `run/<app>-<port>.env` files (`foo` took `foo-2`'s).
  The upload receivers' old fixed unit name `tando-rx-<app>.service` is app `rx-<app>`'s service:
  while such an app exists neither the agent nor tando-gate counts it as an upload or stops it.

- Changed: `tando adopt apply` refuses to start when the hand-written Caddy site does not hold
  requests while the app restarts (no `lb_try_duration`), and `tando adopt plan` says what that
  costs and which command adds it. On the first real server 36 requests got 502 because the hold
  could only be added after adoption. `--accept-502` adopts without it.
- Added: `tando adopt site <unit> --apply` works before adoption and adds the hold only (the
  request log comes after adoption); the copy of the Caddyfile is then kept in
  `/opt/tando/adopt/<unit>/`. Several `reverse_proxy` lines to the port that each have the hold
  count as held.
- Tests: `test/e2e-adopt.sh` adopts a synthetic hand-deployed app on a test server under a request
  loop: plan, the refusal, the hold before adoption, apply, deploy, rollback, the request log,
  undo, and the same adoption without the hold as a control.
- Added: limits on each app's PostgreSQL role, so one app cannot take the shared database from the
  others: `db_statement_timeout` (30s), `db_idle_tx_timeout` (5m), `db_temp_limit` (1G) in
  tando.conf, `off` for none. Set by the next deploy and by `tando host setup`. A statement over
  30 s is now cancelled: a long migration sets `SET statement_timeout = 0` for itself
  (docs/COMMANDS.md, "Database limits"). Backups, restores and `tando db psql` are not cut.
- Added: `tando db` shows the database's size, connections and limits.
- Changed: the PostgreSQL major version is recorded (`postgres_version` in host.conf) and kept; a
  newer one installed beside it is not picked up, `tando doctor` reports it, and
  `host setup postgres_version=N` moves the record after a manual upgrade (runbook in
  docs/COMMANDS.md, not rehearsed). `host setup postgres=yes` restarts PostgreSQL only when its
  settings changed.
- Added: tando's own drop-in keeps the PostgreSQL postmaster out of the OOM killer's reach
  (-900, as the Ubuntu packages already set); `tando doctor` reads the live values.

- Added: alerts for scheduled jobs. A job that fails (exit status, signal, its timeout, the memory
  limit) fires `job.<name>` for its app, one message per failed run, resolved by its next success
  (`tando jobs run <name>` counts); a job removed from tando.conf takes its alert with it.
  `job=off` turns it off.
- Added: alerts for PostgreSQL, on hosts where an app has `database = postgres`: `db_conns` when
  an app's role holds 80% of its connection limit for 5 minutes (`db_conn_pct`, `db_conn_for`; the
  limit is read from the server), host `postgres` when the server does not answer or its slots
  are 80% taken. The database's size counts as the app's disk use (`disk`, `app_max_mb`) and is
  shown with the connections by `tando status <app>` and `tando health <app>`.
- Added: `tando alerts backup-ping [off]`: a URL that is requested once after the daily backups,
  only when every app's backup worked (and, with offsite copies on, reached the bucket). An outside
  service notices the day it is missing. `tando alerts` shows the last request or why none is sent.
- Changed: `tando doctor` warns (no failure) while a server with apps has no outside heartbeat,
  with the command to set one. docs/MONITORING.md has a section "From outside".
- Added: `tando backup offsite test` and `set` report whether the bucket's key can replace or
  delete an object it wrote (`overwrite`, `delete` rows; `status` shows the last result).
- Changed: a key that may not delete, or a bucket with a lock, no longer fails `backup offsite
  set` and `test`: it is the safer setup. tando then prunes nothing in the bucket and says so
  (`sync`, `status`, `doctor`); docs/BACKUP.md, "Backups the server cannot erase", has the setup
  with a lifecycle rule for R2 and S3 (from the providers' documentation, not verified on a real
  bucket).
- Added: a release command. `release = <command>` in tando.conf runs on the server once per deploy
  (database migrations), in the new release, as the app's user with its environment and sandbox,
  after pre-flight and the pre-deploy backup, before the switch. A failure or a timeout
  (`release_timeout`, 300 s) fails the deploy with nothing switched; the message names the
  pre-deploy backup. Its own phase in the deploy box and in `tando history` (`RELCMD`); its output
  in `tando logs --deploy <id>`. tando never restores the database, and `tando rollback` does not
  undo a migration (docs/COMMANDS.md, "The release command"). Not for static sites and containers.
- Tests: tiers (`test/all.sh --tier check|quick|full|nightly|weekly`), `test/check.sh`, suite selection
  by changed files (`test/suites.map`), fault scenarios in shards; the full tier takes about 16 minutes
  on the reference laptop (was about 2 hours). AGENTS.md says what to run when.
- `host setup`: apt is tried three times and waits for the package lock.
- CI on GitHub: two jobs per push; the long tiers run by hand only.

## 0.1.1 - 2026-11-19

Found by adopting a live app on a real server (docs/MIGRATION.md, "On the real server").

- Added: `tando adopt site <app> [--apply]` shows what a hand-written Caddy site lacks (holding
  requests while the app restarts, the request log) and adds it: copy, validate, reload, check.
- Added: the pre-flight of a Next.js release loads `sharp` and requests the pages' optimised
  images. A `sharp` binary for the wrong platform fails the deploy before the switch; the image
  cache starts warm.
- Added: `tando health <app> --forget N` drops a false alarm from the uptime record.
- Changed: `tando backup ls` lists the adopt backup. A failed build prints whole lines and keeps
  its output in `.tando/build.log`.
- Fixed: a release refused before the switch also left its health path and expected answer in
  the app's settings.

- Fixed: a release refused at pre-flight left its `start` command in the app's settings, so the
  live release used it at its next restart. Each release now keeps its own start command.
- Fixed: for an adopted app the monitor probed `<app>.<apps_domain>` instead of the app's own
  site and reported it unhealthy. Health, certificate and after-reboot checks use the real site.
- Fixed: `adopt plan` reported no backup when the owner's backup script runs from a systemd
  timer rather than cron.
- Added: the request log directory is prepared for adopted apps, so `tando requests` works once
  the log block is pasted into the hand-written site.

## 0.1.0 - 2026-11-18

First public release.

- The project was renamed to tando. It is licensed under the PolyForm Noncommercial License 1.0.0; commercial use needs approval (COMMERCIAL.md).

Summary of this round (16-17 Nov 2026). The server programs under `/opt/tando/bin` were rewritten
from bash to Go (`tando-metrics`, `tando-logs`, `tando-watch`, `tando-gate`, `tando-status`, and the
new monitoring daemon `tandod`), with the same verbs, output and files; two features were added,
offsite backup and host care; the alerts cover both. Details by area below. Performance figures are
from a 1-CPU arm64 test container and, since 17 Nov, from the real x86-64 server (bench/RESULTS.md).
- A deploy refused for lack of disk space or inodes gives its upload lease back at once (the next
  deploy was refused for up to 5 seconds).

### Monitoring (alerts for the new features)
- Offsite: a per-app check `offsite` (srv/watch) reads `/var/lib/tando/offsite/state/<app>` and
  fires when a backup made on the server has not reached the bucket after `alert_hours` (6 h), or
  when the bucket credentials stop working; it resolves when no backup waits that long and the credentials
  work. It is judged only for apps with offsite copies on.
- Host care: the host checks `updates`, `reboot`, `exposed`, `ssh`, `units`, `readonly`, `ioerr`,
  `clock`, `eol` and `boot` are judged hourly by `tando-host` and read by tando-watch from its
  summary file (stale after 3 hours). `exposed`, `readonly` and `ioerr` are high severity, `ssh` low.
  Thresholds and on/off through `tando alerts set`; see docs/MONITORING.md and docs/HOSTCARE.md.
- Server programs: no shell anywhere in `srv/` (enforced by `srv/tools/srvlint`, see "Server" below),
  and a cut-off `tando host setup` repairs itself (see "Server" below).

### Offsite backups
- `tando backup offsite set` copies every backup (daily, manual, pre-deploy, safety, final) to
  Cloudflare R2 or any S3-compatible store right after it is made, in a unit of its own (a deploy
  never waits for an upload); `tando-offsite.timer` retries failed uploads every 30 minutes and
  applies the offsite retention (by default the local one; `keep_*` to keep more; only this server's
  objects; the newest always). New Go program `tando-offsite` (srv/offsite: the S3 API with SigV4 by
  hand, standard library only), installed by `tando host setup`.
- Encrypted on the server by default (AES-256-GCM streaming, a recovery key shown once;
  `key --show|--saved|--import|--rotate`); `tando doctor` warns until the key is confirmed saved.
- `tando backup ls` shows where each backup is (local, offsite, both) and lists offsite-only ones;
  `tando restore <id>` (new, = `backup restore`) and `backup pull` fetch from offsite when needed.
- Disaster recovery: `tando backup offsite hosts` and `tando restore --from-host <host id> --all`
  recreate a lost server's apps (settings, env, domains, data, database) on a new one
  (runbook in docs/BACKUP.md). Releases are not backed up: deploy again with `tando up`.
- Monitoring: an offsite state file per app for the `backup` alert, doctor rows (offsite, queue,
  timer, recovery key), an offsite line in `tando status <app>`.
- Tests: srv/offsite unit tests against an in-process S3 that checks every signature (AWS's SigV4
  vectors, multipart, retries, faults, resume, 1.5 GB streams in bounded memory, fuzzed parsers and
  decryption), `test/e2e-offsite.sh`, `test/offsite-r2-check.sh` for a real bucket.

### Server
- Host care (docs/HOSTCARE.md): `tando host status` shows the server itself (OS and its end of
  support, pending and security updates, unattended-upgrades, a needed reboot and the kernel,
  ports open to the world cross-checked with ufw, sshd's effective settings, failed services,
  read-only file systems, disk I/O errors, disks and /boot, the clock, backups) with a to-do list
  of exact fixes; `tando host care on --updates` lets Ubuntu's unattended-upgrades install
  security updates (security origins only, no service restarts), `--reboot` reboots in a
  maintenance window under fixed safety rules (never during a deploy, backups first, a notice
  before, every app verified after, never beside sites tando does not manage unless allowed);
  `tando host update` and `tando host reboot` do the same by hand. New program `tando-host`
  (srv/hostcare) with an hourly timer and a summary file for the alerts (`updates`, `reboot`,
  `exposed`, `ssh`, `units`, `readonly`, `ioerr`, `clock`, `eol`, `boot`; settings through
  `tando alerts set`); `tando ls` and `tando host ls` show the server's to-do count, `tando doctor`
  one row. `tando host setup` turns security updates on where it installed Caddy (`care=off`).
- Logs: the per-minute scan counts each request once after a crash or an index rebuild (its
  position is the log file and a byte offset; where it cannot tell it learns, never a burst);
  `tando errors` no longer takes new errors from the monitor; the journal cursor is sealed and kept
  with the group counts, a refused cursor is reported instead of stopping detection; a first scan
  reports 0 error events; request log file names are checked and their number bounded (log-doctor
  warns); gzip'd rolls are matched by size, reads are bounded per tick; `app-remove` removes the
  scan state; known error groups are not pushed out by a spray of new ones (docs/LOGGING.md).
- Internal: `srv/` architecture cleanup, no change in behaviour (srv/README.md: package map, output rule).
- Tests: the no-shell rule of `srv/` is enforced on the syntax trees (`srv/tools/srvlint`, run by
  `test/go.sh`: aliased imports, raw syscalls, folded literals, a closed and reviewed list of
  programs, the layering), `run.Exec` starts only an allowlist of programs (not only "not a shell"),
  and `test/go.sh` runs `go test -race`; `du` gets `--` before its directories.
- Server programs run in `/` with a scrubbed environment, `systemd-run`, `sudo` and `nice` only
  with the options and unit properties in a fixed list (no `Exec*`), `python3` for the tool
  versions in isolated mode (`-I`: a `venv.py` in the caller's directory is not imported), and
  srvlint lists every program's arguments (`srv/tools/srvlint/args.txt`) and fails on an unvalidated one.
- Fix: `tando host setup` switched its programs into `/opt/tando/bin` one rename at a time, so a
  failure or kill between renames left a mixed set (a new `tando-agent` beside an old
  `tando-status`). Now every file is verified and staged first, a journal and a hard link to each
  replaced file are written, then the renames follow; a failed rename is undone at once, and a
  switch cut off by a kill or a lost connection is finished or undone by the next `tando host
  setup` (or any on-demand install). The client says the install may be cut off and how to repair
  it; `tando doctor` shows a `fail` row "install" while a switch is pending.
- A cut-off install now repairs itself: `tando-install-recover` (a helper; the same code the install
  script runs) finishes or undoes it at boot (`tando-recover.service`) and before any mutating
  `tando-agent` verb (a read-only verb only warns); the check is one bash file test. After a full
  install the agent also records `/opt/tando/bin/.versions`, and hands `status` and the other read
  verbs to `tando-status` only while neither it nor `tando-status` is newer than that file, so a
  new agent no longer execs an old `tando-status` that lacks a verb.
- New: `tandod`, a small monitoring daemon (`srv/daemon`, about 10 MB of memory). Each minute it
  runs the metrics sample, the alert checks and the scan of the apps' logs in one process,
  instead of a timer starting `tando-metrics`, `tando-agent recover-all` (a bash program, every
  minute) and `tando-watch` (which started `tando-logs`, `systemctl` and `nft`): it keeps a
  connection to systemd's private bus and a cache of the files it reads, runs recover-all only
  when an activation died or an app is down, and lists the firewall rules only after the ruleset
  changed. Alert semantics are unchanged (one sample a minute; the same state files, written the
  same crash-safe way). `tando-watch.timer` stays the switch and becomes the fallback: it starts
  `tando-watch-fallback.service`, skipped while tandod runs. The read verbs of `tando-watch` ask
  tandod over a root-only socket first. `tando host setup` installs and starts it; `tando doctor`
  shows it. Email notifications are handed to sendmail in a unit of its own (sendmail could not
  write its spool from the sandbox of the checks). A run of the checks that panics, fails 3 times
  or kills the process twice in a row makes tandod hand the checks to the timer (it removes
  `/run/tandod/active`, the fallback's condition), raise the new host alert `monitor` (also for a
  tandod that keeps restarting) and warn in `tando doctor`; retries back off from 1 h to 24 h.
  "N in a row" counts minutes, not runs (two runs in a minute no longer fire early). A lock of
  the checks held for good is reported straight to the notifiers and by doctor. Host setup
  restarts tandod only when its binary or unit changed, and checks it runs the new binary. Fixed on the way: two runs of one process in the same
  second could overwrite each other's queued message; a lone C1 byte (8-bit CSI) or invalid UTF-8
  in an app's text reached notifications (Telegram rejects them); a static app made every run ask
  the journal how its (non-existent) process ended.
- The agent's read-only, frequently called verbs (`status`, `deploy-status`, `releases`,
  `history`, `busy`, `info`) are answered by a new Go program, `tando-status` (`srv/status`),
  which `host setup` installs and doctor checks (row `status`). `tando-agent` keeps the verbs: it
  checks their arguments and the privilege rule in its first lines and execs tando-status; where
  the binary is missing its shell versions answer as before. The output is the shell's, byte for
  byte (test/e2e-status.sh compares the two on one server: 121 checks). No process is started per
  app, cgroup and /proc files are read directly, df is statfs, a certificate's expiry is read
  without openssl and date, `info` keeps the python3/node/caddy versions until the program
  changes, and systemd is asked over its private socket: the loaded units' properties in one
  pipelined write, a stopped app's MemoryMax from its unit file (asking systemd about a unit it
  has not loaded makes it parse and collect that unit each time). Measured on a 1 CPU / 2 GB
  arm64 test server (CPU of the process tree, medians; test/load/status-bench.sh and
  status-scale.sh): `status` with 100 apps 364 -> 16 ms (wall 426 -> 22 ms; systemd's own share
  60 -> 5.5 ms), with 20 apps 95 -> 9 ms, with 3 apps 30 -> 7 ms (what is left is mostly the other
  programs status includes: tando-logs log-stats and tando-watch brief); `history` of every app
  280 -> 2 ms at 100 apps; `info` 34 -> 2-3 ms; `releases`, `busy`, `deploy-status` 11-19 -> 2 ms
  (the cost of starting bash and a Go program). tando-status's peak RSS is 6.5 MB (11 MB for
  `status` of 100 apps). As root, `status` is answered by tandod when it runs: tando-status asks
  its socket first (100 ms to connect; anything but an `ok` answer and it collects itself), and
  the daemon runs the same code with the rows of tando-logs, tando-watch and tando-metrics
  in-process, collected when asked (a stop, a start or a deploy shows in the very next `tando ls`).
  Everything included (the processes, systemd and tandod's share), `status` at 3 apps costs
  2.2 ms of CPU against the shell's 35 ms, `status <app>` 2.2 ms against 38, at 20 apps 3.0 ms
  against 113, at 100 apps 5.7 ms against 418. `tando doctor` compares the installed tandod too (row `daemon`); the sums of
  tando-status and tandod are sent as named arguments, which an older agent ignores. Fixed on the way: `status` dropped the row of an app whose
  app.conf has no port (or that the caller may not read) with `C[port]: unbound variable`;
  `releases`, `busy` and `deploy-status` without an app said `$1: unbound variable` (now
  `invalid app name`); a certificate file that does not parse showed today's midnight as its
  expiry (now `-`); a `deploy-status` activation file without `result` aborted the verb; a symlink
  in Caddy's certificate store (the caddy user's) was followed by root.
- `tando-metrics` is now a Go program (`srv/`, standard library only), the first of the server
  programs to move from bash; its verbs, output, files (`/var/lib/tando/metrics`, 644) and the
  files the shell version wrote are unchanged. New verb `tando-metrics version`. The shell
  original is kept in `server/legacy/` (not shipped). Fixed on the way: when `systemctl` failed,
  a sample wrote a line for the first app only and forgot every file's line count (the next
  sample started the files over); `read` with a zero-padded number (`010`) read it as octal.
- `tando-logs` (journal namespaces, `tando logs`, the request log, `watch-scan` and `errors`,
  log stats, the audit trail) is now a Go program (`srv/logs`); its verbs, stdin spec, rows,
  `key=value` lines, exit codes, messages, the journald and Caddy config it writes and its files
  (`logs.conf`, the stats and request-log caches, `/var/lib/tando/logscan`: cursors, request
  positions, `groups.tsv`, samples, `audit.log` and its rotation) are unchanged; error group ids
  are the same, so groups on a server keep their ids and counts. New verb `tando-logs version`.
  Caddy's JSON lines and journalctl's are parsed with `encoding/json/jsontext` instead of awk:
  `req-summary` and `req-errors` cost about a third of the CPU (600,000 lines: 2.2 s -> 0.7 s and
  0.9 s -> 0.26 s), the error scan's parser a fifth. `--regex` is RE2 (POSIX ERE plus `\d`, `\w`;
  linear time) and `-i` matches case-insensitively. Fixed on the way: the address column of
  `tando requests tail` and `errors` was empty on Caddy 2.6 (`remote_ip` is the first key of
  Caddy's request object and was never found); every text `tando logs` left a temp file in `/tmp`
  and printed `of: unbound variable`; `-n 00` printed the whole journal; a message over 4096 bytes
  showed as `ul`; a job name in app.conf was word-split into unit names; a fragment of a request
  line (the 8 MB scan cap starting inside a line) counted as a request; an audit result such as
  `1;x` was written as `fail(1;x)`, a note could be cut inside a UTF-8 character, and an audit
  write waiting for the lock during a rotation appended to the rotated file; an invalid hand-set
  `journal_max` reached journald's config. The shell original is kept in
  `server/legacy/tando-logs` (not shipped).
- Requests: tando-logs keeps an index of the request log beside it
  (`/var/lib/tando/logscan/<app>/reqindex/`, root only: a 32-byte record per line and the path
  keys, one segment per log file, deleted with it), brought up to date every minute by `watch-scan`
  and by the new verb `tando-logs req-roll [app]`. `tando requests` (the summary of any window),
  `requests errors` and `requests tail` read it instead of the whole log and print the same bytes
  as a full scan: on 600,000 lines, 2.2 s -> 0.04 s, 0.84 s -> 0.025 s and 0.07 s -> 0.005 s of CPU
  against the shell version, memory under 12 MB. Lines are parsed by a scanner written for
  Caddy's layout (2.4 million lines a second, no allocation per line). `watch-scan` no longer
  starts journalctl for an app whose journal did not change (5 ms an idle app), takes its request
  numbers from the index (all of a rolled file, no 8 MB cap: `bytes skipped` is now always 0), and
  builds the index from the existing log the first time it runs after an upgrade (about 0.3 s per
  600,000 lines, once).
- tandod's log scan: an app with nothing new in its journal or request log costs three stat calls
  (100 idle apps: about 0.25 ms a tick), an app that never logged a line no longer runs
  `journalctl --since=-24h` every minute, and a busy app's tick no longer reloads its path
  dictionary or replaces files by rename (20 apps at 240 requests a minute: about 2.5 ms a tick
  besides journalctl). What the daemon keeps between ticks is bounded: a client requesting unique
  URLs no longer grows it (2 million of them over 5 apps: peak RSS 14 MB, was 45 MB); the path
  dictionary of a segment is capped at 1 MB (was 4 MB). Files in the request log's directory are
  opened without following links or blocking, so a FIFO put there cannot hang a tick.
- `tando-watch` (the alert checks and notifiers) is now a Go program (`srv/watch`); its verbs,
  rows, exit codes, messages, notification bodies, settings and files (state, history,
  incidents, silences, notifiers, queued messages under `/var/lib/tando/watch`, the units) are
  unchanged, and a host upgraded by `tando host setup` keeps all of them. New verb `tando-watch
  version`. Health probes, certificate checks, notifier deliveries and the heartbeat use Go's
  HTTP client with curl's limits instead of curl (no curl process; secrets stay inside the
  process), and the host disk check reads statfs instead of running df. A run killed at any
  point no longer repeats or loses a notification (`/var/lib/tando/watch/commit`; the shell sent
  a run's messages again when killed between queueing and saving its state, and lost an inbox
  rollback notice when killed after reading it). Two runs no longer deliver the same queue at
  once. Fixed on the way: `hog.disk=off` was refused ("disk is a host check") although `disk` is
  also an app check; `silence <app> 08` failed as octal; an app whose directories were all
  missing had `du` measure `/` for up to 50 s; a queued line with an empty detail (a resolve
  owed after a silence) showed its timestamp as the detail; the volatile disk counters of a
  removed app stayed in `/run/tando-watch/vstate`. The shell original is kept in
  `server/legacy/`. `tando alerts` compares the server's tando-watch with either CPU's binary.
- `tando-gate` (CI deploy keys) is now a Go program (`srv/gate`); verbs, the request grammar,
  messages, exit codes, files, modes, the sshd drop-in and the sudo rule are unchanged, so servers
  with keys keep working after `tando host setup`. New verb `tando-gate version`; the shell
  original is in `server/legacy/`. The request is parsed into a typed one by a fixed grammar
  before anything runs; the gate keeps 4 variables of its environment and clears the rest, sets
  umask and working directory, and as root refuses to start with a Go runtime variable set; root
  reads the upload only through directory descriptors (no link followed, no file opened). Fixed
  or hardened on the way: an upload faster than the watchdog's first check (a second) passed
  the app's byte and file limits (now checked from 250 ms and once more when the receiver ends);
  the watchdog stops an upload whose tree it cannot walk (the shell's `find` errors were ignored); authorized_keys gets only well-formed key lines from the key list;
  rx mode checks the rsync options again; a short rsync option ending in a bare `e` is refused;
  the deploy user is looked up in /etc/passwd only (not other NSS sources) and key mode checks the
  real uid too; the sudo rule's candidate file is created afresh (a symlink there was followed);
  an append to cron.deny/at.deny/retired-uids ends an unterminated last line first; the read-only
  verbs' lines are cleaned of control characters once more. An upload right after the previous one (back to
  back, or right after `end`) could fail with "Unit tando-rx-<app>.service was already loaded"
  on a busy host: systemd had not yet collected the ended receiver, and it collects only when it
  is otherwise idle (the shell version had the same race). Each receiver now has a unit of its own,
  `tando-rx-<app>@<nonce>`; one receiver per app is kept by the lease lock, and the gate and
  tando-agent find and stop them by pattern (with `list-units`, which loads no unit). The
  deploy user's own walks of its upload (rx mode) no longer stop at a directory the upload left at
  mode 000: it is made u+rwx first, so links and setuid bits under it are still dealt with.
  When systemd was slow to start the receiver's unit (more than 5 s), the gate gave the lease lock
  back before the unit existed: an `end` or an activation then found nothing to stop, and the
  receiver of the ended upload started afterwards (shown on a test server; with stock clients the
  connection was closed by then). Now the lock is kept until the unit runs, `end`/`activate` close
  the upload under the lock first, and the receiver refuses to start unless its ticket is current. A session opened before the update
  (its login process is the old bash script) is refused by root mode once: deploy again.
- `tando host setup` installs a Go program as the static binary for the server's CPU (x86_64 or
  aarch64), checked by running `<binary> version` (scripts still by `bash -n`), and no longer
  sends a server program whose SHA-256 matches the installed one. `tando doctor` accepts either
  CPU's checksum for a Go program.

### Build and release
- `scripts/build-server.sh` builds the Go programs for linux/amd64 and linux/arm64, statically and
  reproducibly, into `dist/server/`; host setup and `install.sh` run it from a checkout when Go is
  installed. Release archives carry the binaries as `server/linux-<cpu>/<name>` (2.3 MB each;
  the archive is about 2.3 MB instead of 0.3 MB), and making a release needs Go.
- Tests: `test/go.sh` (gofmt, go vet, go test, no-shell lint, layering, both CPUs) runs in
  `test/all.sh`; lint rules RL15/RL16 (no `os/exec` outside `srv/internal/run`, no shell).

## 0.1.0 - not released yet

First tagged release; the date is set when the tag is made. Tested on arm64 Ubuntu 26.04
test containers and, on 14 Nov 2026, on one real x86-64 Ubuntu 26.04 server; see docs/STATUS.md for
what is verified and what is still open.

### Deploy
- `init` detects the recipe (next, node, python, container, static), start command and health
  path, and writes `tando.conf`; `recipes` lists what each recipe needs.
- `up` creates the app (only after a successful build) and deploys; `deploy` builds on the laptop,
  rsyncs changed files, and the server copies them into a root-owned release.
- Activation on the server, detached from ssh: pre-flight on port+100, atomic switch, verify through
  Caddy, 30 s soak (`soak =`), automatic rollback; recovery at boot, from every mutating verb and
  from the activation unit's `ExecStopPost`; client deadline while polling.
- `rollback [id]`, `releases`, `history` with phase times; release order by deploy sequence,
  5 verified releases kept, failed releases deleted at once; per-app disk cap (`app_max_mb`).
- Upload lease with stale-lease takeover and `unlock`; a deploy from another directory or to
  another target asks first (`--force`, `--yes`).
- Next.js: standalone output (`init` offers to set it), static and public copied, darwin native
  packages swapped for the server's architecture.
- `--json` on `ls`, `status`, `releases`, `history`; `--wait` / `TANDO_WAIT=1` for CI.
- A failed deploy explains itself: missing env var, missing local file or missing Python package,
  with the command to fix it; a rollback during the soak records its reason (`why <id>: ...` in
  `history`) and raises an alert. `init` picks a real health route instead of `/` when it can.
- Static sites get clean URLs and a custom `404.html`; Python uploads get gunicorn or uvicorn
  added to `requirements.txt` when the start command needs it.
- A command that has to wait for another deploy says what it is waiting for.

### Run and configure
- `start`, `stop` (503 page), `restart`, with Caddy holding requests during a restart
  (15 s, or `health_timeout` when longer).
- `env set/unset/ls/import`, values on stdin, stored root:app 640.
- `env set` before the first `up` is kept on the server and applied when the app is created;
  `env ls` masks values unless `--show`.
- `ssh <app>` opens a shell (or runs one command) inside the app's sandbox as the app's user;
  `jobs run <name>` runs a scheduled job now.
- Scheduled jobs (`job.<name> = <schedule> | <command>`, `jobs`); `data =` directory,
  `writable =`, `memory =`, `node =`; `MALLOC_ARENA_MAX=2` for Node apps.
- `database = postgres` (one role per app, `db psql`, `db url --show`) or `sqlite`.
- `backup now/ls/restore/pull`, daily and pre-deploy backups, final backup on `destroy`.
- Runtimes installed when the first app needs one: Node (checksummed, per major), Python venv
  built on the server, Podman (container recipe, root Podman), PostgreSQL.

### Servers and domains
- `host add/ls/setup/rm`: setup installs the agent and helpers, rsync, curl, nftables, Caddy
  (the distribution's package) and units; it is idempotent. It moves Caddy's admin API to a unix
  socket without a restart (the new config is handed to the old admin address; a restart
  is the fallback), and adds a `Restart=on-failure` drop-in for Caddy.
- Links `<app>.<ip-with-dashes>.sslip.io` (public IPv4) or `<app>.<apps_domain>`.
- `domain add/rm/ls`: DNS check from the laptop with the records to create, `--wait`, `--www`,
  validated Caddy config with rollback, waits for the certificate.
- `doctor` checks the server end to end, including a server that is not set up yet; `version`.
- `destroy` (`--purge`) removes every trace of the app and retires its uid.
- Unknown host names get a plain 404 over HTTP instead of another app's page (only when the stock
  `:80` block is still in the Caddyfile).
- Package installs on the server run with `NEEDRESTART_SUSPEND=1`, so Ubuntu's needrestart does
  not restart services tando does not manage.

### Security
- Per-app user and sandbox for the app, its pre-flight, jobs, venv build and backups (ProtectSystem
  strict, private /tmp, /dev, IPC, 16 MB private /dev/shm, socket-bind limits); health counts only
  when the listener is in the app's own unit.
- nftables per-uid loopback rules (`inet tando`); journal namespaces closed per app; a secret probe
  header keeps tando's probes out of request logs; requests with a port in Host get 400.
- Server output is checked before any arithmetic on the laptop (numbers with leading zeros or
  more than 18 digits show as `-`); control characters and bidi controls (U+200E/F, U+202A-E,
  U+2066-9, U+061C) are stripped, so a log line cannot reorder what the terminal shows.
- `backup pull` creates its file mode 600 (it holds a database dump); `install.sh` refuses a plain
  `http://` `--from` unless `--insecure`, and redirects stay on https.
- A refused CI deploy key says so (revoked, or for another app or server) and names
  `tando ci setup`, instead of advising to edit authorized_keys.
- CI deploy keys (`ci setup/ls/revoke/rotate/github/hook`) through `tando-gate`: one app only,
  confined rsync receiver, upload limits, revocation that evicts sessions.
- Third review (the architecture notes): the loopback rules also refuse adopted apps' ports and drop app
  replies to outside connections; adopt runs fw_sync; tando-watch puts flushed rules back (alert
  `firewall`). The probe secret never reaches an app; X-Real-IP is the peer's; Host in other
  letters gets 400 on Caddy 2.6; half-closed requests show as `aborted` in `tando requests`.
- **Changed:** an app's HOME is `/opt/tando/apps/<app>/home`, read-only (it was shared/): write
  data under `$TANDO_DATA_DIR`; caches go to `shared/.cache`. User npm/git/pip config is not read.
- App units get ProtectProc, ProcSubset and the kernel-facing systemd protections with a syscall
  filter (exposure 7.7 → 3.3); `tando ssh -- cmd` no longer shows the command in any argv.
- Lock files root 0600 with timeouts (an app could hold `.ports.lock` and freeze `tando up`).
- Disk: an app over `app_max_mb` alerts (`disk`) and is stopped when the disk is 95% full; an
  unreadable file in the data no longer fails the pre-deploy backup (a warning in its meta).
- Caddy header/idle timeouts on a server tando set up; doctor shows the lines elsewhere.
- Destroyed apps' gids are retired; alert state is root-only.

### Observe
- `ls` (`--all`, `--watch`), `status` (`--watch`), `top` full-screen dashboard (`--read-only`).
- `logs` from a journald namespace per app, with filters, `--release`, `--deploy`, `pull`;
  `requests` summary, tail and errors from Caddy's log; `audit` of every mutating verb.
- `alerts`: per-minute checks (down, health, memory, OOM, restarts, TLS, disk...), notifiers
  (webhook, Slack, Telegram, ntfy, email), silences, heartbeat; per-minute metrics for graphs.
- Time columns are headed `TIME (GMT)` and show the UTC time (`11-14 17:01`, with seconds in
  `audit` and `requests`) in `history`, `status`, `backup ls`, `alerts`, `audit`, `requests` and the
  `top` history view, the same clock as release ids; they were a relative age or the laptop's local
  time under `WHEN`; the requests tables' answer time is now `LATENCY`. `--json` is unchanged.
- `status` shows the app's limits in one row (cpu cap, tasks, connections, the in-flight count over
  which Caddy answers 503 busy); `--json` adds `cpu_limit, tasks_max, max_conns, max_requests`.
- Every other absolute time is GMT too: `logs` lines and `--since`/`--until` dates (a first line
  `# times in GMT (UTC)` on a terminal; `--json` times carry `+00:00`), `requests tail -f`, the
  `requests` "log starts" note, `ci ls` (`CREATED (GMT)`, `LAST DEPLOY (GMT)`).
- Log retention and size: `log_keep` (`Nh`/`Nd`, default 30d) and `log_max` (default min(2G, 5% of
  the disk); circular: the oldest entries go when it is full) per app or as host defaults; journal
  files close after a quarter of `log_keep` so retention trims. A change restarts only the app's
  journald (the app and its output stream stay) and vacuums at once. `status` shows `logs 6.4 MB of
  2.0 GB, keeps 30 d`; doctor compares the caps with the free space.
- Request log: sized by `request_log_max` (default min(log_max/4, 256M)), kept for `log_keep`,
  rolled files gzip'd (about 20x); `requests` reads the rolled and gzip'd files; a changed rotation
  applies at the next Caddy reload (no restart). Before: 4 MiB x 4, seconds of history under load.
- `logs` notes the lines journald dropped in the window shown (rate limit `log_rate`); tando-watch
  raises a low-severity `logs` alert.
- `errors [app]`: the app's error lines and stack traces (Node, Python, Go) grouped by type and
  first app frame, with counts, first/last seen (GMT), the release they appeared in and a sample;
  `--since`, `--json`. Read incrementally once a minute; no agent in the app.
- `health [app]`: uptime over 24 h and 7 d, incidents (start, duration, cause), probe latency, the
  last lines before the last crash; `--json`.
- Alerts: `http` (5xx share of real requests, top failing paths), `slow` (p95), `errors` (spike),
  `logs` (low), and one "NEW ERROR ... after release <id> ... tando rollback" notice per new error
  type after a deploy; health failures say unhealthy / slow / saturated / down; tando.conf
  `health_expect`, `health_fails`, `health_recover`; crash alerts name the exit status or signal and
  an OOM kill; log lines are never sent unless `include_log_lines=on`. `alerts` without a notifier
  shows one copy-paste line per kind (ntfy first); `alerts test` shows the message and each
  receiver's HTTP answer; `doctor` reports a failing notifier; the first `up` of an app says alerts
  watch it.

### Migration and onboarding
- `adopt plan/apply/undo/status`: take over a hand-deployed Next.js systemd app in place, with
  backup and verified undo (docs/MIGRATION.md; rehearsed on a replica only).
- Plugins: `go` (setup wizard), `next`, `link`, `open`, `ssh`, `cheat`; plugin loading from
  `lib/cmd-<name>.sh`.
- Help and argument checking driven by `lib/help.txt`; exit codes 0/1/2. The app name can be
  given as a plain word (`tando logs shop`); a mistyped command, flag or app name gets a
  suggestion.
- `tando help <command> <subcommand>` (`tando help alerts notifier`) shows the command's help.
- `host setup` installs its helpers in one call under a host-wide lock (`/opt/tando/.install.lock`):
  each file goes to a unique temporary name, is checked against the size and SHA-256 computed on
  the laptop and with `bash -n`, then moved into place; two setups at once queue instead of failing
  ("mv: cannot stat ...new") or mixing versions. A long step detail is wrapped under the step.
- Wording: `doctor` "1 warning", `env ls` "(1 character)", an empty history in `status` says
  "no deploy has finished yet", a rollback's reason reads "rolled back to it from <id>"; with
  `TANDO_ASCII=1` no "·" is left (help, footers, setup). ssh's "ControlSocket ... already exists"
  notice is no longer shown.
- `host setup` shows the running step at once with a ticking time (a PostgreSQL install takes a
  minute or more), on a terminal.
- Many commands at once to one server: a session sshd turns away (MaxSessions 10 per shared
  connection, MaxStartups) is retried up to 3 times with a short random pause (nothing ran on the
  server), then explained as "too many tando commands at once". A `$TMPDIR` with a space no longer
  breaks rsync's ssh wrapper (the work directory goes to /tmp instead).

### Tooling and docs
- `install.sh`/`uninstall.sh` (manifest, checksum check), `scripts/release.sh` (reproducible
  archive, SHA-256), bash and zsh completions (`completions/gen.sh`), Makefile.
- Tests: `test/all.sh` (parallel slots, `--repeat`), e2e suites (core, bootstrap, cli, data, next,
  recipes, ci, logs, alerts, top, adopt, sec2, faults, ease), `ui-test`, `install-test`,
  `trial` (regressions found on the real server), `portability` (macOS bash 3.2, Debian, BusyBox
  clients), `lint.sh` with a baseline and tando's own rules (RL01-RL14);
  GitHub Actions workflow (never run on GitHub).
- Examples: hello, next, python, container, site, notes, logflood. Benchmarks in `bench/`.
- Docs: README, docs/ (STATUS, COMMANDS, CI, LOGGING, MONITORING, MIGRATION,
  TOP, TESTING, RELEASING, EASE) and the review reports.

### Reliability (idempotency, concurrency, faults)
- Re-runs change nothing: a deploy of an unchanged tree with unchanged settings onto its live,
  verified release says "already live" and restarts nothing (no new release); `env set` of values
  the app already has does not restart it; app.conf, state and unit/job files are rewritten only
  when they differ; host setup twice touches no file and reloads nothing.
- Jobs take effect with a verified release and go back with it: each release keeps the jobs it was
  deployed with (`/opt/tando/apps/<app>/jobs/<id>`); a failed release never changes the schedule.
- `env set`/`unset` on a running app first starts it with the new values on the pre-flight port:
  values it does not start with are refused before anything restarts (no outage); one that fails
  only after the restart is undone (previous env put back, restarted); exit 1 says which. Next
  apps get a 5 s stop timeout (its server keeps keep-alive connections on SIGTERM).
- Upload lease: never taken over while an rsync (or a deploy key's receiver) still writes into
  `incoming/` — two terminals of one user could put a mix of two uploads live; activate refuses
  while another upload writes. A receiver left by a dropped connection (nothing written for 30 s)
  is ended before its lease is taken over.
- Lost updates fixed: verbs re-read app.conf and state once they hold the app's lock (two
  `domain add` at once, a domain add during a deploy's configure); domain ownership under a
  host-wide lock; one host setup or runtime install at a time; firewall rules written under a
  host-wide lock to a temp file of their own, checked by nft, and a failed load is an error;
  `env set` of apps not created yet under a lock; no shared fixed-name temp files.
- `activate` no longer waits for another activation's soak; a queued deploy (also with a CI key)
  says what it waits for. The client says "waiting for ..." only when its call really waits for
  another one, naming it (it used to report its own restart as "another operation").
- Interrupted operations finish when run again: a first `up` cut off after the app's user was
  made, a `destroy` cut off before the end, an app directory without app.conf (destroy removes it).
- Faults: probe timeouts and the soak use the monotonic clock (a wall clock set back no longer
  stretches them); a lease or state field damaged or "from the future" no longer blocks deploys;
  health checks do not fail a good release when /tmp is full; state, env and the firewall file are
  flushed to disk before they replace the old one; old alert notices are not sent when alerts are
  set up later.
- PostgreSQL: apps without `database = postgres` cannot connect to 5432; authentication_timeout
  5 s; each app's role holds at most 10 connections (one app cannot take every slot).
- Under load: tando-watch restarts an app whose unit runs but that failed `liveness` (3) health
  checks in a row (at most 3 times an hour, then it only alerts; `liveness = 0` turns it off);
  node/next apps get `NODE_OPTIONS=--max-old-space-size` at 70% of `memory` (unless set), so V8
  exits instead of thrashing at the cgroup cap; Caddy opens at most 256 connections to an app
  (`max_conns` in app.conf) and queues the rest.
- Limits and load (docs/COMMANDS.md): `max_requests` (off by default) sheds requests over the
  limit with a 503 "busy" page (Retry-After) after the hold (`hold =`, default 15 s); per-client connection limits on 80/443
  (`conn_limit`, `conn_rate`, `rate_limit` in host setup; on by default only where tando owns
  Caddy); every unit of an app in its own slice with `cpu =`, `tasks =` and 3x `memory` for all its
  units together; apps get OOMScoreAdjust 500 and all of them half the CPU weight of Caddy and
  sshd; `stop_timeout` (10 s, was 20); examples close keep-alive connections on SIGTERM; one
  change of Caddy's sites at a time host-wide.
- Disk: a failed copy says why (cp's error, free MB and inodes; "no free inodes"); activate checks
  free inodes as well as bytes; doctor warns at 90% of the inodes; an upload over `app_max_mb` is
  refused before it is sent, and one refused later is cleared from incoming/. 200 jobs are
  enabled in one systemctl call. Two deploys from one checkout: the second says so (lock in .tando).
- A command that waited for an app's lock while the app was destroyed stops cleanly (no half app
  directory recreated); `up` of a name whose earlier app left a directory without app.conf starts
  clean.
- Smaller: a second `up` of an app being created says so; a command that waited for an app that
  was destroyed meanwhile says that instead of "(disk full?)"; write errors name the real cause;
  `backup ls` skips a backup pruned while it lists.
- Tests: test/faults n1-n7 (in e2e-faults), e2e-data D16, e2e 16e.
- Found on the real server (15 Nov): `tando ci setup` works under sudo-rs (it rejects
  `!requiretty`; the rule is written without it there); `tando alerts history` printed "no alerts
  yet" for every server (it read a root-only file without sudo; e2e-alerts 4e); every activation
  creates `shared/data` (`$TANDO_DATA_DIR` was set but the directory existed only with `data =`);
  `tando errors` sees an exception name after a logger's prefix (`12:00:01 [api] TypeError: x`).

- Release check (16 Nov): `install.sh`, `uninstall.sh` and three server programs had lost their
  executable bit (`./install.sh` failed with "permission denied"); `install.sh --from` takes a
  relative path. install-test I3r, I3x.

### Known issues
- An app's shell and jobs can reach loopback ports of services tando does not manage, and can
  list world-readable directories of other software on the server (the architecture notes).
- Unknown host names under HTTPS fail the TLS handshake instead of getting a 404.
- No real disk quota per app (`app_max_mb` caps uploads and releases; the disk guard stops an app
  at `disk_stop_pct`); no requests-per-second limit per app (Caddy has none without a plugin).
- A reload of Caddy closes the idle keep-alive connections of every site it serves.
- On the real server: the container recipe (the image must be built for the server's
  architecture), `adopt apply` and a reboot were not exercised; the default link depends on
  sslip.io.
