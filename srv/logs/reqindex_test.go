package logs

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/out"
	"tando/srv/logs/reqlog"
)

// genLines: n request lines around time t (some from a clock gone back, some not requests, some
// not JSON, a few with a status or a method a record cannot hold when odd is set).
func genLines(r *rand.Rand, n int, t float64, odd bool) []string {
	paths := []string{"/", "/a/%d", "/b/%x", "/c?-", "/users/%d/orders/%x", "/%s"}
	var out []string
	for i := 0; i < n; i++ {
		ts := t + float64(i)*r.Float64()*3
		if r.Intn(20) == 0 {
			ts -= 400 // the clock went back
		}
		p := paths[r.Intn(len(paths))]
		switch {
		case strings.Contains(p, "%d") && strings.Contains(p, "%x"):
			p = fmt.Sprintf(p, r.Intn(99), r.Int63())
		case strings.Contains(p, "%d"):
			p = fmt.Sprintf(p, r.Intn(99))
		case strings.Contains(p, "%x"):
			p = fmt.Sprintf(p, r.Int63())
		case strings.Contains(p, "%s"):
			p = fmt.Sprintf(p, []string{"x", "y", "zz", "caf\\u00e9"}[r.Intn(4)])
		}
		st := []int{200, 200, 200, 301, 404, 500, 503, 0}[r.Intn(8)]
		m := []string{"GET", "GET", "POST", ""}[r.Intn(4)]
		if odd && r.Intn(50) == 0 {
			m = strings.Repeat("M", 600) // a key no dictionary takes
		}
		l := fmt.Sprintf(`{"level":"info","ts":%.6f,"logger":"x","msg":"handled request","request":{"remote_ip":"10.0.0.1","remote_port":"1","proto":"HTTP/1.1","method":%q,"host":"h","uri":%q},"bytes_read":0,"duration":%.9f,"size":%d,"status":%d}`,
			ts, m, p, r.ExpFloat64()/50, r.Intn(5000), st)
		switch k := r.Intn(40); {
		case k == 0:
			l = "not json"
		case k == 1 && odd:
			l = strings.Replace(l, `"status":`, `"status":1.5e2,"x":`, 1)
		case k == 2:
			l = strings.Replace(l, `"size":`, `"size": `, 1) // a blank: the decoder's case
		}
		out = append(out, l)
	}
	return out
}

func TestIndexMatchesScan(t *testing.T) {
	h := newHost(t)
	h.app("req")
	r := rand.New(rand.NewSource(7))
	dir := h.path("log/tando/req")
	os.MkdirAll(dir, 0o755)
	cur := filepath.Join(dir, "access.log")
	ts := float64(h.now - 20000)
	appendLines := func(ls []string, partial bool) {
		f, _ := os.OpenFile(cur, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		s := strings.Join(ls, "\n") + "\n"
		if partial {
			s += `{"level":"info","ts":` // the line Caddy is writing
		}
		f.WriteString(s)
		f.Close()
		ts += float64(len(ls)) * 1.5
		os.Chtimes(cur, time.Unix(int64(ts), 0), time.Unix(int64(ts), 0))
	}
	finishPartial := func() {
		f, _ := os.OpenFile(cur, os.O_APPEND|os.O_WRONLY, 0)
		f.WriteString(fmt.Sprintf(`%.3f,"request":{"method":"GET","uri":"/p"},"duration":0.1,"status":500}`+"\n", ts))
		f.Close()
	}
	n := 0
	roll := func() {
		n++
		p := filepath.Join(dir, fmt.Sprintf("access-%03d.log", n))
		os.Rename(cur, p)
	}
	gz := func(name string) {
		p := filepath.Join(dir, name)
		b, _ := os.ReadFile(p)
		fi, _ := os.Stat(p)
		var z bytes.Buffer
		w := gzip.NewWriter(&z)
		w.Write(b)
		w.Close()
		os.WriteFile(p+".gz", z.Bytes(), 0o644)
		os.Chtimes(p+".gz", fi.ModTime(), fi.ModTime())
		os.Remove(p)
	}
	a, _ := h.l.app("req")
	used := 0
	check := func(step string) {
		t.Helper()
		defer func(u int) {
			if used == u && step != "a path spray" {
				t.Errorf("%s: no segment of the index was used", step)
			}
			t.Logf("%s: %d segments folded", step, used-u)
		}(used)
		for _, w := range []int64{300, 3600, 4000, 86400, 604800} {
			h.now = int64(ts) + 5
			var b1, b2 bytes.Buffer
			o := out.New(&b1)
			if err := h.l.ReqSummary(ctx(), "req", fmt.Sprint(w), o); err != nil {
				t.Fatal(err)
			}
			o.Flush()
			files := a.reqFiles(h.now - w)
			for _, v := range a.views(files) {
				if v != nil {
					used++
				}
			}
			s, _ := a.summarize(files, make([]*segView, len(files)), w, h.now, min(w/60, 60))
			closeAll(files)
			o = out.New(&b2)
			o.KV("files", fmt.Sprint(len(files)))
			s.Write(o)
			o.Flush()
			if b1.String() != b2.String() {
				t.Fatalf("%s, window %d: index and scan differ:\n%s\n---\n%s", step, w, b1.String(), b2.String())
			}
			for _, c := range []struct {
				n    int
				four string
			}{{20, ""}, {7, "4xx"}, {9999, "4xx"}} {
				var e1, e2 bytes.Buffer
				o = out.New(&e1)
				if err := h.l.ReqErrors(ctx(), "req", fmt.Sprint(w), fmt.Sprint(c.n), c.four, o); err != nil {
					t.Fatal(err)
				}
				o.Flush()
				files := a.reqFiles(h.now - w)
				f := reqlog.RowFilter{From: float64(h.now - w), MinStatus: 500}
				if c.four != "" {
					f.MinStatus = 400
				}
				o = out.New(&e2)
				lastRows(files, c.n, f, false, o)
				o.Flush()
				closeAll(files)
				if e1.String() != e2.String() {
					t.Fatalf("%s, req-errors %d %d %s: index and scan differ:\n%s\n---\n%s", step, w, c.n, c.four, e1.String(), e2.String())
				}
			}
		}
	}
	appendLines(genLines(r, 500, ts, false), true)
	check("first build, a partial last line")
	finishPartial()
	appendLines(genLines(r, 300, ts, false), false)
	check("appended")
	roll()
	appendLines(genLines(r, 200, ts, false), true)
	check("rolled; the rest of the old file read before it is gzip'd")
	gz("access-001.log")
	check("the rolled file gzip'd")
	appendLines(genLines(r, 300, ts, true), false)
	roll()
	gz("access-002.log") // gzip'd before the index saw its end
	appendLines(genLines(r, 100, ts, false), false)
	check("rolled and gzip'd between two runs, odd lines")
	os.Truncate(cur, 0)
	appendLines(genLines(r, 50, ts, false), false)
	check("the current file truncated")
	os.Remove(filepath.Join(dir, "access-001.log.gz"))
	check("a rolled file deleted by Caddy")
	// a killed run: records after the saved state are dropped at the next one
	x, _ := loadIndex(a.indexDir())
	for _, s := range x.segs {
		appendFile(x.path(s, ".rec"), make([]byte, reqlog.RecordSize*3))
	}
	appendLines(genLines(r, 20, ts, false), false)
	check("records past the state")
	// a state read torn (a crash, or a reader between the write and the truncate): new lines and
	// an old one after them. The seal catches it: rebuilt, still the scan's answer
	st, _ := os.ReadFile(filepath.Join(a.indexDir(), "state"))
	os.WriteFile(filepath.Join(a.indexDir(), "state"), append(st, []byte("9 0 0 0 0 0 0 - access.log\n")...), 0o600)
	if _, ok := loadIndex(a.indexDir()); ok {
		t.Fatal("a torn state was read as whole")
	}
	check("a torn state")
	// a damaged dictionary: the summary still matches (the log is read instead)
	for _, s := range x.segs {
		if s.Keys > 0 {
			os.Truncate(x.path(s, ".path"), 1)
		}
	}
	check("a damaged dictionary")
	// spraying paths beyond the dictionary's cap: that segment is read from the log
	var spray []string
	long := strings.Repeat("s", 70)
	for i := 0; i < indexMaxDict/80+50; i++ {
		spray = append(spray, fmt.Sprintf(`{"level":"info","ts":%.3f,"logger":"x","msg":"m","request":{"remote_ip":"1","remote_port":"1","proto":"p","method":"GET","host":"h","uri":"/%s%d"},"bytes_read":0,"duration":0.01,"size":1,"status":200}`, ts, long, i))
	}
	appendLines(spray, false)
	check("a path spray")
	if x, _ := loadIndex(a.indexDir()); x.segs[len(x.segs)-1].Flags&segRaw == 0 {
		t.Fatal("the sprayed segment is not marked to be read from the log")
	}
	// the index is root's alone
	if fi, _ := os.Stat(a.indexDir()); fi.Mode().Perm() != 0o700 {
		t.Fatal(fi.Mode())
	}
}

func BenchmarkIndexSummary(b *testing.B) {
	t := &testing.T{}
	h := newHostB(b)
	h.app("req")
	r := rand.New(rand.NewSource(1))
	h.access("req", "access.log", h.now, false, genLines(r, 100000, float64(h.now-90000), false)...)
	a, _ := h.l.app("req")
	if _, err := a.rollIndex(ctx()); err != nil {
		b.Fatal(err)
	}
	_ = t
	b.ResetTimer()
	for b.Loop() {
		files := a.reqFiles(h.now - 86400)
		s, ok := a.summarize(files, a.views(files), 86400, h.now, 60)
		closeAll(files)
		if !ok || s == nil {
			b.Fatal("index unusable")
		}
	}
}

// a roll reads at most rollBudget bytes; the rest at the next (a huge file costs a bounded time
// a tick), and the summary is still the log's
func TestRollBudget(t *testing.T) {
	h := newHost(t)
	h.app("big")
	line := reqLine(float64(h.now), 200, "/"+strings.Repeat("p", 3000)) + "\n"
	h.write("log/tando/big/access.log", strings.Repeat(line, rollBudget/len(line)*5/2))
	a, _ := h.l.app("big")
	var reads []int64
	for range 4 {
		st, err := a.rollIndex(ctx())
		if err != nil {
			t.Fatal(err)
		}
		reads = append(reads, st.Bytes)
	}
	if reads[0] > rollBudget+int64(len(line)) || reads[1] == 0 || reads[3] != 0 {
		t.Fatalf("bytes read per roll: %v", reads)
	}
}
