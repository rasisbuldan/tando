// Package live is tandod's fast loop: every 5 s a point of every app (memory, CPU, tasks and the
// unit's state) and of the host (load, memory, CPU, disk), kept for an hour in memory, for the
// live views (tando status --follow, tando top, the dashboard). It is for looking only: it
// writes no file, takes no lock, feeds no alert rule (they stay once a minute in srv/watch on
// srv/metrics' samples) and starts no program: the cgroup v2 files, /proc, statfs and the unit
// properties the daemon asks over systemd's bus (Units).
//
// A host without the unified cgroup hierarchy (cgroup v1 or hybrid) has no fast loop: V2 says
// so and the daemon then answers the live verbs with an error (the minute samples still run).
//
// Layer: domain. It imports internal/* only; the daemon runs it and serves its rows.
package live

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"tando/srv/internal/apps"
	"tando/srv/internal/cgroup"
	"tando/srv/internal/decimal"
	"tando/srv/internal/env"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/out"
)

// Every is the interval of the fast loop; Keep how many points the ring holds (an hour).
const (
	Every = 5 * time.Second
	Keep  = int(time.Hour / Every)
)

// Units reads ActiveState, SubState, NRestarts and MainPID of the given units, one map per unit
// in order (the daemon's bus: loaded units are asked, the others read as a unit just loaded).
type Units func(units []string) ([]map[string]string, error)

// App is one app in a point.
type App struct {
	Name      string
	Active    string // ActiveState ("?": systemd did not answer)
	Sub       string // SubState
	Restarts  int64  // NRestarts
	MainPID   int64
	Mem       int64 // anon + shmem of the unit's cgroup (what status shows)
	CPU       int64 // per mille of one core since the last point; -1: none (the first point)
	Tasks     int64 // pids.current
	usageUsec int64
}

// Host is the host in a point.
type Host struct {
	Load               string // the first field of /proc/loadavg
	MemUsed, MemTotal  int64  // bytes: MemTotal - MemAvailable, MemTotal
	CPU                int64  // per mille of all cores since the last point; -1: none
	DiskUsed, DiskSize uint64 // bytes of /
	busy, total        uint64 // /proc/stat's first line: busy and all jiffies
}

// Point is one sample.
type Point struct {
	At   int64 // epoch seconds
	Host Host
	Apps []App
}

// Live samples and keeps the ring.
type Live struct {
	Env    env.Env
	Units  Units
	Statfs func(path string) (used, size uint64, err error) // nil: fsinfo.Statfs of "/"

	mu   sync.Mutex
	ring []Point // oldest first, at most Keep
	last time.Time
}

// New makes the fast loop of a host.
func New(e env.Env, u Units) *Live { return &Live{Env: e, Units: u} }

// V2 says whether the host has the unified cgroup hierarchy at root (/sys/fs/cgroup): its
// cgroup.controllers file exists only there.
func V2(root string) bool {
	fi, err := os.Stat(filepath.Join(root, "cgroup.controllers"))
	return err == nil && fi.Mode().IsRegular()
}

// Run samples every Every until ctx ends. A sample that panics is dropped (the loop goes on).
func (l *Live) Run(ctx context.Context) {
	t := time.NewTicker(Every)
	defer t.Stop()
	for {
		l.safeSample()
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (l *Live) safeSample() {
	defer func() { recover() }()
	l.Sample()
}

// Sample takes a point now and adds it to the ring.
func (l *Live) Sample() Point {
	now := l.Env.Now()
	l.mu.Lock()
	var prev *Point
	if n := len(l.ring); n > 0 {
		prev = &l.ring[n-1]
	}
	l.mu.Unlock()
	p := Point{At: now.Unix(), Host: l.host(prev)}
	names, _ := apps.Names(l.Env.Root)
	p.Apps = l.apps(names, prev, now)
	l.mu.Lock()
	if len(l.ring) >= Keep {
		copy(l.ring, l.ring[1:])
		l.ring = l.ring[:Keep-1]
	}
	l.ring = append(l.ring, p)
	l.last = now
	l.mu.Unlock()
	return p
}

func (l *Live) apps(names []string, prev *Point, now time.Time) []App {
	if len(names) == 0 {
		return nil
	}
	units := make([]string, len(names))
	for i, a := range names {
		units[i] = "tando-" + a + ".service"
	}
	var props []map[string]string
	if l.Units != nil {
		props, _ = l.Units(units)
	}
	old := map[string]*App{}
	var dt int64
	if prev != nil {
		for i := range prev.Apps {
			old[prev.Apps[i].Name] = &prev.Apps[i]
		}
		dt = now.UnixMicro() - l.last.UnixMicro()
	}
	res := make([]App, len(names))
	for i, a := range names {
		r := App{Name: a, Active: "?", Sub: "?", CPU: -1}
		if len(props) == len(names) {
			m := props[i]
			r.Active, r.Sub = orQ(m["ActiveState"]), orQ(m["SubState"])
			r.Restarts, _ = strconv.ParseInt(m["NRestarts"], 10, 64)
			r.MainPID, _ = strconv.ParseInt(m["MainPID"], 10, 64)
		}
		dir := cgroup.AppDir(l.Env.Cgroup, a)
		r.Mem = cgroup.Sum(filepath.Join(dir, "memory.stat"), "anon", "shmem")
		r.usageUsec, _ = cgroup.Value(filepath.Join(dir, "cpu.stat"), "usage_usec")
		r.Tasks = firstNumber(filepath.Join(dir, "pids.current"))
		if o := old[a]; o != nil && dt > 0 {
			d := r.usageUsec - o.usageUsec
			if d < 0 {
				d = r.usageUsec // the unit restarted: its counter began again
			}
			r.CPU = d * 1000 / dt
		}
		res[i] = r
	}
	return res
}

// orQ is s, "?" for none; the usual words are shared, so the ring holds no copy of them.
func orQ(s string) string {
	if s == "" {
		return "?"
	}
	for _, w := range words {
		if s == w {
			return w
		}
	}
	return s
}

var words = []string{"active", "inactive", "failed", "activating", "deactivating", "reloading", "running", "dead",
	"exited", "auto-restart", "start", "stop", "stop-sigterm", "start-pre", "start-post", "final-sigterm"}

func (l *Live) host(prev *Point) Host {
	h := Host{CPU: -1}
	b, _ := os.ReadFile(filepath.Join(l.Env.Proc, "loadavg"))
	h.Load, _, _ = strings.Cut(strings.TrimSpace(string(b)), " ")
	b, _ = os.ReadFile(filepath.Join(l.Env.Proc, "meminfo"))
	var total, avail int64
	for _, ln := range strings.Split(string(b), "\n") {
		f := strings.Fields(ln)
		if len(f) < 2 {
			continue
		}
		switch f[0] {
		case "MemTotal:":
			total, _ = strconv.ParseInt(f[1], 10, 64)
		case "MemAvailable:":
			avail, _ = strconv.ParseInt(f[1], 10, 64)
		}
	}
	h.MemTotal, h.MemUsed = total*1024, (total-avail)*1024
	b, _ = os.ReadFile(filepath.Join(l.Env.Proc, "stat"))
	h.busy, h.total = cpuJiffies(b)
	if prev != nil && h.total > prev.Host.total && h.busy >= prev.Host.busy {
		h.CPU = int64((h.busy - prev.Host.busy) * 1000 / (h.total - prev.Host.total))
	}
	statfs := l.Statfs
	if statfs == nil {
		statfs = rootfs
	}
	h.DiskUsed, h.DiskSize, _ = statfs("/")
	return h
}

func rootfs(path string) (used, size uint64, err error) {
	fs, err := fsinfo.Statfs(path)
	if err != nil {
		return 0, 0, err
	}
	return (fs.Blocks - fs.Free) * fs.Unit, fs.Blocks * fs.Unit, nil
}

// cpuJiffies reads /proc/stat's "cpu" line: busy (all but idle and iowait) and total jiffies.
func cpuJiffies(b []byte) (busy, total uint64) {
	ln, _, _ := bytes.Cut(b, []byte("\n"))
	f := strings.Fields(string(ln))
	if len(f) < 5 || f[0] != "cpu" {
		return 0, 0
	}
	for i, s := range f[1:] {
		if i >= 8 { // guest and guest_nice are already in user and nice
			break
		}
		n, _ := strconv.ParseUint(s, 10, 64)
		total += n
		if i != 3 && i != 4 { // idle, iowait
			busy += n
		}
	}
	return busy, total
}

func firstNumber(file string) int64 {
	b, err := os.ReadFile(file)
	if err != nil {
		return 0
	}
	n, _ := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	return n
}

func num(n int64) string {
	if n < 0 {
		return "-"
	}
	return decimal.Itoa(n)
}

// Rows writes the latest point (app "": every app; else that app and the host):
//
//	lhost <epoch> <load> <mem used> <mem total> <cpu ‰ of all cores> <disk used> <disk size>
//	lapp <app> <epoch> <ActiveState> <SubState> <NRestarts> <MainPID> <mem> <cpu ‰ of a core> <tasks> <cpu µs>
//
// Bytes for memory and disk; "-" for a CPU not known yet; the last field is the cgroup's CPU time
// so far (cpu.stat usage_usec). Nothing at all before the first point.
func (l *Live) Rows(w *out.Writer, app string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(l.ring) == 0 {
		return
	}
	p := &l.ring[len(l.ring)-1]
	h := p.Host
	w.Row("lhost", decimal.Itoa(p.At), h.Load, decimal.Itoa(h.MemUsed), decimal.Itoa(h.MemTotal), num(h.CPU),
		strconv.FormatUint(h.DiskUsed, 10), strconv.FormatUint(h.DiskSize, 10))
	for _, a := range p.Apps {
		if app != "" && a.Name != app {
			continue
		}
		w.Row("lapp", a.Name, decimal.Itoa(p.At), a.Active, a.Sub, decimal.Itoa(a.Restarts), decimal.Itoa(a.MainPID),
			decimal.Itoa(a.Mem), num(a.CPU), decimal.Itoa(a.Tasks), decimal.Itoa(a.usageUsec))
	}
}

// RingRows writes the last hour, oldest first (app "": every app):
//
//	rhost <epoch> <load> <mem used> <cpu ‰ of all cores>
//	rapp <app> <epoch> <mem> <cpu ‰ of a core> <ActiveState>
func (l *Live) RingRows(w *out.Writer, app string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	for i := range l.ring {
		p := &l.ring[i]
		w.Row("rhost", decimal.Itoa(p.At), p.Host.Load, decimal.Itoa(p.Host.MemUsed), num(p.Host.CPU))
		for _, a := range p.Apps {
			if app != "" && a.Name != app {
				continue
			}
			w.Row("rapp", a.Name, decimal.Itoa(p.At), decimal.Itoa(a.Mem), num(a.CPU), a.Active)
		}
	}
}

// Len is the number of points held.
func (l *Live) Len() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.ring)
}
