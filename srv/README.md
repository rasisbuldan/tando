# srv: the Go server programs

The root-side programs in `/opt/tando/bin` are moving from bash to Go, one at a time. Each Go
program is a drop-in replacement: same verbs, arguments, stdin, stdout (tab-separated rows and
`key=value` lines), exit codes, files, paths and modes. `tando-agent` (shell) and the laptop CLI
call them and parse their output unchanged.

| Program | State |
|---|---|
| `tando-metrics` | Go (`cmd/tando-metrics`, `metrics/`); the shell original is `server/legacy/tando-metrics` (not shipped, not installed; kept to compare against) |
| `tando-watch` | Go (`cmd/tando-watch`, `watch/`); the shell original is `server/legacy/tando-watch` |
| `tando-gate` | Go (`cmd/tando-gate`, `gate/`); the shell original is `server/legacy/tando-gate` |
| `tando-logs` | Go (`cmd/tando-logs`, `logs/`); the shell original is `server/legacy/tando-logs` |
| `tando-status` | Go (`cmd/tando-status`, `status/`): the agent's read-only verbs `status`, `deploy-status`, `releases`, `history`, `busy`, `info`; tando-agent execs it for them (its shell versions stay as the fallback) |
| `tando-offsite` | Go (`cmd/tando-offsite`, `offsite/`), new (no shell original): offsite copies of the backups in S3-compatible storage, encrypted (docs/BACKUP.md) |
| `tandod` | Go (`cmd/tandod`, `daemon/`): the long-running monitor; runs the per-minute work of tando-watch, tando-metrics and the log scan in one process and answers on a unix socket |
| `tando-host` | Go (`cmd/tando-host`, `hostcare/`): host care, the server itself (docs/HOSTCARE.md); no shell original |
| `tando-studio` | Go (`cmd/tando-studio`, `studio/`), new: `tando db studio`, the read-only web UI and SQL editor (docs/COMMANDS.md); started only by `tando-agent db-studio` |
| `tando-agent`, `tando-adopt` | shell, staying shell (but for the verbs above) |

Module `tando/srv`, standard library only (no third-party modules, ever), Go as in `go.mod`.

## Package map

```
cmd/tando-metrics/      main: parses the verb, wires Env and packages, prints the error, exits
metrics/                domain: sample, read (per-minute samples for tando top and tando status)
cmd/tando-watch/        main: dispatches the verbs of tando-watch (asks tandod first: proto.AskWatch)
watch/                  domain: the alert checks, their state and the notifiers (structure below)
cmd/tandod/             main: the daemon (reads systemd's NOTIFY_SOCKET, WATCHDOG_*); `version`
daemon/                 composition: tandod's schedule, socket and wiring of watch, metrics, logs, status
  proto/      the socket's line protocol, its client and the CLIs' policy for asking it (client.go:
              which verbs, the timeouts); no domain imports: tando-watch and tando-status link it
cmd/tando-gate/         main: scrubs the environment, dispatches the four entry points and version
gate/                   domain: the CI deploy keys' confinement, docs/CI.md (structure below)
cmd/tando-logs/         main: dispatches the verbs of tando-logs and version
logs/                   domain: journals, request log, error scan, audit, log settings (structure below)
  journal/ reqlog/ errscan/ lines/   its parsers: no files, no commands, table, golden and fuzz tests
cmd/tando-status/       main: dispatches the agent's read-only verbs and version; errors as "tando-agent: ..."
status/                 domain: status, deploy-status, releases, history, busy, info (structure below)
cmd/tando-host/         main: dispatches host care's verbs (status, check, care-*, update-*, reboot*, ...)
hostcare/               domain: facts, findings, the summary file, care mode, the reboot rule (below)
cmd/tando-offsite/      main: dispatches the verbs of tando-offsite and version
offsite/                domain: S3 client, encryption, push/fetch/sync/retention, disaster recovery (below)
cmd/tando-studio/       main: serve (flags, the credential file, the socket, signals) and version
studio/                 domain: tando db studio: the HTTP API on a unix socket, the read-only rules (below)
  pgwire/     its PostgreSQL client: protocol 3.0, SCRAM-SHA-256, simple and extended query, cancel
  sqlsplit/   the editor's statements (quotes, dollar quotes, nested comments), the read-only allowlist
  ui/         the page: index.html, s.css, s.js (embedded; no framework, no outside request)
internal/               platform: everything at least two programs need; never imports a domain package
  run/        start a program: argv, timeout, explicit env; never a shell. The only os/exec user
              (Cmd.User: as another user, privileges dropped: psql as postgres)
  env/        Env: paths (/opt/tando, /var/lib/tando, /sys/fs/cgroup, /proc), clock, euid, Runner
  out/        Writer: Row (empty -> "-"), Fields (empty kept), KV, Relay, Stream; Clean (controls -> "?"),
              Cleaner (the rule as values: watch's and gate's shell rules are other values of it)
    outtest/  for tests: Hostile text and Check (nothing of it in a binary)
  valid/      App, ID (release id), Uint (decimal, range-checked; "08" is 8)
  decimal/    Parse (1..n ASCII digits, "08" is 8), IsDigits, Itoa: the one digit parser
  bashread/   bash's read: Lines (complete lines), LinesAll, Fields (IFS=$'\t' read), KV (options), First
  kvfile/     key=value files: Parse, Load (missing = empty), Format (sorted), Save (atomic)
  atomicfile/ Write (temp file in the same dir, fsync, chmod/chown, rename), WriteIfChanged
  lock/       Acquire: flock with a timeout on a root-owned 0600 regular file (same files as the shell)
  fsinfo/     DirFollow/DirNoFollow, RegularFollow/RegularNoFollow, Exists*; Statfs (df's numbers)
  cksum/      POSIX cksum (Sum, File)
  apps/       Names (apps with an app.conf), Dir, Conf, State
  systemd/    Show: one `systemctl show -p ...` for many units, one map per unit
  sdbus/      systemd's private D-Bus socket: ListUnitsByPatterns and pipelined property Gets
              (status asks with it; tandod answers every `systemctl show` of watch and metrics with it)
  cgroup/     AppDir (tando.slice/tando-<app>.slice, escaped; else system.slice), Value (flat-keyed files)
  buildinfo/  Version (set from VERSION by scripts/build-server.sh)
```

Who uses what (`go list -deps ./cmd/<name>` is the truth): `env`, `out`, `valid`, `decimal`
every domain package, `run` every one but metrics (which starts programs only through `systemd`) and studio (none at all); `bashread` gate, status, watch, kvfile (the shell's `read` and
`kv`; status's `load`); `kvfile` logs, watch, apps (`load`/`save`); `atomicfile` metrics, watch,
gate, logs, status (`save`, `atomic`, `put`); `lock` watch, gate, logs (`lockfile` + `flock -w`);
`fsinfo` gate, logs, status, watch (`[[ -d ]]`, `[[ -f ]]`, df); `cksum` status, watch;
`systemd` metrics, watch, status; `sdbus` status, daemon; `cgroup` metrics, watch, status (`app_cg`,
`memstat`, `evcount`); `apps` metrics, watch, logs.

**Duplicates that differ on purpose** (each a thin local wrapper over the shared code, with a
comment saying why): watch's `clean` (a control becomes a space, invalid UTF-8 becomes U+FFFD,
cut at 300 characters: the state, history and notifications) and gate's `clean` (`?`, bidi and
lone C1 bytes kept, cut at 160 bytes: the shell gate's messages) are `out.Cleaner` values;
gate's `kvOf` is `bashread.First` (the first line with the key wins, the shell gate's `kv`),
status's `parseKV` is `bashread.KV` with `DropNUL` (bash's read) keeping the order of first
assignment, kvfile's `Parse` the same with `Partial` and `SkipComments`; watch's `num` takes a
leading `-`; gate's `uintOf` caps at 2^31-1. Parsers with their own golden contract stay in
their packages: `journal.Display`, `reqlog.AppendClean`, `errscan`'s `cleanLine` (the shell's
awk), `metrics`' five-field `fields` (an array: `read` runs over 2000 lines per status call).

## watch: how the package is laid out

`run` is one tick: `tick.go` takes the lock, reads the facts once (one `systemctl show` for every
unit, /proc, statfs, cgroups), runs the checks, decides, commits, unlocks and delivers. Checks are
`hostCheck`/`appCheck` values (`check.go` lists them in the order they run, because earlier ones
hold later ones: Caddy down holds the health probes, a deploying, stopped or dead app holds
memory, restarts and health); one file per check or family (`check_*.go`; `check_jobs.go`: the
job units are asked in that same one call; `check_postgres.go`: one `psql` a run as the postgres
user, `run.Cmd.User`, only when an app has a database). Each check calls
`tick.sample(key, app, check, ok|bad|hold, detail, need)`, the state machine of `machine.go`
(ok -> pending -> firing -> ok, flapping); `reconcile.go` decides what to send (silences,
flapping, reminders); `commit.go` records it so that a killed run neither loses nor repeats a
message (effects to `$V/commit`, then the state with `_out=<id>` as the commit point, then the
queue files, history and incidents); `queue.go` and `deliver.go` send each notifier's queue once
per run with backoff; `notify*.go` has the `Notifier` interface and one type per notifier (webhook,
slack, telegram, ntfy, email). `probe.go` is all HTTP and TLS (net/http with curl's limits:
connect 5 s, no redirects, no proxy; the probe secret header from /opt/tando/probe.header);
`Prober`, `CertReader` and `Sender` are interfaces that tests replace. The other verbs are
`verbs_*.go`. The log scan is a `LogScanner` (the rows of `tando-logs watch-scan`: the one-shot
starts the program, tandod plugs in srv/logs); `pretick.go` runs the metrics sample and, only
when needed, `tando-agent recover-all` before the checks; `cache.go` is what tandod keeps between
ticks. `audit-write` is still a program; nothing imports another domain package.

Tests: `harness_test.go` is a fake host (temp dirs, a clock moved a minute per tick, a
`run.Func` answering systemctl/journalctl/tando-logs/du, fake probes and receivers);
`scenario_test.go` drives it (fire after N, recover after M, flapping, silences, backoff and the
queue, the liveness cap, the disk guard, http/slow/errors/logs thresholds, new errors after a
release, crash recovery of a commit, notifier payloads); `jobs_pg_test.go` the scheduled jobs
(once per failed run, resolve, removed, never ran) and PostgreSQL (thresholds, windows, no
answer, the database in the disk check); `verbs_test.go` the other verbs;
`output_test.go` hostile bytes in the state, history and settings through the read verbs.

## gate: how the package is laid out

The most exposed program: the login shell of every deploy user, and root through their sudo rule.
It imports only small internal packages: `run`, `env`, `valid`, `lock`, `atomicfile`, `out`,
`bashread`, `decimal`, `fsinfo` (not `kvfile`: the shell gate's `kv` takes the *first* line with
a key and skips an unterminated last line: `conf.go`'s `kvOf` is `bashread.First`). Check
`go list -deps ./cmd/tando-gate` after a change: it must not grow beyond leaf packages.
One concern per file: `request.go` turns SSH_ORIGINAL_COMMAND into a typed
`Request` (at most 300 bytes of `[A-Za-z0-9_.:=/@,+ -]`, at most 12 words, a fixed grammar per
verb, the app compared with the caller's; `ParseRequest` stays one function so the whole grammar
reads in one place) and `rsync.go` checks the rsync server options (its
comment lists every receiver restriction and where it is enforced); `params.go` reads root mode's
stdin parameters; `identity.go` reads /etc/passwd and /etc/group (local files only; `CallerApp`:
uid -> app); `session.go` binds root mode to the key's ssh session through /proc; `keys.go` has
ed25519 keys and fingerprints (no ssh-keygen), the key list and authorized_keys; `conf.go` the
limits, the lease and the frozen token; `tree.go` the upload scan and symlink resolution on what a
walk recorded (pure), `fs_linux.go` the walk itself (each directory opened relative to its parent
with O_NOFOLLOW|O_DIRECTORY, entries looked at with fstatat(AT_SYMLINK_NOFOLLOW), changes made
with unlinkat/fchownat/fchmodat on the checked name; never follows a link, never leaves the file
system; `fs_other.go` lets the package build elsewhere for its tests); `procs.go` ends sessions and
evicts users (/proc, cgroup.kill); `receive.go` the confined receiver, its watchdog and rx mode;
`sshd.go`, `sudoers.go` (visudo-checked), `users.go`; `keymode.go`, `rootmode.go`, `admin.go`
the verbs; `startup.go` what is taken from the environment and why.

`main` sets umask 022, cwd `/`, GOMAXPROCS 1 and traceback `none`, keeps `SSH_ORIGINAL_COMMAND`,
`SUDO_UID`, `SUDO_USER` and `INVOCATION_ID` and clears the rest; as root it refuses to start when a
Go runtime variable (`GODEBUG`, `GOTRACEBACK`, `GOGC`, `GOMEMLIMIT`, `GOMAXPROCS`) is set, since
the runtime reads those before `main`. A panic prints `tando-gate: internal error`, nothing more.

Tests: table-driven accept/reject lists for the grammar (`request_test.go`, from e2e-ci.sh and the
security reviews), a fake /proc for the session binding and a fake runner that records every argv
(`session_test.go`), the scan and resolver (`tree_test.go`), keys, params, passwd, the sshd and
sudoers text (`keys_test.go`, `misc_test.go`), the agent's rows cleaned on the way through
(`output_test.go`). Fuzz targets: `FuzzParseRequest`, `FuzzKeyMode` (any
request runs only the fixed argv shapes), `FuzzReadParams`, `FuzzParsePublicKey`, `FuzzKeyList`
(authorized_keys gets only well-formed lines), `FuzzParsePasswd`, `FuzzResolve`; their seed
corpus is in the code and `testdata/fuzz/`. `root_test.go` drives root, admin and rx mode on a
fake host (temp root, fake /proc session, a runner that records every argv, compared whole);
`source_test.go` checks on the AST that nothing in the gate can exec. `fs_linux_test.go` (Linux
only: the symlink-swap race, a 000 directory in an upload) runs in a container from test/go.sh
(g7, docs/TESTING.md). Coverage about 87%.

## logs: how the package is laid out

Two layers. The sub-packages are pure parsers over bytes (no files, no commands, no Env): `lines`
(a line reader that cuts a line to a bound but reports its full length, awk's string-to-number
rule, `Stack` for `tac`, spilling to an unlinked temp file beyond 8 MiB); `journal`
(`journalctl -o json` entries with `encoding/json/jsontext`, one reused decoder, values kept raw;
`Display` neutralises a message, `TextLevel` the level words, `Filter.Line` one output line);
`reqlog` (Caddy's JSON lines: `caddy.go` matches Caddy's key order as literals and checks the
values as JSON, `fast.go` scans any compact object, both without allocation, and anything else
goes to jsontext; `FuzzFast` holds them to the decoder's result, `FuzzDecimal` the number
conversion to strconv's. `AppendClean`, `AppendPath`, the log-scale `Hist`, `Summary`,
`RowFilter`, `Chunk`; `QuickTS`/`QuickStatus` read ts and status of a line of Caddy's shape for a
filter, `FuzzQuick`; `index.go` the request index's record format, its path dictionary in chunks
with an id table, and `Summary.AddRecord`, which folds a record with exactly `Add`'s arithmetic);
`errscan` (the stack-trace state machine over short-unix lines, the fingerprint and group id, the
`groups.tsv` table and its merge, the errors view). `logs` itself holds the verbs, one file per
concern: `settings.go`, `setup.go`, `query.go` (`Query`: `readQuery`, `planQuery`,
`printQuery`, `follow`; + `history.go`), `stats.go`, `requests.go` (the files of a window,
`req-summary`), `reqrows.go` (`req-tail`, `req-errors`), `reqfollow.go` (`req-tail follow`),
`reqindex.go` (the request index: `Roll`, rotation and gzip matching, crash-safe appends),
`reqindex_read.go` (its readers), `reqfiles.go` (the log's files as the index sees them),
`scan.go`, `audit.go`, `doctor.go`; `fs.go` is install -d, du, df (`fsinfo.Statfs`) and the chown
of the shell, `rlimit.go` the CPU limit main sets for a query,
`stream.go` reads a command's output line by line and closes its pipe when enough was read (the
`| awk '... exit'` of the shell). Every external program (journalctl, systemctl, caddy, logger) goes
through `run`; users and groups through `Users` (os/user, a fake in tests).

The fingerprint rules decide group ids that are stored on servers and shown to users, and every
output format is parsed by the agent, tando-watch or the client, so the parsers are tested against
the shell version itself: `testdata/golden/gen.py` makes hostile input (escapes, control bytes,
invalid UTF-8, long lines and traces, other apps' units) and `run.sh` runs the shell's own awk
programs on it under mawk 1.3.4 in the test server image (`out-*`); the golden tests require the
same bytes (group ids, samples, groups.tsv, journal lines in text and JSON, summaries, rows; only
awk's hash order is compared as a set). To regenerate: `python3 gen.py in`, then
`run.sh in gold <server/legacy/tando-logs>` in a `tando-testvm` container, gzip each file (outputs
as `out-<name>.gz`). Tests of `logs` run the verbs on a fake host (`host_test.go`: temp dirs, a
fixed clock, a `run.Func` answering journalctl/systemctl/caddy/logger, a fake /proc). Fuzz targets:
`FuzzReader`, `FuzzEntry`, `FuzzRequest`, `FuzzQuick`, `FuzzFast`, `FuzzDecimal`, `FuzzScanner`,
`FuzzWord`. `TestIndexMatchesScan` compares every summary window and `req-errors` read through
the index with a full scan across appends, rotation, gzip, truncation, deleted and damaged files.
Benchmarks (`go test -bench . ./logs/...`): `BenchmarkParseFast` (about 175 ns a line on an M1,
0 allocations), `BenchmarkParseDecoder`, `BenchmarkSummaryAdd`, `BenchmarkSkips`,
`BenchmarkIndexSummary`; `TestNoAllocations` fails on an allocation per line.

For a long-running caller (a daemon that calls these in-process): every verb is a method of
`Logs` with its state passed in and a `context.Context`; `Logs.Roll(ctx, app)` is the index's
incremental step; nothing below `main` exits or keeps package state; `Logs.Trim` and the GC
settings (`main`: `SetGCPercent(20)`, `FreeOSMemory` after a roll that read something) are the
process's choice, not the package's. Such a caller sets `Logs.Cache = logs.NewScanCache()` once
(`scancache.go`): what the scans learn between calls (per app the signatures of its journal file
and request log, so an idle app costs three `fstatat` calls on precomputed paths and nothing
else; the index in memory; reused buffers), bounded (small dictionaries only, 512 KB of them in
all; apps and log files that are gone are forgotten). The environment (`SUDO_USER`, the parent
pid for audit-origin) is set by `main`, not read by the package. Files in Caddy's directory are
opened with `openRegular`/`openDir` (no symlink, no blocking open, a regular file or directory
by fstat), so a FIFO swapped in cannot hang a tick. Tests: `TestIdleScan` (no command, no
allocation on Linux), `TestScanCacheMatches` (with and without a cache, the same rows across
appends, rolls, gzip, truncation), `TestScanNeverLogged`, `TestCacheBoundedUnderSpray`,
`TestCachePrunes`, `TestFIFODoesNotBlock`, `TestOutputClean`/`TestRowsClean` (hostile bytes
through the journal stream and the rows); benchmarks `BenchmarkIdleScan100`,
`BenchmarkTraffic20`.

## status: how the package is laid out

The agent's read-only verbs, which the client calls on every refresh (`tando ls`, `tando status`,
`tando top`, `--watch`) and every half second of a deploy (`deploy-status`). tando-agent checks
the arguments and the privilege rule, then execs `tando-status <verb> ...` from its first lines
(before bash parses the other 3,500), so the output is this package's; without the binary it falls
through to its shell versions. The output is the shell's byte for byte (test/e2e-status.sh runs
both on one server state and compares them), so each function quotes the shell it replaces.

`Collector` has every input explicit (Env, the /sys and Caddy certificate paths, the sudo user, a
stderr, statfs and netlink as replaceable functions, the systemd socket) and keeps nothing but an
optional open connection to systemd (guarded: calls may run at once), so a long-running caller
can serve from it (tandod does); formatting is
pure (`HostRow`, `AppRow`, `ReleaseRows`). One file per verb (`verb_*.go`); `kv.go` is the
agent's `load` (complete lines only, the first `=` splits, NUL bytes dropped, the order of first
assignment) and `bashOrder` (deploy-status prints the activation file in bash 5's associative
array order: FNV-1 over 1024 buckets, the later key first in a bucket); `host.go` reads /proc,
/sys and statfs (df -Pk's rounding); `units.go` asks systemd; `cert.go` reads a certificate's
notAfter with encoding/asn1 (not openssl and date, three processes per domain); `client.go` is
how tando-status runs `status` (`StatusVia`: tandod first) and the agent's environment
(`AgentEnv`); `sys_linux.go` uname, statfs, the route source (a connected UDP socket) and the
global addresses (one netlink dump, in `ip -o addr`'s order).

**tandod first.** As root, `tando-status status [app]` asks tandod (/run/tandod/tandod.sock, the
`status` verb of daemon/proto; 100 ms to connect, 20 s for the answer: `proto.AskStatus`, which
main passes to `Collector.StatusVia` as its `Remote`) and prints its answer; with no daemon, a
refusal, an error or an `err` answer it collects itself (so error messages stay its own).
`TANDO_STATUS_TRACE=1` (main sets `Collector.Trace`) says on stderr which way it went. The
daemon runs the same Collector, but with the rows of the other programs in-process: `rows.go`
defines `LogRows`, `AlertRows` and `TrendRows` (what `tando-logs log-stats`, `tando-watch brief`
and `tando-metrics read` print), `daemon/statusrows.go` implements them with srv/logs, srv/watch
and srv/metrics (status imports none of them), so an answer from the daemon starts nothing. It is
collected when asked (files, cgroups, the live systemd connection; the only caches are the
mtime-checked ones of those packages), never from the last tick. The skeleton repair of a
half-deleted app is done by tando-status before it asks (the daemon's sandbox cannot write
/opt/tando). The other verbs stay direct: they cost a bash and a Go start, which a socket would
not save.

**What a status costs.** The shell started some 40 processes for a host with 3 apps and two more
per app. Here: the cgroup and /proc files are read directly, nothing is started per app, and of
the other tando programs whose output status includes only `tando-logs log-stats` (root),
`tando-watch brief` and, for one app, `tando-metrics read` run (once each; they are Go too).
systemd is asked over its private socket (`/run/systemd/private`, root): one
`ListUnitsByPatterns("tando-*")` that loads nothing, then the five properties of each loaded
unit in one pipelined write (a loaded unit's property costs systemd next to nothing). A unit that
is not loaded (a stopped app, a static site) reads as systemd would show it right after loading
it (inactive, no restarts, no CPU time), and its MemoryMax comes from its unit file when that is
unambiguous (`unitfile.go`: the only file is a regular one in /etc/systemd/system, no drop-in
directory anywhere on the search path, a plain `128M`-style value); otherwise systemd is asked that
one property. Every question about a unit systemd has not loaded makes it parse the unit file,
announce it to every client and collect it again, about 3 ms of its CPU each time (five
property Gets cost five of those; `systemctl show`'s one GetAll per unit costs one). Without root,
or when the socket fails, it is one `systemctl show` for all units, as before. systemd 259 leaves
the first message after the handshake unanswered until more bytes arrive; `sdbus` sends a Ping
that wants no answer together with BEGIN (checked against systemd 255 and 259), and the bus has
3 s before systemctl answers instead. `info` asks python3, node and caddy for their versions only
when the program file (device, inode, size, times) or the dpkg status changed since
(`/var/lib/tando/status/tools`, root 600).

**Files an app can write.** None of the status files is: app.conf, state, activation,
activation.log, history.tsv, lock.holder are root's in the app's root-owned directory. Caddy's
certificate store belongs to the caddy user: nothing in it is followed (issuer and domain
directories are taken only when they are not links; the certificate is opened with O_NOFOLLOW).
Every read is bounded (key=value files 4 MiB, the history's tail 16 MiB, activation.log 4 MiB, a
certificate 256 KiB) and only regular files are read (a FIFO cannot hang a root process).

Tests: `harness_test.go` is a fake host (temp tree, fixed clock, a `run.Func` answering systemctl
and the tando programs); `status_test.go` the rows of every app state (running, stopped, failed,
deploying, static, adopted, damaged state, no state, no port, unreadable app.conf, systemctl
failing), the one-app sections, the error messages, the skeleton repair, releases ordering
(sort -n on seq, damaged seq), history (counts, NF == 12, unterminated lines) and the backwards
tail; `verbs_test.go` deploy-status (bash key order, recovery of a dead activation through
`tando-agent recover`, the history fallback, queued and waiting), busy (lock held, stale wait
markers removed), info and its cache, certificates (links refused, garbage), the bash
semantics of `read`; `unitfile_test.go` which unit files are read (drop-ins anywhere, a
higher-priority copy, a mask) and which values; `output_test.go` hostile bytes through every verb
and `StatusVia`'s relay; `internal/sdbus/sdbus_test.go` a fake systemd on a pipe (answers out of
order, error answers, the unit list, which units are asked what) and `FuzzReplies` (whatever
comes back, the reply parsing errs, never panics).

## hostcare: how the package is laid out

`parse.go` holds every parser (apt's simulation, `sshd -T`, /proc/net, PSI, mounts, dpkg's status
and `--audit`, `apt-config dump`, needrestart, unattended-upgrades' log, apt's history, ufw's rule
files, nftables.conf, the journal's JSON): bytes in, values out, table tests against output
captured on Ubuntu 24.04 and 26.04 (`testdata/ubuntu24`, `ubuntu26`; hand-written where a
container cannot produce it: `testdata/hand`) and `FuzzParsers`. `facts.go` collects (files
first; `systemctl`, `sshd -T`, one `journalctl` from a saved cursor), `apt.go` the slow facts
(cached in `apt.json`, refreshed every `apt_hours` or when dpkg's status changed), `sockets.go`
maps listeners to processes through /proc and classifies them, `firewall.go` reads ufw's files,
`judge.go` turns facts into findings and the alert checks, `summary.go` writes the summary file
(its format is the contract with tando-watch and tando-status), `state.go` what runs remember.
Actions: `care.go` (care mode's files), `units.go` (its unit files: real files, no transient
properties), `verbs.go` (status, check, update, the reboot sequence, after-boot, maintain),
`reboot.go` (`DecideReboot`, a pure function tested as a table with a fake clock: window edges,
time zones, DST, deploys, backups, boot age, skip, other sites), `probe.go` (the apps' health
after a reboot: watch's rule, copied: domain packages do not import each other), `notify.go`
(tando-watch's inbox, the audit line). Every program runs through `run` with constant options
(apt-get, apt-config, dpkg, needrestart, /usr/sbin/sshd, systemctl, journalctl, tando-agent
backup-run, tando-logs audit-write, tando-watch doctor); untrusted text (package, unit and
process names, journal lines) is cleaned before it reaches a row, the summary or a notice.
Tests: `harness_test.go` (a fake host: temp tree, fixed clock, recorded argv, fake statfs,
adjtimex and prober), `verbs_test.go` (every finding's thresholds, care on/off idempotent and
beside other sites, update's argv and the needrestart guard, a manual reboot's order, after-boot,
the window with skip and a deploy, hostile bytes through every output).

## offsite: how the package is laid out

Offsite copies of every backup (docs/BACKUP.md is the user's side and has the formats). No SDK:
`sigv4.go` signs (header form, payload signed; tested against AWS's published vectors in
`testdata/sigv4`), `s3.go` is the API subset over net/http (PutObject, multipart, GetObject with
Range and If-Match, HeadObject, ListObjectsV2, DeleteObject; retries with backoff and jitter on
network errors, 5xx and 429; no redirects, no proxy, TLS verified; every answer read bounded and
checked; `S3Error` turns a store's code into what to do), `upload.go` the single PUT / multipart
choice (one part in memory: 8 or 16 MiB), ETag and size checks, and the resumable download.
`crypt.go` is the streaming AEAD (AES-256-GCM chunks, HKDF subkey per object, STREAM nonces, the
header as AAD), `key.go` the recovery key, its text form and the key file, `bundle.go` the plaintext
container, `conf.go` the settings, `fs.go` how root opens files (O_NOFOLLOW|O_NONBLOCK, regular,
owned by root). The verbs: `push.go` (an upload; its state next to the backup; the app's config and
the inventory objects), `fetch.go` (fetch, ls, hosts), `sync.go` (the timer's run and its units),
`retention.go` (`prune`, pure), `state.go` (per-backup state, the per-app brief for tando-watch and
status), `verbs.go` (set and its probe, test, status, off, keys, doctor, the disaster-recovery verbs).
It starts only `systemctl` (the timer); the env of a recreated app goes to the agent through a pipe
the client runs on the server (`dr-env | tando-agent env-set`), so no Go code passes it on.

Tests: `fakes3_test.go` is an in-process S3 that checks every request's signature with its own
code (written from the specification, not from sigv4.go), the payload hash and Content-MD5, and
lets a test answer any request (5xx, 429, a dropped connection, a wrong ETag, a truncated body);
`testdata/fakes3` is the same as a program for test/e2e-offsite.sh (TLS, a control path). `s3_test.go`
uploads, retries, aborts, resume, bounded memory for 1 GiB; `crypt_test.go` round trips, every bit
flip, cut, swap, drop and repeat failing closed, 1.5 GB through a pipe in bounded memory, the key
text; `offsite_test.go` set/push/fetch on a fake host, object swaps and planted plaintext refused,
errors that name the cause without the secret, sync retries and the brief, a killed upload,
rotation, retention, disaster recovery, validation, hostile output. Fuzz: `FuzzOpen`,
`FuzzParseList`, `FuzzReadBundle`, `FuzzParseKey`. `TestProviderLive` runs only from
test/offsite-r2-check.sh against a real bucket.

## studio: how the package is laid out

`tando db studio` (docs/COMMANDS.md; the trust boundary and the resource scoping are in
docs/ARCHITECTURE.md). It starts no program (no `run`; `source_test.go` checks on the syntax
trees: no os/exec, no exec syscall, net.Listen only "unix"), so srvlint has nothing to list for
it. `pgwire` is the wire client: one TCP connection to 127.0.0.1:5432, the startup parameters,
SCRAM-SHA-256 only (MD5, cleartext, trust and other methods are refused with a message that names
`tando db psql`), `Simple` for the studio's own statements and `Exec` (Parse/Bind/Describe/
Execute/Sync, text format) for the user's: Parse refuses two commands in one string. Every
message is length-checked (8 MB) except DataRow, which is read as a stream: a cell is cut at its
cap and the rest discarded from the socket. COPY is answered (CopyFail, or the out data drained)
and refused; `Cancel` sends a CancelRequest on a connection of its own. `sqlsplit` splits the
editor's text (code-point offsets for error positions) and reads the first words: `ReadOnly` is
the allowlist. `studio` itself: `studio.go` (Config, New, the session's life: heartbeat, idle,
EOF; Serve and its shutdown order; the unix socket), `http.go` (the checks every request passes:
Host with the port, Origin, Sec-Fetch-Site, the content type, the bearer token; the one-time code;
the headers), `db.go` (the one connection and `ro`: `BEGIN READ ONLY; SELECT 1`, the statements,
`ROLLBACK`, `DISCARD ALL` and the resource settings again; the studio's own clock per statement;
cancel; the connection closed when idle), `query.go` (the editor: the allowlist before anything
runs, then statement by statement, streamed), `catalog.go` (tables, structure, rows: names from
the catalog only, quoted; values as parameters), `sink.go` (a result as streamed JSON, the row,
cell and answer caps), `jsonw.go` (the JSON writer: < > & U+2028/9 escaped, bad UTF-8 as U+FFFD),
`args.go` (the command line and the credential file), `ui.go` (the embedded page, gzip).

Tests: `pgwire_test.go` a scripted server on a net.Pipe (the RFC 7677 SCRAM exchange byte for
byte, the refused methods, a bad server signature or nonce, the wire bytes of P/B/D/E/S, error
fields, a notice mid-stream, a cut cell keeping the stream in sync, PortalSuspended, CopyIn
answered with CopyFail and Sync, CopyOut drained, the cancel packet, short reads, an oversized
message); `FuzzReadMessage`, `FuzzDataRow`; `live_test.go` the same client against a real
PostgreSQL (PGWIRE_LIVE; test/e2e-studio.sh S11 runs it on the test server). `sqlsplit_test.go`
the table of quotes and comments, code-point offsets, the allowlist; `FuzzSplit`.
`studio_test.go` with a fake DB that records every call: the exact sequence of a batch, a
transaction ended mid-batch, every known bypass refused before anything runs, absolute error
positions, row and byte caps, the studio's clock (cancel, then the connection closed), cancel and
busy, every refusal of the HTTP edge, the headers on every route, the one-time code, the history
key, the session's end in each way, no SQL text or value in the log. `catalog_test.go` the rows
SQL with hostile names (golden), `FuzzQuoteIdent`, `FuzzBuildRows` (every quoted name is the
catalog's, one statement), `FuzzJSONString`, the arguments. `ui_test.go` the page's byte budgets
and no HTML sink in s.js; `live_test.go` every bypass against a real PostgreSQL with the table
checked after.

## daemon: tandod

One process instead of a timer starting three programs a minute. `daemon.Daemon` wires the
domain packages for the machine and runs:

- **the schedule** (`sched.go`): a tick at the start of every minute while `tando-watch.timer` is
  active (the timer stays the on/off switch of the checks and their fallback). The next start is
  computed after each tick from the wall clock: a slow tick skips the minutes it overran, a
  suspend gives one tick, nothing drifts; between ticks one timer, no polling. A tick is what
  tando-watch.service ran: `metrics.Sample` and, only when an activation died or an app is down,
  `tando-agent recover-all` (in a unit of its own: it rewrites Caddy's config and links, which the
  daemon's sandbox keeps read-only), then `watch.Watch.Run` with the log scan of `srv/logs`
  in-process. Ticks never overlap (a mutex, and the flock of the watch lock against the one-shot).
- **what it keeps** between ticks: one connection to systemd's private bus (`busRunner` answers
  every `systemctl show` of watch and metrics with pipelined Gets: no fork, and stopped apps'
  units are not loaded every minute), `watch.Cache` (the key=value files, revalidated by inode,
  size and mtime on every use), the nftables ruleset generation the firewall rules were last
  complete at (in vstate, so `nft list` runs only after a change). The durable state of the checks
  is read from disk every tick and written with the commit protocol of watch/commit.go: a kill -9
  at any point is as safe as the one-shot's.
- **the socket** (`server.go`, `proto/`): /run/tandod/tandod.sock, 0600 in systemd's 0700
  RuntimeDirectory, peers checked with SO_PEERCRED (uid 0 only), one request line of at most 128
  bytes read within 2 s, 8 connections at once (more are told `busy`), 30 s per verb (a tick 250 s),
  answers capped at 8 MB. Verbs: `ping`, `tick`, `show [n]`, `history [n]`, `health [app]`,
  `brief [app]`, `status [app]` (srv/status's Collector). The CLI verbs ask here first (100 ms to
  connect) and do the work themselves when nothing answers; a request the protocol does not carry
  is never sent, so error messages stay the CLI's.
- **systemd** (`sdnotify.go`; main reads `NOTIFY_SOCKET`, `WATCHDOG_USEC`, `WATCHDOG_PID` and
  passes them as `daemon.Systemd`: the package reads no environment): Type=notify (READY=1), STATUS= after each tick ("idle; last tick
  <epoch>; <n> ticks[; degraded...][; problems: ...]": how `tando-watch doctor`, run without root,
  sees the last good run and the daemon's troubles), WATCHDOG=1 while the schedule makes progress.
- **its own health** (`health.go`): every tick, the scheduler body and each socket request run under
  `recover()`. `/run/tandod/active` exists while the ticks go well; the timer's fallback runs when
  it does not. A panic, 3 failed ticks or 2 the process did not survive (TickFile, in
  /run/tando-watch, outlives the process; a stop asked for is never one) make the daemon hand the
  checks to the one-shot (no shared code) and keep that state in /run/tando-watch/tandod.health,
  which watch's `monitor` check turns into an alert; retries back off 1 h ... 24 h. Liveness and
  backoff use `Clock.Boot` (time since boot, /proc/uptime: never steps, the same across restarts
  within a boot); the wall clock only aligns ticks on minutes and stamps them. A build with
  `-tags tandotest` (test/e2e-alerts.sh only) can make a tick panic or the process die
  (`hook_on.go`); a real build cannot. `-tags profile` adds a CPU profile (cmd/tandod).

Tests: `sched_test.go` (a fake clock: minute boundaries, a slow tick, a suspend), `server_test.go`
(the parser, a fuzz target, oversized, silent and non-root clients, the connection cap),
`daemon_test.go` (ticks through the real watch, no overlap, paused with the timer),
`health_test.go` (a panic, failed ticks, deaths across restarts, a panicking verb, Run, the
watchdog, status's rows), `busrun_test.go` (the bus answers against `systemctl show` output
captured on a test server: running, stopped/not loaded, failed, missing units, Caddy),
`sdnotify_test.go` (the watchdog interval from what main read), `output_test.go` (every answer
is clean, so the CLIs relay it as it is).

## Rules (test/go.sh enforces them)

1. **Layers.** `cmd/*` -> `daemon` -> domain packages (`metrics`, `logs`, `watch`, `gate`,
   `status`) -> `internal/*`. A domain package never imports another domain package;
   `internal/*` never imports a domain package. Something two domain packages need goes into
   `internal/`. `daemon` is the one composition layer: the only package besides `cmd/*` that may
   import several domain packages, and only `cmd/*` imports it; it holds scheduling, the socket and
   wiring, no check logic and no parsing. Where a domain package needs another one's work it
   defines a small interface and the daemon plugs in an adapter (watch.LogScanner: a subprocess
   in the one-shot, srv/logs in-process in tandod). Code two layers need goes down to `internal/`
   (systemd's bus, `internal/sdbus`, used by status and daemon); srvlint has no exceptions. (g5)
2. **No shell, ever; a closed set of programs.** Every external program starts through
   `run.Runner` with an argv slice, a timeout and an explicit environment (`run.BaseEnv` when nil:
   a fixed PATH and `LC_ALL=C`; nothing is inherited from sudo, systemd or a CI login). `internal/run`
   is the only package that imports `os/exec`, and it starts only what its allowlist names:
   - `run.Programs` (`internal/run/programs.go`) lists the program basenames `Exec` starts; any
     other name is refused. A name with a path separator must be absolute, clean, in one of the
     system directories (`/opt/tando/bin`, `/usr/sbin`, `/usr/bin`, `/sbin`, `/bin`, `/usr/local/*`,
     `/snap/bin`) and its basename must be listed.
   - Whatever the list says, a shell (`sh bash dash zsh ksh ash mksh yash posh fish csh tcsh rbash
     busybox`, with version suffixes) is refused, and so is a wrapper that starts whatever its
     arguments name (`env xargs find timeout nohup setsid su flock ...`: `run.Denied`).
   - `nice`, `sudo` and `systemd-run` are allowed because they are used, but they start another
     program, so each has a closed option set and the program they start goes through the same
     checks: `nice [-n N] prog`; `sudo -n -- prog` only (always root, no `-E`, `-u`, `-s`, `-e`);
     `systemd-run` with `--quiet --wait --collect --no-block --pipe`, `--unit=NAME` and
     `-p NAME=value`, where NAME is on a list (`systemdProperties` in `internal/run/check.go`: the
     sandbox and limit properties the receiver unit and the transient units use; never an `Exec*`
     property, which starts a program) and `Environment=` is only `LC_ALL=C`. No `-E`/`--setenv`,
     `--shell`, `--pty`, `--uid`. Any other option is refused, not guessed at.
   - A command runs in `/` (`Cmd.Dir` names another directory; the gate's rsync runs in the upload
     directory), never in the caller's: under sudo that may be a directory another user can write.
     Its environment is exactly `Cmd.Env` or `BaseEnv`, minus `LD_*`, pagers, editors and the like
     (`scrubEnv`); nothing comes from the parent (a test sets variables and checks).
   - `srv/tools/srvlint` (`cd srv && go run ./tools/srvlint ./...`) reads every `.go` file's syntax
     tree (standard library only: `go/parser`, `go/types` for names and constants) and fails on:
     `os/exec` imported outside `internal/run` under any name (alias, dot, blank); a call or
     reference to `os.StartProcess`, `syscall.Exec`/`ForkExec`/`StartProcess`, resolved through the
     real import path; `syscall.Syscall*`/`RawSyscall*` with a number that is not on the per-package
     list in the tool (today `gate`: fstatat, readlinkat, unlinkat; `logs`: fstatat); cgo, plugins,
     `go:linkname`, any module outside the standard library (and `go.mod` with a `require`); a string
     constant (concatenations folded, raw strings too) that is a shell or has one as basename in a
     call into `run`, and `-c`/`-lc`/`-ec` after one; a program name that is not a constant (it
     follows variables, `append`, helper functions such as `quiet(...)`, `bin("tando-agent")` and
     `which("nft")`; the only exceptions are the two `Paths` fields and `execScanner.bin`, listed in
     the tool); an argv changed after it was built (`a[0] = x`, `copy`, `&a`, `slices.X`); `Output`
     taken as a method value; every `-p` of `systemd-run` with a constant name on the list; and the
     layering of rule 1, without exceptions. Test files get the same checks as warnings (`-v`).
   - `srv/tools/srvlint/args.txt` (`go run ./tools/srvlint -args ./...`, with the count of
     positions at the end) lists, per call site and program, every argument as constant, constant
     start, number, validated (a reviewed claim in `args.go`, with its reason), after `--`, or the
     value of an option; an argument that is none of these fails the lint, so a new non-constant
     argument must be validated (and claimed, with its reason) or placed after `--`. Fixed forms are
     enforced per program: `rsync` is never given `-e`/`--rsh`/`--rsync-path` (its non-constant
     options are `checkRsyncOpts`' result), `sendmail` only `-t -oi`, `du` only `-smxc -- dirs`,
     `nft` only `list table inet tando` or `-f <path joined to a fixed name>`, `visudo -c -q -f f`,
     `crontab -r -u user`, `caddy` only `version` and `validate --config f --adapter caddyfile`,
     `python3 -I -c <constant>`, `node --version`, and `journalctl` always `--no-pager` (or an
     operation that prints no log). Regenerate the file with its header lines kept; its diff is
     what a reviewer reads.
   - `srv/tools/srvlint/programs.txt` lists the programs the tree runs, per package (`go run
     ./tools/srvlint -list ./...` prints it); the lint fails when the tree and the file differ, and
     when `run.Programs` and the file name different programs. **To add a program**: use it in the
     code with a constant name, add its basename to `run.Programs`, regenerate `programs.txt`
     (`go run ./tools/srvlint -list ./... > /tmp/p; ` keep the header lines of the file), and put
     all three in one review: the diff of the list is where it is noticed. Pass path operands after
     `--` where the program supports it (`du -smxc -- dir...`).
   - `test/lint.sh` (RL15, RL16) stays as a cheap first line on the literals. (g4, g5)
3. **gofmt, go vet, go test, go test -race** clean. (g1-g3, g8) Static Linux binaries for amd64
   and arm64. (g6) `srv/tools/` (srvlint) is a repository tool: `scripts/build-server.sh` and
   `scripts/release.sh` build and ship `srv/cmd/*` only.
4. **No package-level mutable state.** What comes from the machine is in `env.Env`, passed by
   value; tests build their own (temp dirs, a fixed clock, a `run.Func` instead of systemctl).
   `buildinfo.Version` is the one exception: the linker sets it.

## Conventions

- **Errors**: return them, wrapped with what was being done (`fmt.Errorf("read %s: %w", p, err)`),
  lowercase, no program name. `main` is the only place that exits: it prints
  `tando-<name>: <error>` on stderr and exits 1 (the shell's `die`; the client turns
  `tando-<name>: ` into `tando: `). Two differ on purpose: tando-status prints the agent's
  `tando-agent: <error>` (cleaned), and tando-gate exits with a child's exit status (`gate.Exit`)
  and prints only `tando-gate: internal error` after a panic. Every other failure is exit 1.
- **main** parses the verb, builds the Env and the writer, reads the environment (and passes
  what it read: `Logs.Getenv`, `daemon.Systemd`, `status.AgentEnv(os.LookupEnv)`), and maps the
  error to an exit status. Policy lives below it: when to ask tandod and with what timeouts
  (`daemon/proto/client.go`), the status fallback (`status.StatusVia`), the query's CPU limit
  (`logs.LimitProcessCPU`). Messages the client or tests match (`bad app name`,
  `bad point count`, `sample runs as root ...`) stay word for word.
- **Output** goes through the one `*out.Writer` main makes for the process; never `fmt.Print`
  to stdout below `main`. `Row` (an empty field is `-`), `Fields` (empty fields stay empty: where
  the shell printed a line as awk did) and `KV` clean every field and key with `out.Clean`, like
  the agent's `san_v`: C0 controls (tab and newline too), DEL and C1 (also a lone 0x80-0x9F byte)
  become `?`, bidi overrides are dropped. Bytes pass without `out.Clean` in these places only,
  each named so it can be found:
  - `Relay`: output another out.Writer made, cleaned there once: tandod's answer in tando-watch
    (`proto.AskWatch`), and in tando-status's status the rows of `tando-watch brief` and
    `tando-metrics read` (or their in-process twins in tandod). tando-status's own relay of
    tandod's answer is `StatusVia` writing the body whole.
  - `Stream`: text that is not rows, neutralised by its verb: tando-logs' journal lines
    (`journal.Filter.Line`: C0 as `^X`, DEL as `^?`, bytes that are not printable UTF-8, C1
    included, as `\xHH`, golden-tested against the shell's awk; a bidi override in a printable
    message is kept as the shell kept it, and the client's `lx_clean` drops it; the header lines
    come from the history as the agent wrote it, through `dropControls` as the shell's `tr -d`),
    and the configuration snippets `unit-props` and `caddy-log` (validated names and settings).
  - tando-status's verbs write their whole output in one write at the end (a verb that fails
    prints nothing): the rows were made by an out.Writer over a buffer (`sink`).
  - tando-gate passes a child's stdout through as the protocol it is (rsync's receiver, root
    mode's own output); the rows of tando-agent it relays are the deploy user's, so it cleans
    them again (`Fields`).
  The shell programs cleaned differently from each other; those rules are kept as values of
  `out.Cleaner` (watch: a space, U+FFFD, 300 characters; gate: `?`, 160 bytes). Every binary has
  a test feeding `outtest.Hostile` (C0, DEL, C1 as UTF-8 and as a lone byte, bidi overrides)
  through each of these paths (`output_test.go` in metrics, watch, gate, logs, status, daemon).
- **Untrusted text** is checked at the boundary: `valid.App` before a name becomes a path, unit or
  user; `valid.Uint` for numbers from argv; values read from files are parsed, never evaluated.
- **Files**: write with `atomicfile` / `kvfile.Save` and an explicit `Perm` (mode, owner) equal to
  the shell version's. Appends (logs, `.tsv`) are one `write(2)` per line. `main` sets
  `umask 022` as the shell programs did, so new directories are 755.
- **Paths** come from `Env` (`Root`, `Lib`, `Cgroup`, `Proc`); an override the shell had for tests
  (`TANDO_METRICS_DIR`) is read in `main` and passed in. Whether a check follows a symlink is in
  its name (`fsinfo.DirFollow`, `fsinfo.RegularNoFollow`, ...): NoFollow for a path in a
  directory a user other than root can write (Caddy's log directory, /run/user/<uid>, an app's
  `data_dir`), Follow where the directory is root's and the shell followed (`[[ -d ]]`).
- **Root**: a verb that needs root checks `Env.EUID == 0` in the domain package (testable).
- **Names**: package names are nouns (`metrics`, `kvfile`), exported functions are the verbs
  (`Sample`, `Read`, `ParseReadArgs`). Small files, one concern each; comments say why, and carry
  over the shell's comments that explain a decision.
- **Bash semantics worth keeping** (the shell is the contract): `IFS=$'\t' read` collapses runs of
  tabs and gives the rest of the line to the last variable; `read` drops a last line without a
  newline; values keep a trailing `=` and a `\r`; a missing *or unreadable* file was often treated
  as empty (`[[ -r $f ]] || return 0`); bash glob order follows the locale, Go's is bytewise (use it
  only where order is not part of the output). Not worth keeping: bash reads `08` as an octal error,
  `010` as 8 (fixed by `valid.Uint`).

## Build and test

```
scripts/build-server.sh            dist/server/linux-{amd64,arm64}/<name> (static, reproducible)
test/go.sh                         gofmt, vet, go test, the no-shell lint, layering, both CPUs
cd srv && go test ./...            the unit tests alone
test/all.sh --only go,e2e-top      with the end-to-end suite of a program
```

`tando host setup` from a checkout runs `scripts/build-server.sh -q` first (a no-op build takes
about 0.3 s), so a test server never gets a binary older than its source. Without Go it uses what
`dist/server` holds, and fails naming `scripts/build-server.sh` when that is empty. A release
(`scripts/release.sh`) carries both CPUs' binaries as `server/linux-<cpu>/<name>`, and so does an
install (`install.sh`).

## How a program reaches a server

`install_helpers` (lib/common.sh) asks the server for `uname -m` and the SHA-256 of what is
installed (one ssh call), then streams every helper that differs in a second one: the shell
program `server/<name>`, or the binary for the server's CPU (`helper_file`). Unchanged ones are
not sent (only re-checked and given their owner and mode). On the server each file is checked for
size and SHA-256, then a script with `bash -n` and a binary by running `<binary> version`
(exit 0 required), and only then are all moved into `/opt/tando/bin` (root, 755). `tando doctor`
gets one checksum per CPU for a Go program (`123,456`) and accepts either.

## Adding a verb

1. A function in the domain package (`func (m Metrics) Verb(...) error`), arguments checked by a
   `ParseXArgs([]string)` in the same package, output through the `*out.Writer` it is given.
2. A `case` in `cmd/<name>/main.go` and the usage line.
3. Table-driven tests next to it; an end-to-end check in the suite that covers the program.
4. If the agent or the client calls it: the agent's dispatch, docs/ARCHITECTURE.md.

## Porting a shell program (tando-logs, tando-watch, tando-gate)

1. `cmd/tando-<name>/main.go` (copy `cmd/tando-metrics`), the domain package `<name>/`.
   Every verb of the shell version, plus `version` (`buildinfo.Version`): install runs it.
2. Move what two programs need into `internal/` with tests; nothing speculative.
3. `mv server/tando-<name> server/legacy/` once the Go one passes its suites. Nothing else needs
   to know: `helper_file`, install, release, doctor sums and test/e2e.sh pick the binary when
   `server/<name>` is gone and `srv/cmd/<name>` exists.
4. grep for the program's name in `lib/`, `server/`, `test/` and `docs/`: code that reads
   `$TANDO_HOME/server/<name>` itself must use `helper_file` (as lib/cmd-alerts.sh does for
   tando-watch's checksum, accepting either CPU's binary).
5. Compare old and new on a test server against the same files (the legacy script still runs
   there: `sudo bash server/legacy/tando-<name> ...` streamed over ssh).
