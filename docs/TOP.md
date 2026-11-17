# tando top

`tando top [host] [--watch N] [--read-only]` is a live dashboard that fills the terminal. It shows
every registered host, the apps on the selected host and a detail pane for the selected app. It
repaints every 2 seconds by default. The code is `lib/cmd-top.sh`, which uses the
interactive parts of `lib/ui.sh`.

## Screen

- **Host strip.** One entry per registered host: a reachability badge, load and memory bars, and the
  app count. A host that stops answering shows `✗ unreachable` with the error. Its last data stays
  on screen, greyed, with its age. While a fetch is slow the badge reads `reconnecting`.
- **Apps table.** For the selected host: state badge, release, memory bar against the cap, cpu %,
  uptime, restarts and link. Columns drop when the terminal is narrow.
- **Detail pane** (enter toggles it). It shows state, release, memory, cpu, port, link, and backup
  age when the app has daily backups. Memory and cpu graphs follow, then releases with their badges
  and recent deploys. From 120 columns up the pane sits beside the apps table, with the host's
  load, memory and disk under the table. Narrower terminals stack it below the table. Below 80x20
  the dashboard switches to a single-pane compact view: the app list, or one app with enter.
- **Log view** (`l`): the app's journal, followed live. Scrolling up pauses it, and `f`, End or
  scrolling past the end follow again.
- **History view** (`h`): deploys and rollbacks with the time each phase took.

## Keys

| Key | |
|---|---|
| ↑ ↓, j k, Home/End | select app |
| ← →, tab / shift-tab | switch host |
| enter, space | show or hide the detail pane |
| l | log view (q, esc or l to go back) |
| h | history view (q, esc or h to go back) |
| t | graph range: buckets of 1, 5 or 30 minutes |
| r | restart the app |
| s | stop it if it is running, else start it |
| b | roll back to the previous verified release |
| ? | help |
| q, Ctrl-C | quit |

`r`, `s` and `b` open a boxed question, and only `y` goes ahead. Keys that were already typed or
pasted are dropped when the question opens, so a paste cannot answer it. The action runs in the
background and its result is shown in a box. With `--read-only` these keys show a note instead.
Deploying needs a project directory, so the dashboard has no deploy key.

## How it works

- **Loop.** The loop reads one key with a 1-second timeout. bash 3.2 only has whole-second
  `read -t`, and the read returns at once when a key is pressed. After each key, `dd` drains
  whatever input is already pending, with `stty min 0 time 0` set so it never waits. That keeps
  ESC and arrow sequences apart, and a paste or a held key queues at most 8 keys. New data repaints
  at most once a second; a key repaints at once.
- **Fetching.** Every fetch runs in the background into temp files, so input is never blocked. Each
  host gets one ssh call per refresh over the ControlMaster connection:
  - every host: `tando-agent status`;
  - selected host, detail visible: the selected app's `releases` and `history`, every 10 s or when
    the selection changes;
  - selected host, graphs need it: `tando-metrics read` for the selected app;
  - while the history view is open: the long history list.

  A fetch that runs longer than 12 s is killed. CPU % comes from the change in `CPUUsageNSec`
  between two samples, timed by the server clock (`$EPOCHREALTIME` in the same ssh call).
- **Terminal.** The dashboard uses the alternate screen with the cursor hidden. Each frame is
  written with one `printf`: cursor home, the lines (each clears to its end), then clear to the
  end of the screen. A resize (SIGWINCH) is measured again on the next frame. The EXIT trap, run
  on q, Ctrl-C, SIGTERM and SIGHUP, does all of this:
  - kills the background jobs;
  - leaves the alternate screen and shows the cursor;
  - restores the saved `stty` modes;
  - prints anything that went to stderr while the screen was in use.

## Metric history (`tando-metrics`, Go: `srv/metrics`)

- **Sampling.** A root-owned program run once a minute by `tando-watch.service` (below); nothing
  stays running. Go since the port (srv/README.md); the shell original, whose file format and output
  it keeps, is `server/legacy/tando-metrics`. Each run appends one line per app to `/var/lib/tando/metrics/<app>.tsv`: time, anon
  memory, cpu µs since the last sample, restarts, state. It also appends one line to `host.tsv`:
  load, memory used and total.
- **Rotation.** A file becomes `<app>.tsv.1` after 3.5 days or 5100 lines, so an app keeps at most
  7 days, about 2 × 160 KB.
- **Cost.** One sample costs about 4–5 ms of CPU for 1–2 apps (measured on the arm64 test
  server, sudo excluded: e2e-top 7e read 5 ms with hello and site; 20 runs with one app took
  3.8 ms each against 5.4 ms for the shell version). A `read` of 60 one-minute points from 7 days of
  data takes about 2 ms wall (shell: 8 ms); 2000 five-minute points about 3 ms (shell: 360 ms).
- **Reading.** `tando-metrics read <app|host> <points> <bucket seconds>` returns the last `points`
  buckets, averaged (`m` rows: start, memory, cpu per mille of a core, restarts, state). It needs no
  root.
- **Live samples.** While the dashboard is open, its own 2-second samples fill the newest bucket.

`tando status` can use the same data for its sparkline: add
`/opt/tando/bin/tando-metrics read <app> 16 60` to the status call, and feed the memory and cpu
columns of the `m` rows to `ui_spark`. That gives the last 16 minutes even without `--watch`.

## Installing the timer

Integrated: there is no separate metrics timer. `tando-watch.service` (the alert checks, once a
minute) runs `ExecStartPre=-/opt/tando/bin/tando-metrics sample` first; the `-` keeps a failed
sample from skipping the checks. `tando doctor` reports the age of the last sample. The units
below were the stand-alone form:

```
# /etc/systemd/system/tando-metrics.service
[Unit]
Description=tando metrics sample

[Service]
Type=oneshot
ExecStart=/opt/tando/bin/tando-metrics sample
Nice=10

# /etc/systemd/system/tando-metrics.timer
[Unit]
Description=tando metrics, once a minute

[Timer]
OnCalendar=*-*-* *:*:00
AccuracySec=1s

[Install]
WantedBy=timers.target
```

## Tests

- `test/e2e-top.sh` drives the real dashboard in a pseudo-terminal (`test/top-pty.py`, python3,
  test-only) at 80x24, 100x30 and 120x40 against its own server, `tando-test-top` on ports
  2302/8302. It covers:
  - navigation, detail, log and history views, and host switching;
  - `--read-only`;
  - a cancelled and then a confirmed restart, checked on the server;
  - resizing down to the compact view;
  - stopping and starting the server with docker;
  - the terminal state after q, Ctrl-C and SIGTERM;
  - the metric files, their rotation and the cost of a sample;
  - that no frame on screen has a line wider than the terminal.
- `test/ui-test.sh` covers the UI parts at every width, under both locales and with colour on and
  off: charts, panes, the modal, table selection, key parsing and scrolling. It also checks the
  `top` mock in `test/ui-demo.sh` at 40x12 up to 120x60.
