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
| `lib/offsite.sh`, `lib/cmd-restore.sh` | `tando backup offsite ...` and `tando restore [--from-host]`, their client side |
| `srv/` (Go): `cmd/tando-host`, `hostcare/` | host care: the server itself (updates, security, health), its summary for the alerts, care mode (unattended-upgrades, the safe reboot); `lib/hostcare.sh` is its client (docs/HOSTCARE.md) |
| `scripts/build-server.sh` | builds the Go server programs into `dist/server/linux-{amd64,arm64}/` |
| `test/e2e*.sh`, `test/all.sh` | end-to-end suites, each on its own test server (docs/TESTING.md) |

`tando host setup` takes a fresh Ubuntu 24.04+ (sshd and a sudo login) to a ready server, in
steps the client shows as they finish: the server programs in `/opt/tando/bin` (root 755: `tando-agent`, `tando-logs`, `tando-metrics`, `tando-watch`, `tandod`, `tando-status`, `tando-offsite`, `tando-host`, `tando-gate`, `tando-install-recover`)
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
| `host_use <name>` | select a registered host: sets `HOST`, `TARGET`, `SSHO` (ssh options incl. ControlMaster) |
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
<id>`, `jobs`, `logs`, `doctor <client cksums> <client version>`. Root: `setup` (prints `step=<name> run|ok <detail>`
lines as it goes), `runtime <node [major]|python|podman|postgres>`, `configure` (stdin settings;
`check=1` only validates and prints `exists`, `current`, `needs` (missing runtimes), `domains`;
`origin=` refuses a deploy from another directory unless `force=1`; an unchanged app.conf with
the same agent skips the rest), `domain-add <app> <domain> <www>`, `domain-rm`, `domain-ls`,
`domain-check` (waits for a valid certificate, or prints Caddy's error),
`begin`/`end` (upload lease; `end` reads the token on stdin), `activate <app> <build s> <upload s>`
(token on stdin; the older form with the token as second argument still works), `rollback [id]`,
`recover`, `env-set/-unset/-ls` (stdin), `start/stop/restart`, `unlock`, `destroy [purge|plan]`,
`backup-run <kind>`, `backup-ls`, `backup-cat`, `backup-restore`, `db-url`, `db-psql`,
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
app user), `backup-run daily`. `info` prints `version` (from /opt/tando/VERSION), `arch`, `libc`,
`apps_domain`, `tls`, `sum` (agent checksum), `podman`, `python`. Output: `key=value` lines, or tab-separated rows whose first field names the row type (`host`,
`app`, `rel`, `hist`, `env`, `job`, `backup`, `check`); empty fields are `-`. New fields are only
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
/etc/systemd/system/tando-<app>.service, tando-<app>_job-*.{service,timer}, tando-<app>-backup.*
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

copy: `cp -a` (no links followed) into a root-owned release, link shared dirs, make `writable`
dirs app-owned. preflight: the same sandbox on port+100, health-checked; a Next.js release also has to load
its `sharp` module and answer for the pages' optimised images. switch: pre-deploy
backup, atomic `current` swap, restart. verify: through Caddy. `recover` (boot and every mutating
verb) reverts copy/preflight and finishes or reverts switch/verify/rollback.

With `release = <command>` in tando.conf there is a phase `release` between the pre-deploy backup
and the swap: `switch` (Caddy up, backup) → `release` → `switch` (swap). The command runs in the
transient unit `tando-<app>-rel-<id>` (the job sandbox, `props - job`; `exec-release` reads the
command from app.conf). A failure, a timeout (`RuntimeMaxSec`) or an interruption (`recover` in
phase `release` stops the unit) ends like a failed pre-flight: bad, current untouched. Nothing is
restored. Its seconds are `t_release` in the activation file and a 13th field of the deploy's
history line (docs/COMMANDS.md, "The release command").

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
(static), `503 stopped` (after `tando stop`; the unit is disabled), `503 unavailable` (set by
`app-down` when the unit has failed for good; cleared by the next start, restart or deploy).

## Trust boundaries
- Loopback: Caddy's admin API is on a unix socket in /run/caddy (caddy and root only), never on
  127.0.0.1:2019. nftables (table `inet tando`, tando-firewall.service) lets each app's uid reach
  only its own port and pre-flight port inside tando's range. Residual: other loopback services
  (PostgreSQL, which needs the app's password; anything the admin runs on 127.0.0.1 outside the
  port range) stay reachable from every app, and per-app metrics and alert state are world-readable.
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
  (`$R/retired-uids`). Failed releases are deleted at once; `incoming/` plus `releases/` share one
  per-app limit (`app_max_mb`, real bytes). Requests whose Host carries a port get 400 (Caddy
  before 2.7 would serve them unlogged). tando's probes carry a root-only secret header, the only
  thing that keeps a request out of the request log; site files are root:caddy 640.
  Residual: container units run under root Podman with their own isolation (no `props`).
- Agent ↔ app: each app is user `tando-<app>` in a sandboxed unit (ProtectSystem=strict,
  writes only to shared/ and its writable release dirs, binds only its port). Releases are
  root-owned and group-readable by the app only; env files are root:tando-<app> 640.
- Root never reads app-controlled paths: inspection runs on the root-owned copy; backups and
  restores run tar/pg_dump/pg_restore as the app user (runuser) and root only handles the streams.
- Commands from tando.conf (start, jobs) are stored in app.conf and executed by fixed agent verbs;
  no command text is written into unit files.
- PostgreSQL: one role per app with CONNECT only on its own database; the password exists only in
  the server's env file and is shown only by `tando db url --show`.

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
  deploy, a job or shell), TasksMax `tasks` (1024), CPUQuota `cpu`; each unit keeps its own
  MemoryMax `memory`. App units have OOMScoreAdjust=500 (killed before Caddy, sshd, the agent);
  Caddy -500 where tando owns it. Destroy and adopt undo remove the slice. Open: Metrics samples stay world-readable
  (`tando top` reads them as the admin's own user; memory and CPU numbers only). Backups and
  restores run pg_dump/tar as the app's user outside its sandbox: with ptrace_scope=0 the app
  could attach (Ubuntu's default is 1; doctor warns on 0).

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
