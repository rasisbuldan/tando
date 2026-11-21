# tando logging

13 Nov 2026. Bounded per-app logs, `tando logs` filters, request logs with `tando requests`, log
size visibility and an audit trail, on a 1 vCPU / 2 GB server, with nothing left running between
commands. Server side: `tando-logs`, a Go program (`srv/cmd/tando-logs`, package `srv/logs`,
srv/README.md; the shell original it replaced is `server/legacy/tando-logs`), installed next to the
agent as `/opt/tando/bin/tando-logs`. Laptop side: `lib/cmd-logx.sh` (`tando logs`), `lib/cmd-requests.sh`
(`tando requests`), `lib/cmd-audit.sh` (`tando audit`). Tests: `test/e2e-logs.sh` (follows
docs/TESTING.md: `TANDO_TEST_*` with its own default server `tando-test-logs` on 2304/8304, work
dir `T_WORK` or `test/.e2e-logs-<server>`; `TANDO_TREE` runs another tree, and
`TANDO_TEST_CADDY=ubuntu` the distribution's Caddy 2.6.2). Example app for floods and traffic:
`examples/logflood`.

Every number below was measured on the test server (`TANDO_TEST_DOCKER_ARGS="--cpus 1 --memory 2g"`,
Ubuntu 26.04, systemd 259, Caddy 2.11.9, mawk 1.3.4) unless marked as an estimate. The container
runs on an Apple M1 core: CPU seconds on the owner's x86 VPS will be higher (bench/RESULTS.md
suggests a factor of about 2 to 3); memory and bytes transfer.

## 1. Bounded application logs

### Decision: one journald namespace per app

Each app unit (and its pre-flight and job units) gets `LogNamespace=tando-<app>`. journald then
runs one small instance per app, `systemd-journald@tando-<app>.service`, writing to
`/var/log/journal/<machine-id>.tando-<app>/` with its own `SystemMaxUse=`, retention and rate
limit from `/etc/systemd/journald@tando-<app>.conf`. A noisy app can only rotate away its own
lines. The main journal (system services, Caddy, activations) gets its own cap from
`/etc/systemd/journald.conf.d/tando.conf`.

| Measured | Main journald | One namespace instance (per app) |
|---|---|---|
| Resident anon memory, idle | 1.2 MB (RssAnon 1,208 kB) | **1.06 MB** (RssAnon 1,048-1,060 kB, cgroup anon 1.07-1.09 MB; n=3 instances) |
| File pages (mmap of the journal, reclaimable) | 16.8 MB | 8.4 MB (memory.current 9.5 MB incl. cache) |
| Anon during an unlimited flood | - | 3.2 MB (memory.peak incl. cache 21.8 MB) |
| Disk with a 16M cap after a 20 s unlimited flood | - | 15.1M (`--disk-usage`), cap held |
| journald CPU, 20 s unlimited flood | - | 14.5 s (72% of the core) |
| journald CPU, 20 s flood, rate limit 5000/30s | 12.2 s | 8.4 s |

Ten apps cost about 11 MB of anon memory for their journald instances, about 0.5% of 2 GB; their
file pages are page cache that the kernel reclaims under pressure. The instance is started on
demand by its socket when the first unit of the namespace starts.

Why not the shared journal with per-unit rate limits and a global cap: journald has no per-unit
size cap, so the only per-app control is the rate limit, and journald scales the configured burst
by free disk space. Measured with `LogRateLimitIntervalSec=30s` / `LogRateLimitBurst=5000`, a
flooding unit still stored 18,750 lines in 20 s (about 940 lines/s, about 80 million lines a day).
Under any global cap that fits a small disk, one such app evicts every other app's history within
minutes. The shared journal cannot meet "one noisy app cannot evict other apps' logs"; namespaces
meet it for about 1 MB of memory per app, so namespaces were chosen.

What the rate limit does not do: it bounds what is stored, not CPU. journald still reads and
drops every line (8.4-12.2 s of CPU per 20 s of flood above), so a flooding app costs about as
much CPU in journald as in itself. On one vCPU that hurts everyone, logs or not; it is an app bug
that `tando logs` makes visible (`[journald] Suppressed N messages from tando-<app>.service`).
A flood loses most of its lines for good (the load test: 99.6%), so it is said, not left to be
noticed: `tando logs` ends with `# note: journald dropped N lines in this window (over log_rate
5000/30s)` when journald recorded drops between the oldest line shown and the end of the window,
and tando-watch raises a low-severity `logs` alert (docs/MONITORING.md). The limit is the
`log_rate` setting; raising it costs disk, `off` costs CPU in journald.

A unit-level `LogRateLimitIntervalSec=0` means "journald's default" (10000/30s), not "off"; the
first version did that and silently kept only about 15k of 600k flood lines. The limit therefore
lives in the namespace config (`RateLimitIntervalSec=`/`RateLimitBurst=`), where 0 does mean off.

### Settings

| Where | Key | Default | Meaning |
|---|---|---|---|
| tando.conf | `log_max` | host default, else min(2G, 5% of the disk) | journal size cap of the app (`SystemMaxUse=`), at least 4M. Circular: at the cap journald deletes the oldest entries to make room for new ones |
| tando.conf | `log_keep` | host default, else 30d | journal retention, `Nh` or `Nd` (`Nw` too): `MaxRetentionSec=`; journal files are closed after a quarter of it (15 min to 1 day, `MaxFileSec=`) because retention removes whole files |
| tando.conf | `log_rate` | host default, 5000/30s | `<burst>/<interval>s` per service in the app's namespace, or `off` |
| tando.conf | `request_log_max` | host default, else min(log_max / 4, 256M) | disk budget of the request log (below) |
| tando.conf | `access_log` | on | write the request log |
| `tando host setup` | `log_max=`, `log_keep=`, `log_rate=`, `request_log_max=` | as above | host defaults for apps without their own setting |
| `tando host setup` | `journal_max=` | 200M | cap of the main journal |
| `tando host setup` | `access_keep_for=` | log_keep | rolled request log files older than this are deleted |
| `tando host setup` | `access_size=`, `access_keep=` | from request_log_max | (older settings) file size in MiB and rolled files kept; when set they win over request_log_max |

Host defaults live in `/opt/tando/logs.conf`; app settings in the app's `app.conf` (sent by
`tando up`, validated by `tando-logs valid`). journald's own `SystemKeepFree=` (15% of the file
system) still applies to every namespace, so even a misconfigured cap cannot fill the disk.

**Defaults that cannot fill a small disk.** The built-in `log_max` is 2G, but an app without its
own (and without a host default) gets min(2G, 5% of the file system that holds the journals): 2G
on a 40 GB disk or larger, 500 MB on a 10 GB one. An explicit `log_max` is used as written.
`tando doctor` ("log caps") adds up every app's journal cap and request log budget, subtracts what
they already hold, and warns when they could still grow by more than the free space. `tando status
-a <app>` shows it as `logs 6.4 MB of 2.0 GB, keeps 30 d` (disk use of journal and request log, the
journal cap, the retention).

Changing `log_max`/`log_keep`/`log_rate` (`tando up`, or `tando host setup` for host defaults; apps
created before this get the new defaults at their next deploy or host setup) rewrites the
namespace config and restarts that app's journald instance only, never the app: journald keeps the
app's stdout/stderr streams in systemd's file descriptor store across its restart (measured: 13 of
13 once-a-second lines across two restarts, same PID). It then rotates and vacuums the namespace
(`journalctl --namespace=tando-<app> --vacuum-size=<log_max> --vacuum-time=<log_keep>`), so a
lowered cap or retention applies at once instead of at the next rotation.

## 2. `tando logs`

```
tando logs [-n N] [-f] [--since T] [--until T] [--grep TEXT [--regex] [-i]] [--level L] [--json]
tando logs --release <id> [filters]        lines from the period(s) the release was current
tando logs --deploy <id> [filters]         the activation unit's log and the pre-flight output
tando logs pull <file> [--since T] [--until T] [filters] [--json]
```

- `T`: `30s`, `15m`, `2h`, `7d`, `1w`; `2026-11-13`, `"2026-11-13 14:30"`, `2026-11-13T14:30:05`,
  `14:30` (today), all in GMT (UTC); or `@<epoch>`. Lines are shown in GMT too, like every table
  (the client sends offset `+0000`; on a terminal a first line `# times in GMT (UTC)` says so).
- `--grep` is a fixed string; `--regex` makes it a regular expression (Go's RE2 syntax: POSIX ERE
  plus `\d`, `\w`, `\b`, no back-references), `-i` ignores case.
  It is matched against the message only. `-n` counts matching lines: the newest N matches.
- `--level L` (`err`, `warning`, `notice`, `info`, `debug`; `error`, `warn` accepted) keeps lines
  at that level or worse. The level is the journal priority (apps can write `<3>` prefixes), or
  the level written in the text when that is worse: JSON loggers (`"level":"error"`, pino's
  `"level":50`), a `FATAL/ERROR/WARN/WARNING/...` word, a line starting with `[error]`/`error:`, or
  `TypeError: ...`-style exception lines. Text output tags such lines `ERR` / `WARN`.
- Output: `2026-11-13 23:23:47 [src] message`, where `src` is empty for the app itself, or
  `job:<name>`, `pre`, `act`, `release` (the release command of a deploy), `systemd` (systemd's
  own lines about the unit: start, stop, exit status), `journald` (rate-limit notices). `--json` prints one object per line:
  `{"time":"2026-11-13T16:23:47.047+00:00","usec":...,"src":"app","unit":"tando-x.service","priority":4,"level":"warning","msg":"..."}`.
- `--release <id>` of a release that never went live (failed pre-flight, failed build): its
  deploy log instead, the same as `--deploy <id>` (activation, build, pre-flight and release command units), headed
  `# release <id> was never live`. This is what the deploy failure box points to.
- `--release <id>`: the periods come from `history.tsv` (a deploy or rollback that verified makes
  the id current from `time - verify`; a deploy that was rolled back was current only during its
  verify). History times are whole seconds, so a boundary can be off by up to a second.
- `-f` follows. Every streamed line carries its journal cursor (stripped by the client); when ssh
  drops, the client reconnects with back-off (1, 2, 4 ... 30 s) and resumes after the last line
  shown, so lines written while disconnected arrive once. Ctrl-C ends it.
- `pull` writes plain text (or JSON lines) to a new local file; it refuses to overwrite.

Security model:

- The query travels as `key=value` lines on stdin (`tando-agent logs <app> spec`); the ssh command
  line holds only the app name. The server reads at most 30 lines and checks every key against a
  whitelist and every value against a strict pattern (`n` digits or `all`, times `@digits` or
  `-digits`, ids `YYYYMMDD-HHMMSS`, cursor `[a-z]=hex;...`, grep 1-256 characters without control
  characters). Anything else fails closed with an error, before journalctl runs.
- The server builds the journalctl argv itself, with exact unit names only (no globs: another app
  named `x-job` could match `tando-x-*`; job units are `tando-<app>_job-<name>`, and `_` is in no
  app or job name; a job name the agent would refuse is never one). The
  pattern is data in tando-logs, never text for a shell; a fixed string also goes to journalctl as
  one argv element, every non-alphanumeric character backslash-escaped so PCRE reads it as a
  literal. An invalid regex is detected before any output. RE2 matches in linear time, so no
  pattern can run away; a query still runs under a 120 s CPU limit (`RLIMIT_CPU`, inherited by
  journalctl; not with `-f`).
- Each entry is checked again by tando-logs: it must come from one of the app's units (`_SYSTEMD_UNIT`),
  or from PID 1 about one of them. With namespaces, other apps' lines are not in the files read.
- Control characters never reach the operator's terminal: journald stores a message that is not
  printable UTF-8 as a byte array; the server prints C0 controls as `^X` (ESC as `^[`), DEL as
  `^?`, and bytes that are not printable UTF-8 (C1 controls such as U+009B CSI included) as
  `\xHH`. The client filters C0/C1 controls again before printing. `--json` uses the same text.

## 3. Request logs

Each app's Caddy site gets a `log` block: JSON lines in `/var/log/tando/<app>/access.log`.

| Field | Written |
|---|---|
| time, method, host, path, status, duration, size, client IP, protocol | yes |
| request headers (Cookie, Authorization, Proxy-Authorization, User-Agent, Referer, ...) | **no**, the whole `request>headers` object is deleted |
| response headers (Set-Cookie, ...) | **no**, `resp_headers` deleted |
| TLS details, basic-auth user (`user_id`) | no |
| query string | **no**: replaced by `?-` (`request>uri regexp \?.*$ ?-`), so `/reset?token=...` is logged as `/reset?-`. Query values carry tokens, e-mail addresses and session ids too often; the path is enough for the statistics, and `?-` keeps the fact that a query was there. An app that needs its query strings logged must log them itself. |

The client IP is personal data; it is kept because it is needed to read an incident, and the
whole file is rotated away by size (below).

Files and permissions: the directory is `caddy:tando-<app>` mode `2750` (setgid, so rolled files
get the app's group), the files `0640`. Readable by root, Caddy (the writer) and the app's own
group; not by other apps, not by other users. `tando-logs app-setup` creates `access.log` before
Caddy sees the config, because `caddy validate` run as root would otherwise create it root-owned
and the reload would fail (found while building this).

Rotation is Caddy's own (no logrotate, no timer), sized from `request_log_max` (default min(log_max
/ 4, 256M)): files of an eighth of it, at most 32 MiB, and as many rolled files as fit (256M: 32 MiB x
(1 + 7)); rolled files are gzip'd by Caddy and deleted after `log_keep`. The budget holds even for
lines that do not compress; real request lines compress about 20x (measured: 1 MiB to 49 KB), so the
default keeps millions of requests in about 15-50 MB. The old default (4 MiB x 4, uncompressed)
kept about 50,000 requests: seconds of history under a load test. `tando requests` (summary, tail,
errors) reads the current file and the rolled ones, plain or gzip'd, that overlap the window.

Caddy keeps one log writer per file name across config reloads, so a changed rotation would wait
for a restart of Caddy (measured: files kept rolling at the old size after a reload). tando-logs
therefore alternates the name it gives Caddy between `<dir>/access.log` and `<dir>/./access.log`
(the same file) whenever the rotation changes (`/var/cache/tando-logs/<app>.reqlog` remembers
which): the reload opens a new writer with the new rotation, without restarting Caddy. Measured
on Caddy 2.6.2.

### The request index ("rollups") and the cost of a query

`req-summary`, `req-errors` and the per-minute scan read the request log through an index that
tando-logs keeps beside it, `/var/lib/tando/logscan/<app>/reqindex/` (root 700: paths and
client behaviour are not for other users):

| File | What |
|---|---|
| `state` | `tando-reqindex 2`, then one line per segment: id, bytes read, records, dictionary bytes and keys, flags, inode, gzip size, first-line hash, file name; sealed with a CRC line, every field checked for its shape and range on load (anything else: rebuilt) |
| `<id>.rec` | one 32-byte record per line that parses, in the file's order: time, duration, line offset, path id, status, histogram bin |
| `<id>.path` | the path keys the records use (`METHOD /folded/path`), length-prefixed |

A segment shadows one file of the request log: the current `access.log` (its records cover the
whole lines read so far; the rest is read from the file), a rolled file, or its gzip'd form (Caddy
renames, then gzips: the segment follows by inode, then by name and first line). It lives exactly
as long as its file, so the index has Caddy's retention (`roll_keep`, `roll_keep_for`,
`request_log_max`) and takes about a tenth of the uncompressed log (22 MB for the 190 MB below).
`tando-logs req-roll [app]` brings it up to date (O(bytes written since), no cap, one writer at a
time under `lock`); `watch-scan` does it every minute, and `req-summary`/`req-errors` first. A
killed roll loses nothing it had saved (records are appended, then `state` is replaced; extra
records are cut at the next run; it saves every 16 MB); a damaged file is read again from the log;
the clock going backwards changes nothing (records are kept in file order, not by time); a file
truncated or replaced under the same name starts a new segment (a gzip'd file is matched by name,
size and first line). The log directory is Caddy's: only names of Caddy's roll pattern are read
(`access.log`, `access-<letters, digits, ._:+->.log[.gz]`, at most 100 characters), at most 1,000
of them (the newest by name) out of at most 20,000 directory entries; more marks the app for
`log-doctor` (a `request log` warning) and writes a `log-files ... failed` audit line once, and is
never worked through (200,000 files: a tick of 40 ms and 0.2 MB of cache). A roll reads at most
128 MB (the rest at the next one: a sparse multi-terabyte file costs a bounded time a minute), and
a gzip'd file is indexed up to 512 MB decompressed (past that it is read from the log by the verbs
that ask, not indexed: a gzip bomb).

**Exact, by construction.** A record holds what the summary takes from its line, already parsed,
and the summary folds records in the file's order with the same arithmetic as the lines (every
floating-point sum in the same order), so its output is byte for byte a full scan's: window edges,
buckets, percentiles, the 2,000 paths and `* (other paths)`, `oldest`. A test builds the index
across appends, partial lines, rotation, gzip, truncation, deleted files, damaged files, a clock
gone back and odd lines, and compares every window and `req-errors` with a full scan. Nothing is
approximate; the price is that a segment whose path keys pass 1 MB (a client spraying unique
URLs; ordinary cache-busting names stay far below) or whose line holds a status a record cannot
hold is marked to be read from the log, which is then what the summary does for that file
(correct, at the raw speed below). `req-errors` reads back from the log only the newest N lines
the records select (by offset; one pass through a gzip'd file). `req-tail` reads the end of the
current file backwards.

Measured on 16 Nov 2026 on the test server (1 CPU, 2 GB), one file of 600,000 synthetic lines
(190 MB, 75,000 distinct path keys) spread over 24 h; CPU of the whole call (a transient unit's
`CPU time consumed`, median of 3) and peak RSS (wait4):

| Call | Shell version | Go, first port | Go with the index |
|---|---|---|---|
| `req-summary`, 7 days (every line) | 2.20 s, 10 MB | 0.70 s, 8 MB | **0.044 s** (index current), 9 MB; 0.05 s a minute later |
| `req-summary`, 24 h | 2.23 s, 11 MB | 0.69 s, 9 MB | **0.041 s**, 10 MB |
| `req-summary`, 15 min | 0.46 s, 11 MB | 0.08 s, 5 MB | **0.022 s**, 9 MB |
| `req-errors`, 7 days, newest 20 | 0.84 s, 11 MB | 0.25 s, 9 MB | **0.025 s**, 9 MB |
| `req-tail 30` | 0.07 s, 11 MB | 0.92 s, 10 MB | **0.005 s**, 5 MB |
| first build of the index (`req-roll`, or the first summary) | - | - | 0.31 s (1.9 million lines/s), 11 MB |

Without an index (another file shape, a sprayed segment) lines are parsed by a scanner written for
Caddy's key order (keys compared as literals, values checked as JSON, numbers converted exactly;
any other shape goes to `encoding/json/jsontext`, and a fuzz test holds the two to the same
result), with no allocation per line: 2.4 million lines a second for the summary's raw path
(0.25 s for the 600,000 lines). A request log rarely holds 600,000 lines in one window on a small
server; the index makes the cost follow what was written since the last minute, not the window.

The shell version's earlier measurements (awk alone, 13 Nov 2026):

| Lines in the files | Window 15 min (most lines skipped) | Window 24 h (all lines parsed) |
|---|---|---|
| 10,000 (3.3 MB) | 0.008 s | 0.036 s |
| 100,000 (33 MB) | 0.076 s | 0.36 s |
| 1,000,000 (334 MB) | 0.75 s | 3.5 s |

About 3.5 µs per parsed line and 0.7 µs per skipped line on this core. Because the request log is
capped at 16 MiB (about 50k lines), the worst case for any window is about 0.18 s of CPU here,
estimated 0.4-0.55 s on the slower VPS core; a 15-minute window on a busy app costs a few ms.
Hence: default window 15 minutes, rotation 4 MiB x 4 files. Compressed rolled files were rejected:
they would hold 10x more history, so a 24 h query would cost 10x more CPU plus gzip.

Percentiles come from a log-scale histogram (5% wide bins, values reported at the bin's geometric
middle), so they are within about 2.5%; max and mean are exact. Paths are grouped by method and
path with numeric segments folded to `:n` and hex ids of 16+ characters to `:id`; at most 2,000
distinct paths are kept, the rest count as `* (other paths)`.

### `tando requests`

```
tando requests [--last 15m|1h|24h]      boxed summary (default 15m)
tando requests tail [-n N] [-f]          newest requests (boxed; -f streams lines)
tando requests errors [--last W] [--4xx] the newest 5xx (or 4xx and 5xx) answers
```

The summary shows requests, rate per minute, 5xx and 4xx share, a per-minute sparkline (60
buckets at most) and one for 5xx, p50/p95/p99/max, status codes with a bar, slowest paths (mean),
most requested paths and paths with most 5xx. If rotation left less than the window, it says
where the log starts (UTC). `tail` and `errors` head their time column `TIME (GMT)`
(`MM-DD HH:MM:SS`, UTC) and the answer time `LATENCY`; `tail -f` lines start with `HH:MM:SS` in GMT too.

### The summary verb (for alerts and dashboards)

`tando-agent req-summary <app> <seconds>` (root; `seconds` 60..604800) prints, in this order:

```
files=<n>                 log files read
window=<seconds>
from=<epoch>              now - window
to=<epoch>                now
bucket=<seconds>          width of one counts bucket (window / min(window/60, 60))
total=<n>
c1xx=<n> ... c5xx=<n>     one line each
p50_ms=<ms> p95_ms=<ms> p99_ms=<ms> max_ms=<ms> avg_ms=<ms>   one line each, 2 decimals
counts=<n,n,...>          requests per bucket, oldest first
counts_5xx=<n,n,...>      5xx per bucket, oldest first
unparsed=<n>              lines without a status (should be 0)
paths=<n>                 distinct paths seen
oldest=<epoch>            oldest line in the files read (> from: the log holds less than the window)
code<TAB><status><TAB><count>                                   one row per status code
path<TAB><METHOD path><TAB><count><TAB><mean ms><TAB><max ms><TAB><5xx count>   one row per path
```

Rows are unordered. A 5xx-rate alert needs only `total`, `c5xx` (and `counts_5xx` for "in the last
minute": its last element). Cost: see the table above; a 5-minute window is a few ms.

## 4. Log size visibility

`tando-agent log-stats [app]` (root) prints one row per app:

```
logs <app> <journal bytes on disk|-> <journal cap bytes> <request log bytes on disk> <lines 24h>
     <bytes 24h> <suppressed 24h> <lines per hour x24, oldest first, comma-separated>
     <bytes per hour x24> <age of the counts in seconds>
```

Disk use is `du` of the app's journal directory and request log directory (allocated bytes). The
hourly counts are kept in `/var/cache/tando-logs/<app>.stats` with the cursor of the last entry
read; a call reuses them for 60 s, then reads only the entries written since. At most the newest
300,000 of them are read per call: when more arrived since the last call (a flood between two
refreshes), the older ones are not counted. Counts are of lines that reached the journal
(after the rate limit); `suppressed` counts journald's "Suppressed N messages" notices. If nobody
asks for stats for a day, the first call counts what the journal still holds, which after
rotation can be less than what was written.

Measured CPU (user+sys of the whole call, including journalctl) with 5 apps, one of them holding a
full 50 MB journal (102,055 entries):

| Call | CPU |
|---|---|
| `log-stats`, all apps, no cache (counts 24 h of every journal) | 0.48 s (2.38 s with JSON output; switched to `-o short-unix`) |
| `log-stats`, all apps, cached | 0.02-0.03 s (0.04-0.09 s wall) |
| `log-stats` refresh after a minute | proportional to new lines: about 3.2 µs per entry |

### Query cost of `tando logs` (same full 50 MB journal)

| Query | CPU |
|---|---|
| `tando logs` (newest 100) | 0.02 s |
| `-n 1000` | 0.035 s |
| `--grep TEXT` with no match (scans everything) | 0.21 s (2.0 s before the journalctl `-g` prefilter) |
| `--regex RE` / `--level` with no match (full scan, JSON + filter) | 2.0-2.4 s (shell version) |
| `logs pull` of all 102k lines | 2.1 s |

A fixed `--grep` is also passed to journalctl as an escaped literal (`-g`, case-sensitive unless
`-i`), which skips the JSON formatting of non-matching entries; tando-logs still makes the exact
decision.
It is not used for patterns that could match the `^X`/`\xHH`/`?` notation of neutralised bytes.
Full scans with a regex or a level filter cost about 2 s per 100k entries here (journalctl's JSON
output is 1.3 s of that, the shell version's awk 0.65 s); add `--since` to bound them.

## 4b. Errors and the per-minute scan

`tando-logs watch-scan [app...]` (root; tando-watch runs it once a minute for every app) reads each
app's journal after a saved cursor (`-o short-unix`, at most 20,000 entries; journalctl is not
started when the namespace's journal files are unchanged since the last scan) and brings the
request index up to date, taking its request numbers from the records added since its own
position (`req.idx`: for each log file, by the hash of its first line, the bytes already counted;
a line without its newline yet is left for the next run; all of a rolled file is counted; there
is no 8 MB cap any more, the `bytes skipped` column stays 0). The position is the file and a byte
offset, not the index's numbering, so it means the same after the index is rebuilt; where the
scan cannot tell what it counted (no position, a torn one, two files with the same first line, a
file shorter than its position) it learns and counts nothing, and only requests of the last 10
minutes count at all (after a monitor stopped for an hour, the hour is not this minute's burst). It prints, per app, the lines read, error
events, lines journald dropped, requests, 5xx answers, p95 latency and the top failing paths;
tando-watch turns those into the `http`, `slow`, `errors` and `logs` alerts
(docs/MONITORING.md). `tando-logs errors <app> <seconds> <n>` prints the error groups seen in the
window with one sample each (and an `hours <id> <hour start:count,...>` row per group: its errors
per hour of the window, for `tando errors --json`'s series), for `tando errors`, folding in what the journal has since the
monitor's last scan in memory: it writes nothing, so the monitor still reports a new error the
operator happened to look at first. `watch-scan` itself is the consumer: run by hand it takes
the minute's events from the monitor (they are printed to whoever ran it, not alerted on); it is
meant for tandod (in-process) and the legacy timer only. How error events are found and
grouped, and what is never sent to a notifier: docs/MONITORING.md "Errors in the app's own log".
The first scan of an app learns the last 24 hours without reporting them as new, and its error
event count is 0 (they are not this minute's: no "errors spike" from a first or a reset scan).
`groups.tsv` keeps, as its last line, `cursor<TAB><journal cursor>`: the journal position its counts
reach, written with them in one atomic replace. The `cursor` file (sealed: `c <cursor>`, or
`s <epoch>` while the journal has had nothing) is the position between event scans; of the two,
the further one is where the next scan goes on. A cursor journalctl refuses (vacuumed, damaged)
gives a `warn` row and a line on stderr, and reading goes on from that minute: never silently
stuck. Over 200 groups, the least recently seen go, but a group known before the scan and seen in
the last 7 days goes only after every group first seen in the scan: an app spraying distinct
messages cannot push out known groups to have a real error reported as new again.

In tandod (which calls the scan in-process every minute, `ScanCache`): an app whose active
journal file and `access.log` have the same inode, size and time as before its last full scan
gets its row (all zeros) from three stat calls, with no allocation, lock, file read or
journalctl; an app that has never logged a line is scanned once (`jsince` then keeps when), not
every minute. Measured 17 Nov 2026 on the test server (1 CPU): 100 idle apps cost the scan about
0.25 ms of CPU a tick; 20 apps with 240 requests a minute between them about 2.5 ms, plus one
journalctl started for each app whose journal changed (about 2 ms each: the floor). The index's
state and the scan's positions are written in place (no rename, no fsync); see "Crash
consistency" below for why that is safe, file by file. Between ticks the cache keeps only small path dictionaries
(at most 32 KB each, 512 KB in all) and no read buffers: under a spray of 2 million unique URLs
over 5 apps tandod's peak RSS was 14 MB (45 MB before these bounds).

### Crash consistency of the files written in place

The scan writes these without rename or fsync (a rename cost more than the rest of a tick on the
test server's overlay file system). What a lost or torn write can do, and why it cannot raise a
false alert, hide a real one, or stop the scan:

| File | Lost or torn write | Why no false alert, missed alert or silent stop |
|---|---|---|
| `reqindex/state` | CRC fails, or an old state (the last appends to `.rec` beyond it are cut) | the index is rebuilt from the log; the scan's position is file + byte offset, independent of it, so nothing is counted twice; while the rebuild catches up the position waits |
| `reqindex/<id>.rec`, `.path` | records past the state's count are cut; a short file fails the state's check | as above: rebuilt from the log, read again within its byte budget |
| `req.idx` (scan position) | CRC fails, or the previous position | torn: the scan learns (counts 0 for one minute, never a burst); previous: at most the last minute's requests again, and only those of the last 10 minutes count at all; a miss is impossible because a lost position only moves backwards |
| `cursor` | CRC fails, or the previous cursor | `groups.tsv` carries the cursor of every scan that counted events (one atomic replace with the counts), and the further of the two is used: lines read again after a lost write had no events (or `groups.tsv` would hold their cursor). No usable position at all: a first scan, which learns and reports 0 events. A cursor journalctl refuses: `warn` row, reading from now on |
| `jstamp` | a stale or torn stamp | it only lets the scan skip journalctl when the journal files did not change: a mismatch costs one journalctl run; it is written last, after the cursor |
| `req` (downgrade only) | stale | read only by the shell version after a downgrade, whose scan caps itself at 8 MB |
| `toomany` | lost | written again at the next tick (and the audit line said it once) |

`groups.tsv` and samples stay atomic (written only on a minute with error events).

Cost of the one-shot `tando-logs watch-scan` (16 Nov 2026, the test server, a journal of 517,846
entries and the 190 MB request log above): an idle app (nothing new) costs 5 ms of CPU, which is the process starting (the shell
version: 19 ms, its journalctl included); a run with 20,000 new journal entries and 8 MB of new
request log costs 0.14 s (shell: 0.21 s), of which journalctl's own output of the 20,000 entries
is 0.075 s: that is the floor while the journal is read through journalctl. The error-scan parser
alone reads 2.2 million short-unix lines a second (the shell version's awk: 420,000). `tando-logs
errors` on an idle app costs 11 ms (shell: 0.17 s), `log-stats` from its cache 5 ms (shell:
34 ms).

## 5. Audit trail

`/var/log/tando/audit.log`, `root:adm 0640`, one line per agent verb that changes something or
reveals a secret, appended under `flock`, written when the verb exits:

```
<epoch> TAB <who> TAB <from> TAB <verb> TAB <app or -> TAB <result> TAB <note>
1794587950  vmadmin  192.168.215.1  rollback  hello  ok  from 20261113-163909 to 20261113-163619
```

- who: the sudo user; from: the ssh client address (found in `SSH_CONNECTION` of an ancestor of
  the agent process). Timers and boot are `system` / `local`. A deploy is written once, by the
  detached activation when it ends, with the requester's who/from passed to it by `activate`.
- result: `ok`, `fail(<exit code>)`, `rolledback`; note: the error message, the release id, or
  `from X to Y` for a rollback (control characters removed, 300 characters at most).
- Audited verbs: setup, configure, deploy (activate + run-activation), rollback, recover,
  env-set, env-unset, env-ls (shows secrets), start, stop, restart, unlock, destroy, backup-run,
  backup-restore, backup-cat (exports data), db-url, db-psql. Not audited: begin/end (the upload
  lease of a deploy), read-only views, env-names (key names only, never a value), exec-app,
  run-job, recover-all at boot.
- Each line is also sent to the main journal (`logger -t tando-audit`), a second copy that a plain
  edit of the file does not change.
- Rotated by the writer at 4 MB to `audit.log.1` .. `.4` (20 MB at most, about 130,000 actions).
- `tando audit [app] [-n N]` shows it boxed (newest last, 40 rows by default); the `TIME (GMT)`
  column is UTC, `MM-DD HH:MM:SS`.

It is an operator's record, not tamper-proof: root can edit both copies. `chattr +a` was not used
because it also blocks the rotation by rename.

## 6. Shipping (`log_forward`): not built

Not built. The lightest design that fits "no resident daemon" would be a systemd timer per host
(every minute) running `journalctl --namespace=* --after-cursor=<saved> -o json | curl --data-binary @-`
to an HTTP endpoint, with the cursor saved only after a 2xx, plus the same for the request logs
by byte offset. For syslog, journald's `ForwardToSyslog=` needs a syslog daemon (rsyslog) that the
minimal image does not have; `systemd-journal-upload` is itself a resident daemon. Left for when
there is a concrete receiver to test against.

## 7. Server files

| Path | Owner, mode | What |
|---|---|---|
| `/opt/tando/bin/tando-logs` | root 755 | the helper (a static Go binary for the server's CPU) |
| `/opt/tando/logs.conf` | root 644 | host defaults (`journal_max`, `log_*`, `access_*`) |
| `/etc/systemd/journald.conf.d/tando.conf` | root 644 | main journal cap |
| `/etc/systemd/journald@tando-<app>.conf` | root 644 | the app's journal: cap, retention, rate limit |
| `/var/log/journal/<machine-id>.tando-<app>/` | journald's own (`root:systemd-journal`, ACL for `adm`) | the app's journal files |
| `/var/log/tando/<app>/access.log`, `access-<time>.log` | `caddy:tando-<app>` 0640 in a 2750 dir | request log |
| `/var/log/tando/audit.log[.1-4]` | `root:adm` 0640 | audit trail |
| `/var/cache/tando-logs/<app>.stats`, `<app>.reqlog` | root 644 in a root 700 dir | log-stats counts and cursor; the request log file name variant |
| `/var/lib/tando/logscan/<app>/` | root 700; files 644 | the per-minute scan: `cursor` (sealed), `jstamp`, `req.idx` (sealed: its request log position), `req` (the shell version's position, kept for a downgrade), `groups.tsv` (with its cursor), `samples/<id>`, `toomany` (the log directory has too many files), `lock` (600); removed with the app (`app-remove`). `jsince` (before 17 Nov 2026) is still read once |
| `/var/lib/tando/logscan/<app>/reqindex/` | root 700, files 600 | the request index (section 3) |

`tando destroy` removes the app's namespace config, journal directory, request logs and stats
cache (the audit trail keeps its lines).

## Notes for code that reads logs

- **LOGS column**: `agent_raw sudo log-stats` (all apps, one round trip) at most once a minute; the
  server caches the counts for 60 s anyway. Not on every 2 s `--watch` frame.
- Anything that reads an app's own output must use `journalctl --namespace=+tando-<app> -u ...`
  (or `tando-logs logs`). systemd's own lines about the unit (start, stop, exit status, OOM kill)
  stay in the main journal.
- The 5xx rate for alerts: `tando-agent req-summary <app> 300`, fields `total`, `c5xx`,
  `counts_5xx` (section 3).
- Unit names are always exact (`tando-<app>.service`, `tando-<app>_job-<name>.service`,
  `tando-<app>-pre-<id>`): an app may be called `<app>-2`, so `tando-<app>-*` is never safe.

## Known weaknesses

- **CPU under a flood.** The rate limit bounds what is stored, not what journald reads: a flooding
  app makes journald use about as much CPU as the app itself (measured 8-14 s per 20 s). Nothing
  here caps that; `CPUQuota=` on app units would, and is the core's call.
- **Memory per app**: about 1.1 MB anon for its journald instance, plus up to 8-20 MB of page cache
  for the mapped journal files (reclaimable, but it shows in `memory.current`).
- **Disk per app** with defaults is up to 50 MB + 16 MiB; `doctor` warns over a quarter of the
  disk, nothing refuses it. journald's 15% keep-free still protects the disk itself.
- **`--release` boundaries** come from `history.tsv`, whose times are whole seconds: lines within
  about a second of a switch can be attributed to the neighbouring release.
- **`--level` from text is a heuristic.** A message that contains the word `ERROR` in another
  sense is tagged as an error; an app that writes errors without a level word or `<3>` prefix is
  not. The journal priority itself is exact.
- **Regex dialect** is RE2 (Go's `regexp`): POSIX ERE plus Perl classes, no back-references, and a
  repeat count of at most 1000. `-i` matches case-insensitively (the shell version lowercased the
  pattern, so `[A-Z]` with `-i` matched nothing). Patterns are matched against the neutralised
  text (`^[` for ESC).
- **Full scans** with a regex or level filter cost about 2 s of CPU per 100k entries on this core
  (estimate 4-6 s on the VPS); they are capped at 120 s of CPU per query, not refused.
- **`-f` across a long disconnect**: lines written and already rotated away while disconnected are
  lost (journalctl seeks to the nearest remaining entry). A follow on a flooding app also costs
  the JSON formatting of every line.
- **log-stats counts** only what reached the journal and was still there when first counted; if no
  one asked for a day, the first call counts what survived rotation.
- **Request log**: client IPs are kept; query strings are dropped wholesale (an app that needs them
  must log them); path folding knows numbers and hex ids only (slugs make many distinct paths, cut
  off at 2,000). Percentiles are
  within about 2.5% (histogram bins).
- **Audit** is not tamper-proof (root can edit the file and the journal copy); `who` is the sudo
  login, so admins sharing one login are indistinguishable; `from` is the address the server sees
  (NAT, jump hosts). begin/end lease calls and reads of logs are not audited.
- **Apps created before this change** log into the main journal until their next `tando up`.
- **Recipes**: `container` apps log into their namespace like the others (`LogNamespace=` on the
  Podman unit; conmon passes the container's output through with `--log-driver=passthrough`).
  `static` sites have no process, so they have a request log and no app log: `tando logs` says so
  and `tando recipes` lists it.
- **Caddy 2.6.2** (Ubuntu's apt package) picks a site's request log by the Host header including a
  port, so a request naming a port (`site.example:8443`) would be served unlogged. The site
  answers such requests 400 instead (except the host's `public_port`, a test setup). It has no
  `output file { mode }` (Caddy 2.8+) and no `client_ip` field (2.7+): tando-logs leaves `mode`
  out there (the files keep the 0640 of the `access.log` it creates) and shows `remote_ip` (the
  shell version looked for it after a comma, but it is the first key of Caddy's `request` object,
  so it showed no address on 2.6).
- **tando's own health checks** (deploy pre-flight, activation, the alert timer) send the secret
  `X-Tando-Probe` header of `/opt/tando/probe.header` (root 600) from 127.0.0.1/::1, and Caddy leaves
  those requests out of the request log (`skip_log`), so a quiet site shows zero requests instead
  of one a minute. Site files are `root:caddy 640` because they hold that secret.
- **Settings with leading zeros** (`log_keep = 09d`) are read as decimal (`9d`) everywhere; a value
  in a file that no longer passes the checks falls back to the host or built-in default, so a
  site file never gets a broken number.
- **`-f` on a filter that never matches** keeps its server-side journalctl until the next line
  reaches the pipe after the client went away (no keepalive row).
- **Measured on an arm64 M1 core in a container**; CPU numbers will be higher on the x86 VPS,
  memory and bytes should transfer. The rotation-size behaviour of Caddy (writer reused across
  reloads) was seen with Caddy 2.11.9.
