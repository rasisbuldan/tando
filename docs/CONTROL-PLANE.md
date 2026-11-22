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
   whole configuration (`sshd -t`) and what sshd will apply to `tando-ctl` (`sshd -T`, for a
   loopback, a private and a public client address on every port sshd listens on): publickey as
   the only method (no password, keyboard-interactive, hostbased or GSSAPI), the CA, the
   revocation list, the principals command and its user, no key file, no keys command, no
   ForceCommand, `ExposeAuthInfo yes`. When another sshd_config file sets one of them first, setup
   stops and says which. Every later `tando host setup` and `tando doctor` checks the same again
   (`sudo /opt/tando/bin/tando-gate admin ctl-check`): a drop-in added since is caught. Run it again with a new key to rotate the CA; `ctl_ca=off` turns the mode off (the
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
| `tando-app-<app>` | that app's read verbs and its `restart`, `stop`, `start`, `rollback`, `env.set`, `env.unset`, `hold` with reason pause and `release` of a pause; `alerts` and `usage` narrowed to it; never `inventory`, `destroy`, or a suspend (set or lifted) |

The principal is matched by sshd: `AuthorizedPrincipalsCommand` runs `tando-gate ctl-principals`
(as the unprivileged user `tando-keys`), which prints one line per principal with its forced
command; a `tando-app-<app>` line exists only while that app is on the server. A certificate with
several principals gets the first in the order write, app, read: give each certificate one.
tando-gate's root mode reads the mode from the session's login process (set by sshd), never from
the request, and does not take even that on trust: it also reads what sshd recorded as the way
the session was authenticated (`ExposeAuthInfo`: the `SSH_USER_AUTH` file) and requires exactly
one method, publickey with a certificate of this node's CA that carries that mode's principal,
serial and key id. A login by any other method is refused, whatever its command line says
(srv/gate/ctlcert.go).

Keep these in mind when you issue certificates:

- `tando-app-<app>` names an app, not one deployment of it: an app destroyed and made again
  under the same name is controlled by a certificate for the old one that is still valid. Keep
  validity to minutes.
- An app's principal can change its env (`env.set`), which is running code in that app
  (`NODE_OPTIONS`, for one). Give it to what may deploy the app anyway.
- `app.destroy` with `purge` drops the final backup too; `confirm` only guards against a typo in
  `app`. Issue write certificates for it to the part of the control plane that decides that.
- `usage` cursors count every app's rows: an app's principal learns roughly how many apps the
  node meters.

## Revocation

sshd reads `/opt/tando/ctl/revoked.krl` (an OpenSSH key revocation list) on every login. Revoke by
serial or key id, not by key, when certificates share a key:

```
printf 'serial: 1042\n' > spec && ssh-keygen -k -f revoked.krl -s ctl-ca.pub spec
tando host setup <host> ctl_krl=revoked.krl
```

The server accepts only a file `ssh-keygen -Q -l` reads: a broken list would make sshd refuse every
certificate. A list with certificate sections must have one for this node's CA (one made with
another `-s` revokes nothing here), and the answer says how many entries it has. An empty file
never replaces a list with entries by accident: `ctl_krl=empty` empties it by name. Short validity is the main defence; the list is for a certificate
that must stop working before it expires.

OpenSSH 9.8 and newer drops every connection from an address for a while after failed logins
(`PerSourcePenalties`), the admin's too. A control plane that sends an expired certificate a few
times locks itself out for that long. Mint a fresh certificate for each call instead of retrying
an old one. `PerSourcePenaltyExemptList` is server-wide (it cannot be set for one user): it lifts
the throttling for every user from that address, root and the admin included. Use it only for an
address that is the control plane's alone (a dedicated egress IP), never a shared NAT.

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
| `app.status` | | app, recipe, state (the web unit), stopped, down, hold and hold_since (only while held: below), idle_stop, current, last_good, phase, alloc_mb, alloc_workers_mb, admitted_mb, cpu, mem_mb and cpu_ms_minute (the last per-minute sample; null before the first), sampled_at, awake_s_24h |
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
| `app.hold` | `reason`: `pause` or `suspend`; `message` (optional) | takes the app off line: see Hold |
| `app.release` | | brings a held app back |

The result of a mutating verb is the agent's `key=value` lines as an object (`healthy`,
`changed`, `restarted`, ...). Deploying an artifact, applying a whole app spec and draining a
server are not in this version.

## Hold

`app.hold` takes an app off line without removing anything; `app.release` brings it back. The
reason is recorded and shown (`app.status`, `inventory`: `hold`, `hold_since`):

| Reason | For | Set by | Lifted by |
|---|---|---|---|
| `pause` | the operator's own reasons (unpaid, on request, maintenance) | `tando-ctl-write` or the app's principal | either |
| `suspend` | an abuse takedown | `tando-ctl-write` only | `tando-ctl-write` only |

An app's principal can neither suspend its app, nor release a suspend, nor turn a suspend into a
pause: which reason holds the app is read from the node's state when the request runs, not from
the request. Pausing a paused app again only changes the message; suspending a paused app makes it
suspended (and freezes evidence).

While an app is held:

- It is stopped as by `tando stop`: Caddy first answers 503 with `<app> is paused` or `<app> is
  suspended` (with `. <message>` after it when one was given; `Retry-After: 3600`), then the web
  unit and the workers stop and are disabled, and an app with `idle_stop` has its wake socket
  stopped and disabled (no request wakes it). Its job timers are off, and no job runs, by its
  timer or by hand.
- A reboot keeps it so: the state file says held, the units are disabled, and tando's recovery at
  boot keeps a held app stopped. A stopped app raises no down alert.
- Refused with `held (<reason>): release it first`: deploy (the laptop's `tando up` and deploy
  keys alike, at configure and again at activation: a deploy queued before the hold gives up),
  start, restart, rollback, backup restore. The current release stays in place and is never
  pruned. `env.set` and `env.unset` are saved and take effect at release; `stop` answers
  `already`; `destroy` works (and removes the evidence below).
- The daily backup skips it (its data stays as it was); a backup by hand still works.
- The message is at most 200 of letters, digits, space and `. , : ; ! ? ' ( ) / @ + _ -`: it is
  written into the Caddy site between quotes, so braces (Caddy placeholders), quotes and
  backslashes are refused.

`app.release` restores what was before the hold: an app that ran is started, checked
(`healthy`) and its job timers come back; an app that was stopped (`tando stop`, `app.stop`)
before the hold stays stopped, with the stopped page. If the start fails, the hold is gone and the
app is stopped: read the message, then `app.start`.

**Evidence.** A suspend first copies, under `/var/lib/tando/ctl/evidence/<app>/<UTC time>/`
(root, 700): the app's journal (its journal namespace, `journal.export`, `journalctl -o export`
format), its request logs (`access.log*`, when request logging is on), `release.sums` (the file
sums of the current release), `info` (app, release id, time, who, message) and `SHA256SUMS` of
them all. The result's `evidence` names the directory (`evidence=0` and a warning when it could
not be written in full: the takedown goes on anyway). Evidence is kept after a release, until the
app is destroyed; copy it off the node when you need it longer.

The agent verbs are `tando-agent hold <app> pause|suspend [message]` and `tando-agent release
<app>` (root), each under the app's lock and written to the audit log like `stop`.


## Idempotency and order

Every mutating request goes through the request store, `/var/lib/tando/ctl` (root 700):

- Request ids belong to a principal: `tando-ctl-write`, `tando-ctl-read` and each
  `tando-app-<app>` have their own namespace (`req/<principal>/`), so one certificate can neither
  claim nor replay nor push out another's ids.
- Before it runs, a record with the request's digest (principal, verb, app, arguments, as an
  HMAC with a key that never leaves the node: env values are neither stored nor guessable from a
  copy of the store) is written and fsynced under `req/<principal>/<request_id>.json`, and the
  process running it holds its `.lock`.
- A retry with the same id and the same request gets the first response (`replayed: true`). If
  the first is still running, the retry waits for it (up to the verb's time limit, then
  `pending`: ask again). Nothing runs twice.
- The same id with another request is refused (`conflict`).
- A request cut off by a crash or reboot (a record nobody runs) is answered `interrupted`, once
  and for good: tando's own recovery finishes or undoes the step; read `app.status` and send a new
  request with a new id.
- Requests for one app run one at a time, in the order they arrived; other apps' run alongside.
- Records are kept 7 days, then removed: a retry after that runs again. A principal keeps at most
  20,000; past that its own oldest records older than 24 hours go, and when there are none, its
  new requests get `busy`. Another principal's records are never touched.
- A request refused before it did anything (`bad_request`, `not_found`) is not kept: the same id
  with the request fixed runs.

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
certificate's serial and key id, verb, app, request id, result and time. A value from the request
that is not a plain word is written quoted (Go syntax), so no request can add fields or lines. sshd logs the
certificate it accepted; tando-agent writes its usual audit line (`tando audit`) with
`tando-ctl` as the user.

## What it does not cover

- The node does not call the control plane; it keeps serving without it.
- A laptop CLI change made beside the control plane is not undone or reported by this version.
- Certificates are checked by sshd (Ubuntu's OpenSSH); tando tests valid, expired, wrong
  principal, wrong CA, no certificate and revoked (`test/e2e-ctl.sh`).
