package metrics

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/decimal"
)

// the host line gains cpu permille (from /proc/stat deltas, kept in .state) and the disk of the
// filesystem holding the metrics directory; the first sample has no cpu yet ("-")
func TestSampleHostCPUDisk(t *testing.T) {
	h := newHost(t)
	h.write("proc/stat", "cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 1 1 1\n")
	if err := h.m.Sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	f := strings.Split(strings.TrimSuffix(h.read("host.tsv"), "\n"), "\t")
	if len(f) != 7 || f[4] != "-" {
		t.Fatalf("first host line %q: want 7 fields, cpu -", f)
	}
	used, total := num(f[5]), num(f[6])
	if total <= 0 || used <= 0 || used > total {
		t.Errorf("disk used %d of %d", used, total)
	}
	if got := h.read(".state"); !strings.HasSuffix(got, ".host 200 1800000000 1 1000\n") {
		t.Errorf(".state %q: want busy and total jiffies", got)
	}
	// a minute later: 300 of 1000 more jiffies busy (iowait counts as idle) -> 300 permille
	h.now += 60
	h.write("proc/stat", "cpu  300 0 200 1300 200 0 0 0 0 0\n")
	if err := h.m.Sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSuffix(h.read("host.tsv"), "\n"), "\n")
	if f := strings.Split(lines[1], "\t"); len(f) != 7 || f[4] != "300" {
		t.Errorf("second host line %q: want cpu 300", lines[1])
	}
	// no /proc/stat (or an old .state without the total): no cpu, the sample still happens
	os.Remove(filepath.Join(h.m.Env.Proc, "stat"))
	h.now += 60
	if err := h.m.Sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	lines = strings.Split(strings.TrimSuffix(h.read("host.tsv"), "\n"), "\n")
	if f := strings.Split(lines[2], "\t"); f[4] != "-" {
		t.Errorf("without /proc/stat: %q", lines[2])
	}
}

// per app: the bytes on disk of its tree (app dir, a data_dir outside it, its journal namespace),
// walked at most every 15 minutes into <app>.disk; hard links count once
func TestSampleDisk(t *testing.T) {
	h := newHost(t)
	h.app("web", "system.slice/tando-web.service", 1, 100)
	h.systemd = "ActiveState=active\nNRestarts=0\n"
	h.write("opt/apps/web/releases/1/a.js", strings.Repeat("x", 10000))
	h.write("ext/webdata/db.sqlite", strings.Repeat("y", 20000))
	h.write("opt/apps/web/app.conf", "port=4100\ndata_dir="+filepath.Join(filepath.Dir(h.m.Env.Root), "ext/webdata")+"\n")
	h.write("journal/abc123.tando-web/system.journal", strings.Repeat("z", 30000))
	h.write("journal/abc123.tando-webx/system.journal", strings.Repeat("z", 90000)) // another app's
	a := filepath.Join(h.m.Env.Root, "apps/web/releases/1/a.js")
	if err := os.Link(a, filepath.Join(h.m.Env.Root, "apps/web/releases/1/b.js")); err != nil {
		t.Fatal(err)
	}
	if err := h.m.Sample(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := h.read("web.disk")
	ts, b, ok := strings.Cut(strings.TrimSuffix(got, "\n"), "\t")
	if !ok || ts != "1800000000" {
		t.Fatalf("web.disk = %q", got)
	}
	n := num(b)
	// blocks, not sizes: at least the 60000 bytes written once each, well under the other app's
	if n < 60000 || n >= 60000+90000 {
		t.Errorf("web disk %d: want the app dir, data_dir and journal (hard link once), not webx's journal", n)
	}
	if !strings.Contains(h.read(".state"), "web 100 1800000000 1 1800000000 -1 -1 -1\n") {
		t.Errorf(".state %q: want the walk's time", h.read(".state"))
	}
	// 14 minutes later: not walked again; 15: walked
	h.now += 14 * 60
	h.m.Sample(context.Background())
	if strings.Count(h.read("web.disk"), "\n") != 1 {
		t.Error("walked again before 15 minutes")
	}
	h.now += 60
	h.m.Sample(context.Background())
	if strings.Count(h.read("web.disk"), "\n") != 2 {
		t.Error("not walked after 15 minutes")
	}
	// over the budget: the walk stops, no line, and it waits 15 minutes before trying again
	h.m.DiskBudget = time.Nanosecond
	h.now += 15 * 60
	h.m.Sample(context.Background())
	if strings.Count(h.read("web.disk"), "\n") != 2 {
		t.Error("a walk over the budget wrote a line")
	}
	if !strings.Contains(h.read(".state"), "web 100 1800000000 4 "+decimal.Itoa(h.now)+" -1 -1 -1\n") {
		t.Errorf(".state %q: the failed walk is not remembered", h.read(".state"))
	}
}

// the per-app walk on a tree of 50k files (go test -bench Walk ./metrics)
func BenchmarkWalk50k(b *testing.B) {
	dir := b.TempDir()
	for i := 0; i < 500; i++ {
		d := filepath.Join(dir, fmt.Sprintf("d%03d", i))
		if err := os.Mkdir(d, 0o755); err != nil {
			b.Fatal(err)
		}
		for j := 0; j < 100; j++ {
			if err := os.WriteFile(filepath.Join(d, fmt.Sprintf("f%03d", j)), []byte("x"), 0o644); err != nil {
				b.Fatal(err)
			}
		}
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		w := walker{deadline: time.Now().Add(time.Minute), seen: map[inode]bool{}}
		if !w.walk(dir) || w.files < 50000 {
			b.Fatalf("walk: %d files", w.files)
		}
	}
}
