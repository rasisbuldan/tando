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
| env | the parent's, minus `preview_skip` names and what the server sets itself (PORT, DATABASE_URL...) |
| data | none (an empty `data/`); no database. A preview that needs one gets it from its env (a shared staging database), or from a later `--db` round |
| expiry | `preview_ttl` (default 7d, at most 90d); `tando-previews.timer` (hourly) runs `tando-agent preview-sweep`, which destroys expired previews with their user, unit, site and files. `tando preview up` again renews it |
| limit | 10 previews per app at once (each one runs an app) |

**Name.** `<app>-<slug>`, 24 characters at most (the app name may be 18). The slug is the branch
lower-cased with every other character as `-`. A branch that had to change (`feature/Login`) or
was too long gets `-<4 hex>` of a checksum of the real branch name at its end, so `feature/login`
and `feature-login` never share an app; a branch that is already a slug keeps its name.

**Env rule.** One line in tando.conf names what a preview must not get:
`preview_skip = STRIPE_SECRET_KEY, SMTP_PASSWORD`. Everything else is copied, once, when the
preview is made (later `tando env set` on the parent does not reach it); the first `up` says how
many variables were copied and how to leave one out. The default is copy-all because a preview that
cannot start is worse than one that has a staging key; the warning is the price. The list lives on
the server (sent with the parent's deploy), so a CI deploy key gets the same rule.

**Who may do what.** `tando preview up|ls|rm` is the admin's. A CI deploy key of the parent may
`up` and `rm` previews named `<app>-<name>` of its own app only, and deploy to them:

- the gate (`srv/gate`) knows two more verbs for a key, `preview-up <app> <preview> [ttl]` and
  `preview-rm <app> <preview>`; the name must be `<app>-<slug>` of the key's own app, checked in
  the request parser, in root mode (the name comes on stdin, like a lease token) and again by the
  agent, which makes or removes only an app whose `preview_of` is that app;
- a preview gets a deploy user of its own, `tando-d-<preview>`, whose key list is a copy of the
  parent's (same key ids), made by root mode after `preview-up` (or by `tando-gate admin
  preview-keys` for an admin's `tando preview up`). Every rule of the gate then holds for it as for
  any app: one app per uid, exact sudo rule, confined receiver, checked activation. `tando ci
  revoke` and `rotate` of the parent rewrite the copies and end their sessions;
- the sudo rule of a deploy user has two more exact commands: `tando-gate root <app> preview-up` and
  `preview-rm`;
- a preview has no previews; a key cannot reach another app's previews or any other verb.

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
2. database: a throwaway database `tando_drill_<app>` is created, the dump is restored into it with
   `pg_restore` (exit status must be 0), the tables restored must equal the tables the dump lists,
   and the rows are counted;
3. both are removed, whatever happened; the live data directory, database and app are never
   touched (the app keeps running; its lock is held only to record the result).

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
