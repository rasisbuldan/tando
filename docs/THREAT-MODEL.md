# Threat model

Who and what tando defends against, where the trust boundaries are, which mechanism holds each
one (with the file to read), what is left open, and where an outside reviewer should start. It is
written for an operator who runs many small apps for other people on a few servers ("many small
apps on one node"), but every statement also holds for one person with one server. It summarises
and indexes the longer reasoning in [ARCHITECTURE.md](ARCHITECTURE.md#trust-boundaries) (trust
boundaries and the third review), [SECURITY-REVIEW-2.md](SECURITY-REVIEW-2.md),
[SECURITY-REVIEW-CI.md](SECURITY-REVIEW-CI.md), [STUDIO.md](STUDIO.md), [PREVIEWS.md](PREVIEWS.md),
[BACKUP.md](BACKUP.md) and [HOSTCARE.md](HOSTCARE.md); where they differ, the code wins. Report a
vulnerability as [SECURITY.md](../SECURITY.md) says.

Status words: **built** (in the tree and tested), **partial** (built, with a named gap),
**open** (known, not built), **planned** (not in the tree yet).

## 1. The model in one paragraph

A node is one Linux VM running systemd. Tenants' apps run on it as ordinary processes, each as its
own unix user in its own cgroup slice with a sandbox of systemd directives and per-uid firewall
rules. They share the kernel, the disk, Caddy, PostgreSQL and the network. The operator's laptop
drives the node over ssh as an administrator with passwordless sudo, and root runs only one agent
program (`tando-agent`) with a fixed set of verbs. tando is a **single-tenant-per-uid, shared-kernel**
design: it makes one app unable to read, starve or impersonate another through the usual paths, and
it limits what a compromised app can reach. It does not make a kernel exploit harmless (section 7).

## 2. Assets

| Asset | Where | Why it matters |
|---|---|---|
| App source and releases | `/opt/tando/apps/<app>/releases` (root-owned, readable by the app's group) | tenant IP; tampering means code execution as the app |
| App env (secrets, database URL) | `/opt/tando/apps/<app>/env` (root:tando-<app> 640) | credentials for third parties; never in a release, a unit file or an argv |
| App data and database | `shared/` and one PostgreSQL role and database per app | tenant data |
| The node's root and the agent | `server/tando-agent`, sudoers, `/opt/tando` | root on the node is every tenant's data |
| Admin ssh key (laptop) | the operator's laptop | sudo on every node it is registered with |
| CI deploy keys | one ssh key per app, shell `tando-gate` | may deploy one app only |
| Backups and the recovery key | `/var/backups/tando`, object storage, `offsite.key` (root 600) | a copy of every tenant's data; the key decrypts the offsite copy |
| Caddy admin API and TLS state | unix socket `/run/caddy/admin.sock` | would let a caller take over any domain |
| Cloud metadata service | `169.254.169.254` | instance credentials on many clouds |
| Node capacity (CPU, memory, disk, connections, ports, inodes, entropy) | the kernel | one tenant's use is another's outage |
| Audit and request logs | `/var/log/tando`, per-app journal namespaces | evidence; per-app logs hold visitors' addresses |

## 3. Actors

| Actor | Trust | Capabilities assumed |
|---|---|---|
| **Visitor** | none | any request to an app's public link; large, slow, malformed and many requests |
| **Tenant app** (its code, as written) | low, even if the tenant is honest: apps have bugs and dependencies | runs as `tando-<app>` with the sandbox; reads its env; talks to its database; makes outbound connections |
| **Compromised tenant** | hostile | arbitrary code as that uid inside the sandbox: fork bombs, memory and disk hogging, port scans of loopback, attacks on the shared services, on other apps, on the kernel, outbound abuse (spam, scans, floods), reading anything world-readable |
| **Preview author / pull request** | hostile until reviewed | code deployed to a public link by CI before anyone reviewed it |
| **CI deploy key holder** | low | one app's upload and activation only, through `tando-gate` |
| **Control plane** (an operator's service that drives many nodes; **planned**, see section 5.5) | high | would hold node credentials and tenants' env; the highest-value target of the whole system |
| **Operator laptop** | high | sudo on every registered node; holds the admin key, the config directory, the dashboard and the studio tabs |
| **Network attacker** | none | anything on the path between laptop and node, and from the internet to ports 22, 80, 443 |
| **Operator's mistake** | n/a | a wrong host, a wrong flag, a lost key: treated as an actor because it is the likeliest one |

## 4. Trust boundaries

```
 visitor ──443/80──▶ Caddy ──unix socket / 127.0.0.1:<port>──▶ app (uid tando-<app>, slice, sandbox)
                       │                                          │   ▲
                       │ admin API: unix socket, caddy+root only  │   │ own port only (nft per uid)
                       ▼                                          ▼   │
                   site files (root:caddy 640)            PostgreSQL role per app (via pgbouncer)

 laptop ──ssh (admin, sudo)──▶ tando-agent (root, fixed verbs) ──▶ units, sites, users, backups
 CI key ──ssh (restricted)───▶ tando-gate (typed grammar) ──▶ agent verbs for ONE app
 laptop ──ssh -L──▶ studio / dashboard (loopback, token, read-only SQL)
 node ──https──▶ object storage (encrypted backups)
```

| Boundary | What separates the two sides | Mechanism (file) |
|---|---|---|
| Visitor / Caddy / app | Caddy is the only listener on 80/443; apps bind loopback only; per-client connection and rate caps | `rate_limit_rules` and `fw_sync` in `server/tando-agent`; Caddy sites made by the agent |
| App A / app B | uid, group, home, `/tmp` and `/dev/shm` per app, ProtectSystem=strict, ProtectProc=invisible, SocketBindDeny=any except its own port, nft rules by uid, cgroup slice, journal namespace | `props()` in `server/tando-agent` (one function writes every unit that runs app code); `fw_sync`; [ARCHITECTURE.md](ARCHITECTURE.md#trust-boundaries) |
| App / node services | Caddy admin API on a unix socket in a directory only caddy and root enter; loopback ports of other apps, pre-flight ports and 2019 refused per uid; PostgreSQL and pgbouncer only for apps with a database; metadata address refused; app packets of an inbound-opened connection dropped | `caddy_admin_private`, `fw_sync` in `server/tando-agent`; tando-watch reloads the table if it drifts (alert `firewall`) |
| App / database | one role per app with CONNECT on its own database only, databases closed to PUBLIC, statement, idle-transaction and temp-file limits, per-uid connection cap | `db_limits` in the agent; [COMMANDS.md](COMMANDS.md#database-limits) |
| App / root | root never reads or writes through app-controlled paths: inspection on a root-owned copy, restores into a fresh directory as the app user then renamed in, symlinks refused, tar and pg_dump run as the app user | `shared_ok`, restore and backup verbs in `server/tando-agent`; `srv/gate` (descriptor-based upload) |
| Laptop / node | ssh with the host key pinned at `host add`; the agent is the only thing root runs for it | `lib/common.sh` (`resolve`, `SSHO`), `bin/tando`, `server/tando-agent` |
| CI key / node | the gate parses the request into a typed form by a fixed grammar, keeps four environment variables, binds its root mode to the key's ssh session through /proc, and reads uploads with directory descriptors only; sshd forwarding disabled for it | `srv/gate`; [CI.md](CI.md); [SECURITY-REVIEW-CI.md](SECURITY-REVIEW-CI.md) |
| Studio | one front as root with only CAP_SETUID/CAP_SETGID, a helper as the app's own user, read-only transaction enforced by PostgreSQL, system catalogs refused, unix socket, bearer token, Host and Origin checks, CSP | `srv/studio`; [STUDIO.md](STUDIO.md) |
| Dashboard (laptop app) | listens on 127.0.0.1 only, session cookie, single-use confirm tokens for actions, idempotency keys, it drives the same `tando` commands as the terminal | `addons/dashboard` (its README: API table) |
| Previews | a preview is an ordinary app (own uid, port, sandbox) that gets none of its parent's env, database, data or jobs unless named, expires by timer, at most 10 per app | `cmd_preview_sweep` in `server/tando-agent`; [PREVIEWS.md](PREVIEWS.md) |
| Node / object storage | backups encrypted on the node with a recovery key before upload; the key never leaves the node except at `offsite set` (shown once); a key that may not delete is the safe setup; a lock on the bucket is supported | `srv/offsite`, `lib/offsite.sh`; [BACKUP.md](BACKUP.md) |
| Node / its own past | the host is repaired by recovery at boot and every minute: unfinished deploys, destroys and restores are finished, not left half | `recover-all`, `tando-install-recover`; [ARCHITECTURE.md](ARCHITECTURE.md#activation-state-machine) |

## 5. Threats and mitigations

IDs are for the reviewer's checklist. "Test" names the suite that exercises the mitigation
([TESTING.md](TESTING.md)).

### 5.1 Tenant to tenant

| # | Threat | Mitigation | Status | Test |
|---|---|---|---|---|
| T1 | Read another app's files, env, release, logs | separate uids; releases root-owned, group-readable by the app only; env root:tando-app 640; ProtectHome, private `/tmp`, `/dev/shm`; journal namespace dirs 0750 root:app group | built | `e2e-neighbours`, `e2e-sec2` |
| T2 | Reach another app's port or its pre-flight port; the Caddy admin API | nft per-uid output rules (own port only); admin API on a unix socket | built | `e2e-sec2` |
| T3 | Reach services tando does not know (a redis on loopback) | not blocked: the services need their own authentication or a unix socket | **open, documented** | |
| T4 | Take another app's domain or read its requests through Caddy | site files root:caddy; admin API private; Host must match a site (400 otherwise); probe secret header dropped at the edge | built | `e2e-proxy`, `e2e-sec2` |
| T5 | Starve a neighbour: memory, cpu, tasks, disk, inodes, connections, `/tmp`, journal | per-app slice (MemoryMax 3x plus workers, TasksMax, CPUQuota when set, CPU/IO weight), tmpfs `/tmp` charged to memory, journal caps per namespace, `max_conns`, per-uid `conn_out` and `dns_rate`, per-role database limits, disk alerts and a stop at 95% full | partial: no disk quota (alert and stop only); `cpu` is optional (planned: mandatory in operator profiles); disk I/O limits best effort | `e2e-neighbours` |
| T6 | Fill the shared kernel tables: conntrack, ports, pids, open files | `conn_out` cap on new connections per uid, `tasks`, port ranges per app | partial: no per-uid cap on UDP flood bytes or packets other than DNS | `e2e-neighbours` |
| T7 | Exhaust PostgreSQL: connection slots, locks, memory, temp files | per-app pool and per-uid connection cap, role limits (`statement_timeout`, idle transaction, temp file limit), pgbouncer in front | partial: `statement_timeout` is the role's setting and the app can reset it for its own session; one value a query builds can still take up to 1 GB; no per-session memory cap | `e2e-data`, `e2e-neighbours` |
| T8 | A noisy app's log lines fill the disk or hide another's | per-app journal namespace with caps and a host log budget | built | `e2e-logs` |

### 5.2 Compromised tenant to the node

| # | Threat | Mitigation | Status | Test |
|---|---|---|---|---|
| C1 | Escalate to root through the agent, sudo or a unit | the app has no sudo; units run with NoNewPrivileges, ProtectKernel*, RestrictNamespaces, RestrictSUIDSGID, SystemCallFilter=@system-service, RestrictAddressFamilies; commands from `tando.conf` are stored in `app.conf` and run by fixed verbs, never written into unit files | built for directory apps | `e2e-sec2` |
| C2 | Escalate through a root path that follows an app-writable path (symlink, hard link, rename race) | root never reads or writes through app paths (see section 4); restores and uploads by descriptor | built; the main class of past findings, see SECURITY-REVIEW-2 | `e2e-sec2`, `e2e-ci` |
| C3 | Ptrace or signal another process | ProtectProc=invisible; `ptrace_scope` checked by doctor (restores unpack as the app user outside its sandbox; with ptrace_scope 0 the app could attach) | partial: depends on a host setting that doctor checks | |
| C4 | Reach the cloud metadata service (instance keys) | refused for every app uid (nft, IPv4 and the IPv6 address used by some clouds) | built for directory apps; **bypassed by container apps** (C6) | `e2e-sec2` |
| C5 | Outbound abuse: spam, scans, floods, attacks on third parties | per-uid new-connection cap and DNS rate; the app's packets of an inbound-opened connection dropped | partial: no outbound mail block and no outbound byte or packet rate yet (planned: operator profiles); no egress allowlist | `bench/container-egress.sh` for containers |
| C6 | **Container apps (`recipe = container`) leave the host through slirp4netns run by root, so their packets carry uid 0, not the app's uid, and none of the per-uid rules (C4, C5, connection and DNS caps, loopback port rules) see them.** Measured on a test server with `bench/container-egress.sh`: the app uid's counter stayed at 0 while the root counter and the app-slice counter rose. Loopback of the host is not reachable from the container (slirp's gateway is closed), so only egress is open | proposed fix: match on the app's cgroup instead of the uid for container apps (`socket cgroupv2 level 2 "tando.slice/<app slice>"`; slirp4netns and conmon run inside the app's unit cgroup, verified), or refuse `recipe = container` in operator profiles until then | **open** | `bench/container-egress.sh` |
| C7 | Read the host's secrets: other users' files, `/opt/tando`, the audit log, offsite credentials | modes root 600/640, apps not in `adm`; ProtectSystem=strict; the agent's lock and state files root 600 | built | `e2e-sec2` |
| C8 | Attack the monitoring daemon or the log scanner by writing crafted log lines or names | control characters in names and log lines are replaced before reaching files or clients; the daemon parses typed grammars | partial: parser fuzzing is thin | `go` |
| C9 | Persist: cron, user units, `~/.npmrc`, `.pth`, shell rc | HOME is root-owned and read-only; npm/pip/git user config disabled; jobs are tando jobs | built | `e2e-sec2` |
| C10 | A restart loop or a start-limit storm that wedges systemd (PID 1 growth, trigger limits) | the monitor resets failed idle-app sockets; `bench/density.sh` and `bench/fleet.sh` watch PID 1 RSS | partial: one unexplained PID 1 growth was seen once ([bench](../bench/README.md)); reproduce before default-on `idle_stop` | `e2e-idle` |

### 5.3 Visitors and the network

| # | Threat | Mitigation | Status | Test |
|---|---|---|---|---|
| N1 | Connection and request floods against one app or the whole node | per-client address (IPv6 /64) connection and rate caps on 80/443; per-app `max_conns`, `max_requests`, `body_max`, `response_timeout`; Caddy header and idle timeouts | partial: one client address limit is no defence against a distributed flood: put an edge in front (planned: origin mode) | `e2e-proxy` |
| N2 | Man in the middle between laptop and node | ssh with the host key shown and pinned at `host add` (a host keyed insecurely is for test servers only) | built | `e2e-cli` |
| N3 | Spoofed client address or probe header to dodge logs and limits | probe secret header, dropped before the app; client address from the peer, not from a header | partial: behind an edge the real client address needs a trusted-proxy list (planned) | `e2e-proxy` |
| N4 | A visitor wakes many idle apps at once (scale to zero) | `cold_timeout`, `max_requests`; wake socket per app | partial: no node-wide cap on apps awake at once (planned: awake governor) | `e2e-idle` |
| N5 | TLS and name abuse: a tenant points any domain at the node, or one that is not theirs | `tando domain add` is an admin action; certificates come from Caddy per name | partial: nothing checks that the tenant owns the domain beyond what the operator does | `e2e-host` |

### 5.4 Operator, laptop and control channel

| # | Threat | Mitigation | Status | Test |
|---|---|---|---|---|
| L1 | The admin key is stolen: sudo on every node | ssh key with a passphrase and agent; host entries per laptop; audit log on the node (user, origin) | **open by design**: the admin has root; planned: short-lived ssh certificates with read and write principals so no long-lived key opens many nodes | |
| L2 | A CI key is stolen | restricted to one app, no shell, no forwarding, grammar-checked verbs, the key's session bound to its root mode; revocable per app | built | `e2e-ci` |
| L3 | The dashboard or the studio tab is reached by another local process or a web page | loopback only, per-run bearer token, Host and Origin checks (DNS rebinding), `application/json` only, no CORS, CSP with Trusted Types; destructive actions need a single-use confirm token | built; a malicious browser extension or a process of the admin's own uid is out of scope | `dashboard-test`, `e2e-studio` |
| L4 | A wrong host or a wrong app: `destroy`, `restore`, `reboot` on the wrong node | commands name the host; destroy asks to type the app name; a final backup is kept unless `--purge`; reboot checks other sites and the care window; the bench scripts only touch `fb-*` apps and refuse a host with other apps | partial: `--yes` removes the questions by design | `e2e-cli` |
| L5 | Replayed or duplicated writes from a flaky link | deploys are idempotent by content ("already live"); the dashboard keeps idempotency records | partial: no request ids with a durable result store on the agent yet (planned) | `e2e` |
| L6 | The operator's laptop is lost with the config directory | it holds host entries and keys, not env values (env is set on the server and never passes through the laptop on restore) | built; keep the recovery key outside the laptop | `e2e-offsite` |

### 5.5 Control plane (planned)

An operator who runs many nodes will want a service that drives them. None exists in the tree.
Whatever shape it takes, treat it as the highest-value asset in the system: it would hold a
credential for every node and, to recover a lost node by itself, every tenant's env. Requirements
for it: its own small VM, never on an app node; no node-wide key (per-node, short-lived
credentials with separate read and write principals, validated on the node); every write carrying
a request id and a generation number so a retry returns the first result and an older plan is
refused; env held only encrypted with a key outside the plane's disk; its own audit log; and a
decision, taken once and written down, on whether it may hold tenants' env at all (the price of
automatic recovery). An outside reviewer should ask for this design before any code exists.

### 5.6 Backups and recovery

| # | Threat | Mitigation | Status | Test |
|---|---|---|---|---|
| B1 | Backup contents read in the bucket | encrypted on the node (the object starts with a format marker, no plaintext marker, env values or file names appear) before upload; the recovery key shown once, kept by the operator | built | `e2e-offsite` |
| B2 | A compromised node deletes or overwrites its own backups | a key that may not delete or replace, a bucket lock, a clock check (a node whose clock jumped deletes nothing), `keep_min` newest objects never pruned; `offsite test` shows what the key can do | built; depends on the operator creating the key that way | `e2e-offsite` |
| B3 | A backup that does not restore | monthly restore drill on the node (into a throwaway directory and database), `backup drill`, alert `drill`; the bench's `rebuild-drill.sh` does the whole rebuild | built; the fresh-VM part is manual | `e2e-data`, `bench/rebuild-drill.sh` |
| B4 | Tenant data in a backup that is restored over a live app | `restore` asks and keeps a safety backup; a restore cut short is finished by recovery and marked until it ends | built | `e2e-data` |
| B5 | Losing the recovery key | nothing recovers it: the offsite copy is then unreadable | **open by design**: the key is the operator's to keep (password manager and a second place) | |

### 5.7 Previews

| # | Threat | Mitigation | Status | Test |
|---|---|---|---|---|
| P1 | Unreviewed code gets production secrets or production data | a preview gets no env, database, data, jobs or domains of its parent unless named (`preview_env`), never the database URLs | built | `e2e-ci` |
| P2 | Previews pile up | TTL (7 days by default, 90 at most), hourly sweep, at most 10 per app | built | `e2e-ci` |
| P3 | A preview is a free compute for abuse | it is an ordinary app: same sandbox and limits, `idle_stop`; but it is public as soon as it deploys | partial: a hostile pull request still runs code on the node | |

## 6. Where each limit is enforced (index)

| Resource | Where |
|---|---|
| Memory, tasks, CPU, weights | `props()` and `app_slice` in `server/tando-agent`; [COMMANDS.md](COMMANDS.md#limits-and-load) |
| Per-uid network rules, DNS and connection caps, metadata block | `fw_sync` in `server/tando-agent`; loaded by `tando-firewall.service`; checked each minute by `srv/watch` |
| Per-client edge caps | `rate_limit_rules` in `server/tando-agent` |
| Database limits | `db_limits` in `server/tando-agent`; [COMMANDS.md](COMMANDS.md#database-limits) |
| Disk: release and upload size, app disk alert, 95% stop | `app_max_mb`, `srv/watch`; no quota |
| Journals | journal namespaces per app, `log_budget`; [LOGGING.md](LOGGING.md) |
| Admission of new apps (memory overcommit, ports, uids) | `mem_overcommit`, `port_min`/`port_max`, `uid_min`/`uid_max` in `host setup`; [ARCHITECTURE.md](ARCHITECTURE.md#many-apps-on-one-server) |

## 7. Residual risks

1. **Shared kernel.** Every tenant runs on the node's kernel. A kernel privilege escalation from an
   unprivileged uid (the sandbox shrinks the syscall surface but leaves most of it) gives root on the
   node and every tenant's data. There is no microVM and no gVisor-class boundary. Mitigations
   are outside the design: a current kernel with unattended security updates (host care,
   [HOSTCARE.md](HOSTCARE.md)), user namespaces refused to apps (`RestrictNamespaces`), small nodes
   so that a loss is bounded, and one node per trust class if tenants must not share a kernel.
2. **Container apps bypass the per-uid network rules** (C6) and run under root Podman with their
   own isolation, not the units' sandbox (`props` does not apply to them). Treat `recipe =
   container` as a lower trust class until the cgroup-keyed rules or the sandbox are applied.
3. **No outbound policy beyond caps.** An app can reach any internet address (except metadata),
   send mail directly, and scan. A mail block and an egress rate are planned, not built.
4. **Services tando does not manage on loopback** are open to every app (T3).
5. **Resource limits are best effort where the kernel makes them so**: disk has no quota,
   I/O weight works only under some schedulers, kernel memory is not accounted per cgroup on some
   kernels, a query can take more memory than its role's settings suggest.
6. **The admin has root.** One stolen admin key is every node it is registered on (L1).
7. **One control channel.** ssh to the node is the only management path; its availability
   and its host key are the node's availability and identity.
8. **Backups depend on the operator's bucket policy and key custody** (B2, B5).
9. **Single node, no failover.** A node loss is recovered from offsite backups and artifacts (a
   rebuild, minutes to hours), not by a replica; `bench/rebuild-drill.sh` measures it.
10. **Unmeasured at scale.** Several limits were measured on a laptop, not a 100-app server;
    `bench/fleet.sh` is the harness for that (PID 1 growth per app, reload times, reboot).

## 8. What an outside reviewer should test first

In this order, each with the file to start from:

1. **Escape from a container app** (C6, residual 2): run `bench/container-egress.sh <test host>`;
   then try to reach the metadata address, send mail directly and open many connections from a
   container app. Review `exec_container` in `server/tando-agent`.
2. **Root-follows-tenant-path bugs** (C2): every root verb that touches `shared/`, `data/`,
   releases, `incoming/` or `/tmp` of an app: backup, restore, upload, adopt, destroy, studio
   credential files. `shared_ok` and the restore and receive verbs. Look for symlink, hardlink,
   rename and mount races, and a uid reused after `destroy`.
3. **The gate** (L2): the grammar in `srv/gate`, the binding of root mode to the ssh session through
   /proc, its sudo rule, directory-descriptor upload. Fuzz the request parser.
4. **Per-uid network rules** (T2, T3, C4, C5): everything in `fw_sync`, including what happens
   between a deploy's configure step and the rules loading, a host with another firewall (ufw),
   IPv6, and apps that share a uid (adopted ones).
5. **Noisy-neighbour limits** (T5-T8): run `test/e2e-neighbours.sh`, then try what it does not:
   a hostile app that fills inodes, creates many sockets in `/run`, holds many database
   locks, opens many files, or forks within `tasks` but burns CPU when `cpu` is unset.
6. **The studio and the dashboard** (L3): the SQL guard (section "db studio" in
   [ARCHITECTURE.md](ARCHITECTURE.md#trust-boundaries)) is a guard, not a sandbox; try catalog reads
   through functions and types the app defined, DNS rebinding and Origin tricks against the
   loopback listeners, token replay.
7. **Backups** (B1, B2, B4): decrypt without the key; replay and rollback objects (an older backup
   substituted); what a node with a delete-capable key can do; restore of a hostile backup (a tar with
   absolute paths, links, device nodes) into a fresh app.
8. **Recovery and half-finished operations**: kill a deploy, a destroy and a restore at every
   step (the fault suites do this for one fault at a time: `docs/FAULT-REVIEW.md`), then check that
   recovery neither leaves an app with another app's user nor runs a stale release.
9. **Reboot**: after a node reboot, every app returns, rules reload before apps listen, and
   nothing listens that should not (`bench/fleet.sh` measures the first; check the second with `ss -ltnp`).
10. **Supply chain of the node itself**: what `tando host setup` installs and from where (apt
    packages, Caddy, the Node and Go toolchains), what the agent trusts at upgrade, and what
    the laptop executes from the server's replies (sanitising of names and control characters).

## 9. Maintaining this page

A change that adds a root verb, a listener, a new kind of unit, a new credential or a new place
where the node reads something a tenant wrote belongs in section 4 and 5 in the same commit, with
the check that fails without the mitigation ([AGENTS.md](../AGENTS.md)). Findings from reviews go
in the review documents; the status column here is updated when they are fixed.
