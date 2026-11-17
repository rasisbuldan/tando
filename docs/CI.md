# CI deploys with a restricted key

`tando deploy` from GitHub Actions (or any CI) with a key that can ship code to **one app** and do
nothing else. The admin keeps everything else: settings, env, rollback, start/stop, logs, destroy.

Commands (run by the admin, in the app's directory): `tando ci setup`, `tando ci github`,
`tando ci hook` (deploy from `git push` on the laptop instead), `tando ci ls`, `tando ci rotate`,
`tando ci revoke <id|SHA256:...|all>`.


## Set up GitHub Actions (quick start)

```sh
cd my-app                       # the app's git repository, with tando.conf
tando ci setup > ci-secrets.txt # a deploy key for this app; the file holds 4 secrets, once
# GitHub > Settings > Environments > New "tando-deploy" (deployment branch: main), then:
for n in TANDO_DEPLOY_KEY TANDO_HOST TANDO_PORT TANDO_KNOWN_HOSTS; do
  awk -v n="--- $n" '$0 == n { on = 1; next } /^--- / { on = 0 } on' ci-secrets.txt |
    gh secret set "$n" --env tando-deploy
done; rm ci-secrets.txt
tando ci github                 # writes .github/workflows/deploy.yml (tando pinned to this release)
git add .github && git commit -m "deploy with tando" && git push   # deploys
```

The key can deploy this app's code and nothing else, but that code runs with the app's env and
data: give a CI-deployed app only secrets you would also give your CI (see below).

## Who can do what

| | admin (own login + sudo) | deploy key of app A (`tando-d-A`) | anyone else |
|---|---|---|---|
| upload into A's `incoming/` | yes (as `tando-d-A` through sudo) | yes, only while it holds A's lease, rsync receiver only | no |
| begin / end A's upload lease | yes | yes (lease is tagged `ci-<key id>`) | no |
| activate A (pre-flight, switch, verify, auto-rollback) | yes | yes, only its own frozen upload | no |
| deploy-status, status, releases, history of A | yes | yes (no app log lines, no other app's rows) | no |
| `rollback`, `rollback <id>` | yes | **no** | no |
| `up`/`configure` (start command, health, memory, jobs, unit, Caddy) | yes | **no** | no |
| `env set/unset/ls`, `logs`, `start/stop/restart`, `unlock`, `backup *`, `db *`, `destroy` | yes | **no** | no |
| read A's env, shared data or releases directly | yes | no (OS permissions) | no |
| ship code that runs **with A's env and data** (also during pre-flight, even when the deploy fails) | yes | **yes**: the key is as good as A's secrets | no |
| anything of app B | yes | **no** (B's files are another user's; sudo rules name A only) | no |
| a shell, pty, port/agent/X11 forwarding, sftp, scp | yes | **no** | no |
| manage keys (`tando ci ...`) | yes | no | no |

Rollback is not given to the key: the activation already rolls back by itself when a release fails
after the switch, and a manual rollback is an operator decision (it can bring back a release with a
known bug). A deploy key that wants the old code can deploy the old commit, which goes through the
same pre-flight as any release.

**What this means for secrets (F9).** A deploy key can run any code as app A, so it can read
everything A can: its env (database URLs, API keys) and `shared/` data. Give an app deployed from CI
only credentials you would also give the CI system: separate, narrowly scoped keys per app, never
shared with other apps. Protect the key like those secrets (a GitHub environment limited to one
branch). The key cannot reach other apps' files, root, or tando' configuration.

## How it works (server)

- **One login user per app**, `tando-d-<app>`, created by `tando ci setup` with a system uid that no
  removed user ever had (`/opt/tando/retired-uids`, shared with tando-agent). Its home
  `/opt/tando/ci/<app>` is root's (711), its password field is `*`, and **its login shell is
  `/opt/tando/bin/tando-gate`**, a static Go binary (`srv/gate`; the shell original is kept in
  `server/legacy/tando-gate`, not installed).
- **Keys** live in `/opt/tando/ci/<app>/.ssh/authorized_keys`, `root:tando-keys` 640. sshd reads it
  through `AuthorizedKeysCommand /usr/bin/cat %h/.ssh/authorized_keys` as the user `tando-keys`
  (`AuthorizedKeysFile none`), so the deploy user cannot read its own key ids. Each line is
  `restrict,command="/opt/tando/bin/tando-gate key <key id>" ssh-ed25519 ...`.
- **sshd drop-in** `/etc/ssh/sshd_config.d/50-tando-ci.conf` (`Match User tando-d-*`): keys only, no
  pty, no forwarding of any kind, no `~/.ssh/rc`, `SetEnv LC_ALL=C LANG=C` (no client locale reaches
  bash), at most 4 sessions per connection.
- **Nothing runs as the deploy user outside its ssh requests:** its systemd user manager is masked,
  lingering is off, and it is listed in `/etc/cron.deny` and `/etc/at.deny`.
- **The app is the caller's uid.** The request may name an app only to have it compared with that
  one: `this key deploys alpha only`.
- **The request** (`SSH_ORIGINAL_COMMAND`) must be at most 300 characters of `[A-Za-z0-9_.:=/@,+ -]`.
  It is split into words and parsed into a typed request by a fixed grammar per verb (an option
  where a name or path is expected, a quote, a glob, a control character or a byte above 0x7e is
  refused); nothing from it is put into a command line except values that passed their pattern
  (token, seconds, release id, history count, whitelisted rsync options). It never reaches a
  shell.
- **The gate's own process** keeps `SSH_ORIGINAL_COMMAND`, `SUDO_UID`, `SUDO_USER` and
  `INVOCATION_ID` from its environment and clears the rest (locale, `PATH`, `HOME`, `TMPDIR`,
  `LD_*`, `SSH_*`); every program it starts gets a fixed `PATH` and `LC_ALL=C`. It sets umask 022
  and works from `/`. As root it refuses to start when a Go runtime variable (`GODEBUG`,
  `GOTRACEBACK`, `GOGC`, `GOMEMLIMIT`, `GOMAXPROCS`) is set (sudo's `env_reset` removes them). A
  crash prints `tando-gate: internal error` and nothing else.
- **sudo**: `/etc/sudoers.d/tando-d-<app>` allows exactly `tando-gate root <app> begin`, `end`,
  `activate` and `receive`: fixed path, verb and app, nothing else.
- **Root mode is bound to the ssh session.** Walking up past sudo, the first other process must be
  the gate as login shell (`tando-gate -c "<gate> key <id>"`, executable the gate) running wholly as the deploy user,
  whose parent is that user's `sshd-session` and whose grandparent is sshd's root process. The key id
  is read from that process's command line (set by sshd from the root-owned key file) and the rsync
  request from its initial environment. A process of the deploy user that sshd did not start for a
  key is refused, whatever it sends. Root mode also checks that the key is still registered.
- **Uploads go through a confined receiver.** `rsync --server` with whitelisted options (short
  `l p t r c z v` plus GNU's `e.<capabilities>`; `--delete`, `--delete-before`, `--delete-during`,
  `--delete-delay`, `--dirs`, `--stats`; exactly one `.`; destination exactly the app's
  `incoming/`) runs as the deploy user in a transient unit `tando-rx-<app>`: `ProtectSystem=strict`,
  `ReadWritePaths=` incoming/ only, private `/tmp` and `/dev`, no `/run/user`, no network, no
  capabilities, `NoNewPrivileges`. So a symlink in the upload cannot carry a write anywhere else.
  Symlinks that resolve outside `incoming/` are also removed before and after each receive (an
  absolute one only when it names `incoming/` itself; a path that leaves `incoming/` on the way
  counts as outside). The
  unit is `tando-rx-<app>@<nonce>`, a new name for every receiver; there is one receiver per app
  at a time because each is started under the lease lock after none of the app's was found
  running, and the lock is given back only once the new one runs.
- **After `end` (or the freeze of an activation), nothing of that upload writes `incoming/`.** The
  lease lock is given back by an upload only once its receiver unit runs (or systemd-run has
  returned); `end` and `activate` mark the lease closed (`ended`/`frozen`) and remove the
  receiver's ticket (`/opt/tando/ci/<app>/receiver`, a nonce root writes for each receiver) under
  that lock before they stop anything, and the receiver checks its ticket before it writes
  anything. A receiver either runs already (and is stopped) or does not start.
- **Limits, during the upload:** one file is capped by the kernel (`LimitFSIZE`); a root watchdog
  walks `incoming/` and stops the receiver when it holds more bytes or entries than the app's
  limit (defaults 3 GB, 200,000 entries, 1 GB per file; `ci_max_mb`, `ci_max_files`, `ci_max_file_mb`
  in `/opt/tando/host.conf`). The watchdog checks every 250 ms or more, waiting four times as
  long as its last walk took, so it uses at most a fifth of a core; the overshoot is what the
  receiver writes in one interval. It checks once more when the receiver ends (an upload faster
  than one interval is refused too), and stops an upload whose tree it cannot walk. The unit also has `MemoryMax=512M`, `TasksMax=16` and ends with
  the lease (`RuntimeMaxSec`).
- **The admin's upload** goes through the same receiver (`tando-gate admin receive`, during the
  admin's own lease).
- **Refusals are logged** to the journal (`journalctl -t tando-gate`, facility auth).
- **Read verbs** (`deploy-status`, `status`, `releases`, `history`) run `tando-agent` as the deploy
  user, never as root; only whitelisted keys and this app's rows pass, `log=` lines are dropped.

### Activation: root never trusts the upload

1. **Freeze**: under the lease lock, the lease must be this key's and not yet activated;
   `/opt/tando/ci/<app>/frozen` (root, 600) gets its token. A receiver is refused from now on.
2. **End everything of the deploy user** but this call's own ancestors: the receiver unit, every
   other session's cgroup (`cgroup.kill`, which takes forks too), then any process of the uid left
   anywhere, repeated until none is left.
3. **Check the frozen upload** as root (names and metadata only, read with directory descriptors:
   no link is followed, no file opened, the file system not left): regular files, directories and
   symlinks; every entry owned by the deploy user; no hardlinks; no setuid/setgid/sticky; no symlink
   that resolves outside `incoming/` (a container upload: no symlink at all); within the limits.
4. `tando-agent activate` copies `incoming/` to `releases/<id>` and checks the root-owned copy, then
   pre-flight, switch, verify and automatic rollback.

### Leases and eviction

- `end` checks, under the lease lock, that the lease is this key's with this token before it stops
  anything; `begin` ends earlier sessions only once the new lease is taken.
- **Revoke and rotate** evict the deploy user: `loginctl terminate-user`, `cgroup.kill` on its slice,
  the receiver unit, a kill loop until no process is left, its crontab and at jobs, IPC objects and
  its files in `/tmp`, `/var/tmp`, `/dev/shm` and `/run/user/<uid>`; the revoked key's lease ends.
- `tando destroy` removes the deploy user, its sudo rule and home, and retires its uid.

## Client

`tando deploy` takes a deploy key from the environment when `TANDO_DEPLOY_KEY` is set (and `-H` is
not given):

| variable | |
|---|---|
| `TANDO_DEPLOY_KEY` | the private key itself, or a path to it |
| `TANDO_HOST`, `TANDO_PORT` | the server (port defaults to 22) |
| `TANDO_KNOWN_HOSTS` | the server's host key lines from `tando ci setup`; required, host keys are always checked. The keys are bound to a fixed alias, so the check does not depend on how the runner spells the host |
| `TANDO_APP` | only when there is no `tando.conf` |
| `TANDO_PLAIN` | `1` plain lines, `0` boxes; default: plain without a terminal |

The login is `tando-d-<app>@$TANDO_HOST`, with `-F /dev/null`, no agent, no forwarding. A host
entry with `kind=deploy` (`tando host add ci tando-d-app@host --key k --deploy`) does the same from the
registry. On a terminal the deploy shows the usual box; without one (CI) it prints one line per
step:

```
deploy alpha (203.0.113.7)
[1/7] build     ok   0.4s  3 lines, built
[2/7] stage     ok   0.0s  6 files
[3/7] upload    ok   0.2s  1 files changed, 172 B sent
release 20261113-170102
[4/7] copy      ok   0.0s
[5/7] preflight fail 10.6s
pre-flight: health check answered HTTP 500 for 10 s
release 20261113-170102: failed; the running app was not touched
```

A failure shows the phase, the reason and the HTTP status, never application log lines.

## GitHub Actions: `tando ci github`

Writes `.github/workflows/deploy.yml` from `templates/github-deploy.yml`:

- `on: push` to the configured branch only, plus a job guard `if: github.ref == 'refs/heads/<b>'`
  (so a manual run from another branch does nothing).
- `concurrency: tando-deploy-<app>`, `cancel-in-progress: false`: two pushes never overlap and an
  upload is never cut short; GitHub keeps only the newest waiting run.
- `permissions: contents: read`, checkout with `persist-credentials: false`.
- `environment: tando-deploy`: put the four secrets in that environment and restrict it to the
  branch, so a workflow on another branch cannot read the key.
- setup-node with the npm cache (when there is a `package-lock.json`), `npm ci`.
- tando installed from `--repo` at `--ref`: a 40-hex commit, or a tag that the local tando checkout
  resolves to its commit (the job then fails if the tag moved). Branch names are refused.
- `tando deploy` with the secrets in that step's environment only. `tando deploy` runs the build
  from `tando.conf`, the same command as on the laptop.

## Pre-push hook: `tando ci hook`

Installs `.git/hooks/pre-push` (from `templates/pre-push`). When a push updates the configured
branch it checks out **the commit being pushed** into a temporary worktree, runs `npm ci` if there is
a lockfile and a build, and runs `tando deploy` there. It says, every time, that the deploy runs
before the push reaches the remote.

- Uncommitted changes: warned about and not deployed (`git config tando.hookdirty refuse` refuses
  the push instead).
- A failed deploy does not stop the push unless `git config tando.hookstrict true`.
- `TANDO_SKIP_HOOK=1 git push` or `git push --no-verify` skips it. `tando ci hook --remove`.
- It uses whatever credentials `tando deploy` finds (normally the admin's host entry).

## Keys

`tando ci setup` generates an ed25519 key pair on the laptop, sends the public half, prints the
private half once with `TANDO_HOST`, `TANDO_PORT` and `TANDO_KNOWN_HOSTS`, and deletes it. The
server keeps the public key, its fingerprint, who added it and when (`/opt/tando/ci/<app>/keys`, root
600) and the time of each key's last deploy. `tando ci ls` lists them (times in GMT). `tando ci revoke` removes a
key and ends every open session of that deploy user. `tando ci rotate` adds a new key and revokes all
others at once (update the secret first). `tando destroy` removes the deploy user, its sudo rule and
home.

## Known limits

- Limits are a watchdog, not a quota: an upload can pass the app's limit by what it writes in one
  check interval (one file is capped exactly). A key can fill the disk up to its app's limit.
- Since the integration, an app's metadata (`app.conf`, `state`, `activation`, `history.tsv`, the
  upload lease) is `root:tando-m-<app>` 640: readable by the app's user and its deploy user only
  (`tando-gate` adds the deploy user to that group); `activation.log` is root's. Other apps'
  metadata is closed to a deploy user even with code execution. Per-app metrics in
  `/var/lib/tando/metrics` (memory, cpu) and the alert state stay world-readable.
- The lease is per app: a key can hold its own app's lease for 15 minutes (`tando unlock` frees it).
- Revoking a key or rotating ends all sessions of that app's deploy user, including another key's
  upload in progress.
- `tando-d-<app>` can be 34 characters; Ubuntu accepts it, some other systems limit user names to 32.
- OpenSSH 9.8+ `PerSourcePenalties` blocks a source address for a while after a few failed logins.
  A CI job with a wrong or revoked key, run repeatedly from the same address, can therefore lock that
  address out (the admin too, if it shares it). The test suite turns penalties off on its own test
  server because it fails logins on purpose.

## Tests

`test/e2e-ci.sh` (server from `TANDO_TEST_NAME`/`TANDO_TEST_SSH_PORT`/`TANDO_TEST_HTTP_PORT`,
default `tando-test-ci` on 2301/8301; work directory `${T_WORK:-test/.e2e-ci-<server>}`). It runs
a copy of this checkout. Section 9 runs the security review's F3 script unchanged and checks
every other finding by the property its fix establishes.
Sections: key management, deploys with openrsync and GNU rsync 3.2.7 (a Linux container on the
server's network), forbidden verbs, ssh restrictions, revoke/rotate/destroy, attacks on another app
and on root, the generated workflow (YAML structure, actionlint 1.7.7, the job's steps run in a clean
ubuntu:24.04 container), and the pre-push hook against a local bare repository. Secrets reach the
containers as mounted files, never on a command line.
