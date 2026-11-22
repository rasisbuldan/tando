package metrics

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"tando/srv/internal/decimal"
	"tando/srv/internal/env"
	"tando/srv/internal/run"
)

// host is a fake machine in a temp directory: /opt/tando, /sys/fs/cgroup, /proc and the
// metrics directory, a settable clock and a fake systemctl.
type host struct {
	t        testing.TB
	m        Metrics
	now      int64
	systemd  string // systemctl's answer
	nft      string // nft -j list counters' answer
	sysErr   error
	lastArgv []string
}

func newHost(t testing.TB) *host {
	h := &host{t: t, now: 1_800_000_000}
	root := t.TempDir()
	e := env.Env{
		Root:   filepath.Join(root, "opt"),
		Lib:    filepath.Join(root, "lib"),
		Cgroup: filepath.Join(root, "cgroup"),
		Proc:   filepath.Join(root, "proc"),
		EUID:   0,
		Now:    func() time.Time { return time.Unix(h.now, 0) },
		Run: run.Func(func(_ context.Context, c run.Cmd) ([]byte, error) {
			if len(c.Argv) > 0 && c.Argv[0] == "nft" {
				return []byte(h.nft), nil
			}
			h.lastArgv = c.Argv
			return []byte(h.systemd), h.sysErr
		}),
	}
	h.m = New(e, "")
	h.m.Journal = filepath.Join(root, "journal")
	statDisk = func(string) (int64, int64, error) { return 4000, 10000, nil }
	t.Cleanup(func() { statDisk = diskOf })
	h.write("proc/loadavg", "0.52 0.40 0.31 1/123 4567\n")
	h.write("proc/meminfo", "MemTotal:        2000000 kB\nMemFree:          100000 kB\nMemAvailable:     500000 kB\n")
	return h
}

func (h *host) write(rel, content string) {
	p := filepath.Join(filepath.Dir(h.m.Env.Root), rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		h.t.Fatal(err)
	}
}

func (h *host) read(name string) string {
	b, err := os.ReadFile(filepath.Join(h.m.Dir, name))
	if err != nil {
		h.t.Fatal(err)
	}
	return string(b)
}

func (h *host) app(name, cgdir string, anon, usec int64) {
	h.write("opt/apps/"+name+"/app.conf", "port=4100\n")
	h.write("cgroup/"+cgdir+"/memory.stat", "anon "+decimal.Itoa(anon-24)+"\nfile 5\nshmem 24\n")
	h.write("cgroup/"+cgdir+"/cpu.stat", "usage_usec "+decimal.Itoa(usec)+"\nuser_usec 1\n")
}

func TestSample(t *testing.T) {
	h := newHost(t)
	h.app("web", `tando.slice/tando-web.slice/tando-web.service`, 1000, 5_000_000)
	h.app("api-2", `tando.slice/tando-api\x2d2.slice/tando-api-2.service`, 2000, 9_000_000)
	h.systemd = "ActiveState=active\nNRestarts=1\n\nActiveState=failed\nNRestarts=3\n"
	if err := os.MkdirAll(h.m.Dir, 0o755); err != nil { // as an older version left it
		t.Fatal(err)
	}
	if err := h.m.Sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(h.lastArgv, " "); got != "systemctl show -p ActiveState,NRestarts,ActiveEnterTimestampMonotonic,InactiveEnterTimestampMonotonic tando-api-2.service tando-web.service" {
		t.Errorf("systemctl argv: %s", got)
	}
	// first sample: no cpu difference yet
	check := func(name, want string) {
		t.Helper()
		if got := h.read(name); got != want {
			t.Errorf("%s:\n got %q\nwant %q", name, got, want)
		}
	}
	check("api-2.tsv", "1800000000\t2000\t0\t1\tr\t-\t-\t-\t-\t-\t-\t-\n")
	check("web.tsv", "1800000000\t1000\t0\t3\tf\t-\t-\t-\t-\t-\t-\t-\n")
	check("host.tsv", "1800000000\t52\t1536000000\t2048000000\t-\t4000\t10000\n")
	check(".state", "api-2 9000000 1800000000 1 1800000000 -1 -1 -1 -1 -1\nweb 5000000 1800000000 1 1800000000 -1 -1 -1 -1 -1\n.host 0 1800000000 1 0\n")
	// root's alone: an app must not read another app's samples (tando top reads through sudo);
	// the directory is made 700 although it existed with 755 (an older version's)
	for f, want := range map[string]os.FileMode{"": 0o700, "web.tsv": 0o600, "host.tsv": 0o600, ".state": 0o600} {
		if fi, err := os.Stat(filepath.Join(h.m.Dir, f)); err != nil || fi.Mode().Perm() != want&^umask() {
			t.Errorf("%q: mode %v, want %v", f, fi.Mode().Perm(), want)
		}
	}

	// a minute later: web used 1.2 s of cpu; api-2 restarted (its counter began again)
	h.now += 60
	h.app("web", `tando.slice/tando-web.slice/tando-web.service`, 1100, 6_200_000)
	h.app("api-2", `tando.slice/tando-api\x2d2.slice/tando-api-2.service`, 2000, 400_000)
	h.systemd = "ActiveState=activating\nNRestarts=2\n\nActiveState=inactive\nNRestarts=\n"
	h.write("proc/loadavg", "12.34 0.40 0.31 1/123 4567\n")
	if err := h.m.Sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	check("web.tsv", "1800000000\t1000\t0\t3\tf\t-\t-\t-\t-\t-\t-\t-\n1800000060\t1100\t1200000\t0\ts\t-\t-\t-\t-\t-\t-\t-\n")
	check("api-2.tsv", "1800000000\t2000\t0\t1\tr\t-\t-\t-\t-\t-\t-\t-\n1800000060\t2000\t400000\t2\ta\t-\t-\t-\t-\t-\t-\t-\n")
	check("host.tsv", "1800000000\t52\t1536000000\t2048000000\t-\t4000\t10000\n1800000060\t1234\t1536000000\t2048000000\t-\t4000\t10000\n")
	check(".state", "api-2 400000 1800000000 2 1800000000 -1 -1 -1 -1 -1\nweb 6200000 1800000000 2 1800000000 -1 -1 -1 -1 -1\n.host 0 1800000000 2 0\n")

	// web is destroyed: its line leaves .state; a unit without a cgroup samples zeros
	os.RemoveAll(filepath.Join(h.m.Env.Root, "apps", "web"))
	os.RemoveAll(filepath.Join(h.m.Env.Cgroup, "tando.slice"))
	h.systemd = "ActiveState=inactive\nNRestarts=0\n"
	h.now += 60
	if err := h.m.Sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	check(".state", "api-2 0 1800000000 3 1800000000 -1 -1 -1 -1 -1\n.host 0 1800000000 3 0\n")
	check("api-2.tsv", "1800000000\t2000\t0\t1\tr\t-\t-\t-\t-\t-\t-\t-\n1800000060\t2000\t400000\t2\ta\t-\t-\t-\t-\t-\t-\t-\n1800000120\t0\t0\t0\ts\t-\t-\t-\t-\t-\t-\t-\n")
}

func TestSampleRotates(t *testing.T) {
	h := newHost(t)
	h.app("full", "system.slice/tando-full.service", 1, 100)
	h.app("old", "system.slice/tando-old.service", 1, 100)
	h.app("fresh", "system.slice/tando-fresh.service", 1, 100)
	h.systemd = strings.Repeat("ActiveState=active\nNRestarts=0\n\n", 3)
	now := h.now
	// the shell's own rotation test (test/e2e-top.sh 7d), plus a file that is not full yet
	h.write("lib/metrics/.state", "full 0 "+decimal.Itoa(now)+" 5100\nold 0 "+decimal.Itoa(now-302401)+" 3\nfresh 0 "+decimal.Itoa(now-302399)+" 5099\n.host 0 "+decimal.Itoa(now)+" 1\n")
	for _, a := range []string{"full", "old", "fresh"} {
		h.write("lib/metrics/"+a+".tsv", "1\t1\t1\t0\tr\n")
		h.write("lib/metrics/"+a+".tsv.1", "previous\n")
	}
	if err := h.m.Sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, a := range []string{"full", "old"} {
		if got := h.read(a + ".tsv.1"); got != "1\t1\t1\t0\tr\n" {
			t.Errorf("%s.tsv.1 = %q: not rotated", a, got)
		}
		if got := strings.Count(h.read(a+".tsv"), "\n"); got != 1 {
			t.Errorf("%s.tsv has %d lines after rotating", a, got)
		}
	}
	if got := h.read("fresh.tsv.1"); got != "previous\n" {
		t.Errorf("fresh rotated too early")
	}
	n := decimal.Itoa(now)
	want := "fresh 100 " + decimal.Itoa(now-302399) + " 5100 " + n + " -1 -1 -1 -1 -1\nfull 100 " + n + " 1 " + n + " -1 -1 -1 -1 -1\nold 100 " + n + " 1 " + n + " -1 -1 -1 -1 -1\n.host 0 " + n + " 2 0\n"
	if got := h.read(".state"); got != want {
		t.Errorf(".state:\n got %q\nwant %q", got, want)
	}
}

func TestSampleSystemdDown(t *testing.T) {
	h := newHost(t)
	h.app("web", "system.slice/tando-web.service", 1, 100)
	h.write("lib/metrics/.state", "web 50 1799990000 7\n.host 0 1799990000 7\n")
	h.sysErr = errors.New("systemctl: timed out after 20s")
	err := h.m.Sample(context.Background())
	if err == nil || !strings.Contains(err.Error(), "apps not sampled") {
		t.Fatalf("Sample = %v", err)
	}
	if _, err := os.Stat(filepath.Join(h.m.Dir, "web.tsv")); !os.IsNotExist(err) {
		t.Error("an app line was written without systemd's answer")
	}
	// the host was sampled, and web's file keeps its count and start
	if got := h.read(".state"); got != "web 50 1799990000 7 1800000000 -1 -1 -1 -1 -1\n.host 0 1799990000 8 0\n" {
		t.Errorf(".state = %q", got)
	}
}

func TestSampleNeedsRoot(t *testing.T) {
	h := newHost(t)
	h.m.Env.EUID = 1000
	if err := h.m.Sample(context.Background()); err == nil || !strings.Contains(err.Error(), "runs as root") {
		t.Fatalf("Sample as a user = %v", err)
	}
}

func TestStateFile(t *testing.T) {
	h := newHost(t)
	// a damaged .state: unparseable numbers are "not known", short lines are fine
	h.write("lib/metrics/.state", "web x 1799990000\n\n  \nonly\n")
	st, err := loadState(filepath.Join(h.m.Dir, ".state"))
	if err != nil {
		t.Fatal(err)
	}
	if e := st["web"]; e.usec != -1 || e.start != 1799990000 || e.lines != 0 {
		t.Errorf("web = %+v", e)
	}
	if e, ok := st["only"]; !ok || e.usec != -1 {
		t.Errorf("only = %+v, %v", e, ok)
	}
}

// umask is the process's (the test runner's, not main's 022).
func umask() os.FileMode {
	m := syscall.Umask(0)
	syscall.Umask(m)
	return os.FileMode(m)
}

// The restarts column counts what tando's recover took from NRestarts (the state's
// restarts_lost: systemd begins the count again when recover starts an app it gave up on).
func TestSampleRestartsLost(t *testing.T) {
	h := newHost(t)
	h.app("web", `tando.slice/tando-web.slice/tando-web.service`, 1000, 5_000_000)
	h.write("opt/apps/web/state", "current=20261114-170102\nrestarts_lost=10\n")
	h.systemd = "ActiveState=active\nNRestarts=1\n"
	if err := h.m.Sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := h.read("web.tsv"); got != "1800000000\t1000\t0\t11\tr\t-\t-\t-\t-\t-\t-\t-\n" {
		t.Errorf("web.tsv: %q", got)
	}
}

// The bytes an app's uid sent and received (fw_sync's nftables counters out_<uid>, in_<uid>) are
// columns 11 and 12: the difference since the last sample; a counter made again counts from 0.
func TestSampleNetBytes(t *testing.T) {
	h := newHost(t)
	h.app("web", `tando.slice/tando-web.slice/tando-web.service`, 1000, 5_000_000)
	if err := os.MkdirAll(filepath.Join(h.m.Env.Root, "apps", "web", "shared"), 0o755); err != nil {
		t.Fatal(err)
	}
	uid := decimal.Itoa(int64(os.Getuid()))
	counters := func(out, in int64) {
		h.nft = `{"nftables": [{"metainfo": {"version": "1.0.9"}}, {"counter": {"family": "inet", "name": "app_conn", "table": "tando", "packets": 1, "bytes": 9}},` +
			`{"counter": {"family": "inet", "name": "out_` + uid + `", "table": "tando", "packets": 3, "bytes": ` + decimal.Itoa(out) + `}},` +
			`{"counter": {"family": "inet", "name": "in_` + uid + `", "table": "tando", "packets": 3, "bytes": ` + decimal.Itoa(in) + `}}]}`
	}
	h.systemd = "ActiveState=active\nNRestarts=0\n"
	counters(1000, 5000)
	for _, step := range []struct {
		out, in int64
		want    string
	}{
		{1000, 5000, "-\t-"},      // the first sample: nothing to compare with
		{1600, 9000, "600\t4000"}, // a minute later
		{200, 300, "200\t300"},    // the rules were loaded anew: the counters began again
	} {
		counters(step.out, step.in)
		if err := h.m.Sample(context.Background()); err != nil {
			t.Fatal(err)
		}
		lines := strings.Split(strings.TrimSpace(h.read("web.tsv")), "\n")
		f := strings.Split(lines[len(lines)-1], "\t")
		if len(f) != 12 || f[10]+"\t"+f[11] != step.want {
			t.Errorf("line %q: want bytes %q", lines[len(lines)-1], step.want)
		}
		h.now += 60
	}
	if st := h.read(".state"); !strings.Contains(st, " 200 300\n") {
		t.Errorf(".state keeps the raw counters: %q", st)
	}
}
