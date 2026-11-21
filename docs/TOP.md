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

- **Sampling.** A root-owned program run once a minute by tandod's tick (by `tando-watch.timer`
  when tandod is handed to the timer, docs/MONITORING.md); nothing of its own stays running. Go since the port (srv/README.md); the shell original, whose file format and output
  it keeps, is `server/legacy/tando-metrics`. Each run appends one line per app to `/var/lib/tando/metrics/<app>.tsv`: time,
  memory (anon + shmem: the same as status, ls, top's live number and the `memory` alert; anon
  only before 2026-11), cpu µs since the last sample, restarts, state. It also appends one line to `host.tsv`:
  load × 100, memory used and total, then (since 2026-11) cpu per mille of all cores since the last
  sample (`/proc/stat`'s busy and total jiffies, kept in `.state`; `-` on the first sample) and the
  used and total bytes of the file system holding /var/lib/tando (statfs; `-` if it failed).
  Columns are only added at the end: an older reader takes the first four, a newer one reads an
  older line's missing ones as gaps. Since 2026-11 an app line also has five columns from the
  app's slice (`tando-<app>.slice`, where tando sets its memory, task and CPU limits; the unit's
  own cgroup never sees them): CPU throttled (per mille of the scheduler periods; `-` without a
  CPU limit), OOM kills since the last sample (`memory.events`), tasks (`pids.current`), the task
  limit (`-`: none) and the slice's memory pressure (PSI "some" avg60 × 100). An app set up before
  the per-app slices (still under system.slice) has `-` in all five. Per-app IO is not sampled:
  IO accounting is off for the apps.
- **The host, extended (`host.x`).** One wide line a minute beside `host.tsv` (which stays as it
  was), like a cloud console's VM page. The writer turns counters into per-minute values,
  keeping the previous raw counters in `.x.state`; the first sample, a counter that went back, a
  reboot (uptime went back) or more than 10 minutes since the last sample is `-`, as is a source
  the kernel does not have. Columns: CPU user (with nice), system (with irq and softirq), iowait
  and steal in per mille of all cores; memory available and cached, swap used and total (bytes);
  swap in and out (pages a minute); PSI "some" avg60 × 100 of cpu, memory and io (`-` when the
  kernel has no PSI); reads and writes a minute, bytes read and written a minute, the average
  time of a request (µs) and the busy share (per mille; overstated on NVMe, virtio and dm, which
  serve requests in parallel) of the block device holding /var/lib/tando (from its device number
  through `/sys/dev/block`: a partition counts as its disk, an LVM or crypt volume as itself;
  btrfs, ZFS and loop devices: `-`); bytes in and out, errors and drops a minute of the default
  route's interfaces (a container bridge or veth would count the same bytes twice; loopback is
  never counted); TCP connections established and segments retransmitted a minute; OOM kills a
  minute (`/proc/vmstat`); inodes used (per mille, the file system holding /var/lib/tando); uptime
  (s). On an LXC or OpenVZ container the CPU and disk numbers are the host machine's. The name
  holds a dot, so no app can collide with it.
- **What the monitoring costs (`tandod.x`).** A line a minute: tandod's cgroup CPU (ms, with the
  programs it started), its anon memory and page cache (bytes), major faults and refaults (page
  cache read again; the sign of a cgroup too small for its working set) a minute, and two counters
  only tandod has: the programs it started and the requests readers sent to its socket (tando
  status, top, the dashboard) a minute. The readers' requests are shown apart: they are what
  looking costs, not the monitor. A sample by the timer's fallback (tandod not running the checks)
  writes `-` for the two counters; no tandod: no line. The `monitor_cost` alert reads it
  (docs/MONITORING.md).
- **App disk.** Every 15 minutes at most, the sample walks each app's tree in-process (no `du`):
  `/opt/tando/apps/<app>` (releases, shared data, incoming, home), its `data_dir` when that is
  outside, and its journal namespace (`/var/log/journal/<id>.tando-<app>`); allocated blocks, a hard
  link once, symlinks not followed. Not its PostgreSQL database nor its backups. The result goes to
  its own small file, `<app>.disk` (`time bytes`, at most one line per 15 minutes; `.disk.1` past
  24 KB), not into the per-minute line: a column there would cost 1440 numbers a day per app for a
  value that changes every 15 minutes (and readers before 2026-11 took the app line's last field
  as the rest of the line). The walks of one sample share a 500 ms budget, oldest walk
  first; a walk that runs out is dropped (a gap) and waits its 15 minutes, so one huge tree cannot
  take every minute. A walk of 50,000 files takes about 170 ms (BenchmarkWalk50k, macOS APFS on an
  M1 laptop; ext4 is usually faster). `read` carries the newest walk into the buckets after it, up
  to 20 minutes older than the bucket.
- **Rotation.** A file becomes `<app>.tsv.1` after 3.5 days or 5100 lines, so an app keeps at most
  7 days, about 2 × 160 KB.
- **Cost.** One sample costs about 4–5 ms of CPU for 1–2 apps (measured on the arm64 test
  server, sudo excluded: e2e-top 7e read 5 ms with hello and site; 20 runs with one app took
  3.8 ms each against 5.4 ms for the shell version). A `read` of 60 one-minute points from 7 days of
  data takes about 2 ms wall (shell: 8 ms); 2000 five-minute points about 3 ms (shell: 360 ms).
- **Reading.** `tando-metrics read <app|host> <points> <bucket seconds>` returns the last `points`
  buckets, averaged (`m` rows: start, memory, cpu per mille of a core, restarts, state, disk bytes;
  `h` rows: start, load × 100, memory used, memory total, cpu per mille of all cores, disk used,
  disk total; `-` where not known; since 2026-11 `m` rows go on with throttled per mille
  (average), OOM kills (sum), tasks and the task limit (maximum), memory pressure × 100
  (average)). `read host.x|tandod.x <points> <bucket>` returns an `xc` row naming the columns
  (`name:aggregation:scale`: `a` average, `s` sum, `m` maximum over the bucket's minutes; scale 10
  or 100 is a value shown divided by it) and an `x` row per bucket, `-` where no minute had a
  value: a column added later reaches `tando snapshot` without a change there. It needs root (the
  directory is 700).
- **Cost of the extended sample.** BenchmarkSampleMinute (25 apps, a whole fake /proc and /sys,
  `go test -run - -bench SampleMinute ./metrics`): 3.4–4.3 ms of CPU per sample on Linux (the
  arm64 test container, overlayfs; 3 runs), about 7–8 ms on macOS APFS, whose open(2) is slower;
  the same sample without host.x, tandod.x and the slice columns took 3.4 ms on macOS. Budget: 5 ms
  on Linux. Per app it reads 5 small files more (the slice's `cpu.stat`, `memory.events`,
  `pids.current`, `pids.max`, `memory.pressure`), for the host about 12 files under /proc and
  /sys, and writes two lines and `.x.state`.
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
