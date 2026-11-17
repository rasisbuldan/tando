# Security review: restricted CI deploy keys (tando-gate)

14 Nov 2026. Adversarial review of the CI deploy path: `server/tando-gate`, the integrated
`server/tando-agent`, `lib/cmd-ci.sh`, `lib/deploy.sh`, `lib/common.sh`, `templates/`, against
`docs/CI.md` and `docs/history/REVIEW-v3.md`.

**Code reviewed.** A snapshot taken at 00:56 WIB, because `server/tando-agent` was being edited during
the review. The snapshot's cksums are in `test/.work-sec-ci/snapshot.cksum`
(tando-agent `571269943 72727`, tando-gate `1594548151 22473`). The snapshot's agent and client
**already carry** `docs/ci-integration.patch` (upload_sum, `upload_as`, `tando-gate admin remove`,
pkill on admin begin/unlock), so every finding assumes the patched agent. None of the findings
depends on a hunk of the patch being missing.

**Test bed.** My own server `tando-test-sec1` (Ubuntu 26.04 image from `test/server`, systemd 259,
OpenSSH with `PerSourcePenalties no`, rsync 3.4.1, Caddy upstream, uutils coreutils 0.10 as default
with GNU coreutils 9.7 also installed as `gnuinstall`). I used ssh 2391 and http 8391, because 2341 is
taken by another container (`tando-core1`). I tested GNU behaviour where it matters by pointing
`/usr/bin/install` at `gnuinstall`, and checked it against GNU 9.4 in a local `ubuntu:24.04` image.

**Apps.** `alpha` (node, the attacker's app; deploy key `key.alpha`), `bravo` (node, `data = data`,
env `SECRET_B`; the victim) and `cont` (recipe container, for F5). Setup is in
`test/.work-sec-ci/setup.sh` and `env.sh`. Every reproduction is a script under
`test/.work-sec-ci/attacks/`, and its recorded output is the `.out` file of the same name.

## Verdict

**No. Do not give this key to a CI system for a production app on a server that hosts anything
else.**

Starting from only app A's deploy key (or only a malicious dependency in A's build), I reached:

- **root**: F2b, with GNU coreutils, the default on Ubuntu 24.04.
- **another app's traffic, cookies and env secrets**: F1, F2, F2b, F5.
- **code execution as the deploy user**, which the design says never happens: F3.
- **a host-wide outage** of every app and every deploy key: F2 with uutils, the default on Ubuntu 26.04.

All of these were reproduced on a live server. The gate's own parsing (tokens, whitelist, sudo
argv, stdin parameters) held. The breaks are:

- around it: what the shipped code can reach (F1);
- what root does later with app-writable paths (F2);
- what the rsync protocol lets a hostile sender do inside the whitelisted options (F3).

A single-app server with "yes, with all critical and high findings fixed and re-tested" is the best
case. Even then, F9 stays: the key is equivalent to A's env secrets and data.

## Findings

| id | severity | starting point | summary |
|---|---|---|---|
| F1 | critical | A's release code (shipped by A's key; also from F3) | Caddy admin API on 127.0.0.1:2019 is reachable from every app unit: A rewrites Caddy's live config and takes over B's domain, cookies, credentials |
| F2 | critical (GNU coreutils, Ubuntu 24.04) / high (uutils, 26.04) | A's release code + A's key | root `install -d -o <app user> $D/shared/data` (and `shared/next-cache`, `shared/.cache`) follows a symlink A's code puts in its own `shared/`: any directory becomes A's (GNU) or mode 750 (uutils) |
| F2b | critical (GNU) | as F2, plus the admin's next `tando backup restore` of A | the restore chowns `/etc/systemd/system` to A and untars A's data into it as A: root |
| F3 | high (critical with F1) | A's key only | the gate's rsync receiver writes through a symlink planted in `incoming/` by an earlier session: arbitrary file write as `tando-d-A`; a unit in `/run/user/<uid>/systemd/user` gives code execution as `tando-d-A`, triggered by the gate's own `end_sessions` |
| F4 | medium | A's key | `end` kills every process of `tando-d-A` before checking the token, including the admin's own upload (which runs as `tando-d-A`); a loop blocks the admin's deploys of A |
| F5 | high | key of an app with recipe `container` | the scan allows relative `..` symlinks; root reads `incoming/image-ref` through one and returns the content in `message=`: any root-readable one-line token of another app |
| F6 | medium | A's key | resource exhaustion: 1 GiB on disk per 32 KB sent; unlimited parallel receivers per lease; with F3, files in `/dev/shm` (RAM) and `/tmp` that no revoke or cleanup removes |
| F7 | low | A's key | file names reach `history.tsv` and the activation file raw (newline, UTF-8 C1 controls); the client's `strip` keeps C1 |
| F8 | high (conditional) | a foothold as `tando-d-A` (F3) | revoke/rotate do not evict it: key ids are world-readable, root mode trusts any process of the uid that names a registered id, crontab/at are not cleared, pkill is single-pass |
| F9 | medium (design/doc) | A's key | the doc says the key cannot read A's env or shared data; the code it ships runs with both, already at pre-flight, even when the deploy "fails" |
| F10 | low | A's key | `AcceptEnv LANG LC_*` reaches the gate's bash before it sets `LC_ALL`; glibc loads locale data from an absolute path, which can point into `incoming/` |
| F11 | low | A's key, during revoke | `rsync_mode` checks the lease owner, not `key_active`; a session that slips past the single-pass pkill keeps uploading under a revoked key's lease |

### F1: Caddy's admin API is open to app code (critical)

- **Starting point:** code in A's release, shipped with A's key or by a malicious dependency. F3 gets
  the same access without any deploy.
- **Reproduction:** `attacks/f1-caddy-admin.sh`. The release's `server.js` sends, at start,
  `PUT http://127.0.0.1:2019/config/apps/http/servers/srv0/routes/0`, adding a route for
  `bravo.localhost` that proxies to alpha's port. It uses a plain `http.request`, because Node's
  `fetch` adds `Sec-Fetch-*` headers, which make Caddy demand an Origin. The script then deploys with
  alpha's key through `tando deploy`.

  ```
  [7/7] verify    ok   0.0s
  live in 1.4s  http://alpha.localhost:8391
  --- a visitor of bravo, with bravo's session cookie:
  PWNED: alpha answers for bravo.localhost:8391; cookie=bravo_session=s3cr3t env=alpha-secret-value
  ```

  It runs in the pre-flight unit too, so a release that never goes live still does it. From F3's
  deploy-user foothold the same API answered `HTTP 200` (`attacks/f3.out`).
- **Impact:**
  - B's (and every app's) traffic, sessions and logins go to A.
  - Through a `file_server` route, Caddy serves anything the `caddy` user reads: static releases of
    other apps (`root:caddy`) and, with `tls=auto`, the certificate private keys under
    `/var/lib/caddy`.
  - Caddy can write log files anywhere it can write.
  - The change lasts until the next `systemctl reload caddy`, and A's process can re-apply it at any
    time.
- **Fix:**
  - Put `admin unix//run/caddy/admin.sock` in the Caddyfile's global options, owned and only
    reachable by `caddy`/root, or `admin off` if reloads use `--force` restarts. Check that
    `systemctl reload caddy` still works.
  - Also give units a loopback egress policy per uid (nftables `meta skuid`). Other loopback
    services, such as other apps' ports, PostgreSQL on 127.0.0.1 and B's pre-flight port, are
    equally reachable today. REVIEW-v3 S9 asked for exactly this.
  - Add a test in `e2e-ci.sh` that runs code inside an app unit.

### F2: root follows an app-owned symlink in `shared/` (critical with GNU coreutils)

- **Starting point:** A's key deploys code that runs as `tando-A`, which owns
  `/opt/tando/apps/A/shared` (`ReadWritePaths`).
- **Code path:**
  - `link_shared` runs as root in every activation, before pre-flight, so a release that fails
    pre-flight still triggers it: `install -d -m 750 -o "$AU" -g "$AU" "$D/shared/data"` when `data`
    is set, and `"$D/shared/next-cache"` for every `next` app.
  - `build_venv` does the same with `"$D/shared/.cache"`, and `cmd_backup_restore` with
    `"$D/shared/data"`.
  - GNU `install -d` on an existing path applies owner and mode through a symlink. uutils 0.10
    applies the mode only. Checked: GNU 9.4 (ubuntu:24.04) and 9.7 change owner and mode; uutils
    changes the mode.
- **Reproduction:** `attacks/f2-install-follow.sh gnu|uutils`. The admin gives alpha `data = data`.
  Alpha's release then replaces `shared/data` with a symlink to the next target and exits, so
  pre-flight fails. The next key deploy's root `install -d` hits the target.

  GNU (`f2-gnu.out`):

  ```
    deploy v22: release 20261113-180354: failed; the running app was not touched
      /opt/tando/apps/bravo/shared tando-alpha:tando-alpha 750
    deploy v23: live in 1.4s  http://alpha.localhost:8391
      /opt/tando/apps/bravo/shared/data tando-alpha:tando-alpha 750
  alpha's URL now serves:
  /opt/tando/apps/bravo/shared/data/db.json: bravo-data-value
  ```

  uutils, target `/opt/tando/bin` (`f2-uutils.out`):

  ```
      /opt/tando/bin root:root 750
  tando-bravo.service: Main process exited, code=exited, status=203/EXEC
  /opt/tando/bin/tando-gate: Permission denied        (bravo's own deploy key)
  bravo URL after 15 s: bravo is unavailable [503]
  ```
- **Impact:**
  - GNU: A takes ownership of any directory: B's data and shared dirs (B is locked out of them), the
    `/var/backups/tando` tree (B's `data.tar.gz` and `db.dump` are 0644 inside 0700 dirs), and system
    directories. For root, see F2b.
  - uutils: mode 750 on any root-owned directory (`/opt/tando/bin`, `/usr/bin`, `/etc`). That stops
    every app and every deploy key, and on `/usr/bin` it also locks the admin out of the shell.
- **Fix:**
  - Create `shared/data`, `shared/next-cache` and `shared/.cache` once at `configure`. At activation,
    only check them (`[[ -d $p && ! -L $p ]]`) and fail otherwise; never chown/chmod them as root
    again.
  - If something must be created inside an app-owned directory, create it as the app user
    (`runuser -u $AU -- mkdir -p`), so the kernel applies the app's own rights.
  - Audit every root `install`/`chown`/`chmod`/`mkdir -p`/`-d` test on a path under `shared/`,
    `releases/<writable>` or `incoming/` (the same class appears in restore and in `ADATA`).

### F2b: the admin's restore of A becomes root (critical with GNU coreutils)

- **Starting point:** A's key, plus a routine admin action: `tando backup restore` of A's own
  backup.
- **Code path, in `cmd_backup_restore`:**
  1. `install -d -m 750 -o "$AU" -g "$AU" "$D/shared/data"` (F2): the symlink's target
     `/etc/systemd/system` becomes `tando-alpha:tando-alpha 750`.
  2. `as_app find "$ADATA" -mindepth 1 -delete` does not descend into a symlinked start point.
  3. `as_app tar -C "$ADATA" -xzf -` runs outside any sandbox, follows the symlink, and replaces
     root-owned unit files in the directory alpha now owns with the files alpha wrote into its own
     data before the pre-deploy backup.
- **Reproduction:** `attacks/f2b-restore-root.sh` (`f2b.out`). Alpha v31 writes
  `tando-bravo-backup.service` into its data. v32's pre-deploy backup archives it. v32, once live,
  points `shared/data` at `/etc/systemd/system`. The admin restores:

  ```
    tando backup restore 20261113-181644-predeploy
    restored 20261113-181644-predeploy; the data before the restore is in backup 20261113-181650-safety
    /etc/systemd/system tando-alpha:tando-alpha 750
  == the next daemon-reload (any tando up/configure, or a reboot) and bravo's daily backup timer:
  uid=0(root) gid=0(root) groups=0(root)
  SECRET_B="bravo-secret-value"
  ```
- **Impact:** root on the host. The admin's command reports success.
- **Fix:**
  - F2's fix.
  - Restore into a fresh root-created directory that the app user then fills
    (`runuser ... tar --no-same-owner` into it).
  - Swap it into place with `mv` as root, after checking that `shared/data` is a real directory
    (`-d && ! -L`) under the lock.

### F3: rsync write-through and code execution as the deploy user (high; critical with F1)

- **Starting point:** A's key only.
- **Code path:**
  - The gate checks the options and the destination, then runs the stock receiver. A sender may list
    `r/x` without listing `r`. The client used `-R --no-implied-dirs`, with the `R` and
    `--no-implied-dirs` removed from the remote command by an `-e` wrapper, so the command passes the
    whitelist: `rsync --server -re.iLsfxCIvu . /opt/tando/apps/alpha/incoming/`.
  - If `r` is already a symlink in `incoming/`, created in an earlier session with `-l`, rsync 3.4.1
    writes through it.
  - Deploy-user ssh sessions get a logind session, so `user@<uid>.service` runs. It loads units from
    `/run/user/<uid>/systemd/user/`.
  - The gate's own `end_sessions` (on `begin`, `end` or `activate`) stops that manager, and the next
    login starts it again with the planted units.
  - The author's test 6.5 used a normal client (which sends `d/` and replaces the link) against
    bravo's `incoming/` (blocked by permissions anyway), so this path was never exercised.
- **Reproduction:** `attacks/f3-rsync-escape-rce.sh`, which runs `f3-remote.sh` in the container
  with only `~/ka`, alpha's private key, plus the `-e` wrapper `f3-kssh`. `f3-run-remote.sh "<cmd>"`
  runs any command as `tando-d-alpha` through the same chain. Output (`f3.out`):

  ```
  == 1. plant incoming/r -> /run/user/992
  == 2. write r/systemd/... (no entry for r itself)
  == 3. 'end' (any token): the gate as root stops user@992 and kills the user's processes
  ok=1
  == 4. a new login within UserStopDelaySec: logind starts user@992, which loads the planted unit
  == result:
  uid=992(tando-d-alpha) gid=991(tando-d-alpha) groups=991(tando-d-alpha),995(tando-m-alpha)
  caddy admin from the deploy user: HTTP 200
  tando-d-alpha    10161 sleep 100000
  ```

  The simpler write (`/tmp/pwned-by-rsync`, owned by `tando-d-alpha`) is in the same scripts.
- **Impact:**
  - Arbitrary code as `tando-d-A`, the thing the gate's design rests on never happening. From there:
    - F1 without deploying anything;
    - files in `/tmp`, `/var/tmp` and `/dev/shm` that outlive the key (F6);
    - local kernel attack surface;
    - every root-mode verb without the key (F8);
    - reading A's metadata and the lease token.
  - It also lets the attacker race the activation from inside, but the copy checks held (see "held").
- **Fix:** run the receiver confined, not as a bare process:
  - **Preferred:** `rsync --server --daemon` through sudo, with a root-owned per-app module
    `path = /opt/tando/apps/A/incoming`, `use chroot = yes`, `uid = tando-d-A`, `read only = no`,
    `refuse options = ...`. The chroot makes write-through impossible.
  - **Or:** a transient unit, `systemd-run --pipe --wait -p User=tando-d-A -p ProtectSystem=strict
    -p ReadWritePaths=$D/incoming -p PrivateTmp=yes -p PrivateDevices=yes
    -p InaccessiblePaths=/run/user -p ProtectHome=yes`.
  - **In addition:**
    - mask `user@<uid>.service` for deploy users (no user manager);
    - add `cron.deny`/`at.deny` entries;
    - with `use chroot`, rsync's defaults also handle `..` and absolute symlink targets.

### F4: the key's `end` kills the admin's upload (medium)

- **Starting point:** A's key.
- **Code path:** `root_mode end` calls `end_sessions` before `$AGENT end` compares the token, and
  `cmd_end` answers `ok=1` whatever the token. Since the integration patch, the admin's own rsync runs
  as `tando-d-A` (`--rsync-path="sudo -n -u tando-d-A rsync"`).
- **Reproduction:** `attacks/f4-end-kills-admin-upload.sh` (`f4.out`):

  ```
  tando-d-alpha  rsync --server -ltprcze.iLsfxCIvu --bwlimit=2000 --delete . /opt/tando/apps/alpha/incoming/
  == key: end with a token that is not its own
  rsync error: unexplained error (code 255) at io.c(849) [sender=3.4.1]
  admin rsync exit status: 255
  ok=1
  ```
- **Impact:** the key can stop every admin deploy of A, for example to keep its own release live
  while the admin tries to replace it, until the admin revokes the key.
- **Fix:**
  - Verify the token, and that the lease is `ci-<this key>`, before ending sessions.
  - Kill only what this key started: give each gate rsync its own scope or cgroup and stop that, not
    the uid.
  - Have `cmd_end` say whether it removed a lease.

### F5: root reads any one-line file through `image-ref` (high)

- **Starting point:** the deploy key of any app with recipe `container`. Podman does not need to
  work.
- **Code path:**
  - `scan_upload` rejects only `-lname '/*'`, so `image-ref -> ../../bravo/shared/data/api-token`
    passes.
  - `import_image` runs `[[ -f $D/incoming/image-ref ]]` and `ref=$(< ...)` as root, both following
    the link.
  - The regex accepts most tokens (hex, base64url, JWT-like `a.b.c`), and
    `fail "podman pull $ref failed"` stores it in `message=`, which `deploy-status` passes to the
    key.
- **Reproduction:** `attacks/f5-image-ref-read.sh` (`f5.out`):

  ```
  -rw------- 1 tando-bravo tando-bravo 28 ... /opt/tando/apps/bravo/shared/data/api-token
  message=podman pull sk_live_51HbravoS3cretT0ken failed
  ```

  With podman installed, the secret is also sent to a registry as an image name.
- **Impact:** cross-app (and root-only) secret disclosure, for anything that fits
  `^[A-Za-z0-9][A-Za-z0-9._/:@-]*$`.
- **Fix:**
  - Refuse every symlink in a container upload. More generally, have the scan reject symlinks whose
    target, resolved within `incoming/`, leaves it.
  - Read `image-ref` with `[[ -f $f && ! -L $f ]]`, ideally as the deploy user.
  - Never echo uploaded content in messages.

### F6: resource exhaustion (medium)

- **Starting point:** A's key.
- **Reproduction:** `attacks/f6-dos.sh` and `f6c-parallel.sh` (`f6.out`):

  ```
  Total file size: 1,073,741,824 bytes
  Total bytes sent: 32,893                 (-z, a zero/sparse file; written in full without -S)
  -rw-r--r-- 1 tando-d-alpha tando-d-alpha 104857600 ... /dev/shm/ram.bin
  Shmem: 120852 kB -> 223268 kB              (F3 write into RAM-backed tmpfs)
  rsync receivers of tando-d-alpha running at once: 24   (12 sessions under one lease)
  ```

  The container's btrfs stored the 1 GiB in 403 MiB; ext4 stores all of it.
- **Impact:**
  - The disk fills at network speed times about 30,000. The doc's "known limit" assumes the upload
    costs bandwidth; it does not.
  - Memory goes to many receivers with large file lists.
  - With F3, `/dev/shm` takes up to half the RAM and stays after revoke: nothing tando runs cleans
    files owned by the deploy uid.
  - The activation's 3 GB/200,000-file check comes after the damage.
- **Fix:**
  - A quota or a size-capped filesystem for `incoming/` (project quota, or a per-app loop or XFS
    mount).
  - `--max-alloc` and `--max-size` added by the gate on the server side.
  - One receiver per lease: an `flock` on a per-lease lock in `rsync_mode`.
  - A `user-<uid>.slice` drop-in with `MemoryMax`/`TasksMax` for deploy users.
  - On revoke, `find / -xdev -uid <uid> -delete` across the tmpfs mounts.

### F7: raw file names in history and activation files (low)

- **Starting point:** A's key.
- **Reproduction:** `attacks/f7-filename-injection.sh` (`f7.out`). A file named
  `.env<U+009B>2J<U+009D>0;tando: all good<U+009C>\n<forged row>` fails the release with
  `secret file in release: <name>`.
- **Result:**
  - The newline splits the row in `history.tsv`. Tabs are replaced, so the forged line shows only as
    a junk row in `tando history`.
  - The C1 bytes are stored raw. `lib/common.sh` `strip` removes C0 controls but not UTF-8 C1, so any
    view that prints `message`/note text through `agent_raw` passes them to the terminal. I found no
    such view today, but `deploy-status` `message=` is one field away.
  - A newline in `message=` also injects keys into `$D/activation`. I found no root reader that uses
    them unsafely: `tando-watch` only uses `started` while a phase is running, and a new activation
    rewrites the file first.
- **Fix:**
  - Pass every path in agent `fail` messages through a `clean()` like the gate's.
  - Make `row()` replace newlines.
  - Add `\302[\200-\237]` to the client's `strip`, as `lx_clean` already does.

### F8: revocation and rotation do not evict a foothold (high, conditional on F3)

- **Starting point:** code running as `tando-d-A` (F3).
- **Code path:**
  - Root mode accepts any process with `SUDO_UID` of the deploy user that names a registered key id.
  - Key ids are in the 0644 `authorized_keys`, and the lease token is in `$D/upload` (0640, group
    `tando-m-A`, which includes the deploy user).
  - Revoke and rotate do a single `pkill -KILL -u`, which a fork-hopping process can outrun. They
    never touch `crontab`/`at` jobs (cron is in Ubuntu Server's default install; `crontab` is
    setgid, with no `cron.allow`) or files in tmpfs.
- **Reproduction (partial; the image has no cron):** `f3-run-remote.sh` ran, as `tando-d-alpha`
  with no key, `printf 'keyid=<id from authorized_keys>' | sudo -n tando-gate root alpha begin`,
  and the lease was taken (`f8.out`):

  ```
  key id read from the world-readable authorized_keys: f7bdc3ad1a5d
  who=ci-f7bdc3ad1a5d   token=18190b3e-...   (written by that call)
  tando-d-alpha : ... COMMAND=/opt/tando/bin/tando-gate root alpha begin
  ```
- **Impact:** after `tando ci revoke`/`rotate`, a cron job of `tando-d-A` reads the new key id and
  keeps deploying A. It can also write `incoming/` during the admin's next upload, since the admin's
  `begin` uses a single pkill.
- **Fix:**
  - Fix F3 first.
  - Deny cron/at to deploy users, and on revoke run `crontab -r -u`, `atrm`,
    `loginctl terminate-user` and `systemctl stop user-<uid>.slice` (cgroup, not pkill), and clean
    tmpfs files.
  - Bind root mode to the ssh session, not to a guessable id. For example, use
    `ExposeAuthInfo yes` and have root mode read `SSH_USER_AUTH` of the session's sshd process
    (`/proc/<sshd pid>/environ`, root-readable) and compare the fingerprint with the keys list.
  - Make `authorized_keys` 0640 root:root (sshd reads it as root).

### F9: the key reads A's env and data (medium, design/documentation)

The CI.md table says the deploy key cannot "read A's env, shared data or releases". It ships code
that runs as `tando-A` with `EnvironmentFile=$D/env` and `shared/` read-write. That code already runs
in the pre-flight unit, so even a deploy shown as "failed; the running app was not touched" can send
everything out. F1's output shows `env=alpha-secret-value`.

- **Fix:**
  - State in CI.md that a deploy key is equivalent to A's secrets and data.
  - Recommend separate credentials for CI-deployed apps.
  - Consider an egress policy for pre-flight units.

### F10: client locale variables reach the gate's bash (low)

`sshd -T -C user=tando-d-alpha` shows `acceptenv LANG`, `LC_*`, `COLORTERM` and `NO_COLOR`.
`LC_ALL=/opt/tando/apps/alpha/incoming/x ssh -o SendEnv=LC_ALL ...` printed
`bash: warning: setlocale: LC_ALL: cannot change locale (/opt/tando/apps/alpha/incoming/x)`.

So glibc parses locale files from a directory the key fills, in the deploy user's bash, before line
23 sets `LC_ALL=C`. No exploit is known. It only matters if glibc's locale loader has a memory-safety
bug, and it runs as the deploy user (sudo drops `LC_*` values that contain `/`).

- **Fix:** an `AcceptEnv` override in the `Match User tando-d-*` block (verify with `sshd -T` that the
  list is empty), or a small compiled wrapper as the shell.

### F11: rsync does not check that the key is still registered (low)

`rsync_mode` accepts any session whose key id equals the lease's `who`. It does not call
`key_active`. A session that survives the single-pass pkill during `revoke` (a race) keeps uploading
until the lease expires. It cannot activate.

- **Fix:** check `key_active` (through a root-readable marker) in `rsync_mode`, and end the lease of a
  revoked key on revoke.

## What held (so the next reviewer can skip it)

- **Request parsing:** the 300-character limit, the character whitelist, word splitting with `set -f`,
  verb and app matching, `-c` handling as the login shell, and `info`. No shell metacharacter or
  option reached a shell.
- **rsync options:**
  - `--sender`, `-e`, every long option except the six allowed, `--`, a bare `-`, and options
    smuggled in combined short flags are refused.
  - The `e.<caps>` suffix allows letters only.
  - The destination must be exactly `incoming/`, and options after it are still checked.
  - `--bwlimit` is refused too, which is harmless.
  - The receiver itself, not the options, is the problem (F3).
- **sudo:**
  - Exact argv per app, `env_reset`, no extra arguments, `SUDO_UID`/passwd checks, key id checks,
    and the stdin parameter whitelist with length limits.
  - Root mode for another app or from the admin is refused.
  - Locale variables with `/` are dropped by sudo.
- **ssh restrictions:** `restrict` and the Match block (no pty, forwarding, agent, X11, tunnel, sftp
  or scp), and the forced command applies to subsystems.
- **The key activation's freeze:**
  - `frozen` is written before `end_sessions`, so a gate that checked the lease earlier is alive and
    killed.
  - Multiplexed channels on one connection are siblings, not ancestors, and are killed.
  - `/proc/<pid>/stat` parsing is not fooled by a `) Z` in `comm`.
  - A fork-hopping process makes `end_sessions` fail closed (the activation is refused), not pass.
- **The root copy:**
  - `cp -a --no-dereference` plus checks on the copy (symlinks resolve inside, no special files or
    hardlinks, no `.env*`, chmod/chown).
  - `upload_sum` uses ctime, which users cannot set, so renaming a directory away and back during
    the copy is detected.
  - `protected_hardlinks` stops hardlinks to other users' files.
  - Setuid bits are stripped after upload and again on the copy.
- **Client parsing:** `kv_read` whitelists, nothing is evaluated, and the `ci ls` fields are fixed
  formats. The logs path cleans C0 and C1 (`lx_clean`). The pre-push and workflow templates were not
  in my threat model beyond reading them.
- **Linger:** `loginctl enable-linger` as the deploy user was denied (no polkit), so F3's foothold
  dies with the user manager in this image.

## What I could not test

- Cron and at persistence (F8): the image has neither. The claim rests on Ubuntu Server's default
  `cron` package and its PAM/setgid behaviour.
- Caddy with `tls=auto`, so reading certificate keys through F1 is argued, not shown. Also not tested:
  `admin` over a unix socket as a fix.
- Real memory exhaustion with huge file lists, and a full disk. I stopped at 1 GiB and 100 MiB on a
  shared laptop VM.
- glibc locale parsing of hostile files (F10).
- Whether uutils `cp -a`, the default on 26.04, creates destination files with their final modes
  before `chown`. If so, a reader with F3's foothold could see copied files during the window before
  the activation fails. I did not test it.
- A real GitHub runner, and the pre-push hook under attack.

## Residual risks inherent to the design

- A key that ships code is A's env and data (F9). Only egress control and separate credentials
  reduce that.
- Anything on loopback is reachable from app code unless a uid-based firewall exists (F1, other apps'
  ports, PostgreSQL).
- A key can hold A's lease and redeploy at will, so the admin cannot "win" against a live key except
  by revoking it.
- The deploy user's uid exists on the host with a logind session per login. Any code-execution bug in
  ssh, PAM, bash or rsync becomes a foothold whose rights are the same as the key's.
- Shared resources (disk, memory, pids, journal) need quotas that tando does not set.

## Cleanup

The server `tando-test-sec1` was removed with `test/server/down.sh`. No product files were edited.
