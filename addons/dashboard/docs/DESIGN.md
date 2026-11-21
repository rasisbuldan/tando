# tando dashboard: design guideline

Binding for M2-M6. Sources: docs/SPEC.md (spec), the design-language notes and the review of spec v1 (not in the repository), tando docs/COMMANDS.md. Where this file and the spec disagree on data, the spec wins; on looks, copy and behaviour, this file wins. "Must" is a test-checked rule.

## 1. Principles

1. Hue only for state. Chrome is neutral, the primary action is ink, colour always comes with a word.
2. The terminal, in a window. Same words, units, GMT times and field meanings as `tando status` and `tando ls`; show the matching command where it helps.
3. Complete, not crowded. Every field the CLI shows is somewhere; secondary values go muted in the same cell, not into new columns.
4. Nothing moves unless the user moved it. No layout shift (CLS 0), no animated data, no blanking on refresh; last data stays until replaced.
5. Failures are local and honest. A broken host, section or panel says what failed and what to do; the rest of the page keeps working.
6. Server truth for writes. A write's outcome is read back from tando, never guessed from an HTTP status.
7. Cheap by default. System fonts, no images, one lazy chart chunk, zero polls when hidden.

## 2. Tokens

One file, `src/styles/tokens.css`. No hex/rgb/oklch literal anywhere else (ESLint `no-restricted-syntax` on colour literals in `.ts/.tsx`, plus a script that greps `src/` excluding tokens.css; both fail CI).

```css
:root {
  --background:#f6f5f2; --card:#ffffff; --popover:#ffffff;
  --foreground:#1f1c19; --muted:#efede8; --muted-foreground:#5c5650; --faint:#6f665c;
  --border:#e5e1da; --input:#8c8378; --ring:#1f1c19;
  --primary:#1f1c19; --primary-foreground:#ffffff;
  --secondary:var(--muted); --secondary-foreground:var(--foreground);
  --accent:var(--muted); --accent-foreground:var(--foreground);
  --ok:#2f6b2b; --warn:#8a5f12; --fail:#b3261e; --stale:#6f665c; --info:#1f4f8a; --neutral:#5c5650;
  --destructive:var(--fail); --destructive-foreground:#ffffff;
  --chart-1:#1f6fb2; --chart-2:#b86e00; --chart-3:#00806a;
  --chart-4:#6b5b95; --chart-5:#a3456a; --chart-6:#c2410c;
  --shadow-pop:0 4px 16px rgb(0 0 0 / .08), 0 1px 3px rgb(0 0 0 / .06);
  --radius:8px; --radius-sm:6px;
}
.dark {
  --background:#141312; --card:#1c1b19; --popover:#22201e;
  --foreground:#ece8e2; --muted:#292724; --muted-foreground:#a8a097; --faint:#9c938a;
  --border:#34312d; --input:#736b61; --ring:#ece8e2;
  --primary:#ece8e2; --primary-foreground:#1c1b19;
  --ok:#7cc277; --warn:#e3b55c; --fail:#f08a80; --stale:#a8a097; --info:#8db4e8; --neutral:#a8a097;
  --destructive-foreground:#1c1b19;
  --chart-1:#6aaee8; --chart-2:#e8a33a; --chart-3:#3fbfa0;
  --chart-4:#a99be0; --chart-5:#e68ab3; --chart-6:#f2855a;
  --shadow-pop:0 4px 16px rgb(0 0 0 / .4), 0 1px 3px rgb(0 0 0 / .3);
}
/* per state s in ok warn fail stale info neutral: */
:root { --ok-bg:color-mix(in oklab, var(--ok) 12%, var(--card));
        --ok-border:color-mix(in oklab, var(--ok) 35%, var(--card)); /* …same for each */ }
```

Measured contrast (WCAG): foreground 17.0/14.1 on card (light/dark); muted-foreground 7.2/6.7; faint 5.6/5.7; every state colour >= 4.8 on its own tint and >= 5.1 on background in both themes; input border 3.7/3.3 (>= 3:1 for controls); chart colours >= 4.0 (light) and >= 6.8 (dark) on card. Border (1.3:1) is decoration only, never the sole boundary of a control.

**Tailwind (v4) mapping** in `src/styles/app.css`:
`@theme { --color-*: initial; --color-background: var(--background); …` one line per token above, including `--color-ok`, `--color-ok-bg`, `--color-ok-border` per state and `--color-chart-1..6`. `--radius-lg: var(--radius); --radius-md: var(--radius-sm); --radius-full: 9999px`. Result: `bg-red-500` does not exist; only `bg-card`, `text-fail`, `bg-warn-bg`, `border-ok-border` etc. compile.

**Theme selection.** Default follows `prefers-color-scheme`; a System/Light/Dark menu in the sidebar footer stores the choice in localStorage. `.dark` is set before first paint by `/theme.js` (external, render-blocking, <= 400 bytes; no inline script under the CSP).

**State colours.**

| State | Words it carries | Text | Background | Border |
|---|---|---|---|---|
| ok | running, healthy, live, ok, reachable | `--ok` | `--ok-bg` | `--ok-border` |
| warn | pending, restarting, slow, rolled back, queued | `--warn` | `--warn-bg` | `--warn-border` |
| fail | down, failed, firing, unreachable write error | `--fail` | `--fail-bg` | `--fail-border` |
| stale | stale, not answering, unknown | `--stale` | transparent | 1px `--input` ring |
| info | deploying, soaking, running (a write), silenced | `--info` | `--info-bg` | `--info-border` |
| neutral | stopped, never deployed, already live, resolved | `--neutral` | `--muted` | `--border` |

Only status badges, dots, banner left rules and chart thresholds use state colours. Text in tables stays `--foreground`/`--muted-foreground`; a failed value may use `text-fail` only beside a badge.

**Focus ring:** `outline: 2px solid var(--ring); outline-offset: 2px` on `:focus-visible` only; inside table rows and sidebar rows offset `-2px` (inset). Never removed.

**Chart series** (Okabe-Ito hues, adjusted for contrast): order 1 blue, 2 orange, 3 teal, 4 purple, 5 pink, 6 vermillion. A chart uses the first N in order. Max 6. `--fail`/`--warn` never appear as series; they are for threshold lines and incident areas only.

## 3. Typography

- **Sans:** system stack, 0 KB: `ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`. (A webfont costs 30-60 KB and a swap; rejected.)
- **Mono:** `ui-monospace, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace`. Used for: release ids (`20261113-171442`), hosts and IPs, commands (`tando rollback shop`), env key names, request paths, log lines. Never for numbers in tables.
- **Tabular numbers:** `font-variant-numeric: tabular-nums` on `body`. Every number column, KPI, axis tick and age uses it; nothing opts out.

| Role | Size / line height | Weight | Use |
|---|---|---|---|
| title | 20 / 28 | 600 | page title |
| section | 15 / 22 | 600 | card and section heads |
| body | 14 / 20 | 400 | text, dialogs |
| table | 13 / 20 | 400 | cells, sidebar rows |
| label | 13 / 20 | 500 | buttons, tabs, field labels |
| small | 12 / 16 | 500 | table headers (muted), badges, tooltips |
| eyebrow | 11 / 16 | 600, uppercase, +0.04em | sidebar group heads |
| kpi | 24 / 30 | 600 | metric card number |
| mono | 12.5 / 18 | 400 | logs, ids, commands |

No other sizes. No italics. Weight 700 is not used.

## 4. Layout

- **Shell:** CSS grid `[sidebar] [main]`. Sidebar 240 px expanded, 56 px collapsed, full height, sticky, its own scroll. Main scrolls the document.
- **Page header:** 56 px high, sticky at top of main, `bg-background`, bottom hairline: title (+ status badge), meta line slot, actions right. Below it a 24 px **freshness row**, always present, holding "updated 12 s ago" or the stale text: banners never insert space.
- **Content:** max width 1440 px, left-aligned beside the sidebar; gutters 16 px (< 1024) and 24 px (>= 1024); sections separated by 16 px.
- **Grid:** 12 columns, gap 12. Metric cards: 4 per row >= 1024, 2 per row 641-1023, 1 per row <= 640. Charts: 2 per row >= 1280, else 1.
- **Breakpoints:** sm 640, md 768, lg 1024, xl 1280. At <= 640 the sidebar is collapsed to 56 and opens as an overlay sheet (280 px, over content, no reflow). Above 640 the collapse state is the user's, remembered in localStorage.
- **Spacing scale:** 2, 4, 8, 12, 16, 24, 32. Card padding 16; cell padding 0 12; control gap 8. Nothing else.
- **Radius:** cards, dialogs 8; buttons, inputs, tooltips 6; badges 999. Shadows only on popover, dialog, toast, sheet (`--shadow-pop`). Resting cards: 1px `--border`, no shadow.
- **Fixed heights:** button 32 (toolbars, rows) / 36 (dialogs, page header); input 32; tab bar 40; table row 36; sidebar row 32; chart plot 200 (sparkline 24 x 80); metric card 96.

## 5. Sidebar

Order (never changes with state):

```
[logo mark] tando                 [«]
Overview
Deploys
Alerts                         3
SERVERS
● web-1                        2
    ● shop                     2
        Database          open  Stop
    ● blog
◌ db-2                            (not answering)
    ◌ api
─────────
[theme]  v1.9.0
```

- **Row anatomy (32 px):** 16 px slot (icon for pages, 8 px dot for servers/apps), 8 gap, name (13/400, ellipsis), right-aligned count (12/500 tabular, `text-fail` when firing, `text-warn` when only pending). Apps indented 12 px. Servers and apps sorted by name.
- **Dot:** ok running/reachable, fail down/firing, warn pending/restarting, info deploying, neutral stopped, stale ring (1px `--input`, transparent fill) not answering. The dot has `aria-hidden`; the row's accessible name includes the word ("shop, down, 2 alerts").
- **States:** hover `bg-muted`; selected `bg-muted`, weight 600, 2 px `--foreground` bar at the left edge, `aria-current="page"`; alert: dot and count as above, the parent server shows the worst child dot; unreachable: stale ring dot, name `text-muted-foreground`, apps keep their last state dot as stale rings; collapsed: 56 px, icons and dots only, names in tooltips (300 ms delay), counts become a 6 px dot at the icon's top right.
- **Keyboard:** the sidebar is one `role="tree"` (servers expandable). Up/Down move, Right expands/enters, Left collapses/goes to parent, Enter opens, Home/End jump. `[` toggles collapse. Tab leaves the tree into main content.
- Server expand state is remembered; a server with a firing alert opens by default.
- **Database row:** under an app with a database (never for one without; not while its server is not answering), a 32 px row indented under the app: database icon, "Database" in `text-muted-foreground`; "opening…" while a click is out. Enter or a click opens the studio in a new tab at once: no dialog, no confirmation (SPEC "Database studio"); a failure is one line in a small `role="alert"` notice, bottom right, with a dismiss button.

## 6. Components

Copy-in shadcn (new-york, neutral base, our tokens): Button, Badge, Card, Table, Tabs, Dialog, AlertDialog, Sheet, Tooltip, DropdownMenu, Input, Textarea, Select, Toggle, Separator, Skeleton, Sonner (toast). Not copied: `chart.tsx` (injects a `<style>`; CSP), Sidebar block (too heavy; ours is ~150 lines), Command, Calendar, Carousel. Radix only through these.

- **Page header:** title, then state badge (app/server pages), then meta in `text-muted-foreground` separated by " · " ("release 20261121-140233 · deployed 3 h ago by ana · shop.example.com"). Actions right: one primary (ink) at most, others outline; overflow in a "More" menu below 1024 px.
- **Metric card (96 px):** label (13/500 muted), number (kpi) with unit in 13/400 muted ("412 MB"), one sub-line (12 muted: "of 512 MB · 80%"). Optional sparkline right (80 x 24). Click = navigate or filter; then it is a link with hover border `--input`.
- **Data table:** shadcn Table + `@tanstack/react-table` (headless, sort only). Row 36, header 32, sticky header `bg-card`, header text small muted; hairline row borders; hover `bg-muted/60` via `--muted` token; no zebra. Numbers right-aligned, text left, badges left. Sortable headers are buttons with a 12 px chevron and `aria-sort`; one sort key; click toggles desc/asc. Secondary value muted in the same cell after " · " ("412 MB · of 512"). No wrap: ellipsis + Tooltip with the full value; ids truncate in the middle ("2026…140233") only when the column is < 14 ch. Missing value "—" in `--faint`. Column widths fixed per table (`table-layout: fixed`) so polls never shift columns. > 100 rows: virtualised (`@tanstack/react-virtual`).
- **Status badge:** 22 px pill, small (12/500), padding 0 8, state text on state bg with state border, optional 6 px dot. Always a word. **Status dot:** 8 px, always followed by a word or inside a row whose name says it.
- **Tabs:** shadcn Tabs as links (each tab a route, `?tab=` not used): 40 px bar, label 13/500, selected = foreground + 2 px bottom bar; others muted. Counts in muted after the label ("Alerts 2").
- **Charts (Recharts, lazy chunk):** every chart `isAnimationActive={false}`, fixed height 200, fixed time domain `[now - range, now]` with `now` = server clock, fixed tick count (5 x, 3-4 y), y domain fixed per metric (memory `[0, memory_max_bytes]` or `[0, auto-rounded max]`; CPU `[0, 100]`). Gaps: `connectNulls={false}`, values null never zero. Line 1.5 px, `dot={false}`, `activeDot r=3`. Area fill 12% of the series colour. Grid horizontal only, `stroke var(--border)`. Axes no line, no ticks, labels 11 px muted with unit ("256 MB", "14:00"). Tooltip: custom `content` component (classes, no style prop): card, 12 px, "14:05 GMT" then "412 MB". Deploy markers: `ReferenceLine` vertical, 1 px dashed `--faint`, label "r" + short id on hover only. Limits: dashed `--warn` (memory cap); incidents: `ReferenceArea` `--fail-bg`. "Data since 19 Nov 08:00 GMT" label top right of the card when retained data starts after the domain start. Charts sharing a page share `syncId`. Memory definition change (Nov 2026): one `ReferenceLine` labelled "memory now counts shared memory". Empty: the plot box with "No data in this range yet" centred, muted.
  - Memory, CPU: area (one series). Restarts: bars of per-bucket deltas. Load: line (1m, chart-1) with RAM as separate memory chart.
  - Deploy phases: horizontal stacked bar per deploy, 16 px bar, 1 px card-colour gap between segments; segments build (1), upload incl. copy (2), release command (3), preflight (4), switch (5), verify (6); total right of the bar ("48 s").
  - Sparkline: our own 30-line SVG (no Recharts), 80 x 24, 1.25 px `--chart-1`, nulls break the path.
- **Log viewer:** mono 12.5/18, rows 18 px fixed, virtualised; columns: time (GMT, `14:02:07`), level (3-letter word: `err`, `wrn`, `inf`, `dbg`; err in `--fail`, wrn in `--warn`), worker (muted, if any), message (no wrap; click a row to expand it wrapped). Filter bar 40 px: level Select, text Input ("Filter lines", `/` focuses), worker Select, release Select, Follow Toggle. Follow on: pinned to bottom; scrolling up turns follow off and shows a "N new lines · Jump to latest" pill (bottom right, 28 px). Ring buffer 5,000 lines in memory; nothing stored.
- **Write confirmation (AlertDialog, 440 px):** title is a question naming the action, app and host: "Roll back shop on web-1?". One or two sentences of consequence. The command in a mono line (`tando rollback shop 20261113-171103 -H web-1`). Buttons: Cancel (outline, left, default focus), action (right). Destructive (`bg-destructive`) only for Roll back and Stop; Deploy, Restart, Start, Set are primary ink. The confirm token is requested when the dialog opens; the action button shows "Preparing…" until it arrives (max 2 s, then the one-line error).
- **Progress panel:** inline card under the page header (not a modal), header row: state badge, "Deploying shop · started 14:02 GMT · 32 s", Close (only after end). Body: phase stepper (the six phases, current one info, done ok, failed fail) and a 12-line mono stream (fixed 216 px, virtualised, auto-follow). Reattached operations show one muted line on top: "Reattached to the deploy started 14:02 GMT."
- **Toast (Sonner):** bottom right, 360 px, 4 s, max 1 visible. Only for a write finished while its progress panel is not on screen, and for "Copied". Never for errors that a section can show.
- **Skeleton:** `bg-muted`, radius of the final element, exact final size: table = header + last known row count (default 8) x 36; metric card 96; chart 200; text lines 12 px bars at 60%/40% width. No shimmer, no pulse. Container gets `aria-busy="true"`.
- **Icons:** lucide-react, named imports, size 16, stroke 1.75, `aria-hidden`.

## 7. States (every view, every section)

| State | Shows |
|---|---|
| Loading (no data yet) | Skeletons of exact size. Shown after 150 ms only; before that nothing changes. |
| Refreshing | Nothing visible except the freshness row age resetting. Old data stays. |
| Empty | In the section box: one line of what is missing + one action. "No deploys yet. Deploy with `tando deploy`." |
| Stale (last success > 2 poll intervals, 30 s visible) | Data stays; freshness row: stale badge + "data from 14:02 GMT, retrying". Per host. |
| Unreachable host | Host section header: fail badge "not answering" + "ssh timed out. Check ssh access, then retry." + Retry (outline 32). Last data stays, labelled stale. |
| Partial failure | Only the failed section swaps its body for the one-line error + Retry; siblings render. Never a page-wide error. |
| Error | One line: fact, then next step. "Could not read metrics: tando 1.8 is too old. Update with `tando update`." Retry where a retry can help. |
| Panel crash (error boundary) | "This panel failed to draw. Reload the page." + Reload. The rest works. |
| Session gone | Full-page (the only one): "Session ended. Open the dashboard again with `tando-dash`." |
| Write running | Progress panel; the action buttons of that app disabled with tooltip "A deploy is running". |
| Write succeeded | Panel badge ok: "Deployed 20261121-140233 in 48 s." Header refreshes from server data. |
| Write failed | Panel badge fail: "Deploy failed at preflight: health check got 502. The live release is unchanged." + "Show log" link to Logs tab filtered by deploy. No auto retry. |
| Already running (409) | Dialog body replaced: "A rollback of shop is running, started 14:02 GMT (40 s ago)." + "Show progress". |
| Repeated action (idempotent replay) | Same panel, muted top line: "Already sent. Showing the first request." |
| Refused by tando-dash | Dialog error line: "Deploy refused: shop was last deployed from another machine. Deploy from there." |

Read retries: 1 s, 2 s, 4 s, 8 s, then every 30 s, each ±20% jitter; request timeout 15 s (as the CLI's `--watch`). Writes: never retried automatically.

## 8. Motion

- Animates: dialog, sheet, popover, tooltip, toast. Opacity + transform only. Enter 150 ms `cubic-bezier(0.2, 0, 0, 1)`, from `opacity 0; translateY(4px) scale(.98)`. Exit 120 ms `cubic-bezier(0.4, 0, 1, 1)`. Tooltips: opacity only, 120 ms.
- Hover/press colour changes: 120 ms on `background-color`, `color` only for buttons and rows (paint, not layout).
- Never animates: tables, row insert/reorder, numbers, chart data, axes, skeleton, layout, sidebar width, page and tab changes (instant), progress lines.
- `@media (prefers-reduced-motion: reduce)`: all durations 0.
- Navigation: routes are code-split and prefetched on sidebar hover/focus; a route renders its shell and cached data in the same frame.

## 9. Copy rules

1. Labels are nouns, sentence case: "Memory", "CPU", "Last deploy", "Restarts".
2. Use tando's words: release, firing, pending, soak, preflight, rollback target, host. Never invent synonyms ("instance", "service", "incident" only for health incidents).
3. Buttons: verb first, at most two words plus the object: "Deploy", "Roll back", "Restart", "Stop", "Start", "Set variable", "Run doctor", "Retry".
4. Confirmations: question with app and host ("Stop shop on web-1?"), then the consequence in tando's words: "Visitors get 503 until you start it. Jobs and workers stop too. Nothing is removed."
5. Errors: fact, then fix. "web-1 not answering: ssh timed out. Check ssh access, then retry."
6. Alerts: check, then detail from tando: "disk 92% full" + the alert's `detail`.
7. Results past tense with the number: "Rolled back to 20261113-171103 in 1.5 s."
8. Units always, with a space: "412 MB", "12%", "180 ms", "48 s", "3 of 10 connections". MB below 1 GB, GB above with one decimal ("1.4 GB"). Percent no decimals except under 10 ("0.4%").
9. Times GMT, 24 h: "14:02 GMT"; with date "21 Nov 14:02 GMT"; relative "12 s ago", "5 min ago", "3 h ago", "2 d ago", "just now" under 5 s. Exact time in a tooltip on every relative age.
10. Durations: "48 s", "2 min 10 s", "3 h 20 min", "4 d".
11. Missing: "—". Unknown state: "unknown". Never "N/A", "null", "0" for missing.
12. Empty: what is missing + one action. "No alerts firing." "No jobs. Add one under `[jobs]` in tando.conf."
13. No match: "Nothing matches “timeout”." + "Clear filter".
14. Stale: "data from 14:02 GMT, retrying".
15. Percentages next to counts: "412 MB · 80%".
16. At most one sentence under a heading; no subtitles, no helper text that repeats the label.
17. No exclamation marks, "please", "successfully", "oops", "simply", emojis.
18. Show the command when an action has a CLI equivalent (mono, copy button).
19. UI copy is English; app names, hosts, ids appear exactly as tando prints them.

## 10. Pages

Every section below is its own error boundary with its own loading/empty/error/stale state from §7.

**Overview** (`/`): header "Overview", actions: Refresh (outline). Sections:
1. Needs attention (only when non-empty; reserved 0 height otherwise, it is a section not a banner): list rows 36: badge, app/server, `check` + `detail`, since ("for 12 min"), link. Sources: alerts (`state` firing first, then pending), apps with `state_reason` down/failed, unreachable hosts.
2. Servers: one card per host (grid 3/2/1): name (mono), reachable badge, load (1m/5m/15m), memory used of RAM, disk % ("full in 9 days" muted when the estimate exists), headroom ("caps 1.5 GB of 2 GB RAM"), versions muted, clock skew when > 30 s ("clock 42 s ahead").
3. Apps: one table. Columns: State (badge, `state`/`state_reason`), App, Server, Release (`release` mono · age of `deployed_at`), Memory (`memory_bytes` · of `memory_max_bytes`), CPU (`cpu_percent`), Restarts, Uptime (`uptime_s`), Last deploy, Alerts (`alerts_firing`). Default order: attention (fail, warn, stale, info, ok, neutral), then name. Rows keep their place on polls; re-sorting happens on user sort, `r`, or page re-entry.

```
┌──────────┬──────────────────────────────────────────────────────────┐
│ tando  « │ Overview                                     [Refresh]  │
│ Overview │ updated 4 s ago                                          │
│ Deploys  │ NEEDS ATTENTION                                          │
│ Alerts 3 │ [down] shop · web-1   app down   for 12 min           →  │
│ SERVERS  │ [pending] blog · web-1  memory 91% of cap             →  │
│ ● web-1 2│ ┌web-1 [reachable]──┐┌db-2 [not answering]──┐           │
│   ● shop │ │load 0.4 0.3 0.2   ││ssh timed out. Check  │           │
│   ● blog │ │mem 1.2 GB of 2 GB ││ssh access. [Retry]   │           │
│ ◌ db-2   │ │disk 61% · full 9 d││data from 14:02 GMT   │           │
│   ◌ api  │ └───────────────────┘└──────────────────────┘           │
│          │ APPS                                                     │
│          │ State   App   Server Release       Memory        CPU …  │
│          │ [down]  shop  web-1  2026…140233   —             —      │
│          │ [run]   blog  web-1  2026…091002   231 MB · 256  4%     │
└──────────┴──────────────────────────────────────────────────────────┘
```

**Deploys** (`/deploys`): header "Deploys". Filter row: server Select, app Select, result Select. Timeline table, newest first, 50 then "Show 50 more": time (`at`, GMT), app, server, kind (deploy/rollback), result badge, deployer, phase bar (from `*_s`), total (`total_s`), note (muted, ellipsis). Empty: "No deploys yet."

**Alerts** (`/alerts`): header "Alerts". Sections: Firing (table: badge, app, server, check, detail, since), Pending (same), History (last 7 days: check, app, from, to, duration), Notifications (where alerts go: one row per notifier, kind and target masked as tando prints it). Empty firing: "No alerts firing."

**Server** (`/s/:host`): header: host name (mono), reachable badge, meta "Ubuntu 24.04 · tando 1.9.0 · clock ok". Actions: Run doctor (outline). Sections: range Tabs (1h/24h/7d, default 24h); then the observability sections below (cloud-VM style), from `host_metrics`; Disk gauge card (SVG bar 8 px, % and "full in N days" or "—"); Alerts on this host; Doctor (collapsed until run; result list with ok/warn/fail per check, "last run 14:02 GMT"; runs at most once a minute, button disabled with tooltip "Ran 20 s ago. Again in 40 s"); Host to-dos (security updates, reboot pending, failed units, from `host status`, on demand); Backups line ("last 03:00 GMT · offsite 03:04 GMT", warn past the alert threshold); Apps (the Overview table filtered to this host, without the Server column).

**App** (`/s/:host/:app/:tab`): header: app name, state badge with `state_reason` ("down · exited 1"), meta: release (mono) · deployed age by deployer · link. Actions: Deploy (primary), Roll back, Restart, Stop or Start (by state), in that order; "More" holds Copy command. Progress panel under the header when a write runs. Tabs: Overview, Deploys, Logs, Traffic, Jobs, Env, What changed.

- **Overview:** range Tabs; metric row: Memory (`memory_bytes` of max), CPU (`cpu_percent`), Restarts (24 h), Probe p95 (24 h, ms) with sparkline; charts: Memory, CPU, Restarts, Disk (the app's tree, every 15 min) (deploy markers on all); no per-app load (Linux has none), said under the charts; Uptime and incidents (24 h strip: 1 px per bucket, ok/fail/no-data, list of incidents below); Workers table (name, state, restarts, memory of cap); Database line ("postgres · 412 MB · 3 of 10 connections"); Firing alerts for this app.

```
┌──────────────────────────────────────────────────────────────────┐
│ shop [running]  r 20261121-140233 · 3 h ago by ana · shop.ex…  │
│                         [Deploy] [Roll back] [Restart] [Stop]    │
│ updated 6 s ago                                                  │
│ Overview  Deploys  Logs  Traffic  Jobs  Env  What changed        │
│ [1h] [24h] [7d]                                                   │
│ ┌Memory──────┐┌CPU────────┐┌Restarts───┐┌Probe p95──────┐         │
│ │412 MB      ││12%        ││0          ││180 ms  ╱╲_╱   │         │
│ │of 512 · 80%││last minute││24 h       ││24 h           │         │
│ └────────────┘└───────────┘└───────────┘└───────────────┘         │
│ ┌Memory ─────────────data since 19 Nov┐┌CPU──────────────────┐   │
│ │ 512 MB - - - - - - - - - - - - - -  ││100%                 │   │
│ │      ▁▂▃▃▃  ▃▃▄▄▄¦▄▄▄              ││  ▁ ▁▂ ▁ ¦ ▁         │   │
│ └─────────────────────────────────────┘└─────────────────────┘   │
│ UPTIME 24h ████████████▌██████████  2 incidents                  │
│ WORKERS  queue [running] restarts 0  41 MB of 256 MB             │
│ DATABASE postgres · 412 MB · 3 of 10 connections                 │
└──────────────────────────────────────────────────────────────────┘
```

- **Deploys:** Releases table first (id mono, deployed_at, status badge, "live" / "rollback target" tags from `current`/`last_good`, Roll back button per non-live release, outline 32). Then History (as the Deploys page, without app/server columns).
- **Logs:** log viewer, full height of the viewport below the tab bar (min 400 px). Note under the filter bar, once, muted: "Logs are not stored." Follow off by default; last 200 lines on open.
- **Traffic:** range Tabs; requests per minute stacked area by class (2xx 1, 3xx 3, 4xx 2, 5xx 6); p50/p95 line chart (2 series, legend); Slowest paths table (path mono, count, p50, p95); Error groups table (title, count, first seen, last seen, 7-day sparkline).
- **Jobs:** table: job, schedule (mono, cron), next run (GMT + "in 12 min"), last result badge, last duration; expand row: past runs (time, result, duration), 20 max.
- **Env:** Names table (key mono, last changed age, note), never values. "Set variable" (primary 32) opens a dialog: Key input (validated with tando's name rule, inline error), Value textarea (`type=password`-like masking via `-webkit-text-security` class, autocomplete off), body "shop restarts once with the new value. If it does not come up healthy, nothing changes." Change log below (time, key, action set/unset, by, note).
- **What changed:** two release Selects (from, to; default previous live → live), then three sections: Deploy notes, Env changes (names only), Deploys between. Empty: "Nothing changed between these releases."

## 11. Accessibility

- WCAG 2.2 AA in both themes: text >= 4.5:1, large text and control boundaries and chart marks >= 3:1 (values in §2). Checked by a vitest that parses tokens.css and asserts each pair.
- State never by colour alone: badge words, log level words, chart thresholds labelled.
- Focus order: skip link ("Skip to content") → sidebar tree → page header actions → freshness Retry (if any) → tabs → sections in visual order. Dialogs trap focus, return it to the trigger; Cancel gets initial focus in destructive dialogs, the action in others.
- Shortcuts (ignored while typing in a field; listed by `?` in a dialog): `/` filter (logs, tables) or sidebar search, `g o` Overview, `g d` Deploys, `g a` Alerts, `r` refresh now, `[` toggle sidebar, `?` help, `Esc` close overlay.
- Charts: `role="img"` with `aria-label` summary ("Memory, last 24 h: 380 to 430 MB, now 412 MB of 512 MB, 2 deploys"), plus a visually hidden "Show as table" button revealing a 24-row table (hour buckets). Sparklines `aria-hidden` with the number beside them read instead.
- Live regions: freshness row `aria-live="polite"` only when it turns stale or recovers; progress panel end state `role="status"`; never announce each poll.
- Targets >= 24 x 24 px; row actions 32 px.

## 12. Performance rules

1. Budgets are tests (spec): first route JS <= 150 KB gz, CSS <= 15 KB, CLS 0, shell paint <= 150 ms. A size check fails the build.
2. Recharts only via `React.lazy(() => import('./charts'))`; the first route without charts must not pull it. Prefetch the chunk on idle after first data.
3. Routes are lazy; prefetch on sidebar hover/focus.
4. Data: one query per (host, view) from the snapshot; polling 15 s visible, 60 s for off-screen hosts, 0 when `document.hidden`. Responses structurally shared (keep the previous object when equal) so `React.memo` components skip; charts memoise their series by a content hash.
5. No `style` prop and no `<style>` in our code (ESLint `react/forbid-dom-props: style`). Allowed exceptions: the virtualiser's row transform and Recharts internals (both set through CSSOM, which `style-src 'self'` allows). Gauges and bars use SVG `width` attributes.
6. Virtualise any list that can exceed 100 rows: logs, deploy history, jobs runs, tables.
7. No layout reads (`getBoundingClientRect`, `offsetHeight`) in loops or render; use ResizeObserver once per chart container.
8. No images, no webfonts, no CSS-in-JS. Favicon is an SVG file.
9. Icons: lucide-react named imports only, at most 24 distinct icons in the bundle (a test counts them).
10. Dependencies beyond the stack need an owner OK: allowed today are react, react-dom, react-router, @tanstack/react-query, @tanstack/react-table, @tanstack/react-virtual, recharts, Radix packages used by the copied components, sonner, lucide-react, clsx, tailwind-merge.
11. Times formatted with one cached `Intl.DateTimeFormat` (`timeZone: 'UTC'`, suffix " GMT"); no date library.
12. SSE (logs, progress): batch appended lines per animation frame; cap rendered buffer (5,000 log lines, 2,000 progress lines).

## Observability (Server page, App Overview, Database tab)
- **Server page sections** (each folds with a chevron button, `aria-expanded`; all open at first; 2 charts per row >= 1280): CPU (stacked user / system / I/O wait / steal; load with the cores line), Memory (used / cached / available with the RAM line; swap used on the swap's own axis; swap in and out, pages a minute), Disk (usage %, inodes %, IOPS, throughput, latency, busy time), Network (traffic in and out, errors and drops, TCP connections, retransmits), Pressure (CPU, memory and I/O stall in one chart), Monitoring cost (tandod CPU ms a minute, memory, programs started, reader requests: a chart of its own). 20 charts: only the first section draws at once; every other chart draws when it comes within 300 px of the viewport (IntersectionObserver) and stays drawn; until then a skeleton of the card's exact height holds the place (CLS 0). A folded section draws nothing.
- **Multi-line charts** carry a legend row under the plot (swatch and name, 12 px muted; the card is 24 px taller than a single-line card) and a tooltip with one row per line; stacked ones fill at 30%. Counters the server sums per bucket are shown as rates (per second for bytes and operations, per minute for rare events). Existing rules hold: gaps are nulls, "data since", dashed limit lines (cores, RAM).
- **Steal and swap are information:** no `--warn` / `--fail` in any series (steal is `--faint`); the swap chart has no limit line, its axis is the swap size. Limit lines stay for cores and RAM only.
- **App Overview slice row** (below the first metric cards; hidden for a server that does not send it): CPU throttled %, OOM kills in the range, Tasks against the limit, Memory pressure. No alert styling.
- **Database tab** (only for an app with a database; its own lazy chunk): the Open database button and the range tabs in one toolbar; metric cards Size (with growth a day), Connections (of max), Longest transaction (and idle in transaction), Wraparound; a warn-tinted note only from 50%; charts Connections by state (stacked, dashed line at max), Transactions, Rows (returned, fetched, inserted, updated, deleted), Cache hit, Deadlocks, Temp files, Longest transaction, Size; Top queries table (calls, mean, total, rows; query text in mono, one line, cut with an ellipsis, full text in the title; always rendered as text, never as HTML).
