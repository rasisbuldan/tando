package metrics

import (
	"bufio"
	"bytes"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/decimal"
)

// host.x: the host's extended per-minute line, like a cloud console's VM page (docs/MONITORING.md,
// "Host, per minute"). One wide line a minute, written beside host.tsv (which stays as it was):
// the writer turns counters into per-minute values (keeping the previous raw counters in .x.state),
// "-" is a value not known (the first sample, a counter that went back, a reboot, a source the
// kernel does not have). Columns are only ever added at the end; xCols names them for `read`.
//
// The name holds a dot: no app can be called "host.x" (app names are a-z, 0-9 and -), and no
// app's <app>.tsv or <app>.disk can be called that either.

// col is one column of an x file: its name in JSON, how `read` merges a bucket's minutes
// (a: average, s: sum, m: maximum) and the divisor a reader shows it with (10: per mille as a %
// with one decimal; 100: x100 as a % with two).
type col struct {
	name  string
	agg   byte
	scale int
}

// hostXCols are host.x's columns after the time, in file order.
var hostXCols = []col{
	{"cpu_user_pct", 'a', 10}, {"cpu_system_pct", 'a', 10}, {"cpu_iowait_pct", 'a', 10}, {"cpu_steal_pct", 'a', 10},
	{"mem_available_bytes", 'a', 1}, {"mem_cached_bytes", 'a', 1}, {"swap_used_bytes", 'a', 1}, {"swap_total_bytes", 'a', 1},
	{"swap_in_pages", 's', 1}, {"swap_out_pages", 's', 1},
	{"psi_cpu_pct", 'a', 100}, {"psi_memory_pct", 'a', 100}, {"psi_io_pct", 'a', 100},
	{"disk_reads", 's', 1}, {"disk_writes", 's', 1}, {"disk_read_bytes", 's', 1}, {"disk_write_bytes", 's', 1},
	{"disk_latency_us", 'a', 1}, {"disk_util_pct", 'a', 10},
	{"net_in_bytes", 's', 1}, {"net_out_bytes", 's', 1}, {"net_errors", 's', 1}, {"net_drops", 's', 1},
	{"tcp_established", 'a', 1}, {"tcp_retransmits", 's', 1}, {"oom_kills", 's', 1},
	{"inodes_pct", 'm', 10}, {"uptime_s", 'm', 1},
}

// hostXFile and selfFile are the x files; xState keeps their raw counters between samples.
const (
	hostXFile = "host.x"
	selfFile  = "tandod.x"
	xState    = ".x.state"
)

// raw is a sample's counters, by name ("-" or absent: not known).
type raw map[string]int64

// sampleHostX appends host.x's line and tandod.x's, from the counters of the last sample (prev)
// to those of this one, and returns this one's to keep.
func (m Metrics) sampleHostX(now int64) error {
	prev := loadRaw(filepath.Join(m.Dir, xState))
	cur := raw{"t": now}
	m.readHostRaw(cur)
	m.readSelfRaw(cur)
	d := deltas{prev: prev, cur: cur}
	if pu, ok := prev["uptime"]; ok {
		if cu, ok := cur["uptime"]; !ok || cu < pu {
			d.reset = true // a reboot: every counter began again
		}
	}
	if pt, ok := prev["t"]; !ok || now-pt <= 0 || now-pt > 600 {
		d.reset = true // nothing to compare with, or too long ago for a per-minute value
	} else {
		d.dt = now - pt
	}
	if err := m.appendX(hostXFile, "hx", now, prev, cur, d.hostLine(cur)); err != nil {
		return err
	}
	if _, ok := cur["s_usec"]; ok { // (no tandod on this host: no line)
		if err := m.appendX(selfFile, "sx", now, prev, cur, d.selfLine(cur)); err != nil {
			return err
		}
	}
	return atomicfile.Write(filepath.Join(m.Dir, xState), cur.format(), atomicfile.Mode(fileMode))
}

// appendX appends a line to an x file, rotating it as appendLine does; its start time and line
// count are kept in .x.state as <key>_start and <key>_lines.
func (m Metrics) appendX(name, key string, now int64, prev, cur raw, line string) error {
	e, err := m.appendFile(filepath.Join(m.Dir, name), now, entry{start: prev[key+"_start"], lines: prev[key+"_lines"]}, decimal.Itoa(now)+"\t"+line)
	if err != nil {
		return err
	}
	cur[key+"_start"], cur[key+"_lines"] = e.start, e.lines
	return nil
}

// deltas turns two samples' counters into per-minute values.
type deltas struct {
	prev, cur raw
	dt        int64 // seconds between them (0 with reset)
	reset     bool
}

// rate is key's increase per minute, or "-" (not known, gone back, or no previous sample).
func (d deltas) rate(k string) string {
	n, ok := d.diff(k)
	if !ok {
		return "-"
	}
	return decimal.Itoa(n * 60 / d.dt)
}

func (d deltas) diff(k string) (int64, bool) {
	if d.reset {
		return 0, false
	}
	p, ok1 := d.prev[k]
	c, ok2 := d.cur[k]
	if !ok1 || !ok2 || c < p {
		return 0, false
	}
	return c - p, true
}

// share is the per mille of key's increase in the increase of total ("-" not known).
func (d deltas) share(total string, keys ...string) string {
	t, ok := d.diff(total)
	if !ok || t <= 0 {
		return "-"
	}
	var n int64
	for _, k := range keys {
		x, ok := d.diff(k)
		if !ok {
			return "-"
		}
		n += x
	}
	return decimal.Itoa(n * 1000 / t)
}

// gauge is key's value now, or "-".
func (r raw) gauge(k string) string {
	if v, ok := r[k]; ok {
		return decimal.Itoa(v)
	}
	return "-"
}

func (d deltas) hostLine(c raw) string {
	v := []string{
		d.share("cpu_total", "cpu_user", "cpu_nice"), d.share("cpu_total", "cpu_system", "cpu_irq", "cpu_softirq"),
		d.share("cpu_total", "cpu_iowait"), d.share("cpu_total", "cpu_steal"),
		c.gauge("mem_avail"), c.gauge("mem_cached"), "-", c.gauge("swap_total"),
		d.rate("pswpin"), d.rate("pswpout"),
		c.gauge("psi_cpu"), c.gauge("psi_memory"), c.gauge("psi_io"),
		d.rate("d_reads"), d.rate("d_writes"), "-", "-", "-", "-",
		d.rate("n_rxb"), d.rate("n_txb"), "-", "-",
		c.gauge("tcp_estab"), d.rate("tcp_retrans"), d.rate("oom_kill"),
		c.gauge("inodes_pm"), c.gauge("uptime"),
	}
	if t, ok := c["swap_total"]; ok {
		if f, ok := c["swap_free"]; ok {
			v[6] = decimal.Itoa(t - f)
		}
	}
	if r, ok := d.diff("d_rsect"); ok {
		v[15] = decimal.Itoa(r * 512 * 60 / d.dt)
	}
	if w, ok := d.diff("d_wsect"); ok {
		v[16] = decimal.Itoa(w * 512 * 60 / d.dt)
	}
	// latency: the time the completed requests took, per request; util: the share of the time
	// the device had requests in flight (overstated on multi-queue devices: NVMe, virtio, dm)
	ops, ok1 := d.diff("d_reads")
	wops, ok2 := d.diff("d_writes")
	rms, ok3 := d.diff("d_rms")
	wms, ok4 := d.diff("d_wms")
	if ok1 && ok2 && ok3 && ok4 && ops+wops > 0 {
		v[17] = decimal.Itoa((rms + wms) * 1000 / (ops + wops))
	}
	if io, ok := d.diff("d_ioms"); ok {
		v[18] = decimal.Itoa(min(io*1000/(d.dt*1000), 1000))
	}
	sum := func(a, b string) string {
		x, ok1 := d.diff(a)
		y, ok2 := d.diff(b)
		if !ok1 || !ok2 {
			return "-"
		}
		return decimal.Itoa((x + y) * 60 / d.dt)
	}
	v[21], v[22] = sum("n_rxerr", "n_txerr"), sum("n_rxdrop", "n_txdrop")
	return strings.Join(v, "\t")
}

// readHostRaw reads /proc (and statfs, /sys for the disk) into r: every source that cannot be
// read is left out, and its columns are "-".
func (m Metrics) readHostRaw(r raw) {
	p := m.Env.Proc
	if b, err := os.ReadFile(filepath.Join(p, "stat")); err == nil {
		line, _, _ := strings.Cut(string(b), "\n")
		f := strings.Fields(line)
		if len(f) >= 9 && f[0] == "cpu" {
			var total int64
			for i, k := range []string{"cpu_user", "cpu_nice", "cpu_system", "cpu_idle", "cpu_iowait", "cpu_irq", "cpu_softirq", "cpu_steal"} {
				n, err := strconv.ParseInt(f[i+1], 10, 64)
				if err != nil {
					total = -1
					break
				}
				r[k] = n
				total += n
			}
			if total > 0 {
				r["cpu_total"] = total
			}
		}
	}
	keyed(filepath.Join(p, "meminfo"), func(k, v string) {
		if n, ok := meminfoKeys[k]; ok {
			if x, err := strconv.ParseInt(v, 10, 64); err == nil {
				r[n] = x * 1024
			}
		}
	})
	keyed(filepath.Join(p, "vmstat"), func(k, v string) {
		if k == "pswpin" || k == "pswpout" || k == "oom_kill" {
			if x, err := strconv.ParseInt(v, 10, 64); err == nil {
				r[k] = x
			}
		}
	})
	for _, k := range []string{"cpu", "memory", "io"} {
		if v, ok := psiSome(filepath.Join(p, "pressure", k)); ok {
			r["psi_"+k] = v
		}
	}
	if b, err := os.ReadFile(filepath.Join(p, "uptime")); err == nil {
		s, _, _ := strings.Cut(strings.TrimSpace(string(b)), ".")
		if n, err := strconv.ParseInt(s, 10, 64); err == nil {
			r["uptime"] = n
		}
	}
	m.readDiskRaw(r)
	readNetRaw(p, r)
	if files, free, err := statInodes(m.Dir); err == nil && files > 0 {
		r["inodes_pm"] = int64((files - free) * 1000 / files)
	}
}

// meminfoKeys: what readHostRaw takes of /proc/meminfo (kB).
var meminfoKeys = map[string]string{"MemAvailable:": "mem_avail", "Cached:": "mem_cached", "SwapTotal:": "swap_total", "SwapFree:": "swap_free"}

// keyed calls fn with the first two words of every line of a "key value" file.
func keyed(path string, fn func(k, v string)) {
	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		w := strings.Fields(sc.Text())
		if len(w) >= 2 {
			fn(w[0], w[1])
		}
	}
}

// psiSome: "some avg10=0.00 avg60=1.25 ..." -> 125 (avg60 x 100); false when the file is absent
// (a kernel without PSI, or psi=0)
func psiSome(path string) (int64, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	for _, line := range strings.Split(string(b), "\n") {
		w := strings.Fields(line)
		if len(w) < 3 || w[0] != "some" {
			continue
		}
		for _, kv := range w[1:] {
			if v, ok := strings.CutPrefix(kv, "avg60="); ok {
				i, f, _ := strings.Cut(v, ".")
				f = (f + "00")[:2]
				n, err1 := strconv.ParseInt(i, 10, 64)
				x, err2 := strconv.ParseInt(f, 10, 64)
				return n*100 + x, err1 == nil && err2 == nil
			}
		}
	}
	return 0, false
}

// statInodes is inodesOf (a test replaces it).
var statInodes = inodesOf

func inodesOf(path string) (files, free uint64, err error) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return 0, 0, err
	}
	return uint64(st.Files), uint64(st.Ffree), nil
}

// devOf is devOfStat (a test replaces it).
var devOf = devOfStat

// devOfStat is the device number of the file system holding path, as major and minor. btrfs,
// ZFS and overlay have major 0: no block device to read.
func devOfStat(path string) (major, minor uint64, ok bool) {
	var st syscall.Stat_t
	if err := syscall.Stat(path, &st); err != nil {
		return 0, 0, false
	}
	dev := uint64(st.Dev) //nolint:unconvert // (int32 on darwin)
	major = (dev>>8)&0xfff | (dev>>32)&^0xfff
	minor = dev&0xff | (dev>>12)&^0xff
	return major, minor, major != 0
}

// mainDisk is the block device that holds Dir (/var/lib/tando), by its name in /proc/diskstats:
// /sys/dev/block/M:m names it; a partition counts as its disk (sda1 -> sda), a device mapper
// volume (LVM, crypt) as itself (dm-0: the kernel keeps its stats). "" when there is none:
// btrfs, ZFS, a loop or zram device.
func (m Metrics) mainDisk() string {
	maj, mnr, ok := devOf(m.Dir)
	if !ok {
		return ""
	}
	link := filepath.Join(m.sys(), "dev", "block", decimal.Itoa(int64(maj))+":"+decimal.Itoa(int64(mnr)))
	dir, err := filepath.EvalSymlinks(link)
	if err != nil {
		return ""
	}
	if _, err := os.Stat(filepath.Join(dir, "partition")); err == nil {
		dir = filepath.Dir(dir)
	}
	name := filepath.Base(dir)
	for _, skip := range []string{"loop", "zram", "sr", "ram"} {
		if strings.HasPrefix(name, skip) {
			return ""
		}
	}
	return name
}

func (m Metrics) sys() string {
	if m.Sys != "" {
		return m.Sys
	}
	return "/sys"
}

// readDiskRaw: the main disk's line of /proc/diskstats, fields 1-11 (later kernels add discard
// and flush fields, which are not read).
func (m Metrics) readDiskRaw(r raw) {
	dev := m.mainDisk()
	if dev == "" {
		return
	}
	b, err := os.ReadFile(filepath.Join(m.Env.Proc, "diskstats"))
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) < 14 || f[2] != dev {
			continue
		}
		for i, k := range diskFields {
			if n, err := strconv.ParseInt(f[i], 10, 64); err == nil {
				r[k] = n
			}
		}
		return
	}
}

// diskFields: the /proc/diskstats words read (the third is the name; then reads completed,
// merged, sectors read, ms reading, writes completed, merged, sectors written, ms writing, in
// flight, ms doing IO).
var diskFields = map[int]string{3: "d_reads", 5: "d_rsect", 6: "d_rms", 7: "d_writes", 9: "d_wsect", 10: "d_wms", 12: "d_ioms"}

// readNetRaw: bytes, errors and drops of the default route's interfaces (/proc/net/route; a
// container bridge or veth would count the same bytes twice), and TCP from /proc/net/snmp.
func readNetRaw(p string, r raw) {
	ifs := map[string]bool{}
	if b, err := os.ReadFile(filepath.Join(p, "net", "route")); err == nil {
		for _, line := range strings.Split(string(b), "\n")[1:] {
			f := strings.Fields(line)
			if len(f) > 2 && f[1] == "00000000" {
				ifs[f[0]] = true
			}
		}
	}
	if b, err := os.ReadFile(filepath.Join(p, "net", "dev")); err == nil && len(ifs) > 0 {
		var sums [6]int64
		found := false
		for _, line := range strings.Split(string(b), "\n") {
			name, rest, ok := strings.Cut(line, ":")
			if !ok || !ifs[strings.TrimSpace(name)] {
				continue
			}
			f := strings.Fields(rest)
			if len(f) < 12 {
				continue
			}
			for i, idx := range []int{0, 2, 3, 8, 10, 11} {
				n, _ := strconv.ParseInt(f[idx], 10, 64)
				sums[i] += n
			}
			found = true
		}
		if found {
			for i, k := range []string{"n_rxb", "n_rxerr", "n_rxdrop", "n_txb", "n_txerr", "n_txdrop"} {
				r[k] = sums[i]
			}
		}
	}
	if b, err := os.ReadFile(filepath.Join(p, "net", "snmp")); err == nil {
		var head []string
		for _, line := range strings.Split(string(b), "\n") {
			if !strings.HasPrefix(line, "Tcp:") {
				continue
			}
			f := strings.Fields(line)[1:]
			if head == nil {
				head = f
				continue
			}
			for i, k := range head {
				if i >= len(f) {
					break
				}
				n, err := strconv.ParseInt(f[i], 10, 64)
				if err != nil {
					continue
				}
				switch k {
				case "CurrEstab":
					r["tcp_estab"] = n
				case "RetransSegs":
					r["tcp_retrans"] = n
				}
			}
			break
		}
	}
}

// loadRaw reads .x.state ("key value" lines); a missing or damaged file is empty.
func loadRaw(path string) raw {
	r := raw{}
	b, err := os.ReadFile(path)
	if err != nil {
		return r // (missing: the first sample; unreadable: start over)
	}
	for _, line := range strings.Split(string(b), "\n") {
		k, v, ok := strings.Cut(line, " ")
		if n, err := strconv.ParseInt(v, 10, 64); ok && err == nil {
			r[k] = n
		}
	}
	return r
}

func (r raw) format() []byte {
	keys := make([]string, 0, len(r))
	for k := range r {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	var b bytes.Buffer
	for _, k := range keys {
		b.WriteString(k + " " + decimal.Itoa(r[k]) + "\n")
	}
	return b.Bytes()
}
