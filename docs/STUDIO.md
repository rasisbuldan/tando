# The database studio as one service per server (design)

`tando db studio` used to start one program per ssh session (a transient unit as the app's
user, at most 2 per server). From this version it is one always-on service per server,
`tando-studio.service`, that serves every app with a database. This page says who it runs as,
what it may reach and what it costs when nobody uses it. The guarantees of the review
(docs/ARCHITECTURE.md "db studio": read-only, scope guard, limits, the page's checks) are
unchanged: the code that enforces them is the same and runs in the same place.

## Two processes: a front as root, a helper per app as the app's user

- **The front** (`tando-studio service`, the unit's main process, uid 0). It listens on unix
  sockets only, holds the codes and the bearer tokens, checks Host, Origin, Sec-Fetch-Site and
  the token of every request, and forwards each API request to the helper of the app it names.
  It never connects to PostgreSQL, never reads an env file and holds no password. Its only
  privileges are CAP_SETUID and CAP_SETGID (the unit's bounding set: no CAP_DAC_OVERRIDE, no
  CAP_SYS_ADMIN, no CAP_NET_*), used for one thing: starting a helper as an app's user.
- **A helper** (`tando-studio serve --fd`, one per browser session and app, started on the first
  request for that app). It is today's per-session studio, unchanged in what it enforces: it runs
  as the app's user (`user=` of app.conf, else tando-<app>) with that user's primary group and no
  supplementary groups, reads the app's DATABASE_URL from the app's env file itself (root:<app
  group> 0640: the app's user may read it, the front does not need to), connects to
  127.0.0.1:5432 as the app's role (the loopback firewall lets only an app's uid reach 5432), and
  answers on a listening socket the front made and passed to it (fd 3) in a directory only root
  can enter. It exits after 120 s without a request and closes its database connection after 60 s.

Why this and not a `tando_studio` PostgreSQL role with per-database read-only grants: that role
would read every app's database from one process (the per-app separation would rest on the
front alone), its grants would need upkeep on every migration (new schemas, new tables of other
owners), and its connections would need a pg_hba and firewall change. Why not a dedicated
unprivileged user for the front: starting a process as another user needs CAP_SETUID anyway.

So a bug in the code that reads hostile database content (pgwire, the result writer) gives what
it gave before: one app's user with its own role. The new part is the front, which parses only
HTTP from the admin's tunnel, as root without file or system capabilities. A compromised front
could start a helper as any app's user, which the admin who reaches it (a sudoer) can do anyway.

## Who reaches it

- `/run/tando-studio/ctl` (root 0600, in a root 0711 directory): the root agent mints codes
  there (`tando-agent db-studio-code`, admin logins only; a CI deploy key is refused by the gate,
  its sudo rule and the agent).
- `/run/tando-studio/u/<login>/s`: one socket per admin login, created on that admin's first
  code and chowned to that login (0600). The admin's `ssh -L` reaches their own socket only.
  A token works only on the socket of the admin it was minted for.
- Codes: 256 bits, single use, 60 s, bound to the admin, the app the link opens on and the
  laptop port (the Host check). Tokens: 256 bits, bound to the admin and the port, expire after
  12 h without a request; restarting the service (`tando db studio --stop`, host setup) revokes
  every token.
- One token reads any app with a database (the page's switcher): the admin is root on the server
  and could open any app already. Each request names its app (`/api/a/<app>/...`; without it, the
  app of the link); a helper serves one app only.

## Limits and idle cost

- Helpers: at most 2 per app and 4 in all; a new one past the limit replaces the one unused the
  longest, or is refused (503) when all are busy.
- Idle: no helper, no database connection, the front alone (a Go program waiting on its sockets,
  about 6-10 MB RSS). The unit: MemoryMax=128M for all of it, CPUWeight=20, Nice=10, idle I/O
  class, TasksMax=64. Each helper keeps GOMEMLIMIT=24MiB and the result caps of srv/studio.
- The database backend of a helper is still moved to a CPUWeight=1 scope: the helper names its
  pid, the front drops a request file in `/run/tando-studio/lower/`, and a path unit runs
  `tando-agent db-studio-lower` (root, outside the sandbox), which checks the pid exactly as
  before (child of the postmaster, the app's role and database, the studio's application_name)
  before it moves it.

## Compatibility

- An old client calling the old `db-studio` verb: "update tando on this computer".
- A new client and an old agent (no `service=1` from `db-studio-ls`): the old per-session flow.
- Host setup writes and starts the unit, and stops and removes what the per-session studios
  left (their units, credentials and directories).
