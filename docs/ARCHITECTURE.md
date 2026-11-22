# tando architecture

Laptop CLI in bash 3.2 talks over ssh to root-run server programs. Nothing stays running between
calls: work happens in commands, transient units and one per-minute timer.

## Files

| Path | Role |
|---|---|
| `bin/tando` | entry point: flags, dispatch, host/env/rollback/backup/db/destroy/unlock commands |
| `lib/help.txt`, `lib/args.sh` | every command's help, flags and argument counts; checked before anything runs |
| `lib/common.sh` | messages, validation, host registry, ssh options, tando.conf parser, agent calls |
| `lib/build.sh` | `init`, build step, staging, release guard, npm platform-package swap and the fixes for other native packages (planned by `lib/native.js`, which reads JSON and file headers, and downloads declared prebuilt binaries; docs/CROSS-ARCH.md) |
| `lib/deploy.sh` | `configure`, upload lease and rsync, activation polling, deploy box |
| `lib/views.sh` | boxed views: ls (one host, `--all`), status, history, releases, jobs, env, backups, doctor, host ls |
| `lib/ui.sh` | boxed UI library |
| `lib/cmd-logx.sh`, `cmd-requests.sh`, `cmd-audit.sh` | `tando logs`, `requests`, `audit` (docs/LOGGING.md) |
| `lib/cmd-top.sh`, `lib/cmd-alerts.sh`, `lib/cmd-ci.sh` | `tando top` (docs/TOP.md), `alerts` (docs/MONITORING.md), `ci` (docs/CI.md) |
| `lib/cmd-domain.sh`, `lib/cmd-adopt.sh` | `tando domain` (DNS check, then the site), `adopt` (docs/MIGRATION.md) |
| `server/tando-agent` | the server program: apps, releases, activation, backups, database, status |
| `srv/` (Go): `cmd/tando-metrics`, `metrics/` | per-minute samples of each app (memory, cpu, restarts) for graphs (srv/README.md) |
| `srv/` (Go): `cmd/tando-watch`, `watch/` | alert checks and notifiers; the structure is in srv/README.md |
| `srv/` (Go): `cmd/tandod`, `daemon/` | tandod, the monitoring daemon: each minute the metrics sample, the checks and the log scan in one process; a root-only socket for the read verbs (docs/MONITORING.md "How it runs"); `tando-watch.timer` is the switch and the fallback |
| `srv/` (Go): `cmd/tando-gate`, `gate/` | login shell and forced command of CI deploy keys (`tando-d-<app>`), their sudo root mode, the confined receiver, key management (srv/README.md, docs/CI.md) |
| `srv/` (Go): `cmd/tando-logs`, `logs/` | journald namespaces, Caddy request logs, log queries and stats, the per-minute error and request scan, audit file (docs/LOGGING.md, srv/README.md) |
| `srv/` (Go): `cmd/tando-status`, `status/` | the agent's read-only verbs `status`, `deploy-status`, `releases`, `history`, `busy`, `info`: tando-agent execs it for them (srv/README.md) |
| `srv/` (Go): `cmd/tando-offsite`, `offsite/` | offsite backups: S3 API by hand (SigV4), streaming AES-256-GCM encryption, upload after each backup (the agent starts `push` in a unit of its own), `tando-offsite.timer` retries and prunes, fetch for restore, disaster recovery verbs (docs/BACKUP.md, srv/README.md) |
| `srv/` (Go): `cmd/tando-studio`, `studio/` | `tando db studio`: a read-only web UI and SQL editor for an app's database, on a unix socket forwarded by the admin's ssh; its own PostgreSQL wire client (`studio/pgwire`), statement splitter and name checks (`studio/sqlsplit`), the scope guard's plan check (`studio/scope.go`) and page (`studio/ui`); `lib/studio.sh` is its client (docs/COMMANDS.md, srv/README.md) |
| `lib/offsite.sh`, `lib/cmd-restore.sh` | `tando backup offsite ...` and `tando restore [--from-host]`, their client side |
| `srv/` (Go): `cmd/tando-host`, `hostcare/` | host care: the server itself (updates, security, health), its summary for the alerts, care mode (unattended-upgrades, the safe reboot); `lib/hostcare.sh` is its client (docs/HOSTCARE.md) |
| `scripts/build-server.sh` | builds the Go server programs into `dist/server/linux-{amd64,arm64}/` |
| `test/e2e*.sh`, `test/all.sh` | end-to-end suites, each on its own test server (docs/TESTING.md) |

`tando host setup` takes a fresh Ubuntu 24.04+ (sshd and a sudo login) to a ready server, in
steps the client shows as they finish: the server programs in `/opt/tando/bin` (root 755: `tando-agent`, `tando-logs`, `tando-metrics`, `tando-watch`, `tandod`, `tando-status`, `tando-offsite`, `tando-host`, `tando-studio`, `tando-gate`, `tando-install-recover`)
with `/opt/tando/VERSION`; rsync, curl, nftables, openssl and Caddy (the distribution's package)
from apt; the Caddyfile's `import` and admin socket; the firewall unit (and 80/443 in ufw when ufw
is active); recover/down units, journals, a swap file under 2 GB of RAM; the alert timer. Every
step writes only what differs, so a second run changes nothing and does not reload Caddy.
Runtimes come with the first app that needs one (`configure check` lists them, the client calls
`runtime`): Node from nodejs.org (checksummed) at the project's major (`node =`, .nvmrc, engines),
python3-venv, podman, PostgreSQL. `tando doctor` checks every piece and names the fix.

## Commands and plugins
lib/help.txt holds each command's usage, description, flags (`-n=` takes a value) and argument
counts. Before a command runs, lib/args.sh answers `-h`/`--help` anywhere with that help (the
command never runs) and refuses unknown flags, missing values, unknown subcommands and extra
arguments (exit 2, with the usage lines). Flags may also come before the command.
`tando X ...` without a core function sources `lib/cmd-X.sh` and calls `cmd_X "$@"`; a plugin
without a help.txt section is listed by its `# help: <usage>  <text>` line and not checked. Before
the call, `parse` has set `APP`, `HOST` (from `-a`, `-H`), `WATCH`, `FOLLOW`, `LINES`, `ALL`,
`PURGE`, `SHOW`, `JSON`, `YES`, `FORCE`, and `ARGS` (the remaining words, `ARGS[0]` is the
command; plugins also find `--json`, `--yes`, `--force` there). `TMPD` is a private temp dir
removed on exit; `ui_init` has run. Stable helpers:

| Helper | Use |
|---|---|
| `resolve <0/1>` | settle `APP`/`HOST` from flags, tando.conf or the only host; 1 = app required. Sets `TARGET`, `SSHO` |
| `host_use <name>` | select a registered host: sets `HOST`, `TARGET`, `SSHO` (ssh options incl. ControlMaster; the shared connection stays 10 minutes after the last use, `ControlPersist=600`) |
| `host_get <name> <key>` | read `target`, `port`, `key`, `insecure` from the registry |
| `conf_load [file]` | parse tando.conf into `C_app`, `C_host`, `C_recipe`, ... `C_jobs` |
| `agent_raw [sudo] <verb> <args...>` | run an agent verb; output stripped of control characters; returns its status. Arguments must match `[A-Za-z0-9_.:=/@,+-]+` |
| `agent [sudo] <verb> <args...>` | same, exits (closing an open box) on failure |
| `kv_read <file> <keys...>` | read `key=value` output into `K_<key>` for the listed keys only |
| `die <msg>`, `note <msg>`, `bail [code]` | error and exit (closing an open box), message to stderr, exit |
| `usage_err <msg> [cmd]`, `confirm <text> <word>` | exit 2 with the command's usage; ask to type a word (`--yes` skips) |
| `ssh_explain <errfile>` | turns an ssh/sudo/missing-agent failure into one sentence and the next command |
| `strip` | filter: drop control characters except tab and newline |
| `valid_app`, `valid_id`, `valid_host`, `is_num` | validation predicates |
| `clock`, `since <t0>` | seconds with one decimal (perl) or whole seconds |
| `fetch_hosts <host...>` | `status` from hosts in parallel into `$TMPD/h.<host>.{st,rc,err}`, 10 s cap |
| `ui_*` | see the header of lib/ui.sh |

Server output is never evaluated or sourced. Free text (env values, start commands, job
commands, settings) travels to the agent on stdin, never in the remote command line.

## Agent verbs
Read-only (no sudo): `info`, `status [app]`, `releases`, `history [app] [n]`, `deploy-status <app>
<id> [wait=<phase>]` (with `wait=`: answered once the activation is past that phase or has a
result, at most 10 s later, with `waited=1`; the client's one call per phase instead of a poll every
0.5 s, an agent without it answers at once), `jobs`, `logs`, `doctor <client cksums> <client version>`. Root: `setup` (prints `step=<name> run|ok <detail>`
lines as it goes), `runtime <node [major]|python|podman|postgres>`, `configure` (stdin settings;
`check=1` only validates and prints `exists`, `current`, `needs` (missing runtimes), `domains`;
`origin=` refuses a deploy from another directory unless `force=1`; an unchanged app.conf with
the same agent skips the rest), `domain-add <app> <domain> <www>`, `domain-rm`, `domain-ls`,
`domain-check` (waits for a valid certificate, or prints Caddy's error),
`begin`/`end` (upload lease; `end` reads the token on stdin), `activate <app> <build s> <upload s>`
(token on stdin; the older form with the token as second argument still works), `rollback [id]`,
`recover`, `env-set/-unset/-ls` (stdin), `start/stop/restart`, `unlock`, `destroy [purge|plan]`,
`backup-run <kind>`, `backup-ls`, `backup-cat`, `backup-restore`, `db-url`, `db-psql`,
`db-studio <app> ro <sid> <idle-min> <port> <host>` (the older per-session studio, for as long as its
ssh session, still used against a server without the studio service: relays only its `ready` and
`stopped` lines), `db-studio-ls [app]` (`database=`, `installed=`, then
`studio <app> <sid12> <started> <mode> <admin>` rows; without an app also `app <name> <database 0|1>
<bytes> <state>` rows for the client's picker), `db-studio-stop [app]` (`stopped=N`),
`shell <app> [hex command]` (a shell, or one command, as the app's user in its sandbox: its env,
cwd its current release, only shared/ writable), `busy <app>` (what holds the app: `busy=<id>`,
`busy_phase`, `busy_left`, `busy_soak`; the client says what it waits for), `job-run <app> <name>`
(runs a scheduled job now: `log=` lines, `result`, `status`, `secs`). `env-set`/`env-import` for an
app that does not exist yet keep the values in `/opt/tando/staged/<app>` (`staged=1`); the first
`configure` applies them. tando-watch takes events from other programs (an automatic rollback)
in its inbox `/var/lib/tando/watch/inbox`; the log verbs
`logs`, `log-stats`, `req-summary`, `req-tail`, `req-errors`, `audit-read` are handed to tando-logs.
Read verbs run through sudo for the admin and as the deploy user for a CI key (via tando-gate).
Every mutating verb writes one audit line (`tando audit`). Internal
(run by systemd): `run-activation`, `recover-all`, `exec-app` (as the app user; as root for
containers), `container-stop`, `app-down` (tando-down@ when a unit has failed), `run-job` (as the
app user), `exec-worker <app> <name>` (as the app user, in a worker's unit), `backup-run daily`. `info` prints `version` (from /opt/tando/VERSION), `arch`, `libc`,
`apps_domain`, `tls`, `sum` (agent checksum), `podman`, `python`. Output: `key=value` lines, or tab-separated rows whose first field names the row type (`host`,
`app`, `worker`, `rel`, `hist`, `env`, `job`, `backup`, `check`); empty fields are `-`. New fields are only
appended.

## Server state

```
/opt/tando/host.conf                 apps_domain, tls, port range, public_port, postgres, postgres_version
/opt/tando/apps/<app>/app.conf       port, recipe, start, health, path, data, writable, backup, database,
                                     job.*, domains (domain|www ...), origin (user@machine:dir)
/opt/tando/apps/<app>/state          current, last_good, phase, target, kind, prev, fallback, status_<id>,
                                     last_backup, applied (checksum of the last configure)
/opt/tando/apps/<app>/activation     progress of the latest activation (phase, result, t_* seconds)
/opt/tando/apps/<app>/upload         upload lease: token, who, started, id
/opt/tando/apps/<app>/{incoming,releases/<id>,current,shared,env,history.tsv,lock,lease.lock}
/opt/tando/apps/<app>/jobs/<id>      the job.* lines release <id> was deployed with (root 600); the
                                     job units are always those of the current release
/opt/tando/apps/<app>/lock.holder, lock.wait.<pid>   which verb holds the app's lock / waits for it
/opt/tando/.{host,domains,fw,ports}.lock, staged/.lock   host-wide locks (setup+runtime, domain
                                     owners, firewall file, new ports, staged env)
/var/backups/tando/<app>/<YYYYMMDD-HHMMSS>-<kind>/   data.tar.gz, db.dump, meta (root 700); offsite (its upload state), fetched (came from the bucket)
/opt/tando/offsite.conf, offsite.key, offsite.id     offsite settings + credentials, recovery keys (root 600), host id (docs/BACKUP.md)
/var/lib/tando/offsite/state/<app>, host             offsite state per app (for alerts and status) and of the credentials
/etc/systemd/system/tando-<app>.service, tando-<app>_job-*.{service,timer}, tando-<app>_worker-*.service, tando-<app>-backup.*
/etc/caddy/tando/<app>.caddy        (all key=value files are written to a temp file and renamed)
/etc/systemd/journald@tando-<app>.conf, /var/log/journal/<id>.tando-<app>/   the app's own journal
/var/log/tando/<app>/access.log*, /var/log/tando/audit.log    request log, audit trail
/var/lib/tando/metrics/<app>.tsv*, /var/lib/tando/watch/      metrics samples, alert state
/opt/tando/ci/<app>/, /etc/sudoers.d/tando-d-<app>             deploy keys of the app
```
Every verb that changes an app takes its lock first and reads app.conf and state after it (never
a copy read before). state, app.conf, host.conf, env and the firewall file are written to a temp
file, flushed to disk and renamed; an unchanged file is not rewritten.
Modes: app.conf, state, activation, history.tsv and the upload lease are root:tando-m-<app> 640
(the app user and its deploy user are the group's members); activation.log, env and secrets are
root's or root:tando-<app>. `destroy` removes every one of these for the app (test 19j lists them).

## Activation state machine

`begin` hands out the upload lease → client rsyncs into `incoming/` → `activate <token>` reserves
`releases/<id>` and starts `tando-<app>-act-<id>` (transient unit), returning at once. The unit
takes the per-app flock (`lock`) and walks `state.phase`:

```
idle → copy → preflight → switch → verify → idle      (verified, last_good = id)
         │        │                     └──→ rollback → idle   (bad; current = fallback)
         └────────┴──→ idle (bad; current untouched)
```

copy: the upload (no links followed) into a root-owned release: a file with the same bytes as in
the live release is a hard link to that file. Which files have the same bytes comes from the live
release's manifest (`sums/<id>`, root's: per file of the upload its sha256, size, and identity in
the release and in `incoming/`, written last in its import): only the upload's new or changed files
are hashed, and a live file is trusted unread while it is the recorded inode with the recorded
mtime and size, root's with mode 640 or 750. A live release without a valid manifest (an older
agent's, a damaged one: it ends with a sha256 of its lines) is compared byte for byte, `rsync -c
--link-dest`, as before; either way the new release gets one. The shared file is root-owned, mode 640 or
750 (so the release's chown and chmod leave it unchanged); a shared file that is not, or that lies
in a `writable`, `public_dirs` or assets directory, is copied (`unshare_release`), so nothing done
to one release shows in another. Never a link to `incoming/` (the uploader writes there). Then
link shared dirs, make `writable` dirs app-owned. preflight: the same sandbox on port+100, health-checked; a Next.js release also has to load
its `sharp` module and answer for the pages' optimised images. switch: pre-deploy
backup, atomic `current` swap, restart. verify: through Caddy. `recover` (boot and every mutating
verb) reverts copy/preflight and finishes or reverts switch/verify/rollback.

A deploy's settings (its tando.conf) wait in `confs/<id>` from `configure` to the switch, where
`conf_put` writes them into app.conf, the unit file and the site; a revert, a rollback or a deploy
that does not go live puts the fallback's back (`start/<id>`, `start_back`). A record lists the
settings its agent knew (`keys=`); `rec_put` unsets one it knows but lacks and keeps the app's
value of one it does not know (a record older than that setting; 0.1.1's has only start and
health). Domains are the app's, not in a release's record: a rollback keeps them. Two things follow the
same rule. New domains of tando.conf: `configure` checks them (`domain_free`, under
`.domains.lock`) and stages them (`domain_add=` in `confs/<id>`); the switch checks them again
under the same lock (another app may have taken one meanwhile: the deploy then fails before the
swap) and adds them to app.conf; the state records them (`domains_new`) and a revert takes them out.
Nothing is reserved meanwhile, so a deploy that never goes live holds no domain. A new app (no
live release) takes them at configure, as before. The site gets a new domain at the switch, so its
certificate is asked for then, not before: a deploy that fails asks for none, and the client's
check after the deploy (`domain-check`, up to 90 s) covers the issuance. The database role's
limits (`db_limits`) are the live release's: `configure` creates the role and database (the
pre-flight and the release command need them) with the live limits; the new ones are set just
before the release command, if there is one (a migration runs under the `db_temp_limit` it was
deployed with), else at the switch (`db_follow` in `conf_put`, only when they differ from the
state's `db_limits`); a failure, a revert, recovery and a rollback set the fallback's again.

With `release = <command>` in tando.conf there is a phase `release` between the pre-deploy backup
and the swap: `switch` (Caddy up, backup) → `release` → `switch` (swap). The command runs in the
transient unit `tando-<app>-rel-<id>` (the job sandbox, `props - job`; `exec-release` reads the
command from app.conf). A failure, a timeout (`RuntimeMaxSec`) or an interruption (`recover` in
phase `release` stops the unit) ends like a failed pre-flight: bad, current untouched. Nothing is
restored. Its seconds are `t_release` in the activation file and a 13th field of the deploy's
history line (docs/COMMANDS.md, "The release command").

### Workers

`worker.<name> = <command>` (docs/CONFIG.md, "Workers") is one unit per worker,
`tando-<app>_worker-<name>.service` (`_` is in no app or worker name and `_worker-` is not `_job-`:
the name is exactly this app's worker; `app_units` enumerates them for destroy). The unit has the
job sandbox (`props - job`: the app's user, env file, slice, no listening socket) with the
worker's own MemoryMax, `WorkingDirectory=<app>/current`, `exec-worker` (the command from
`start/<id>` of the release its cwd is in; it exports `TANDO_RELEASE` and `TANDO_WORKER`),
`Restart=always` with a backoff and no start limit (never "failed", never tando-down@: the web
process is not touched), `TimeoutStopSec` = `worker.<name>.stop_timeout` (30), enabled.

One idempotent step, `workers_follow`, makes the workers those of the release `current` points
at: unit files written (only what differs), removed workers stopped (their stop time), disabled
and deleted, every worker not running that release (`TANDO_RELEASE` of its main process) restarted
in one `systemctl restart` (per unit: the old process stops, then the new one starts: two
generations never run together), none when the app is stopped. It runs:

- in `finish` (deploy, rollback, and recover's re-run of either), after the web process passed its
  check through Caddy and before the soak; the soak (or 3 s when there is none: a rollback, `soak
  = 0`) watches the workers' NRestarts and ActiveState with the web unit's, and a worker that does
  not stay up fails the release (`revert`). A release whose web check fails never touches the
  workers that run;
- in `revert`, after the fallback's web process is back and before the end is committed (its
  workers come back; a failure leaves the phase for recover to retry);
- in `stop_app`, `rec_service` (every idle recover: a reboot, a worker the machine missed),
  `start`/`restart`/`env set` (all restarted), a backup restore (stopped first) and `switch_to ""`.

Every call happens inside an operation's phase, before its `end_op`: a kill or a reboot at any
point is finished by recover running `finish` or `revert` again. Fault points: `wk.write`,
`wk.stop`, `wk.start`, `fin.workers`, `bad.workers` (the fault matrix's kind `worker` checks that
the workers that run are exactly the serving release's: invariant 11).

## Recipes
| Recipe | Release | Process |
|---|---|---|
| node, next | files; next ships .next/standalone + static + public | `start`, as tando-<app> |
| python | files; `.venv` built on the server from requirements.txt in a transient unit (as the app user, MemoryMax=build_memory, CPUQuota=100%), then root-owned | `start` with the venv on PATH |
| container | `IMAGE` naming `localhost/tando-<app>:<id>` in root Podman's storage (loaded from the uploaded image archive, or pulled from `image =`) | `podman run -d --sdnotify=conmon` (quadlet-style unit, conmon is the main process) |
| static | files, root:caddy 750/640 | none: Caddy serves `current` |

Containers run under root Podman with the container's root mapped to the app's own uid, no
capabilities, `--read-only`, slirp4netns publishing on 127.0.0.1 only, in the unit's cgroup.

Site names: `<app>.<apps_domain>` (apps_domain defaults to `<ip-with-dashes>.sslip.io` when the
server has a public address, else `localhost`) plus the app's own domains in the same block, with
`www.` twins redirecting in blocks of their own. Every change is validated against the whole
Caddyfile before the reload and rolled back if Caddy rejects it.
Caddy modes per app: proxy (holding requests up to 15 s while the process restarts), file_server
(static; in both, the fingerprinted files of the kept releases are answered first from the app's
shared assets directory, see "Assets" below,, `503 stopped` (after `tando stop`; the unit is disabled), `503 unavailable` (set by
`app-down` when the unit has failed for good; cleared by the next start, restart or deploy),
`503 being deployed` (while the app has no release yet, from the site's setup until its first
release switches in, and again if it ends with none; a small HTML page with `Retry-After: 10`). The
last one is a Caddy `file` matcher, looked at on each request, on the app's `current` link and on `live`
(an empty file `switch_link` makes before the link and removes with it, so a link left dangling by a
release directory removed by hand does not show the page): it goes away by itself when the release
switches in, with no site rewrite and no reload.

## Assets

A browser that holds a page of release N asks for release N's hashed files
(`/_next/static/<build>/...`, `/assets/index-<hash>.js`) after N+1 went live, and the new release
does not have them: a 404 that breaks the page until reload. The same for a CDN or a slow client.
So the fingerprinted files of every release tando keeps are hard-linked into one directory per app,
`/opt/tando/apps/<app>/assets/`, laid out like their URLs (`assets/demo/_next/static/...`), and
Caddy answers a request under those URL prefixes from it first and hands a miss to the app (or, for a
static site, to its own `file_server`). It is `$D/assets` and not `shared/` because `shared/` is the
app's own (it creates and owns what is in it, root never writes there) and Caddy must read the files.

- **What counts:** the Next.js recipe's `.next/static` (Next itself sends the whole tree as
  immutable); the directory `assets = <dir>[, <url prefix>]` names; for a static site, the first of
  `assets`, `_astro`, `static`, `_next/static` whose files all carry a hash in their names (the last
  `-`, `.` or `_` before the extension followed by 8 to 32 characters of `[A-Za-z0-9_-]` with a
  digit or a capital after the first: `index-DiwrgTda.js`, `main.3f2a1c0b.chunk.js`); one file
  without it and the directory is not taken. Node, Python and the rest only by `assets =`. A
  container's files are inside its image: not supported (`assets` is refused for one).
- **Records** (`$D/assetlog/`, root only): `<id>` lists the files release `<id>` put in the shared
  directory, `<id>.spec` the `<dir><TAB><url prefix>` lines (written last: Caddy serves a prefix
  only when every file of the release is in place), `<id>.cc` the `Cache-Control` the app itself
  sent for one of its files, when it sent one.
- **When:** `assets_link` runs at the start of `switch_to`, before the link moves: for a deploy,
  after the pre-flight passed and the backup and release command ran; for a rollback and a revert,
  for the release going live (a file of the same name with other bytes, which a fingerprint rules
  out but a constant build id does not, is replaced by the newer release's, by a rename). A new file
  is a `cp -l` (a hard link); a name that exists keeps its file. A failure only says so: the
  app answers what is not shared.
- **Compression:** every site block has `encode zstd gzip` (Caddy's own; `compress = off` leaves it
  out). It skips an answer that has a Content-Encoding already, one under 512 bytes, and types that
  are not text (an event stream, images), and a websocket upgrade never reaches it. On the fly a
  200 KB script costs about 2 to 3 ms of CPU a request; so `assets_link` also makes a `<file>.gz`
  (`gzip -9`, only in the shared directory, never in the release) of each new text file (js, css, svg,
  json, html, wasm, map, txt, xml) of 1 KB or more that shrinks, lists it in the release's record
  like any other file (so `assets_gc` removes it with its file), and the assets `file_server` has
  `precompressed gzip`: Caddy sends the .gz as it is (about 0.3 ms). No .zst: a visitor that accepts
  zstd and gzip is sent the .gz.
- **Pruning:** `prune` ends with `assets_gc`: records of releases that are gone are removed, then
  every file of the shared directory that no kept release lists. Releases are kept as before (5, and
  current, last_good and the target), so the files of the last releases stay and nothing grows without
  bound. A failed or cut-off deploy's release is dropped the same way.
- **Crash safety:** the files are linked before the link moves, and the serving release's files are
  never removed while it is kept (its list is in the union). A kill leaves files nobody lists (or a
  `*.tmp` list): the next prune takes them; the kill's own recovery is that of any kill before the
  switch. A hit on a file in the middle of a replace never misses (link beside, then rename).
- **Caddy:** `@tandoassets` (GET, HEAD, the prefixes, and the file exists in `$D/assets`) is a
  `handle` with `Cache-Control: public, max-age=31536000, immutable` and `file_server`; the
  request guards (a Host with a port, a Host that is not the site's) become `handle` blocks before
  it, because `handle` comes before `respond` in Caddy's order and they must answer first. A site
  with no mounts is exactly as before. The header is the app's own when the app sent one for a sample
  file in the pre-flight (`<id>.cc`), so an app that caches its assets another way keeps that.
  Not in the stopped and down pages.
- **Cost:** hard links use no data blocks beyond the first copy; deploy time and measurements
  are in the changelog entry.

## Trust boundaries
- Loopback: Caddy's admin API is on a unix socket in /run/caddy (caddy and root only), never on
  127.0.0.1:2019. nftables (table `inet tando`, tando-firewall.service) lets each app's uid reach
  only its own port and pre-flight port inside tando's range. Residual: other loopback services
  (PostgreSQL, which needs the app's password; anything the admin runs on 127.0.0.1 outside the
  port range) stay reachable from every app. The cloud metadata address (169.254.169.254, and
  fd00:ec2::254) is refused to every app's uid: an app tricked into fetching a URL cannot read the
  instance's keys or tokens.
  **Limit:** the per-uid rules only block what tando knows: other tando apps' ports and Caddy's
  admin. A service tando does not manage that listens on loopback is open to every app, whatever
  port it uses: on the first real server a tando app's shell (`tando ssh <app>`) reached a hand-run
  app on 127.0.0.1:3100. Such a service needs its own authentication or a unix socket; tando does
  not firewall it.
- Root never writes through app-writable paths: shared/ directories are created by the app's user
  and only verified by root (a symlink is refused); restores fill a fresh directory as the app user
  and swap it in by rename; image uploads with symlinks are refused; control characters in names
  are replaced before they reach a file or the client.
- CI deploy key: user `tando-d-<app>` whose shell is tando-gate; it can upload into its app's
  `incoming/`, activate it and read its status; sudo allows exactly the gate's root mode for
  begin/end/activate/receive of that app (docs/CI.md). The gate (Go) parses the request into a
  typed one by a fixed grammar before anything runs, keeps four variables of its environment,
  binds root mode to the key's ssh session through /proc, and reads the upload as root only with
  directory descriptors (O_NOFOLLOW per directory, fstatat on names, never a file's contents).
- Laptop → server: the admin's ssh login with passwordless sudo; root runs only the agent.
- App ↔ app: every unit that runs an app's code (the app, its pre-flight, jobs, venv build,
  backups) gets the same sandbox from one function (`props <port|-> <kind>`): its own user,
  ProtectSystem=strict, private /tmp, /dev and IPC, a 16 MB private /dev/shm counted in its memory;
  only the app and its pre-flight may listen, each on its own port (SocketBindDeny=any for the
  rest). A health answer counts only when the listener on the port is in the app's own unit
  (`own_listener`). Journal namespace directories are 0750 root:<app's group>, so no app writes
  into another's journal. `destroy` stops every unit, kills every process of the uid (failing if
  one survives), deletes its files in /dev/shm, /tmp and /var/tmp, and retires the uid for good
  (`$R/retired-uids`; new ids come from tando's band, 30000-39999: "Many apps on one server"). Failed releases are deleted at once; `incoming/` plus `releases/` share one
  per-app limit (`app_max_mb`, real bytes). Requests whose Host carries a port get 400 (Caddy
  before 2.7 would serve them unlogged). tando's probes carry a root-only secret header, the only
  thing that keeps a request out of the request log; site files are root:caddy 640.
  Residual: container units run under root Podman with their own isolation (no `props`).
- Agent ↔ app: each app is user `tando-<app>` in a sandboxed unit (ProtectSystem=strict,
  writes only to shared/ and its writable release dirs, binds only its port). Releases are
  root-owned and group-readable by the app only; env files are root:tando-<app> 640.
- Root never reads app-controlled paths: inspection runs on the root-owned copy; backups and
  restores run tar/pg_dump/pg_restore as the app user and root only handles the streams; the
  backup's tar in the app's sandbox and slice, pg_dump and pg_restore in a scope of the app's slice
  (its memory limits, 512 MB at most, oom_score_adj 500).
- Commands from tando.conf (start, jobs) are stored in app.conf and executed by fixed agent verbs;
  no command text is written into unit files.
- PostgreSQL: one role per app with CONNECT only on its own database; the password exists only in
  the server's env file and is shown only by `tando db url --show`. One pgbouncer in front of it
  for every app (127.0.0.1:6432, transaction pooling, `db_pool` server connections per app; it
  holds the roles' SCRAM secrets, not passwords, in a root:postgres 0640 file); the loopback
  rules keep apps without a database away from 5432 and 6432. Sizing from RAM, the env's
  `DATABASE_URL`/`DATABASE_URL_DIRECT`, the upgrade path: docs/COMMANDS.md, "Database connections
  and pgbouncer".
- db studio (`tando db studio`, srv/studio): one always-on service per server since the studio-vm
  change (docs/STUDIO.md: a front as root with CAP_SETUID/CAP_SETGID only, holding the codes and
  tokens; a helper per app and page as the app's user, which is the per-app studio described here).
  The points below describe that helper; "Who reaches it" and "Resources" changed as STUDIO.md says
  (a socket per admin login, tokens 12 h, the backend lowered by tando-studio-lower.path).
  - **Who it is.** The app's user (`C[user]`, the uid nftables lets reach 5432) with the app's
    role and password, in a transient unit under tando.slice: no capabilities, no new privileges,
    ProtectSystem=strict, private /tmp, /dev and IPC, SocketBindDeny=any, IP only to localhost,
    96 MB, 32 tasks, 12 h at most; the app's env file is not loaded. The password reaches it as a
    systemd credential (root 600 under /run/tando/studio, removed with the unit), never in an
    argv, the URL, the page, the API or a log. It starts no program (an AST test).
  - **Who reaches it.** Its unix socket (0666) is in `/run/tando-studio/<sid>/`, 0770 owned by the
    admin and the app's group, under a root 0711 directory: the admin's sshd session, the app's
    uid (which has the password anyway) and root. Nothing listens on a network port. On the laptop
    `ssh -L 127.0.0.1:<port>:<socket>` on a connection of its own (not the shared master); any
    local process can connect to that port, so every API call needs a 256-bit bearer token, which
    the page gets once for a single-use code in the URL (a minute to use it); Host must be
    127.0.0.1, localhost or [::1] with that port (DNS rebinding), a foreign Origin or
    Sec-Fetch-Site is refused, POST needs application/json, OPTIONS gets 405 (no CORS). The page:
    CSP `default-src 'self'` with Trusted Types and no inline script; database content only
    through textContent. Residual: a malicious browser extension or a process of the admin's own
    uid on the laptop can read the tab; out of scope.
  - **What it may do.** Read-only, PostgreSQL enforcing it: each request is one `BEGIN READ ONLY`
    whose snapshot is taken by the studio (`SELECT 1`) before any user statement, so `SET
    TRANSACTION READ WRITE` and `set_config('transaction_read_only', ...)` fail; a statement that
    ends the transaction stops the batch (no second BEGIN); ROLLBACK and DISCARD ALL after. Each
    statement is its own Parse (one command only). In front of that, an allowlist of first words
    (SELECT, WITH, VALUES, TABLE, SHOW, EXPLAIN, SET, RESET; not SET TRANSACTION/ROLE/SESSION) stops
    LOCK, VACUUM, ANALYZE, NOTIFY, COMMIT and the rest before they reach the server, and some
    functions a read-only transaction still runs are refused by name: `pg_cancel_backend` and
    `pg_terminate_backend` (the role may signal the app's own sessions), `pg_logical_emit_message`,
    and the ones that run SQL given as text (`query_to_xml` and kin, `ts_stat`, `ts_rewrite`); so is
    any `U&"..."` identifier (its escapes could spell those names). The studio's
    own clock cancels a statement at 30 s and closes the connection 5 s later.
  - **Scope: the app's own tables only.** The table list, structure and rows never list or serve
    a relation of pg_catalog, information_schema, pg_toast or any pg_* schema (the studio's own
    catalog queries filter them; a request for one is the 404 of an unknown table; no request
    field carries SQL into those queries); a view's rows get the editor's plan check (2) first,
    so a view of the app's over a system table is refused there too (403). In the editor, a guard refuses (42501, "the studio only
    reads this app's own tables: pg_catalog.pg_authid is a system table") any statement that
    reaches a system relation, in two halves, both before the statement runs:
    (1) on the text of every statement of the batch, before anything runs (srv/studio/sqlsplit
    scope.go): an identifier, quoted or not, any case, that is a system schema
    (`pg_catalog`, `information_schema`, `pg_toast`, `pg_temp`) or starts with `pg_` (except a
    short list that reads no catalog: `pg_sleep*`, `pg_typeof`, `pg_size_pretty`,
    `pg_size_bytes`, `pg_column_size`, `pg_input_*`, the advisory locks); the reg* lookups
    (`regclass` and its kin as a cast in any form, an array or a function, `to_regclass` ...);
    catalog-reading functions without the prefix (`current_setting`, `has_*_privilege`,
    `obj_description`, `col_description`, `shobj_description`, `format_type`,
    `current_schemas`, `row_security_active`, `acldefault`, `aclexplode`, `txid_*`, `lo_*`,
    `table_to_xml` / `schema_to_xml` / `database_to_xml` and kin, which take a table by name);
    and `SHOW ALL`; `SET standard_conforming_strings` / `backslash_quote` are refused, so the
    server reads a string where this scan does. (2) In the request's read-only transaction, right before each SELECT, WITH,
    VALUES or TABLE (and the statement a user's EXPLAIN [ANALYZE] explains), the server is asked
    for its plan, `EXPLAIN (VERBOSE, FORMAT JSON)` (never ANALYZE; nothing runs), after the
    batch's own SETs: PostgreSQL resolves the names as it will run them (search_path, quoting,
    views expanded to their base relations, CTEs, subplans), so every relation with its schema
    must be outside the system schemas, every function scan and every expression the plan
    prints (a view's included) must pass the name check of (1). Fail closed: no plan, a plan
    over 1 MB, an unknown node type or a relation without a schema refuse the statement.
    EXPLAIN's own error (a syntax error, an unknown table) is the statement's, at its position.
    SHOW one setting, SET and RESET have no plan; their text gets (1). Allowed on purpose, as
    they read no table: `version()`, `current_user`, `current_database()`, `SHOW <setting>`
    (what the role may see of it), a text search configuration by name (`to_tsvector('english',
    ...)`, a lookup PostgreSQL does for the function); `current_setting()` is refused with the
    catalog functions (`SHOW` is the one way to a setting). Another app's tables are
    in another database: a name with a database (`other.public.t`) is PostgreSQL's 0A000, and
    the role cannot connect to any other (below). Cost: one planning round trip per statement,
    about 0.3 ms (bench/RESULTS.md "db studio"). Why not a parser library: the real one
    (libpg_query) needs cgo and several MB, against srv/'s no-dependency static builds; the
    server's own plan resolves names exactly as it will run them, which no tokenizer can.
    It is a guard that keeps the studio to the app's tables, not a sandbox: a function the app
    itself defined that reads a catalog in its body is called by its own name and is not seen
    (as for set_config); a type or domain of the app's over regclass the same; it refuses by
    name, so an app column or table called `pg_x` or `lo_x` is refused too (`tando db psql`
    reads them). One connection; at most 2
    helper processes per app and 4 in all (docs/STUDIO.md). CI deploy keys cannot start it: the client, the gate's grammar, their
    sudo rule and sshd's DisableForwarding refuse, and the agent refuses SUDO_USER tando-d-*.
  - **One app.** The app comes only from the root agent verb's argument; the credential file
    holds that app's role, and the API has no field for a database, role or connection string
    (unknown JSON fields are refused). Every app database is closed to PUBLIC (`db_limits`, run by
    every deploy and host setup, so an older or hand-made grant is undone); no extension that
    reaches another database (dblink, postgres_fdw) is installed, and the role cannot create one.
    Residual: PostgreSQL's shared catalogs show any role the names of databases and roles and that
    other sessions exist (queries and client addresses of other roles stay hidden); the studio's
    scope guard refuses those catalogs, `tando db psql` as the role still reads them.
  - **Resources** (bench/RESULTS.md "db studio"). The bound comes from settings, never from the
    OOM killer: a backend killed by it makes the postmaster restart every session of every app.
    The settings bound sorts and hashes only: one value a query builds (`repeat`, `string_agg`)
    may take up to 1 GB of the backend's memory, and PostgreSQL has no per-session cap (residual:
    on a server with little free memory a deliberate query can still bring the OOM killer).
    The studio's backend starts with `work_mem=2MB`, `hash_mem_multiplier=1`, no parallel workers,
    `temp_buffers=1MB`, `jit=off` (DISCARD ALL after each request puts them back; SET of them and
    `set_config` are refused; a function of the app's that calls set_config is the residual), the
    role's `temp_file_limit` (1 GB, superuser-only) for what spills. The root agent checks the pid the
    studio reports (a postgres process, child of this cluster's postmaster, its title this app's
    role and database, listed by pg_stat_activity with the studio's application_name), then moves
    it into a transient scope at the root of the cgroup tree with CPUWeight=1 and IOWeight=1
    (StartTransientUnit with its PID; no memory limit), at nice 19 and the idle I/O class; the
    studio itself runs at Nice=10. `lock_timeout=2s`; 30 s per editor statement, 10 s for browsing: an app's DDL
    waits for a studio query at most that long. Nothing is held between requests (ROLLBACK, no
    snapshot, `idle_in_transaction_session_timeout=60s` behind it); the connection closes after 60 s
    unused and is opened only when the role keeps 2 connections free for the app.
  - **Residual** (documented in docs/COMMANDS.md): the app's tables the role can read, 30 s of CPU and
    I/O per statement, an ACCESS SHARE lock for that long, advisory locks for the request,
    whatever a function the app defined does inside (set_config, pg_cancel_backend, a catalog
    read). The SQL history is in the browser's
    localStorage, AES-GCM encrypted with a key derived from the role's password (HMAC), so a later
    local page on the same port cannot read it.

### Third review (test/sec3), and what stays open
- Loopback (fw_sync): an app's uid may reach its own port and pre-flight port; it is refused the
  port range, 2019, 5432 (unless it has a database) and every other app.conf port outside the
  range (an adopted app's 3100). Apps that share a user share their ports. Not "deny all but its
  own": that breaks what an app may rightly use on loopback (a redis the admin runs, resolved's
  DNS over TCP, its own public name through Caddy on 80/443) with nothing to opt in. A service
  tando does not know about still needs its own authentication. `adopt apply`/`undo` call fw_sync.
  The app's own packets in a connection opened from outside (not over lo) are dropped (`ct
  direction reply`): listen() on an unbound socket autobinds 0.0.0.0 past SocketBindDeny.
  tando-watch compares the loaded table with firewall.nft every minute and loads it again (alert
  `firewall`, audit `fw-restore`); tando-firewall.service is PartOf nftables.service.
- The probe secret never reaches an app: Caddy drops X-Tando-Probe (`header_up -X-Tando-Probe`)
  and sets X-Real-IP to the peer; direct-to-port checks (pre-flight, adopt) send no secret. Caddy
  before 2.7 serves but does not log a Host in other letters: each tando site answers 400 unless
  Host is exactly one of its names; a request whose client half-closed (logged with status 0) is
  shown as `aborted` in `tando requests`, not dropped.
- HOME is `<app>/home`, root's and read-only to the app (dotfiles there ran in every later release:
  `.npmrc` node-options, `~/.local` .pth, `.gitconfig`); `XDG_CACHE_HOME` and `npm_config_cache` are
  under shared/.cache (a venv build's in its private /tmp: a planted wheel would be installed);
  `NPM_CONFIG_USERCONFIG=/dev/null`, `PYTHONNOUSERSITE=1`, `GIT_CONFIG_GLOBAL=/dev/null`. Adopted
  apps get the same (their HOME was shared/ under tando, their own home before).
- Units that run app code (systemd 247+): ProtectProc=invisible, ProcSubset=pid (not in the app
  shell: ps and free need /proc), ProtectKernelTunables/Modules/Logs, ProtectControlGroups,
  ProtectClock, ProtectHostname, RestrictNamespaces, RestrictRealtime, RestrictSUIDSGID,
  LockPersonality, SystemCallArchitectures=native, RestrictAddressFamilies (IP, unix, netlink),
  SystemCallFilter=@system-service (EPERM). `systemd-analyze security` of an app: 7.7 → 3.3. Not
  MemoryDenyWriteExecute (JITs). Container units (root Podman) take none of these.
- `tando ssh <app> -- cmd`: the command goes on stdin to `shell-put` (root-only file in
  /run/tando/shell, token back) and reaches the unit as a credential; no argv carries it.
- Lock files are root 0600 (`lockfile`), every flock has a timeout with a message; host setup
  repairs older 0644 ones and kills a non-root process holding one.
- Disk (no quotas): tando-watch measures each app (shared/, data_dir, releases, incoming) every 10
  min against `app_max_mb`, alerts, and stops it when its file system is 95% full. Backups are
  written by root (the file system's root reserve still takes them); doctor names the file system,
  its root reserve and the largest app. ext4 project quotas would be real limits, but only on
  ext4/xfs with the feature enabled at mkfs or tune2fs time: documented, not built.
- Backups: unreadable or vanished files are a `warning=` in the backup's meta (tar
  --ignore-failed-read, exit 1 accepted), so an app cannot block deploys; tar errors stay fatal.
- Caddy timeouts (read_header 10s, idle 2m) are set only on a Caddy that host setup installed or
  whose Caddyfile has no site but :80; elsewhere doctor prints the lines. Under the same rule a
  drop-in (`caddy.service.d/tando-memory.conf`) sets `GOMEMLIMIT` to 28% of RAM and
  `OOMScoreAdjust=-500` (the kernel kills apps before Caddy), from Caddy's next start (host setup never
  restarts a running Caddy; one it installed itself is restarted at once); doctor prints it elsewhere. No
  MemoryMax: at the cap the kernel would kill Caddy, every site with it. Measured on the test
  server: 15,000 open keep-alive connections took Caddy to 766 MB, 386 MB with a 200 MiB
  GOMEMLIMIT (still running, no restart).
- Limits: plan on about 10,000 concurrent connections per 2 GB of RAM (20,000 reached 1.8 GB on a
  2 GB server and Caddy was OOM-killed before GOMEMLIMIT). Behind an app's `max_conns_per_host`
  Caddy queues further requests without bound unless the app's site sheds load (fast 503): latency
  grows until clients time out. Caddy asks apps for gzip (Go's default); `transport http {
  compression off }` would be faster for Next.js, but tando sites have no `encode`, so clients
  would then get uncompressed answers: left as is.
- uid and gids of a destroyed app are retired; tando-m-<app> takes its gid from the same
  allocator. Alert state (watch/state, history) is root 600.
- Per app: every unit of an app (service, pre-flight, jobs, shell, venv build, backups) runs in
  `tando-<app>.slice` (name escaped, so hello-2's is not under hello's) under `tando.slice`
  (CPUWeight/IOWeight 50: all apps together yield to Caddy, sshd and the agent). The slice caps
  the app's units together: MemoryMax 3x `memory` (the live app, its pre-flight beside it during a
  deploy, a job or shell) plus each worker's memory, TasksMax `tasks` (1024), CPUQuota `cpu`; each unit keeps its own
  MemoryMax `memory`. App units have OOMScoreAdjust=500 (killed before Caddy, sshd, the agent);
  Caddy -500 where tando owns it. Destroy and adopt undo remove the slice. Metrics samples are root's
  (/var/lib/tando/metrics 700; `tando top` reads them through sudo). Restores unpack the data with
  tar as the app's user outside its sandbox: with ptrace_scope=0 the app could attach (Ubuntu's
  default is 1; doctor warns on 0).

## Go server programs

The server programs are moving from bash to Go one at a time (`srv/`, module `tando/srv`,
standard library only); `tando-metrics`, `tando-watch`, `tando-gate` and `tando-logs` are ported,
`tando-agent` and `tando-adopt` stay shell, except that the agent's read-only, frequently called
verbs (`status`, `deploy-status`, `releases`, `history`, `busy`, `info`) are answered by
`tando-status`: the agent checks their arguments and privilege rule in its first lines and execs
`/opt/tando/bin/tando-status <verb> ...` (which, for `status` as root, asks tandod first: it
answers from the same code with nothing started), so the client and tando-gate keep calling
`tando-agent <verb>`; when the binary is missing (a server set up by an older client) the agent's
shell versions answer, and they go when the agent is ported. A Go program keeps its shell original's
contract byte for byte (verbs, arguments, stdin, rows and `key=value` lines, exit codes, files,
paths, modes), so the agent and the client do not know which one runs; the original moves to
`server/legacy/` (not shipped, not installed). Each is one static binary per CPU (linux/amd64,
linux/arm64), built reproducibly by `scripts/build-server.sh` into `dist/server/linux-<cpu>/` and
shipped in a release as `server/linux-<cpu>/<name>`. `install_helpers` picks the binary for the
server's `uname -m`, sends only helpers whose SHA-256 differs from the installed one, and checks a
binary by running `<binary> version` where it checks a script with `bash -n`. The files are
staged as `.<name>.new` and switched in as one set: a journal `.install.pending`, a hard link
`.<name>.old` per replaced file, one rename each, then the journal goes; a cut-off switch is
finished or undone by the next install (the directory stays a real directory: a symlink flip was
rejected, see `install_helpers`), and `tando doctor` fails while a journal exists. The recovery (`server/tando-install-recover`, also
the code inside the install script) runs at boot and before a mutating agent verb; `.versions`
tells the agent whether `tando-status` belongs to it. Inside `srv/`:
`cmd/*` (parse the verb, build the Env and the writer, read the environment, map the error to
an exit status) -> `daemon` (tandod's composition, the only package that imports several domain
packages; `daemon/proto` also holds the CLIs' policy for asking tandod first) -> domain packages
-> `internal/*` (no domain package imports another, internal never imports a domain package;
shared code such as systemd's bus client `internal/sdbus` lives there; srvlint enforces it with
no exceptions); every external program starts through `internal/run` (argv, timeout, explicit
environment, never a shell; the only `os/exec` user, enforced by srv/tools/srvlint, and lint
RL15/RL16 as a first line). Output goes through one `out.Writer` per process whose rows and
`key=value` lines clean every field like `san_v`; the only bytes that pass it uncleaned are named
(`Relay`: rows another out.Writer cleaned, such as tandod's answer; `Stream`: tando-logs' journal
lines, neutralised by the shell's awk rules, and its configuration snippets), and every binary
has a test that feeds control, C1 and bidi bytes through each path. srv/README.md has the package
map and the conventions; test/go.sh checks them.

## Host care

`tando-host` (srv/hostcare) looks after the machine, under the same rule as the rest: tando does
not silently change what it does not manage. It reads facts (files first; `sshd -T`,
`systemctl`, one bounded `journalctl`; `apt-get -s`, `dpkg --audit`, `apt-config dump`,
`needrestart -b -r l` at most every 6 hours) and writes `/var/lib/tando/hostcare/summary` hourly
(`tando-host.timer`); tando-status adds its counts to `status` (a file read), tando-watch is to
read its alert rows as host checks. It changes the server only by the owner's command or opt-in
(`tando host care on`): its own apt.conf.d file and apt-daily-upgrade drop-in (Ubuntu's
unattended-upgrades, security origins, `NEEDRESTART_SUSPEND=1`), its units, `apt-get` runs, and a
reboot decided by one pure function (`DecideReboot`: window, deploys, backups, boot age,
confirmation, other sites). A reboot can only start from root: the owner's `tando host reboot`
through sudo, or `tando-host-window.timer` reading root's `/opt/tando/hostcare.conf`; no socket
verb, nothing an app writes is read. Beside sites tando does not manage (`caddy_ours` false) host
setup turns nothing on and reboots need `--even-with-other-sites`. docs/HOSTCARE.md.

## Known debt
The shell server programs (tando-agent, -watch, -logs, -gate, -adopt) each carry their own
copies of the same helpers: `die`, `valid_app`, `load`/`save`, `row`, `san_v`, number parsing,
locking. A fix in one (such as keeping a trailing `=` in values) must be repeated in the others.
The Go port replaces these copies with shared packages (`srv/internal/`) for the programs it
covers; the agent keeps its own.

## Many apps on one server

Tuned for 100 apps on a 4 vCPU / 8 GB server (docs/CONFIG.md and `tando host setup` have the
settings; all are in `host.conf`). What keeps the work per app O(1), and the shared parts shared:

- **Ports.** Apps take ports from `port_min`-`port_max` (default 4100-4999) and their pre-flight
  port from a separate range, `preflight_min`-`preflight_max` (14100-14999), stored as
  `preflight_port`. Apps made before keep port + 100 as theirs; `port_pick` skips every app's
  port and pre-flight port, 2019, 5432 and what listens (one `ss` per scan). The loopback rules
  close both ranges to every app but its owner.
- **Users.** New app users and groups get ids from `uid_min`-`uid_max` (30000-39999, nologin):
  passwd and group are read once, the id picked is checked against NSS by number. A destroyed
  app's id is retired and used again only when the band has no other.
- **Caddy's lock.** A site change takes `.caddy.lock` exclusively; an app's restart takes it
  shared for its hold window (until the app listens), so restarts of different apps run at once
  and only reloads wait for them.
- **systemd and Caddy reloads.** `write_if_changed` says when it wrote; a daemon-reload follows
  only then. Host setup writes every app's units and sites first (sites staged as
  `<app>.caddy.new`), then reloads systemd once and validates and reloads Caddy once; when Caddy
  refuses, every site file goes back.
- **Memory.** Configure refuses a deploy that raises an app's caps (memory plus workers') when all
  apps' caps would pass RAM x `mem_overcommit` (1.5), unless `--force`. `priority = high|low` sets
  OOMScoreAdjust 100/900 (default 500); high also sets MemoryLow on the app's slice, and their sum
  on tando.slice (a child is protected only as far as its parent).
- **Jobs.** A job's journal is read from its app's namespace only (`--namespace=+tando-<app>`).
  Timers spread starts over a sixth of the period (at most 10 minutes) at a fixed offset. A run
  takes one of `job_slots` host-wide slots in job-begin (`$R/jobslots/<i>`, made with mkdir) and
  gives it back in job-end; a slot whose run has ended without its job-end is taken over.
- **Backups.** One `tando-backups.timer` at the start of `backup_window` runs `backup-all`: every
  `backup = daily` app's `tando-<app>-backup.service`, `backup_jobs` at a time, in an order by a
  hash of the name, none started after the window's end; an app backed up in the last 20 hours is
  skipped. Host setup removes the per-app timers of before.
- **Logs.** `log_budget` (default 20% of the log file system) is split across the apps: an app's
  default journal cap is min(256M, 5% of the disk, 4/5 of the budget / apps), its request log a
  quarter of that. A cap is applied at the app's next deploy or host setup.

