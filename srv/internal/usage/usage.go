// Package usage is the metering ledger: one row per app and minute with the memory the app is
// allocated (its caps), the seconds its web process was awake, and what it measurably used
// (informational). tando-metrics' per-minute sample appends to it (metrics.Sample); the control
// plane's `usage` verb reads it with a cursor (srv/ctl, docs/CONTROL-PLANE.md "Metering").
//
// Metering is allocation-based: alloc_mb x awake_s is what an app held; mem_mb and cpu_ms are
// measured once a minute and only informational (a cgroup's counters start over when its unit
// does, and idle_stop removes the cgroup).
//
// Files, in Dir (/var/lib/tando/usage, root 700):
//
//	seg-<first seq, 16 digits>.tsv   rows, appended and fsynced once a minute; a new segment
//	                                 starts at segMax bytes; segments older than Keep are removed
//	                                 (never the newest)
//	.last                            "<app> <unix time>": when each app's last row ended (the
//	                                 next row covers the time since, up to maxGap)
//
// A row: seq  t  boot  app  interval_s  alloc_mb  alloc_workers_mb  awake_s  mem_mb  cpu_ms
// (tab-separated; columns are only ever added at the end; a reader skips a line it cannot read,
// such as one cut by a crash). seq grows by one per row, across segments and restarts: it is
// the cursor. boot is the start of the kernel's boot id: a reboot shows as a new value.
//
// Layer: internal. It imports internal/atomicfile and the standard library only.
package usage

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
)

const (
	segMax = 8 << 20 // bytes of one segment (about 100 apps x 1 day)
	// Keep is how long rows are kept: a control plane that reads at least this often loses nothing.
	Keep    = 14 * 24 * time.Hour
	maxGap  = 3600 // seconds one row may cover (after a stop of the sampler); longer: 60
	dirMode = 0o700
)

// Row is one app's minute.
type Row struct {
	Seq       int64  `json:"seq"`
	T         int64  `json:"t"`    // unix time the interval ended
	Boot      string `json:"boot"` // the boot it was measured in
	App       string `json:"app"`
	Interval  int64  `json:"interval_s"`
	AllocMB   int64  `json:"alloc_mb"`         // the web process' memory cap
	WorkersMB int64  `json:"alloc_workers_mb"` // the workers' caps (they run always)
	AwakeS    int64  `json:"awake_s"`          // seconds of the interval the web process ran
	MemMB     int64  `json:"mem_mb"`           // measured at the end (anon + shmem), informational
	CPUms     int64  `json:"cpu_ms"`           // CPU time in the interval, informational
}

func (r Row) line() string {
	return fmt.Sprintf("%d\t%d\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n", r.Seq, r.T, r.Boot, r.App, r.Interval,
		r.AllocMB, r.WorkersMB, r.AwakeS, r.MemMB, r.CPUms)
}

func parseRow(l string) (Row, bool) {
	f := strings.Split(l, "\t")
	if len(f) < 10 {
		return Row{}, false
	}
	var n [10]int64
	for _, i := range []int{0, 1, 4, 5, 6, 7, 8, 9} {
		v, err := strconv.ParseInt(f[i], 10, 64)
		if err != nil {
			return Row{}, false
		}
		n[i] = v
	}
	return Row{Seq: n[0], T: n[1], Boot: f[2], App: f[3], Interval: n[4], AllocMB: n[5], WorkersMB: n[6],
		AwakeS: n[7], MemMB: n[8], CPUms: n[9]}, n[0] > 0
}

// segments lists Dir's segments by first seq.
func segments(dir string) ([]string, error) {
	ents, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var s []string
	for _, e := range ents {
		n := e.Name()
		if strings.HasPrefix(n, "seg-") && strings.HasSuffix(n, ".tsv") && len(n) == 4+16+4 && e.Type().IsRegular() {
			s = append(s, n)
		}
	}
	sort.Strings(s)
	return s, nil
}

// lastSeq is the seq of the last whole row of a segment (0: none).
func lastSeq(path string) (int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return 0, err
	}
	off := max(fi.Size()-64<<10, 0)
	b := make([]byte, fi.Size()-off)
	if _, err := f.ReadAt(b, off); err != nil && err != io.EOF {
		return 0, err
	}
	var last int64
	for l := range bytes.SplitSeq(b, []byte{'\n'}) {
		if r, ok := parseRow(string(l)); ok && r.Seq > last {
			last = r.Seq
		}
	}
	return last, nil
}

// Append gives rows their seq and appends them to the newest segment (a new one when it is
// full), fsynced; then removes segments older than Keep.
func Append(dir string, now time.Time, rows []Row) error {
	if len(rows) == 0 {
		return nil
	}
	if err := os.MkdirAll(dir, dirMode); err != nil {
		return err
	}
	os.Chmod(dir, dirMode)
	segs, err := segments(dir)
	if err != nil {
		return err
	}
	var seq int64
	cur := ""
	if len(segs) > 0 {
		cur = filepath.Join(dir, segs[len(segs)-1])
		if seq, err = lastSeq(cur); err != nil {
			return err
		}
		if seq == 0 { // an empty or unreadable newest segment: its name says where it began
			n, _ := strconv.ParseInt(strings.TrimPrefix(strings.TrimSuffix(segs[len(segs)-1], ".tsv"), "seg-"), 10, 64)
			seq = max(n-1, 0)
		}
		if fi, err := os.Stat(cur); err == nil && fi.Size() >= segMax {
			cur = ""
		}
	}
	if cur == "" {
		cur = filepath.Join(dir, fmt.Sprintf("seg-%016d.tsv", seq+1))
	}
	var b strings.Builder
	for i := range rows {
		seq++
		rows[i].Seq = seq
		b.WriteString(rows[i].line())
	}
	f, err := os.OpenFile(cur, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	// a row cut by a crash is ended first: the new rows start on a line of their own
	if fi, err := f.Stat(); err == nil && fi.Size() > 0 {
		last := make([]byte, 1)
		if r, err := os.Open(cur); err == nil {
			r.ReadAt(last, fi.Size()-1)
			r.Close()
		}
		if last[0] != '\n' {
			f.WriteString("\n")
		}
	}
	_, err = f.WriteString(b.String())
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	prune(dir, segs, now)
	return nil
}

// prune removes segments whose rows all ended over Keep ago (the newest is always kept).
func prune(dir string, segs []string, now time.Time) {
	for _, s := range segs[:max(len(segs)-1, 0)] {
		p := filepath.Join(dir, s)
		if fi, err := os.Stat(p); err == nil && now.Sub(fi.ModTime()) > Keep {
			os.Remove(p)
		}
	}
}

// Page is a read from a cursor.
type Page struct {
	Rows []Row `json:"rows"`
	// Next is the cursor for the next read (the last row's seq; since itself when nothing is new).
	Next int64 `json:"next"`
	// Oldest is the first seq still kept (0: none); Gap: rows after since were already removed.
	Oldest int64 `json:"oldest"`
	Gap    bool  `json:"gap"`
	More   bool  `json:"more"` // the limit was reached: read again from Next
}

// Read returns up to limit rows with seq > since (of app only, when app is not "").
func Read(dir string, since int64, limit int, app string) (Page, error) {
	p := Page{Rows: []Row{}, Next: since}
	segs, err := segments(dir)
	if err != nil {
		return p, err
	}
	first := func(s string) int64 {
		n, _ := strconv.ParseInt(strings.TrimSuffix(strings.TrimPrefix(s, "seg-"), ".tsv"), 10, 64)
		return n
	}
	if len(segs) > 0 {
		p.Oldest = first(segs[0])
		p.Gap = since+1 < p.Oldest
	}
	for i, s := range segs {
		if i+1 < len(segs) && first(segs[i+1]) <= since+1 {
			continue // every row of this segment is at or before since
		}
		f, err := os.Open(filepath.Join(dir, s))
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 64<<10), 1<<20)
		for sc.Scan() {
			r, ok := parseRow(sc.Text())
			if !ok || r.Seq <= since {
				continue
			}
			p.Next = r.Seq
			if app != "" && r.App != app {
				continue
			}
			p.Rows = append(p.Rows, r)
			if len(p.Rows) >= limit {
				p.More = true
				f.Close()
				return p, nil
			}
		}
		f.Close()
	}
	return p, nil
}

// LoadLast reads .last: when each app's last row ended.
func LoadLast(dir string) map[string]int64 {
	m := map[string]int64{}
	b, err := os.ReadFile(filepath.Join(dir, ".last"))
	if err != nil {
		return m
	}
	for l := range strings.SplitSeq(string(b), "\n") {
		f := strings.Fields(l)
		if len(f) == 2 {
			if n, err := strconv.ParseInt(f[1], 10, 64); err == nil {
				m[f[0]] = n
			}
		}
	}
	return m
}

// SaveLast writes .last (apps that are gone drop out: only the apps of this minute are written).
func SaveLast(dir string, m map[string]int64) error {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		fmt.Fprintf(&b, "%s %d\n", k, m[k])
	}
	return atomicfile.WriteVolatile(filepath.Join(dir, ".last"), []byte(b.String()), atomicfile.Mode(0o600))
}

// Interval is the start of an app's next row: its last end, or now-60 for a first row or one
// after a gap over maxGap (that time is not metered: the sampler did not run).
func Interval(last map[string]int64, app string, now int64) int64 {
	t0, ok := last[app]
	if !ok || now-t0 > maxGap || now-t0 <= 0 {
		return now - 60
	}
	return t0
}

// Awake is how many microseconds of [m0, m1] (monotonic, microseconds since boot) a unit ran,
// from systemd's ActiveEnterTimestampMonotonic (ae) and InactiveEnterTimestampMonotonic (ie) and
// whether it is up now. One start and one stop within the interval are seen exactly; more (a
// unit that slept and woke several times in one minute) count from the last start.
func Awake(ae, ie int64, up bool, m0, m1 int64) int64 {
	var d int64
	switch {
	case up && ae > 0:
		d = m1 - max(m0, ae)
	case !up && ie > m0 && ae > 0 && ae < ie:
		d = min(ie, m1) - max(m0, ae)
	}
	return min(max(d, 0), m1-m0)
}

// MB is a memory value of tando.conf (512M, 1G, 65536K) in MB; def when it is not one.
func MB(v string, def int64) int64 {
	if len(v) < 2 {
		return def
	}
	n, err := strconv.ParseInt(v[:len(v)-1], 10, 64)
	if err != nil || n < 0 {
		return def
	}
	switch v[len(v)-1] {
	case 'G':
		return n * 1024
	case 'M':
		return n
	case 'K':
		return n / 1024
	}
	return def
}

// Caps is an app's memory caps from its app.conf (the agent's mem_caps_mb): the web process'
// (default 256 MB) and its workers' together (worker.<name>.memory, else the app's).
func Caps(conf map[string]string) (web, workers int64) {
	web = MB(conf["memory"], 256)
	for k := range conf {
		name, ok := strings.CutPrefix(k, "worker.")
		if !ok || strings.Contains(name, ".") {
			continue
		}
		workers += MB(conf["worker."+name+".memory"], web)
	}
	return web, workers
}

// Admitted is what admission counts for an app (mem_caps_mb -a): an app with idle_stop (not
// static, not a container) counts 2 MB plus idleAwake % of its web cap; workers count whole.
func Admitted(conf map[string]string, idleAwake int64) int64 {
	web, workers := Caps(conf)
	is, r := conf["idle_stop"], conf["recipe"]
	if is != "" && is != "off" && r != "static" && r != "container" {
		web = 2 + (web*idleAwake+99)/100
	}
	return web + workers
}

// AwakeSince sums each app's awake seconds over the rows that ended after t (only segments
// written to since t are read).
func AwakeSince(dir string, t int64) map[string]int64 {
	m := map[string]int64{}
	segs, _ := segments(dir)
	for _, s := range segs {
		p := filepath.Join(dir, s)
		if fi, err := os.Stat(p); err != nil || fi.ModTime().Unix() < t {
			continue
		}
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 64<<10), 1<<20)
		for sc.Scan() {
			if r, ok := parseRow(sc.Text()); ok && r.T > t {
				m[r.App] += r.AwakeS
			}
		}
		f.Close()
	}
	return m
}
