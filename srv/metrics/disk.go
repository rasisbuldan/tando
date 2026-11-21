package metrics

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"tando/srv/internal/apps"
)

const (
	diskEvery    = 900                    // seconds between two walks of one app's tree
	diskBudget   = 500 * time.Millisecond // walking time one sample may spend, all apps together
	diskRotate   = 24 << 10               // <app>.disk becomes .disk.1 past this size (~1000 lines, 10 days)
	diskCheckDue = 256                    // entries between two looks at the clock
)

// sampleDisk walks the trees of the apps whose last walk is 15 minutes old or more, oldest first,
// in-process (no du), until the sample's budget is spent, and appends "time bytes" to <app>.disk.
// A walk that runs past the budget is dropped (no line: a gap) and the app waits its 15 minutes
// like one that finished, so one huge tree cannot take every sample's time. The value between two
// walks is the last line: `read` carries it.
func (m Metrics) sampleDisk(now int64, names []string, next state) {
	var due []string
	for _, a := range names {
		if e, ok := next[a]; ok && now-e.x >= diskEvery {
			due = append(due, a)
		}
	}
	sort.SliceStable(due, func(i, j int) bool { return next[due[i]].x < next[due[j]].x })
	budget := m.DiskBudget
	if budget == 0 {
		budget = diskBudget
	}
	w := walker{deadline: time.Now().Add(budget)}
	for i, a := range due {
		if i > 0 && time.Now().After(w.deadline) {
			return // the rest stay due: the next sample takes them first
		}
		w.seen, w.bytes, w.files = map[inode]bool{}, 0, 0
		ok := true
		for _, root := range m.appTrees(a) {
			if ok = w.walk(root); !ok {
				break
			}
		}
		e := next[a]
		e.x = now
		next[a] = e
		if ok {
			m.appendDisk(a, now, w.bytes)
		}
	}
}

// appTrees: what an app has on this server's disk: /opt/tando/apps/<app> (releases, shared data,
// incoming, its home), its data_dir when that is outside (an adopted app), and its journal
// namespace's directories (/var/log/journal/<machine id>.tando-<app>). Not its PostgreSQL
// database (that is the cluster's) nor its backups (/var/backups/tando).
func (m Metrics) appTrees(a string) []string {
	dir := apps.Dir(m.Env.Root, a)
	roots := []string{dir}
	if c, err := apps.Conf(m.Env.Root, a); err == nil {
		if d := c["data_dir"]; filepath.IsAbs(d) && d != dir && !strings.HasPrefix(d, dir+"/") {
			roots = append(roots, filepath.Clean(d))
		}
	}
	j, _ := filepath.Glob(filepath.Join(m.Journal, "*.tando-"+a))
	return append(roots, j...)
}

// appendDisk adds "time bytes" to <app>.disk; past diskRotate it becomes .disk.1 first.
func (m Metrics) appendDisk(a string, now, bytes int64) {
	f := filepath.Join(m.Dir, a+".disk")
	if fi, err := os.Stat(f); err == nil && fi.Size() >= diskRotate {
		os.Rename(f, f+".1")
	}
	w, err := os.OpenFile(f, os.O_WRONLY|os.O_APPEND|os.O_CREATE, fileMode)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "%d\t%d\n", now, bytes)
	w.Close()
}

type inode struct{ dev, ino uint64 }

// walker sums the blocks of a tree as du does (allocated bytes; a hard link once; symlinks not
// followed) and gives up at deadline.
type walker struct {
	deadline     time.Time
	seen         map[inode]bool
	bytes, files int64
	n            int
}

// walk adds root's tree; false when the deadline passed. A missing root is 0 bytes.
func (w *walker) walk(root string) bool {
	var st syscall.Stat_t
	if err := syscall.Lstat(root, &st); err != nil {
		return true
	}
	w.add(&st)
	if st.Mode&syscall.S_IFMT != syscall.S_IFDIR {
		return true
	}
	return w.dir(root)
}

func (w *walker) add(st *syscall.Stat_t) {
	if st.Nlink > 1 && st.Mode&syscall.S_IFMT != syscall.S_IFDIR {
		k := inode{uint64(st.Dev), uint64(st.Ino)}
		if w.seen[k] {
			return
		}
		w.seen[k] = true
	}
	w.bytes += int64(st.Blocks) * 512
	w.files++
}

func (w *walker) dir(path string) bool {
	if time.Now().After(w.deadline) {
		return false
	}
	f, err := os.Open(path)
	if err != nil {
		return true // unreadable: what we can see
	}
	names, _ := f.Readdirnames(-1)
	f.Close()
	var st syscall.Stat_t
	for _, n := range names {
		if w.n++; w.n%diskCheckDue == 0 && time.Now().After(w.deadline) {
			return false
		}
		p := path + "/" + n
		if err := syscall.Lstat(p, &st); err != nil {
			continue
		}
		w.add(&st)
		if st.Mode&syscall.S_IFMT == syscall.S_IFDIR {
			if !w.dir(p) {
				return false
			}
		}
	}
	return true
}
