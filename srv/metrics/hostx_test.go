package metrics

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"tando/srv/internal/decimal"
)

// fakeProc writes a whole /proc and /sys of a small VM: the counters move by step between two
// samples (a step of 0 is the first sample's values).
func (h *host) fakeProc(step int64, uptime int64) {
	n := func(base, per int64) string { return decimal.Itoa(base + per*step) }
	// cpu: user nice system idle iowait irq softirq steal; per step 6000 jiffies: user 600 + nice 0,
	// system 300 + irq 0 + softirq 0, idle 4500, iowait 300, steal 300
	h.write("proc/stat", "cpu  "+n(1000, 600)+" 0 "+n(500, 300)+" "+n(9000, 4500)+" "+n(100, 300)+" 0 0 "+n(50, 300)+" 0 0\ncpu0 1 2 3\n")
	h.write("proc/meminfo", "MemTotal:        2000000 kB\nMemFree:          100000 kB\nMemAvailable:     500000 kB\nBuffers: 1 kB\nCached:           300000 kB\nSwapCached: 7 kB\nSwapTotal:       1000000 kB\nSwapFree:         750000 kB\n")
	h.write("proc/vmstat", "nr_free_pages 1\npswpin "+n(10, 40)+"\npswpout "+n(20, 8)+"\noom_kill "+n(0, 1)+"\n")
	h.write("proc/pressure/cpu", "some avg10=0.00 avg60=1.5 avg300=0.00 total=1\nfull avg10=0.00 avg60=9.99 avg300=0.00 total=1\n")
	h.write("proc/pressure/memory", "some avg10=0.00 avg60=12.34 avg300=0.00 total=1\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=1\n")
	h.write("proc/pressure/io", "some avg10=0.00 avg60=0.07 avg300=0.00 total=1\n")
	h.write("proc/uptime", decimal.Itoa(uptime)+".25 100.00\n")
	// diskstats: the partition's line and the disk's; 120 reads + 60 writes a minute, 2 MB read,
	// 1 MB written, 900 ms reading + 900 ms writing, 30 s busy. Kernel 5.5 has 20 fields.
	disk := " 8 0 vda " + n(1000, 120) + " 0 " + n(2000, 4096) + " " + n(100, 900) + " " + n(500, 60) + " 0 " + n(4000, 2048) + " " + n(300, 900) + " 0 " + n(50, 30000) + " 9 0 0 0 0 0 0\n"
	h.write("proc/diskstats", "   7       0 loop0 1 2 3 4 5 6 7 8 9 10 11\n 8 1 vda1 5 0 5 5 5 0 5 5 0 5 5\n"+disk)
	// eth0 is the default route; docker0 and veth would count the same bytes twice; lo is not
	h.write("proc/net/route", "Iface\tDestination\tGateway \nbr-x\t000011AC\t00000000\neth0\t00000000\t0102000A\n")
	h.write("proc/net/dev", "Inter-|   Receive |  Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs drop fifo colls carrier compressed\n"+
		"    lo: 99999 9 0 0 0 0 0 0 99999 9 0 0 0 0 0 0\n"+
		"  eth0: "+n(5000, 600000)+" 10 "+n(1, 2)+" "+n(0, 3)+" 0 0 0 0 "+n(7000, 120000)+" 20 "+n(0, 1)+" "+n(0, 0)+" 0 0 0 0\n"+
		"docker0: "+n(5000, 77777)+" 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0\n")
	h.write("proc/net/snmp", "Ip: Forwarding DefaultTTL\nIp: 1 64\nTcp: RtoAlgorithm RtoMin RtoMax MaxConn ActiveOpens PassiveOpens AttemptFails EstabResets CurrEstab InSegs OutSegs RetransSegs InErrs OutRsts\nTcp: 1 200 120000 -1 5 6 0 0 "+n(14, 1)+" 100 200 "+n(3, 5)+" 0 0\n")
	// /sys: 8:1 is vda1, a partition of vda
	dev := filepath.Join(filepath.Dir(h.m.Env.Root), "sys/devices/pci0/virtio1/block/vda/vda1")
	h.write("sys/devices/pci0/virtio1/block/vda/vda1/partition", "1\n")
	os.MkdirAll(filepath.Join(h.m.Sys, "dev", "block"), 0o755)
	os.Symlink(dev, filepath.Join(h.m.Sys, "dev", "block", "8:1"))
}

func newXHost(t testing.TB) *host {
	h := newHost(t)
	h.m.Sys = filepath.Join(filepath.Dir(h.m.Env.Root), "sys")
	devOf = func(string) (uint64, uint64, bool) { return 8, 1, true }
	statInodes = func(string) (uint64, uint64, error) { return 1000, 875, nil }
	t.Cleanup(func() { devOf, statInodes = devOfStat, inodesOf })
	return h
}

func lastLine(s string) []string {
	l := strings.Split(strings.TrimSuffix(s, "\n"), "\n")
	return strings.Split(l[len(l)-1], "\t")
}

// the host's extended line: the first sample has gauges only, the next one per-minute values
func TestHostX(t *testing.T) {
	h := newXHost(t)
	h.fakeProc(0, 1000)
	if err := h.m.Sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	first := lastLine(h.read("host.x"))
	if len(first) != len(hostXCols)+1 {
		t.Fatalf("host.x has %d columns, want %d: %q", len(first), len(hostXCols)+1, first)
	}
	want0 := map[string]string{"cpu_user_pct": "-", "disk_reads": "-", "net_in_bytes": "-", "oom_kills": "-",
		"mem_available_bytes": "512000000", "swap_used_bytes": "256000000", "psi_memory_pct": "1234", "tcp_established": "14",
		"inodes_pct": "125", "uptime_s": "1000"}
	checkCols(t, "first", first, want0)

	h.now += 60
	h.fakeProc(1, 1060)
	if err := h.m.Sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := lastLine(h.read("host.x"))
	if got[0] != decimal.Itoa(h.now) {
		t.Errorf("time %s", got[0])
	}
	checkCols(t, "second", got, map[string]string{
		"cpu_user_pct": "100", "cpu_system_pct": "50", "cpu_iowait_pct": "50", "cpu_steal_pct": "50",
		"mem_available_bytes": "512000000", "mem_cached_bytes": "307200000", "swap_used_bytes": "256000000", "swap_total_bytes": "1024000000",
		"swap_in_pages": "40", "swap_out_pages": "8", "psi_cpu_pct": "150", "psi_memory_pct": "1234", "psi_io_pct": "7",
		"disk_reads": "120", "disk_writes": "60", "disk_read_bytes": "2097152", "disk_write_bytes": "1048576",
		"disk_latency_us": "10000", "disk_util_pct": "500",
		"net_in_bytes": "600000", "net_out_bytes": "120000", "net_errors": "3", "net_drops": "3",
		"tcp_established": "15", "tcp_retransmits": "5", "oom_kills": "1", "inodes_pct": "125", "uptime_s": "1060",
	})

	// a reboot (uptime went back): every per-minute value is "-" again, gauges stay
	h.now += 60
	h.fakeProc(2, 30)
	h.m.Sample(context.Background())
	checkCols(t, "after a reboot", lastLine(h.read("host.x")), map[string]string{"cpu_user_pct": "-", "disk_reads": "-", "oom_kills": "-", "uptime_s": "30", "tcp_established": "16"})

	// sources the kernel does not have (no PSI; btrfs: no block device): "-"
	h.now += 60
	h.fakeProc(3, 90)
	os.RemoveAll(filepath.Join(h.m.Env.Proc, "pressure"))
	devOf = func(string) (uint64, uint64, bool) { return 0, 0, false }
	h.m.Sample(context.Background())
	checkCols(t, "no psi, no block device", lastLine(h.read("host.x")), map[string]string{"psi_cpu_pct": "-", "psi_memory_pct": "-", "disk_reads": "-", "disk_util_pct": "-", "cpu_user_pct": "100"})
}

func checkCols(t *testing.T, what string, line []string, want map[string]string) {
	t.Helper()
	for i, c := range hostXCols {
		if w, ok := want[c.name]; ok && (i+1 >= len(line) || line[i+1] != w) {
			g := "(none)"
			if i+1 < len(line) {
				g = line[i+1]
			}
			t.Errorf("%s: %s = %s, want %s", what, c.name, g, w)
		}
	}
}

// the main disk: a partition counts as its disk, a device mapper volume as itself, a loop device
// or an unknown number as none
func TestMainDisk(t *testing.T) {
	h := newXHost(t)
	h.fakeProc(0, 1)
	if got := h.m.mainDisk(); got != "vda" {
		t.Errorf("partition: %q", got)
	}
	h.write("sys/devices/virtual/block/dm-0/dm/name", "vg-root\n")
	os.Symlink(filepath.Join(h.m.Sys, "devices/virtual/block/dm-0"), filepath.Join(h.m.Sys, "dev/block/253:0"))
	devOf = func(string) (uint64, uint64, bool) { return 253, 0, true }
	if got := h.m.mainDisk(); got != "dm-0" {
		t.Errorf("lvm: %q", got)
	}
	h.write("sys/devices/virtual/block/loop3/x", "")
	os.Symlink(filepath.Join(h.m.Sys, "devices/virtual/block/loop3"), filepath.Join(h.m.Sys, "dev/block/7:3"))
	devOf = func(string) (uint64, uint64, bool) { return 7, 3, true }
	if got := h.m.mainDisk(); got != "" {
		t.Errorf("loop: %q", got)
	}
	devOf = func(string) (uint64, uint64, bool) { return 9, 9, true }
	if got := h.m.mainDisk(); got != "" {
		t.Errorf("unknown device: %q", got)
	}
}

// an app's slice: throttling only with a CPU limit, OOM kills, tasks and the limit, memory pressure
func TestSliceColumns(t *testing.T) {
	h := newXHost(t)
	svc := `tando.slice/tando-web.slice/tando-web.service`
	sl := "cgroup/tando.slice/tando-web.slice/"
	h.app("web", svc, 1000, 1)
	h.app("old", "system.slice/tando-old.service", 1000, 1)
	h.systemd = strings.Repeat("ActiveState=active\nNRestarts=0\n\n", 2)
	slice := func(periods, throttled, ooms int64) {
		h.write(sl+"cpu.stat", "usage_usec 9\nnr_periods "+decimal.Itoa(periods)+"\nnr_throttled "+decimal.Itoa(throttled)+"\nthrottled_usec 5\n")
		h.write(sl+"memory.events", "low 0\nhigh 0\nmax 4\noom 2\noom_kill "+decimal.Itoa(ooms)+"\n")
		h.write(sl+"pids.current", "17\n")
		h.write(sl+"pids.max", "512\n")
		h.write(sl+"memory.pressure", "some avg10=1.00 avg60=2.50 avg300=0.00 total=1\nfull avg10=0 avg60=0 avg300=0 total=0\n")
	}
	slice(100, 10, 1)
	h.m.Sample(context.Background())
	if got := lastLine(h.read("web.tsv"))[5:]; strings.Join(got, " ") != "- - 17 512 250" {
		t.Errorf("first sample: %q", got)
	}
	h.now += 60
	slice(700, 160, 3)
	h.m.Sample(context.Background())
	if got := lastLine(h.read("web.tsv"))[5:]; strings.Join(got, " ") != "250 2 17 512 250" {
		t.Errorf("a minute later: %q (want 150 of 600 periods throttled, 2 OOM kills)", got)
	}
	// no CPU limit: no period runs, no throttling to show; no task limit: "max"
	h.now += 60
	slice(0, 0, 3)
	h.write(sl+"pids.max", "max\n")
	h.m.Sample(context.Background())
	h.now += 60
	h.m.Sample(context.Background())
	if got := lastLine(h.read("web.tsv"))[5:]; strings.Join(got, " ") != "- 0 17 - 250" {
		t.Errorf("without limits: %q", got)
	}
	// an app still under system.slice has no slice of its own
	if got := lastLine(h.read("old.tsv"))[5:]; strings.Join(got, " ") != "- - - - -" {
		t.Errorf("old: %q", got)
	}
}

// what the monitoring costs: tandod's cgroup, and its own counters only while it is the same tandod
func TestSelfX(t *testing.T) {
	h := newXHost(t)
	cg := "cgroup/system.slice/tandod.service/"
	self := func(usec, majflt, refault int64) {
		h.write(cg+"cpu.stat", "usage_usec "+decimal.Itoa(usec)+"\nuser_usec 1\n")
		h.write(cg+"memory.stat", "anon 9000000\nfile 4000000\npgmajfault "+decimal.Itoa(majflt)+"\nworkingset_refault_anon 77\nworkingset_refault_file "+decimal.Itoa(refault)+"\n")
	}
	h.m.Sample(context.Background())
	if _, err := os.Stat(filepath.Join(h.m.Dir, "tandod.x")); !os.IsNotExist(err) {
		t.Fatal("tandod.x written on a host without tandod")
	}
	pid, children, requests := int64(4242), int64(10), int64(100)
	h.m.Self = func() (int64, int64, int64) { return pid, children, requests }
	self(1_000_000, 5, 50)
	h.m.Sample(context.Background())
	if got := strings.Join(lastLine(h.read("tandod.x"))[1:], " "); got != "- 9000000 4000000 - - - -" {
		t.Errorf("first: %q", got)
	}
	h.now += 60
	self(1_450_000, 7, 1050)
	children, requests = 13, 112
	h.m.Sample(context.Background())
	if got := strings.Join(lastLine(h.read("tandod.x"))[1:], " "); got != "450 9000000 4000000 2 1000 3 12" {
		t.Errorf("a minute later: %q (want 450 ms cpu, 2 major faults, 1000 refaults, 3 programs, 12 requests)", got)
	}
	// another tandod (restarted): its counters began again
	h.now += 60
	pid, children, requests = 4300, 1, 1
	self(1_500_000, 7, 1050)
	h.m.Sample(context.Background())
	if got := strings.Join(lastLine(h.read("tandod.x"))[1:], " "); got != "50 9000000 4000000 0 0 - -" {
		t.Errorf("after a restart: %q", got)
	}
	// a sample that is not tandod's (the timer's fallback): its counters are not known
	h.now += 60
	h.m.Self = nil
	h.m.Sample(context.Background())
	if got := lastLine(h.read("tandod.x")); got[6] != "-" || got[7] != "-" {
		t.Errorf("one-shot: %q", got)
	}
}

// read host.x / tandod.x: the column names, then per bucket the average, sum or maximum of
// each column, "-" minutes left out
func TestReadX(t *testing.T) {
	h := newXHost(t)
	h.now = 1_800_000_300
	h.write("lib/metrics/tandod.x", ""+
		"1800000060\t100\t10\t1\t2\t5\t1\t-\n"+
		"1800000090\t300\t30\t1\t-\t5\t2\t4\n"+
		"1800000120\t-\t-\t-\t-\t-\t-\t-\textra\n"+
		"1800000180\t7\t1")
	want := "mx\t60\t1800000300\n" +
		"xc\tcpu_ms:a:1\tanon_bytes:a:1\tfile_bytes:a:1\tmajor_faults:s:1\trefaults:s:1\tchildren:s:1\trequests:s:1\n" +
		"x\t1800000060\t200\t20\t1\t2\t10\t3\t4\n" +
		"x\t1800000120\t-\t-\t-\t-\t-\t-\t-\n"
	if got := h.readOut("tandod.x", "5", "60"); got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
	if _, err := ParseReadArgs([]string{"host.y"}); err == nil {
		t.Error("host.y accepted")
	}
	if a, err := ParseReadArgs([]string{"host.x", "60", "60"}); err != nil || a.Who != "host.x" {
		t.Errorf("host.x: %v", err)
	}
}

// the cost of one minute's sample with 25 apps on a fake /proc and /sys (budget: under 5 ms of
// CPU; docs/MONITORING.md): go test -run - -bench SampleMinute ./metrics. cpu-ms/op is the
// process's CPU time (user + system); ns/op is wall time, mostly the fsync of .state and
// .x.state (slow on macOS, which flushes the drive's cache).
func BenchmarkSampleMinute(b *testing.B) {
	h := newXHost(b)
	h.fakeProc(0, 1000)
	var sd strings.Builder
	for i := 0; i < 25; i++ {
		a := "app-" + decimal.Itoa(int64(i))
		esc := strings.ReplaceAll(a, "-", `\x2d`)
		h.app(a, "tando.slice/tando-"+esc+".slice/tando-"+a+".service", 1000, 1)
		sl := "cgroup/tando.slice/tando-" + esc + ".slice/"
		h.write(sl+"cpu.stat", "usage_usec 9\nnr_periods 100\nnr_throttled 1\nthrottled_usec 5\n")
		h.write(sl+"memory.events", "low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\n")
		h.write(sl+"pids.current", "17\n")
		h.write(sl+"pids.max", "512\n")
		h.write(sl+"memory.pressure", "some avg10=0.00 avg60=0.00 avg300=0.00 total=1\n")
		sd.WriteString("ActiveState=active\nNRestarts=0\n\n")
	}
	h.write("cgroup/system.slice/tandod.service/cpu.stat", "usage_usec 9\n")
	h.write("cgroup/system.slice/tandod.service/memory.stat", "anon 1\nfile 1\npgmajfault 1\nworkingset_refault_file 1\n")
	h.systemd = sd.String()
	h.m.Self = func() (int64, int64, int64) { return 1, 1, 1 }
	h.m.Sample(context.Background()) // (the disk walks: every 15 minutes, not in each minute)
	var r0, r1 syscall.Rusage
	b.ResetTimer()
	syscall.Getrusage(syscall.RUSAGE_SELF, &r0)
	for i := 0; i < b.N; i++ {
		h.now += 60
		if err := h.m.Sample(context.Background()); err != nil {
			b.Fatal(err)
		}
	}
	syscall.Getrusage(syscall.RUSAGE_SELF, &r1)
	cpu := time.Duration(r1.Utime.Nano() + r1.Stime.Nano() - r0.Utime.Nano() - r0.Stime.Nano())
	b.ReportMetric(float64(cpu.Microseconds())/1000/float64(b.N), "cpu-ms/op")
}
