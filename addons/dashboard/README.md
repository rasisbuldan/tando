# tando dashboard (add-on)

A web dashboard for tando, served on your laptop by `tando-dash`. It is an add-on: it ships as its
own release asset (`tando-dash-<v>-<os>-<arch>.tar.gz`) and nothing of it is in the main tando
archive. Its version matches the tando CLI it is installed for (`VERSION`).

- `docs/SPEC.md`: what the dashboard is, its architecture, budgets and robustness rules.
- `docs/DESIGN.md`: the design guideline for the web app (M2 onwards).
- `server/`: `tando-dash`, a Go program with no third-party dependencies.
- `web/`: the web app (React, Vite, TypeScript, Tailwind, Recharts). `npm ci && npm run build` writes
  the build into `server/webdist/dist/`; `theme.js` stays a file of its own (`web/public/`).
- `server/webdist/dist/`: what `go build` embeds. The repository holds only a placeholder page; the
  build output is not committed, so the release build runs the web build first:
  `(cd web && npm ci && npm run build) && (cd server && go build ...)`. Developing the web app
  without a server: `web/dev/restart.sh` builds both and runs tando-dash against `web/dev/fake-tando.sh`
  (fixtures; one reachable host, one not).

## Install, run, uninstall

```sh
tando addon install dashboard      # the asset of this tando's version, checksum verified
tando dashboard                    # opens the browser with a one-time link (--no-open prints it)
tando addon status                 # installed version against the client's, running or not
tando addon uninstall dashboard    # stops it; removes binary, links, dash.lock, the cache files
```

`tando addon install dashboard` puts `tando-dash` in `~/.local/lib/tando-dash/<v>/` (with a
`current` link) and links it as `~/.local/bin/tando-dash`; `--from PATH|URL` and `--sha256 HEX` install
a downloaded or local archive (a checksum is always needed), `--version V` another version.
The release assets are `tando-dash-<v>-darwin-universal.tar.gz`, `-linux-amd64.tar.gz` and
`-linux-arm64.tar.gz`, each with a `.sha256`, built by `scripts/release-dashboard.sh` (web app,
then `tando-dash`; `--check` proves two builds give the same bytes). The add-on's version is the
client's: after a tando update run `tando addon install dashboard` again.

### The Mac window

On macOS the menu bar app (`tando menubar install`) has **Open dashboard** (⌘D): a window of its own
instead of a browser tab. It uses the installed `tando-dash` (the row says "Install dashboard…" and
shows the command when there is none), starts it when `dash.lock` names no running process, asks it
for a fresh one-time link and loads it. One window, reused; at least 900x600, its size and place are
remembered; ⌘R reloads, ⌘W closes the window (the app stays). Links to other sites open in your
default browser; the window never shows anything but `127.0.0.1:<port>`. While `tando-dash` runs, the
menu bar reads `cache/ls-all.json` when it is younger than its interval instead of running
`tando ls --all --json`. Rebuild the app after a tando update: `tando menubar install`.

## Running it from a checkout

```sh
cd addons/dashboard/server
go build -trimpath -ldflags "-s -w -X main.version=$(cat ../VERSION)" -o tando-dash .
./tando-dash              # opens the browser with a one-time link
./tando-dash --no-open    # prints the link instead
```

Flags: `--no-open`, `--idle 30m` (stop after that long without a request and with no write
running; `0`: never), `--port N` (default: the last port if free, else any), `--tando PATH`.
`tando-dash` runs the tando CLI it finds like the menu bar does: `--tando`, `TANDO_DASH_TANDO`,
`tando=` in `~/.config/tando/menubar.conf`, `PATH`, then `~/.local/bin`, `/usr/local/bin` and
`/opt/homebrew/bin`. It refuses to start when that tando is older than it needs or has no
`snapshot` command ("update tando: ..."), and checks again whenever the file changes on disk.

A second `tando-dash` does not start another server: it asks the running one for a fresh link
and opens it. It stops on Ctrl-C, SIGTERM or after the idle time.

Files (all 0600, under `~/.config/tando`, or `TANDO_CONFIG_DIR`):

| File | What |
|---|---|
| `dash.lock` | pid, port, re-open URL, the key a second `tando-dash` uses; held with flock, emptied at exit |
| `cache/ls-all.json` | the last overview, in `tando ls --all --json`'s shape, for the menu bar |
| `cache/dash-sessions.json` | SHA-256 hashes of the session cookies (30 days) |
| `cache/dash-idem.json`, `cache/dash-ops/` | idempotency records of writes (24 h, 500 at most) and their output |
| `cache/dash-port` | the last port |

## API

Every `/api/` request needs the session cookie (`401 {"error":{"code":"session"}}` otherwise:
the page shows "Session ended"). Errors are `{"error":{"code","message"}}`, the message one line.

| Method | Path | tando argv | Cache | Auth |
|---|---|---|---|---|
| GET | `/open?code=` | none | none | the one-time code (60 s, single use); sets the cookie, 303 to `/` |
| GET | `/`, `/theme.js`, other files | none | `assets/*` immutable, others no-cache | none (no data) |
| POST | `/api/newcode` | none | none | `X-Tando-Dash-Key` from dash.lock (a second tando-dash) |
| GET | `/api/ping` | none | none | cookie |
| GET | `/api/snapshot?host=&app=&range=&visible=` | `snapshot --json -H <host> [--app <app> [--range 1h\|24h\|7d]]` | 10 s per (host, app, range), single flight | cookie |
| GET | `/api/overview?visible=` | the snapshot above, per host, in parallel | as snapshot | cookie |
| GET | `/api/doctor?host=` | `doctor <host> --json` | 60 s per host (also failures) | cookie |
| GET | `/api/hoststatus?host=` | `host status <host> --json` | 60 s per host (also failures) | cookie |
| GET | `/api/logs?host=&app=&n=&since=&level=&grep=&worker=&release=` | `logs <app> -H <host> --json -n <n> [--since T] [--level L] [--grep TEXT] [--worker W] [--release ID]` | none | cookie |
| GET | `/api/logs/stream?host=&app=&level=&worker=` | `logs <app> -H <host> --json -f -n 200 [--level L] [--worker W]` (a restart: `-n 1000 --since @<epoch>`) | one child per (host, app, level, worker), shared | cookie |
| POST | `/api/confirm` `{action,host,app}` | none | token 60 s, single use | cookie |
| POST | `/api/action` `{action,host,app,confirm,params?}` | the action's argv (M1b: `noop` = `--version`) | idempotency record 24 h | cookie + confirm token + `Idempotency-Key` |
| GET | `/api/action?key=` | none | the record | cookie |

Snapshot answers: `{host, app, range, fetched_at, age_s, cached, next_poll_s, data}` where `data` is
the CLI's JSON as it is; `next_poll_s` is 15 with `visible=1` (default) and 60 with `visible=0`.
Overview: `{hosts: [{host, ok, fetched_at, cached, data} | {host, ok: false, error}], next_poll_s}`.
Doctor and host status: `{host, ran_at, cached, next_run_s, data | error}`.
Action: 202 `{key, action, host, app, status: "running", started_at, replay}`; the same key again
returns that record (`replay: true`, 200 once ended); the same key with another body 422; another
write of the same app while one runs 409 `{"error":{"code":"running","running":{action,since,key}}}`.
`GET /api/action?key=` adds `output` (the last 8 KB) and, once ended, `ended_at` and `exit`.

Logs: a tail answers `{host, app, ran_at, lines: [...], notes: [...]}`: `lines` are the CLI's JSON
lines as they are (`{time, usec, src, unit, priority, level, msg}`), `notes` its other lines.
`n` is 1-5000 (default 200); `since` takes the CLI's forms (`15m`, `2h`, `7d`, `2026-11-13`,
`2026-11-13 14:30`, `14:30`, `@epoch`; GMT); `level` `err`, `warning`, `notice`, `info`, `debug`;
`grep` is a fixed text of 1-256 characters without control characters and not starting with `-`
(one argv element, never a shell); `worker` and `release` follow tando's names. Anything else is
400, nothing run.

The stream is Server-Sent Events (`text/event-stream`). Events: `hello` (`{host, app, level,
worker, buffered}`), `line` (one JSON line; `id:` its number), `reconnecting` (`{attempt,
retry_in_ms, message}`), `reconnected`, `error` (`{code, message}`, the last event: `busy` when the
server's ssh sessions are taken, `ended` when the child failed 5 times in a row), `dropped` (the
last event: this tab could not keep up). A comment every 15 s keeps it open. Every tab watching
the same (host, app, level, worker) shares one `tando logs -f` child; a tab that joins later
first gets the last 500 lines (or, with `Last-Event-ID`, only those it missed). The child is
stopped 30 s after its last tab leaves; when it dies while tabs remain it is started again with
backoff (1 s doubling to 30 s) from the second of the last line, the lines already sent skipped.
Bounds: 2 streams per host (the third ssh session stays for reads: at most 3 tando children per
host in all, reads included), 16 streams, 32 tabs, 256 events queued per tab. The page should
close its EventSource on `error` and `dropped` (otherwise the browser reconnects by itself).

The allowlist (`server/internal/dash/allow.go`) is the only list of what tando-dash may run:
`--version`, `help snapshot`, `snapshot`, `doctor`, `host status`, `health <app> --json -H <host>`,
`logs <app> -H <host> --json -n N` with the filters above (and `-f` with `--level` and `--worker`
only) and `restart <app> -H <host>` (for M4), each with an exact set of flags and positionals. Names
follow tando's rules (app `^[a-z][a-z0-9-]{1,23}$`; host: letters, digits, `.`, `_`, `-`, and
here also no leading `-` or `.` and no `..`) and the host must be one of `~/.config/tando/hosts`.

## Tests

`test/dashboard-test.sh` (in `test/all.sh`): for the web app `npm ci`, vitest, the build, the bundle
budgets and the design rules (SKIP without node); then gofmt, `go vet`, `go test -race` (with a 2-minute
soak; the quick tier skips it with `-short`; `TANDO_DASH_SOAK=30m` for the long one), the main
release archive holding nothing of `addons/`, the stripped build, and the VERSION match. The Go
tests run a fake tando CLI (the test binary itself) with fault injection chosen by host name:
slow, hang (with a grandchild), garbage, a non-zero exit, killed mid-output, too large. For logs it
keeps a fake journal (4 lines a second) and leaves a grandchild holding stdout like ssh;
`drop*` hosts exit after 6 lines, `flood*` hosts write as fast as they can. A second 2-minute soak
has viewers joining and leaving streams.
