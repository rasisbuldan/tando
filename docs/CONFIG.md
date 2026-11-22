# tando.conf reference

`tando.conf` sits in the project directory. One setting per line, `key = value`; spaces around the
`=` and at the ends are ignored, lines starting with `#` and empty lines are skipped. An unknown key
or a bad value stops the command with the file, the line and what was expected. `tando init` writes
a first file; `tando deploy` (or `tando up`) applies it. A setting you remove is cleared at the next
deploy. `tando help conf` prints a short version of this page.

```
app = shop
host = vps
recipe = node
start = node server.js
health = /api/health
memory = 256M
data = data
job.nightly = daily | node scripts/nightly.js
```

Types: **text** is taken as written; **number** is whole digits; **size** is digits and `K`, `M` or
`G`; **time** is digits and a unit; **bool** is `true` or `false`; **path** is relative to the
project (or to the release on the server). Every key below is accepted by the client
(`lib/common.sh`, `conf_load`); the server checks them again (`tando-agent configure`).
test/ui-test.sh fails when this page and the code disagree: one table row per key, the key first.

## App

| Key | Type | Default | Unit | Meaning | Example |
|---|---|---|---|---|---|
| `app` | name | the directory name (`tando init`) | | The app's name on the server: starts with a lower case letter, then lower case letters, digits and `-`; 2 to 24 characters (the server makes a group `tando-m-<app>`, and a group name stops at 32). | `app = shop` |
| `host` | text | the only registered server | | The server (`tando host ls`) this project deploys to; `-H` overrides it. | `host = vps` |
| `recipe` | choice | detected by `tando init` | | How the app is built and run: `node`, `next`, `static`, `python`, `container` or `workerd` (the Workers API, one workerd process per app; opt-in, docs/COMMANDS.md "Workers apps"). | `recipe = next` |
| `node` | number | `.nvmrc`, then `engines.node`, then the current LTS | major version | The Node.js major the server installs and runs the app with. | `node = 24` |

## Build

| Key | Type | Default | Unit | Meaning | Example |
|---|---|---|---|---|---|
| `build` | text | none | | A command run on your machine before the upload (`sh -c`). For a container without `image`, the image build is added after it. | `build = npm run build` |
| `out` | path | `.` | | The directory that is uploaded (static sites: the built files). It must be inside the project. | `out = dist` |
| `spa` | `true` or `false` | `false` (`tando init` writes `true` for a Vite app with a client-side router) | | Static sites only: a single-page app. A path that is not a file gets `index.html`, so the app's router answers deep links like `/about/team`. | `spa = true` |
| `dockerfile` | path | `Dockerfile` | | The Dockerfile `recipe = container` builds when `image` is not set. | `dockerfile = docker/Dockerfile` |
| `image` | text | none | | A ready image the server pulls instead of one built here (`recipe = container`). | `image = registry.example.com/shop:1.4` |
| `container_port` | number | none | port | The port the container listens on (`recipe = container`). | `container_port = 3000` |
| `build_memory` | size | `512M` | bytes | Memory limit of the server-side build of a Python app's virtualenv. | `build_memory = 1G` |

## Run

| Key | Type | Default | Unit | Meaning | Example |
|---|---|---|---|---|---|
| `start` | text | from the recipe (`npm start`, the server entry ...) | | The command that starts the app. It listens on `$PORT`. Without `start_shell` it is split on spaces and run without a shell. | `start = node server.js` |
| `start_shell` | bool | `false` | | Run `start` with `sh -c` (pipes, `&&`, `$VARS`, quotes). | `start_shell = true` |
| `path` | path | `/` | URL path | Serve the app under a sub-path (starts with `/`). | `path = /shop` |
| `memory` | size | `256M` (none for `static`) | bytes | Memory limit of each process of the app; over it the process is killed and restarted. | `memory = 512M` |
| `writable` | paths | none | | Directories inside the release the app may write to (a copy per release), separated by spaces or commas. | `writable = .next/server/app` |
| `soak` | number | `30` | seconds | How long a new release must stay up after going live before the deploy counts as good; a crash in it rolls back. | `soak = 60` |

## Health

| Key | Type | Default | Unit | Meaning | Example |
|---|---|---|---|---|---|
| `health` | path | `/` | URL path | The route a new release must answer (and the monitor probes) before it takes traffic. | `health = /api/health` |
| `health_timeout` | number | `60` | seconds | How long a release may take to become healthy; Caddy holds requests that long if it is over 15. | `health_timeout = 90` |
| `health_expect` | text | any 2xx or 3xx | | What the monitor wants from the health route: a status (`200`, `2xx`) and/or text the answer contains. | `health_expect = 200 ok` |
| `health_fails` | number | `3` (the host's alert setting) | probes | Failed probes in a row before the `health` alert fires, 1 to 99. | `health_fails = 2` |
| `health_recover` | number | `2` (the host's alert setting) | probes | Good probes in a row before the alert resolves, 1 to 99. | `health_recover = 3` |

## Limits

| Key | Type | Default | Unit | Meaning | Example |
|---|---|---|---|---|---|
| `cpu` | number or percent | none | % of a core, or cores | The app's CPU share: `50%` or `1.5` cores. | `cpu = 150%` |
| `tasks` | number | `1024` | processes and threads | Processes and threads of the app, 10 to 999999. | `tasks = 512` |
| `max_conns` | number | `256` | connections | Connections Caddy keeps to the app, 1 to 99999. | `max_conns = 100` |
| `max_requests` | number | off | requests | Requests in flight through Caddy; over it a visitor waits, then gets a 503. | `max_requests = 200` |
| `hold` | number | `15`, or `health_timeout` if larger | seconds | How long Caddy holds a request while the app (re)starts, 1 to 999. | `hold = 20` |
| `response_timeout` | number or `off` | `60` | seconds | How long Caddy waits for the headers of the app's answer; then the visitor gets a 504. Websockets and event streams (their headers come at once) are not cut. `off`: no limit (long polls). | `response_timeout = 300` |
| `body_max` | size or `off` | `100MB` | `KB`, `MB`, `GB` | The largest request body Caddy passes to the app; a larger one gets a 413. | `body_max = 2GB` |
| `cold_timeout` | number | `30` | seconds | With `idle_stop`: how long a visitor waits for the idle app to start; then a 503 "waking up" page with `Retry-After: 5` (the app goes on starting). | `cold_timeout = 10` |
| `stop_timeout` | number | `10` | seconds | How long a stopping process may finish its requests before it is killed, 1 to 999. | `stop_timeout = 30` |
| `priority` | `high`, `normal` or `low` | `normal` | | Which app the kernel stops last (`high`) or first (`low`) when the server runs out of memory, and its CPU weight under contention (200, 100, 50). `high` also keeps the app's memory, up to its cap, from being reclaimed while other apps have more. | `priority = high` |
| `tmp_size` | size | `64M` | `K`, `M`, `G` | The app's `/tmp` and `/var/tmp`, each a tmpfs counted in its memory. | `tmp_size = 256M` |
| `io` | number | none | MB/s | Read and write bandwidth on the disk of the app's directory, 1 to 99999 (only where the cgroup io controller is). | `io = 50` |
| `disk` | size | host `app_max_mb` (8192 MB) | `M`, `G` | The app's disk share (files and database) for the `disk_warn` (80%) and `disk` alerts. Not a hard quota. | `disk = 2G` |
| `preview_ttl` | time | `7d` | `s`, `m`, `h`, `d` | How long a preview app of this app (`tando preview up`) lives before the server removes it, at most 90 days. | `preview_ttl = 3d` |
| `preview_env` | env names | none | | Variables of this app's env a preview gets, copied once when it is made: names separated by commas or spaces. Nothing else is copied; never `DATABASE_URL`, `DATABASE_URL_DIRECT`, the paths the server sets, or a value naming this app's database or directory (docs/PREVIEWS.md). | `preview_env = API_BASE, FEATURE_FLAGS` |
| `preview_skip` | env names | none | | Variables a preview never gets, even when `preview_env` names them. | `preview_skip = STRIPE_SECRET_KEY, SMTP_PASSWORD` |
| `preview_release` | `on` or `off` | `off` | | Whether a preview runs this app's `release` command (migrations) on its deploys. Off: a branch nobody reviewed never migrates what the env points at. | `preview_release = on` |
| `idle_stop` | time or `on` or `off` | `off` | `s`, `m`, `h` | Scale to zero: stop the app's web process after this long without a request and start it on the next one (`on` is `6h`). Only the web process stops; workers and scheduled jobs keep running. Not for `static` sites or containers. The first request after idle waits while the app starts; no down alert is raised while it is idle (docs/COMMANDS.md, "Scale to zero"). | `idle_stop = 10m` |
| `node_lite` | `true` or `false` | `false` | | V8's `--lite-mode` for the app's `node` (recipes `node`, `next`): no optimizing JIT, about 10 MB less memory once warm, about half the peak throughput. For small, low-traffic apps. `tando init` never sets it (docs/COMMANDS.md, "node_lite"). | `node_lite = true` |

## Assets

| Key | Type | Default | Unit | Meaning | Example |
|---|---|---|---|---|---|
| `assets` | `off`, or a directory and optionally a URL prefix | found by tando for `next` (`.next/static`) and `static` (the first of `assets`, `_astro`, `static`, `_next/static` whose files all have a hash in their name); nothing for other recipes and containers | | The release's fingerprinted files (names that carry their content: `index-DiwrgTda.js`), which stay reachable after a newer release goes live and are sent with `Cache-Control: public, max-age=31536000, immutable`. `<dir>` is inside the release; the prefix is the URL they are served under, with the app's `path` if it has one (default `/<dir>/`). `off` turns it off. Name only files whose names change with their content. | `assets = public/build, /build/` |
| `compress` | `on` or `off` | `on` | | Caddy compresses text answers (HTML, CSS, JS, JSON, SVG, plain text; zstd or gzip, what the visitor accepts) of 512 bytes or more. An answer the app already compressed, an event stream and a websocket are sent as they are. For the fingerprinted files (`assets`) of text types, tando also keeps a gzip copy made once at deploy time, so they cost no CPU per request. `off` sends everything as it is and makes no copies. | `compress = off` |

## Data and database

| Key | Type | Default | Unit | Meaning | Example |
|---|---|---|---|---|---|
| `data` | path | none (`data` with `database = sqlite`) | | A directory that survives deploys, given to the app as `$TANDO_DATA_DIR`. For a container: the volume's path inside it (`/data`). | `data = data` |
| `backup` | choice | `daily` when `data` or `database` is set, else off | | `daily` or `off`: a daily backup of the data directory and the database. | `backup = off` |
| `database` | choice | none | | `postgres` or `sqlite`; the app gets `DATABASE_URL`. | `database = postgres` |

## Database limits

PostgreSQL only (`database = postgres`); `off` turns a limit off.

| Key | Type | Default | Unit | Meaning | Example |
|---|---|---|---|---|---|
| `db_statement_timeout` | time or `off` | `30s` | `ms`, `s`, `m`, `h` | How long one statement may run. | `db_statement_timeout = 2m` |
| `db_idle_tx_timeout` | time or `off` | `5m` | `ms`, `s`, `m`, `h` | How long a connection may sit idle inside an open transaction. | `db_idle_tx_timeout = 1m` |
| `db_temp_limit` | size or `off` | `1G` | `M`, `G` | Temporary files of one connection (large sorts, index builds). | `db_temp_limit = 4G` |
| `db_pool` | number | `5` | connections | Server connections pgbouncer gives the app (with `db_direct = true`: what its own pool should stay within). The apps' pools together must fit in max_connections. | `db_pool = 10` |
| `db_direct` | `true`, `false` | `false` | | `true`: `DATABASE_URL` is PostgreSQL itself, not pgbouncer. For LISTEN/NOTIFY, session advisory locks, session SET, prepared statements on old drivers (docs/COMMANDS.md, "Database connections and pgbouncer"). | `db_direct = true` |

## Release command

Runs on the server once per deploy, before the switch (migrations). Not for `static` or `container`.

| Key | Type | Default | Unit | Meaning | Example |
|---|---|---|---|---|---|
| `release` | text | none | | The command, run in the new release as the app's user. | `release = node scripts/migrate.js` |
| `release_shell` | bool | `false` | | Run it with `sh -c`; needed for `&&`, pipes, `$VARS` and quotes. | `release_shell = true` |
| `release_timeout` | number | `300` | seconds | Longest it may run, 1 to 3600; over it the deploy fails and nothing is switched. | `release_timeout = 120` |

## Jobs

| Key | Type | Default | Unit | Meaning | Example |
|---|---|---|---|---|---|
| `job.<name>` | text | none | | A scheduled job: `<schedule> \| <command>`. The schedule is cron (`*/15 * * * *`, `0 9 * * mon-fri`, `@daily`: five fields, lists, ranges, steps, month and weekday names) or a systemd calendar expression (`daily`, `*-*-* 03:00`, `Mon..Fri 09:00`); either is checked before anything is deployed. Times are the server's time zone (`tando jobs` says which). The name is lower case letters, digits and `-`, starts with a letter, at most 21 characters. One line per job. A job removed from tando.conf (or by a rollback) loses its timer at once; a run of it still going on finishes within its timeout. | `job.nightly = daily \| node scripts/nightly.js` |
| `job_timeout` | number | `3600` | seconds | Longest any of the app's jobs may run, 1 to 86400; past it the job is stopped and its result is `timeout`. | `job_timeout = 600` |
| `job.<name>.timeout` | number | `job_timeout` | seconds | The same for one job, 1 to 86400. | `job.nightly.timeout = 7200` |
| `job_spread` | number | a sixth of the job's period, at most 600 (hourly: 10 minutes) | seconds | A job starts this long after its time at most, at a fixed offset of its own, so the hourly jobs of 100 apps do not all start in the same second. 0 to 3600; 0 starts them exactly on time. | `job_spread = 0` |
| `job.<name>.spread` | number | `job_spread` | seconds | The same for one job. | `job.report.spread = 300` |
| `job_missed` | `run` or `skip` | `run` | | What a run the server missed while it was off or down becomes: `run` makes it up once when the server is back (a nightly backup), `skip` waits for the next time (a morning digest that would arrive at night). | `job_missed = skip` |
| `job.<name>.missed` | `run` or `skip` | `job_missed` | | The same for one job. | `job.digest.missed = skip` |

## Workers

Long-running processes beside the web one: queue consumers, websocket servers, schedulers. Each is
its own process (`tando-<app>_worker-<name>`), as the app's user, in the same sandbox, with the
same env and in the same release as the web process, with no port. A worker that exits is started
again (after 2 s, then longer); one that keeps exiting is shown by `tando status` and `tando ls`
and raises the `worker.<name>` alert, and never stops the web process. At a deploy the workers
change once the new release's web process passed its health check: the old ones are stopped (each
gets its `stop_timeout`), then the new ones start; one that does not stay up fails the deploy and
the old ones run again. Not for `static`, not for `container` yet. At most 20.

| Key | Type | Default | Unit | Meaning | Example |
|---|---|---|---|---|---|
| `worker.<name>` | text | none | | The command of a worker, run in the release (`sh -c` when it has shell syntax). The name is lower case letters, digits and `-`, at most 21, and not a job's name. One line per worker. | `worker.queue = node worker.js` |
| `worker.<name>.memory` | size | `memory` | bytes | Memory limit of that worker; the app's limits count it. | `worker.queue.memory = 512M` |
| `worker.<name>.stop_timeout` | number | `30` | seconds | How long a stopping worker (a deploy, `tando stop`) may finish its work after SIGTERM before it is killed, 1 to 3600. | `worker.queue.stop_timeout = 120` |

## Domains

| Key | Type | Default | Unit | Meaning | Example |
|---|---|---|---|---|---|
| `domain` | list | none | | Domains for the app, separated by spaces or commas; added when the deploy goes live (one that is refused or rolled back adds none; `tando domain rm` removes one). Lowercase host names only; the server refuses one under its `apps_domain`, one another app has, and one whose www twin another app has, as `tando domain add` does. | `domain = example.com example.org` |
| `www` | choice | by name, see below | | What `www.<domain>` does: `redirect` to the domain, `serve` the app too, or `off`. | `www = serve` |

`www` defaults to `redirect` for a registered name (`example.com`, `example.co.uk`) and for a
`www.` name, and to `off` for a sub-domain (`app.example.com`). `tando domain add` prints the mode
it chose and why.

## Logs

Per app; the host's defaults are set with `tando host setup` (docs/LOGGING.md).

| Key | Type | Default | Unit | Meaning | Example |
|---|---|---|---|---|---|
| `log_max` | size | host default, else the smaller of 256M and 5% of the disk | `K`, `M`, `G` | Size cap of the app's journal, at least 4M; the oldest entries go first. | `log_max = 500M` |
| `log_keep` | time | host default, else `30d` | `h`, `d`, `w` | How long the journal keeps entries. | `log_keep = 14d` |
| `log_rate` | text | host default, else `5000/30s` | lines / seconds | Lines per interval per service, as `<lines>/<seconds>s`, or `off`. | `log_rate = 2000/10s` |
| `access_log` | bool-like | `on` | | `on` or `off`: write the request log. | `access_log = off` |
| `request_log_max` | size | host default, else the smaller of `log_max / 4` and 256M | `K`, `M`, `G` | Disk budget of the request log, at least 4M. | `request_log_max = 100M` |

## Not settings

The client also sends `origin`, `force` and `check` to the server with every deploy. They are
protocol words, not keys of `tando.conf`, and the file rejects them.
