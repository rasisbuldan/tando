# tando monitoring and alerts

`tando-watch` checks every app and the host once a minute and tells you when something is wrong
and when it is fine again. It is built for a 1 vCPU / 2 GB server: one small daemon, `tandod`
(about 10 MB of memory), runs the checks, the metrics sample and the log scan at the start of
every minute; between minutes it sleeps. When it is not running, a systemd timer runs the same
checks as a short process each minute instead (see "How it runs").

```sh
tando alerts enable                          # once per host (`tando host setup` also does it)
tando alerts notifier add phone ntfy         # asks for the topic URL without echoing it
tando alerts test                            # one test message through every notifier
tando alerts                                 # active alerts, notifier health, recent history
tando alerts heartbeat                       # outside dead man's switch (see "From outside")
tando alerts backup-ping                     # a URL called after each whole run of the daily backups
```

## How it runs

- **tandod.service** (`/opt/tando/bin/tandod`, Type=notify, `Restart=always`): at the start of every
  minute, while `tando-watch.timer` is active, one tick: the metrics sample, `tando-agent
  recover-all` when an activation died or an app is down (in a unit of its own), the checks and
  their notifications, the scan of the apps' logs. It keeps one connection to systemd's private
  bus and a cache of the settings and app files (revalidated by inode, size and time on each use);
  the alert state is read from disk every tick and written as before, so killing it at any point
  loses and repeats nothing. It sleeps between ticks (one timer; a watchdog ping every 150 s).
  Sandboxed: `ProtectSystem=strict` with `/var/lib/tando`, `/run/tando-watch`, `/var/log/tando`
  and `/var/cache/tando-logs` writable, `NoNewPrivileges`, `MemoryMax=160M`, `GOMEMLIMIT=20MiB`,
  `GOGC=50`, `GOMAXPROCS=1`, `Nice=5`, `CPUWeight=20`, `OOMScoreAdjust=-200`; what writes elsewhere
  (the agent's recover-all and stop, sendmail) runs in transient units of its own. Its own memory
  stays under `GOMEMLIMIT` (6-20 MB; the live ring keeps 16 bytes per app per point, 2.3 MiB for 200 apps in an hour); `MemoryMax` leaves room for the page cache of the journals
  and programs it reads each minute. At 64M (up to 0.2) that cache was evicted every tick and read
  again from disk; `tando host setup` rewrites an older unit, reloads systemd and restarts tandod.
- **The switch and the fallback**: `tando-watch.timer` still fires every minute, but starts
  `tando-watch-fallback.service`, which systemd skips (`ConditionPathExists=!/run/tandod/active`)
  while tandod runs the checks well. tandod keeps `/run/tandod/active` (its own RuntimeDirectory,
  removed whenever it stops) only then: a run of the checks that panics (it is recovered, logged
  with its stack at priority err, and counted), 3 runs in a row that fail, or 2 in a row the
  process did not survive (an OOM kill, a fatal error; a record in /run/tando-watch outlives the
  process; a stop asked for, such as a restart by host setup, cancels the run at once and is never
  counted) remove it, and its watchdog (300 s, measured on time since boot, so a stepped wall
  clock cannot hide a stuck run) kills a hung one. tandod then stops ticking on its own and refuses
  `tick` ("degraded"), so the one-shot, which shares none of its code, runs the checks from the
  next minute. The owner sees it as an alert, `host/monitor` (below), shown by `tando alerts`,
  sent once when it fires and once when it resolves; tandod keeps the degraded state in
  /run/tando-watch/tandod.health, so a daemon that dies again and again is one alert, not a
  message per restart. It retries one run after 1 h, then 2 h, 4 h, ... at most 24 h (at once
  after a restart asked for, such as an upgrade), and takes the checks back when one works. When
  it cannot write `/run/tandod/active` (a full /run) it does not tick on its own: the timer's
  one-shot runs and asks it, one run a minute, and `tando doctor` warns. The condition is checked
  by systemd itself: no process per minute while tandod works (measured over 10 minutes with 3
  apps: PID 1 used 5 ms a minute in all, for the timer, the skipped fallback and tandod's
  questions on the bus together). Stopping the timer stops the checks either way: the dead man's
  check keeps its meaning.
- **One sample a minute**: some paths run the checks twice in a minute (tandod's tick and one
  asked for, the agent's run after a rollback, a degraded tandod's retry after the timer's run).
  A second run in the same minute re-evaluates and may deliver or resolve, but "N in a row"
  counts minutes: failed probes, the liveness count and good samples advance once a minute.
- **A stuck lock**: a process that holds the lock of the checks for good would stop tandod and the
  timer alike. Whoever takes it records itself (`/var/lib/tando/watch/lock.holder`); a run that
  cannot get it and finds it held longer than 5 min logs an error, sends `MONITOR host: no
  checks run: the lock of the checks is held for ... by pid ...` straight to every notifier
  (no queue: that needs the lock; once an hour), and `tando doctor` fails a row `alerts lock`.
- **`tando-watch run`** (and `systemctl start tando-watch.service`, which the agent runs after a
  rollback and the test suites use): asks tandod for a tick and waits for it; with no daemon it
  runs one itself. The read verbs (`show`, `history`, `health`, `brief`) also ask tandod first
  (`/run/tandod/tandod.sock`, root only) and read the files themselves when nothing answers. The
  answers are framed ("ok <length>"): a daemon that dies while it answers gives no partial rows,
  the verb runs here. `run` has one budget of 290 s (the units allow 300): what tandod's tick
  did not use, the run here gets.
- **Installing**: `tando host setup` (or `tando alerts enable`) installs `tandod`, writes the units
  and (re)starts it; a host that had only the timer keeps its state, history, silences, notifiers
  and queued messages. `tando alerts disable` removes tandod's unit with the timer's.
- **How an app last ended** (`last: exit status 3` in `down` and `restarts`): systemd's line about
  it is read from the system journal (one `journalctl -u`, which opens every file of that journal)
  only when the app restarted or its unit's state changed since the last read, never for a stopped
  or static app. The result is kept in `/run/tando-watch/vstate` (`xi.<app>`), so an app that stays
  failed costs one read, not one a minute.
- **Journals**: the scan reads an app's journal with one `journalctl --after-cursor` in a minute in
  which the app wrote something (an unchanged journal starts nothing). A follower per app
  (`journalctl -f`) was measured at 7.6 MB each: 760 MB at 100 apps.
- **Seeing it**: `tando doctor` has a row `tandod  running since 2h, last run 12s ago, 10 MB` (a
  warning when it is not running: the timer runs the checks meanwhile); `tando alerts` says when
  the checks last ran either way.

## Live views (5 s)

`tando status --follow`, `tando ls --follow` (and the menu bar's "Open status in Terminal") show
numbers 5 s old at most. They are for looking only: every alert rule stays once a minute, on the
minute samples above, unchanged.

- **The fast loop** (srv/live, in tandod, its own goroutine beside the minute schedule): every 5 s
  one point of every app (memory as anon + shmem of `memory.stat`, CPU from `cpu.stat`'s
  `usage_usec` since the last point, tasks from `pids.current`, and the unit's `ActiveState`,
  `SubState`, `NRestarts` and `MainPID` over the bus connection tandod already keeps, asked of
  loaded app units only) and of the host (`/proc/loadavg`, `/proc/meminfo`, `/proc/stat`, statfs of
  `/`). It starts no program, writes no file, takes no lock and never touches the alert state; the
  last hour (720 points) stays in memory and is lost on a restart. The minute files of
  `tando-metrics` are written exactly as before.
- **cgroup v2 only.** On a host with cgroup v1 or the hybrid layout there is no fast loop: the live
  verbs answer "no live view on this server", and `--follow` polls `status` every 5 s instead.
- **On the socket**: `live [app]` gives the latest point (`lhost`, `lapp` rows), `ring [app]` the
  hour (`rhost`, `rapp`). An older tandod answers "bad request" to both.
- **`tando-agent status-follow [app]`** (`tando-status follow`, root): one long-running process per
  viewer that writes a frame every 5 s: the rows of `status [app]` with the live fields patched in
  (state, memory, restarts, uptime, the CPU field now over 5 s; load, memory and disk of the host),
  then the live rows, between `@frame <epoch>` and `@end`. The whole status (from tandod: no program
  started either) is collected once a minute and at once when an app's `ActiveState` changes, so a
  crash, a stop or a start shows within 5 s with its release and alerts. It ends when the reader
  goes (its next write fails, within 5 s of the ssh session closing).
- **The laptop** keeps one ssh session for the whole view and reads the frames from a fifo; a
  silent server shows as stale after 15 s, an ended session is opened again. A server that sends no
  first frame (no `status-follow`, no tandod, no cgroup v2) is polled every 5 s as `--watch 5` does.

Cost, measured by `test/e2e-live.sh` on the arm64 Docker test server with 25 app units (one
deployed, 24 that only sleep), apps idle: tandod with the fast loop and its minute ticks about
0.1-0.2% of a core averaged over the window (about 110 ms of CPU a minute), the fast loop alone about
4 ms per point; systemd's own CPU (init.scope, the Gets) under 0.1%; tandod's anonymous memory
about 5 MB with the hour's ring; no program started by the fast loop (tandod's reaped-children
counters unchanged over 30 s with the minute ticks paused). A follower costs one process per
viewer reading tandod's socket every 5 s; the whole status once a minute.

## What is checked

| Check | Fires when | Production default |
|---|---|---|
| `down` | the unit is failed, restarting (auto-restart), inactive without `tando stop`, or restarted 2+ times since the last run | 2 samples in a row |
| `health` | the app's health path (`path` + `health`, `/` if unset) through Caddy does not answer as `health_expect` wants (default: any 2xx/3xx). The detail says which kind: **unhealthy** (wrong status, expected text missing, or Caddy got nothing from the app's port: 502/504), **slow** (no answer within `health_timeout`), **saturated** (Caddy's 503 "busy": more requests at once than `max_requests`/`max_conns`), **down** (Caddy's 503 "unavailable") | 3 failed probes in a row (`health_fails` in tando.conf), 10 s timeout each |
| `http` | real visitors get errors: at least 5 answers with HTTP 5xx **and** at least 10% of the requests within 5 minutes (from the request log, not the probe). The detail names the top failing paths, ids folded: `8 of 20 requests answered 5xx (40%) in 5 min; top: 8x 500 GET /api/fail/:n` | 1 sample |
| `slow` | the p95 latency of real requests in a minute is over 3000 ms (`slow_ms`), with at least 10 requests that minute (`slow_min`) | 5 minutes in a row (`slow_for`) |
| `errors` | a spike of error events in the app's own log (below): at least 20 within 5 minutes (`err_spike`) and 5 times its usual rate (a slow per-minute average) | 1 sample |
| `logs` (low severity) | journald dropped lines of the app (its rate limit `log_rate`): they are gone for good. Marked `(low)` in messages, no high priority in ntfy | resolves 15 min after the last drop (`logs_quiet`) |
| new error | an error type never seen in the app's log before appears within 30 min (`err_new_min`) of a deploy: sent once per type, as `NEW ERROR <app>: new error after release <id> (live 2m 10s when it first appeared): TypeError at handler (server.js), 3x [92408073]; tando errors -a <app>; to undo the release: tando rollback -a <app>` (at most 3 per app and run, then "and N more") | an event |
| `memory` | anon + shmem at or above 90% of the app's `MemoryMax` (page cache is not counted) | 5 samples in a row |
| `oom` | the kernel OOM killer killed a process of the app, even if systemd restarted it at once | fires at once; resolves 30 min after the last kill |
| `restarts` | 3 automatic restarts within 15 min (a crash loop is `down` instead). `down` and `restarts` say how the process ended: `last: exit status 3`, `killed by SIGKILL`, `core dumped (SIGSEGV)`, `OOM-killed at its memory cap 128M`; its last 10 lines are kept for `tando health <app>` (and sent only with `include_log_lines=on`) | |
| `tls` | the link's certificate (as Caddy serves it) has less than 20% of its lifetime left, or none can be read; `tls=auto` only, every 6 h | |
| `backup` | apps with daily backups: the last backup is older than 50 h (absent field: counts from app creation). With offsite copies on (docs/BACKUP.md): also a backup that has not reached the bucket after `alert_hours` (6 h), or bucket credentials that stopped working, read from `/var/lib/tando/offsite/state/<app>` (format in docs/BACKUP.md, "Monitoring"; the watch side of this is being wired in) | |
| `stuck` | an activation has been running for more than 20 min, or it died: its phase is not idle and nothing holds the app's lock (SIGKILL, full disk) | 2 samples for a dead one |
| `disk` | the app's own files (shared/, its `data_dir`, releases, incoming) and its PostgreSQL database together take more than `app_max_mb` (host setup, 8192 MB by default); the files measured with `du`, the database as the server gives its size, every 10 min. The detail says which: `shop uses 9100 MB of disk (files 400 MB, database 8700 MB), over the 8192 MB allowed per app`. When its file system is also 95% full (`disk_stop_pct`), the app is **stopped** (as `tando stop`: a 503 page; `tando start -a <app>` after freeing space), so one app cannot fill the disk under every other app's writes and deploys (the database counts for the stop only when PostgreSQL keeps its data on that file system) | 1 measurement |
| `job.<name>` | a scheduled job (`job.<name>` in tando.conf) failed: its last run ended with a non-zero exit status, a signal, its timeout or the memory limit. One message per failed run: `FIRING shop/job.nightly: job nightly failed at 11-19 03:00 UTC: exit status 1; tando jobs run nightly -a shop runs it again and shows its output` (`killed by its timeout`, `killed at its memory limit 256M`, `killed by SIGKILL`); a run that fails again while it fires is one more message. See "Scheduled jobs" below | fires at once; resolves at the job's next success |
| `db_conns` | apps with `database = postgres`: the app's database role holds at least 80% (`db_conn_pct`) of the role's connection limit (10 as tando sets it; read from the server, `pg_roles.rolconnlimit`). At the limit PostgreSQL refuses the app's next connection: a pool larger than the limit, connections never given back, a second instance during a deploy. Idle connections count: the limit counts them | 5 samples in a row (`db_conn_for`) |
| `db_deadlock` | apps with `database = postgres`: PostgreSQL broke a deadlock in the app's database since the last run (it cancelled one transaction of each; the app got an error). Read from `pg_stat_database.deadlocks`; a counter that went down or a new `stats_reset` is a reset, never a deadlock | fires at once; resolves 30 min after the last one (`deadlock_quiet`) |
| `db_wrap`, `db_wrap_warn` (low) | apps with `database = postgres`: the database has used 50% (`db_wrap_pct`) of its transaction IDs towards wraparound (`age(datfrozenxid)` of 2^31; at 100% PostgreSQL stops accepting writes); the low-severity warning from 25% (`db_wrap_warn_pct`) up to it. Autovacuum normally keeps it under 10% | 1 sample |
| host `disk`, `inodes` | `/`, `/var` or `/opt/tando` at or above 90% | 1 sample |
| host `firewall` | the per-app loopback rules (nftables table `inet tando`) differ from `/opt/tando/firewall.nft`: after `nft flush ruleset` (the stock `/etc/nftables.conf`, a firewall tool). The run loads them again at once, writes an audit line (`fw-restore`) and fires; it resolves on the next good runs. `tando-firewall.service` also reloads them whenever `nftables.service` (re)starts | 1 sample |
| host `memory` | MemAvailable below 5% of RAM, or memory PSI "some" avg60 at or above 30% (when the kernel has PSI) | 5 samples |
| host `swap` | 80% of swap used | 5 samples |
| host `load` | 5-minute load at or above 100% of the CPU count | 15 samples |
| host `oom` | an OOM kill outside the tando apps (Caddy, PostgreSQL, a job, an ssh session) | as `oom` |
| host `postgres` | only while an app has `database = postgres`: PostgreSQL does not answer (stopped, failed, still starting, refusing): `PostgreSQL does not answer (connection to server on socket ... failed: No such file or directory); used by shop, notes: sudo systemctl status postgresql`; or its usable slots (`max_connections` less the reserved ones: 17 of 20 as tando sets it) are 80% taken (`db_conn_pct`), all apps together | 2 samples (`down_after`) for no answer; 5 (`db_conn_for`) for the slots |
| host `caddy` | caddy.service is not active (a restart in progress is not counted): every app is unreachable | 1 sample |
| host `monitor` | tandod does not run the checks: it handed them to the timer (a panic, failed runs, runs it did not survive; the reason is in the detail), its unit failed or keeps restarting, or it restarted twice since the last run. The timer runs the checks meanwhile | 1 sample |
| host `monitor_cost` | what the monitoring costs (tandod and the programs it starts, from its cgroup: `tandod.x`, docs/TOP.md) averaged over the last hour is over 2× its normal (`monitor_cost_x`), and always over 600 ms of CPU a minute (`monitor_cost_cap_ms`: 1% of one core). Silent until there are 7 days of data (`monitor_cost_days`); the normal is the median of those minutes, worked out again once a day. Only minutes without a reader's request count: what the dashboard, `tando status` or `top` ask of tandod is the readers' cost, shown apart. An hour with fewer than 10 such minutes is not judged. Steal and swap-in are shown (`tando snapshot`), never alerted: the inode, memory pressure, swap, OOM and connection alerts above already cover the harm | 1 sample |
| host `caddy_config` | `caddy validate` rejects the config on disk (a hand edit that would break the next reload or restart); run only when a file under /etc/caddy changed, at most every 5 min | 1 sample |
| `restart` | tando-watch's liveness check restarted an app that runs but stopped answering (see `liveness`): sent once as `RESTARTED <app>: unhealthy: ... restarted by tando-watch (1 of at most 3 this hour)`; in the history and in `tando health <app>` as an incident | an event |
| `rollback` | a release was rolled back by itself (it fell over in its soak, or failed after the switch): sent once, as `ROLLED BACK <app>: release <id> rolled back to <prev>: <reason>`; `tando history` and `tando status` show the same reason | fires at once (an event, nothing to resolve) |
| host `updates`, `reboot`, `exposed` (high), `ssh` (low), `units`, `readonly` (high), `ioerr` (high), `clock`, `eol`, `boot` | host care's checks, judged hourly by tando-host (security updates waiting 3 days or unattended-upgrades failing; a reboot needed for 7 days; an unexpected port open to the world; password or root ssh login; failed units; a read-only file system; disk I/O errors; the clock unsynchronised for an hour; the release near or past its end of support; /boot 90% full). Thresholds and on/off with `tando alerts set` (they go to tando-host): docs/HOSTCARE.md | read from tando-host's summary |
| `watch` (dead man) | the timer is not active, or the last run is more than 3 min old or failed: shown by `tando alerts` and `tando doctor` | |

The health probe timeout (10 s) is deliberate: Caddy holds a request for up to 15 s (or `health_timeout`, if longer)
(`lb_try_duration`) while an app restarts, so a probe against a dead app would wait that long.
A dead app is caught by `down` from systemd's state, not by waiting for the probe; 10 s also
bounds the run when one app hangs. All probes run in parallel (at most 16 at once) from the one
tando-watch process.

One sample is one run, once a minute. While Caddy is down, no app's health is probed (they
would all fail with it), so a dead Caddy is one alert, not one per app. While an activation is
alive its app is not checked; once its activation died, the app is checked again (a release left
live and failing its health check is then reported). While `down` is not ok, `health`, `memory` and `restarts`
of that app are not evaluated, so a dead app gives one alert, not four. While PostgreSQL does not
answer, no app's `db_conns` is judged: one host alert, not one per app.

### Scheduled jobs

The agent writes one systemd unit per job of the live release (`tando-<app>_job-<name>.service`,
started by its timer or by `tando jobs run`). How a job last ended is read where `tando jobs`
reads it: the unit's state and result, the exit status of its process and the time the run ended,
asked in the run's one question to systemd for every app unit. No program is started and no
journal read for it.

- **Once per failed run.** A failed run fires `job.<name>` at once. While it fires, nothing is
  sent again for the same run (and no reminder is needed to know: `tando alerts` shows it); the
  next run that fails is one more message with its own exit status and time. A job that fails on
  every run flaps like any check: after `flap_max` (3) firings within `flap_window` one
  "flapping" notice, then silence until it is quiet, so a job scheduled every minute does not
  send 60 messages an hour.
- **Resolved by the next success**, at once (one good run, not `resolve_after` samples).
- **Never ran, or running now**: not a failure, nothing changes.
- **`tando jobs run <name>` by hand** starts the same unit: a run by hand that fails fires (or is
  the "next failed run"), one that succeeds resolves. That is the way to clear an alert after
  fixing the job, without waiting for its schedule.
- **Removed from tando.conf** (and deployed, or gone with a rollback: the jobs are those of the
  live release): its alert resolves once with "the job is no longer scheduled" and its state is dropped.
- **Not held with the app**: a job's alert does not wait for deploys, `tando stop` or `down`.
- **After a restart of the host** systemd no longer knows the last run: an alert that fires stays
  until the job next succeeds; a failure from before the restart that was not yet seen is lost.
- `job=off` or `<app>.job=off` turns it off (all jobs of the app; there is no switch per job).

### PostgreSQL

Asked once per run, and only on a host where an app has `database = postgres`: one `psql` as the
`postgres` user over the local socket, as the agent connects (a superuser slot: it gets in when
the apps hold every other slot), with a connect timeout of 3 s, a statement timeout of 4 s and
10 s for the whole call, after which the run goes on without an answer (that is the `postgres`
alert). One query reads `max_connections`, the reserved slots, the number of client sessions,
and each `tando_*` role's connection limit and sessions; every 5 minutes (or `disk_every`, when
shorter) a second one in the same call reads the databases' sizes (`pg_database_size`, which stats every file of a
database: not every minute).

- **The size has no threshold of its own**: no number fits (50 MB and 50 GB are both healthy
  databases). What matters is the disk, so the database counts as the app's disk use against the
  existing per-app allowance `app_max_mb` (check `disk` above), and the host's `disk` check
  watches the file system itself. `tando status <app>` and `tando health <app>` show it:
  `database  postgres  412 MB, 3 of 10 connections` (`--json`: `"database":{"bytes":...,
  "connections":...,"connection_limit":...}`), as last read (the size up to 10 minutes old).
- **The limit is the server's**: `db_conns` compares against the role's `CONNECTION LIMIT` as
  PostgreSQL reports it, so a limit changed by hand is followed; a role without a limit is only
  covered by the host's slots.
- **The database's own numbers** (as Cloud SQL and RDS show them), in the same `psql`, never a
  connection of their own: per app database its sessions by state (active, idle, idle in
  transaction, waiting for a lock) against `max_connections`; commits and rollbacks; rows
  returned, fetched, inserted, updated, deleted; blocks hit and read (the cache hit ratio);
  deadlocks; temporary files and bytes; conflicts; `stats_reset`; the oldest open transaction
  (`pg_dump`'s and tando-watch's left out) and the longest idle-in-transaction session;
  `age(datfrozenxid)`; the size every 5 minutes. For the server: checkpoints timed and requested
  (`pg_stat_bgwriter` up to PostgreSQL 16, `pg_stat_checkpointer` from 17) and WAL bytes
  (`pg_stat_wal`, 14 and newer). The statement that depends on the version is chosen by
  `server_version_num` as the previous run saw it (the first run after a start has none).
  Written to `/var/lib/tando/metrics/<app>.db` (root, 0600), one line a minute, the counters raw:
  readers take differences, and a counter that went down or a changed `stats_reset` is a gap,
  never a negative rate. `tando-metrics read-db <app> <points> <bucket>` gives the rates per
  bucket and `tando snapshot --json --app <app>` the `database` object (docs/COMMANDS.md).
  Idle in transaction is shown, not alerted: every app's role ends such a session after 5 minutes
  (`db_idle_tx_timeout`). tando-watch's `psql` runs as the `postgres` superuser, which reads every
  session and statement: no `pg_monitor` grant is needed.
- **It cannot make PostgreSQL look down.** The `postgres` alert fires when the `psql` fails or
  times out, and `psql`'s exit status is its last statement's. So the new statements run before
  the connections, which stay last; each under a statement timeout of 500 ms (set just before
  them, 4 s again just after), so together they add at most 2 s, and the whole call may take
  10 s (8 s before); one that fails (a view the version lacks) only loses its rows.
- **Top statements** (`pg_stat_statements`), only after `tando host setup <host>
  --pg-stat-statements`, which asks first: it adds the module to `shared_preload_libraries`, so
  PostgreSQL restarts once (every app's database away for a few seconds), and creates the
  extension in the `postgres` database only (the view covers every database; the apps cannot
  connect there, so they do not see each other's statements). `track_utility` is off: statements
  such as `ALTER ROLE ... PASSWORD` keep their literals and are never recorded. The checks never
  install it; while it is on, each app's 10 statements with the most total time (calls, total
  and mean time, rows; normalized: constants are `$1`, never values; the text cut to 500
  characters) are written to `<app>.dbtop` (0600), the latest only, never into the history.
- Measured cost: see "Cost".

### Settings

`tando alerts set` shows every setting; `tando alerts set key=value` changes it in
`/opt/tando/alerts.conf`. `<app>.<key>=value` overrides it for one app, `<check>=off` (or
`<app>.<check>=off`) turns a check off, `key=` goes back to the default. Host checks that share a
name with an app check are switched with `host_memory=off` and `host_oom=off`; every job of an
app with `job=off` (or `<app>.job=off`).

| Setting | Default | Meaning |
|---|---|---|
| `down_after` | 2 | samples with the unit not running before `down` fires |
| `health_fails` | 3 | failed health probes in a row before `health` fires (tando.conf `health_fails` overrides it for the app) |
| `liveness` | 3 | failed health probes in a row, with the app's unit running, after which tando-watch restarts the app (through `tando-agent restart`; at most 3 times an hour, then only the alert); 0 = never |
| `health_timeout` | 10 | seconds per probe (one value for the host: all probes run together) |
| `http_min`, `http_pct` | 5, 10 | 5xx answers and % of requests within 5 min before `http` fires |
| `slow_ms`, `slow_min`, `slow_for` | 3000, 10, 5 | p95 latency in ms; requests a minute needed; slow minutes in a row |
| `err_spike` | 20 | error events in the app log within 5 min (and 5x the usual rate) |
| `err_new_min` | 30 | minutes after a deploy in which a never-seen error type is reported |
| `logs_quiet` | 15 | minutes without dropped lines before `logs` resolves |
| `include_log_lines` | off | `on`: crash notifications carry the app's last 10 lines. Off by default: log lines can hold secrets; messages carry types, counts and ids instead |
| `mem_pct`, `mem_for` | 90, 5 | app memory threshold (% of MemoryMax) and samples |
| `restarts_max`, `restarts_window` | 3, 15 | restarts within that many minutes |
| `oom_quiet` | 30 | minutes without a new OOM kill before `oom` resolves |
| `disk_pct`, `inode_pct` | 90, 90 | |
| `mem_avail_pct`, `psi_pct`, `swap_pct`, `host_for` | 5, 30, 80, 5 | host memory and swap, samples |
| `load_pct`, `load_for` | 100, 15 | 5-min load as % of CPUs, samples |
| `tls_pct`, `tls_every` | 20, 360 | % of certificate lifetime left; minutes between checks |
| `backup_hours` | 50 | |
| `disk_every`, `disk_stop_pct` | 10, 95 | minutes between measurements of each app's disk use; % full of its file system at which an app over `app_max_mb` is stopped (0 = never) |
| `stuck_min` | 20 | |
| `db_conn_pct`, `db_conn_for` | 80, 5 | connections of an app's database role as % of the role's limit (8 of 10), and for host `postgres` the server's client sessions as % of its usable slots; samples in a row |
| `caddy_every` | 5 | minutes between Caddy config validations (only after a change) |
| `resolve_after` | 2 | good samples in a row before a firing alert resolves |
| `sample_seconds` | 60 | seconds one sample stands for: a second run within it (tandod's tick and one asked for, the agent's run after a rollback) re-evaluates but does not count again; 0: every run counts (the test suites) |
| `remind_hours` | 6 | reminder while it keeps firing (0 = never) |
| `flap_max`, `flap_window` | 3, 60 | firings within that many minutes that count as flapping |
| `deploy_grace` | 120 | seconds after an activation in which the app is not checked |
| `boot_grace` | 180 | seconds after the host started in which apps, memory and load are not checked |
| `monitor_cost_days`, `monitor_cost_x`, `monitor_cost_cap_ms` | 7, 2, 600 | days of data before `monitor_cost` judges; times its normal CPU a minute; and the ceiling in ms a minute (1% of one core) |
| `heartbeat_every` | 5 | minutes between heartbeat pings |
| `notify_reboot` | yes | one notification when the host has restarted |
| `name` | hostname | host name in messages |

### Per app in tando.conf

```
health = /health              # the path probed (exists)
health_expect = 200 ok        # status (200, 2xx) and/or a text the answer must contain; default any 2xx/3xx
health_fails = 2              # failed probes in a row before it fires (default: alerts health_fails, 3)
health_recover = 3            # good probes in a row before it resolves (default: alerts resolve_after, 2)
```

They travel with `tando up` (checked on the laptop with a `tando.conf:<line>` message and again on
the server). There is no per-app interval: every check runs once a minute (one timer, one process
for the host), so a failure is seen within a minute and `health_fails` x 1 min is the time to an
alert. `health_fails` and `health_recover` are the anti-flapping knobs: one bad minute does not
page you, one good minute does not resolve it.

## Errors in the app's own log (`tando errors`)

No agent runs inside the app: tando reads the two things it already owns, the app's journal and
its Caddy request log. Once a minute (`tando-logs watch-scan`, started by tando-watch for every app
in one process) it reads only what was written since the last run: the journal from a saved
cursor (at most 20,000 entries a run; the newest are kept when more arrived), the request log
from a saved file position (at most 8 MB; a line still being written waits for the next run).

An **error event** is a line that looks like one (a level word or a JSON level of error and above,
or error/exception/panic/traceback/unhandled/fatal/critical as a word) together with the stack trace
lines that follow it from the same process within 2 seconds: Node (`TypeError: ...` then
`    at f (file:l:c)`), Python (`Traceback (most recent call last):`, the `File` lines and code, the
final `KeyError: ...`, chained exceptions; a `logging.exception` line before it), Go (`panic: ...`,
`goroutine 1 [running]:`, functions and file lines). Events are grouped by a **fingerprint**: the
exception type and the first frame of the app's own code (not node_modules, node: internals,
site-packages, runtime.), with numbers, hex and ids replaced and line numbers dropped, so a group
survives a redeploy; a plain error line is grouped by its text with numbers and ids folded. Each
group keeps its count per hour (7 days), first and last seen, the release live when it first
appeared, and one sample (30 lines); at most 200 groups per app (the least recent are dropped, but a group known before the scan and
seen in the last 7 days only after every group new in it: docs/LOGGING.md 4b).
State: `/var/lib/tando/logscan/<app>/` (root 700).

```
$ tando errors -a boom
╭─ errors boom ─────────────────────────────────────────────── test  last 24h ─╮
│ COUNT  LAST (GMT)   FIRST (GMT)  RELEASE          ERROR                      │
│     2  11-15 01:42  11-15 01:42  20261115-013512  TypeError at nodeErr (ser… │
│     2  11-15 01:42  11-15 01:42  20261115-013512  KeyError at /srv/app/view… │
│     1  11-15 01:42  11-15 01:42  20261115-013512  Go panic at main.handler   │
│     3  11-15 01:42  11-15 01:42  20261115-013512  ERROR db timeout after 10… │
├─ 2 x  TypeError at nodeErr (server.js)  [92408073] ──────────────────────────┤
│   TypeError: Cannot read properties of null (reading 'foo')                  │
│       at nodeErr (/opt/tando/apps/boom/releases/20261115-013512/server.js:1… │
```

`--since 6h` (1 minute to 7 days; counts are per hour), `-n N` groups, `--json`. Everything shown
went through the client's `strip` (control characters, bidi overrides).

**What is sent and what is not.** Log lines and request paths are written by the app and its
visitors. Notifications carry the exception type and frame (`TypeError at nodeErr (server.js)`),
counts and the group id; a plain error line is "an error line" with its id; never its text. With
`tando alerts set include_log_lines=on` crash notifications also carry the app's last 10 lines.
Every text sent is control- and bidi-stripped, cut to 300 characters and JSON-escaped; request
paths come folded (`/users/:n`) and cut to 80. Parsing runs as root in tando-logs (Go; text is data, never evaluated), with a cap
on lines and bytes per run and on each line's length.

## Uptime and incidents (`tando health`)

Each run records one line per app (`/var/lib/tando/watch/probe/<app>`: time, class, probe ms; 7
days) and each availability alert as an incident (`/var/lib/tando/watch/incidents/<app>.tsv`:
start, end, check, cause; at most 200). Minutes during deploys, boots and `tando stop` are not
counted.

```
$ tando health
╭─ health ────────────────────────────────────────────────────────────── test ─╮
│ APP   NOW      UP 24H    UP 7D  PROBE P95  PROBE LATENCY 24H         INC 7D  │
│ boom  ✗ http  100.00%  100.00%      33 ms  ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁█       1  │
│ h1    ● ok    100.00%  100.00%      71 ms  ▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁█       0  │
├─ recent incidents ───────────────────────────────────────────────────────────┤
│ START (GMT)  APP   CHECK  LASTED       CAUSE                                 │
│ 11-15 01:52  boom  http   ongoing, 4m  29 of 58 requests answered 5xx (50%)… │
╰─ P95: tando-watch's probe, 24 h; real traffic: tando requests ─── 01:56 GMT ─╯
```

Three p95s, three populations: `tando health`'s is tando-watch's own probe through Caddy, once a
minute over 24 h (`PROBE P95`; `probe 24h` for one app); `tando requests`' is the real requests of
its window (`latency ... real requests, 1h`); the `slow` alert's is real requests per minute.

`tando health <app>` adds p50/p95, the 24-hour latency sparkline, up to 15 incidents and the last
lines the app wrote before its last crash or liveness restart. `--json` for both.

## Alert states

Each (app, check) is `ok → pending → firing → ok` (resolved):

- **pending**: a bad sample, not yet enough of them. Samples more than 5 minutes apart do not
  add up (after a reboot or a stopped timer the count starts again).
- **firing**: notified once. A reminder every `remind_hours` while it stays firing.
- **resolved**: after `resolve_after` good samples in a row; notified once, with how long it lasted.
- **flapping**: the third firing within `flap_window` sends one "flapping" notice instead, and the
  check is not notified again until it has not fired for `flap_window`; then its current state is
  sent if it differs from what was last sent.
- **silenced** (`tando alerts silence <app|all> <30m|2h|1d|off>`): states still change and are
  shown, nothing is sent. When the silence ends, whatever is owed is sent once: a firing alert
  that was never sent is sent; one that fired and resolved inside the silence is not.
- **deploys**: while an app's activation runs and for `deploy_grace` after it, its checks are
  held (neither good nor bad), except `stuck`. A failed deploy is reported by the deploy itself.
- **reboot**: the start of PID 1 is remembered; after a restart one "host restarted" notice is
  sent and app checks wait `boot_grace`. Firing alerts stay firing across the restart (the state
  is on disk) and are not sent again.
- `tando stop` (the agent records `stopped` in the app's state and Caddy answers 503) is not an
  outage: the app is not checked until `start`, `restart` or a deploy clears it.
- Static apps have no systemd unit (Caddy serves the files): only `health`, `tls` and `backup`
  apply to them.

All transitions of one run go out as one message per notifier.

**Where they go.** `tando host setup` turns the checks on; nothing else is needed for them to run.
Until a notifier exists, alerts are only visible in `tando alerts`, which then shows one
copy-paste line per notifier type (ntfy first: a phone app, no account). The first `tando up` of
an app says so once. `tando alerts test` shows the message it sent and each receiver's answer
(`HTTP 200`, or why not); a failing notifier is shown by `tando alerts` and by `tando doctor`
(`notifier <name>  failing for 12m: HTTP 500; messages wait in its queue`).

## Notifiers

| Type | Asks for | Sends |
|---|---|---|
| `webhook` | URL | JSON POST: `{"host","title","text","events":[{"state","app","check","detail","since"}]}` |
| `slack` | incoming-webhook URL (Slack, Mattermost, Discord's `/slack` URL, ...) | `{"text": ...}` |
| `telegram` | bot token, chat id; option `api=URL` for a self-hosted Bot API server | `sendMessage` |
| `ntfy` | topic URL (`https://ntfy.sh/<topic>` or your server), optional access token | plain text with Title and Priority headers |
| `email` | address; option `from=ADDR` | through the local `sendmail`; refused when there is none |

Secrets (URLs, tokens, chat ids) are read on the laptop without echo (or from stdin when it is not
a terminal: `printf '%s\n' "$URL" | tando alerts notifier add hook webhook`), sent on ssh's
stdin, and stored in `/opt/tando/alerts.d/notify-<name>` (root 600 in a root 700 directory).
tando-watch puts them into the HTTP request itself (no curl process), never into a program's
arguments or an error message; they are never written to a unit file, the journal, or a
world-readable file. `tando alerts` shows only the scheme and host of a URL.

Delivery is separate from checking: a run first decides and saves state, then queues one message
per notifier in `/var/lib/tando/watch/out/<name>/`, then all notifiers are tried in parallel,
each once per run with a 15 s limit. A failure is retried on later runs with backoff (1, 2, 4,
... 60 min); queued messages are sent together when it works again (at most 100 kept, older ones
dropped and counted). `tando alerts` shows each notifier's last success, failure count, error and
queue. A successful `tando alerts test <name>` ends the backoff.

A run that is killed (a reboot, the unit's timeout, a full disk) neither loses nor repeats a
notification: the run writes what it decided to `/var/lib/tando/watch/commit`, then saves the
state with the id of that file (the commit point), then queues the messages, writes the history
and deletes the file. The next run finishes a committed one and drops one that was not committed
(and decides again). Delivery is at least once: a message leaves the queue after the receiver's
2xx (and a committed run that is finished by the next run may queue again a message a delivery
running at the same moment had just sent: at least once, never lost). Temp files of a run killed
while it queued are swept after 10 minutes.

## Recipe: alerts on your phone and on your laptop

The server sends; nothing is pushed to the laptop by tando itself. Three ways, from the least
setup:

**Phone, with ntfy** (no account; the topic name is the only secret on the public ntfy.sh, so make
it long and random, and keep it out of your repository):

    printf 'tando-%s\n' "$(openssl rand -hex 12)"   # your topic name, e.g. tando-3f9c...
    # in the ntfy app (iOS, Android): + -> subscribe to that topic (server ntfy.sh)
    tando alerts notifier add phone ntfy         # paste https://ntfy.sh/<topic> (not echoed)
    tando alerts test phone                      # the phone should buzz now
    tando alerts heartbeat                       # optional: a dead man's switch (next section)

A self-hosted ntfy server works the same (its URL, and an access token when it asks for one).

**Laptop, the same topic.** In a browser: open `https://ntfy.sh/app` and subscribe to the topic
(desktop notifications when the browser allows them). Or with the ntfy command-line client
(`brew install ntfy`), a macOS notification per alert:

    ntfy subscribe "https://ntfy.sh/<topic>" \
      'osascript -e "display notification \"$m\" with title \"$t\""'

**Laptop, polling with tando** (no third party; it notices a server that does not answer too,
which no notifier can send). `--check` exits 2 when an app is down, an alert fires or a server
does not answer, 1 when tando itself failed:

    while sleep 300; do
      tando ls --all --check > /dev/null 2>&1 ||
        osascript -e 'display notification "tando ls --all" with title "tando: something needs attention"'
    done

**Laptop, the menu bar app** (macOS; new, still being finished): `tando menubar install` puts an
icon in the menu bar that runs `tando ls --all --json` every minute and probes each app's link: a
red count of the problems, a notification once per new problem and once when it clears
(docs/COMMANDS.md, "menubar"). `ls --all --json` carries what such a badge needs: per server
`reachable` and `checked_at`, per app `state`, `alerts_firing` and `firing`, every alert in
`alerts`; `tando alerts --json` adds the notifiers' failures. Like the loop above, it works only
while the laptop is on and online.

## What it cannot see (and the heartbeat)

The server cannot report its own death. If the host is down, frozen, out of network, or the
timer stops, no message is sent at all. `tando alerts` and `tando doctor` say "NOT RUNNING" when
the last run is more than 3 minutes old, but only when you look.

`tando alerts heartbeat` stores a URL (as a secret) that is called after a completed run, every
`heartbeat_every` minutes. Point it at an outside dead man's switch (healthchecks.io, Uptime
Kuma's push monitor, Better Stack heartbeats, ...) with a period of `heartbeat_every` plus a
grace of a few minutes. The ping is skipped while every notifier has been failing for 30 min, so
"alerts cannot be delivered" also becomes a missed heartbeat.

## From outside

Everything above runs on the server it watches. Three things outside it close the gap; each is a
free tier at several services (healthchecks.io, Uptime Kuma on another machine, UptimeRobot and
others: tando needs only a URL, and none of them is required).

| What | Catches | Set with |
|---|---|---|
| **Heartbeat**: the server calls a URL every `heartbeat_every` minutes | the server is down, frozen or cut off; the checks stopped; no notifier can deliver | `tando alerts heartbeat` |
| **Backup ping**: the server calls a URL once after the daily backups, when all of them worked | a backup that failed, did not run, or did not reach the offsite bucket | `tando alerts backup-ping` |
| **An HTTP monitor of your public link** | DNS, the firewall, the provider's network, an expired domain or certificate: what a visitor sees | at the outside service, nothing in tando |
| **The menu bar app** (macOS): your laptop requests every link and reaches every server each minute | the same, plus a server ssh cannot reach; a badge and a notification on the laptop | `tando menubar install` (only while the laptop is on and online: an addition to the heartbeat, not a replacement; docs/COMMANDS.md, "menubar") |

- **Heartbeat.** Until one is set on a server that has apps, `tando doctor` shows a warning row
  (`heartbeat`, not a failure) and `tando alerts` says so in its header. Create a check at the
  outside service with a period of `heartbeat_every` (5) minutes and a grace of a few minutes, then
  `tando alerts heartbeat` and paste its URL. `tando alerts heartbeat off` removes it.
- **Backup ping.** `tando alerts backup-ping` stores a second URL (a secret, like the heartbeat's:
  `/opt/tando/alerts.d/backup-ping`, root 600). It is requested once per run of the daily backups,
  and only when the run was whole: every app with daily backups made one since the last request,
  none failed, and, when offsite copies are on, each of them is in the bucket. A failure sends
  nothing: the outside service notices the missing call. Give its check a period of 1 day and a
  grace of a few hours (uploads of large backups take time). The request is a plain GET of the URL
  as you gave it (nothing is added: no app name, no result), with a 10 s limit. It is made by
  tando-watch's minute run, not by the backup, so a slow or dead receiver cannot delay or fail a
  backup; a failed request is tried again every 5 minutes. `tando alerts` shows the last request (`backups`), or
  why none is sent now (`the last daily backup of <app> failed`); `tando doctor` warns while the
  request itself fails. Only daily backups count (`tando backup now` and pre-deploy backups do
  not); it needs `tando alerts enable` (on after `host setup`). `tando alerts backup-ping off`
  removes it.
- **A monitor of the public link.** Point any outside HTTP monitor at an app's public URL (its
  health path is a good target: `https://<your domain>/<health path>`), every 1 to 5 minutes, with
  a keyword or status check. It needs no access to the server. It is the only one of the three
  that sees what a visitor sees.

Other blind spots, stated plainly:

- **From outside**: the health probe goes through the local Caddy (connected to 127.0.0.1).
  DNS, the firewall, the provider's network, an expired domain or a certificate a visitor's
  browser rejects for other reasons are not seen. An outside uptime check of the public link
  covers those; the heartbeat does not.
- **Between samples**: a crash that systemd restarts within the minute shows only as a restart
  (and as `restarts` if it repeats); a 30-second outage can fall between two probes.
- **Slow, not dead**: a probe that answers within 10 s is healthy. Latency and error rates of
  real traffic are not measured.
- **Inside the app**: a health endpoint that answers 200 while the app is broken.
- **Jobs that do not run**: a failed run of a scheduled job is alerted (`job.<name>`), a job that
  never starts (a schedule that never matches, a timer disabled by hand) or runs for ever is not:
  jobs have no timeout unless their unit is given one, and no "expected by" time. A job that
  exits 0 without doing its work is a success. A job's OOM kill also counts as host `oom`.
- **PostgreSQL from inside**: the checks see that the server answers on its local socket, how
  many connections each role holds and how large each database is. Slow queries, locks, bloat,
  replication, a full `max_connections` caused by roles tando did not make, and a server that
  answers locally but not on 127.0.0.1:5432 are not seen (the apps' own health checks are). An
  app that uses a database tando did not create (its own `DATABASE_URL`) is not watched at all.
- **Kernel and hardware**: disk I/O errors, a read-only remount, clock synchronisation and the
  journal's size are host care's (docs/HOSTCARE.md), checked hourly, not every minute.
- **OOM attribution** uses the journal when the slice counter rises; with a journal that has
  been rotated away or rate-limited, the kill is reported as host `oom` without the app.
- **Load in containers**: `/proc/loadavg` is the whole machine's. Fine on a VPS; in the test
  container it reflects other containers, so the test suite turns `load` off outside its own check.
- **PSI**: kernels without `/proc/pressure` (some containers) use MemAvailable only.

## Cost

**tandod (this version).** CPU of one minute's work, "everything it triggers": the cgroup of the
unit that does it (children included) plus PID 1's (unit starts and systemctl calls cost systemd
too). 20 runs each on a 1-CPU / 2 GB arm64 test container, median per run, apps healthy, no
traffic. "shell" is what the shell version's tando-watch.service ran every minute
(tando-metrics sample, tando-agent recover-all, tando-watch run with the shell tando-logs);
"one-shot" the Go tando-watch of the previous version (still the fallback).

| | shell | Go one-shot | tandod |
|---|---|---|---|
| 3 apps (2 node, 1 static) | 94 ms + 14 ms in PID 1 | 17 ms + 17 ms | **5.9 ms** + 1 ms |
| 20 apps (19 node, 1 static) | 758 ms + 49 ms (of which recover-all 142, run 320, metrics 21) | 47 ms + 38 ms | **15.4 ms** + 1 ms |
| 100 apps (19 node, 81 static) | 2158 ms + 64 ms | 177 ms + 55 ms | **127 ms** + 0 ms |

Per day at 3 apps: about 8.5 s of CPU for tandod's ticks against about 156 s for the shell
units; between ticks tandod uses no CPU and is not woken (0 wakeups in a 40 s window measured with
/proc/<pid>/task/*/schedstat). Memory: 9-11 MB RSS at 3 and 20 apps (`MemoryMax=64M` then, 160M now,
`GOMEMLIMIT=20MiB`); a 65-minute soak with 20 apps and about 240 requests a minute stayed between
8.1 and 10.2 MB, 6 goroutines, 8 open files, no restart, and cost 117 ms a minute with that
traffic (the request-log scan of srv/logs). What is left per tick: the request-log index and
the journal stamps of srv/logs for each app (about 40% at 20 apps, also when nothing was
written), the fsync of srv/metrics' .state, the health probes through Caddy, one bus round trip.
At 100 apps most of the 127 ms is `journalctl --since=-24h` started by the log scan for apps
whose journal has no entry yet (their cursor is never saved, so every minute is a first scan):
a known issue of srv/logs. Repeated measurements on the shared test machine varied by up to
50% (3 apps: tandod 5.9 and 6.6 ms, the shell 94 and 140 ms); the ratios held.

**Jobs and PostgreSQL.** Watching jobs starts nothing: their units are asked on the same bus
connection as the apps' (the one-shot: in its one `systemctl show`). The PostgreSQL question is
the one program the checks start every minute, and only on a host where an app has
`database = postgres`. Measured on the 1-CPU / 2 GB arm64 test container with 5 apps (4 node, 1
static; one with a database and a job), PostgreSQL 18, 3 rounds of 20 runs each, CPU per run of
tandod's cgroup (psql is its child) and of the PostgreSQL cluster's unit:

| | tandod | PostgreSQL |
|---|---|---|
| no app with a database (nothing asked) | 6.8 - 7.4 ms | 0 ms |
| the question (connections) | 21.4 - 22.4 ms | 3.7 - 4.0 ms |
| the question with the sizes (one run in ten) | 22.9 - 23.5 ms | 4.7 ms |

So about 15 ms in psql (most of it starting the program: it loads libpq and what that needs) and
4 ms in the server for the session, 19 ms a run in all: about 27 s of CPU a day, 0.03% of one
CPU. A run with the question took 51 ms of wall time. The call cannot hold a run: psql gives up
connecting after 3 s, the server ends a statement after 4 s (the database's numbers after
500 ms), and the program is killed after 10 s. The database's numbers were added after these
measurements and not measured yet.
Speaking the protocol from tandod itself would save the 15 ms but needs a password login for a
monitoring role; not done.

**What the monitoring costs, recorded.** Since 2026-11 every minute's sample also writes
`tandod.x`: tandod's CPU (its cgroup, with the programs it starts), anon memory, page cache,
major faults, refaults, the programs it started and the readers' requests (docs/TOP.md). `tando
snapshot --json --range R` returns it as `host_metrics.monitoring`, and `monitor_cost` alerts on
it after a week. The extended host sample itself (host.x, the slice columns, tandod.x) costs
3.4–4.3 ms of CPU a minute at 25 apps on Linux (BenchmarkSampleMinute, fake /proc and /sys).

**Where tandod's CPU goes.** `sudo /opt/tando/bin/tando-status cost` on the server asks tandod for
its own cost by section, kept in memory since it started (no restart, nothing to switch on): one
`costs` row (seconds running, ticks, its CPU and its programs' CPU in ms), then `cost last|total
<calls> <wall ms> <cpu ms> <programs' cpu ms> <programs> <section>` for every check of the minute
tick, the metrics sample, the log scan (`check logscan`: its journalctl runs are the programs),
the health probes, the commit, the live loop and each socket verb. `last` is the last minute,
`total` since the start. A section's cpu is the whole process's while it ran (the live loop running
at the same moment counts in it). For a CPU profile, add `Environment=TANDOD_PROFILE=/var/lib/tando/tandod.pprof`
in a drop-in of tandod.service (`systemctl edit tandod`), restart, wait, then `systemctl stop
tandod` writes it (`go tool pprof`); remove the drop-in afterwards.

Measured this way on the Docker test server (25 apps, 12 logging a line a second with an error
every 20 s, one 300 MB journal; a laptop core, 4 minutes each): 153 ms of CPU a minute, of which
the flush to disk of every logging app's error counts each minute was the largest part. Those counts (and the metrics' previous
counters, the request log position) are now replaced atomically without the flush: a power cut
costs a minute of counts; a new error group is still flushed. After: 80 ms a minute (the live
loop about 20, the log scan about 30 plus 22 for its journalctl runs, the metrics sample 4). The per-app journalctl of the scan
costs about 2 ms each; one long-lived `journalctl -f --namespace='*'` cost more (about 120 ms a
minute for the same traffic, waking on every line), so the scan keeps its per-minute runs.

**The Go tando-watch.** `tando-watch run` alone, in a transient unit (systemd's CPU accounting of
its cgroup, children included), shell and Go interleaved, 20 runs each, median [min-max], on the
1-CPU / 2 GB arm64 test container (apps healthy, nothing firing, no deliveries):

| | shell | Go |
|---|---|---|
| 3 apps (2 node, 1 static), with `tando-logs watch-scan` | 61 ms [58-65] | 15 ms [14-24] |
| 3 apps, without the scan | 39 ms [38-42] | 9 ms [8-12] |
| 20 apps (19 node, 1 static), with the scan | 166 ms [156-205] | 56 ms [51-74] |
| 20 apps, without the scan | 101 ms [96-106] | 21 ms [20-23] |

The Go run forks only systemctl (once), tando-logs (once) and, when needed, journalctl, du, nft,
caddy; probes, certificates and deliveries are in-process HTTP, df is statfs. The binary is
about 6.5 MB (net/http and TLS). The numbers below are the shell version's.

**With the error and request scan (this version).** Measured with `systemctl show -p
CPUUsageNSec` of the whole unit (metrics sample, recover-all, the run, tando-logs watch-scan), 5
apps on the 1-CPU test container, one app logging about 100 lines a second and two apps getting
traffic (one with 5xx): **before 154 ms per run on average, after about 260 ms** (6-8 runs each).
The scan alone is 80-130 ms for the 5 apps: one journalctl and one awk per app, a stat (and tail,
head, awk only when the request log grew). A first version that forked sed/grep/od per app cost
450 ms; the forks were cut. Its ceiling is set by the caps (20,000 journal entries and 8 MB of
request log per app and run): an app that wrote 30,000 lines and 30 stack traces in a minute
costs 0.18 s of CPU for its scan (0.22 s wall), measured. Disk: each run now appends about 20 bytes per app to its uptime
record (about 30 KB per app and day, trimmed to 7 days) and rewrites the scan cursors.

**Before this version:**

Measured on the test container limited like the real VPS (`--cpus 1 --cpuset-cpus 0 --memory
2g`; arm64 M1 core, Ubuntu 26.04, systemd 259), with `systemctl show` of the service after each
run (its cgroup holds the script, curl, systemctl, df), 20 runs each, median [min-max]. An x86
VPS vCPU is slower; expect higher CPU-milliseconds, the same memory and bytes.

| | 2 apps | 5 apps | 10 apps |
|---|---|---|---|
| CPU per run | 29 ms [25-95] | 35 ms [31-42] | 48 ms [43-67] |
| wall time per run | 34 ms | 43 ms | 62 ms |
| peak memory of the run | 5.0 MB | 4.4 MB | 5.0 MB |

Since tando-metrics' sample runs in the same unit (`ExecStartPre`) and the Caddy and
dead-activation checks were added, a run measures **50 ms [47-57] at 5 apps and 66 ms [62-79]
at 10 apps** (before the Caddy checks: 48.5 and 64.0 ms, same apps and container). Caddy's state
comes from the same `systemctl show` call; the dead-activation check forks `flock` only while an
app's phase is not idle. A run that validates the Caddy config costs about 35 ms more (about
100 ms at 10 apps); that happens only after a file under /etc/caddy changed, at most every 5 min.

Of the first 10-app run: one curl for all health probes 7-8 ms, one `systemctl show` 8-9 ms, df 3 ms,
bash start 3 ms; the rest is the script. CPU per day at 5 apps: about 50 s (0.06% of one CPU).

Disk: a run with nothing changing writes **0 bytes** (state and history untouched; the volatile
counters live in `/run`, a tmpfs) and logs **0 journal lines** (`LogLevelMax=notice` also hides
systemd's start/finish lines for the unit). Each transition rewrites the state file (about 1-3 KB),
appends one history line (about 120 B) and one queued message per notifier (about 200 B, deleted
once delivered). A day with 20 transitions writes well under 100 KB.

## Files

```
/opt/tando/bin/tando-watch                  root 755
/opt/tando/alerts.conf                      settings (644)
/opt/tando/alerts.d/notify-<name>           notifier secrets (root 600, dir 700)
/opt/tando/alerts.d/heartbeat               heartbeat URL (root 600)
/opt/tando/alerts.d/backup-ping             backup ping URL (root 600)
/var/lib/tando/watch/state                  alert state, key=value, temp file + rename, only on change (root 600)
/var/lib/tando/watch/history.tsv            transitions; trimmed to 1000 lines past 2000 (root 600)
/var/lib/tando/watch/out/<name>/            queued messages (root 700; no secrets)
/var/lib/tando/watch/commit                 a run's decided effects until applied (root 600, see Notifiers)
/run/tando-watch/                           volatile: last run, heartbeat time, per-app counters, the last
                                            size and connections of each app's database (tmpfs, 700)
/var/lib/tando/watch/probe/<app>            one line per run: time, class, probe ms; 7 days (root 600)
/var/lib/tando/watch/incidents/<app>.tsv    start, end, check, cause; at most 200 (root 600)
/var/lib/tando/watch/tail/<app>             the app's last 10 lines at its last crash/restart (root 600)
/var/lib/tando/logscan/<app>/               scan cursor and position, error groups, samples (root 700)
/etc/systemd/system/tandod.service                  the daemon (checks, metrics sample, log scan each minute)
/etc/systemd/system/tando-watch.{service,timer}     a run now; the timer, which starts tando-watch-fallback.service
/etc/systemd/system/tando-watch-fallback.service    the checks when tandod is not running (skipped while it is)
/run/tandod/tandod.sock                               tandod's socket (root 600 in a root 700 directory)
```

Server verbs (`/opt/tando/bin/tando-watch <verb>`): `run` (timer), `install`, `uninstall`,
`show`, `history [n]`, `doctor` and `brief [app]` (no root; rows for `tando doctor` and
`tando status`: alerts, and as root the `pg` row of one app's database), `health [app]` (rows for `tando health`), `set`, `notifier-add`, `notifier-rm`, `heartbeat` (stdin), `silence`, `test`,
`tando status`), `health [app]` (rows for `tando health`), `set`, `notifier-add`, `notifier-rm`, `heartbeat` (stdin), `backup-ping` (stdin), `silence`, `test`,
`forget <app>` (drops an app's alert state at once; `tando destroy` calls it), `version`. The
program is Go (`srv/watch`, structure in srv/README.md); the shell original is
`server/legacy/tando-watch`.
Numbers in settings are decimal: `08` is 8.
Tests: `test/e2e-alerts.sh`.
