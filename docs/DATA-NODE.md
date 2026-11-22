# Data nodes: PostgreSQL on its own server

By default every server tando sets up holds its apps' PostgreSQL itself (one cluster, a role and a
database per app, pgbouncer in front). Nothing on this page changes that. A **data node** is the
other layout: one server runs only PostgreSQL and pgbouncer, and **app nodes** run the apps with no
database of their own. An app node then holds nothing that cannot be redeployed: its releases come
from the deploy, its database lives on the data node, its files in object storage (or in its
backups). Losing an app node loses no data.

```
operator's tando (laptop or control plane)
   |  ssh: data-link, data-db ensure|drop        ssh: configure, db-link, db-remote-set
   v                                              v
data node  <------- TLS (verify-full) -------  app node(s)
PostgreSQL :5432, pgbouncer :6432              apps; per-app role's password only
```

## Set up

```
tando host add db1 admin@203.0.113.20
tando host setup db1 role=data
tando host add app1 admin@203.0.113.21
tando host setup app1
tando host link app1 db1
```

- `host setup <h> role=data` installs PostgreSQL and pgbouncer, sized from the server's RAM as on
  any server (docs/COMMANDS.md, "Database limits"). Both listen on every address of the node, with
  TLS. The certificates come from a CA made on the node (`/etc/tando-data/`: the CA key never
  leaves it), or from your own: `data_cert=/path data_key=/path data_ca=/path` (files on the
  server; setup checks that the key matches and the CA signs the certificate).
- `host link <app-node> <data-node> [app_addr=A] [data_addr=B]` registers the app node on the
  data node and pins the data node's CA on the app node (`/opt/tando/db-ca.pem`). By default the
  addresses are each node's source address towards the internet; give `app_addr` and `data_addr`
  for a private network. A `data_addr` the node's certificate does not name yet is added to it
  (a new certificate, read by a reload: no connection drops).
- An app node with local databases is refused: link it before its first app with a database.

## What is enforced where

| Layer | Data node | App node |
|---|---|---|
| Firewall (nft, table `inet tando`) | 5432 and 6432 accept new connections only from linked app nodes; anything else gets a TCP reset | the per-app rules that already guard the local ports also apply to the data node's address: only apps with `database = postgres` reach it, at most `db_pool` x 20 connections each |
| pg_hba | one `hostssl <role>,tdrill_<app> <role> <app-node>/32 scram-sha-256` line per project: a role logs in only from its own app node, only with TLS | — |
| pgbouncer | `auth_type = hba` with the same per-project lines (TLS for every address but the loopback) | — |
| Role limits | `CONNECTION LIMIT db_pool + 5`, `statement_timeout`, `idle_in_transaction_session_timeout`, `temp_file_limit` (the per-app settings of docs/CONFIG.md "Database limits") | — |
| TLS | PostgreSQL and pgbouncer present the node's certificate | `sslmode=verify-full&sslrootcert=/opt/tando/db-ca.pem` in both URLs: the CA and the address must match |

The superuser of the data node stays on the data node. Provisioning goes from the operator's
tando to the data node (`data-db ensure`), which returns a new role's password once; tando pipes
it to the app node (`db-remote-set`, on stdin), where it lives only in the app's env, as it does
on a single server. The app node cannot create, drop or alter any role or database.

## An app on an app node

Nothing changes in `tando.conf`: `database = postgres` on an app whose server is linked gets its
role and database on the data node. Each `tando up` (or `deploy`):

1. configure on the app node says the database is remote (`db_remote=`) and which limits the
   app's settings ask for;
2. tando asks the data node to make or update the role and database (and the limits; a new
   password only when the app node has none yet);
3. the app's env gets `DATABASE_URL` (pgbouncer, 6432; 5432 with `db_direct = true`) and
   `DATABASE_URL_DIRECT` (5432, for migrations), both pointing at the data node with TLS.

Limits follow the deploy that set them: on a data node they change at configure, not at the
switch, so a deploy that does not go live leaves its new limits set (the next deploy sets them
again).

## Backups, restore, the drill, the studio, monitoring

- **Backups** run on the app node as before, with the app's own role: `pg_dump` connects to the
  data node over TLS (verify-full) and the dump goes into the same backup as the app's files
  (`db.dump`), copied offsite as usual (docs/BACKUP.md). One backup per project.
- **Restore** stops the app, takes the safety backup and runs `pg_restore --clean` against the data
  node with the app's role. On a single server tando lifts the role's `temp_file_limit` for the
  restore; on a data node it cannot (that needs the superuser), so a restore that needs more
  temporary space than `db_temp_limit` fails: raise `db_temp_limit`, deploy, restore again.
- **Restore drill** (`tando backup drill`, monthly): the data node makes an empty `tdrill_<app>`
  database with each project, owned by the app's role. The drill empties it, restores the backup
  into it as the app's role, counts tables and rows, and empties it again.
- **db studio**: the helper reads `DATABASE_URL_DIRECT` and connects to the data node with TLS,
  checking the certificate against the pinned CA (verify-full); a remote URL without
  `sslmode=verify-full` and an `sslrootcert` is refused. The studio service may reach the data
  node's address (its `IPAddressAllow`). Lowering the priority of the studio's backend process is
  a local-only feature and does nothing on a data node.
- **Monitoring**: tandod on the app node does not ask PostgreSQL (it has none) and raises nothing
  about it. tandod on the data node watches its PostgreSQL for the projects it holds: server
  down, connection slots, each project's database size and numbers.
- **`tando db`** (db-info) asks the data node as the app's role.

## Destroy, previews, unlink

- `tando destroy` takes the final backup (through the data node) and then drops the project's
  database, drill database and role on the data node and removes its pg_hba lines. When the data
  node cannot be reached, the command says how to drop it later.
- Preview apps get no database, as on a single server.
- An app name is one project on a data node: two app nodes cannot both have a `shop` with a
  database on the same data node (the second is refused).

## Not covered yet

- Moving an existing app's database from a single server to a data node (a dump and restore by
  hand works: `tando backup now`, link, deploy, `tando backup restore`).
- `host unlink` from the CLI (the agent verb `data-unlink` exists and refuses while projects of the
  node remain), replicas and failover, point-in-time recovery.
- Container apps: `/opt/tando/db-ca.pem` is not mounted into the container; set the URL's
  `sslrootcert` to a path inside the image.
- The connection limit of pgbouncer per project is `db_pool`; PostgreSQL itself has no size quota:
  watch the database sizes on the data node (tandod records them).
