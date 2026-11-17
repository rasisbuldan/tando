package metrics

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"tando/srv/internal/apps"
	"tando/srv/internal/atomicfile"
	"tando/srv/internal/cgroup"
	"tando/srv/internal/systemd"
)

// Sample appends one line per app and one for the host, then rewrites .state.
func (m Metrics) Sample(ctx context.Context) error {
	if m.Env.EUID != 0 {
		return errors.New("sample runs as root (from tando-watch.timer)")
	}
	if err := os.MkdirAll(m.Dir, dirMode); err != nil {
		return fmt.Errorf("cannot create %s: %w", m.Dir, err)
	}
	now := m.Env.Now().Unix()
	statePath := filepath.Join(m.Dir, ".state")
	prev, err := loadState(statePath)
	if err != nil {
		return err
	}
	names, err := apps.Names(m.Env.Root)
	if err != nil {
		return fmt.Errorf("list apps: %w", err)
	}
	next := state{}
	keys := append(slices.Clone(names), hostKey) // .state's order: the apps, then the host

	appErr := m.sampleApps(ctx, now, names, prev, next)
	if appErr != nil {
		// systemd did not answer (or a file could not be written): no line this minute for the
		// apps not done yet, but their files' line counts and start times must survive, or the
		// next sample would start those files over (the shell version lost them)
		for _, a := range names {
			if _, done := next[a]; !done {
				if e, ok := prev[a]; ok {
					next[a] = e
				}
			}
		}
	}
	if err := m.sampleHost(now, prev[hostKey], next); err != nil {
		return err
	}
	if err := atomicfile.Write(statePath, next.format(keysIn(next, keys)), atomicfile.Mode(fileMode)); err != nil {
		return err
	}
	if appErr != nil {
		return fmt.Errorf("apps not sampled: %w", appErr)
	}
	return nil
}

func (m Metrics) sampleApps(ctx context.Context, now int64, names []string, prev, next state) error {
	if len(names) == 0 {
		return nil
	}
	units := make([]string, len(names))
	for i, a := range names {
		units[i] = "tando-" + a + ".service"
	}
	props, err := systemd.Show(ctx, m.Env.Run, units, "ActiveState", "NRestarts")
	if err != nil {
		return err
	}
	for i, a := range names {
		dir := cgroup.AppDir(m.Env.Cgroup, a)
		mem, _ := cgroup.Value(filepath.Join(dir, "memory.stat"), "anon")
		usec, _ := cgroup.Value(filepath.Join(dir, "cpu.stat"), "usage_usec")
		p, seen := prev[a]
		d := int64(0) // the first sample of an app has nothing to compare with
		if seen && p.usec >= 0 {
			d = usec - p.usec
		}
		if d < 0 {
			d = usec // the unit restarted: its counter began again
		}
		restarts := props[i]["NRestarts"]
		if _, err := strconv.ParseUint(restarts, 10, 64); err != nil {
			restarts = "0"
		}
		e, err := m.appendLine(a, now, p, fmt.Sprintf("%d\t%d\t%d\t%s\t%s", now, mem, d, restarts, stateLetter(props[i]["ActiveState"])))
		if err != nil {
			return err
		}
		e.usec = usec
		next[a] = e
	}
	return nil
}

// stateLetter: r running, f failed, s stopped, a anything else (activating, deactivating, ...).
func stateLetter(active string) string {
	switch active {
	case "active":
		return "r"
	case "failed":
		return "f"
	case "inactive", "":
		return "s"
	}
	return "a"
}

func (m Metrics) sampleHost(now int64, prev entry, next state) error {
	load, err := os.ReadFile(filepath.Join(m.Env.Proc, "loadavg"))
	if err != nil {
		return err
	}
	// "0.52 0.40 0.31 ..." -> 52: the 1-minute load times 100, without floating point
	l1, _, _ := strings.Cut(strings.TrimSpace(string(load)), " ")
	la, _ := strconv.ParseInt(strings.Replace(l1, ".", "", 1), 10, 64)
	total, avail, err := meminfo(filepath.Join(m.Env.Proc, "meminfo"))
	if err != nil {
		return err
	}
	e, err := m.appendLine("host", now, prev, fmt.Sprintf("%d\t%d\t%d\t%d", now, la, (total-avail)*1024, total*1024))
	if err != nil {
		return err
	}
	next[hostKey] = e
	return nil
}

// meminfo: MemTotal and MemAvailable in kB.
func meminfo(path string) (total, avail int64, err error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, 0, err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k := strings.Fields(sc.Text())
		if len(k) < 2 {
			continue
		}
		switch k[0] {
		case "MemTotal:":
			total, _ = strconv.ParseInt(k[1], 10, 64)
		case "MemAvailable:":
			avail, _ = strconv.ParseInt(k[1], 10, 64)
			return total, avail, nil
		}
	}
	return total, avail, sc.Err()
}

// appendLine adds line to who's file, rotating it first when it is full, and returns the
// file's new entry (start time and line count).
func (m Metrics) appendLine(who string, now int64, p entry, line string) (entry, error) {
	f := m.file(who)
	start, lines := p.start, p.lines
	if lines >= maxLines || (start > 0 && now-start >= span) {
		// full: it becomes .1 and the old .1 goes
		if fi, err := os.Stat(f); err == nil && fi.Mode().IsRegular() {
			if err := os.Rename(f, f+".1"); err != nil {
				return entry{}, fmt.Errorf("rotate %s: %w", f, err)
			}
		}
		start = 0
	}
	if start == 0 {
		start, lines = now, 0
	}
	w, err := os.OpenFile(f, os.O_WRONLY|os.O_APPEND|os.O_CREATE, fileMode)
	if err != nil {
		return entry{}, err
	}
	// one write(2) of a whole line: a reader never sees half of one (and drops an unfinished
	// last line anyway)
	_, err = w.WriteString(line + "\n")
	if cerr := w.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return entry{}, fmt.Errorf("append to %s: %w", f, err)
	}
	return entry{start: start, lines: lines + 1}, nil
}

// keysIn: those of keys that st has, in order.
func keysIn(st state, keys []string) []string {
	var out []string
	for _, k := range keys {
		if _, ok := st[k]; ok {
			out = append(out, k)
		}
	}
	return out
}
