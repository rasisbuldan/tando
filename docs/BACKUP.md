# Backups, offsite copies and disaster recovery

tando backs up every app that has data (`data = <dir>` or `database = postgres|sqlite` in
tando.conf) on the server itself. Those backups go with the server if it is lost. **Offsite
copies** put every backup into object storage (Cloudflare R2, or any S3-compatible store),
encrypted on the server before it leaves, so that a new server can be rebuilt from them.

Contents: [What is backed up](#what-is-backed-up) · [Local backups](#local-backups) ·
[Offsite: Cloudflare R2, step by step](#offsite-cloudflare-r2-step-by-step) ·
[Other S3 stores](#other-s3-stores) · [Commands](#commands) · [The recovery key](#the-recovery-key) ·
[Disaster recovery runbook](#disaster-recovery-runbook) · [Retention](#retention) ·
[Backups the server cannot erase](#backups-the-server-cannot-erase) ·
[Monitoring](#monitoring) · [Encryption format](#encryption-format) · [Object layout](#object-layout) ·
[Threat model](#threat-model) · [Testing against a real bucket](#testing-against-a-real-bucket) ·
[Costs](#costs)

## What is backed up

| | local backup | offsite copy |
|---|---|---|
| the app's data directory (`data =`, or an adopted app's `data_dir`) as `data.tar.gz` | yes | yes |
| the PostgreSQL database (`pg_dump -Fc`) as `db.dump`; SQLite as a consistent snapshot inside the data | yes | yes |
| the backup's `meta` (kind, time, warnings) | yes | yes |
| the app's settings (`app.conf`: recipe, start, domains, jobs, limits ...) | no | yes, with each backup and as `<app>/app.rbk` (refreshed daily) |
| the app's env (`tando env`, secrets included) | no | yes, the same way (encrypted) |
| the server's `host.conf` and the list of apps, recipes, domains | no | yes, `inventory.rbk` (daily) |
| **releases (the built code)** | no | **no**: they come from your project directory; after a recovery `tando up` deploys them again |
| uploads in `incoming/`, logs, metrics, alert history, Caddy's certificates | no | no (certificates are issued again by Caddy) |
| the server's own config (users, sshd, firewall) | no | no: `tando host setup` makes it again |

## Local backups

`/var/backups/tando/<app>/<YYYYMMDD-HHMMSS>-<kind>/` (root 700): `data.tar.gz`, `db.dump`, `meta`.
Kinds: `daily` (timer), `manual` (`tando backup now`), `predeploy` (before a deploy switches a release
in), `safety` (before a restore), `final` (on `tando destroy`). Kept: the newest 7 daily and the newest
of each of the 4 weeks before them, the newest 5 of each other kind, every final.

## Offsite: Cloudflare R2, step by step

1. **Create the bucket.** Cloudflare dashboard → R2 Object Storage → Create bucket. A name such as
   `myname-tando-backups`; location: automatic (or a jurisdiction you need). Note the **Account ID**
   shown on the R2 overview page (32 hex characters).
2. **Create an API token for that bucket only.** R2 → Manage API tokens → Create API token:
   permission **Object Read & Write**, *Apply to specific buckets only* → your bucket, TTL as you like.
   Create it and copy the **Access Key ID** and the **Secret Access Key** (shown once). Do not use an
   Admin token: a token limited to one bucket is what a leak would expose.
3. **Recommended: protect what is written.** The key on the server can, by default, delete every
   backup in the bucket, and so can whoever breaks into the server. A lock on the bucket takes that
   away: see [Backups the server cannot erase](#backups-the-server-cannot-erase). Also: *Object
   lifecycle rules* → abort incomplete multipart uploads after 1 day (R2 does this after 7 days by
   default).
4. **On your laptop:**

   ```
   tando backup offsite set              # asks: account id (or endpoint), bucket, key id, secret (not shown)
   ```

   tando writes, reads back and lists a small test object, tries to replace and delete it (a
   refusal there is reported, not a failure), checks the server's clock, and only then
   saves the settings (`/opt/tando/offsite.conf`, root only). On the first `set` it makes the
   **recovery key** and shows it once: store it now (password manager, or paper), then

   ```
   tando backup offsite key --saved      # tando doctor stops reminding you
   tando backup offsite status           # bucket, encryption, last upload per app
   tando backup ls                       # WHERE: local, local + offsite, offsite only
   ```

   The newest backup of each app is uploaded at once; every backup after that right after it is made.

Non-interactive (CI, a script): key=value lines on stdin, the secret among them; never in argv:

```
printf 'account_id=%s\nbucket=%s\naccess_key_id=%s\nsecret_access_key=%s\n' "$ID" "$B" "$K" "$S" |
  tando backup offsite set -H vps
```

Settings `set` takes (on stdin or as `key=value` arguments; the secret only on stdin):
`account_id` (R2) or `endpoint` (`https://host[:port]`), `bucket`, `access_key_id`,
`secret_access_key`, `region` (default `auto`), `prefix` (default `tando`), `encrypt` (`on`, default;
`off` must be given explicitly), `alert_hours` (6), `keep_daily` (7), `keep_weekly` (4),
`keep_monthly` (0), `keep_other` (5), `keep_min` (3). A later `set` changes only what it is given.

## Other S3 stores

Anything that speaks the S3 API with SigV4 and path-style requests. `endpoint=` and `region=`:

| store | endpoint | region |
|---|---|---|
| Cloudflare R2 | `account_id=<id>` (= `https://<id>.r2.cloudflarestorage.com`) | `auto` |
| AWS S3 | `https://s3.<region>.amazonaws.com` | the bucket's region, e.g. `eu-central-1` |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com` | e.g. `us-west-004` |
| MinIO | `https://minio.example.com:9000` | `us-east-1` (MinIO's default) or yours |

Only R2 and tando's own S3 test server have been exercised by tando's tests; AWS, B2 and MinIO are
expected to work by the same API (run `test/offsite-r2-check.sh` with `S3_ENDPOINT` against yours).
Endpoints must be `https://` with a certificate the server trusts (plain http is refused except to
the server itself), and redirects are not followed (a wrong region on AWS shows as "the endpoint
answered with a redirect").

## Commands

| command | |
|---|---|
| `tando backup offsite [status]` | settings (never the secret), encryption and key, the last credentials check, per app: waiting, failed, last upload |
| `tando backup offsite set [key=value...]` | set or change the settings; checked against the bucket before they are saved |
| `tando backup offsite test` | the same check with the saved settings; its `overwrite` and `delete` rows say whether this key could replace or erase a backup ([below](#backups-the-server-cannot-erase)) |
| `tando backup offsite sync` | upload what waits now (also failed ones not due yet), apply retention |
| `tando backup offsite hosts` | the servers whose backups are in the bucket (host id, hostname, apps, key id) |
| `tando backup offsite key --show` | print the recovery key(s) (asks first) |
| `tando backup offsite key --saved` | confirm the key is stored elsewhere |
| `tando backup offsite key --import` | give this server a key (reads it without echo) |
| `tando backup offsite key --rotate` | a new key for new uploads; the old ones stay to read older backups |
| `tando backup offsite off` | stop uploading; the bucket's contents and the key stay |
| `tando backup ls` | every backup with WHERE: `local`, `local + offsite`, `offsite only`, `local, uploading`, `local, upload failed` |
| `tando restore <id>` / `tando backup restore <id>` | restore; a backup that is only offsite is fetched and verified first |
| `tando backup pull <id> <file>` | works for offsite-only backups the same way |
| `tando restore --from-host <host id> [app...\|--all]` | recreate apps of another server here (below) |

## The recovery key

- 256 random bits, made on the server by the first `set` (`/opt/tando/offsite.key`, root 600), shown
  once as `tando-key-xxxx-xxxx-...` (14 groups of 4; a checksum catches a typo when it is typed back).
- **Without it the offsite backups cannot be read**, by anyone. The bucket's credentials do not help.
  Keep it outside the server; tando cannot recover it for you.
- `tando doctor` warns until `tando backup offsite key --saved`.
- Several servers may share a bucket, each with its own key, or the same one (`key --import` it on each).
- Rotation (`key --rotate`): new uploads use the new key; old keys stay in the key file to read
  what they encrypted (each object names its key by id). Keep every key whose backups you may need.

## Disaster recovery runbook

The old server is gone. You have: your laptop with tando and the project directories, the bucket's
credentials, the recovery key.

1. **A new server**: `tando go admin@<new address>`, or
   `tando host add newvps admin@<new address>` then `tando host setup newvps` (with `postgres=yes` if
   an app used PostgreSQL, and the same `apps_domain` / `tls` as before if you want the same links).
2. **The key**: `tando backup offsite key --import -H newvps` (paste the `tando-key-...`).
3. **The bucket**: `tando backup offsite set -H newvps` (the same bucket and credentials; no new key is
   made, the imported one is used).
4. **Find the old server**: `tando backup offsite hosts -H newvps` → its host id, hostname, apps.
5. **Recreate the apps**: `tando restore --from-host <host id> --all -H newvps` (or name apps instead of
   `--all`). For each app: runtimes installed, env set on the server (it never passes through your
   laptop), the app created with its settings and domains, then its newest backup fetched, verified
   and restored (data and database). An app that already exists there is skipped.
6. **Deploy the code** (releases are not backed up): the command prints, per app,
   `cd <project directory> && tando up -H newvps --yes` (`--yes` because tando remembers that the
   directory deployed to the old server). Point `host =` in tando.conf at the new server for later
   deploys.
7. **DNS**: point the apps' domains (and `*.apps_domain`) at the new address. Caddy gets new certificates.
8. **Check**: `tando ls -H newvps`, `tando doctor newvps`, `tando backup offsite status -H newvps`.
   The new server uploads under its own host id from now on; the old server's objects stay until you
   delete them in the bucket (tando never deletes another server's objects).

## Retention

Offsite, per app, over the objects this server wrote (its host id's directory only): by default the
local policy; `keep_daily`, `keep_weekly`, `keep_monthly`, `keep_other` keep more (e.g.
`tando backup offsite set keep_daily=30 keep_monthly=12`). Every final backup is kept. Whatever the
policy says, the `keep_min` objects the storage received last (by the storage's own clock) are never
deleted, and a run whose clock is more than 5 minutes off the storage's deletes nothing: a server
whose clock jumped cannot delete its newest backups. With a key that may not delete, or a lock on
the bucket, tando prunes nothing there and says so: the bucket's lifecycle rule does it
([Backups the server cannot erase](#backups-the-server-cannot-erase)).

## Backups the server cannot erase

The server holds the bucket's key, because it uploads unattended. Whoever takes over the server
has that key. Encryption keeps them from reading other servers' backups, but with an ordinary key
they can delete or overwrite every copy in the bucket, which is what ransomware does first. The
defence is in the storage, not in tando: make deletes and overwrites impossible for this key, and
let the storage itself remove old copies.

**What tando tells you.** `tando backup offsite test` (and `set`) writes one small object,
`<prefix>/<host id>/.tando-key-test/can-this-key-delete-or-overwrite.txt`, and tries to replace
and to delete it:

| row | says | meaning |
|---|---|---|
| `overwrite` | `allowed` | this key can replace an object it wrote (a backup could be overwritten with garbage) |
| | `refused` | it cannot (a lock on the bucket) |
| | `kept` | the bucket keeps versions: the replaced content stays as an older version |
| `delete` | `allowed` | this key can delete the offsite backups. The test still passes; this is the default setup and the one to improve |
| | `refused` | it cannot: the good outcome. The test object stays (under 300 bytes, its text says what it is) and the next test uses the same one, so they never pile up |
| | `not tested` | the bucket keeps versions, so a delete only hides an object; whether the key may delete a *version* is not tested by tando: check its policy |

`tando backup offsite status` shows the last result (`this key`).

**Retention then belongs to the bucket.** tando prunes old offsite copies with the same key
([Retention](#retention)). When the storage refuses those deletes, nothing fails and uploads go
on, but tando removes nothing: `tando backup offsite sync` says `retention skipped`, and `status`
(`pruning`) and `tando doctor` (`offsite retention`) say so until a delete goes through again.
Set a **lifecycle rule** on the bucket that expires objects under `<prefix>/` after as many days
as you want to keep backups (for example 35, or 400 to keep a year). A lifecycle rule knows only
age: tando's `keep_*` counts (7 daily, 4 weekly ...) do not apply offsite any more, and `final`
backups expire like the rest. Never set the expiry below the lock's period, and keep it well above
one day so that the newest backup always exists.

The two setups below are written from the providers' documentation (Cloudflare: "Bucket locks",
"Object lifecycles", "Authentication"; AWS: "Locking objects with Object Lock"). **tando's tests
cover them only against its own S3 test server** (a key whose deletes are refused with 403, a lock
that answers 409, a bucket that returns version ids); they were not verified against a real R2 or
S3 bucket. Run `tando backup offsite test` after setting one up: the `delete` row tells you
whether it worked.

**Cloudflare R2.** R2's API tokens have no "write but not delete" permission (Object Read & Write
is the narrowest that can upload), so the protection is a bucket lock rule, which the token cannot
change (editing a bucket's configuration needs an Admin token; never give the server one).

1. R2 → your bucket → Settings → *Bucket lock rules* → add a rule for the prefix `tando/` (your
   `prefix`) with a retention by age, e.g. 30 days. A locked object cannot be deleted or
   overwritten until it is that old; R2 answers such a request with `409
   ObjectLockedByBucketPolicy`.
2. Settings → *Object lifecycle rules* → add a rule for the same prefix that deletes objects
   after more days than the lock, e.g. 35. (A lock takes precedence over a lifecycle rule.)
3. `tando backup offsite test`: `overwrite refused`, `delete refused`.

A limit to know: besides the backups (each under a new name), tando rewrites three small objects
in place, `<app>/app.rbk` (the app's settings and env), `inventory.rbk` and `host.manifest`. Under
an R2 lock a rewrite is refused until the old object has aged out, so these are as old as the
lock's period at worst, and with the lifecycle rule above they are deleted and written again once
per period. `tando restore --from-host` takes an app's settings and env from `app.rbk`: after a
loss of the server, check the env of a recreated app against what you know changed recently.
Keep the lock's period short enough for that (7 to 30 days), not years.

**AWS S3** (and stores with the same model). Two parts, both needed:

1. *Keep versions.* Create the bucket with **Object Lock** enabled (this turns on versioning) and
   a default retention, e.g. governance or compliance mode, 30 days. An overwrite then creates a
   new version and a delete only adds a delete marker; the locked version underneath stays until
   its retention ends. (Versioning alone, without Object Lock, protects the same way as long as
   the key cannot delete versions: part 2.)
2. *A key that cannot remove versions.* Give the server's IAM user a policy with only
   `s3:PutObject`, `s3:GetObject`, `s3:AbortMultipartUpload` on `arn:aws:s3:::<bucket>/<prefix>/*`
   and `s3:ListBucket` on the bucket; no `s3:DeleteObject`, no `s3:DeleteObjectVersion`, no
   `s3:BypassGovernanceRetention`, no `s3:PutLifecycleConfiguration`, no `s3:PutBucketVersioning`.
3. *Lifecycle.* A rule for the prefix that expires current versions after N days, permanently
   deletes noncurrent versions some days after that, and removes expired delete markers.
4. `tando backup offsite test`: without `s3:DeleteObject` the `delete` row says `refused`; in a
   bucket with versions it says `not tested` (tando does not try to delete a version).

In a bucket that keeps versions, an attacker's deletes and overwrites only hide the backups:
`tando backup ls` and a restore see the current versions, so recovering after such an attack means
removing the delete markers or restoring the older versions with the provider's own tools first.

## Monitoring

- **The `backup` alert** (tando-watch) reads `/var/lib/tando/offsite/state/<app>` (below) and fires
  when a backup made here has not reached the bucket after `alert_hours` (6), or the credentials stop
  working. (The watch side of this is being added separately; until then `tando doctor` and
  `tando status <app>` show it.)
- **`tando doctor`**: `offsite` (bucket, encrypted, credentials failing), `offsite queue` (waiting,
  failed, last upload; a warning when one is late), `offsite retention` (only while the storage
  refuses tando's deletes), `offsite timer`, `recovery key` (saved or not).
- **The backup ping** (`tando alerts backup-ping`, docs/MONITORING.md "From outside"): an outside
  service is called once a day, only when every daily backup worked and is in the bucket.
- **`tando status <app>`**: an `offsite` line: last upload, uploads waiting or late, failing credentials.

State file per app (`/var/lib/tando/offsite/state/<app>`, root 644, key=value, rewritten after each
upload attempt and each sync):

| key | meaning |
|---|---|
| `enabled` | 1 while offsite copies are on |
| `alert_hours` | a backup waiting longer than this is late |
| `pending` | local backups not offsite yet (waiting, uploading or failed) |
| `failed` | of them, how many failed their last attempt (retried with backoff, 5 min to 6 h) |
| `oldest_pending`, `oldest_pending_id` | when the oldest of them was made (epoch; 0: none) and its id |
| `last_upload`, `last_upload_id` | the last backup that reached the bucket |
| `error` | the last upload error |
| `creds` | `ok` or `failing` (the store refused the credentials, the bucket, or the clock) |
| `creds_error`, `checked` | why, and when they were last checked |

`tando-offsite brief [app]` prints the same as rows: `offsite <app> <ok|pending|late|failing|off>
<last upload> <pending> <oldest pending> <alert hours> <detail>`.

## Encryption format

Each object (`.rbk`) is encrypted with a streaming AEAD built from the Go standard library: AES-256-GCM
over 1 MiB chunks (the STREAM construction).

```
header   "TANDOBK1" | alg=1 | chunk shift=20 | 0 0 | key id (8) | salt (32) | nonce prefix (7)
         | context length (2, BE) | context ("<host id>/<app>/<file>")
subkey   HKDF-SHA256(recovery key, salt, "tando offsite v1 chunk key")   (a new key per object)
chunk i  AES-256-GCM(subkey, nonce = prefix | i (4, BE) | last (1), plaintext, aad = header)
```

Every chunk but the last holds exactly 1 MiB of plaintext; the last holds 0 to 1 MiB - 1 and has the
last flag. A changed, moved, dropped or repeated chunk fails its tag; a cut at a chunk boundary
lacks the last chunk; bytes after it are refused; the header (key id, the object's own name) is
authenticated by every chunk, so an object copied under another name or app is refused. Salt and
prefix are random per object. The key id is the first 8 bytes of
SHA-256("tando-offsite-key-id\0" || key).

The plaintext is a *bundle*: `"RBKB1\n"`, then per file `'F' | name length (1) | name | size (8, BE)
| bytes`, then `'E'`; names from a fixed list (`meta`, `data.tar.gz`, `db.dump`, `config/app.conf`,
`config/env`, `inventory`, `host.conf`). With `encrypt=off` the bundle is stored as it is; a plaintext
object is refused while encryption is on.

## Object layout

```
<prefix>/<host id>/<app>/<backup id>.rbk         the backup (encrypted bundle)
<prefix>/<host id>/<app>/<backup id>.manifest    key=value, not encrypted: kind, created, sizes and
                                                 SHA-256 of plaintext and object, holds, key id, tando version
<prefix>/<host id>/<app>/app.rbk                 the app's app.conf and env (encrypted)
<prefix>/<host id>/inventory.rbk                 host.conf and the apps (encrypted)
<prefix>/<host id>/host.manifest                 hostname, apps, tando version, key id (not encrypted)
```

The host id (`/opt/tando/offsite.id`) is 12 random hex digits made once per server. Per local backup,
`/var/backups/tando/<app>/<id>/offsite` records `state=pending|uploading|uploaded|failed`, tries,
the next attempt, an upload id in progress (aborted by the next attempt when the process was killed),
and for a backup fetched from the bucket its source host. Uploads: one PUT up to 16 MiB, multipart
above (8 MiB parts up to 80 GB, 16 MiB up to 160 GB; one part in memory), each part with Content-MD5
and a signed SHA-256 payload hash, the ETags checked, the final size checked with HEAD. Downloads are
streamed, resumed with a Range and If-Match after a broken connection, and the SHA-256 of object and
plaintext compared with the manifest before the backup directory appears (whole or not at all).
With `encrypt=off` a backup whose manifest is missing from the bucket is refused: the manifest's
SHA-256 is the only check a plaintext object has (an encrypted one authenticates itself).

## Threat model

- **The bucket's credentials leak.** The attacker reads only ciphertext and the plaintext manifests
  (app names, backup times and sizes, hostname). They can **delete or overwrite** objects: the defence
  is the bucket, not tando: object lock (R2 bucket lock rules, S3 Object Lock, B2 object lock) or
  versioning with a key that cannot delete ([Backups the server cannot
  erase](#backups-the-server-cannot-erase)); `tando backup offsite test` says which you have.
- **The server is taken over** (root): the same, with the key in hand. The offsite copies survive
  only with that protection in the bucket. Planted objects do not get restored: a plaintext object is refused while
  encryption is on, and an encrypted one needs the recovery key. Use a token limited to one bucket.
- **The recovery key leaks** (with bucket access): the backups can be read. Rotate (`key --rotate`),
  and consider older objects exposed.
- **A compromised app** cannot read the credentials or the key (root 600 files in /opt/tando), cannot
  choose object names (app names and backup ids are validated, `[a-z][a-z0-9-]` and a fixed id shape;
  the host id is root's), and cannot make root upload other files: the uploader opens only root-owned
  regular files in root's 700 backup directory and the app's root-owned app.conf and env, with
  O_NOFOLLOW and O_NONBLOCK (a link or a FIFO is refused). The archive itself is made as the app user
  (as before), so it holds what the app could read.
- **A hostile or broken endpoint**: TLS is verified (system roots), redirects are never followed (a
  signed request never goes to another host), no proxy is taken from the environment; answers are
  bounded (error documents 64 KiB, list pages 8 MiB, manifests 64 KiB) and checked (keys under the
  asked prefix, sizes, a continuation token when truncated, a `200` with an `<Error>` body is an
  error); a downloaded object is authenticated chunk by chunk and its hashes compared before it is
  used. The parsers and the decryption are fuzzed (`go test -fuzz` targets in srv/offsite).
- **Secrets on the laptop**: the secret access key and the recovery key are read without echo and sent
  on ssh's stdin, never in argv or a file; error messages never contain them.
- **What is not protected**: who can log in as root on the server can read everything (the key is
  there so that backups can be made unattended). Manifests and object names are not secret.

## Testing against a real bucket

tando's tests run against its own S3 server (unit tests in-process; `test/e2e-offsite.sh` in a
container with TLS). To check your provider (R2 first):

```
R2_ACCOUNT_ID=... R2_BUCKET=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... test/offsite-r2-check.sh
```

It works under a throwaway prefix `tando-check-<random>/` and deletes it again. Another store:
`S3_ENDPOINT=https://... S3_REGION=...` instead of `R2_ACCOUNT_ID`.

## Costs

tando does not estimate them. The bucket holds about the size of your kept backups (compressed data
plus database dumps, with 16 bytes per MiB of encryption overhead); check your provider's current
storage and request prices.
