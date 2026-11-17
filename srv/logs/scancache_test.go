package logs

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"os"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	"tando/srv/internal/out"
)

// an app whose journal never held a line: one first scan, then no journalctl while nothing is
// written; what it logs first is then read from that scan's time and reported, not learned
func TestScanNeverLogged(t *testing.T) {
	h := newHost(t)
	h.app("quiet")
	h.write("opt/apps/quiet/state", "current=x\n")
	h.write("etc/systemd/journald@tando-quiet.conf", "x")
	h.write("log/journal/"+machineID+".tando-quiet/system.journal", "empty")
	journal := ""
	h.cmd = func([]string) (string, error) { return journal, nil }
	scan := func() string {
		o, _ := h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), nil, w) })
		return o
	}
	scan()
	if j := h.argvs("journalctl"); len(j) != 1 || !strings.Contains(j[0], "--since=-24h") {
		t.Fatal(j)
	}
	for range 3 {
		scan()
	}
	if j := h.argvs("journalctl"); len(j) != 1 {
		t.Fatalf("journalctl ran %d times for a journal that did not change", len(j))
	}
	h.write("log/journal/"+machineID+".tando-quiet/system.journal", "now with a line")
	journal = fmt.Sprintf("%d.5 host node[7]: ERROR first words\n-- cursor: s=1\n", h.now)
	o := scan()
	j := h.argvs("journalctl")
	if len(j) != 2 || !strings.Contains(j[1], fmt.Sprintf("--since=@%d", h.now)) || !strings.HasPrefix(o, "newerr\tquiet\t") {
		t.Fatalf("%q %q", j, o)
	}
}

// the same ticks with and without a cache print the same rows
func TestScanCacheMatches(t *testing.T) {
	hs := [2]*host{newHost(t), newHost(t)}
	hs[1].l.Cache = NewScanCache()
	var outs [2][]string
	for i, h := range hs {
		h.app("web")
		h.write("opt/apps/web/state", "current=x\n")
		h.write("etc/systemd/journald@tando-web.conf", "x")
		jn := 0
		h.cmd = func(argv []string) (string, error) {
			jn++
			return fmt.Sprintf("%d.5 host node[7]: ERROR boom %d\n-- cursor: s=%d\n", h.now, jn, jn), nil
		}
		dir := h.path("log/tando/web")
		os.MkdirAll(dir, 0o755)
		app := func(ls ...string) {
			f, _ := os.OpenFile(dir+"/access.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
			f.WriteString(strings.Join(ls, "\n") + "\n")
			f.Close()
		}
		for tick := range 12 {
			switch tick {
			case 2, 5:
				app(reqLine(float64(h.now), 500, "/a/1"), reqLine(float64(h.now), 200, "/b"))
			case 3:
				h.write("log/journal/"+machineID+".tando-web/system.journal", "j"+fmt.Sprint(tick))
			case 7:
				os.Rename(dir+"/access.log", dir+"/access-1.log")
				app(reqLine(float64(h.now), 503, "/c/9"))
			case 8:
				b, _ := os.ReadFile(dir + "/access-1.log")
				var z bytes.Buffer
				zw := gzip.NewWriter(&z)
				zw.Write(b)
				zw.Close()
				os.WriteFile(dir+"/access-1.log.gz", z.Bytes(), 0o644)
				os.Remove(dir + "/access-1.log")
			case 10:
				os.Truncate(dir+"/access.log", 0)
				app(reqLine(float64(h.now), 502, "/d"))
			}
			o, _ := h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), nil, w) })
			outs[i] = append(outs[i], o)
		}
	}
	for k := range outs[0] {
		if outs[0][k] != outs[1][k] {
			t.Fatalf("tick %d:\nno cache %q\n   cache %q", k, outs[0][k], outs[1][k])
		}
	}
}

func idleHost(t *testing.T, dir string, n int) *host {
	h := newHostTB(t, dir)
	h.l.Cache = NewScanCache()
	h.cmd = func([]string) (string, error) { return "-- cursor: s=1\n", nil }
	for i := range n {
		a := fmt.Sprintf("app%03d", i)
		h.app(a)
		h.write("opt/apps/"+a+"/state", "current=x\n")
		h.write("etc/systemd/journald@tando-"+a+".conf", "x")
		h.write("log/journal/"+machineID+".tando-"+a+"/system.journal", "j")
		h.write("log/tando/"+a+"/access.log", reqLine(float64(h.now), 200, "/")+"\n")
	}
	for range 2 { // learn, then a full scan that finds nothing
		h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), nil, w) })
	}
	return h
}

func TestIdleScan(t *testing.T) {
	h := idleHost(t, t.TempDir(), 20)
	n := len(h.calls)
	var b bytes.Buffer
	w := out.New(&b)
	h.l.WatchScan(ctx(), nil, w)
	w.Flush()
	if len(h.calls) != n || strings.Count(b.String(), "\tscan\t") != 0 || strings.Count(b.String(), "scan\tapp") != 20 ||
		!strings.Contains(b.String(), "scan\tapp007\t0\t0\t0\t0\t0\t0\t0\n") {
		t.Fatalf("%d commands, %q", len(h.calls)-n, b.String())
	}
	if runtime.GOOS == "linux" && !raceOn { // (fstatat; elsewhere os.Stat allocates)
		b.Reset()
		if a := testing.AllocsPerRun(20, func() { h.l.WatchScan(ctx(), nil, w); w.Flush(); b.Reset() }); a > 1 {
			t.Fatalf("an idle scan of 20 apps: %v allocations", a)
		}
	}
}

func BenchmarkIdleScan100(b *testing.B) {
	h := idleHost(&testing.T{}, b.TempDir(), 100)
	var buf bytes.Buffer
	w := out.New(&buf)
	b.ReportAllocs()
	for b.Loop() {
		h.l.WatchScan(ctx(), nil, w)
		w.Flush()
		buf.Reset()
	}
}

// 240 requests a minute over 20 apps: what a tick costs the scan (journalctl is the fake runner
// here; with journal set every app's journal changed too)
func benchTraffic(b *testing.B, journal bool) {
	h := idleHost(&testing.T{}, b.TempDir(), 20)
	var buf bytes.Buffer
	w := out.New(&buf)
	lines := make([]string, 12)
	for i := range lines {
		lines[i] = reqLine(float64(h.now), []int{200, 200, 404, 500}[i%4], fmt.Sprintf("/api/x/%d", i))
	}
	add := strings.Join(lines, "\n") + "\n"
	tick := 0
	b.ReportAllocs()
	for b.Loop() {
		b.StopTimer()
		tick++
		for i := range 20 {
			a := fmt.Sprintf("app%03d", i)
			f, _ := os.OpenFile(h.path("log/tando/"+a+"/access.log"), os.O_APPEND|os.O_WRONLY, 0)
			f.WriteString(add)
			f.Close()
			if journal {
				h.write("log/journal/"+machineID+".tando-"+a+"/system.journal", fmt.Sprint("j", tick))
			}
		}
		b.StartTimer()
		h.l.WatchScan(ctx(), nil, w)
		w.Flush()
		buf.Reset()
	}
}

func BenchmarkTraffic20(b *testing.B)        { benchTraffic(b, false) }
func BenchmarkTraffic20Journal(b *testing.B) { benchTraffic(b, true) }

// a client spraying unique URLs at many apps, across rolls, through the long-running path: what
// the cache keeps between ticks stays small (dictionaries dropped when large, a cap on all of
// them), and so does the heap
func TestCacheBoundedUnderSpray(t *testing.T) {
	h := idleHost(t, t.TempDir(), 20)
	runtime.GC()
	var m0, m1 runtime.MemStats
	runtime.ReadMemStats(&m0)
	var buf bytes.Buffer
	w := out.New(&buf)
	n := 0
	for roll := range 4 {
		for i := range 20 {
			a := fmt.Sprintf("app%03d", i)
			dir := h.path("log/tando/" + a)
			if roll > 0 {
				os.Rename(dir+"/access.log", fmt.Sprintf("%s/access-%d.log", dir, roll))
			}
			var ls []string
			paths := 300 // apps 0-9: small dictionaries (kept, up to the cap on all), 10-19: sprayed
			if i >= 10 {
				paths = 3000
			}
			for range paths {
				n++
				ls = append(ls, reqLine(float64(h.now), 200, fmt.Sprintf("/s-%x-page", n*7919)))
			}
			os.WriteFile(dir+"/access.log", []byte(strings.Join(ls, "\n")+"\n"), 0o644)
		}
		h.l.WatchScan(ctx(), nil, w)
		w.Flush()
		buf.Reset()
	}
	held := h.l.Cache.Held()
	runtime.GC()
	runtime.ReadMemStats(&m1)
	grew := int64(m1.HeapInuse) - int64(m0.HeapInuse)
	t.Logf("cache holds about %d KB; heap in use grew %d KB", held>>10, grew>>10)
	if held > 1<<20 || grew > 2<<20 {
		t.Fatalf("cache holds %d bytes, heap grew %d bytes", held, grew)
	}
	// and every app's index is still right: a summary through it is a full scan's
	for _, a := range []string{"app003", "app015"} {
		ap, _ := h.l.app(a)
		files := ap.reqFiles(0)
		s1, ok := ap.summarize(files, ap.views(files), 604800, h.now, 60)
		s2, _ := ap.summarize(files, make([]*segView, len(files)), 604800, h.now, 60)
		closeAll(files)
		var b1, b2 bytes.Buffer
		o1, o2 := out.New(&b1), out.New(&b2)
		s1.Write(o1)
		s2.Write(o2)
		o1.Flush()
		o2.Flush()
		if !ok || b1.String() != b2.String() {
			t.Fatalf("%s: the index after the spray differs from the log", a)
		}
	}
}

// apps and log files that are gone are forgotten by the cache
func TestCachePrunes(t *testing.T) {
	h := idleHost(t, t.TempDir(), 3)
	os.RemoveAll(h.path("opt/apps/app001"))
	h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), nil, w) })
	if _, ok := h.l.Cache.per["app001"]; ok || len(h.l.Cache.per) != 2 {
		t.Fatalf("%d apps cached", len(h.l.Cache.per))
	}
}

func TestCacheForgetsDeletedFiles(t *testing.T) {
	h := idleHost(t, t.TempDir(), 1)
	dir := h.path("log/tando/app000")
	for i := range 3 {
		os.Rename(dir+"/access.log", fmt.Sprintf("%s/access-%d.log", dir, i))
		h.write("log/tando/app000/access.log", reqLine(float64(h.now), 200, "/")+"\n")
		h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), nil, w) })
	}
	os.Remove(dir + "/access-0.log")
	os.Remove(dir + "/access-1.log")
	// (an idle app is not even listed: what Caddy deleted is forgotten at its next request)
	f, _ := os.OpenFile(dir+"/access.log", os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(reqLine(float64(h.now), 200, "/x") + "\n")
	f.Close()
	h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), nil, w) })
	if n := len(h.l.Cache.per["app000"].files); n != 2 {
		t.Fatalf("%d files remembered", n)
	}
}

// a FIFO in the request log's directory (Caddy's: a process running as caddy can make one, or
// swap one in after a stat) blocks nothing
func TestFIFODoesNotBlock(t *testing.T) {
	h := idleHost(t, t.TempDir(), 1)
	dir := h.path("log/tando/app000")
	for _, n := range []string{"access-1.log", "access-2.log.gz", "sub"} {
		if err := syscall.Mkfifo(dir+"/"+n, 0o644); err != nil {
			t.Skip("no mkfifo here:", err)
		}
	}
	done := make(chan bool)
	go func() {
		h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), nil, w) })
		h.rows(func(w *out.Writer) error { return h.l.ReqSummary(ctx(), "app000", "604800", w) })
		h.rows(func(w *out.Writer) error { return h.l.ReqErrors(ctx(), "app000", "604800", "20", "", w) })
		h.rows(func(w *out.Writer) error { return h.l.LogStats(ctx(), "app000", w) })
		diskUsage(dir)
		done <- true
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("blocked on a FIFO")
	}
	if isGzip(dir+"/access-2.log.gz") || func() bool { _, err := openRegular(dir + "/access-1.log"); return err == nil }() {
		t.Fatal("a FIFO opened as a log file")
	}
}
