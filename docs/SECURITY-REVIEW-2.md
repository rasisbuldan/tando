# Security review 2: compromised apps, CI keys, adopt, and the laptop

14 Nov 2026. This is an adversarial follow-up to `docs/SECURITY-REVIEW-CI.md` (F1–F11). The
developer says F1, F2, F2b, F5, F7 and the gate findings are fixed. I re-ran the earlier attacks and
then attacked the six threat models in the brief.

**Code reviewed.** I worked from a snapshot taken at the start, in `test/.work-sec2/tree/` (no
`.git`, no `test/.*`). Its checksums are in `test/.work-sec2/snapshot.cksum`:

| file | cksum | size |
|---|---|---|
| tando-agent | 4156298484 | 80853 |
| tando-gate | 2993679088 | 36250 |
| tando-adopt | 1757168803 | 43658 |
| tando-logs | 209214973 | 38083 |
| tando-watch | 2626509548 | 46844 |

The snapshot already contains the CI integration (tando-gate, the confined receiver, `tando-m-<app>`
groups, the nftables rules, and Caddy's admin API on a unix socket).

**Test bed.** Two servers, both built from `test/server`:

- `tando-sec2`: Caddy 2.11.9, ssh 2260, http 8360.
- `tando-sec2b`: `TANDO_TEST_CADDY=ubuntu`, Caddy 2.6.2, ssh 2262, http 8362. This is the real
  target's Caddy version.

Both run Ubuntu 26.04 with systemd 259 and rsync 3.4.1. In that image cp, mv and rm are GNU 9.7, and
chown, chmod and install are uutils 0.10. Both servers were removed at the end.

**Apps.** `setup.sh` creates the same two apps on each server; `env.sh` has the helpers.

- `alpha`, the attacker. Its release has a backdoor: `POST /__x` runs bash as `tando-alpha` inside
  its own unit (helper `x`). It also has a job, `job.tick` every 20 s, that runs `$HOME/jobcmd`.
- `bravo`, the victim. It has `data = data`, an env secret `SECRET_B`, and a data file.

Each app has a deploy key from `tando ci setup`.

**How to read the claims.** Every attack is a script under `test/.work-sec2/attacks/`. Exit 0 means
the attack was blocked, 1 means it succeeded, 2 means it was inconclusive. The recorded output is the
`.out` file with the same prefix. The earlier review's scripts were re-run from
`test/.work-sec2/prev/`, pointed at my environment. In this document:

- **[ran]** means I ran it against a live test server.
- **[read]** means I inferred it from the code without running it.

## Verdict

**A compromised app: no, it is not contained. A stolen CI key: mostly yes.**

A compromised app can do the following, all demonstrated on a live server:

- **Take over another app's traffic.** A scheduled job of A has no socket-bind limits, so it can
  listen on any port. It waits for B's port to free up during any B restart or deploy, binds it
  first, and serves B's visitors with their cookies (A01). The same trick refuses all of B's deploys
  (A02).
- **Survive `tando destroy`.** A running job is never stopped. The user deletion fails silently, the
  nftables rules for the uid are dropped, and the process keeps running with unrestricted loopback
  access (A03).
- **Evict B's logs.** It can write into B's journal namespace and push B's own history out (A15).
- **Use memory beyond its cap.** It can park RAM outside its MemoryMax in the host-wide `/dev/shm`
  (A16).
- **Leave files for the next app.** Its leftovers become the property of whichever app later reuses
  its uid (A16).

On a host that adopted hand-made services, two more paths open:

- An adopted app can load another app's secrets into its own environment through its own env file
  (A14).
- A user who can edit its hand-made unit file gets root when the admin runs the read-only
  `tando adopt plan` (A17).

A malicious or compromised server runs code on the admin's laptop through `tando ls`, `tando status`
and `tando top` (A11, A12).

The CI deploy key held against everything I tried: the gate's parsing, sudo binding, the confined
receiver, the freeze before activation, and revocation. The one open path is disk amplification
(A09): about 32 KB on the wire becomes 1 GB per release kept, with 5 releases kept plus `incoming/`.
F1, F2, F2b, F3, F4, F5, F7, F8, F10 and F11 are fixed. I did not reach root from an app, a key or the
network without the adopt preconditions.

## Findings

Severity is judged for the threat model named in each row. Fix locations use the snapshot's
function names.

| id | sev | threat | finding | shown | reproduction | proposed fix |
|---|---|---|---|---|---|---|
| N1 | **critical** | 1 | Job units have no `SocketBindAllow`/`SocketBindDeny`, because `sync_jobs` runs `props \| grep -v '^SocketBind'`. A's job listens on B's port the moment B restarts (deploy, `tando restart`, `env set`, reboot). Caddy then sends B's visitors, cookies and logins to A. A's listener also answers B's health checks, so B's deploy can pass verification while A is the one serving. B's own process crash-loops into `down` (503). | **[ran]** `HIJACKED by 993 (tando-alpha job): bravo.localhost:8360/account cookie=bravo_session=s3cr3t` | `attacks/a01-job-port-hijack.sh` (`a01.out`) | `server/tando-agent` `sync_jobs` and `server/tando-adopt` `sync_jobs_one`: keep `SocketBindDeny=any` (a job needs no listener) and drop only `SocketBindAllow`. Also, in `probe` and `via_caddy`, check that the process listening on the port belongs to the app's own unit (`ss -Hltnp` pid, then that pid's `/proc/<pid>/cgroup`) before calling the app healthy. |
| N2 | medium | 1 | The same gap lets A's job hold B's pre-flight port (port + 100). Every deploy of B is then refused with `pre-flight port 4201 is in use`. | **[ran]** | `attacks/a02-job-preflight-port.sh` (`a02.out`) | Same as N1. |
| N3 | **high** | 1 | `cmd_destroy` disables the job *timers* with `--now` and deletes the unit files, but never stops a running job *service*. Type=oneshot has no start timeout. `userdel` then fails ("user is used by process"; the error is discarded), so the user and uid stay. `fw_sync` drops the uid's nftables rules, so the leftover process reaches every app's port. It runs until the host reboots. Re-creating an app with that name is also blocked ("user exists but was not created by tando"). | **[ran]** `user: tando-gamma:x:987` · `node job.js` still running · `nft rules mentioning its uid: 0` · `connected to bravo:4101 -> HTTP/1.1 200 OK` | `attacks/a03-destroy-survivor.sh` (`a03.out`) | `server/tando-agent` `cmd_destroy`: (1) run `systemctl stop 'tando-<app>-*.service'` and `systemctl kill --signal=KILL` on every `tando-<app>*` unit before deleting any unit file; (2) loop `pkill -KILL -u tando-<app>` until `pgrep -u` is empty, as `evict_user` does for deploy users; (3) check `userdel`'s status and fail loudly; (4) only then run `fw_sync`. Better still: give `fw_sync` a final catch-all that rejects the whole tando port range for every uid in the tando system-uid range that has no app. |
| N4 | **high** | 3 | The laptop CLI does bash arithmetic on fields the server sends. Bash expands `a[$(cmd)]` subscripts inside `$(( ))`, so this is code execution. Two places: `lib/cmd-top.sh` `top_graph_hist` (`$(($1 / G_BK))` on an `m` row; reached as soon as `tando top` opens) and `lib/views.sh` `cpu_pct` (`$(( $2 / 10000000 / $3 ))` on the app row's cpu field; reached by `tando ls`/`status`). A compromised server, or anything that controls the agent's output, gets code execution on every admin laptop that connects. This contradicts ARCHITECTURE.md's claim that server output is never evaluated. | **[ran]** marker files `PWNED-by-top` and `PWNED-by-ls` were created on the laptop. The "malicious server" was simulated by wrapping `tando-metrics`/`tando-agent` on the test server. | `attacks/a11-top-arith-rce.sh`, `attacks/a12-ls-arith-rce.sh` (`a11.out`, `a12.out`) | `lib/cmd-top.sh` `top_parse`: check `is_num` on v1–v3 of `m` rows (and v2–v8 of `host`/`app` rows) before use. `lib/views.sh` `cpu_pct`: check `is_num "$2"`. Audit every `$(( ))`, `(( ))`, `[[ -gt ]]` and `printf -v` on row fields. A shared `num()` helper that maps anything non-numeric to 0 keeps this from coming back. |
| N5 | **high** (with adopt) | 6 + 1 | An adopted app keeps its hand-made env file (`app.conf env_file=`). The tando unit loads it with `EnvironmentFile=`, which PID 1 reads as root. When that file sits in a directory the app's user owns (the usual `/srv/<app>/.env`), the app replaces it with a symlink to `/opt/tando/apps/bravo/env`. At its next restart, systemd loads bravo's secrets into the app. | **[ran]** `shop's process environment, read as shop: SECRET_B=bravo-secret-value` | `attacks/a14-adopted-envfile-symlink.sh` (`a14.out`, run on tando-sec2b) | `server/tando-adopt` `adopt_scan`: block unless the env file and every directory above it are root-owned and not writable by group or others. Preferably, `cmd_adopt_run` copies the values into `$D/env` (root:tando-<app> 640, the normal path) and drops `env_file`, keeping the original file untouched for undo. |
| N6 | **high** (conditional) | 6 | `adopt_scan` → `unit_env` runs `eval "w=($(systemctl show -P Environment …))"` as root. It escapes only `` ` ``, `$` and `\`. systemctl prints an embedded quote as `\"`, the escaping turns that into `\\"`, and the quoted word closes. One `Environment=` line can then end the array and run commands. This runs during the read-only `tando adopt plan`, even when the plan is blocked, and again in `adopt-run`. Precondition: the unit's `Environment=` is writable by a non-root user. I used a unit file in the app's own directory installed with `systemctl link`, and the next `daemon-reload` (every `tando up`) loads it. | **[ran]** `tando adopt plan shop2` → `/root/pwned-by-adopt-plan: uid=0(root)` | `attacks/a17-adopt-plan-eval.sh` (`a17.out`, tando-sec2b) | `server/tando-adopt` `unit_env`: no `eval`. Parse `systemctl show` output with a small unquoting reader (`\"` `\\` and space-separated quoted words), or read the `Environment=` lines of `FragmentPath` directly. Also, in `adopt_scan`, block when `FragmentPath` (resolved) or any parent directory is not root-owned and non-writable. |
| N7 | medium | 5 | On Caddy 2.6.2, request logs are mapped by exact Host (`logger_names`), and the Caddyfile adapter sets `skip_unmapped_hosts`. A request with `Host: <site>:443`, or any port, still reaches the site but is never logged. Any client on the internet can use or attack an app without showing in `tando requests` or the alert statistics. Caddy 2.11.9 logs it. A test server with `public_port` logs nothing at all on 2.6.2, which hides the problem in tests. | **[ran]** 2.6.2: `Host with :443: answer [hello v1 …], log lines 3 -> 3`; 2.11.9: `4 -> 5` | `attacks/a07-host-port-unlogged.sh` (`a07b.out` 2.6.2, `a07.out` control) | `server/tando-agent` `write_caddy`: on Caddy < 2.7, refuse such requests before any handler, for example `@hostport header_regexp Host :[0-9]+$` → `respond 400`. Alternatively, list the `:80` and `:443` variants as extra site addresses. `tando doctor` should warn on Caddy < 2.7. |
| N8 | medium | 1 | Every app can write into every other app's journal namespace. The sockets `/run/systemd/journal.tando-<app>/{socket,dev-log}` are 0666 and visible inside the sandbox. `tando logs` hides the forged lines because it filters on `_SYSTEMD_UNIT`, but they fill B's cap (`log_max`) and evict B's real history. They also inflate B's line counts in `log-stats`, `status` and `top`. | **[ran]** 1600 lines from alpha: `bravo's oldest own line after:` (empty), and bravo's namespace went from 6.2M to 49.7M | `attacks/a15-journal-namespace-flood.sh` (`a15.out`) | `server/tando-agent` `props`: emit `InaccessiblePaths=-/run/systemd/journal.tando-<other>` for every other app (rendered at configure), or `TemporaryFileSystem=/run/systemd/journal.tando-*`-style isolation. `server/tando-logs` `app_stats` should count only the app's own units. |
| N9 | medium | 1 | `/dev/shm` is the host's for every unit; `PrivateDevices=yes` keeps the host `/dev/shm`. It is shared by all apps, and destroy never cleans it. Uids are reused: a file left by destroyed app `gamma` (uid 989) now belongs to the later app `cont`. Shmem charged to a unit leaves its MemoryMax when the unit restarts. Alpha, capped at 192 MB, parked 451 MB of RAM by crashing between writes; repeating this exhausts host RAM. | **[ran]** `/dev/shm/x owner now: tando-cont` · `451 MB parked … capped at 192 MB` | `attacks/a16-devshm-shared.sh` (`a16.out`) | `server/tando-agent` `props`: add `PrivateIPC=yes` and `TemporaryFileSystem=/dev/shm:size=…` (a per-unit tmpfs, charged to and freed with the unit). `cmd_destroy` should delete the uid's files in `/dev/shm`, `/tmp` and `/var/tmp`, and should not hand a destroyed app's uid to the next app (`useradd -u` from a counter, or never `userdel`, only lock). |
| N10 | medium | 2 | Disk amplification (F6, partly open). The gate caps `incoming/` at 3 GB, 1 GB per file. But `incoming/` persists, every activation copies it into `releases/<id>`, failed releases count towards `KEEP=5`, and compressible non-sparse data costs about 1/30,000 on the wire. | **[ran]** a 1000 MiB file of `A`: `Total bytes sent: 32,168`, then `209` for the second deploy; `incoming 1.1G`, `releases 2.1G` (du). df grew only 445 MiB because the test VM's btrfs compresses and reflinks. On ext4, du is the cost: about 6 GB per GB-file per key, 18 GB at the cap. | `attacks/a09-disk-amplification.sh` (`a09.out`) | `server/tando-agent`: in `fail`, `rm -rf` the release directory of a failed activation (keep only verified releases in `KEEP`). In `server/tando-gate` `scan_upload`/`limits`, cap `incoming/` + `releases/` together per app. Consider emptying `incoming/` after a CI activation. |
| N11 | low | 5 | The skip_log rule is "UA `tando-probe` and remote 127.0.0.1/::1". A remote client cannot use it: XFF was ignored and the request logged on both Caddy versions. Any local process can, including a compromised app sending requests to *another* app through Caddy, and those requests leave no line in that app's request log. | **[ran]** both versions: `3 requests from alpha's process to bravo with UA tando-probe: log lines 4 -> 4` | `attacks/a06-probe-ua-unlogged.sh` (`a06.out`, `a06b.out`) | `server/tando-logs` `cmd_caddy_log`: tie the skip to a secret header known only to root, for example a random `X-Tando-Probe` token in `/opt/tando` (root 600) that `probe`/`tando-watch` send, instead of a public UA. |
| N12 | medium | 6 | `adopt_scan` blocks only `User=root`. It accepts users with a login shell, sudo, `adm` (reads `/var/log/tando/audit.log` and journals), `docker`, a crontab, or users shared with other services (`www-data`). tando then advertises sandboxing and per-uid loopback rules for a user that has other ways out, or that other services need: nftables would cut nginx-as-www-data off from the app ports. | **[read]** | (none) | `server/tando-adopt` `adopt_scan`: block (or require `--accept-user`) when the user has a valid shell, is in `sudo`/`adm`/`wheel`/`docker`/`lxd`, owns processes outside the unit, or is the `User=` of another unit. |
| N13 | low | 1 | `as_app` runs backup `tar` (and `sqlite3`) as the app user *outside* its sandbox. If `shared/data` is a symlink (the app can make it one), `backup_take` archives the target with the app user's rights. That includes paths the unit hides (`ProtectHome`, the real `/tmp`). A restore then hands the copy to the app. This bypasses the sandbox's read view, not unix permissions. | **[read]** The F2b re-run did take a `safety` backup while `shared/data -> /etc/systemd/system`; I did not inspect its contents. | (none) | `server/tando-agent` `backup_take`: `shared_ok data` before archiving (refuse a symlinked data directory), and run tar in a transient unit with the app's sandbox properties rather than plain `runuser`. |
| N14 | low | 3 | The client's `strip` replaces UTF-8 C1 (`\302[\200-\237]`) but passes single-byte C1 such as a raw `0x9b` (8-bit CSI). App log lines reach the admin through `deploy-status` `log=` lines (`app_journal -o cat`, not sanitized on the server). Modern UTF-8 terminals ignore a lone `0x9b`; an 8-bit terminal does not. | **[ran]** for the filter (`printf 'a\x9bd' \| strip` keeps byte 233); terminal effect **[read]** | (none) | `lib/common.sh` `strip`: also drop `[\200-\237]` bytes that are not part of a valid UTF-8 sequence. `server/tando-agent` `cmd_deploy_status`: pass `log=` lines through `san_v`. |
| N15 | low | 4 | A repository's `tando.conf` chooses the target `host` and `app`, any local `out` path (absolute or `..`) and the `build` command, all without confirmation. A malicious repo or PR retargets a deploy at another app on the same server, or publishes local files with `recipe = static`. This is by design, since `build` runs the repo's code anyway, but it is not stated. | **[read]** | (none) | `lib/build.sh` `stage`: refuse an `out` outside the repo. `lib/deploy.sh`: show `host/app` and ask once when `tando.conf` names an app or host that differs from the last deploy from this checkout. Document it in CI.md / README. |

Root-run file operations I reviewed (cp, mv, rm, chown, chmod, install, tar, rsync, redirects): apart
from N3, N5, N6, N9 and N13 above, every root write into an app- or key-writable directory now
goes through `as_app`, a confined unit, `-hP`, `mv -T`/`rename`, or a check on the root-owned copy. The
ones I raced are listed under "What held".

## Earlier findings F1–F11

| id | status | evidence |
|---|---|---|
| F1 Caddy admin API | **fixed** | `prev/f1.out`: `caddy admin connect ECONNREFUSED 127.0.0.1:2019`, and bravo still answers `hello v1`. `a04.out`: 127.0.0.1:2019 and `unix:/run/caddy/admin.sock` both refused from alpha (`/run/caddy` is 0750 caddy). |
| F2 root `install -d` through a symlink in shared/ | **fixed** | `prev/f2-gnu.out` (GNU install forced): bravo's dirs stay `tando-bravo 750`. The deploys fail with `shared/data is not a directory of tando-alpha (a symbolic link?)`. The uutils variant uses the same code path (`ensure_shared`/`shared_ok`) and was not re-run. |
| F2b restore into a symlink → root | **fixed** | `prev/f2b.out`: `shared/data is not a directory of tando-alpha … nothing restored`, `/etc/systemd/system root:root 755`, no `/root/pwned-by-alpha`. See N13 for the safety backup taken just before. |
| F3 rsync write-through / RCE as deploy user | **fixed** | `prev/f3.out`: `mkdir … incoming/r/systemd failed`, no file and no process. `a08.out`: the single-session variant (link and file in one file list) for five targets including `../../bravo/shared/data` and `/run/user/<uid>` wrote nothing outside `incoming/`. |
| F4 key's `end` kills admin upload | **fixed** | `f4.out` (adapted to the confined admin receiver): wrong-token `end`, `begin` and a key rsync are all refused; `admin rsync exit status: 0`. |
| F5 image-ref read through a symlink | **fixed** | `prev/f5.out`: the escaping link is dropped by the receiver (`nothing uploaded`). By code reading, container uploads refuse every symlink and `image-ref` must be `-f && ! -L`. |
| F6 resource exhaustion | **partly open** | Held: a single 1100 MiB sparse file is stopped (`File too large`), and a second receiver per lease is refused (`a10.out`). Open: N10 (a09). |
| F7 file names in history and activation | **fixed** | `a10.out`: newline, CSI/OSC C1 and ESC become `?` in `history.tsv` and `message=`, with no forged row. |
| F8 revoke does not evict a foothold | **fixed** (as far as testable) | `a10.out`: root mode called from a deploy-user process outside a key's ssh session is refused (`not called from a deploy key's ssh session`), and `authorized_keys` is unreadable to the deploy user. By code reading, `evict_user` covers cgroups, cron, at, IPC and tmp files. The image has no cron, so that part is untested. |
| F9 key equals A's secrets (docs) | **fixed** | `docs/CI.md` now says so ("What this means for secrets (F9)"). |
| F10 client locale reaches gate bash | **fixed** | `a10.out`: `LC_ALL=/opt/tando/apps/alpha/incoming/x` sent with `SendEnv` produced no setlocale warning on the server. The drop-in has `SetEnv LC_ALL=C LANG=C`. |
| F11 rsync without `key_active` | **fixed** | **[read]** `root_mode` checks `key_active` before every verb, including `receive`, and revoke ends the lease (`end_lease_of`). |

## What held

All of these are **[ran]** unless marked otherwise. Script references are in `test/.work-sec2/attacks/`.

**Loopback isolation (a04).** From an app unit, every target was refused:

- bravo's port over 127.0.0.1, `[::1]`, 127.0.0.2 and the container's own address;
- bravo's pre-flight port;
- 127.0.0.1:2019, and Caddy's unix socket.

The nftables rules use `inet` and `oifname lo`, so v4 and v6 are both covered.

**Gate request handling (a10).** All of these were refused:

- a shell, `sftp`;
- `--sender`, `-e.L`, `--info=all`;
- another app's `incoming/`;
- `status bravo`, `env-ls`, `logs`;
- `;id`, and a direct `tando-gate root … receive`.

Also held: one receiver per lease; the per-file size limit; root mode's binding to the key's ssh
session; the deploy user's inability to read its key ids; client locale.

**Confined receiver (a08 and the F3 re-run).** No write outside `incoming/`, even in one session.
rsync 3.4 refuses to create through the link, and the unit is read-only elsewhere.

**Admin's upload versus the key (f4).** None of the key's verbs stopped or joined the admin's
upload.

**Root `chown -RhP` / `chmod -R` (uutils 0.10) against a racing symlink swap (a05).** No hit in 400
rounds. uutils `chown -R` without `-h` also does not follow links found during the walk (one-off
test).

**GNU cp 9.7 `cp -a --no-dereference` against a racing swap (a13).** This held after four
strategies, the last on a tmpfs so that cp really copies:

- random toggling;
- an atime trigger;
- `RENAME_EXCHANGE` timed to the moment `dst/a` appears.

cp still copied an empty directory, so it does not reopen the source by path after its `lstat`. An
earlier "hit" was my own mistake: `ls` followed a copied symlink. The adopt copy of a live release
is therefore not exploitable this way. a13 records the attempt.

**Restore swap.** The new restore (a fresh directory filled by the app, then `mv -T`) refused a
symlinked `shared/data` (F2b re-run).

**Request log.**

- A remote client cannot spoof the probe exception with `X-Forwarded-For`/`X-Real-IP`: logged on
  2.6.2 and 2.11.9 (a06).
- Headers are deleted, and paths and IPs are cleaned of C0/C1 when shown. **[read]**

**Journal display.** Forged lines in another app's namespace carry the writer's `_SYSTEMD_UNIT` and
are not shown by `tando logs` (A15 output). The awk JSON reader cannot be fooled by quotes inside
MESSAGE. **[read]**

**Alerts and notifiers.** **[read]**

- URLs are checked to have no quote, backslash or space, and reach curl through `-K -` config, never
  the command line.
- JSON is escaped.
- The email subject is a fixed format, with the host name checked.
- App-derived text in alert details comes only from validated `app.conf` fields.
- State files are root-written and validated on load.

**Metrics and status rows.** Server-side, every value an app can influence is numeric-checked
(`app_row`, `tando-metrics read`). N4 needs a compromised server, not a compromised app. **[read]**

**Things outside reach from an app.**

- Other apps' `app.conf`/`state` (`tando-m-<app>` 640, `ls` denied), releases, env, access logs and
  backups.
- Container env files (`/opt/tando/run` 700). **[read]**

**Laptop-side writes.**

- `backup pull` and `logs pull` write only to a path the user names, and nothing is extracted.
- `tando.conf.adopted` values come through `strip` and cannot carry a newline. **[read]**

## Not tested

- **Python venv build and the container recipe:** no `python3`/`podman` in the image.
  - `build_venv` gives the app user a writable `.venv` inside the new release. With `writable`
    set, the live app's `ReadWritePaths=$D/releases` lets it reach that `.venv` during the build.
    That is a same-app persistence path, not escalation. **[read]**
- **cron/at eviction for deploy users:** no cron in the image.
- **TLS/ACME (`tls=auto`), and a full disk on ext4.** The disk amplification numbers are du-based
  (N10).
- **The pre-push hook and a real GitHub runner.**

## Counts

- **Scripts run against live servers: 25.** That is 23 scripts, with a06 and a07 run on both Caddy
  versions. The 23 are five from the earlier review (f1, f2, f2b, f3, f5), the adapted F4 re-test,
  and new attacks a01–a17.
- **Blocked: 12.** f1, f2, f2b, f3, f5, f4, a04, a05, a07 on 2.11.9, a08, a10 (17 sub-tests, all
  held), a13.
- **Succeeded: 13.** a01, a02, a03, a06 ×2, a07 on 2.6.2, a09, a11, a12, a14, a15, a16, a17.

## Cleanup

Both test containers (`tando-sec2`, `tando-sec2b`) were removed with `test/server/down.sh`. No product
files were edited. The only change in the real tree is this file. Everything else is under
`test/.work-sec2/`.
