# tando dashboard: spec v2 (after adversarial review and owner decisions)

Supersedes v1. B1-B5 and S1-S6 refer to the adversarial review of v1 (B = blocker, S = should fix;
the review itself is not in the repository). The design guideline is docs/DESIGN.md.

## Owner decisions (21 Nov)
- Stack: React + Vite + TypeScript + shadcn/ui (Tailwind + Radix, copy-in) + **Recharts kept**.
- Logs: in the dashboard everywhere (web and Mac), read-only, never stored.
- Platforms: web (tando-dash on macOS and Linux) + a Mac window that is part of the existing
  menu bar app, built locally by its installer (no downloaded .app, no Gatekeeper block).
- Writes in the first release: deploy, rollback, stop / start / restart, env set.
- Layout: left sidebar. As light and performant as possible, the smoothest, complete data,
  concise copy. Design language and conciseness of the owner's reference project.

## Architecture
- **Main package (lean, bash):** new client verbs, all `--json`:
  - `tando snapshot --json [-H host] [--app A] [--range 1h|24h|7d]` (`--range` without `--app`: the host series, for the Server page): ONE ssh exec per host per
    refresh (built like `top_fetch`, lib/cmd-top.sh): status, host row (load, memory, disk,
    clock, versions), alerts, and for the selected app: releases, history (with deployer),
    metrics (gap-filled buckets), health series. (B1, B2)
  - `env-names` agent verb: key names only, not audited as a reveal, refused by the gate. (B4)
  - `--json` for doctor, jobs, requests (with per-minute series), backup ls; `series` in health
    and errors; history in alerts. (B2)
  - `state_reason` in status JSON (down vs stopped vs failed), so the UI never re-derives it. (S4)
  - History gets the deployer (from the audit `who`). (B2)
- **Add-on `tando-dash` (Go, no third-party deps):** serves the built web app (go:embed) on
  127.0.0.1 and an API; calls ONLY the tando CLI from a fixed allowlist of exact argv shapes
  (never a shell, names validated with tando's own rules; `health --forget`, `env ls` refused).
  - Reads: `snapshot` per host; on-demand `doctor`, `host status` (at most once a minute: hostcare).
  - Logs: at most one follow stream per (host, app), fanned out to tabs over SSE; at most 3 ssh
    sessions per host from tando-dash; a stream stops 30 s after its last viewer. (B3)
  - Writes: `deploy` (in the app's recorded project folder, from `tando`'s last-deployed-from
    record; refused if the folder is missing or another machine deployed last), `rollback [id]`,
    `stop`, `start`, `restart`, `env set KEY` (value sent in the request body, passed on stdin,
    never logged, never read back), and `host rename <old> <new>` (the Server page's Rename: a
    host-wide write that waits for no app write of the host and holds them all off; refused when
    the new name is a host already; the page moves to the new name). Each write needs a per-action confirm token issued by the
    server when the confirmation dialog opens (single use, 60 s), on top of the session cookie.
    Runs one write per app at a time; streams its progress (the CLI's output) to the page; the
    audit line's `from` says "dashboard".
  - Session: one-time code in the opening link, exchanged for an `HttpOnly; SameSite=Strict;
    Path=/` cookie (long-lived, so a tab left open survives reloads). Host, Origin, Sec-Fetch and
    JSON-only POST checks as in srv/studio; no CORS; CSP `default-src 'self'`, no inline styles
    or scripts (Trusted Types). 127.0.0.1 only. `~/.config/tando/dash.lock` (0600) holds port and
    re-open URL: a second `tando-dash` reuses the running one. (B5)
  - Writes `~/.config/tando/cache/ls-all.json` after each overview refresh; the menu bar app reads
    it instead of polling while tando-dash runs. (S2)
  - Refuses to start when the tando CLI is older than the version it needs (proto / version). (S6)
- **Mac window:** the menu bar app gets "Open dashboard": a WKWebView window that starts
  tando-dash if needed and loads it (same cookie flow). Built locally by `tando menubar install`.
- **Distribution:** `tando addon install dashboard` (main CLI, small) downloads
  `tando-dash-<v>-<os>-<arch>.tar.gz` (universal darwin; linux amd64/arm64) of the matching
  version from the GitHub release, checks SHA-256, removes quarantine only from verified files.
  `tando addon uninstall dashboard` removes binary, web files, dash.lock and the menu item. The
  main release archive contains nothing of the add-on (install-test checks it).

## Budgets (Recharts kept: these are the ones to hold anyway)
- JS: first route <= 150 KB gzipped (Recharts loaded only with the first chart, lazy chunk);
  CSS <= 15 KB. No shadcn `chart.tsx` (inline style breaks the CSP): Recharts styled with CSS
  variables. Animations off on every chart (`isAnimationActive={false}`).
- Charts: <= 1,500 points each (downsampled on the server side by the bucket choice), memoised
  so a poll that changes nothing re-renders nothing.
- First paint of the shell <= 150 ms; first data <= 1 s warm, 3 s cold. CLS 0 (fixed-size
  skeletons).
- Tab hidden: 0 polls; laptop CPU idle < 0.5 %; tando-dash RSS <= 30 MB.
- Server: <= 1 snapshot exec per host per 15 s while visible, 1 per 60 s for hosts off screen.
  Since the live views: while visible, one `snapshot --json --follow` per host instead (a line every
  5 s from one ssh session; README.md, "Live"), an app's own snapshot at most every 10 s.

## Data rules (S3)
- Metrics keep 3.5-7 days: a "7d" chart has a fixed domain with a "data since" label.
- Missing buckets are nulls (gaps), never interpolated. Restarts plotted as per-bucket deltas.
- Chart "now" is the server's clock; show skew when over 30 s. Times in GMT, as the CLI.
- Deploy markers on time charts. The Nov 2026 memory definition change shows as a note.

## Pages (left sidebar: Overview, Alerts, Deploys; then servers with their apps)
1. **Overview:** needs attention first; per server: reachable, load, memory, disk, headroom (sum
   of memory caps vs RAM; disk "full in N days" when enough points); every app in one table,
   sortable by state, memory, CPU, restarts, last deploy.
2. **Deploys (all apps):** a timeline of recent deploys across apps with phase bars and results.
3. **Alerts:** firing and pending across servers; history; where notifications go.
4. **Server:** the observability sections (CPU, Memory, Disk, Network, Pressure, Monitoring cost;
   1h/24h/7d; below); disk gauge; alerts; doctor (on demand); host to-dos; backups line (last,
   offsite); its apps; "Database studio".
5. **App:** header (state + reason, release, link, actions: deploy, rollback, restart, stop/start)
   and tabs:
   - Overview: memory, CPU, restarts charts; slice row (throttled, OOM kills, tasks, memory
     pressure); probe p95 24h; uptime and incidents; workers; database line (size, connections
     vs limit); firing alerts.
   - Database (apps with a database): see "Observability pages".
   - Deploys: history with phase bars and deployer; releases (live, rollback target, rollback
     button per release).
   - Logs: tail with level/text/worker/release filters, follow.
   - Traffic: requests per minute by status class, p50/p95, slowest paths, error groups with
     7-day sparklines.
   - Jobs: schedule, next runs, past runs (result, duration).
   - Env: names only, the change log with notes, "set a variable" (write-only).
   - What changed: between two releases, env changes and deploy notes.
   Cut from v1: the Backups page (a line), the job output viewer (M-later). The Database page of v1 is the Database tab above.

## Database studio (owner, 21 Nov: a new tab, opened directly; never a view inside the dashboard)
- The server's studio is always on (docs/STUDIO.md). Under each app with a database (`database` in
  its status row) the sidebar has a "Database" row; the app header and the Database tab have "Open
  database"; the Server page has "Database studio" (it opens on the server's first app with a
  database; the studio's own page switches apps). **A click opens the studio in a new tab at once:
  no dialog, no confirmation.** The page opens the tab on the click itself (a pop-up blocker lets
  it through), then sends it to the link when the answer comes; on a failure the tab closes and a
  one-line notice says why. The studio's page trades the code itself; its key never passes through
  tando-dash; no proxy.
- `POST /api/studio/open {host, app}` (session cookie and the usual Origin / JSON checks; no
  confirm token, no Idempotency-Key: a double click mints two codes, which is harmless) answers
  `{url, host, app}`: a fresh one-time link (`http://127.0.0.1:<port>/#c=<code>&app=<app>`, works
  once, within a minute), never logged, never written to disk.
- **One lazy ssh forward per host.** The first click starts `tando db studio <app> -H <host> --json`
  (exact argv in the allowlist) as a long-running child: its first stdout line is the link. Every
  later click on the host, for any app, writes `mint <app>` (the name validated first) on the
  child's stdin and reads one more line: a fresh code on the same port (the CLI's `--json` mode,
  lib/studio.sh). A line `{"error":"..."}` is the answer's message and the forward stays. The
  forward closes after 30 min without a click (SIGTERM to the child's group); the next click starts
  a new one. At most 4 forwards in all, counted apart from the 3-per-host limiter of reads and
  log streams (the forward is its own ssh connection). A tando CLI older than this
  change ignores `mint`: the second click then times out after 45 s and closes the forward (the
  dashboard wants the tando of its own version).
- Never orphaned: the child's stdin is a pipe tando-dash holds; `--json` ends the forward at its
  EOF (tando-dash died). On shutdown every child's group gets SIGTERM. The children's pids are in
  `cache/dash-studios.json` (0600); a tando-dash started after a crash sends SIGTERM to each one
  whose command line is still that studio's (pid leads its group), then empties the file. A child
  that ends on its own (lost ssh, sleep) is noticed; the next click starts a new one.
- Removed with the per-session studio: the confirm token of kind `studio`, the Idempotency-Key
  and its memory, one-studio-per-server slots, Stop (`/api/studio/stop`), the `studios` list in
  the overview poll, the confirmation dialog.
- The audit line's `from` says `dashboard` (TANDO_FROM, as for writes).

## Observability pages (owner, 21 Nov: a cloud VM's monitoring tab, concise)
- **Server:** the sections CPU, Memory, Disk, Network, Pressure and Monitoring cost, 20 charts from
  `host_metrics` (`series`, `extended`, `monitoring`; docs/COMMANDS.md "snapshot"). Sections fold;
  charts below the fold draw lazily. Steal and swap carry no alert styling. DESIGN.md "Observability".
- **App Overview:** a slice row: CPU throttled %, OOM kills in the range, tasks against the limit,
  memory pressure (from the app's `metrics.series`).
- **App Database tab** (apps with a database; its own lazy chunk): connections by state against the
  max, commits and rollbacks per second, rows per second by kind, cache hit %, deadlocks, temp
  bytes, longest transaction and longest idle-in-transaction, wraparound %, size and growth a day,
  the top queries when present (query text is always rendered as text), "Open database".
- Budget unchanged: first route <= 150 KB gzipped; the Server page and the Database tab are lazy
  chunks (checked by `npm run check:size`).

## Milestones (implementation: Opus for critical parts, Sonnet for straightforward ones)
- **M1 data + server (Opus):** `snapshot --json`, `env-names`, `state_reason`, deployer, host
  row in JSON; a JSON contract test (test/json-contract.sh, key:type schemas, stub ssh);
  tando-dash core: session, allowlist, snapshot cache and poll policy, gate tests.
- **M2 shell + read pages (Sonnet, from the design guideline):** sidebar, Overview, App
  Overview, Deploys tab, Server page; Recharts lazy; budgets checked in a test.
- **M3 logs + streams (Opus):** SSE fan-out, session cap, Logs tab.
- **M4 writes (Opus):** confirm tokens, deploy/rollback/restart/stop/start/env set, progress
  streaming, audit `from`.
- **M5 remaining pages (Sonnet):** Alerts, all-apps Deploys timeline, Traffic, Jobs, Env, What
  changed; the remaining `--json`.
- **M6 Mac window + add-on packaging (Sonnet, with an Opus review):** menu bar "Open dashboard",
  `tando addon install`, release assets, menu bar reads the shared cache.

## Tests (cheap, local)
JSON contract test for every `--json`; Go httptest for tando-dash (Host/Origin/cookie, argv
allowlist incl. refused shapes, confirm tokens, stream fan-out and cap, version check); vitest on
data shaping (gaps, restart deltas, skew, sort) and a bundle-size check; gate tests for new verbs;
one browser smoke test before a release.

## Idempotency, failure handling, robustness (owner, 21 Nov; web and Mac alike)
- **Idempotent writes.** Every write request carries a client-generated `Idempotency-Key` (UUID per
  user action, kept by the page until the action ends). tando-dash keeps the key -> result for 24 h
  (on disk, 0600, bounded): a repeated key (double click, retry after a timeout, a reload that
  resends, two tabs) returns the first request's status and stream instead of running again. The
  confirm token is single use as well. Per app, one write at a time: a second write while one runs
  gets 409 with what is running and since when, never a queue the user did not see.
- **Server-side truth.** A write's outcome is read back from the server (deploy-status / history),
  not inferred from the HTTP request: a page reloaded or a laptop that slept mid-deploy reattaches
  to the running operation (by app and operation id) and shows its real end. tando's own state
  machine already makes the server side recoverable (recover, leases); tando-dash never adds its
  own state that could disagree with it.
- **Failure handling in the UI.** Every request has a timeout, a visible state (loading, stale,
  failed with the reason in one line and what to do), and retry with backoff and jitter for reads
  (never automatic retry for writes: the idempotency key makes a manual retry safe). A host that
  fails keeps its last data, marked "data from 14:02 GMT", never blanked. Partial failure is shown
  per host/section, never as one page-wide error. Error boundaries per panel so one broken view
  never takes the page down.
- **tando-dash robustness.** Bounded everything: request body size, concurrent CLI processes,
  cache size, SSE clients, log lines kept per stream (ring buffer), idempotency records. Child
  processes always killed on timeout or client disconnect (process group), never orphaned.
  Panics recovered per request with a 500 and a log line. Graceful shutdown: running writes are
  not killed (tando's CLI owns them); the page reattaches after a restart. Survives the laptop
  sleeping, the network dropping, the tando CLI being upgraded underneath it (re-checks version),
  and the ssh master dying (the CLI reconnects).
- **Stability tests.** Go: idempotency (same key twice runs once; concurrent same key; key reused
  with a different body is refused), 409 for a second write, child killed on cancel, bounded
  queues under load, panic recovery. Web: vitest for retry/backoff and stale handling with a fake
  clock; a fault-injection mode in the fake CLI (slow, hang, garbage JSON, non-zero exit, killed
  mid-stream) driven by the Go tests. One soak test: 30 min of polling with injected faults, RSS
  and goroutines flat.
