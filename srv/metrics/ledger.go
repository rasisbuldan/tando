package metrics

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/apps"
	"tando/srv/internal/usage"
)

// ledger collects one sample's metering rows (internal/usage): per app, the time since its last
// row, its caps, how long its web unit was up in that time (systemd's monotonic enter
// timestamps against /proc/uptime, as tando-watch reads them), and the measured memory and CPU.
type ledger struct {
	dir  string
	last map[string]int64
	boot string
	mono int64 // microseconds since boot now (0: unknown: awake is then judged by the state alone)
	rows []usage.Row
	ends map[string]int64
}

// usageDir is Lib/usage, beside the metrics directory.
func (m Metrics) usageDir() string { return filepath.Join(filepath.Dir(m.Dir), "usage") }

func (m Metrics) bootID() string {
	b, _ := os.ReadFile(filepath.Join(m.Env.Proc, "sys", "kernel", "random", "boot_id"))
	s := strings.TrimSpace(string(b))
	if len(s) < 8 {
		return "-"
	}
	return s[:8]
}

func (m Metrics) uptimeUsec() int64 {
	b, err := os.ReadFile(filepath.Join(m.Env.Proc, "uptime"))
	if err != nil {
		return 0
	}
	f := strings.Fields(string(b))
	if len(f) == 0 {
		return 0
	}
	v, err := strconv.ParseFloat(f[0], 64)
	if err != nil {
		return 0
	}
	return int64(v * 1e6)
}

// add is one app's row (rows of an app that held nothing and ran nothing are left out: a
// stopped static site).
func (l *ledger) add(root, app string, now int64, props map[string]string, memBytes, cpuUsec int64) {
	if l.ends == nil {
		l.ends = map[string]int64{}
	}
	t0 := usage.Interval(l.last, app, now)
	l.ends[app] = now
	conf, _ := apps.Conf(root, app)
	web, workers := usage.Caps(conf)
	if conf["recipe"] == "static" {
		web, workers = 0, 0 // no process: Caddy serves its files
	}
	st := props["ActiveState"]
	up := st != "inactive" && st != "failed" && st != ""
	span := now - t0
	var awake int64
	if l.mono > 0 {
		ae, _ := strconv.ParseInt(props["ActiveEnterTimestampMonotonic"], 10, 64)
		ie, _ := strconv.ParseInt(props["InactiveEnterTimestampMonotonic"], 10, 64)
		awake = usage.Awake(ae, ie, up, l.mono-span*1e6, l.mono) / 1e6
	} else if up {
		awake = span
	}
	if web == 0 && workers == 0 && awake == 0 && memBytes == 0 {
		return
	}
	l.rows = append(l.rows, usage.Row{T: now, Boot: l.boot, App: app, Interval: span, AllocMB: web,
		WorkersMB: workers, AwakeS: awake, MemMB: memBytes >> 20, CPUms: cpuUsec / 1000})
}

// write appends the rows and remembers where each app's next row starts.
func (l *ledger) write(now time.Time) error {
	if l.ends == nil {
		return nil
	}
	if err := os.MkdirAll(l.dir, 0o700); err != nil {
		return err
	}
	if err := usage.Append(l.dir, now, l.rows); err != nil {
		return err
	}
	return usage.SaveLast(l.dir, l.ends)
}
