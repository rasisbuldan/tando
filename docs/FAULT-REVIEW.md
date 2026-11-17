# tando fault-injection review

Scope: deploy, rollback, backup, restore, env, destroy and the timers, under injected faults.
Code under test: a snapshot of the tree taken at the start of the run
(`test/.work-fault/tree/`; file:line references below point into that snapshot's
`server/tando-agent` and `lib/deploy.sh`). Servers: `tando-fault` (upstream Caddy) and
`tando-fault2` (`TANDO_TEST_CADDY=ubuntu`, the Ubuntu package 2.6.2-14, as on the real VPS). Both ran
with `--memory 2g --cpus 1`. Every failure listed was reproduced on both servers. The scenarios
are runnable scripts in `test/.work-fault/scenarios/`; exit 0 means robust. Raw logs are in
`test/.work-fault/batch-*.log` and `results-*.tsv`.

## Verdict

tando holds its promise against the faults its design anticipated. A server restart or power
loss at any point of an activation (copy, pre-flight, switch, verify, rollback) recovers on boot to
the right release, and the state stays truthful. Bad releases (exits, hangs, wrong port, crash or
500 only on the live port) are caught and rolled back with zero failed requests. Concurrent deploys,
rollback, env, backup and destroy serialise correctly. The promise breaks when something stops the
activation *without a reboot*, or when the state it relies on is missing:

- **SIGKILL of the activation unit, or a full disk during copy or rollback.** The activation
  freezes in `phase=copy|preflight|switch|verify|rollback` with `result=running`, and the client
  polls forever. Nothing repairs this until a later mutating command runs `recover`. Meanwhile an
  unhealthy release can stay live (a4).
- **A client that dies during the upload** (laptop sleep, dropped network). It blocks every deploy
  for 15 minutes, and the error does not mention `tando unlock`.
- **Lost or stale state.** An empty state file, a deleted rollback target or a deleted `current`
  link leads to a total outage at the next failed deploy or reboot. `doctor` does not see any of it.
- **Caddy-level faults.** Caddy is not restarted when it dies (`Restart=no` in both packages). A
  failed reload leaves `stopped=1` in the state while Caddy keeps serving. Any process holding the
  app's port is accepted as "healthy".

Counts: **76 scenarios, 49 pass, 27 fail.** 7 of the failures leave the app not serving its last
good release, 17 leave state or output untruthful, and 4 need manual repair before the next deploy
works.

## Scenario table

Downtime is the longest gap between two successful requests minus 1 s, from a ~5 req/s loop
through Caddy. "Failed" counts non-200 answers. For restart and power loss, the requests lost
while the container itself was down are expected and are counted anyway.

| id | fault | point | result | downtime s / failed | state truthful | self-recovers |
|---|---|---|---|---|---|---|
| s00 | none (baseline) | normal deploy | pass | 0 / 0 | y | y |
| a1 | SIGKILL activation unit | copy | **fail** | 0 / 0 | n | y* |
| a2 | SIGKILL activation unit | preflight | **fail** | 0 / 0 | n | y* |
| a3 | SIGKILL activation unit | switch (link swapped, old process stopping) | **fail** | 0 / 0 | n | y* |
| a4 | SIGKILL activation unit | verify (release unhealthy) | **fail** (bad release stays live) | 0 / 0 | n | y* |
| a5 | SIGKILL activation unit | rollback | **fail** | 0 / 0 | n | y* |
| a6–a10 | docker restart | copy / preflight / switch / verify / rollback | pass | 0.7/4, 0.6/3, 5.8/24, 0.6/3, 4.8/23 | y | y |
| a11–a15 | power loss (docker kill + start) | copy / preflight / switch / verify / rollback | pass | 1.6/9, 0.8/4, 1.5/8, 0.6/4, 0.4/3 | y | y |
| a16–a20 | systemctl daemon-reload | copy / preflight / switch / verify / rollback | pass | 0 / 0 | y | y |
| b1 | laptop Ctrl-C | upload | pass | 0 / 0 | y | y |
| b2 | laptop killed (SIGKILL) | upload | **fail** | 0 / 0 | y | **n** (15 min lease) |
| b3 | network drop 45 s | upload | **fail** | 0 / 0 | y | **n** (15 min lease) |
| b4 | laptop Ctrl-C | activation polling | pass | 0 / 0 | y | y |
| b5 | network drop 30 s | activation polling | pass | 0 / 0 | y | y |
| c1 | two deploys at once | upload / activation | pass | 0 / 0 | y | y |
| c2 | deploy during rollback | rollback switch | pass | 0 / 0 | y | y |
| c3 | rollback during deploy | preflight | pass (minor message issue, F19) | 0 / 0 | y | y |
| c4 | destroy during deploy | preflight | pass | – | y | y |
| c5 | env set during deploy | preflight | pass | 0 / 0 | y | y |
| c6 | backup now during deploy | preflight | pass | 0 / 0 | y | y |
| d1 | Caddy stopped | deploy (verify) | **fail** (good release rolled back; message says "within -H s") | 0 / 0 | y | y |
| d2 | Caddyfile broken by hand | deploy / stop / start / env | **fail** | 0 / 0 | n | y |
| d3 | Caddy admin socket missing | stop / start / deploy | **fail** | 0 / 0 | n | y |
| d4 | Caddy SIGKILL | verify | **fail** (Caddy stays dead, whole host down) | ∞ / 116 | n | y (after manual start) |
| e1 | app exits at start | deploy | pass | 0 / 0 | y | y |
| e2 | app never listens | deploy | pass | 0 / 0 | y | y |
| e3 | app binds wrong port | deploy | pass | 0 / 0 | y | y |
| e4 | healthy, crashes after 20 s (live only) | after verify | **fail** (verified, flaps forever) | 1.4 / 0 | y | y |
| e5 | memory leak, OOM kill (live only) | after verify | **fail** (verified, OOM loop) | 1.5 / 0 | y | y |
| e6 | current ignores SIGTERM | deploy | pass (switch 21 s) | 0 / 0 | y | y |
| e7 | current forks a child keeping the port | deploy | pass (switch 21 s) | 0 / 0 | y | y |
| e8 | log flood on the live port | deploy | pass | 0 / 0 | y | y |
| e9 | crash only on live port | verify | pass | 4.3 / 0 | y | y |
| e10 | start takes 18 s (Caddy holds 15 s) | switch | **fail** | 17.3 / 1 | y | y |
| e11 | start takes 12 s | switch | pass | 11.3 / 0 | y | y |
| e12 | 500 only on live port | verify | pass | 0 / 0 | y | y |
| f1 | port range exhausted | tando up | pass | – | y | y |
| f2 | pre-flight port held by stray | preflight | pass | 0 / 0 | y | y |
| f3 | app port held by stray answering 200 | start / deploy | **fail** | 0 / 0 (stray answers) | n | y |
| g1 | state file emptied | failing deploy | **fail** (app stopped: "back on nothing") | ∞ / 1+ | n | y |
| g2 | state truncated mid-line | deploy + rollback | pass | 0 / 0 | y | y |
| g3 | history.tsv truncated mid-line | next deploy | **fail** (next row swallowed) | 0 / 0 | y | y |
| g4 | app.conf lost last line (start=) | deploy | pass (pre-flight fails, v2 kept) | 0 / 0 | y | y (tando up) |
| g5 | host.conf emptied | deploy + doctor | **fail** (doctor aborts) | 0 / 0 | n | y |
| g6 | `current` symlink deleted | reboot | **fail** (app down after reboot) | ∞ | n | y (next deploy) |
| g7 | current release dir deleted | restart | **fail** (doctor silent; 502 after restart) | ∞ | n | y (next deploy) |
| g8 | rollback target dir deleted | failing deploy | **fail** (switch to missing dir, 503) | ∞ | y | y (next deploy) |
| g9 | releases/ emptied | deploy | **fail** (doctor silent) | 0 / 0 | n | y |
| g10 | clock jump backwards | deploy + rollback | **fail** (rollback refuses) | 0 / 0 | y | y |
| g11 | activation + lease files garbage | deploy | pass | 0 / 0 | y | y |
| h1 | disk 100% full (app dir) | upload | pass (clear rsync "No space left") | 0 / 0 | y | y |
| h2 | disk full | copy to releases/ | **fail** (client hangs, phase=copy forever) | 0 / 0 | n | y* |
| h3 | /var/backups full | pre-deploy backup, backup now | pass | 0 / 0 | y | y |
| h4 | inodes exhausted | upload | pass | 0 / 0 | y | y |
| h5 | disk fills | verify → rollback | **fail** (state current≠link, client hangs) | 0 / 0 | n | y* |
| i1 | restore of truncated archive | restore | pass | app stopped for the restore | y | y |
| i2 | restore while app writes | restore | pass | 0 / 0 | y | y |
| i3 | PostgreSQL down | pg_dump (pre-deploy, backup now) | pass | 0 / 0 | y | y |
| j1 | app dir half-deleted | watch, ls, doctor, deploy | **fail** ("could not reserve a release id") | – | y | **n** |
| j2 | notifier endpoint hangs | tando-watch | pass (runs ≤1 s, test times out at 15 s) | – | y | y |
| j3 | 50 apps (45 static + 5 node) | watch, views, deploy | pass (ls 3 s, watch 1 s) | 0 / 0 | y | y |
| k1 | agent version differs | deploy + doctor | pass | – | y | y |
| k2 | host setup interrupted | deploy + doctor | pass | 0 / 0 | y | y |
| l1 | 10 failed pre-flights in a row | prune | **fail** (12 releases kept) | 0 / 0 | y | y |

\* "y*": the next deploy works because `cmd_activate` runs `recover` first. Until then the state
lies, the client spins, and a pre-flight unit keeps running.

## Failures: diagnosis and fixes

References are to the snapshot: `server/tando-agent` (A) and `lib/deploy.sh` (D). Since the
snapshot, the working tree has fixed F8 (probe message) and partly F14 (`drop_release`). The rest
are unchanged in the current tree.

**F1 Activation interrupted without a reboot: stale phase, hung client, leaked pre-flight unit
(a1–a5, a4 keeps a 500-ing release live; also h2, h5).** A `cmd_run_activation` (A:858) can end
without `fail`/`finish`, through SIGKILL, OOM kill or an ENOSPC that makes `st`/`pg` no-ops. When it
does, `state.phase` and `activation.result=running` are never updated. `recover` (A:1024) runs only
from mutating verbs and at boot. `cmd_deploy_status` (A:1094) reports `result=running` without
checking that `tando-<app>-act-<id>` is still alive. The client loop (D:144–156) has no deadline;
it only counts ssh errors. The pre-flight unit `tando-<app>-pre-<id>` is a separate transient unit
and keeps running on port+100.
*Fix:* start the activation with `systemd-run -p ExecStopPost="$AGENT recover $A"`. ExecStopPost
runs after the main process dies, even on SIGKILL, and the flock is free by then. In
`cmd_deploy_status`, when `P[result]=running` and the activation unit is not active/activating,
call `recover` and report its result (the client already calls it through sudo). Let the
tando-watch timer run `recover-all` each minute. Give the client a deadline:
health_timeout × 2 + copy budget.

**F2 Upload lease outlives a dead client for 15 minutes (b2, b3).** `lease_live` (A:389) trusts
`started` for `UPLOAD_TIMEOUT=900` s, and `cmd_begin` (A:401) refuses with "another deploy is
uploading". The message does not mention `tando unlock`, even when the holder is this same client.
*Fix:* in `cmd_begin`, treat a lease without an `id` as stale when no `rsync --server` writing into
`incoming/` is running (`pgrep -u "$SUDO_USER" -f "apps/$A/incoming"`) and its age is over 30 s.
Also let the same `who` take its own lease over. Add "tando unlock clears it" to the message.

**F3 Disk full makes state writes silently fail (h2, h5).** `save` (A:69) returns non-zero, but
`st`/`pg` (A:102–103) callers ignore it. h5 ended with `state current=<v3>` while `current ->` v2,
`phase=verify`, and no history line. `fail` at copy (A:867, A:931) leaves the partial
`releases/<id>`, so the space stays used.
*Fix:* in `cmd_activate`, refuse to start when the free space on `$D` is below the size of
`incoming/` plus a margin (`du -s`, `df`). Keep a small reserve file (e.g. `$R/.reserve`, 8 MB)
and delete it when a `save` fails, then retry. `rm -rf "$rel"` in `fail` when the copy failed.
`switch_to` must check that `st current` succeeded before restarting.

**F4 Empty state makes a failed deploy stop the app (g1).** In `cmd_run_activation`,
`fallback=${S[last_good]}` is empty, and `finish` (A:364) then calls `switch_to ""` (A:328), which
stops the unit and deletes `current`. That rule is meant for a first deploy, but it fires for any
deploy that has lost its state.
*Fix:* when `last_good` is empty, fall back to `prev` (the `current` link at activation start) if
that directory exists. Only stop the app when there was no `current` link at all. In `load` of the
state, if the file is empty but `current` exists, rebuild `current`/`last_good` from the link and
the last `ok` row of history.tsv.

**F5 Rollback to a release directory that no longer exists (g8, g7).** `finish` and `cmd_rollback`
switch to `fb`/`to` without `[[ -d $D/releases/$fb ]]`. The unit then fails and `app-down` shows 503.
*Fix:* check that the directory exists before `switch_to`. If the fallback is missing, try the
newest existing verified release. If there is none, keep the current process and report
"no release to roll back to".

**F6 `current` link not repaired; doctor blind to release layout (g6, g7, g9).** `recover` handles
only non-idle phases, so a missing or mismatched `current` link leaves the unit failing at boot
(`WorkingDirectory`). `cmd_doctor` (A:595, apps loop) never compares `S[current]` with
`readlink current` and never checks that the release directory exists.
*Fix:* in `recover`'s `idle` case, if `S[current]` is set and its directory exists but the link is
missing or points elsewhere, recreate the link and restart. In doctor, warn on "current link
missing or mismatched", "current release directory missing" and "no releases on disk".

**F7 Caddy is a single point of failure that tando does not supervise (d1, d4).** Both Caddy
packages ship `Restart=no`, so after a SIGKILL or OOM kill the host serves nothing. A deploy while
Caddy is down rolls back a good release because `via_caddy` gets "connection refused", and the
message never names Caddy.
*Fix:* `cmd_setup` writes `/etc/systemd/system/caddy.service.d/tando.conf` with
`Restart=on-failure`, `RestartSec=1`. `cmd_run_activation` checks `systemctl is-active caddy`
before the switch and fails before switching with "Caddy is not running". tando-watch should alert
on Caddy down.

**F8 Wrong probe message (d1, d4, e2).** `probe` (A:279) uses `$1` after `shift 2`, so the
message reads "no healthy answer within -H s" or "within http://127.0.0.1:4216/health s".
*Fix:* `local to=$1` before the shift (done in the current tree).

**F9 `tando stop` / `app-down` persist state before Caddy accepts it (d2, d3).** `cmd_svc` stop
(A:1648) saves `stopped=1`, then `write_caddy` dies on the failed validate or reload. Status then
says "stopped" while Caddy proxies and the unit runs. `cmd_app_down` has the same order. Doctor's
"caddy admin" check only greps the Caddyfile and says ok while `/run/caddy/admin.sock` is gone.
*Fix:* set `S[stopped]` in memory, run `write_caddy`, and save only on success; otherwise unset it
and die. In doctor, test `[[ -S $CADDY_SOCK ]]`.

**F10 Any process on the app port counts as a healthy app (f3).** `probe` (A:~250) returns on the
first 2xx before it looks at the unit, and `via_caddy` only asks Caddy. With a stray on the port,
`tando start` reports healthy and a deploy is "live in 1.4s" and verified, while `tando-<app>` sits
in `activating` with growing NRestarts.
*Fix:* accept a 2xx only when the unit is `active` and the listener on `C[port]` belongs to the
unit's cgroup (`ss -Hltnp "sport = :$p"` → pid → `/proc/<pid>/cgroup` contains
`tando-$A.service`). Before the restart in `switch_to`, refuse if a process outside the unit
listens on the port, as the pre-flight already does for port+100.

**F11 No soak after verify (e4, e5).** `finish` marks a release verified on the first good answer
through Caddy. A release that crashes after 20 s, or is OOM-killed under MemoryMax, stays
"verified" and flaps. Caddy's hold hides most of it, but restarts every 20 s will drop requests
for slower apps.
*Fix:* after `via_caddy` succeeds, watch `NRestarts`/`ActiveState` for a soak window (default 30 s,
`soak =` in tando.conf) before `status_<id>=verified`. A restart in the window rolls back.

**F12 Cold restart longer than Caddy's hold drops requests (e10).** The new process is started
cold at the switch, even though the pre-flight just proved it. `HOLD=15s` (A:16) is shorter than a
`health_timeout = 60` app's start time. With an 18 s start, there was a 17 s stall and 1 request
failed, which contradicts the README's "so none fail".
*Fix (cheap):* `lb_try_duration` = max(15 s, health_timeout). *Fix (better):* blue/green. Keep the
pre-flight process as the new live one and point Caddy at port+100, alternating ports per release.

**F13 A truncated history line swallows the next record (g3).** `hist` (A:341) appends with `>>`.
If the file does not end in a newline, the new row is glued onto the broken one: the release
disappears from `tando history` and the garbage shows up in the phase columns.
*Fix:* before appending, `[[ -s $f && $(tail -c1 "$f") != "" ]] && echo >> "$f"`. In
`cmd_history`, drop rows whose field count is wrong.

**F14 Failed releases are not pruned (l1).** `fail` exits before `prune` (A:909). After 10 failed
pre-flights, 12 full release copies were on disk. A CI loop on a broken build fills a small disk,
which then feeds F3.
*Fix:* call `prune` (or delete the failed release) in `fail`. The current tree's `drop_release`
does this for the rollback path (`finish`); check that `fail` uses it too.

**F15 Rollback and prune order releases by name, i.e. by the clock (g10).** `cmd_rollback` picks
`$i < $cur` by string compare, and `prune` keeps the 5 newest names. After the clock moved
backwards, rollback found "no earlier verified release". The same happens for ids with `-10`
suffixes (they sort before `-9`).
*Fix:* order by deploy sequence. Store `seq=N` per release in the state (or use history.tsv order)
and use it in rollback, prune and `cmd_releases`.

**F16 Doctor aborts on an empty host.conf (g5).** `cmd_doctor` A:621 reads `H[apps_domain]` under
`set -u` and prints `unbound variable`, so the host gets no report at all. Deploys keep working,
but links lose the public port.
*Fix:* use defaults (`${H[apps_domain]:-}`), and report `fail host.conf "empty or incomplete: tando
host setup"` when `port_min`/`apps_domain` are missing.

**F17 Half-deleted app dir cannot be deployed or repaired (j1).** If `releases/` is missing, as
after an interrupted destroy, `cmd_activate`'s `mkdir` loop fails 100 times and reports
"could not reserve a release id". `tando status` prints `ls: cannot access .../releases`. There is
no hint to run `tando up` or `tando destroy`.
*Fix:* `app()` (or `recover`) recreates the skeleton directories (`releases`, `incoming`,
`shared`). If `state` is missing, say "incomplete app directory: tando up repairs it, tando
destroy removes it".

**Minor, recorded:**
- F18: "pre-deploy backup failed" drops the pg_dump/tar stderr and marks the release `bad` even
  though the release itself is fine (h3, i3).
- F19: c3. When a user rollback overwrites the activation file, the deploying client prints
  "bad; the running app was not touched", although the release had been live. `cmd_deploy_status`
  should read the release's history row when `P[id]` differs.
- F20: `cmd_begin` prints a token even when saving the lease failed on a full disk (h1, harmless
  here because rsync then fails too).
- F21: the pre-flight instance runs against the live `shared/data` at the same time as the live
  process (seen in i2, where two writers interleave in one file). Migrations or single-writer
  stores such as SQLite with WAL see two processes during every pre-flight. Worth documenting.

## Top 5 fixes, by how likely the fault is on a 2 GB single-CPU VPS

1. **F1 + F3: self-healing activations (ExecStopPost recover, deploy-status liveness, disk-space
   gate and reserve, prune on failure F14).** OOM kills of the activation and full disks are the
   most common faults on a 2 GB box. Today each one leaves a hung client, a lying state and, in a4,
   an unverified release serving indefinitely.
2. **F2: stale upload lease after the laptop sleeps or the Wi-Fi drops.** This happens to every
   laptop user eventually and blocks deploys for 15 minutes with a misleading message.
3. **F7: supervise Caddy (Restart=on-failure drop-in, pre-switch check, alert).** One Caddy crash
   takes every app down until someone notices, and a deploy at that moment rolls back a good
   release.
4. **F11 + F12: soak after verify, and hold requests at least as long as the app takes to start.**
   Apps that leak memory into MemoryMax or crash shortly after start are routine at 128–256 MB
   caps. Slow cold starts (Next.js, Python) beyond 15 s drop requests on every deploy.
5. **F4 + F5 + F6: never switch to "nothing" or to a missing directory; repair `current` from state
   in recover; doctor checks link, state and releases.** These are less frequent (they need power
   loss on a filesystem without rename durability, or a manual cleanup), but each one turns an
   ordinary failed deploy or reboot into a full outage.

## Notes on method

- Fault points were reached with release behaviours in a test app
  (`scenarios/app/server.js`, words in a shipped `BEHAVIOR` file): slow pre-flight
  (`slow@pre:N`), an old process ignoring SIGTERM to hold the switch phase open, `unhealthy@live`
  for verify and rollback, and 12 000 files for copy.
- Disk faults used tmpfs mounts (size or `nr_inodes`) over `/opt/tando/apps/<app>` or
  `/var/backups/tando` inside the container. The network drop was an nftables rule on port 22 in
  the container. The clock jump was simulated by renaming release ids into the future, because
  changing the clock in a privileged container would change the shared VM clock.
- The truth check compares served version, `state` (phase, current, status of current), the
  `current` link, the activation result, and `tando status/releases/history/doctor`.
- Both containers were removed at the end.
