# Control plane mode

For operators who run many small apps on many servers and drive them from their own program (a
"control plane") instead of the laptop CLI. It is off unless you turn it on, and it changes
nothing for the laptop CLI: `tando up`, `deploy`, `env`, `restart` and the rest work as before
on the same server.

A server in control plane mode accepts one more kind of login: the user `tando-ctl`, with an
OpenSSH **user certificate** signed by your control plane's certificate authority (CA). Each
login carries one JSON request on stdin and gets one JSON response on stdout. There is no shell,
no listener and no static key on the server: what a certificate may do comes from its principal,
how long it works from its validity, and sshd checks both.

Design notes: the transport is sshd plus tando-gate (srv/gate, the same code that confines CI
deploy keys, docs/CI.md); the protocol and the request store are srv/ctl; the metering ledger is
srv/internal/usage. Tests: `test/e2e-ctl.sh`, the Go tests of those packages.

## Setup

1. Make a CA key pair where your control plane runs (keep the private key off the app servers;
   a hardware or cloud key signer is better than a file):

   ```
   ssh-keygen -t ed25519 -f ctl-ca -C ctl-ca
   ```

2. Give each server the CA's public key:

   ```
   tando host setup <host> ctl_ca=ctl-ca.pub
   ```

   `ctl_ca=` takes the `.pub` file (the CLI sends `<type>:<base64>`, the form the server's agent
   takes). It creates the user `tando-ctl` (its login shell is tando-gate, home
   `/opt/tando/ctl`, root-owned), writes `/opt/tando/ctl/ca.pub`, an empty revocation list, one
   sudo rule (`tando-ctl ALL=(root) NOPASSWD: /opt/tando/bin/tando-gate ctl-root`) and the sshd
   drop-in `/etc/ssh/sshd_config.d/50-tando-ctl.conf`. Before sshd is reloaded it checks the
   whole configuration (`sshd -t`) and what sshd will apply to `tando-ctl` (`sshd -T`): the CA,
   the revocation list, the principals command, no key file and no keys command. When another
   sshd_config file sets one of them first, setup stops and says which. Run it again with a new key to rotate the CA; `ctl_ca=off` turns the mode off (the
   drop-in, the sudo rule and the CA file go; the request store stays).

3. Sign a short-lived certificate for each call or batch of calls:

   ```
   ssh-keygen -s ctl-ca -I cp-2026-11-22T10:00 -n tando-ctl-write -V +10m -z 1042 \
     -O source-address=203.0.113.10/32 client.pub
   ```

   `-I` (key id) and `-z` (serial) are written to the server's journal with every request: make
   them identify the call. Never give the certificate a `force-command`.

## Principals

| Principal | May |
|---|---|
| `tando-ctl-read` | every read verb, every app |
| `tando-ctl-write` | every verb, every app |
| `tando-app-<app>` | that app's read verbs and its `restart`, `stop`, `start`, `rollback`, `env.set`, `env.unset`; `alerts` and `usage` narrowed to it; never `inventory` or `destroy` |

The principal is matched by sshd: `AuthorizedPrincipalsCommand` runs `tando-gate ctl-principals`
(as the unprivileged user `tando-keys`), which prints one line per principal with its forced
command; a `tando-app-<app>` line exists only while that app is on the server. A certificate with
several principals gets the first in the order write, app, read: give each certificate one.
tando-gate's root mode reads the mode from the session's login process (set by sshd), never from
the request (srv/gate/ctl.go has the details).

## Revocation

sshd reads `/opt/tando/ctl/revoked.krl` (an OpenSSH key revocation list) on every login. Revoke by
serial or key id, not by key, when certificates share a key:

```
printf 'serial: 1042\n' > spec && ssh-keygen -k -f revoked.krl -s ctl-ca.pub spec
tando host setup <host> ctl_krl=revoked.krl
```

The server accepts only a file `ssh-keygen -Q -l` reads (or an empty one): a broken list would make
sshd refuse every certificate. Short validity is the main defence; the list is for a certificate
that must stop working before it expires.

OpenSSH 9.8 and newer drops every connection from an address for a while after failed logins
(`PerSourcePenalties`), the admin's too. A control plane that sends an expired certificate a few
times locks itself out for that long; put its address in `PerSourcePenaltyExemptList` if that
matters more to you than the slowdown of guessing from it.

## Requests

```
ssh -i client -o CertificateFile=client-cert.pub tando-ctl@<host> < request.json
```

One JSON object per session, at most 256 KB, no command on the ssh line. Unknown fields are
refused.

```json
{"v": 1, "verb": "app.restart", "app": "shop", "request_id": "0b8f4c1e-2d3a-4b5c-8d9e-0f1a2b3c4d5e"}
```

| Field | |
|---|---|
| `v` | the schema version: 1. A version the server does not speak is refused (`unsupported_version`) |
| `verb` | below |
| `app` | the app, for the verbs that take one |
| `request_id` | required on every mutating verb: 8 to 64 of `A-Z a-z 0-9 . _ : -` (a UUID fits) |
| `args` | the verb's arguments, an object |

The response is one line of JSON:

```json
{"v":1,"ok":true,"verb":"app.restart","app":"shop","request_id":"0b8f...","result":{"healthy":"1"}}
{"v":1,"ok":false,"verb":"app.rollback","app":"shop","request_id":"...","error":{"code":"failed","message":"no earlier verified release to roll back to"}}
```

`replayed: true` marks a stored response (below). The exit status is 0 for `ok`, 1 otherwise; a
login that sshd refuses ends with ssh's 255 and no JSON. Error codes: `bad_request`,
`unsupported_version`, `unknown_verb`, `forbidden`, `not_found`, `conflict`, `pending`, `busy`,
`failed` (the verb ran and failed; the message is tando's reason), `interrupted`, `internal`.

## Verbs

Read (no request id needed):

| Verb | args | Result |
|---|---|---|
| `inventory` | | `node`: cpus, mem_total_mb, mem_available_mb, swap_total_mb, load1, disk_total_mb, disk_free_mb, mem_overcommit, idle_awake_pct, alloc_mb (every cap), admitted_mb (as admission counts them), admit_limit_mb and admit_headroom_mb (RAM x mem_overcommit, without them when the check is off), apps, version; `apps`: each as `app.status` |
| `app.status` | | app, recipe, state (the web unit), stopped, down, idle_stop, current, last_good, phase, alloc_mb, alloc_workers_mb, admitted_mb, cpu, mem_mb and cpu_ms_minute (the last per-minute sample; null before the first), sampled_at, awake_s_24h |
| `app.releases` | | `releases`: id, status, current, last_good, newest first |
| `app.history` | `n` (1-1000, default 20) | `history`: time, id, kind, result, seconds, note |
| `alerts` | (`app` optional) | `alerts` that are firing or pending: scope (an app or `host`), check, state, since, detail |
| `usage` | `since` (cursor, default 0), `limit` (default 5000); `app` optional | see Metering |

Mutating (`request_id` required), each the agent verb the laptop CLI runs:

| Verb | args | Like |
|---|---|---|
| `app.restart`, `app.stop`, `app.start` | | `tando restart / stop / start` |
| `app.rollback` | `to` (a release id; default: the previous verified one) | `tando rollback` |
| `app.env.set` | `vars`: {"NAME": "value"} (no control characters) | `tando env set`; the app restarts and is checked, a change that breaks it is undone |
| `app.env.unset` | `names`: ["NAME"] | `tando env unset` |
| `app.destroy` | `confirm` (must be the app's name), `purge` (bool) | `tando destroy [--purge]`; write principal only |

The result of a mutating verb is the agent's `key=value` lines as an object (`healthy`,
`changed`, `restarted`, ...). Deploying an artifact, holding an app, applying a whole app spec and
draining a server are not in this version.

## Idempotency and order

Every mutating request goes through the request store, `/var/lib/tando/ctl` (root 700):

- Before it runs, a record with the request's digest (verb, app, arguments; a hash only: env
  values are never stored) is written and fsynced under `req/<request_id>.json`, and the process
  running it holds `req/<request_id>.lock`.
- A retry with the same id and the same request gets the first response (`replayed: true`). If
  the first is still running, the retry waits for it (up to the verb's time limit, then
  `pending`: ask again). Nothing runs twice.
- The same id with another request is refused (`conflict`).
- A request cut off by a crash or reboot (a record nobody runs) is answered `interrupted`, once
  and for good: tando's own recovery finishes or undoes the step; read `app.status` and send a new
  request with a new id.
- Requests for one app run one at a time, in the order they arrived; other apps' run alongside.
- Records are kept 7 days (at most 20,000), then removed: a retry after that runs again.

## Metering

Once a minute the sampler (tandod, or tando-watch's timer without it) appends one row per app to
the ledger in `/var/lib/tando/usage` (fsynced; kept 14 days). Read it with `usage` and a cursor:

```json
{"v":1,"verb":"usage","args":{"since":41870}}
{"v":1,"ok":true,"verb":"usage","result":{"rows":[{"seq":41871,"t":1795000000,"boot":"0123abcd","app":"shop","interval_s":60,"alloc_mb":256,"alloc_workers_mb":0,"awake_s":60,"mem_mb":61,"cpu_ms":420}],"next":41871,"oldest":1,"gap":false,"more":false}}
```

- **Metering is allocation-based**: `alloc_mb` (the app's `memory` cap) and `alloc_workers_mb`
  (its workers' caps; they run always) for `interval_s`, with `awake_s` the seconds of that
  interval the web process ran (from systemd's start and stop times: an app with `idle_stop` is
  awake only while it serves). `mem_mb` and `cpu_ms` are measured and informational only (a
  cgroup's counters start over with its unit).
- `seq` grows by one per row across restarts of tandod and of the server; `next` is the cursor
  for the next read; `more` says the limit was reached; `gap` says rows after `since` were already
  removed. `boot` changes with each boot of the server.
- A row covers the time since the app's last row, up to an hour (after a longer stop of the
  sampler, that time is not metered). A static site and an app that held and ran nothing have no
  rows.

## Audit

Every request writes one line to the journal (`journalctl -t tando-gate`): principal, the
certificate's serial and key id, verb, app, request id, result and time. sshd logs the
certificate it accepted; tando-agent writes its usual audit line (`tando audit`) with
`tando-ctl` as the user.

## What it does not cover

- The node does not call the control plane; it keeps serving without it.
- A laptop CLI change made beside the control plane is not undone or reported by this version.
- Certificates are checked by sshd (Ubuntu's OpenSSH); tando tests valid, expired, wrong
  principal, wrong CA, no certificate and revoked (`test/e2e-ctl.sh`).
