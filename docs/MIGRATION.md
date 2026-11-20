# Moving bakery and magazine onto tando (`tando adopt`)

A runbook for the owner's VPS. Rehearsed on a local replica of that server
(a replica container and a rehearsal suite, kept outside this repository because they
reproduce a private server). bakery was then adopted on the real server on 19 Nov 2026:
see "On the real server" at the end. magazine, timers and `adopt undo` are replica-only so far.
`test/e2e-adopt.sh` in this repository runs the same steps (without timers) against a synthetic
hand-deployed app on a test server.

The order is: `adopt plan`, `adopt site --apply` (the request hold), `adopt apply`. The second
step is there because of what the real server showed: 36 visitor requests got 502, 16 during the
adoption and 20 during the first deploy, because the hand-written site did not hold requests
while the app restarted, and the hold could then only be added after adoption.

## What adopt does, in one paragraph

`tando adopt` takes over a running, hand-deployed Next.js app **in place**. It keeps everything
production depends on: the port (3100, 3200), the app's user (`bakery`, `magazine`), the data
directory (`/var/lib/bakery`), the env file (`/etc/bakery.env`, used by the new unit as is: tando
copies its values into its own root-owned env file, never prints them), the hand-written Caddy site (tando does not render one:
`caddy = external`) and the path Caddy serves files from (`/opt/bakery/current` stays, as a link to
tando's current release). It changes: the unit (`bakery.service` becomes `tando-bakery.service`
with tando's sandbox), where releases live (`/opt/tando/apps/<app>/releases`), and timers that call
the app become tando jobs. Before changing anything it backs up the data, the unit, the env file,
`/etc/caddy`, the timers and the backup script, and records the hand-managed state. Any failed
check during `apply` returns the server to that state; `tando adopt undo` does the same on request
and then compares the server with the record.

## Decisions, and why (what the replica showed)

| Question | Decision | Why |
|---|---|---|
| Caddy: keep the hand-written block or let tando render one? | Keep it (`caddy = external`). `host setup` adds `import /etc/caddy/tando/*.caddy` and moves the admin API to a socket (global options), once; the site block is never touched. | The block has precompressed static files, `www` redirect, HSTS, request size limit and `X-Real-IP` for the rate limiter. tando's renderer can express none of these (R1). Caddy 2.6.2 accepts the import of an empty directory (checked on the replica). |
| Who serves static files, with what permissions (R1)? | Caddy, from disk, as today. `/opt/bakery/current` becomes a link to tando's current release; `.next/static` and `public` in each release are made world-readable (they are public anyway), everything else stays `root:bakery 640/750`. | tando releases are closed to other users (`o=`), so Caddy (user `caddy`) would get 403 for every CSS/JS file while Node answers the health check: the R1 failure. Adopt checks `runuser -u caddy test -r` before the switch, and every health check now fetches the first `_next/static` file of the health page and one public photo **through Caddy**. Tested: with the static directory closed, `tando restart` reports the app unhealthy. |
| Port | Keep 3100 / 3200. | The Caddyfile and the magazine timers call these ports; changing them changes the hand-written block (R8: the cron calls would miss). tando's pre-flight normally uses port + 100: for bakery that is 3200, magazine's port. Adopt picks a free pre-flight port from tando's range (4100) instead. |
| Data location | Keep `/var/lib/bakery` in place, owned by `bakery`; tando backs it up as `data_dir`. | Moving it would need a stop, a move and a change to `BAKERY_DATA_DIR`; and `bakery-backup` archives `-C /var/lib bakery`, so a symlink left behind would make the nightly archive hold only a link (R9). |
| App user | Keep `bakery` (`user = bakery` in app.conf). | No ownership change of the order file and photos; the backup script and anything else that knows the user keep working. |
| Env file | The values of `/etc/bakery.env` are copied into tando's own env file (`/opt/tando/apps/bakery/env`, `root:bakery 640`) at the switch, taken from the running process's environment, i.e. exactly what systemd gave the app, with no re-parsing of the file. The new unit does not read `/etc/bakery.env`; the file is left untouched for undo. The `Environment=` lines of the old unit (NODE_OPTIONS) move into the same file. | tando never prints a value: the plan shows variable names only, and adopt compares a digest of `NAME=value` in the old and new process (computed as root). Copying rather than referencing closes N5 (SECURITY-REVIEW-2): an env file in a directory the app can write could be swapped for a link to another app's env, and systemd would load it as root at the next restart. Afterwards the values behave like any tando app's: `tando env set` changes them and `tando env ls` shows them on request. |
| Timers (R8) | Each timer whose service calls the app becomes a tando job with the same `OnCalendar`, running as the app user with the same env file (so `${CRON_SECRET}` matches). The handoff is split around the restart: the old timers are paused (each once its service is idle) **before** the old unit stops, and resume as tando jobs **after** the new unit answers through Caddy, each with the old timer's last trigger as its systemd stamp and `Persistent=true`. Undo does the same in reverse and gives each hand-written timer its original stamp back. | An elapse that falls in the pause runs exactly once, after the app is back (Persistent catches it up); nothing runs twice because the stamp says the previous elapse already ran. The first version handed timers over after the restart: on the replica a timer fired into the restart window and its run was lost (curl: connection refused). Timers that cannot be expressed (monotonic, AccuracySec, specifiers, another user or env file, a literal secret in the command, disabled) stay hand-managed and are listed. |
| Backups (R9) | `bakery-backup` and its cron line stay as they are (it still reads `/var/lib/bakery`, which does not move). tando adds a backup of `/var/lib/bakery` before every deploy (`/var/backups/tando/bakery/*-predeploy`) and the full adopt backup. tando's nightly backup stays off (`backup=daily` turns it on). | The plan opens the newest `bakery-backup` archive and checks it holds every top-level entry of the data directory; the rehearsal runs the script after adoption and finds an order written after the switch in it. No "backup ok" on something that is not the data. |
| The image cache | Per release, as today (`next_cache = release`). | tando normally shares `.next/cache` across releases. bakery's `minimumCacheTTL` is 31 days because its cache is rebuilt with every release (next.config comment): a shared cache would serve an old photo for a month after it changes. |
| Regenerated pages (R2) | Per-release writable copies of `.next/server/app` **and `.next/server/route-cache`**. | Next 16 writes ISR output to `.next/server/route-cache` too. With tando's default (`app` only) every regeneration logs `EACCES: mkdir .next/server/route-cache` (seen on the replica). Adopt detects directories the app wrote at runtime. |
| The old deploy scripts | `/opt/<app>/incoming` becomes a file saying the app is managed by tando; the directory is kept as `incoming.pre-tando`. | `deploy-vps.sh` starts with `mkdir -p /opt/bakery/incoming`, so it now stops before it changes anything. Without this it would switch `/opt/bakery/current` to a release Node does not serve and restart a disabled unit: static files from one build, HTML from another. Tested on the replica. |
| Downtime | One restart: from `systemctl stop bakery` to the first healthy answer through Caddy. The old unit gets 20 s to stop, then SIGKILL. With the request hold in the site (`adopt site --apply`, step 2 below) requests wait for that restart and are then served; `adopt apply` refuses to start without the hold unless `--accept-502` is given. | A hand-written block usually has no request holding, so requests in that window get 502. Static files switch with no gap (the link moves first, both point at identical files). On the replica a Next server once ignored SIGTERM until systemd's default 90 s stop timeout (the hand-written units do not lower it); it kept serving meanwhile, but the switch waited. tando's own units stop within 20 s. |

## Before you start: read-only checks on the real server

Run these over ssh and compare with the replica's assumptions (table at the end). None of them
change anything. None print secret values (env files: names only).

```sh
# system
lsb_release -ds; uname -m; systemctl --version | head -1; caddy version; node --version; command -v node
free -m; df -h / /opt /var; sudo ufw status verbose
# units: the files, drop-ins, and what systemd made of them
systemctl cat bakery magazine
systemctl show bakery magazine -p User,WorkingDirectory,ExecStart,EnvironmentFiles,Environment,MemoryMax,MemoryHigh,ReadWritePaths,Restart,DropInPaths
# release layout and ownership
ls -la /opt/bakery /opt/magazine; readlink /opt/bakery/current /opt/magazine/current
sudo stat -c '%U:%G %a %n' /opt/bakery/current/ /opt/bakery/current/server.js /opt/bakery/current/.next/static /opt/magazine/current/server.js
# data and env files: owners and modes, variable NAMES only
sudo stat -c '%U:%G %a %n' /var/lib/bakery /var/lib/bakery/db.json /var/lib/bakery/uploads /etc/bakery.env /etc/magazine.env
sudo sed -n 's/^\(export \)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p' /etc/bakery.env /etc/magazine.env
sudo tr '\0' '\n' < /proc/$(systemctl show -P MainPID bakery)/environ | sed 's/=.*//' | sort | tr '\n' ' '; echo
# Caddy: the site block, and whether it validates as is
sudo cat /etc/caddy/Caddyfile; ls -la /etc/caddy; caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
# timers and cron jobs that call the apps (look at ExecStart: the secret should be ${VAR}, not a literal)
systemctl list-timers --all --no-pager
systemctl cat 'magazine*.timer'
systemctl show 'magazine*.timer' -p Id,TimersCalendar,TimersMonotonic,AccuracyUSec,RandomizedDelayUSec,Persistent,UnitFileState
sudo grep -rn 'bakery\|magazine\|3100\|3200' /etc/crontab /etc/cron.d /var/spool/cron/crontabs 2> /dev/null
# the backup: what it runs, and whether the newest archive holds the data
sudo cat /usr/local/bin/bakery-backup; sudo ls -la /var/backups/bakery | tail -5
sudo tar -tzf "$(sudo ls -t /var/backups/bakery/*.tar.gz | head -1)" | head -20
# what listens where; files the apps wrote into their releases since they were deployed
sudo ss -ltnp
sudo find /opt/bakery/current/ /opt/magazine/current/ -type f -newermc /opt/magazine/current/server.js -not -path '*/.next/cache/*' | sed 's#/[^/]*$##' | sort | uniq -c | head
```

Then make a copy you can restore by hand whatever happens:

```sh
sudo tar -czf /root/pre-tando-$(date +%F).tar.gz /etc/caddy /etc/systemd/system/bakery.service \
  /etc/systemd/system/magazine*.{service,timer} /etc/bakery.env /etc/magazine.env /etc/cron.d /usr/local/bin/bakery-backup
sudo /usr/local/bin/bakery-backup
```

## Set up tando on the server

```sh
tando host add vps <you>@<server> --key ~/.ssh/<key>     # accept the host key by hand first: ssh <you>@<server>
tando host setup vps apps_domain=<a domain you own> tls=auto   # only matter for apps tando creates later
tando doctor vps
```

Without `apps_domain`, and only when the server has a public IPv4 address, `host setup` picks
`<ip-with-dashes>.sslip.io` with `tls=auto`. That is harmless for adopted apps (tando renders no
site for them), but public certificates are requested as soon as a tando-native app is created.

`host setup` installs `/opt/tando/bin/tando-agent` and its units, and changes `/etc/caddy/Caddyfile`
twice:
- it appends `import /etc/caddy/tando/*.caddy`;
- it moves Caddy's admin API to a socket: it puts `admin unix//run/caddy/admin.sock` into the global
  options block (adding one at the top if there is none), and hands the new config to the old
  admin address (`caddy reload --address localhost:2019`). Caddy moves its admin API without
  closing a connection. Only if that fails does setup **restart** Caddy, which drops the
  requests in flight for about a second.

Both changes are validated first (`caddy validate`); the previous file is put back if Caddy rejects
the new one. `adopt apply` and `adopt undo` never touch the Caddyfile, and neither do deploys of
adopted apps; only `adopt site --apply` edits it, when you run it. Back
up the Caddyfile before `host setup` (the tar command above does), and check
`systemctl status caddy` afterwards.

## Adopt bakery

Pick a quiet time (not 02:30, when `bakery-backup` runs). Keep a second terminal running:

```sh
while :; do printf '%s %s\n' "$(date +%T)" "$(curl -s -o /dev/null -w '%{http_code} %{time_total}' https://example.com/bakery/order/new)"; sleep 0.5; done
```

1. Read the plan. It changes nothing.

   ```sh
   tando adopt plan bakery -H vps --health /order/new
   ```

   Check: port 3100, user bakery, data `/var/lib/bakery` with `BAKERY_DATA_DIR`, env file names
   (`COOKIE_SECURE, KITCHEN_PASSWORD, BAKERY_DATA_DIR, SESSION_SECRET` expected), the R1 risk line,
   "bakery-backup ... still covers /var/lib/bakery", the pre-flight port note (3200 is magazine's),
   `now: healthy through Caddy, static files included`. The plan blocks (with the exact fix) a unit
   file or drop-in that is not root-owned or sits in a directory others can write, an app user in a
   privileged group (sudo, adm, docker, ...), one that can log in with ssh keys, has a crontab, or is
   also the user of another unit or process. Anything under **blocked**, or a risk you
   did not expect: stop and compare with the replica.

   When the site does not hold requests while the app restarts, the plan has a section
   **request hold: missing**: what it costs (every request that arrives during the adoption and
   during every later deploy, rollback or restart fails with 502) and the command of step 2.

2. Add the request hold to your Caddy site, before anything is switched.

   ```sh
   tando adopt site bakery -H vps --health /order/new           # what it would add
   tando adopt site bakery -H vps --health /order/new --apply
   ```

   It adds `lb_try_duration 15s` and `lb_try_interval 100ms` to the `reverse_proxy` of the app's
   port, nothing else. The app must answer through Caddy first; the Caddyfile is validated before
   and after the edit, the previous file is kept as `/opt/tando/adopt/bakery/Caddyfile.<time>`
   (root only; there is no app directory or app backup yet, and the adoption record will live in
   the same place), Caddy is reloaded (not restarted) and the app is checked through it. Anything
   that fails puts the previous file back. This also helps a deploy with the old script. The
   request log is not added now: it needs the app's log directory, which adoption makes (step 5).

   A site it cannot edit with certainty (no `reverse_proxy` to the port in the Caddyfile itself,
   or more than one) is left alone and the two lines to add by hand are printed. Add them to each
   `reverse_proxy` of the port, `caddy validate`, `systemctl reload caddy`, and the plan stops
   reporting the hold as missing. If you would rather adopt without the hold, step 3 takes
   `--accept-502`.

3. Apply. Run it in the bakery source directory: it writes `tando.conf` there (or
   `tando.conf.adopted` if one exists).

   ```sh
   cd ~/github/ai-playground/bakery-preorder
   tando adopt apply bakery -H vps --health /order/new
   ```

   Without the hold it refuses before it changes anything and names step 2;
   `--accept-502` starts it anyway. Steps: check, backup, register (pre-flight of a copy of the
   live release in tando's sandbox on port 4100), switch (the restart), jobs, verify. A dropped
   ssh connection does not stop it (`tando adopt status bakery -H vps` re-attaches). Any failure
   after the backup returns everything to the recorded state and says so. `apply` does not edit
   the Caddyfile: the state `adopt undo` returns to is the one `apply` found, with the hold of
   step 2.

4. Fix the build line in `tando.conf` before the first deploy (tando cannot know it). For bakery,
   the same build `deploy-vps.sh` does, including the precompressed files Caddy serves:

   ```
   build = NEXT_STANDALONE=1 NEXT_TELEMETRY_DISABLED=1 npm run build && find .next/static -type f \( -name '*.js' -o -name '*.css' -o -name '*.svg' -o -name '*.json' -o -name '*.txt' \) -exec sh -c 'for f; do zstd -q -19 -f "$f" -o "$f.zst" && gzip -k -9 -f "$f" && brotli -k -f -q 11 "$f"; done' _ {} +
   ```

   tando replaces the macOS `sharp` packages with the server's (linux-x64) itself.

5. Add the request log to the site, now that the app has a log directory:
   `tando adopt site bakery -H vps --apply` (this copy of the Caddyfile goes to
   `/var/backups/tando/bakery/`). `tando requests`, `tando errors` and the 5xx alert read it.

6. Retire `scripts/deploy-vps.sh` (it would stop at its first step anyway). Deploy with
   `tando deploy`; roll back with `tando rollback`.

### Verify

```sh
tando status bakery -H vps                     # running, release verified, memory against 650M
systemctl show -P User,MainPID tando-bakery; systemctl is-enabled bakery     # bakery / disabled
curl -sI https://example.com/bakery/order/new | head -1
curl -s https://example.com/bakery | grep -o '/bakery/_next/static/[^"]*\.css' | head -1 | xargs -I{} curl -s -o /dev/null -w '%{http_code}\n' https://example.com{}
sudo -u bakery test -w /var/lib/bakery && echo data writable
sudo /usr/local/bin/bakery-backup && sudo tar -tzf /var/backups/bakery/bakery-$(date +%F).tar.gz | grep db.json
tando logs -a bakery -H vps -n 30
```

Place a test order you can delete (or watch the kitchen page) and check it is in `db.json`.

## Adopt magazine

Same steps, with its health path (whatever `remote.sh` checks; the replica uses `/api/health`):

```sh
cd <magazine source>
tando adopt plan magazine -H vps --health /api/health
tando adopt site magazine -H vps --health /api/health --apply    # the request hold, first
tando adopt apply magazine -H vps --health /api/health
tando jobs -a magazine -H vps                  # six jobs, next runs at the same times as before
systemctl list-timers --all | grep magazine    # tando-magazine_job-* active, magazine-* inactive
```

**Expect one shifted interval at each handover, not a doubled or missed run.** systemd fires an
`OnCalendar` timer somewhere in `[elapse, elapse + AccuracySec)` (one minute by default), at a
fixed offset of its own. The hand-written `magazine-sync.timer` and `tando-magazine_job-sync.timer`
have different offsets (on the replica :25 and :00 past the minute), so around adopt or undo one
interval between two calls is shorter or longer than the schedule, for example 35 s or 85 s for the
every-minute job. If an elapse falls in the few seconds the timers are paused, it runs once at
resume time, which can add a second short interval. Every elapse still runs exactly once, never
before its scheduled time, and never twice. This is the same latitude the hand-written timers
always had, so no endpoint sees anything it could not see before (an endpoint that relied on calls
being exactly 60 s apart would already have been wrong). To check after adopting: the run times of
each job, `journalctl -u tando-magazine_job-sync.service -o short-iso | grep Starting`, show one
run per minute.

**A run that fires while the app restarts is lost, as it always was.** Each job is a `curl` to
127.0.0.1:3200; during a restart (tando deploy, rollback, restart, or a hand deploy before
adoption) the app refuses new connections, curl exits 7 and the run fails, with nothing retrying it.
On the replica this happened once in about 20 restarts. That restart was stretched to 20 s because
Next ignored SIGTERM (it closes its listener but keeps serving open keep-alive connections, so
visitors saw no extra errors, but a new connection from a job was refused). The fix belongs in the
job command, and works with the hand-written timers too: let curl wait for the app, for example
`curl -fsS --retry 10 --retry-connrefused --retry-delay 2 -m 120 ...`, then `tando up` to apply the
job lines from tando.conf. Adopt does not rewrite the commands itself.

In the plan, every timer row must say `yes`; one that says `no` stays a hand-written timer (it
keeps working: port and secret do not change). `--no-jobs` leaves all of them hand-written.
Check its build line in `tando.conf` against `remote.sh` (and `writable` must list
`.next/server/route-cache` if the plan found it). After the first tando deploy, watch the
regenerated pages: `tando logs -a magazine -H vps | grep -i EACCES` must stay empty.

## Undo

```sh
tando releases -a bakery -H vps            # the adopted release is the oldest tando one
tando rollback <adopted id> -a bakery -H vps   # only if tando deployed something since
tando adopt undo bakery -H vps
```

Undo refuses while a release other than the adopted one is live, so it never silently brings back
older code: roll back first, or redeploy the newer code with the old script after undoing. It
hands the timers back (restoring their stamps), points `/opt/bakery/current` back at the original
release, stops `tando-bakery`, starts and re-enables `bakery.service`, restores `incoming/`,
removes tando's unit files and `/opt/tando/apps/bakery`, checks health through Caddy and compares
the unit file, env file, Caddyfile, link, timers, cron, data directory and users with the record.
The data stays where it always was. The adopt backup stays in `/var/backups/tando/bakery/*-adopt`
(`data.tar.gz`, `config.tar.gz`, the record), root-only.

If tando itself is broken, the by-hand undo is: `sudo systemctl disable --now tando-bakery`,
`sudo ln -sfn <original release> /opt/bakery/current.tmp && sudo mv -T /opt/bakery/current.tmp /opt/bakery/current`,
`sudo systemctl enable --now bakery`, `sudo rm /opt/bakery/incoming && sudo mv /opt/bakery/incoming.pre-tando /opt/bakery/incoming`.
The original release path is `f.link_target` in `/opt/tando/adopt/bakery/record`.

## Rehearsal results (replica)

The rehearsal suite (`e2e-adopt`, about 8 minutes; it rebuilds the replica first) is kept outside this repository. Each run gets its own work directory (`T_WORK`); `TANDO_TEST_NAME` with `REPLICA_SSH_PORT` and `REPLICA_HTTPS_PORT` points it at another replica container; two runs on one replica are refused.

Five full rehearsals, each on a freshly built replica: bakery adopted, the old deploy script tried
(stopped at its first step), v2 deployed with tando, rolled back, adoption undone, adopted again; then
the same for magazine with its timers firing throughout. A request loop ran the whole time (about 10
GETs per second over both apps: pages, a hashed CSS file, a photo, an image-optimiser URL, ISR page,
health) plus one real order per second to bakery (every fifth with a proof photo).

| | run 1 | run 2 | run 3 | run 4 | run 5 |
|---|---|---|---|---|---|
| checks | 42/46 (test bugs) | 45/46 (timer bug) | 46/46 | 46/46 | 46/46 |
| orders acknowledged / lost / doubled | 397 / 0 / 0 | 484 / 0 / 0 | 401 / 0 / 0 | 401 / 0 / 0 | 412 / 0 / 0 |
| orders that got a 502 (not stored, the shop shows an error) | 0 | 1 | 2 | 1 | 1 |
| undo identical to the snapshot before adoption | yes, both | yes, both | yes, both | yes, both | yes, both |
| minute and 2-minute timers: runs doubled / missed | 0 / 0 | 0 / **1** | 0 / 0 | 0 / 0 | 0 / 0 |
| (checked per elapse slot; one or two phase-shift intervals per handover are expected) | | | | | |
| bakery adopt: failed requests, longest stall | 10, 266 ms | 8, 347 ms | 28, 419 ms | 12, 312 ms | 14, 242 ms |
| bakery tando deploy | 10, 420 ms | 11, 267 ms | 8, 284 ms | 8, 340 ms | 8, 275 ms |
| bakery rollback | 8, 332 ms | 8, 280 ms | 8, 479 ms | 12, 282 ms | 8, 283 ms |
| bakery undo | 15, 317 ms | 16, 368 ms | 28, 463 ms | 16, 341 ms | 12, 466 ms |
| magazine adopt | 6, 453 ms | 7, 415 ms | 21, 983 ms | 9, 597 ms | 9, 585 ms |
| magazine deploy / rollback | 8 / 9 | 9 / 6 | 6 / 6 | 6 / 6 | 6 / 6 |
| magazine undo | 12, 663 ms | 12, 711 ms | 21, 1007 ms | 9, 568 ms | 9, 571 ms |

Every failed request is an HTTP 502 from Caddy during one restart (the deliberate R1 test adds about
15 HTTP 403s, not counted above). "Stop to healthy" for adopt was 0.6 to 1.3 s. Run 2 lost one
`sync` run: the timers were then handed over after the restart, and one fired into it (fixed: timers
now pause before the switch). Run 3 had longer gaps from a 0.5 s polling interval in the new bounded
stop (fixed in runs 4 and 5).

**The request hold (now step 2, before adoption):** the 502s in the table above come from the
hand-written block, which did not hold requests while the app restarted (tando-rendered sites do).
The rehearsals ran before `adopt site` existed. `tando adopt site <unit> --apply` adds the hold
before adoption (and the request log after it); by hand it is two lines in each `reverse_proxy`
block of the Caddyfile:

```
reverse_proxy 127.0.0.1:3100 {
	lb_try_duration 15s
	lb_try_interval 100ms
	...
}
```

Measured on the replica with both apps adopted: tando deploy, rollback and restart of each app, about
2,500 requests and 72 orders, **0 failed**; the longest stall was 0.65 s (requests held, then served).
Validate (`caddy validate`) and `systemctl reload caddy` (no restart). This also helps any future
deploy, with tando or by hand.

## What only the real server can confirm

- x86-64 and the real sharp `linux-x64` binary under tando's sandbox (`PrivateDevices`,
  `SocketBindDeny`): the replica is arm64 because OrbStack's x86 emulation was not usable.
- The restart gap on a 1-vCPU x86 VPS with the real data size (the replica measured it on one
  core of an M1 Pro); expect it to be the app's start time, see `Ready in` in `journalctl -u bakery`.
- Real TLS: the replica uses Caddy's local CA (`local_certs`); the real site has public certificates.
  Adopt never touches the site block, and tando checks health with `--resolve <site>:443:127.0.0.1`.
- magazine's real `remote.sh`, its release ownership, its data and its six timers (the replica's
  are stand-ins: names, schedules and `${CRON_SECRET}` usage are guesses).
- How `bakery-backup` is triggered (the replica assumes `/etc/cron.d/bakery-backup` at 02:30) and
  whether anything else (monitoring, a cron job) calls `systemctl ... bakery`: the plan lists cron
  entries and scripts that mention the app, but not monitoring outside the server.
- That `BAKERY_DATA_DIR=/var/lib/bakery` is set in `/etc/bakery.env` (assumed; PRODUCTION.md says
  the data lives there and the unit does not set it). The plan shows which variable points at the
  data directory; if none does, it says so.
- Ubuntu 26.04 mixes coreutils: `mkdir` is the Rust uutils one (its messages differ from GNU's),
  `cp` is GNU. The replica has the same mix, so the scripts were tested against it.
- Memory: the replica's apps are small; the real bakery is about 230 MB. The new unit keeps
  `MemoryMax=650M` and `MemoryHigh=450M` and adds `MALLOC_ARENA_MAX=2` (less memory, not more).

## Assumptions about the real server (check with the commands above)

| Assumption | Source | Check |
|---|---|---|
| `bakery.service` is exactly `deploy/bakery.service` from the repo | PRODUCTION.md | `systemctl cat bakery` |
| `/opt/bakery/current` is an absolute symlink to `/opt/bakery/releases/<YYYYMMDD-HHMMSS>`, releases `root:root`, `.next/cache` owned by bakery | deploy-vps.sh | `ls -la /opt/bakery/releases/*/.next` |
| `/etc/bakery.env` is `root:root 600` and holds `KITCHEN_PASSWORD`, `SESSION_SECRET`, `COOKIE_SECURE`, `BAKERY_DATA_DIR` | PRODUCTION.md (+ the data-dir variable assumed) | `sudo stat`, the names command above |
| `/var/lib/bakery` is `bakery:bakery 750` with `db.json`, `db.json.bak`, `uploads/` | PRODUCTION.md, lib/db.ts | `sudo stat`, `sudo ls /var/lib/bakery` |
| `bakery-backup` runs from `/etc/cron.d` daily and writes `/var/backups/bakery/bakery-YYYY-MM-DD.tar.gz` of `-C /var/lib bakery` | deploy-vps.sh (file name), trigger guessed | `sudo cat /usr/local/bin/bakery-backup`, cron grep |
| The Caddyfile is `deploy/Caddyfile` plus a `handle /magazine*` block proxying to 3200 in the same site | owner's notes; magazine block guessed | `sudo cat /etc/caddy/Caddyfile` |
| magazine: `/opt/magazine/{current,releases,incoming}`, user `magazine`, `/etc/magazine.env` with `CRON_SECRET`, releases owned by magazine, `basePath /magazine` | owner's notes; rest guessed | `systemctl cat magazine`, `ls -la /opt/magazine` |
| Six timers `magazine-<job>.timer`, each a `curl -H "Authorization: Bearer ${CRON_SECRET}" http://127.0.0.1:3200/...` with `EnvironmentFile=/etc/magazine.env`, default AccuracySec | owner's notes; form guessed | `systemctl cat 'magazine*'` |
| No drop-ins, no other unit or script runs `systemctl restart bakery` except deploy-vps.sh | guessed | `systemctl cat`, `grep -r 'systemctl.*bakery' /usr/local/bin /etc/cron*` |

## On the real server (19 Nov 2026)

bakery, with real orders, on a 1-vCPU x86-64 server (Ubuntu 26.04, Caddy 2.6.2, Node 24). A
loop on the laptop asked for five pages, a hashed CSS file, a photo and an optimised image about
twice a second through the public address for 28 minutes: 16,569 requests.

| Step | Time | Failed requests |
|---|---|---|
| `adopt apply` | 64 s in all, about 2 s without the app | 16 (HTTP 502), dynamic pages only |
| first `tando deploy` | 69 s, about 3 s without the app | 20 (HTTP 502) |
| after `lb_try_duration 15s` in the site block: rollback (4 s), three deploys (58 to 72 s) | | 0; slowest answer 3.8 s |
| `host setup` three times over the running install | 44 to 54 s | 0 |
| a release with a wrong start command | refused at pre-flight | 0 |
| hard kill of the app (after the fix below) | back in 3 s | 0; slowest answer 4.0 s |
| `ab`, 20 at once, 12,000 requests over four URLs | | 0 |

The order file had the same digest before and after, and tando's pre-deploy backup held the
same file and every upload. The owner's nightly backup ran unchanged.

Four bugs, found here and not on the replica, all fixed:

1. **A refused release changed how the live one starts.** The deploy with the wrong start
   command was refused, correctly, but its `start` line stayed in `app.conf`. The live app kept
   running until it was killed (the next test); then systemd started it with the wrong command,
   five times, and gave up. The pages answered 502 for about 50 s until the line was put back by
   hand. Now each release keeps its own start command (`/opt/tando/apps/<app>/start/<id>`), as it
   already kept its own jobs. Test: e2e 3g, 3h.
2. **The monitor probed an address that does not exist.** For an adopted app, `tandod` asked
   `<app>.<apps_domain>` instead of the app's real site, so it reported the app unhealthy
   (TLS error) while it was serving. It did not restart it: before a restart it asks the app's
   port directly. The health probe, the certificate check and host care's check after a reboot
   now use the adopted site's address.
3. **The plan said there was no backup.** It looked for the owner's backup script in cron only;
   this server runs it from a systemd timer. Timers are read too now, and such a timer is never
   turned into a tando job.
4. **No request log for an adopted app.** `tando requests`, the HTTP part of `tando errors` and
   the 5xx alert read `/var/log/tando/<app>/access.log`, which only a tando-rendered site writes.
   The directory is now prepared for adopted apps, and the block to paste into your own site is
   printed by `sudo /opt/tando/bin/tando-logs caddy-log <app>` on the server. Validate, then
   `systemctl reload caddy`.

Also seen then, and changed in 0.1.1:

- Adopt left the hold and the request log to the owner. `tando adopt site <app>` now shows what the
  hand-written site lacks and `--apply` adds it (copy, validate, reload, check, and the previous
  file back on failure). `adopt apply` ends with the same list.
- In 0.1.1 `adopt site` still refused an app that was not adopted yet, so the hold could only be
  added after the 36 failed requests above. Since then `adopt site <unit> --apply` adds the hold
  before adoption, `adopt plan` reports a missing hold with its cost, and `adopt apply` refuses
  to start without it unless `--accept-502` is given.
- The image cache was empty after adopt and after every deploy, and nothing checked the image
  optimiser (the old deploy script did both). The pre-flight of a Next.js release now loads
  `sharp` as the app's user and requests the optimised images of the health page and the start
  page on the spare port: a `sharp` binary for the wrong platform fails the deploy before the
  switch, and the cache is warm at the switch.
- A refused release also left its `health` path in the app's settings. Start command, health path
  and expected answer go back to the live release's when a release is refused before the switch.
- `tando backup ls` now lists the adopt backup (kind `adopt`, never pruned, restorable).
- A failed build prints whole lines, wrapped, and keeps all of its output in `.tando/build.log`.
- A false alarm can be dropped from the uptime record: `tando health <app> --forget N`.

Still open: `path`, `recipe` and `writable` of a refused release are applied to the live app's unit
and site when the deploy starts (as `memory` is, by design). Change those in a deploy of their own.
