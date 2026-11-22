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
  (fixtures; one reachable host, one not; the writes are emulated with state by `web/dev/fake-state.mjs`:
  a slow deploy, a failing one, a busy restart, deploy refused for its origin, see the top of that file).

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

### The Mac app

`tando menubar install` also builds **tando Dashboard.app** in `~/Applications`: a regular app (Dock
icon, Cmd+Tab, Spotlight, app/Edit/View/Window menus) that is a thin WKWebView on the system WebKit.
The menu bar's **Open dashboard** (⌘D) and `tando dashboard` open it. It uses the installed `tando-dash`
(the menu row says "Install dashboard…" when there is none), starts it when `dash.lock` names no running
process, asks it for a fresh one-time link and loads it. One window, at least 900x600, size and place
remembered; ⌘R reloads, ⌘W closes the window (the app stays, doing nothing). Links to other sites open in
your default browser; the window never shows anything but `127.0.0.1:<port>`. While `tando-dash` runs, the
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
| GET | `/api/ping` | none (answers `{ok, client}`: this machine's `user@machine` as tando records deploys) | none | cookie |
| GET | `/api/snapshot?host=&app=&range=&visible=` | `snapshot --json -H <host> [--app <app> [--range 1h\|24h\|7d]]` | 10 s per (host, app, range), single flight | cookie |
| GET | `/api/overview?visible=` | the snapshot above, per host, in parallel | as snapshot | cookie |
| GET | `/api/doctor?host=` | `doctor <host> --json` | 60 s per host (also failures) | cookie |
| GET | `/api/hoststatus?host=` | `host status <host> --json` | 60 s per host (also failures) | cookie |
| GET | `/api/logs?host=&app=&n=&since=&level=&grep=&worker=&release=` | `logs <app> -H <host> --json -n <n> [--since T] [--level L] [--grep TEXT] [--worker W] [--release ID]` | none | cookie |
| GET | `/api/logs/stream?host=&app=&level=&worker=` | `logs <app> -H <host> --json -f -n 200 [--level L] [--worker W]` (a restart: `-n 1000 --since @<epoch>`) | one child per (host, app, level, worker), shared | cookie |
| POST | `/api/confirm` `{action,host,app}` | none | token 60 s, single use | cookie |
| GET | `/api/jobs?host=&app=` | `jobs ls <app> --json -H <host>` | 60 s per (endpoint, host, app, range), single flight | cookie |
| GET | `/api/requests?host=&app=&range=1h\|24h\|7d` | `requests summary <app> --json -H <host> --since <range>` (default 1h) | as jobs | cookie |
| GET | `/api/errors?host=&app=` | `errors <app> --json -H <host>` (24 h) | as jobs | cookie |
| GET | `/api/envnames?host=&app=` | `env ls <app> --names --json -H <host>` (names only; never `env ls` without `--names`) | as jobs | cookie |
| GET | `/api/envlog?host=&app=` | `env log -a <app> --json -H <host>` | as jobs | cookie |
| GET | `/api/alerts?host=` | `alerts --json -H <host>` | as jobs | cookie |
| GET | `/api/history?host=` | `history --json -H <host>` (every app of the server) | as jobs | cookie |
| POST | `/api/studio/open` `{host,app}` | `db studio <app> -H <host> --json` once per host, then `mint <app>` on its stdin | none (a click may mint two codes) | cookie (no confirm token) |
| POST | `/api/action` `{action,host,app,confirm,params?}` | the action's argv (below) | idempotency record 24 h | cookie + confirm token + `Idempotency-Key` |
| GET | `/api/action?key=` | none | the record | cookie |
| GET | `/api/action/stream?key=` | none (the write's output file) | none | cookie |

Snapshot answers: `{host, app, range, fetched_at, age_s, cached, next_poll_s, data}` where `data` is
the CLI's JSON as it is; `next_poll_s` is 5 with `visible=1` (default) and 60 with `visible=0`.
Live (5 s): while a visible page asks for a server, tando-dash keeps one `tando snapshot --json
--follow -H <host>` running for it (the server pushes a line every 5 s over one ssh session) and
answers that server's polls from the last line, without running anything; an app's page gets its
own snapshot (at most every 10 s, cached) with the live app row and server numbers laid over it.
The follow ends 30 s after the last visible poll. A server without a live view (older tando,
no tandod, no cgroup v2: the follow exits at once) is polled through the 10 s cache and asked
again after 10 minutes. Why not a 5 s poll: on the server a poll is an ssh exec, a shell, sudo,
the agent and tando-status each time; a follow is one process reading tandod's socket.
Overview: `{hosts: [{host, ok, fetched_at, cached, data} | {host, ok: false, error}], next_poll_s}`.
Doctor and host status: `{host, ran_at, cached, next_run_s, data | error}`.
Action: 202 `{key, action, host, app, status: "running", started_at, replay}`; the same key again
returns that record (`replay: true`, 200 once ended); the same key with another body 422; another
write of the same app while one runs 409 `{"error":{"code":"running","running":{action,since,key}}}`.
`GET /api/action?key=` adds `output` (the last 8 KB) and, once ended, `ended_at`, `exit`, `code`
(`busy`: another operation held the app; `message` is then `busy: ` and the CLI's own words),
`message` and `outcome`.

The app reads above answer `{host, app, ran_at, cached, next_poll_s, data}` (`range` too for
requests; no `app` for alerts and history), `data` the CLI's JSON as it is (test/fixtures/json),
or the error shape with `error` instead of `data`. They run in `/`, so a `tando.conf` in the
folder tando-dash was started from never picks the app or the server.

### Writes

| action | params | tando argv |
|---|---|---|
| `deploy` | none | `deploy -a <app> -H <host>`, run in the app's recorded folder |
| `rollback` | `{release?}` (an id from releases; none: the CLI's rollback target) | `rollback <app> [<release>] -H <host>` |
| `stop`, `start`, `restart` | none | `<action> <app> -H <host>` |
| `env-set` | `{key, value}` | `env set <KEY> -a <app> -H <host>`, the value on stdin |

- **deploy** runs where tando recorded the app was last deployed from: the server keeps
  `origin=user@machine:path` in the app's app.conf (written by every deploy, checked by the agent:
  "was last deployed from X, not from here"); `tando releases` sends it as an `origin` row and
  `tando snapshot --app` as `app.origin`. tando-dash refuses (422 `deploy_folder`, one line saying
  why and what to do) when there is no record (a server set up by an older tando), when the record
  is another machine's (`user@machine` is not this one's, as lib/deploy.sh `client_name` makes it),
  when the folder is gone, or when its `tando.conf` names another app or another server. It never
  passes `--force` or `--yes`: where the CLI would ask, it stops and says so in the output.
- **env-set**: the value is one line of text (no line break or other control character, 32 KB at
  most; refused before anything runs, in words that never repeat it). It goes to the CLI on stdin
  and nowhere else: not in argv, the idempotency record (the value is not part of the body the
  HMAC covers; a reused key with another value is refused while tando-dash runs, from a key kept in
  memory only), the output file, a log line or an error.
- Every write runs with `TANDO_FROM=dashboard`: the CLI puts it in front of `sudo` in its ssh
  command, and the server's audit line says `from` dashboard instead of the address (a deploy
  key's gate refuses such a command, so no key can set it).
- **Outcome from the server.** When the CLI ends, tando-dash reads the app back with `snapshot`:
  for deploy and rollback the history entry newer than the one before the write (waiting while the
  app is `deploying`, a soak, up to 15 min), for the others its state. The record's `status` is
  `done` when the server agrees (a deploy whose CLI was killed after the server finished is
  `done`), `failed` with the CLI's last `tando:` line and the server's word otherwise. `outcome`:
  `{checked_at, state, release, history?, verdict: ok|failed|unknown, summary}`.
- **Reattach.** A write that was running when tando-dash stopped is not killed (its own process
  group, output to its file) and is taken over at the next start: its app stays taken (409) until
  that CLI is gone, then its outcome is read from the server as above. Only an env set (the state
  says nothing of it) and the test action end as `unknown`, with where to look.

The progress stream is Server-Sent Events, read from the write's output file, so a reloaded page,
a second tab and a restarted tando-dash see the same lines: `hello` (`{key, action, host, app,
status, started_at}`), `line` (`{n, text}`, `id:` n; with `Last-Event-ID` only the lines after it),
`end` (the record as `GET /api/action` gives it, without `output`; the last event). A comment every
15 s keeps it open; 32 streams at most.

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
only), the app reads above, and the writes (`deploy -a <app> -H <host>`, `rollback <app>
[<release>] -H <host>`, `stop|start|restart <app> -H <host>`, `env set <KEY> -a <app> -H <host>`;
never `--force`, `--yes`, `KEY=VALUE` or a value), each with an exact set of flags and positionals. Names
follow tando's rules (app `^[a-z][a-z0-9-]{1,23}$`; host: letters, digits, `.`, `_`, `-`, and
here also no leading `-` or `.` and no `..`) and the host must be one of `~/.config/tando/hosts`.

## Tests

`test/dashboard-test.sh` (in `test/all.sh`): for the web app `npm ci`, vitest, the build, the bundle
budgets and the design rules (SKIP without node); then gofmt, `go vet`, `go test -race` (with a 2-minute
soak; the quick tier skips it with `-short`; `TANDO_DASH_SOAK=30m` for the long one), the main
release archive holding nothing of `addons/`, the stripped build, and the VERSION match. The Go
tests run a fake tando CLI (the test binary itself) with fault injection chosen by host name:
slow, hang (with a grandchild), garbage, a non-zero exit, killed mid-output, too large. For logs it
keeps a fake journal (4 lines a second) and leaves a grandchild holding stdout like ssh; for the
writes it keeps each app's state and history (snapshot shows them) and records every write's argv,
`TANDO_FROM` and folder: `busy*` hosts refuse as a held app does, `flop*` fail, `cut*` kill
themselves after the server finished, `soak*` stay deploying for one more read;
`drop*` hosts exit after 6 lines, `flood*` hosts write as fast as they can. A second 2-minute soak
has viewers joining and leaving streams.
