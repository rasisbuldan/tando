package logs

import (
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"os"
	"runtime"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/out"
)

// (from the second review's demonstrations, zz_review_test.go)

func scanHost(t *testing.T) (*host, func() string, func(n int, st int)) {
	h := newHost(t)
	h.app("big")
	h.write("opt/apps/big/state", "current=x\n")
	h.write("log/tando/big/access.log", strings.Repeat(reqLine(float64(h.now), 500, "/x")+"\n", 5000))
	scan := func() string {
		o, _ := h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), []string{"big"}, w) })
		return o
	}
	add := func(n int, st int) {
		f, _ := os.OpenFile(h.path("log/tando/big/access.log"), os.O_APPEND|os.O_WRONLY, 0)
		f.WriteString(strings.Repeat(reqLine(float64(h.now), st, "/y")+"\n", n))
		f.Close()
	}
	return h, scan, add
}

const oneNew = "scan\tbig\t0\t0\t0\t1\t1\t"

// the index rebuilt (a torn state, a lost append after a power cut, another process rolling in
// between): its segments get new numbers, the requests already counted are not counted again
func TestScanCountsOnceAfterIndexRebuild(t *testing.T) {
	for _, mode := range []string{"torn-state", "short-rec", "oneshot", "cache"} {
		t.Run(mode, func(t *testing.T) {
			h, scan, add := scanHost(t)
			if mode == "cache" {
				h.l.Cache = NewScanCache()
			}
			scan()
			add(10, 503)
			scan()
			add(1, 503)
			switch mode {
			case "torn-state":
				p := h.path("lib/logscan/big/reqindex/state")
				b, _ := os.ReadFile(p)
				os.WriteFile(p, b[:len(b)-3], 0o600)
			case "short-rec": // the state persisted, the last .rec append did not
				ents, _ := os.ReadDir(h.path("lib/logscan/big/reqindex"))
				for _, e := range ents {
					if strings.HasSuffix(e.Name(), ".rec") {
						p := h.path("lib/logscan/big/reqindex/" + e.Name())
						fi, _ := os.Stat(p)
						os.Truncate(p, fi.Size()-32)
					}
				}
			case "oneshot":
				h.l.Cache = nil
			}
			if o := scan(); !strings.Contains(o, oneNew) {
				t.Errorf("%s: want 1 new request, got %q", mode, o)
			}
		})
	}
}

// the same after a roll whose rolled file Caddy then deleted: numbers start again at 0, the
// position still means what it meant
func TestScanCountsOnceAfterRollAndRebuild(t *testing.T) {
	h, scan, add := scanHost(t)
	scan()
	dir := h.path("log/tando/big")
	os.Rename(dir+"/access.log", dir+"/access-1.log")
	h.write("log/tando/big/access.log", strings.Repeat(reqLine(float64(h.now), 500, "/z")+"\n", 3000))
	scan()
	os.Remove(dir + "/access-1.log")
	add(5, 503)
	scan()
	add(1, 503)
	p := h.path("lib/logscan/big/reqindex/state")
	b, _ := os.ReadFile(p)
	os.WriteFile(p, b[:len(b)-3], 0o600)
	if o := scan(); !strings.Contains(o, oneNew) {
		t.Errorf("want 1 new request, got %q", o)
	}
}

// where the scan cannot tell (its position torn, two files with the same first line), it learns:
// nothing counted, never a burst
func TestScanLearnsWhenItCannotTell(t *testing.T) {
	h, scan, add := scanHost(t)
	scan()
	add(7, 503)
	h.write("lib/logscan/big/req.idx", "tando-reqpos 2\nab")
	if o := scan(); !strings.Contains(o, "scan\tbig\t0\t0\t0\t0\t0\t") {
		t.Errorf("a torn position: %q", o)
	}
	add(2, 503)
	if o := scan(); !strings.Contains(o, "scan\tbig\t0\t0\t0\t2\t2\t") {
		t.Errorf("then counting again: %q", o)
	}
	// requests older than posMaxAge are not this minute's (a monitor that was stopped for an hour)
	h.now += 3600
	f, _ := os.OpenFile(h.path("log/tando/big/access.log"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(strings.Repeat(reqLine(float64(h.now-3000), 503, "/y")+"\n", 3))
	f.Close()
	if o := scan(); !strings.Contains(o, "scan\tbig\t0\t0\t0\t0\t0\t") {
		t.Errorf("an hour old: %q", o)
	}
}

// tando errors (the operator's command) shows what was logged since the monitor's last scan, but
// leaves it to the monitor: its next scan still reports the new error
func TestErrorsLeavesTheMonitorItsEvents(t *testing.T) {
	h := newHost(t)
	h.app("boom")
	h.write("opt/apps/boom/state", "current=20261115-013512\n")
	h.write("etc/systemd/journald@tando-boom.conf", "x")
	journal := "-- cursor: s=1;i=1;t=1\n"
	h.cmd = func(argv []string) (string, error) { return journal, nil }
	scan := func() string {
		o, _ := h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), nil, w) })
		return o
	}
	scan()
	journal = "1794589990.000001 host node[7]: TypeError: brand new\n-- cursor: s=1;i=2;t=2\n"
	o, _ := h.rows(func(w *out.Writer) error { return h.l.Errors(ctx(), "boom", "", "", w) })
	if !strings.Contains(o, "TypeError: brand new") {
		t.Fatalf("errors does not show what was just logged: %q", o)
	}
	if o := scan(); !strings.Contains(o, "newerr\tboom\t") || !strings.Contains(o, "scan\tboom\t1\t1\t") {
		t.Errorf("the monitor's new error was taken by errors: %q", o)
	}
}

// the cursor and the counts it covers: a crash between the groups and the cursor file, a torn
// cursor file, a cursor journalctl refuses
func TestCursorCrashConsistency(t *testing.T) {
	h := newHost(t)
	h.app("boom")
	h.write("opt/apps/boom/state", "current=x\n")
	h.write("etc/systemd/journald@tando-boom.conf", "x")
	var after string
	journal := "-- cursor: s=1;i=1;t=10\n"
	h.cmd = func(argv []string) (string, error) {
		after = argv[len(argv)-1]
		if after == "--after-cursor=s=1;i=9;t=99" {
			return "", errors.New("journalctl: exit status 1: Failed to seek to cursor")
		}
		return journal, nil
	}
	scan := func() string {
		o, _ := h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), nil, w) })
		return o
	}
	scan()
	cursorFile := h.path("lib/logscan/boom/cursor")
	journal = "1794589990.5 host node[7]: ERROR one\n-- cursor: s=1;i=2;t=20\n"
	scan()
	// a crash after groups.tsv (it has the new cursor) but before the cursor file: put the old back
	writeCursor(h.path("lib/logscan/boom"), "c s=1;i=1;t=10")
	journal = "-- cursor: s=1;i=2;t=20\n"
	scan()
	if after != "--after-cursor=s=1;i=2;t=20" {
		t.Fatalf("read again after the crash: %s", after)
	}
	// a torn cursor file: the groups' cursor
	b, _ := os.ReadFile(cursorFile)
	os.WriteFile(cursorFile, b[:len(b)-2], 0o644)
	scan()
	if after != "--after-cursor=s=1;i=2;t=20" {
		t.Fatalf("a torn cursor: %s", after)
	}
	// a cursor journalctl refuses: said, and reading goes on from now
	writeCursor(h.path("lib/logscan/boom"), "c s=1;i=9;t=99")
	os.WriteFile(h.path("lib/logscan/boom/groups.tsv"), []byte("cursor\ts=1;i=9;t=99\n"), 0o644)
	o := scan()
	if !strings.Contains(o, "warn\tboom\tjournal cursor not found") {
		t.Fatalf("%q", o)
	}
	scan()
	if !strings.HasPrefix(after, "--since=@") {
		t.Fatalf("after a refused cursor: %s", after)
	}
}

// file names in Caddy's directory that are not Caddy's roll names are not read, and never reach
// the index's state (a blank or a newline would break or forge it)
func TestLogFileNamesAreChecked(t *testing.T) {
	for _, name := range []string{"access-x y.log", "access-a\n7 0 0 0 0 1 0 0 - access-zz.log", "access-" + strings.Repeat("x", 101) + ".log"} {
		h, scan, add := scanHost(t)
		h.write("log/tando/big/"+name, reqLine(float64(h.now), 200, "/q")+"\n")
		scan()
		add(1, 503)
		if o := scan(); !strings.Contains(o, oneNew) {
			t.Errorf("%q: %q", name, o)
		}
		st, _ := h.l.Roll(ctx(), "big")
		if st.Built || strings.Contains(h.read("lib/logscan/big/reqindex/state"), "access-zz") {
			t.Errorf("%q: the index was rebuilt or forged: %q", name, h.read("lib/logscan/big/reqindex/state"))
		}
	}
	if _, ok := parseSegment("0 0 0 0 0 0 0 0 - access x.log"); ok {
		t.Fatal("a segment line with a blank in its name")
	}
	if _, ok := parseSegment("0 0 0 0 0 9 0 0 - access.log"); ok {
		t.Fatal("flags out of range")
	}
}

// files Caddy's user piles into the log directory cost a bounded time and memory a tick
func TestManyLogFilesAreBounded(t *testing.T) {
	if testing.Short() {
		t.Skip("200,000 files")
	}
	h, scan, add := scanHost(t)
	h.l.Cache = NewScanCache()
	scan()
	for i := range 200000 {
		os.WriteFile(h.path(fmt.Sprintf("log/tando/big/access-%06d.log", i)), nil, 0o644)
	}
	runtime.GC()
	var m0, m1 runtime.MemStats
	runtime.ReadMemStats(&m0)
	add(1, 200)
	t0 := time.Now()
	o := scan()
	d := time.Since(t0)
	add(1, 200)
	t1 := time.Now()
	scan()
	d2 := time.Since(t1)
	runtime.GC()
	runtime.ReadMemStats(&m1)
	t.Logf("200,000 files: ticks %v, %v; cache %d KB, heap +%d KB", d, d2, h.l.Cache.Held()>>10, (int64(m1.HeapInuse)-int64(m0.HeapInuse))>>10)
	if d2 > 3*time.Second || h.l.Cache.Held() > 4<<20 || !strings.Contains(o, "scan\tbig\t") {
		t.Fatalf("tick %v, cache %d bytes", d2, h.l.Cache.Held())
	}
	if !strings.Contains(h.read("log/tando/audit.log"), "\tlog-files\tbig\tfailed\t") || h.read("lib/logscan/big/toomany") == "" {
		t.Fatal("not reported")
	}
	o, _ = h.rows(func(w *out.Writer) error { h.l.LogDoctor(ctx(), w); return nil })
	if !strings.Contains(o, "too many files") {
		t.Fatalf("doctor: %q", o)
	}
}

// a gzip'd roll replaced by another file of the same name is not served from the old segment
func TestReplacedGzipIsReadAgain(t *testing.T) {
	h := newHost(t)
	h.app("req")
	gz := func(ls ...string) []byte {
		var z bytes.Buffer
		w := gzip.NewWriter(&z)
		w.Write([]byte(strings.Join(ls, "\n") + "\n"))
		w.Close()
		return z.Bytes()
	}
	h.write("log/tando/req/access.log", reqLine(float64(h.now), 200, "/now")+"\n")
	h.write("log/tando/req/access-1.log.gz", string(gz(reqLine(float64(h.now-10), 500, "/a"), reqLine(float64(h.now-9), 500, "/b"))))
	sum := func() string {
		o, _ := h.rows(func(w *out.Writer) error { return h.l.ReqSummary(ctx(), "req", "3600", w) })
		return o
	}
	sum()
	h.write("log/tando/req/access-1.log.gz", string(gz(reqLine(float64(h.now-10), 500, "/a"), reqLine(float64(h.now-9), 404, "/c"), reqLine(float64(h.now-8), 404, "/d"))))
	if o := sum(); !strings.Contains(o, "total=4\n") || !strings.Contains(o, "c4xx=2\n") {
		t.Fatalf("%s", o)
	}
}

// a removed app takes its scan state with it: an app created again under its name starts afresh
func TestAppRemoveForgetsScanState(t *testing.T) {
	h := newHost(t)
	h.app("gone")
	h.write("lib/logscan/gone/groups.tsv", "x")
	h.rows(func(w *out.Writer) error { return h.l.AppRemove(ctx(), "gone", w) })
	if h.read("lib/logscan/gone/groups.tsv") != "" {
		t.Fatal("scan state left behind")
	}
}

// ownFile gives away only a file of its own (one link): not a hard link to someone else's
func TestOwnFileRefusesHardLinks(t *testing.T) {
	d := t.TempDir()
	os.WriteFile(d+"/a", []byte("x"), 0o600)
	os.Link(d+"/a", d+"/b")
	if err := ownFile(d+"/b", 0o640, os.Getuid(), os.Getgid()); err == nil || !strings.Contains(err.Error(), "links") {
		t.Fatalf("%v", err)
	}
}

// du in a directory others can write: fd-relative, symlinks not followed, links once
func TestDiskUsageStaysInside(t *testing.T) {
	d := t.TempDir()
	os.MkdirAll(d+"/x/y", 0o755)
	os.WriteFile(d+"/x/y/f", bytes.Repeat([]byte("z"), 1<<16), 0o644)
	os.Link(d+"/x/y/f", d+"/x/g")
	os.Symlink("/", d+"/x/root")
	os.Symlink("..", d+"/x/y/up")
	n, err := diskUsage(d)
	if err != nil || n < 1<<16 || n > 1<<16+64<<10 {
		t.Fatalf("%d %v", n, err)
	}
}

// an index rebuilt over more than one roll's budget: the position waits for it, nothing is
// counted twice while it catches up
func TestScanWaitsForARebuildingIndex(t *testing.T) {
	h := newHost(t)
	h.app("big")
	h.write("opt/apps/big/state", "current=x\n")
	line := reqLine(float64(h.now), 500, "/"+strings.Repeat("p", 3000)) + "\n"
	h.write("log/tando/big/access.log", strings.Repeat(line, rollBudget/len(line)*5/2))
	scan := func() string {
		o, _ := h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), []string{"big"}, w) })
		return o
	}
	for range 4 {
		scan()
	}
	os.RemoveAll(h.path("lib/logscan/big/reqindex"))
	for i := range 4 {
		if o := scan(); !strings.Contains(o, "scan\tbig\t0\t0\t0\t0\t0\t") {
			t.Fatalf("scan %d after the rebuild: %q", i, o)
		}
	}
	f, _ := os.OpenFile(h.path("log/tando/big/access.log"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(reqLine(float64(h.now), 503, "/y") + "\n")
	f.Close()
	if o := scan(); !strings.Contains(o, oneNew) {
		t.Fatalf("%q", o)
	}
}
