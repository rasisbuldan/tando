# tando dashboard (add-on)

A web dashboard for tando, served on your laptop by `tando-dash`. It is an add-on: it ships as its
own release asset (`tando-dash-<v>-<os>-<arch>.tar.gz`) and nothing of it is in the main tando
archive. Its version matches the tando CLI it is installed for (`VERSION`).

- `docs/SPEC.md`: what the dashboard is, its architecture, budgets and robustness rules.
- `docs/DESIGN.md`: the design guideline for the web app (M2 onwards).
- `server/`: `tando-dash`, a Go program with no third-party dependencies.
- `server/webdist/dist/`: the built web app, embedded into the binary (a placeholder until M2;
  the web app's build writes here; `theme.js` stays a file of its own).

## Running it

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

The allowlist (`server/internal/dash/allow.go`) is the only list of what tando-dash may run:
`--version`, `help snapshot`, `snapshot`, `doctor`, `host status`, `health <app> --json -H <host>`
and `restart <app> -H <host>` (for M4), each with an exact set of flags and positionals. Names
follow tando's rules (app `^[a-z][a-z0-9-]{1,23}$`; host: letters, digits, `.`, `_`, `-`, and
here also no leading `-` or `.` and no `..`) and the host must be one of `~/.config/tando/hosts`.

## Tests

`test/dashboard-test.sh` (in `test/all.sh`): gofmt, `go vet`, `go test -race` (with a 2-minute
soak; the quick tier skips it with `-short`; `TANDO_DASH_SOAK=30m` for the long one), the main
release archive holding nothing of `addons/`, the stripped build, and the VERSION match. The Go
tests run a fake tando CLI (the test binary itself) with fault injection chosen by host name:
slow, hang (with a grandchild), garbage, a non-zero exit, killed mid-output, too large.
