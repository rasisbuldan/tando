# Preview apps and the restore drill

Design note and reference for two features of 0.3.0. Commands: docs/COMMANDS.md (`preview`,
`backup drill`). CI: docs/CI.md, "Preview apps from CI".

## Preview apps

A preview is a temporary copy of an app for one branch: `<app>-<branch>`, on its own link
(`<app>-<branch>.<apps_domain>`), made by `tando preview up` or by a pull request in CI.

**What it is.** An ordinary tando app (own user, port, unit, Caddy site, deploy history) that the
server makes from its parent's settings:

| | |
|---|---|
| code | deployed from the checkout (`tando preview up` builds and uploads it like `tando deploy`) |
| settings | the parent's (start, health, memory, limits, workers); `idle_stop` 6h unless the parent set a time; no `job.*`, no `domain`, no `backup`, no `database` |
| env | only the parent's variables that `preview_env` names (none by default), minus `preview_skip`; never its database URLs or paths |
| release | none: the parent's `release` command (migrations) is left out unless `preview_release = on` |
| data | none (an empty `data/`); no database. A preview that needs one gets it from its env (a shared staging database), or from a later `--db` round |
| expiry | `preview_ttl` (default 7d, at most 90d); `tando-previews.timer` (hourly) runs `tando-agent preview-sweep`, which destroys expired previews with their user, unit, site and files. `tando preview up` again renews it |
| limit | 10 previews per app at once (each one runs an app) |

**Name.** `<app>-<slug>`, 24 characters at most (the app name may be 18). The slug is the branch
lower-cased with every other character as `-`. A branch that had to change (`feature/Login`) or
was too long gets `-<4 hex>` of a checksum of the real branch name at its end, so `feature/login`
and `feature-login` never share an app; a branch that is already a slug keeps its name.

**Env rule.** A preview is code nobody has reviewed yet, on a public link. So it gets nothing of
the parent's env by default: `preview_env = API_BASE, FEATURE_FLAGS` in tando.conf names what it
does get, copied once when the preview is made (later `tando env set` on the parent does not reach
it; `tando env set -a <preview>` sets more), minus `preview_skip`. Never copied, even when named:
`DATABASE_URL`, `DATABASE_URL_DIRECT` (also with an external or managed database: that would be
production's), `DATABASE_PATH`, `TANDO_DATA_DIR`, `PORT`, `HOME`, and any value that names the
parent's database role (`tando_<app>`) or its directory. Give a preview a staging database by
naming a variable that holds one (`STAGING_DATABASE_URL`), or set it on the preview.
The first `up` says how many variables were copied and how many left out. The lists live on the
server (sent with the parent's deploy), so a CI key gets the same rule.

**Release command.** Left out by default: the parent's `release` (migrations) would run the
branch's migrations against whatever the env points at. `preview_release = on` keeps it (for a
preview whose env points at its own staging database only).

**Who may do what.** `tando preview up|ls|rm` is the admin's. A CI deploy key of the parent may
`up` and `rm` previews named `<app>-<name>` of its own app only, and deploy to them. For pull
requests use a key made for that, `tando ci setup --previews`: it may do the same, and read the
app's status, but root mode refuses it every verb on the app itself (begin, receive, activate,
end), so the branches that can read it can never deploy production. The production key stays
limited to `main` (docs/CI.md):

- the gate (`srv/gate`) knows two more verbs for a key, `preview-up <app> <preview> [ttl]` and
  `preview-rm <app> <preview>`; the name must be `<app>-<slug>` of the key's own app, checked in
  the request parser, in root mode (the name comes on stdin, like a lease token) and again by the
  agent, which makes or removes only an app whose `preview_of` is that app;
- a preview gets a deploy user of its own, `tando-d-<preview>`, whose key list is a copy of the
  parent's (same key ids), made by root mode after `preview-up` (or by `tando-gate admin
  preview-keys` for an admin's `tando preview up`). Every rule of the gate then holds for it as for
  any app: one app per uid, exact sudo rule, confined receiver, checked activation. `tando ci
  revoke` and `rotate` of the parent rewrite the copies and end their sessions, under one lock
  for every key list (a copy read before a revoke is never written after it); a copy that could
  not be written makes the revoke fail and names the preview user;
- destroying the parent destroys its previews first, and the gate empties the key copies of any
  preview of an app it removes;
- the sudo rule of a deploy user has two more exact commands: `tando-gate root <app> preview-up` and
  `preview-rm`;
- a preview has no previews; a key cannot reach another app's previews or any other verb;
- making a preview holds a host lock over the name check, the count (10 at most) and the
  creation, and creates only: an app made under that name in the meantime is never taken over.

Not covered this round: a database for a preview (`--db copy`), previews listed inside `tando ls`
and the dashboard (they appear as ordinary apps named `<app>-<branch>`; `tando preview ls` lists
them apart), a preview's own domain, copying a data directory.

## The restore drill

A backup nobody has restored is a hope. `tando backup drill [app]` (agent verb `backup-drill`)
takes the newest local backup of an app (or fetches it from offsite) and restores it into a place
of its own on the same server:

1. data: `data.tar.gz` is unpacked as the app's user into `shared/.drill-<pid>` (so a planted link
   cannot make root write elsewhere); the files restored must equal the regular files the archive
   lists;
2. database: a throwaway database `tdrill_<app>` is created (not `tando_...`: that prefix is every
   app's own database, so no app, not even one called `drill-<x>`, can own this name), owned by the
   app's role, with no access for PUBLIC and marked as a drill database. The dump is restored into
   it with `pg_restore` as the app's own role, exactly like `tando backup restore` (the dump is the
   app's: a function, an index or a view in it never runs with more than the app's rights), the
   exit status must be 0 (only the code is kept: its messages may hold the app's rows), the tables
   restored must equal the tables the dump lists, and the rows are counted, as the app's role too,
   with `search_path = pg_catalog` and every function schema-qualified. The superuser only creates
   and drops the empty database. A database of that name that is not a drill database of this app
   is never dropped: the drill fails and says so;
3. both are removed, whatever happened; the live data directory, database and app are never
   touched (the app keeps running; its lock is held only to record the result).

**Disk.** Before anything is unpacked the drill adds up the sizes the archive lists (its real size,
however well it compressed) and takes the live database's size (`pg_database_size`), and checks the
disk of the apps and the disk of PostgreSQL's data (the same one when they share it): each must
keep 256 MB to spare afterwards, or the drill fails with why and restores nothing.

The result is in the app's state (`drill_at`, `drill_result`, `drill_id`, `drill_why`,
`drill_files`, `drill_tables`, `drill_rows`, `drill_secs`), shown by `tando backup ls` (and in its
`--json` as `drill`), by `tando doctor` (a failed drill, or none in 40 days on an app older than
that), and raised by tando-watch as the alert `drill` for an app with daily backups when the last
drill failed (it resolves with the next one that works).

**Schedule.** `backup_drill = monthly|off` (`tando host setup <host> backup_drill=off`, default
monthly). `tando-drill.timer` fires on the 1st of the month five minutes after the backup window
opens (`backup_window`), and `backup-drill-all` waits for the backup queue (`tando-backups.service`)
to finish, then drills the apps one at a time in the queue's order, none after the window's end. So
a drill never competes with a backup and never takes more than one backup job's worth of load.
