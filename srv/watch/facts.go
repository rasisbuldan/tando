package watch

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"tando/srv/internal/cgroup"
	"tando/srv/internal/lock"
)

func errf(format string, a ...any) error { return fmt.Errorf(format, a...) }

// readFirst is the first line of a file ("" when it cannot be read).
func readFirst(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	l, _, _ := strings.Cut(string(b), "\n")
	return l
}

// bootTime is when PID 1 started (epoch seconds): it changes when the host (or the test
// container) restarts. From /proc/uptime and the start time of /proc/1/stat (USER_HZ is 100).
func (w Watch) bootTime(now int64) int64 {
	up, _, _ := strings.Cut(readFirst(filepath.Join(w.Env.Proc, "uptime")), " ")
	up, _, _ = strings.Cut(up, ".")
	st := readFirst(filepath.Join(w.Env.Proc, "1", "stat"))
	if i := strings.LastIndex(st, ") "); i >= 0 {
		st = st[i+2:]
	}
	f := strings.Fields(st)
	var start int64
	if len(f) > 19 {
		start = num(f[19], 0)
	}
	return now - num(up, 0) + start/100
}

// uptime: seconds since boot (the integer part of /proc/uptime).
func (w Watch) uptime() int64 {
	up, _, _ := strings.Cut(readFirst(filepath.Join(w.Env.Proc, "uptime")), " ")
	up, _, _ = strings.Cut(up, ".")
	return num(up, 0)
}

// ncpu: the CPUs this process may run on (Cpus_allowed_list), at least 1.
func (w Watch) ncpu() int64 {
	b, _ := os.ReadFile(filepath.Join(w.Env.Proc, "self", "status"))
	var list string
	for l := range strings.SplitSeq(string(b), "\n") {
		if v, ok := strings.CutPrefix(l, "Cpus_allowed_list:"); ok {
			list = strings.TrimSpace(v)
			break
		}
	}
	if list == "" {
		return 1
	}
	var n int64
	for p := range strings.SplitSeq(list, ",") {
		if a, b, ok := strings.Cut(p, "-"); ok {
			n += num(b, 0) - num(a, 0) + 1
		} else {
			n++
		}
	}
	return max(n, 1)
}

// meminfo: MemTotal, MemAvailable, SwapTotal, SwapFree in kB.
func (w Watch) meminfo() (mt, ma, st, sf int64) {
	b, _ := os.ReadFile(filepath.Join(w.Env.Proc, "meminfo"))
	for l := range strings.SplitSeq(string(b), "\n") {
		f := strings.Fields(l)
		if len(f) < 2 {
			continue
		}
		v := num(f[1], 0)
		switch f[0] {
		case "MemTotal:":
			mt = v
		case "MemAvailable:":
			ma = v
		case "SwapTotal:":
			st = v
		case "SwapFree:":
			return mt, ma, st, v
		}
	}
	return
}

// psi: memory pressure "some" avg60 as a whole percentage, "" when the kernel has no PSI.
func (w Watch) psi() string {
	f := strings.Fields(readFirst(filepath.Join(w.Env.Proc, "pressure", "memory")))
	if len(f) < 3 {
		return ""
	}
	v := strings.TrimPrefix(f[2], "avg60=")
	v, _, _ = strings.Cut(v, ".")
	return v
}

// load5 is the 5-minute load average as written ("0.52").
func (w Watch) load5() string {
	f := strings.Fields(readFirst(filepath.Join(w.Env.Proc, "loadavg")))
	if len(f) < 2 {
		return ""
	}
	return f[1]
}

// hostname: the kernel's host name.
func (w Watch) hostname() string {
	return readFirst(filepath.Join(w.Env.Proc, "sys", "kernel", "hostname"))
}

// memstat is anon + shmem of a cgroup's memory.stat (page cache is not the app's), 0 when the
// file cannot be read. shmem comes after file in the kernel's order: the read stops there.
func memstat(dir string) int64 {
	f, err := os.Open(filepath.Join(dir, "memory.stat"))
	if err != nil {
		return 0
	}
	defer f.Close()
	var mem int64
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, _ := strings.Cut(sc.Text(), " ")
		switch k {
		case "anon":
			mem += num(v, 0)
		case "shmem":
			return mem + num(v, 0)
		}
	}
	return mem
}

// evcount: a counter of a flat-keyed file (memory.events), 0 when absent.
func evcount(file, key string) int64 {
	n, _ := cgroup.Value(file, key)
	return n
}

// appCgroup is the cgroup directory of the app's unit.
func (w Watch) appCgroup(a string) string { return cgroup.AppDir(w.Env.Cgroup, a) }

// lockHeld: something holds the flock of path (an activation, a rollback or a backup holds the
// app's lock). A missing file is held by nothing; nothing is created. A shared try (lock.Held):
// another probe at the same moment is never taken for the holder.
func lockHeld(path string) bool { return lock.Held(path) }

// which finds a program in cmdEnv's PATH (`command -v`).
func which(name string) string {
	for _, kv := range cmdEnv {
		dirs, ok := strings.CutPrefix(kv, "PATH=")
		if !ok {
			continue
		}
		for d := range strings.SplitSeq(dirs, ":") {
			p := filepath.Join(d, name)
			if fi, err := os.Stat(p); err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0 {
				return p
			}
		}
	}
	return ""
}

// countLines: lines of b that contain sub (grep -c).
func countLines(b []byte, sub string) int {
	n := 0
	for l := range bytes.SplitSeq(b, []byte("\n")) {
		if bytes.Contains(l, []byte(sub)) {
			n++
		}
	}
	return n
}

// isExec: a regular file with an execute bit (bash -x, for root).
func isExec(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0
}
