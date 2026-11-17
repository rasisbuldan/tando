# tando usability review

14 Nov 2026. An adversarial review of a newcomer's first hour and their second day. I tested a
copy of `bin/`, `lib/`, `server/`, `examples/` and `VERSION` (0.1.0) in `test/.work-ux/tree`
against the test container `tando-test-ux` (ssh 2330, http 8330), with `NO_COLOR=1` and
`COLUMNS=80` unless a width is stated. I read only README.md before the journeys and the other
docs afterwards. The raw captures are in `test/.work-ux/out/`.

The standard I applied: tando should feel as simple as Vercel or Heroku for a prototype and as
complete as Kamal or Dokku on a small server. "Works if you know the trick" counts as a defect.

---

## Executive summary: the 10 changes that would most improve the first hour

1. **`--help` must never run the command.** `tando stop --help` stops the production app (the
   link returns 503), `tando up --help` creates and deploys whatever is in the current directory,
   and `tando deploy -h` deploys. Add `tando help <cmd>` and `<cmd> --help` with per-command
   usage, and treat any unknown flag as an error (F-01, F-02, F-20).
2. **`host setup` should prepare a fresh Ubuntu box, and the README should cover DNS.** Setup
   assumes Caddy and Node are already installed, and with no Caddy it fails with
   `Job for caddy.service failed`. Nothing in README.md or docs/ says you need a wildcard DNS
   record (`*.apps.example.com → server IP`) or open ports 80 and 443. A newcomer with a new VPS
   cannot get a link to work (F-03, F-04).
3. **Install Node dependencies, or say clearly that you don't.** A plain Express app (the most
   common Node app there is) fails pre-flight with `MODULE_NOT_FOUND`, because tando neither runs
   `npm ci` nor warns that `node_modules` is missing (F-05).
4. **Turn every ssh and sudo failure into one tando sentence with a next step.** The user currently
   sees raw `ssh:`, `bash: line 1: /opt/tando/bin/tando-agent: No such file or directory`,
   `sudo: a password is required` and `mux_client_request_session` lines, unboxed. `doctor` shows
   all green for a login without sudo (F-07 to F-11).
5. **Write `host = <name>` into tando.conf at init, and list the hosts when it is missing.**
   Registering a second host silently breaks every existing project directory with
   `no host: use -H <host> or set host in tando.conf` (F-12).
6. **One command applies config and code.** `deploy` silently ignores edits to tando.conf (I
   changed memory from 256M to 128M and status still said 256 MB). Either `deploy` applies changed
   settings or it refuses with "tando.conf changed (memory): run tando up" (F-14).
7. **Explain the three classic crashes in plain words.** For a hard-coded port (`EPERM listen 3000`),
   a write into the read-only release (`EROFS`) and a missing module, the pre-flight box should say
   what happened and what to change, and lead with the first error line, not the tail of a stack
   trace and systemd noise (F-16, F-17, F-18).
8. **Make the Next.js path one step.** tando warns about `output: 'standalone'`, then builds anyway
   and fails after the build. It should stop before building and offer to add the line itself, or
   build standalone without the config edit. This is the owner's main stack (F-19).
9. **Pick one clock and fit the link at 80 columns.** Release ids are UTC (`20261113-171442`) while
   the WHEN column for the same deploy is local (`11-14 00:14`), so one event shows two different
   dates. At 80 columns `ls` cuts the link, the most useful thing it shows, to `http://hello-no…`
   (F-24, F-25).
10. **Add `--json` and quiet the noise.** No view has machine-readable output, so piped output is
    box-drawing characters. `tando logs` mixes systemd lifecycle lines with app output, and each line
    is over 80 columns. Empty views print a bare header row with no hint of what to do next
    (F-28, F-29, F-33).

**Counts by severity:** 4 blocker, 29 major, 22 minor, 8 polish (63 findings).

---

## How long things took (wall clock, my measurements)

| Journey | Commands | Edits / decisions | Look-ups | Time |
|---|---|---|---|---|
| Host: `host add`, `host setup` | 2 (+1 to put tando on PATH) | apps_domain, tls, public_port | test README for port and `--insecure-test` | ~2 s run time |
| Plain Node server (no deps) | 1 `up` | 0 | 0 | 1.8 s |
| Static folder | 1 `up` | 0 | 0 | 0.8 s |
| Node + Express (deps) | `up` (fails) → `npm install` → `up` | had to guess the cause from `MODULE_NOT_FOUND` | no doc says deps are not installed | ~2 s + npm |
| Next.js (create-next-app defaults) | `up` (fails after a 6 s build) → edit next.config.ts → `up` | 1 file edit | the warning printed it | 7 s + 11 s |
| Python (`main.py`) | `up` (fails) → `host setup vps python=yes` → `up` | 1 | 0 | 24 s setup (no progress shown) + 3 s |
| Dockerfile only | `up` (fails) → `host setup vps podman=yes` → `up` | 1 | 0 | 42 s setup (silent) + 6 s |
| Database + data + job | edit tando.conf (3 keys from README) → `up` (fails) → `host setup vps postgres=yes` → `up` | 3 keys | README tando.conf block | 52 s |

---

## Step-count comparison (zero to a live link, first app on a new server)

| Step | tando | Vercel | Heroku | Kamal 2 | Dokku |
|---|---|---|---|---|---|
| Install CLI | clone + PATH (install.sh exists, README does not mention it) | `npm i -g vercel` | installer | `gem install kamal` | bootstrap script on the server |
| Account / server prep | **install Caddy and Node by hand; passwordless sudo; DNS wildcard (undocumented)** | `vercel login` | `heroku login` | Docker is installed by `kamal setup`; registry account | bootstrap installs everything; DNS documented |
| Register target | `host add` + accept host key by hand with ssh | – | `heroku create` | edit `config/deploy.yml` (servers, image, registry) | `dokku apps:create`, `git remote add` |
| Prepare server | `host setup` (+ `python=yes` / `podman=yes` / `postgres=yes` discovered by failing) | – | – | `kamal setup` | – |
| Config file | written by `up` | none / auto | none (Procfile optional) | `deploy.yml`, `.kamal/secrets` | none |
| Deps install | **not done for node** | automatic | automatic (buildpack) | in the Dockerfile | automatic (buildpack) |
| Next.js | **edit next.config for standalone** | zero config | buildpack | your Dockerfile | buildpack |
| Deploy | `up` | `vercel` | `git push heroku main` | `kamal deploy` | `git push dokku main` |
| Commands after install, Node app with deps | **5 + 2 manual server installs + npm install** | 2 | 3 | 3 + YAML + Dockerfile | 3 (+ bootstrap) |

Where tando asks for more: preparing the server (Caddy, Node, sudo, DNS), installing dependencies,
the Next.js config edit, and finding out about host features (`python=yes`, `podman=yes`,
`postgres=yes`) by failing. Where tando already beats them: no registry, no Docker for Node and
static apps, two-second deploys, and an honest multi-step progress box. Once the server is ready,
redeploying a plain Node or static app takes one command and under two seconds, which is better
than any of the four.

---

## Findings

Format: **id · severity · journey**, then what I did, what I saw (exact output), what I expected,
and the fix.

### Journey 1: first contact

**F-01 · blocker · J1/J6. `--help` after a command runs the command.**
- Did: `tando stop --help` in an app directory; `tando up --help` in an empty directory;
  `tando deploy -h`.
- Saw:
  ```
  $ tando stop --help
  stop: hello-node
  [exit 0]                       (link now answers 503)
  $ tando up --help              (empty dir)
  tando: cannot tell what this is: no package.json, Node or Python entry file, Dockerfile or index.html (tando recipes lists what each recipe looks for)
  $ tando backup now --help -a mynext
  tando-agent: mynext has no data or database to back up
  ```
  In a project directory, `up --help` and `deploy -h` deploy.
- Expected: usage for that command and exit 0, with nothing executed.
- Fix: in `parse`, map `-h|--help` anywhere to `HELP=1`; `main` then prints `usage_<cmd>` and
  exits before `resolve`. Add `tando help <cmd>`.

**F-02 · major · J1. There is no per-command help, and the help that exists is spread across three formats.**
- Did: `tando help deploy`, `tando host --help`, `tando env --help`, `tando audit --help`, `tando alerts --help`.
- Saw: `help deploy` and `host --help` print the full 18-line usage and exit 1. `env --help` and
  `alerts --help` print `tando: no host: use -H <host> or set host in tando.conf`. `audit --help`
  prints `tando: bad app name: --help`. `top --help` prints its own one line and `ci --help` its own
  block, so each plugin does it differently.
- Expected: per-command help with a synopsis, a one-line description, the flags and one example.
- Fix, for example:
  ```
  $ tando help env
  tando env: the app's environment variables (stored on the server, 640, never in git)

    tando env ls                     list keys and values (values masked; --show to reveal)
    tando env set KEY=VALUE ...      set one or more; restarts the app once
    tando env set KEY                read the value from the terminal without echo (or stdin)
    tando env unset KEY ...          remove; restarts the app once
    tando env import [.env]          set every KEY=VALUE line of a file

  Set by tando, not editable: PORT, HOME, TANDO_DATA_DIR (and DATABASE_URL with database =).
  Example: tando env set STRIPE_KEY        (paste, Enter)
  ```

**F-06 · major · J1. An unknown command or a typo dumps the whole usage with no error line.**
- Did: `tando deplyo`, `tando staus`, `tando lgos`, `tando foo`.
- Saw: the same 18 lines starting `usage: tando <command> [-a app] [-H host]` and `[exit 1]`, with
  no "unknown command". This error usage also leaves out the 8 plugin lines that `tando help` shows.
- Expected:
  ```
  tando: unknown command "deplyo". Did you mean "deploy"?
  Run tando help for the list of commands.
  ```
- Fix: an edit-distance or prefix match against the known commands and the plugins; print the two
  lines above; exit 2 (usage error), not 1.

**F-21 · major · J1/J6. Global flags only work after the command, and `-a` with no value crashes.**
- Did: `tando -H strict ls`, `tando -a`, `tando ls -a`.
- Saw: `tando -H strict ls` prints the full usage. `tando -a` and `tando ls -a` print
  `/Users/…/bin/tando: line 52: $2: unbound variable`.
- Expected: `tando -H vps ls` works (git, kubectl and heroku accept global flags first), and a
  missing value gives `tando: -a needs an app name`.
- Fix: parse leading flags before taking the command; `${2:?}`-style checks with a message.

**F-37 · minor · J1. The help screen is hard to scan.**
- 12 of its 26 lines are wider than 80 columns, so they wrap in a default terminal. `releases` has
  no description. `version` is hidden inside the `recipes` line. Nothing tells a newcomer where to
  start.
- Fix: group the commands and keep every line under 80 columns:
  ```
  tando: deploy apps to your own server

  Start here
    tando host add vps admin@203.0.113.7     register a server
    tando host setup vps apps_domain=…       prepare it (once)
    cd my-app && tando up                    create, configure and deploy

  Deploy           up · deploy · rollback [id] · releases · history
  Run              status · logs [-f] · start · stop · restart · top
  Configure        env · jobs · db · backup
  Servers          host add|ls|setup|rm · doctor · ls --all
  More             destroy · unlock · recipes · version · ci · alerts · requests · audit

  tando help <command> for details. Flags: -a <app>, -H <host>, --json.
  ```

### Journey 2: zero to a live link

**F-03 · blocker · J2/J7. `host setup` does not prepare a fresh server, and the failure is opaque.**
- Did: removed `/usr/bin/caddy` in the container (a fresh Ubuntu has none) and ran `tando host setup vps`.
- Saw:
  ```
  ╭─ host setup vps ───────────────────────────────────────── vmadmin@127.0.0.1 ─╮
  │ ✓ 1/2  agent               /opt/tando/bin/tando-agent                        │
  Job for caddy.service failed.
  See "systemctl status caddy.service" and "journalctl -xeu caddy.service" for details.
  tando-agent: could not enable the recover unit or reload caddy
  [exit 1]
  ```
  The README says only "Server: Ubuntu with systemd, Caddy, curl, rsync, Node". It gives no
  commands to install them.
- Expected: `host setup` installs Caddy (official apt repository) and Node LTS when they are
  missing, as it already does for `python=yes`, `podman=yes` and `postgres=yes`. Or it stops before
  touching anything and says:
  `vps is missing caddy and node. Install them with: tando host setup vps --install (apt: caddy, nodejs 24)`.
- Fix: a pre-check step `0/3 prerequisites` that lists what is missing, plus an install option.
  Show progress for long apt runs (see F-22).

**F-04 · blocker · J7. DNS and firewall are documented nowhere.**
- Did: searched README.md, ARCHITECTURE.md, WHY.md and docs/ for DNS, wildcard and record.
- Saw: nothing that tells a user to create `*.apps.example.com A <server ip>` or to open 80 and 443.
  With `tls=auto` and no DNS, the deploy's "verify" step and the certificate fail in ways the README
  does not mention.
- Fix: a "Before you start" block in the README (see the draft below), and a `doctor` check that
  resolves `probe.<apps_domain>` and compares it with the server's address.

**F-05 · blocker · J2. Node dependencies are not installed, and the failure doesn't say so.**
- Did: an Express app (`package.json` with `"express"`, `index.js`), with no `node_modules`
  locally (a fresh clone), then `tando up`.
- Saw:
  ```
  │ pre-flight: the app exited (inactive; last: connection refused)              │
  │       at Object.<anonymous> (/opt/tando/apps/expressapp/releases/20261113-1… │
  │       at Module._compile (node:internal/modules/cjs/loader:1929:14) {        │
  │     code: 'MODULE_NOT_FOUND',                                                │
  ```
  It worked after a local `npm install`. Native modules built on macOS would still break.
- Expected: Heroku and Dokku run `npm ci`. Either tando does too (`build = npm ci --omit=dev` in the
  generated tando.conf, with the npm platform swap already used for Next), or `init`/`stage` refuses
  with: `package.json lists 1 dependency but node_modules is missing: run npm install (or npm ci) first`.
- Fix: `init` writes `build = npm ci && npm run build --if-present` when package.json has
  dependencies; stage checks that every top-level dependency exists in `node_modules`.

**F-19 · major · J2. Next.js: tando warns, builds anyway, then fails.**
- Did: `npx create-next-app@latest mynext --yes`, then `tando up`.
- Saw:
  ```
  next.js: add  output: 'standalone'  to next.config.ts (tando ships .next/standalone)
  wrote tando.conf (next)
  start runs without a shell (no pipes, &&, $VARS); set start_shell = true for sh -c
  created mynext on vps: user tando-mynext, port 4102
  ╭─ deploy mynext ──────────────────────────────────────────────────────── vps ─╮
  │ ✓ 1/7  build         6.3s  23 lines, ✓ Generating static pages using 5 work… │
  │ ✗ 2/7  stage                                                                 │
  │ no .next/standalone/server.js: set output: 'standalone' in next.config.ts    │
  ╰─ nothing was uploaded ───────────────────────────────────────────────────────╯
  mynext exists on vps but nothing is deployed: fix the problem and run tando up again (it resumes), or remove it with tando destroy
  ```
- Expected: one command. Two acceptable designs. (a) `init` asks
  `Add output: "standalone" to next.config.ts? [Y/n]` and edits the file (it is a one-line insert in
  the default template). (b) Stop before the build, with the one-line fix and no server-side app
  created.
- Fix: (a) when stdin is a tty, (b) otherwise. Never create the server app before the build has
  succeeded (see F-23).

**F-22 · major · J2. Missing host features are found by failing, and setup is silent for up to a minute.**
- Did: `tando up` for a Python app, then a Dockerfile app, then `database = postgres`.
- Saw: `tando-agent: no python3 with venv on this host: tando host setup <host> python=yes`. Then
  `host setup vps python=yes` ran for 24 s (podman 42 s, postgres 50 s) with no output, and finally
  printed the same box as before. The box mentions neither python nor podman. Postgres also leaked
  `/var/cache/debconf/tmp.ci/postgresql.config.dpGort: 12: pg_lsclusters: not found`.
- Expected:
  ```
  vps has no Python yet (needed by recipe python).
  Install it now? This runs apt on vps and takes about 30 s. [Y/n]
  ```
  In setup, a running step line `… 2/3  python  installing python3-venv (apt)` and a final box that
  lists the features: `features  node · python · podman · postgres`.
- Fix: substitute the real host name for `<host>`; drop the `tando-agent:` prefix (F-34); offer
  the install when interactive; send apt output to a log and show only the step.

**F-40 · minor · J2. The host setup summary leaves out what matters next.**
- Saw: `apps  *.localhost (tls off)` and the footer `ready: tando up`. Public port 8330 is not
  shown, no example link, no features.
- Fix:
  ```
  ╭─ host setup vps ───────────────────────────────────────── vmadmin@127.0.0.1 ─╮
  │ ✓ 1/3  prerequisites  caddy 2.10, node 24.22, rsync 3.4                      │
  │ ✓ 2/3  agent          0.1.0                                                  │
  │ ✓ 3/3  setup          recover unit, caddy import                             │
  │ links      http://<app>.localhost:8330   (tls off)                           │
  │ features   node · python · podman · postgres                                 │
  ╰─ next: cd your-app && tando up ──────────────────────────────────────────────╯
  ```

**F-41 · minor · J2. `init` accepts names the server rejects and changes names without saying so.**
- Did: `tando init` in a directory named `x`, and `tando up` in `My_Cool.App`.
- Saw: `x` wrote `app = x` (1 character; the README says at least 2) and exited 0. `My_Cool.App`
  became `my-coolapp` without a word.
- Fix: validate at init with `tando: "x" is too short for an app name (2-26 of a-z, 0-9, -): set app = … in tando.conf`;
  print `app name: my-coolapp (from directory My_Cool.App)`.

**F-42 · minor · J2. The generated tando.conf teaches nothing.**
- Saw: 5 bare lines (`app`, `recipe`, `start`, `health`, `memory`). To add data, a job or a
  database I had to go back to the README.
- Fix: append the common options, commented out:
  ```
  # data = data                      # persistent dir, survives deploys ($TANDO_DATA_DIR)
  # database = postgres              # or sqlite; app gets DATABASE_URL
  # job.nightly = daily | node scripts/nightly.js
  # path = /shop                     # serve under a sub-path
  # Change settings, then: tando up
  ```

**F-43 · polish · J2. Small noise in the deploy box.**
- `– 1/7  build` with an empty detail when nothing builds: should read `– 1/7  build   skipped (no build in tando.conf)`.
- `1 files changed`: should read `1 file changed`.
- `venv: 1.566s wall, 1.545s CPU, 96.1M peak memory` is indented under `upload` but happens during
  `copy`: give it its own step (`venv  1.6s  96 MB peak`).
- `start runs without a shell (no pipes, &&, $VARS); set start_shell = true for sh -c` is printed on
  every init, even for `node server.js`. Show it only when `start` contains a shell character.
- The release id line between steps 3 and 4 breaks the column. Move it to the box title:
  `deploy hello-node → 20261113-171442`.

**F-44 · minor · J2. `.tando/` is a 47 MB staging directory in the project, and git does not ignore it.**
- Saw: `.tando/` in the Next app was 47 MB. `git status` would list it and `git add .` would commit it.
- Fix: write `.tando/.gitignore` containing `*` when the directory is created.

### Journey 3: day two

**F-14 · major · J3. `deploy` silently ignores changed settings.**
- Did: changed `memory = 256M` to `128M`, ran `tando deploy`, then `tando status`.
- Saw: `memory ━─── 12 MB of 256 MB`. After `tando up`: `14 MB of 128 MB`. The README warns about
  this in one sentence, but the tool says nothing.
- Expected: either `deploy` applies settings (Kamal and Heroku apply config on every deploy), or it
  refuses:
  `tando.conf changed since the last tando up (memory 256M → 128M, job.report added). Run tando up to apply them, or tando deploy --code-only.`
- Fix: compare a checksum of the applied settings (returned by `configure`) with the local one;
  the simplest version is that `deploy` behaves like `up`.

**F-15 · major · J3. Deploying the same app name from another directory silently replaces it.**
- Did: copied hello-node's tando.conf into `hello-copy/` and ran `tando deploy` there.
- Saw: a normal `live in 1.3s  http://hello-node.localhost:8330`. hello-node now serves the other
  directory's code.
- Expected: something like Vercel's project link: `hello-node on vps was last deployed from ~/apps/hello-node (me@mbp). Deploy from ~/apps/hello-copy instead? [y/N]`.
- Fix: keep a random `project_id` in `.tando/project` (or the source path and host in app.conf)
  and warn on a mismatch; `--force` overrides it.

**F-26 · major · J3/J6. Destructive commands confirm inconsistently, and there is no `--yes`.**
- `destroy` asks for the app name. `backup restore` overwrites production data with no question
  (it does keep a safety backup, which is good). `rollback`, `stop` and `env unset` act at once.
  `destroy --yes` is silently ignored and then prompts, so it cannot be scripted.
- Fix: one rule. Commands that lose data (`destroy`, `backup restore`, `db reset`) ask
  `Type hello-node to confirm`, and `--yes` skips the question for scripts. Commands you can undo
  (`rollback`, `stop`) do not ask. Document the rule in `tando help`.

**F-30 · major · J3. `destroy` overstates what it removes and keeps, and the "final backup" is unreachable.**
- Did: `echo brk | tando destroy` on an app with no data or database.
- Saw: `This removes brk from vps: its unit, Caddy site, releases, data and database (a final backup is kept).`
  followed by `destroyed brk`. No backup was made, because there was nothing to back up. When an
  app does have a final backup, `tando backup ls -a <gone app>` answers `tando-agent: no such app`.
- Fix: list only what exists (`releases (3), env (2 keys), Caddy site`). Print the backup id and
  how to get it back: `final backup 20261113-…-final: tando backup pull … -a brk`. Make `backup ls`
  and `backup pull` work for destroyed apps.

**F-23 · major · J3. Apps that were never deployed look like stopped apps.**
- Saw: after a failed first `up`, `ls` shows `brk  ○ stopped  -  …  http://brk.loca…` with a link
  that does not work. After `destroy`, `tando deploy` in the same directory prints
  `tando-agent: no such app: brk` from inside a half-drawn deploy box.
- Fix: a separate state, `○ not deployed`. `deploy` for an unknown app should say
  `brk is not on vps (never created, or destroyed): run tando up`. Create the server-side app
  only after the build and stage succeed.

**F-27 · minor · J3. Rollback brands a healthy release "✗ bad".**
- Did: `tando rollback` from a healthy v2.
- Saw: `20261113-171442  ✗ bad` in red, for a release that passed every check. I then rolled
  forward to it with `tando rollback 20261113-171442`, which works.
- Fix: label it `↩ rolled back` (dim, not red) and keep `✗ bad`/`failed` for releases that failed a
  check. Make the rollback box show the move and the link:
  ```
  ╭─ rollback hello-node ─────────────────────────────────────────────── vps ─╮
  │ from     20261113-171442  (now ↩ rolled back; tando rollback <id> to return)│
  │ to       20261113-171103  ✓ verified, deployed 3 min ago                  │
  ╰─ live  http://hello-node.localhost:8330 ──────────────────────────────────╯
  ```

**F-45 · minor · J3. Job output cannot be seen.**
- Did: `job.report = *:0/1 | ./bin/report`. `tando jobs` showed `● ok  8s ago`. `tando logs`
  shows only the app unit.
- Fix: `tando jobs logs <name> [-n N]`, or `tando logs --job report`. Add the last exit code and
  duration to the jobs table.

**F-46 · minor · J3. Start, stop and restart messages are terse and say nothing about state.**
- Saw: `stop: hello-node` (printed twice in a row, even when already stopped), `start: hello-node`.
- Fix: `hello-node stopped. Visitors get 503 "hello-node is stopped". tando start brings it back.`
  When it is already stopped: `hello-node was already stopped`.

**F-47 · minor · J3. `env unset` of a missing key reports success and restarts the app.**
- Saw: `tando env unset ODD NOPE` printed `env updated, hello-node restarted`.
- Fix: `NOPE is not set; unset ODD; hello-node restarted`, and no restart when nothing changed.

**F-48 · polish · J3. `backup now` prints a bare id.**
- Saw: `backup 20261113-171815-manual`.
- Fix: `backed up hello-node: 20261113-171815-manual (2.3 KB, data + db)`.

### Journey 4: things going wrong

**F-07 · major · J4. Connection failures come back as raw ssh lines, outside any box.**
- Saw (wrong port, unknown host, wrong key, offline):
  ```
  ssh: connect to host 127.0.0.1 port 2399: Connection refused
  ssh: Could not resolve hostname no-such-host.invalid: nodename nor servname provided, or not known
  vmadmin@127.0.0.1: Permission denied (publickey).
  mux_client_request_session: read from master failed: Broken pipe
  Connection timed out during banner exchange           (after 43 s)
  ```
  `host setup` opens a box, closes it empty, then prints
  `tando: could not install the agent: ssh: connect to host … Connection refused ` (with a trailing
  space).
- Expected, for example:
  ```
  tando: cannot reach vps (vmadmin@127.0.0.1, port 2399): connection refused.
    Is sshd on that port? Check with: ssh -p 2399 vmadmin@127.0.0.1
    Change the port with: tando host add vps vmadmin@127.0.0.1 --port 22
  tando: vps refused the key ~/.ssh/wrongkey (Permission denied).
    Add its public key to ~/.ssh/authorized_keys on the server, or pass --key.
  ```
- Fix: one `ssh_fail` helper that classifies the ssh error (refused, resolve, timeout, publickey,
  host key) and prints two lines. `ConnectTimeout=5` plus a cap on mux retries, so going offline
  costs 5 s, not 43 s.

**F-08 · major · J4. An unknown host key gives a raw error, and the README's fix is "ssh by hand".**
- Saw: `No ED25519 host key is known for [127.0.0.1]:2330 and you have requested strict checking.` / `Host key verification failed.`
- Fix: `host add` connects once and shows the fingerprint:
  `vps presents ED25519 key SHA256:abc…. Trust it? [y/N]`, then writes it to tando's own
  known_hosts. `--insecure-test` then no longer needs to appear in the quick start.

**F-09 · major · J4 (security). The ControlMaster socket is shared between host entries, so key and host-key checks are skipped.**
- Did: registered `strict` (strict host-key checking) and `badkey` (a wrong key) for the same
  `vmadmin@127.0.0.1:2330` as the `--insecure-test` host `vps`.
- Saw: both worked fully (`host setup strict` and `doctor badkey` were green) for as long as `vps`'s
  master connection was alive (`ControlPersist=60`). After I closed the master: `Host key verification failed.`
  and `Permission denied (publickey).`
- Fix: include the host entry's name and key fingerprint in `ControlPath` (for example
  `cm/<name>-%C`).

**F-10 · major · J4. A login without passwordless sudo passes `doctor` and fails every deploy with a raw sudo line.**
- Saw: `doctor nosudo` printed `0 failed, 1 warnings`. Then:
  ```
  ╭─ deploy hello-node ───────────────────────────────────────────────── nosudo ─╮
  │ – 1/7  build                                                                 │
  │ ✓ 2/7  stage         0.0s  2 files                                           │
  sudo: a password is required
  ```
  (The box was never closed.)
- Fix: a `sudo` row in doctor (`sudo -n true`), and the message
  `nosudo@127.0.0.1 cannot use sudo without a password. tando needs it: on the server run  echo 'nosudo ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/tando`.

**F-11 · major · J4. A host that was never set up gives a bash error, and `doctor` fails the same way.**
- Saw (agent missing) from `doctor`, `deploy` and `ls`: `bash: line 1: /opt/tando/bin/tando-agent: No such file or directory`.
  `host ls` shows `✗ no bash: line 1:…`.
- Fix: `vps is reachable but not set up for tando yet: tando host setup vps`. `host ls` shows
  `○ not set up`. `doctor` should work on a bare host and list what setup would do.

**F-12 · major · J4. A second registered host breaks every existing project directory.**
- Did: `tando host add` a second host, then `tando deploy` and `tando status` in hello-node.
- Saw: `tando: no host: use -H <host> or set host in tando.conf`. The README quick start's
  `tando doctor` fails the same way.
- Fix: `init`/`up` write `host = vps` into tando.conf. When it is ambiguous:
  `tando: 2 hosts are registered (vps, staging). Add  host = vps  to tando.conf, or pass -H vps.`

**F-13 · major · J4. `host add` does not check anything, and there is no `host rm`.**
- Saw: `host add` with a wrong port, a wrong key or an unresolvable name answers
  `added host badport (vmadmin@127.0.0.1, port 2399, host key NOT checked)` with exit 0. Adding an
  existing name overwrites it silently. `tando host rm strict` prints the usage, so I removed the
  file by hand.
- Fix: `host add` runs one `ssh true` and reports what it found
  (`✓ connected · sudo ok · not set up yet → tando host setup vps`); `host rm <name>` and
  `host add --force` to replace an entry.

**F-16 · major · J4. A hard-coded port crashes with no explanation.**
- Did: `server.js` listening on 3000 and ignoring `PORT`.
- Saw:
  ```
  │ pre-flight: the app exited (inactive; last: connection refused)              │
  │     errno: -1,                                                               │
  │     syscall: 'listen',                                                       │
  │     address: '0.0.0.0',                                                      │
  │     port: 3000                                                               │
  ```
- Expected (Heroku's R10 error names the cause):
  `pre-flight: the app tried to listen on port 3000, but tando gives it PORT=4107 and blocks other ports. Listen on process.env.PORT.`
- Fix: match `EPERM`/`EACCES` with `listen` in the journal, or `SocketBindDeny` audit lines.

**F-17 · major · J4. Writing into the release directory crashes with `EROFS` and no hint.**
- Saw: `code: 'EROFS', syscall: 'open', path: './counter.json'`.
- Fix: `pre-flight: the app tried to write ./counter.json, but releases are read-only. Put files that change in a data dir: add  data = data  to tando.conf and write to $TANDO_DATA_DIR.`

**F-18 · major · J4. Crash output shows the wrong part of the log.**
- Did: `require('./config.json')` with no such file.
- Saw: the box shows the tail (`at Module._compile…`, `requireStack…`, `Node.js v24.22.3`, two
  `tando-brk-pre-…service: …` lines). The line that matters, `Error: Cannot find module './config.json'`,
  is cut. Long lines are truncated at 80 columns, not wrapped. `tando logs` afterwards shows
  `-- No entries --`, because the pre-flight unit is not in the app's log.
- Fix: show the first line matching `Error|Exception|Traceback|panic` plus up to 6 lines after it,
  wrapped, and drop systemd lines. End with `full output: tando logs --release 20261113-172110`,
  and include the pre-flight unit in `tando logs`.

**F-20 · major · J4/J6. Unknown flags are silently ignored.**
- Saw: `tando logs --grep listening` dumped every line. `tando logs -x` was accepted.
  `tando destroy --yes` still prompted. `tando history --watch 1` was accepted, although only
  `ls`/`status` document `--watch`.
- Fix: every command declares its flags; anything else gives
  `tando: logs does not take --grep (see tando help logs)` and exits 2.

**F-31 · major · J4. When Caddy is down, a good release waits a minute, is rolled back and marked bad.**
- Did: `systemctl stop caddy`, then `tando deploy`.
- Saw:
  ```
  │ ✗ 7/7  verify          1m  0s                                                │
  │ after the switch: no healthy answer within -H s (last: connection refused);… │
  │   tando-hello-node.service: Deactivated successfully.                        │
  ...
  ╰─ release 20261113-172142: rolled back to the last good release ──────────────╯
  ```
  Note the literal `-H s` (a formatting bug) and `1m  0s`. Meanwhile `ls` and `status` showed every
  app as `● running`.
- Fix: pre-flight checks `systemctl is-active caddy` and stops with
  `Caddy is not running on vps, so no app is reachable. Start it: ssh vps sudo systemctl start caddy (tando doctor shows why it stopped).`
  `ls` gets a header warning `✗ caddy stopped: apps unreachable`.

**F-32 · major · J4. A full disk reads as an rsync I/O error with the cause cut off.**
- Did: a 2 MB tmpfs on the app's `incoming/`, then a 4 MB file.
- Saw:
  ```
  │ ✗ 3/7  upload                                                                │
  │   rsync: [receiver] write failed on "/opt/tando/apps/brk/incoming/big.bin":… │
  │   rsync error: error in file IO (code 11) at receiver.c(488) [receiver=3.4.… │
  │   rsync(77473): error: unexpected end of file                                │
  ╰──────────────────────────────────────────────────────────────────────────────╯
  ```
- Fix: detect `No space left on device`:
  `upload: vps ran out of disk space (big.bin, 3.8 MB). Free space: tando doctor. Large files: add them to .tandoignore.`
  Also compare the free space with the upload size during `begin`. (A `.tandoignore` is also
  missing: today only `.git`, `.DS_Store` and `.env*` are left out.)

**F-33 · minor · J4. An error in the middle of a box leaves the box open.**
- Seen with `host setup vps tls=bogus` (`│ ✓ 1/2  agent …` then `tando-agent: bad setting: tls=bogus`),
  the lease conflict, no sudo, Ctrl-C during the build, and `deploy` after `destroy`.
- Fix: `die` and the INT trap close the open box with the message in the footer:
  `╰─ ✗ stopped: another deploy is uploading (started 0s ago by me@mbp) ─╯`.

**F-34 · minor · J4. Internal names leak into user messages.**
- Messages start with `tando-agent:` and contain placeholders such as `tando host setup <host> python=yes`.
- Fix: print as `tando:` and fill in the host's name.

**F-35 · minor · J4. The Ctrl-C messages are incomplete.**
- During the build: the box is left at `╭─ deploy mynext …` and `^C`, exit 130, and nothing says
  nothing was uploaded. After the upload:
  `detached: release 20261113-172320 keeps activating on the server (tando releases)`. That is good,
  but `tando status --watch 2` is the better pointer, and `status` meanwhile shows `● deploying` (good).
- Fix: `cancelled during build; nothing was uploaded` and close the box.

**F-36 · polish · J4. The concurrent deploy message is good but gives no next step.**
- Saw: `tando-agent: another deploy is uploading (started 0s ago by me@my-MacBook-Pro)`.
- Fix: add `Wait for it, or if that terminal is gone: tando unlock`.

**F-38 · minor · J4. The `.env` file is skipped without a word.**
- Did: `.env` with `GREETING=from-dotenv` in the project, then `tando deploy`.
- Saw: the deploy succeeded and the app did not get the variable. No message.
- Fix: `.env not uploaded (secrets stay off the release). To use it on the server: tando env import .env`.
  Add `env import`.

**F-39 · minor · J4. An unknown `recipe` passes the client and fails confusingly.**
- Saw: `recipe = nodejs` opened the deploy box, `✓ 2/7  stage  0.1s  0 files`, then `tando-agent: no such app: shop`.
- Fix: validate `recipe` in `conf_load`: `tando.conf:2: recipe must be node, next, static, python or container (got "nodejs")`.

**F-49 · polish · J4. A first-deploy failure says "the running app was not touched" when nothing is running.**
- Fix: `nothing is live yet` for first deploys.

**F-50 · polish · J4. A health-check failure shows systemd lines, not the response.**
- Saw: `pre-flight: health check answered HTTP 500 for 10 s` followed by `Started tando-brk-pre-…service - [systemd-run] /opt/tando/…`.
- Fix: show the first 200 bytes of the body (`boom`) and add `health = / in tando.conf; point it at a route that returns 200`.

**F-51 · polish · J4. The no-tando.conf messages could carry the fix.**
- `deploy` says `no tando.conf here`; `status` says `no app: run in a directory with tando.conf, or use -a <app>` (good).
- Fix: also search parent directories (like git) and say
  `no tando.conf in ~/apps or its parents. Run tando up here to create one, or use -a <app>.`

**F-52 · minor · J4. `-a` with a misspelled app gives no list.**
- Saw: `tando status -a nope` → `tando-agent: no such app: nope`.
- Fix: `no app "nope" on vps. Apps: brk, dockapp, expressapp, … (tando ls)`.

### Journey 5: boxed views

**F-25 · major · J5. At 80 columns `ls` truncates the two columns that identify things.**
- Saw (80 columns):
  ```
  │ APP         STATE      RELEASE         MEMORY  CPU      UP  LINK             │
  │ hello-node  ● running  20261113-1714…   12 MB   0%      0s  http://hello-no… │
  │ mysite      ● running  20261113-1711…       -   0%      0s  http://mysite.l… │
  ```
  At 60 columns: `2026111…` and `http://he…`.
- After (80 columns): drop `http://` and the shared domain, which goes in the header, and show the
  release as its age:
  ```
  ╭─ tando ls · vps ────────────────────── apps at *.localhost:8330 (http) ─╮
  │ load 1.67 ━──  mem 2.3/16 GB ━──  disk 26/142 GB ━──  up 3h 31m         │
  ├─────────────────────────────────────────────────────────────────────────┤
  │ APP         STATE        DEPLOYED   MEMORY       CPU   UP      LINK      │
  │ guestbook   ● running    6m ago      13 MB/256   0%    1m 8s   guestbook │
  │ hello-node  ● running    just now    12 MB/256   0%    0s      hello-node│
  │ mysite      ● static     12m ago         -        -    -       mysite    │
  │ writer      ○ not deployed  -            -        -    -       -         │
  ╰─ 4 apps · tando status <app> for details · 00:14:45 ────────────────────╯
  ```
  (A full release id belongs in `status`/`releases`; `ls` answers "is it up, and where?")

**F-24 · major · J5. Times are shown in mixed zones and formats.**
- Same deploy: release `20261113-171442` (UTC), history `11-14 00:14` (local, UTC+7), logs
  `2026-11-13T17:14:45+00:00`, backups `6s ago`, jobs NEXT `11-14 00:19`, top `5m 14s ago`, footer
  clock `00:14:45`.
- Fix: one rule. Absolute times are local in `MM-DD HH:MM`. Relative times (`6m ago`) are used in
  lists. Release ids stay UTC but are labelled as such, or become local too. Log timestamps are
  local `HH:MM:SS` by default, with `--utc`.

**F-28 · major · J5/J6. No machine-readable output.**
- Saw: piping `tando ls > f` writes the box-drawing characters (colour does turn off, which is
  good). No `--json` exists in the core commands; only `logs` in the logx plugin has it. The
  `TANDO_ASCII`, `TANDO_COLOR` and `TANDO_PLAIN` variables are undocumented in the README.
- Fix: `--json` on `ls`, `status`, `releases`, `history`, `env ls` (keys only), `backup ls`,
  `jobs` and `host ls`. A non-tty without `--json` prints plain aligned columns with no borders,
  like `kubectl`/`docker ps`.

**F-29 · minor · J5. `tando logs` is noisy and wide.**
- Saw: `2026-11-13T17:14:45+00:00 tando-test-ux systemd[1]: Stopping tando-hello-node.service - tando app hello-node...`.
  4 of the 5 default lines were systemd lifecycle lines. Each line repeats the host name and is
  over 80 columns.
- After:
  ```
  00:14:45  ── restarted (env set) ──
  00:14:45  listening on 4100
  ```
  App output by default; `--system` for the unit lines; local `HH:MM:SS`.

**F-53 · minor · J5. Empty states have no next step.**
- Saw: `host ls` with no hosts shows only the header. `jobs` with none shows
  `│ JOB  SCHEDULE  NEXT  LAST  RESULT  COMMAND │`. `backup ls` for an app without data shows an
  empty table, while `backup now` says `hello-node has no data or database to back up`.
  `env ls` with no keys shows the bare header.
- Fix, for example:
  ```
  ╭─ hosts ─────────────────────────────────────────────────────────────────╮
  │ No servers yet. Add one:  tando host add vps admin@203.0.113.7          │
  ╰─────────────────────────────────────────────────────────────────────────╯
  ╭─ jobs hello-node ───────────────────────────────────────────────── vps ─╮
  │ No jobs. Add a line to tando.conf, then tando up:                       │
  │   job.nightly = daily | node scripts/nightly.js                         │
  ╰─────────────────────────────────────────────────────────────────────────╯
  ╭─ backups hello-node ────────────────────────────────────────────── vps ─╮
  │ Nothing to back up: hello-node has no data dir or database.             │
  ╰─────────────────────────────────────────────────────────────────────────╯
  ```

**F-54 · minor · J5. Units, badges and columns differ between views.**
- Memory: `12 MB` (ls), `12 MB of 256 MB` (status), `12/256M` (top), `960 KB` (ls) next to `0/256M`
  (top) for the same container.
- A static app's UP is `0s` in ls and `-` in top. Its STATE is `● running`, although nothing runs.
- Results: `● ok`, `✓ verified`, `✗ failed`, `✗ bad`, `● rolled-back`. Columns: `RESULT` (history)
  and `STATUS` (releases) for the same concept.
- Fix: one table of states and badges:
  `running ●`, `stopped ○`, `deploying ◐`, `failed ✗`, `static ◆`, `not deployed ·`; release
  `✓ verified`, `✗ failed`, `↩ rolled back`; deploy result the same three words. Memory is always
  `12 MB / 256 MB`, shortened to `12/256 MB` when narrow.

**F-55 · minor · J5. History at 60 columns keeps the wrong columns.**
- Saw: `│ 11-14 …  202611…  deploy   ● rolle…  1m 0s   0.6    60.1 │`. The per-phase seconds survive
  while WHEN, RELEASE and RESULT are cut.
- Fix: drop priority UPLOAD, PRE, VERIFY first, then RELEASE; never truncate RESULT or WHEN.
  `host ls` at 60 columns drops TARGET, the one column you need, while it keeps the config path in
  the title: show `~/.config/tando` shortened, or move it to the footer.

**F-56 · minor · J5. Leaving `--watch` exits 130, and nothing on screen says how to leave.**
- Fix: a footer `every 1s · Ctrl-C to stop`, exit 0 on Ctrl-C in watch mode. `status | head` prints
  `ui.sh: line 233: printf: write error: Broken pipe`: ignore SIGPIPE in views.

**F-57 · minor · J5. `doctor` always warns about every static site.**
- Saw: `│ app mysite    ● warn  unit not running │` on every run (the static recipe has no unit).
  `doctor` therefore never comes back clean once a static site exists, which teaches users to
  ignore its warnings.
- Fix: skip the unit check for `recipe = static`, and check the Caddy site instead.

**F-58 · polish · J5. `top` details.**
- At 80×24 the detail pane is open by default and hides 4 of the 9 apps, with no `↓ 4 more`
  marker. At 120 columns the apps table drops RELEASE, UP and LINK although the detail pane repeats
  them only for the selected app. The confirm modal footer is cut: `y confirm · any other …`.
  `top` opens on the first app, not on the app of the current directory.
- Otherwise `top` is the most polished view in the tool (see "Already good").

**F-59 · polish · J5. Status view wording.**
- `current last good` reads as one phrase. Use `current · last good`, or just `● live`.
- `recent deploys` in status versus `history`: use one word (see F-60).

### Journey 6: vocabulary and consistency

**F-60 · major · J6. Several words for the same concept.**
- release / deploy / version: `releases` lists releases, `history` lists deploys, `status` has a
  section called `recent deploys`, PROTOTYPE.md talks about versions. host / server: help says
  `register a server` for `host add`. `upload lease`, `preflight`, `switch`, `copy`, `recover unit`
  and `last good` are internal terms shown to users.
- Fix, a glossary to enforce:
  | Concept | Word | Not |
  |---|---|---|
  | a machine | **server** in prose, `host` only as the command noun | VPS, box |
  | your code on a server | **app** | service, project, unit |
  | one uploaded build | **release** | version, deploy (as a noun) |
  | the act | **deploy** (verb), **deploy log** = `history` | — |
  | phases | build · upload · start test · go live · check | stage, copy, preflight, switch, verify |
  | the lock | "another deploy is running" | upload lease |

**F-61 · major · J6. Flag conventions differ between commands.**
- `-n` means lines in `logs`/`audit` and seconds in `top`. Refresh is `--watch N` in
  `ls`/`status`/`alerts` but `-n secs` in `top`. The time window is `--since` in logs but `--last`
  in requests. The host is positional in `doctor [host]`/`top [host]` and `-H` everywhere else. The
  app is positional in `status [app]`/`history [app]`/`audit [app]`/`alerts silence <app>` and `-a`
  everywhere else.
- Fix: `-a/--app` and `-H/--host` everywhere (keep positional forms as aliases); `-n` is always a
  count; `--watch [N]` everywhere refresh exists, `top` included; `--since` everywhere a time window
  exists.

**F-62 · minor · J6. Exit codes.**
- Usage errors exit 1, like runtime failures. Ctrl-C out of a watch exits 130. `stop` on a stopped
  app exits 0, which is fine, but the message implies it did something.
- Fix: 0 ok, 1 failed, 2 usage error, 3 not found (app/host), 4 cannot connect. Document them in
  `tando help exit-codes`.

### Journey 7: documentation

**F-63 · major · J7. The README is a reference, not a quick start, and has no troubleshooting.**
- The quick start uses `export PATH="$PWD/bin:$PATH"` (it only works from the repo root), while
  `install.sh` exists and is never mentioned. It includes `--insecure-test` and "recover unit"
  jargon. It does not show what success looks like or how to get the first link. It has nothing on
  DNS, firewall, installing Caddy/Node, passwordless sudo, `PORT`, dependencies, or what to do when
  `up` fails. Troubleshooting for every error in Journey 4 is absent.
- ARCHITECTURE.md and docs/TOP.md are excellent for maintainers; none of that helps the
  first-hour user.
- Fix: the draft below, plus a `docs/TROUBLESHOOTING.md` keyed by the exact first line of each
  error.

---

## Draft README quick start (proposed text, not applied)

````markdown
## Quick start (5 minutes)

You need: a Mac or Linux laptop, and an Ubuntu 24.04+ server you can `ssh` into as a user
with passwordless sudo.

**1. Point a wildcard domain at the server** (once). At your DNS provider add:

    *.apps.example.com   A   203.0.113.7

and open ports 80 and 443 in the server's firewall.

**2. Install tando** on the laptop:

    git clone https://github.com/OWNER/tando && cd tando && ./install.sh
    # adds ~/.local/bin/tando; open a new terminal if `tando` is not found

**3. Add and prepare the server** (once). `host add` shows the server's key fingerprint and
asks you to trust it; `host setup` installs Caddy and Node if they are missing (about a minute):

    tando host add vps admin@203.0.113.7
    tando host setup vps apps_domain=apps.example.com tls=auto

**4. Deploy an app.** From your app's folder:

    cd ~/code/my-app
    tando up

`up` detects Node, Next.js, static sites, Python and Dockerfiles, writes `tando.conf`, creates
the app and deploys it. The last line is your link:

    ╰─ live in 2.1s  https://my-app.apps.example.com ─╯

Your app must listen on `process.env.PORT` (tando picks the port). Next.js needs
`output: "standalone"` in next.config (tando offers to add it).

**5. Day two:**

    tando deploy                 # ship changes (also applies tando.conf changes)
    tando env set API_KEY        # asks for the value; restarts once
    tando logs -f                # follow the app's output
    tando status                 # memory, uptime, releases
    tando rollback               # back to the previous good release
    tando ls                     # every app on the server
    tando doctor                 # check the server

Something failed? The error says what to do next; the full list is in
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).
````

---

## The five worst raw outputs

1. `tando stop --help` → `stop: hello-node` [exit 0]. Production now answers 503. (F-01)
2. A fresh server without Caddy:
   ```
   │ ✓ 1/2  agent               /opt/tando/bin/tando-agent                        │
   Job for caddy.service failed.
   See "systemctl status caddy.service" and "journalctl -xeu caddy.service" for details.
   tando-agent: could not enable the recover unit or reload caddy
   ```
   (F-03)
3. Deploying while Caddy is down: 60 s of waiting, then
   `│ after the switch: no healthy answer within -H s (last: connection refused);… │`,
   and a good release is rolled back. (F-31)
4. `tando doctor` on a host that is not set up: `bash: line 1: /opt/tando/bin/tando-agent: No such file or directory`.
   For a login without sudo it shows all green, then every deploy prints `sudo: a password is required`
   inside a box that never closes. (F-10, F-11)
5. `tando status` with the server offline: 43 s of silence, then
   `mux_client_request_session: read from master failed: Broken pipe` /
   `Connection timed out during banner exchange`. (F-07)

---

## Already good: keep these

- **Deploy speed and the progress box.** Plain Node and static apps go live in 1-2 s; Next.js in
  about 10 s with a 12 MB first upload and a 138 KB delta after that. The 7-step box with
  per-step seconds is clear and calm.
- **Safety model.** The pre-flight on a spare port means a broken release never touches the
  running app. Failed releases are marked and visible in `history`. A deploy survived a 25-second
  network drop mid-activation (`live in 26s`), and Ctrl-C after the upload detaches cleanly with
  a message. The concurrent-deploy guard names who holds it.
- **Restore keeps a safety backup**, and the message says so:
  `restored 20261113-171815-manual; the data before the restore is in backup 20261113-171822-safety`.
- **`db url` refuses to print the password without `--show`**, and says why.
- **The env value round-trip is exact**: spaces, quotes, `$`, backticks, `;|&` and URLs with query
  strings all arrived intact.
- **Recipe detection** for Node, static, Next.js, Python and Dockerfile (including EXPOSE) worked
  first time. The npm platform swap for `sharp` happened automatically.
- **Errors that already do it right**, and that the rest should copy:
  `next.js: add  output: 'standalone'  to next.config.ts`,
  `this prints the database password: use tando db url --show`,
  `fix the problem and run tando up again (it resumes), or remove it with tando destroy`.
- **`top`**: no flicker, sensible 80/120/60-column layouts, a confirm modal that ignores pasted
  keys, and a log view that follows.
- **Colour turns off when piped**, and `NO_COLOR` is honoured.
- **`destroy` asks for the app name**, which is the right strength for that command.
