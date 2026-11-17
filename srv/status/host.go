package status

import (
	"bytes"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"

	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
)

// HostFacts are the numbers of the host row.
type HostFacts struct {
	Name                    string // /proc/sys/kernel/hostname
	CPUs                    int    // /sys/devices/system/cpu/online
	Load                    string // the first field of /proc/loadavg, as written
	MemTotalKB, MemAvailKB  int64  // /proc/meminfo
	DiskTotalKB, DiskUsedKB uint64 // df -Pk /
	Uptime                  int64  // whole seconds of /proc/uptime
}

// HostRow is `row host "$hn" "$cpus" "$la" $((mt * 1024)) $(((mt - ma) * 1024)) $((dt * 1024))
// $((du * 1024)) "$UPT"`.
func HostRow(h HostFacts) []string {
	return []string{"host", h.Name, decimal.Itoa(int64(h.CPUs)), h.Load, decimal.Itoa(h.MemTotalKB * 1024),
		decimal.Itoa((h.MemTotalKB - h.MemAvailKB) * 1024), utoa(h.DiskTotalKB * 1024), utoa(h.DiskUsedKB * 1024), decimal.Itoa(h.Uptime)}
}

// uptime is `read -r UPT _ < /proc/uptime; UPT=${UPT%.*}`.
func (c *Collector) uptime() int64 {
	b, _ := readBounded(filepath.Join(c.Env.Proc, "uptime"), 4096, false)
	f := firstWord(b)
	f, _, _ = strings.Cut(f, ".")
	return atoi(f)
}

// host reads the host row's facts. No process is started (the shell's one fork, df, is statfs).
func (c *Collector) host(upt int64) HostFacts {
	h := HostFacts{Uptime: upt}
	b, _ := readBounded(filepath.Join(c.Env.Proc, "sys", "kernel", "hostname"), 4096, false)
	h.Name = firstLine(b)
	b, _ = readBounded(filepath.Join(c.Env.Proc, "loadavg"), 4096, false)
	h.Load = firstWord(b)
	b, _ = readBounded(filepath.Join(c.Env.Proc, "meminfo"), 64<<10, false)
	for _, l := range bashread.Lines(b) {
		f := words(l)
		if len(f) < 2 {
			continue
		}
		switch f[0] {
		case "MemTotal:":
			h.MemTotalKB = atoi(f[1])
		case "MemAvailable:":
			h.MemAvailKB = atoi(f[1])
		}
	}
	b, _ = readBounded(filepath.Join(c.Sys, "devices", "system", "cpu", "online"), 4096, false)
	h.CPUs = cpusOnline(firstLine(b))
	statfs := c.Statfs
	if statfs == nil {
		statfs = dfKB
	}
	h.DiskTotalKB, h.DiskUsedKB, _ = statfs("/")
	return h
}

// cpusOnline counts "0-3,5" as the shell did: for each part lo-hi, hi - lo + 1 (a single "5"
// is 5-5).
func cpusOnline(s string) int {
	n := 0
	if s == "" {
		return 0
	}
	for _, p := range strings.Split(s, ",") {
		lo, hi, ok := strings.Cut(p, "-")
		if !ok {
			hi = lo
		}
		n += int(atoi(hi) - atoi(lo) + 1)
	}
	return n
}

// memAnonShmem is the memory status shows for an app: anon + shmem of memory.stat (memory.current
// also counts reclaimable page cache). 0 when the file cannot be read (the unit is not running).
func memAnonShmem(statFile string) int64 {
	b, err := readBounded(statFile, 64<<10, false)
	if err != nil {
		return 0
	}
	var n int64
	for _, l := range bashread.Lines(b) {
		k, v, ok := strings.Cut(l, " ")
		if ok && (k == "anon" || k == "shmem") {
			n += atoi(strings.TrimSpace(v))
		}
	}
	return n
}

func firstLine(b []byte) string {
	if i := bytes.IndexByte(b, '\n'); i >= 0 {
		b = b[:i]
	}
	return string(b)
}

// firstWord is `read -r w _`: the first word of the first line.
func firstWord(b []byte) string {
	if f := words(firstLine(b)); len(f) > 0 {
		return f[0]
	}
	return ""
}

// atoi reads a decimal number with an optional sign; anything else is 0 (bash's ${x:-0} of a
// value that was never anything but a number).
func atoi(s string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0
	}
	return n
}
func utoa(n uint64) string { return strconv.FormatUint(n, 10) }

// lookupUID resolves a user name (or a number) as install -o does.
func lookupUID(name string) (int, bool) {
	if decimal.IsDigits(name) {
		n, err := strconv.Atoi(name)
		return n, err == nil
	}
	u, err := user.Lookup(name)
	if err != nil {
		return 0, false
	}
	n, err := strconv.Atoi(u.Uid)
	return n, err == nil
}

// exists is [[ -e p ]].
