# tando usability review 2: a newcomer, hands on

14 Nov 2026. A first-time user's study of tando 0.1.0, run against a snapshot of the tree
(`test/.work-ux2/tree`, installed with `install.sh --prefix test/.work-ux2/prefix`) and a bare
test VM (`TANDO_TEST_BARE=1`, container `tando-ux2`, ssh 2270, http 8370). I used macOS
`/bin/bash` 3.2, the stock macOS `rsync` (openrsync), `TANDO_CONFIG_DIR=test/.work-ux2/config`,
and real ptys at 80 and 120 columns (`test/.work-ux2/pty.exp`, `ptyrec.py`, `toprec.py`). Raw
captures are in `test/.work-ux2/logs/`. I read only README.md, `tando help` and command output
until something stopped me. Reading source to get past a problem counts as a finding. The test-only
pieces were `public_port=8370 domain_tls=internal` on `host setup` and `TANDO_TEST_RESOLVE` for
domains. I judged the real flow from the messages.

---

## (a) Verdict

**Not yet. A newcomer who follows the README word for word cannot get a live app.** Two plain bugs
stop the documented path for any real user, meaning anyone who trusts the host key instead of
passing the test-only `--insecure-test`:

1. The first `tando host add` on a laptop says `trusted; saved` and then fails with
   `the host key of prod is not trusted yet` (B-1).
2. After that, every `tando up` or `tando deploy` fails at upload with
   `cannot reach prod: the name 127.0.0.1 does not resolve` (B-2). Nothing in the docs gets
   past it. I had to read `lib/common.sh` and `lib/deploy.sh`, then switch to `--insecure-test`.

The README's own transcript uses `--insecure-test`, and so does every e2e suite. That is why
neither bug shows up in the tests.

**With those two bugs fixed, the answer is yes, and the rest is good.** The path is 4 commands:
`host add`, `host setup`, `cd app && tando up`, `tando domain add`.

- Empty VM to first live link: about 2 minutes (setup 50 s, the first `up` 25 s, mostly
  installing Node, plus a 30 s soak).
- Live link to custom domain: under 1 s plus DNS propagation.
- My actual run: 9 commands and 4 minutes of wall time to the first live link, including 3
  `host add` attempts, 2 failed `up`s and reading source. A human reading that source would
  need far longer.
- Nothing on the server was configured by hand. Caddy, rsync, nftables, Node, Python, Podman
  and PostgreSQL all came on demand.

| | tando (bugs fixed) | Kamal 2 | Dokku | Coolify | Fly / Vercel CLI |
|---|---|---|---|---|---|
| Server prep | `host add` + `host setup`, ~1 min, nothing by hand | `kamal setup` installs Docker; you need a registry account | curl bootstrap script on the box, then `dokku apps:create` on the server | web installer, then a GUI | none (their cloud) |
| First deploy | `tando up`: detects the recipe, writes config, no Dockerfile | needs Dockerfile + `deploy.yml` + registry | `git push dokku` (buildpacks) | GUI wizard | `fly launch` / `vercel` |
| Domain + TLS | `tando domain add`, prints the exact DNS records | edit `proxy: host:` in deploy.yml, redeploy | `dokku domains:add` + letsencrypt plugin | GUI field | `fly certs add` / `vercel domains add` |
| Failure explanation | best of the group when it hits a known pattern (port, EPERM, build); falls back to raw journal lines | container logs | buildpack output | GUI logs | good |

Once B-1 and B-2 are fixed, tando is close to the Fly/Vercel experience on your own box. It is
clearly smoother than Kamal and Dokku for the first hour: no registry, no Dockerfile, and DNS
records spelled out for you.

**Findings by severity:** 2 blockers, 10 major, 17 minor, 12 polish (41 in all; 6 are plain
bugs, marked B-).

---

## (b) Findings

Columns: id, severity, journey, what happened, what I expected, fix.

### Blockers

**B-1 · blocker · J2: the first `host add` on a laptop always fails after trusting the key.**

```
$ tando host add prod vmadmin@127.0.0.1 --port 2270 --key …/id_test --yes   # fresh TANDO_CONFIG_DIR
added host prod (vmadmin@127.0.0.1, port 2270)
prod (127.0.0.1, port 2270) presents these host keys: …
trusted; saved in …/known_hosts
tando: the host key of prod is not trusted yet
  tando host add prod vmadmin@127.0.0.1 --port 2270 --force  shows its fingerprint and asks
rc=1
```

Running the same command again with `--force` works.

- **Cause:** `host_add` calls `host_use`, which builds `SSHO` and adds
  `UserKnownHostsFile=$CFG/known_hosts …` only if that file already exists
  (`lib/common.sh:197`). `host_trust` then creates the file, and `host_check` runs with the
  stale `SSHO`.
- **Expected:** "connected sudo ok, not set up yet".
- **Fix:** call `host_use "$name"` again after `host_trust` succeeds, or always add the
  `UserKnownHostsFile` option.
- **Reproduce:** `TANDO_CONFIG_DIR=$(mktemp -d) tando host add p user@server --yes`.

**B-2 · blocker · J2: every upload fails for a host whose key was trusted (the normal path), with a misleading message.**

```
╭─ deploy myapi ─────────────────────────────────────────── prod ─╮
│ ✗ 3/7  upload                                                   │
│ tando: cannot reach prod: the name 127.0.0.1 does not resolve   │
│   check the spelling, or use the IP address: tando host add prod vmadmin@<i… │
╰─ nothing was deployed ──────────────────────────────────────────╯
```

- **Cause:** `lib/deploy.sh:105` runs `rsync -e "ssh ${SSHO[*]}"`. `SSHO` contains
  `-o "UserKnownHostsFile=$CFG/known_hosts $HOME/.ssh/known_hosts"`, so rsync splits it on the
  space and ssh takes `/Users/me/.ssh/known_hosts` as the host name:
  `ssh: Could not resolve hostname /users/me/.ssh/known_hosts`. `ssh_explain` then reports
  the address as the name that does not resolve. Both openrsync and GNU rsync split `-e` this way.
- **Expected:** the upload works.
- **Fix:** pass the two files without a space inside one option: write a tiny ssh config
  (`-F $CFG/ssh_config` with `UserKnownHostsFile "a" "b"`), or use
  `-o UserKnownHostsFile=$CFG/known_hosts -o GlobalKnownHostsFile=~/.ssh/known_hosts`. Add an
  e2e test that does not use `--insecure-test`. Also, `ssh_explain` should print the hostname ssh
  actually failed on.
- **Reproduce:** `tando host add` without `--insecure-test`, then `tando up` in any app.

### Major

**B-3 · major · J4: the command the failure box recommends does not work, and on macOS the error is blank.**

```
│ all of it: tando logs --release 20261114-020252 · the server: tando doctor │
$ tando logs --release 20261114-020252
tando: logs:
rc=1
```

- **Cause, part 1:** the server answers
  `tando-logs: release 20261114-020252 was never live (see tando history)`, so `--release`
  refuses exactly the failed pre-flight releases it is suggested for.
- **Cause, part 2:** `lx_err` in `lib/cmd-logx.sh:63` uses `sed 's/^tando-\(logs\|agent\): //p'`.
  `\|` is GNU-only, so BSD sed matches nothing and the message comes out empty.
- **Expected:** the full output of the release's start test.
- **Fix:** let `--release` read a failed release's activation log. Replace the sed with
  `sed -n -e 's/^tando-logs: //p' -e 's/^tando-agent: //p'`. Also check line 61's
  `grep '^tando-\(logs\|agent\):'` (it works with BSD grep, but use `-E 'tando-(logs|agent):'`
  to be safe).

**B-4 · major · J6: `tando ci github` and `tando ci hook` fail on any tando installed with `install.sh`.**

```
$ tando ci github --repo https://github.com/example/tando --ref 0123…4567
tando: missing template …/prefix/lib/tando/templates/github-deploy.yml
$ tando ci hook
awk: can't open file …/prefix/lib/tando/templates/pre-push
tando: could not write …/.git/hooks/pre-push
```

- **Cause:** `install.sh:116` copies `bin lib server completions` and leaves out `templates`.
- **Fix:** add `templates` to that list, and to the release archive.

**M-1 · major · J4: a Flask app that binds its default port gets no explanation.**

```
│ pre-flight: the app exited (inactive; last: connection refused) │
│    * Serving Flask app 'app'                                    │
│   Operation not permitted                                       │
```

- **What happened:** `app.run()` binds 5000. Node's `listen EPERM` gets the friendly "fixed
  port" explanation (see M-2), but Python's bare `Operation not permitted` does not.
- **Fix:** treat `Operation not permitted` in the last lines of a python app as a fixed-port
  bind and print the Python hint. `tando init` for python should detect `Flask(` / `FastAPI(`
  and write `start = gunicorn app:app -b 127.0.0.1:$PORT` (or `flask run --port $PORT` with
  `start_shell`), or at least write a comment in tando.conf that names `os.environ["PORT"]`.

**M-2 · major · J8: the fix is printed last and cut off at 80 columns.**

```
│   Error: listen EPERM: operation not permitted 0.0.0.0:3000        │
│       at Server.setupListenHandle … (6 stack frames)                │
│ the app listened on a fixed port; tando gives it one in PORT and blocks the… │
│   listen on process.env.PORT (Node), os.environ["PORT"] (Python)  │
```

- **Expected:** the explanation first, never cut off.
- **Fix:** put the known-cause sentence directly under `✗ 5/7 preflight`, show at most 2
  lines of the error (the first line and the first frame in the user's file), and wrap instead
  of truncating hint lines (this applies to all of `ui_box_line`).

**M-3 · major · J2: a container app whose Dockerfile has `EXPOSE 8000` waits 60 s and fails with podman noise.**

```
│ ✓ 5/7  preflight      59s
│ pre-flight: no healthy answer within 60 s (last: empty reply)
│   2026-11-14 01:58:39.785247298 +0000 UTC m=+0.041239983 container create c384…
```

- **Expected:** `tando init` reads `EXPOSE 8000` and writes `container_port = 8000`.
- **Fix:** read `EXPOSE` in init. If the health check gets an empty reply, say:
  `nothing answered on container_port 8080; the Dockerfile EXPOSEs 8000: set container_port = 8000`.
  Filter podman's own `container create/init/pull` lines out of the excerpt.

**M-4 · major · J2/J4: every deploy blocks the terminal 30 s, without a countdown, and the reason is cut off.**

```
│ ✓ 6/7  switch        0.1s
│         live at http://myapi.localhost:8370; watching it for 30 s before ca… │
│ ✓ 7/7  verify         29s
╰─ live in 31s …
```

- **What happened:** the README promises "about two seconds per deploy". With the default
  soak, every deploy I ran took 31–38 s and printed nothing for 29 s (pty timeline: no bytes
  between 2.0 s and 31.5 s).
- **Fix:** say on the closing line `live (watching 30 s; Ctrl-C leaves it to the server)` and
  count down in the verify row. Better: once switched, print the link and return, as Ctrl-C
  already does ("detached: … keeps activating"), with `--wait` to block. Then update the README
  figure.

**M-5 · major · J3: a `domain =` line with wrong DNS blocks the whole code deploy, and the suggested flag does not exist on deploy.**

```
$ tando deploy
tando: DNS for bad.test does not point at prod yet. At your DNS provider, create: …
then run this again (--wait polls until it is right; --force skips the check)
$ tando deploy --wait
tando: deploy does not take --wait
```

- **What happened:** `--force` on deploy means two different things: "from another directory"
  and "skip DNS".
- **Expected:** deploy the code and warn about the domain.
- **Fix:** deploy anyway and end with
  `bad.test not added yet: DNS points at 203.0.113.9; create A bad.test -> 192.0.2.10, then tando domain add bad.test --wait`.

**M-6 · major · J8: unreachable, refused, timeout and typo'd hosts all print the same message, and the README rows never appear.**

```
$ tando host add typo vmadmin@prod.invalid           (also: closed port, 10.255.255.1)
added host typo (vmadmin@prod.invalid, port 22)
tando: could not read the host key of prod.invalid (port 22): is sshd listening there?
  the entry is saved; check it with: tando doctor typo
```

- **What happened:** `host_trust` runs `ssh-keyscan` and drops its error, so the precise
  `ssh_explain` texts ("does not resolve", "connection refused", "no answer within 5 s") never
  reach the user at `host add`.
- **Fix:** before the keyscan, run one `ssh -o BatchMode=yes -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null true` probe and pass its stderr through `ssh_explain`.

**M-7 · major · J2/J8: a failed `host add` leaves the host saved, so the obvious retry is refused.**

```
tando: not trusted (no terminal to ask): run again with --yes to trust them
$ tando host add prod … (same command again)
tando: host prod exists (vmadmin@127.0.0.1, port 2270): tando host add prod ... --force replaces it
```

The same happens after Ctrl-C at the trust prompt, after a wrong key, and after an unreachable
host. `host ls` then shows `✗ no no answer` (the word "no" is doubled), even for a server that
answers and only refused the key.

- **Fix:** save the entry only after it connects, or let re-running the identical command
  continue without `--force`. In `host ls`, say `✗ host key not trusted` or `✗ login refused`
  instead of `no answer`.

**M-8 · major · J6: docs/CI.md is mostly a security design document.**

The newcomer needs: (1) `tando ci setup`; (2) four `gh secret set` commands; (3)
`tando ci github`; (4) push. Instead, those steps sit inside 200 lines about gates, leases and
hardlinks. `tando ci github` without `--repo` says
`tando has no origin remote here: use --repo <url of the tando repository>`, and "here" means the
tando install, not my app. An installed tando never has an origin.

- **Fix:**
  - Put a 10-line "Set up GitHub Actions" section first, and move the internals under
    "How it is secured".
  - Default `--repo` to the URL baked in at release time (`REPO=` in install.sh) and `--ref` to
    the installed VERSION tag.
  - Change the error to `the workflow installs tando from GitHub: pass --repo https://github.com/<owner>/tando --ref v0.1.0`.
  - Offer `tando ci setup --github`, which runs the four `gh secret set` commands when `gh` is
    logged in.

### Minor

- **m-1 · J1:** the README install line is `git clone https://github.com/OWNER/tando`, and
  `REPO=OWNER/tando` in install.sh. A newcomer cannot install from the README. Fill in the real
  repo before publishing, or add a one-line `curl … | bash` installer.
- **m-2 · J8:** the wrong-key hint drops the port:
  `tando host add wk vmadmin@127.0.0.1 --key ~/.ssh/<key> --force`. The host was on port 2270,
  so the suggested command points at port 22. Include `--port $port` when it is not 22, as the
  other hints do.
- **m-3 · J5:** `tando -H staging up` writes tando.conf without `host =`. Every later command in
  that directory fails with `2 servers are registered (prod, staging): add host = <name> …`.
  When `up` writes tando.conf with `-H`, write `host = staging`.
- **m-4 · J5:** with 2+ hosts and a terminal, `tando up` refuses instead of asking. Ask
  `Deploy to which server? 1) prod 2) staging [1]` and write the answer into tando.conf.
- **m-5 · J7/J8:** outside an app directory, server commands (`alerts`, `status`, `logs`) say
  `add host = <name> to tando.conf`. There is no tando.conf there, and `tando deploy` in the same
  directory says `no tando.conf here` instead. For server-level commands, say
  `which server? tando alerts -H prod (servers: prod, staging)`, and accept
  `tando alerts prod` as `top [host]` does.
- **m-6 · J4:** `tando status` shows `○ stopped` for an app that died, the same as one
  stopped with `tando stop`. alerts says `not running (inactive; not stopped with tando stop)`.
  status should say `✗ down (not stopped by you) — tando start, tando logs`.
- **m-7 · J7:** the alert text has no next step:
  `FIRING myapi/down: not running (…)`. Add `→ tando logs -a myapi; tando start -a myapi`.
  The title uses the machine's hostname (`tando tando-ux2`), not the name the user gave
  (`prod`); use `prod (tando-ux2)`.
- **m-8 · J3:** deleting `domain = api.test` from tando.conf and deploying leaves the domain
  live, with no hint. The README says so, but at deploy time print
  `api.test is still served (not in tando.conf): tando domain rm api.test`.
- **m-9 · J4:** `tando logs` is mostly systemd and journald lines (`Starting
  systemd-journald@…`, `Failed to open /dev/kmsg …`, `Collecting audit messages is disabled`).
  For the failed Flask app, the app's own two lines were buried. Hide `[journald]` lines by
  default and dim `[systemd]` lines (`--all` shows them).
- **m-10 · J4:** after a failed deploy ("the running app was not touched"), `tando rollback`
  goes back from the good current release to the one before it. A newcomer who thinks they are
  undoing the failure loses a good release. Print
  `20261114-020252 failed and was never live; rolling back the live release 020250 → 020240. Sure? [y/N]`
  when the last deploy failed.
- **m-11 · J2:** the first `tando up` of an Express app with no `node_modules` ran
  `npm install` on the laptop and created `package-lock.json` and `node_modules` in my project.
  It says so (`installed dependencies: npm install`), but changing my tree is a surprise. Say
  `ran npm install here (created package-lock.json)`.
- **m-12 · J4:** there is no way to run a job once to test it: `tando jobs run report` gives
  `jobs takes no arguments`. Add `tando jobs run <name>`, as Dokku's `run` and Kamal's
  `app exec` do.
- **m-13 · J4:** for a database, data dir and job added in tando.conf, the deploy box says
  nothing about them. Add lines such as
  `database postgres: created tando_flaskapp, DATABASE_URL set`, `job report: daily, next in 21h`
  and `data: $TANDO_DATA_DIR`.
- **m-14 · J2:** a removed or unknown app's link (`my-site.localhost` after `destroy`) shows
  Caddy's "Congratulations! … Edit your Caddyfile at /etc/caddy/Caddyfile". That is the opposite
  of tando's advice. `host setup` should replace the stock `:80` site with a small
  `no app here (tando)` 404, as the non-bare test image does.
- **m-15 · J2:** the setup box says `caddy 2.6.2 (installed now)`, and `tando doctor` then warns
  `Caddy 2.6.2 does not log requests whose Host has a …`. Setup installs the version that doctor
  complains about. Either install upstream Caddy, or have setup itself say once what is lost.
- **m-16 · J8:** `tando -H prdo` gives `unknown host: prdo (tando host add)`, and `-a myap`
  gives `no app "myap"`. Command typos get "Did you mean", but host and app names do not. Add
  `did you mean prod?` / `myapi?`.
- **m-17 · J4:** `tando status | head` (admin and deploy-key mode) prints
  `…/lib/ui.sh: line 269: printf: write error: Broken pipe` (also in `cmd-ci.sh:35`). Ignore
  SIGPIPE/EPIPE when output is piped.

### Polish

- **p-1 · J8:** flag typos get no suggestion: `deploy does not take --forse`. Add
  `(did you mean --force?)`. `logs --follow` should be accepted as `-f`.
- **p-2 · J8:** `tando help nope` suggests `"top"`. Do not suggest when the edit distance is
  ≥ the length of the word.
- **p-3 · J3:** `domain add https://Shop.test/` gives `not a domain name`. Strip the scheme,
  path and case and continue (`using shop.test`).
- **p-4 · J3:** the success line `https://shop.test is live` does not mention www. Say
  `https://shop.test is live; www.shop.test redirects to it`, and show the custom domain as the
  link on the deploy's closing line once there is one.
- **p-5 · J2:** the deploy-box hint lines are cut at 80 columns (`vmadmin@<i…`,
  `watching it for 30 s before ca…`, `tando rollback 2026…`). Wrap hint lines; truncate only
  table cells. At 120 columns everything fits.
- **p-6 · J4:** history says `TOTAL 0.9s` for a deploy whose box said `live in 2.2s`. Use one
  number (wall time) in both.
- **p-7 · J8:** Ctrl-C at a prompt (`Type flaskapp to confirm`, `Trust them?`) leaves the cursor
  after `^C` with no newline and no "cancelled". Print `\ncancelled; nothing changed`.
- **p-8 · J8:** two deploys at once: the second waited about 30 s without a word, then said
  `live in 1m 3s`. Say `waiting for the other deploy of expressapp (from this laptop, 2s ago)…`.
- **p-9 · J4:** `tando db url` without `--show` refuses and tells you to add `--show`. Print the
  URL with the password masked, plus the hint, instead of failing.
- **p-10 · J4:** `tando backup restore` with no id gives `wrong number of arguments`. List the
  backups and ask `restore the newest (20261114-020640-manual)? type flaskapp`.
- **p-11 · J1:** uninstall leaves empty `bin/ lib/ share/…` directories in a private prefix,
  and does not say that `~/.config/tando` remains (the script's header does). Add one line:
  `kept ~/.config/tando (hosts, known_hosts): --purge removes it`.
- **p-12 · J4:** `ls` shows `● static` for a static app, `top` shows `● running` for the same
  app, and `doctor` warns `app port3000 nothing deployed` without a fix. Use one state word, and
  add `tando destroy -a port3000` to the doctor line.

---

## (c) Ten changes that would make this feel effortless (ranked)

1. **Fix B-2 (the rsync `-e` split) and B-1 (stale `SSHO` after trust), and run one e2e suite
   without `--insecure-test`.** Today the documented path fails for every real user, at the
   first two commands that matter.
2. **Put the fix first in every failure box and never truncate it** (M-2, p-5). Use one plain
   sentence under the failed phase, then at most two lines of evidence, then the command.
3. **Make `tando logs --release <id>` work for failed releases, and fix the BSD-sed blank
   error** (B-3). It is the one command every failure box recommends.
4. **Teach init the two port conventions it misses:** `EXPOSE` → `container_port`, and Python's
   `Operation not permitted` → the Python PORT hint, with gunicorn/uvicorn start lines for
   Flask/FastAPI (M-1, M-3).
5. **Return when the release is live, and soak in the background** (M-4). Show
   `live: <link> · watching 30 s on the server (tando status)`, and keep `--wait` for CI. This
   gives back the README's "two seconds".
6. **`host add` saves only what works and explains the real ssh error** (M-6, M-7). Re-running
   the same command just works. Unreachable, refused, unresolved and bad-key each get their own
   README row text.
7. **Ship `templates/` in install.sh, and give `ci github` sensible defaults** (`--repo` and
   `--ref` from the installed release), plus a 10-line GitHub quick start on top of docs/CI.md
   (B-4, M-8).
8. **A domain is never a reason to refuse a code deploy** (M-5). Deploy, then print the DNS
   records and `tando domain add X --wait`.
9. **One host question, asked once:** with 2+ servers, `up` asks which one and writes `host =`;
   `-H` also writes it; server-level commands accept `tando alerts prod` (m-3, m-4, m-5).
10. **Tell the user what the server did** (m-13, m-6, m-7): `database created`,
    `job scheduled`, `down (not stopped by you)`, and alert texts with the next command.

---

## (d) What is already good and must not change

- **The four-line quick start.** `host add` → `host setup` → `up` → `domain add` is the right
  shape. It is shorter than Kamal and Dokku, and nothing on the server is configured by hand.
  Runtimes installed on demand ("installing node 24 on prod (the first app that needs it…)")
  are excellent.
- **`host setup`'s closing box,** ending in `next: cd your-app && tando up`. Every success
  should end this way.
- **Recipe detection.** A plain Node file, a static folder, a default `create-next-app` (with
  the `output: "standalone"` offer) and a Dockerfile all deployed with no tando.conf editing,
  except `container_port`. `my_Site` becomes `my-site`, and tando says so.
- **`domain add`'s DNS check,** which prints the exact A records, with "(now 203.0.113.9)".
  It is better than any competitor I know.
- **Safety:** a failed pre-flight never touches the live app ("the running app was not
  touched"). A failed first deploy says the app exists and what to do. `destroy` and `restore`
  require typing the app name, and a wrong name changes nothing. Deploying the same app from
  another directory is caught. `--help` never runs anything.
- **Ctrl-C mid-deploy:**
  `detached: release … keeps activating on the server; follow it with tando status --watch 2`.
  Keep it.
- **Command typos** get "Did you mean "deploy"?", and unknown flags give a usage line and
  exit 2.
- **`env`:** `set`/`unset` restart once, `env unset NOPE` says nothing changed and does not
  restart, `env import` understands `export B="two"`, and a `.env` file is never uploaded, with a
  pointer to `env import`.
- **Backups:** a pre-deploy backup is taken automatically, and restore keeps a safety copy.
- **`tando top`, `status` and `ls`:** dense and readable at 80 columns.
- **Alerts:** one notifier, `alerts test` delivered, and a real `down` fired within about
  1.5 minutes and resolved with a duration.
- **CI deploy key:** the plain one-line-per-step output, and the clear refusal
  `not allowed with a deploy key: rollback (…everything else is the admin's)`.
- **`install.sh`:** half a second, no sudo, prints the PATH line to add; uninstall removes
  exactly what it installed.

---

## (e) The first five minutes, as they should read

```
$ curl -fsSL https://tando.dev/install | bash
tando 0.2.0 installed in ~/.local/bin (open a new terminal if `tando` is not found)

$ tando host add prod root@203.0.113.7
prod (203.0.113.7) presents host key ED25519 SHA256:zfKx/+ls…
Trust it? (compare on the server: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub) [y/N] y
● connected · sudo ok · Ubuntu 24.04, 2 GB RAM · not set up yet
next: tando host setup prod

$ tando host setup prod
╭─ host setup prod ──────────────────────────────── root@203.0.113.7 ─╮
│ ✓ 1/8  agent      0.2.0                                              │
│ ⠼ 2/8  packages   installing rsync curl nftables (apt, ~30 s)…       │
…
│ links  https://<app>.203-0-113-7.sslip.io                            │
╰─ ready in 52s · next: cd your-app && tando up ───────────────────────╯

$ cd ~/code/shop && tando up
detected: node (package.json, start: node server.js, health: /)
wrote tando.conf (host prod) — edit it any time, then tando deploy
installing node 24 on prod (first Node app; ~20 s)… node 24.22.3
╭─ deploy shop ─────────────────────────────────────────────── prod ─╮
│ ✓ 1/7  build …  ✓ 6/7 switch 0.1s                                  │
╰─ live  https://shop.203-0-113-7.sslip.io  (watching 30 s on prod) ─╯
next: tando domain add shop.example.com

$ tando domain add shop.example.com
DNS for shop.example.com does not point at prod yet. At your DNS provider, create:
  A  shop.example.com  ->  203.0.113.7
waiting for DNS (Ctrl-C stops waiting; run this again later)… found after 2m 10s
certificate issued · https://shop.example.com is live
```

The first app goes live in 4 commands and under 2 minutes of machine time. Each step ends by
naming the next one, and no one types `--force`, `--insecure-test` or `-H`.
