// Package metrics keeps per-minute samples of every tando app and of the host, for the graphs of
// `tando top` and the trend in `tando status` (docs/TOP.md). Nothing keeps running: `sample` is
// run once a minute by tando-watch.service (ExecStartPre, see tando-watch's install) and costs
// one systemctl call and a few /sys and /proc reads; `read` needs root (the directory is 700).
//
// Files, in Dir (/var/lib/tando/metrics, root 700: an app must not read another app's memory, CPU
// and restarts), read through sudo by `tando top`:
//
//	<app>.tsv, <app>.tsv.1   time  mem_bytes  cpu_usec_since_last_sample  restarts  state(r|s|f|a)
//	                         then (since 2026-11) the slice's: throttled_permille  oom_kills  tasks
//	                         tasks_max  memory_psi_x100 ("-": not known; sample.go readSlice)
//	                         then (since 2026-11) net_out_bytes  net_in_bytes: what the app's uid
//	                         sent and got back over the network since the last line (sample.go appNet)
//	host.tsv, host.tsv.1     time  load1x100  mem_used_bytes  mem_total_bytes  cpu_permille_all_cores
//	                         disk_used_bytes  disk_total_bytes  (the last three since 2026-11; "-":
//	                         not known; the disk is the file system holding Dir)
//	<app>.disk, .disk.1      time  bytes: the app's tree, walked at most every 15 min (disk.go)
//	host.x, tandod.x (.1)    the host's extended line and what the monitoring costs, a minute at a
//	                         time (hostx.go, self.go; named columns: readx.go)
//	.state                   "<app> <cpu usage_usec> <file start time> <lines> <last disk walk>
//	                         <nr_periods> <nr_throttled> <oom_kill> <net out> <net in>" per app, and ".host <busy
//	                         jiffies> <start> <lines> <total jiffies>"
//	.x.state                 "<key> <value>": the raw counters host.x and tandod.x were last
//	                         computed from, and their files' start and line count
//
// Columns are only ever added at the end of a line, and a reader takes the fields it knows.
//
// Each file covers at most 3.5 days or 5100 lines, then becomes .1 (the old .1 is dropped), so an
// app keeps at most 7 days, about 2 x 160 KB. The format is the shell version's: files it wrote
// are read as they are. mem_bytes is anon + shmem of memory.stat (before 2026-11: anon only).
//
// Layer: domain. It imports internal/* only; no other domain package, not daemon.
package metrics

import (
	"path/filepath"
	"time"

	"tando/srv/internal/env"
)

const (
	span     = 302400 // seconds one file covers (3.5 days)
	maxLines = 5100   // lines one file holds
	fileMode = 0o600  // root's: tando top reads them through sudo
	dirMode  = 0o700  // (set again on every sample: older versions made it 755)
)

// Metrics samples into and reads from Dir.
type Metrics struct {
	Env        env.Env
	Dir        string
	Journal    string        // /var/log/journal: the apps' journal namespaces, counted in their disk
	DiskBudget time.Duration // walking time one sample may spend (0: diskBudget)
	Sys        string        // /sys ("": /sys): the main disk's name (host.x)
	Self       SelfCounters  // tandod's own counters (tandod.x); nil: not known (a one-shot)
}

// New uses dir, or Env.Lib/metrics when dir is "" (the shell's TANDO_METRICS_DIR override).
func New(e env.Env, dir string) Metrics {
	if dir == "" {
		dir = filepath.Join(e.Lib, "metrics")
	}
	return Metrics{Env: e, Dir: dir, Journal: "/var/log/journal"}
}

func (m Metrics) file(who string) string { return filepath.Join(m.Dir, who+".tsv") }
