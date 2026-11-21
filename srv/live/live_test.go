package live

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/env"
	"tando/srv/internal/out"
)

type fixture struct {
	t    *testing.T
	e    env.Env
	now  time.Time
	asks int
}

func put(t *testing.T, p, s string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func newFixture(t *testing.T) *fixture {
	d := t.TempDir()
	f := &fixture{t: t, now: time.Unix(1_700_000_000, 0)}
	f.e = env.Env{Root: filepath.Join(d, "opt"), Cgroup: filepath.Join(d, "cg"), Proc: filepath.Join(d, "proc"),
		Now: func() time.Time { return f.now }}
	put(t, filepath.Join(f.e.Proc, "loadavg"), "0.52 0.40 0.31 1/100 42\n")
	put(t, filepath.Join(f.e.Proc, "meminfo"), "MemTotal:       2000 kB\nMemFree: 1 kB\nMemAvailable:   500 kB\n")
	f.stat(100, 1000)
	for _, a := range []string{"a1", "b2"} {
		put(t, filepath.Join(f.e.Root, "apps", a, "app.conf"), "port=1\n")
	}
	f.app("a1", 1000, 2000, 0, 3)
	f.app("b2", 0, 0, 0, 0)
	return f
}

// stat writes /proc/stat with busy and idle jiffies.
func (f *fixture) stat(busy, idle int) {
	put(f.t, filepath.Join(f.e.Proc, "stat"), "cpu  "+itoa(busy)+" 0 0 "+itoa(idle)+" 0 0 0 0 0 0\ncpu0 1 2 3 4\n")
}

func (f *fixture) app(a string, anon, shmem, usec, tasks int) {
	d := filepath.Join(f.e.Cgroup, "system.slice", "tando-"+a+".service")
	put(f.t, filepath.Join(d, "memory.stat"), "anon "+itoa(anon)+"\nfile 99999\nshmem "+itoa(shmem)+"\n")
	put(f.t, filepath.Join(d, "cpu.stat"), "usage_usec "+itoa(usec)+"\nuser_usec 1\n")
	put(f.t, filepath.Join(d, "pids.current"), itoa(tasks)+"\n")
}

func itoa(n int) string { return strconv.Itoa(n) }

func (f *fixture) live() *Live {
	l := New(f.e, func(units []string) ([]map[string]string, error) {
		f.asks++
		res := make([]map[string]string, len(units))
		for i, u := range units {
			if u == "tando-a1.service" {
				res[i] = map[string]string{"ActiveState": "active", "SubState": "running", "NRestarts": "2", "MainPID": "4242"}
			} else {
				res[i] = map[string]string{"ActiveState": "inactive", "SubState": "dead", "NRestarts": "0", "MainPID": "0"}
			}
		}
		return res, nil
	})
	l.Statfs = func(string) (uint64, uint64, error) { return 300, 1000, nil }
	return l
}

func rows(l *Live, app string, ring bool) string {
	var b bytes.Buffer
	w := out.New(&b)
	if ring {
		l.RingRows(w, app)
	} else {
		l.Rows(w, app)
	}
	w.Flush()
	return b.String()
}

func TestSampleRows(t *testing.T) {
	f := newFixture(t)
	l := f.live()
	if got := rows(l, "", false); got != "" {
		t.Fatalf("rows before the first point: %q", got)
	}
	l.Sample()
	want := "lhost\t1700000000\t0.52\t1536000\t2048000\t-\t300\t1000\n" +
		"lapp\ta1\t1700000000\tactive\trunning\t2\t4242\t3000\t-\t3\t0\n" +
		"lapp\tb2\t1700000000\tinactive\tdead\t0\t0\t0\t-\t0\t0\n"
	if got := rows(l, "", false); got != want {
		t.Errorf("first point:\n%s\nwant\n%s", got, want)
	}
	// 5 s later a1 used 2.5 s of CPU (500 ‰ of a core); the host was busy 300 of 1000 jiffies
	f.now = f.now.Add(5 * time.Second)
	f.app("a1", 1000, 2000, 2_500_000, 3)
	f.stat(400, 1700)
	l.Sample()
	got := rows(l, "a1", false)
	want = "lhost\t1700000005\t0.52\t1536000\t2048000\t300\t300\t1000\n" +
		"lapp\ta1\t1700000005\tactive\trunning\t2\t4242\t3000\t500\t3\t2500000\n"
	if got != want {
		t.Errorf("second point, a1:\n%s\nwant\n%s", got, want)
	}
	// the unit restarted: its counter began again (the CPU since then, never negative)
	f.now = f.now.Add(5 * time.Second)
	f.app("a1", 1000, 2000, 1_000_000, 3)
	l.Sample()
	if got := rows(l, "a1", false); !strings.Contains(got, "\t200\t3\t1000000\n") {
		t.Errorf("after a restart: %q", got)
	}
	ring := rows(l, "b2", true)
	if strings.Count(ring, "rhost\t") != 3 || strings.Count(ring, "rapp\tb2\t") != 3 || strings.Contains(ring, "a1") {
		t.Errorf("ring of b2:\n%s", ring)
	}
}

func TestRingKeepsAnHour(t *testing.T) {
	f := newFixture(t)
	l := f.live()
	for i := 0; i < Keep+10; i++ {
		l.Sample()
		f.now = f.now.Add(Every)
	}
	if l.Len() != Keep {
		t.Fatalf("ring holds %d points, want %d", l.Len(), Keep)
	}
	ring := rows(l, "a1", true)
	first := strings.SplitN(ring, "\n", 2)[0]
	if want := "rhost\t" + itoa(1_700_000_000+10*5) + "\t"; !strings.HasPrefix(first, want) {
		t.Errorf("oldest point %q, want it to start %q", first, want)
	}
}

func TestSystemdDoesNotAnswer(t *testing.T) {
	f := newFixture(t)
	l := f.live()
	l.Units = func([]string) ([]map[string]string, error) { return nil, errors.New("bus down") }
	l.Sample()
	if got := rows(l, "a1", false); !strings.Contains(got, "lapp\ta1\t1700000000\t?\t?\t0\t0\t3000\t-\t3\t0\n") {
		t.Errorf("without systemd: %q", got)
	}
}

func TestV2(t *testing.T) {
	d := t.TempDir()
	if V2(d) {
		t.Error("v2 without cgroup.controllers")
	}
	put(t, filepath.Join(d, "cgroup.controllers"), "cpu memory pids\n")
	if !V2(d) {
		t.Error("not v2 with cgroup.controllers")
	}
}
