package logs

import (
	"bytes"
	"compress/gzip"
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"tando/srv/internal/out"
	"tando/srv/logs/reqlog"
)

func reqLine(ts float64, status int, uri string) string {
	return fmt.Sprintf(`{"level":"info","ts":%.6f,"logger":"http.log.access.log0","msg":"handled request","request":{"remote_ip":"10.0.0.1","remote_port":"1","proto":"HTTP/1.1","method":"GET","host":"h","uri":%q},"bytes_read":0,"user_id":"","duration":0.0125,"size":3,"status":%d}`,
		ts, uri, status)
}

func (h *host) access(app, name string, mtime int64, gz bool, ls ...string) {
	data := []byte(strings.Join(ls, "\n") + "\n")
	if gz {
		var b bytes.Buffer
		z := gzip.NewWriter(&b)
		z.Write(data)
		z.Close()
		data = b.Bytes()
	}
	h.write("log/tando/"+app+"/"+name, string(data))
	os.Chtimes(h.path("log/tando/"+app+"/"+name), time.Unix(mtime, 0), time.Unix(mtime, 0))
}

func TestRequests(t *testing.T) {
	h := newHost(t)
	h.app("req")
	n := float64(h.now)
	h.access("req", "access-2026-11-13T10-00-00.000.log.gz", h.now-7200, true, reqLine(n-7300, 200, "/old"), reqLine(n-7250, 500, "/old/1"))
	h.access("req", "access-2026-11-13T11-00-00.000.log", h.now-3000, false, reqLine(n-3100, 503, "/mid/2"), reqLine(n-3050, 200, "/mid"))
	h.access("req", "access.log", h.now, false, reqLine(n-100, 200, "/a/9f86d081884c7d65?-"), reqLine(n-50, 404, "/b"),
		reqLine(n-10, 500, "/c/12"), `{"level":"info","ts":1794589995,"request":{"remote_ip":"1.1.1.1","method":"POST","uri":"/x"},"duration":0.5,"size":0}`)
	h.write("log/tando/req/access-9.log.lnk", "")
	os.Symlink(h.path("log/tando/req/access.log"), h.path("log/tando/req/access-link.log"))
	o, err := h.rows(func(w *out.Writer) error { return h.l.ReqSummary(ctx(), "req", "3600", w) })
	if err != nil || !strings.HasPrefix(o, "files=2\nwindow=3600\nfrom=1794586400\nto=1794590000\nbucket=60\ntotal=6\n") ||
		!strings.Contains(o, "code\taborted\t1\n") || !strings.Contains(o, "path\tGET /a/:id\t1\t12.50\t12.50\t0\n") ||
		!strings.Contains(o, "\noldest=1794586900\n") {
		t.Fatalf("%s %v", o, err)
	}
	o, _ = h.rows(func(w *out.Writer) error { return h.l.ReqSummary(ctx(), "req", "", w) })
	if !strings.HasPrefix(o, "files=1\nwindow=900\n") {
		t.Fatal(o)
	}
	o, _ = h.rows(func(w *out.Writer) error { return h.l.ReqSummary(ctx(), "req", "604800", w) })
	if !strings.Contains(o, "files=3\n") || !strings.Contains(o, "total=8\n") {
		t.Fatalf("the gzip'd rolled file is read: %s", o)
	}
	for _, w := range []string{"59", "604801", "1h", "9999999", "08;"} {
		_, err = h.rows(func(o *out.Writer) error { return h.l.ReqSummary(ctx(), "req", w, o) })
		wantErr(t, err, "bad window")
	}
	// tail: the last 3 lines of the newest two files; the line without a method or status is not a row
	o, _ = h.rows(func(w *out.Writer) error { return h.l.ReqTail(ctx(), "req", "3", "", w, nil) })
	if o != "req\t1794589950.000\t404\t12.50\tGET\t/b\t3\t10.0.0.1\nreq\t1794589990.000\t500\t12.50\tGET\t/c/12\t3\t10.0.0.1\nreq\t1794589995.000\taborted\t500.00\tPOST\t/x\t0\t1.1.1.1\n" {
		t.Fatalf("%q", o)
	}
	o, _ = h.rows(func(w *out.Writer) error { return h.l.ReqTail(ctx(), "req", "100", "", w, nil) })
	if strings.Count(o, "\n") != 6 || strings.Contains(o, "/old") {
		t.Fatalf("%q", o)
	}
	_, err = h.rows(func(w *out.Writer) error { return h.l.ReqTail(ctx(), "req", "5 $(id)", "", w, nil) })
	wantErr(t, err, "bad count")
	// errors: 5xx (and aborted) in the window; with 4xx
	o, _ = h.rows(func(w *out.Writer) error { return h.l.ReqErrors(ctx(), "req", "3600", "20", "", w) })
	if strings.Count(o, "\n") != 3 || !strings.Contains(o, "\t503\t") || strings.Contains(o, "\t404\t") {
		t.Fatalf("%q", o)
	}
	o, _ = h.rows(func(w *out.Writer) error { return h.l.ReqErrors(ctx(), "req", "3600", "2", "4xx", w) })
	if o != "req\t1794589990.000\t500\t12.50\tGET\t/c/12\t3\t10.0.0.1\nreq\t1794589995.000\taborted\t500.00\tPOST\t/x\t0\t1.1.1.1\n" {
		t.Fatalf("%q", o)
	}
	h.app("nolog")
	_, err = h.rows(func(w *out.Writer) error { return h.l.ReqTail(ctx(), "nolog", "", "", w, nil) })
	wantErr(t, err, "no request log for nolog (access_log = off, or no request yet)")
}

func TestRowsOverBudget(t *testing.T) {
	h := newHost(t)
	h.app("req")
	var ls []string
	for i := 0; i < 5000; i++ {
		ls = append(ls, reqLine(float64(h.now-5000+int64(i)), 500, "/"+strings.Repeat("p", 4000)+fmt.Sprint(i)))
	}
	h.access("req", "access.log", h.now, false, ls...)
	o, _ := h.rows(func(w *out.Writer) error { return h.l.ReqTail(ctx(), "req", "4999", "", w, nil) })
	r := strings.Split(strings.TrimSuffix(o, "\n"), "\n")
	if len(r) != 4999 || !strings.Contains(r[0], "p1\t") || !strings.Contains(r[4998], "p4999\t") {
		t.Fatalf("%d rows", len(r))
	}
}

func TestTailFollow(t *testing.T) {
	h := newHost(t)
	h.app("req")
	n := float64(h.now)
	h.access("req", "access.log", h.now, false, reqLine(n, 200, "/1"), reqLine(n, 200, "/2"))
	var b bytes.Buffer
	w := out.New(&b)
	c, cancel := context.WithCancel(ctx())
	done := make(chan error)
	go func() { done <- h.l.ReqTail(c, "req", "1", "follow", w, w.Flush) }()
	time.Sleep(100 * time.Millisecond)
	p := h.path("log/tando/req/access.log")
	f, _ := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(reqLine(n, 200, "/3") + "\n" + reqLine(n, 200, "/4")[:20])
	time.Sleep(400 * time.Millisecond)
	f.WriteString(reqLine(n, 200, "/4")[20:] + "\n" + reqLine(n, 200, "/5-before-roll") + "\n")
	f.Close()
	// Caddy's roll: rename, new file
	os.Rename(p, h.path("log/tando/req/access-1.log"))
	os.WriteFile(p, []byte(reqLine(n, 200, "/6-new")+"\n"), 0o644)
	time.Sleep(1200 * time.Millisecond)
	cancel()
	<-done
	var paths []string
	for l := range strings.SplitSeq(strings.TrimSuffix(b.String(), "\n"), "\n") {
		paths = append(paths, strings.Split(l, "\t")[5])
	}
	if strings.Join(paths, " ") != "/2 /3 /4 /5-before-roll /6-new" {
		t.Fatalf("%q", b.String())
	}
}

func TestTailFromTheEnd(t *testing.T) {
	h := newHost(t)
	h.app("req")
	for _, c := range []struct {
		lines   int
		partial bool
	}{{0, true}, {1, false}, {1, true}, {5, false}, {5, true}, {40, false}} {
		var ls []string
		for i := 0; i < c.lines; i++ {
			ls = append(ls, reqLine(float64(h.now-int64(i)), 200+i, fmt.Sprintf("/%d", i)))
		}
		content := strings.Join(ls, "\n")
		if len(ls) > 0 && !c.partial {
			content += "\n"
		}
		if c.partial {
			content += `{"partial` + "\n" + reqLine(float64(h.now), 500, "/last")
		}
		h.write("log/tando/req/access-0.log", reqLine(float64(h.now-9999), 404, "/older")+"\n")
		os.Chtimes(h.path("log/tando/req/access-0.log"), time.Unix(h.now-9999, 0), time.Unix(h.now-9999, 0))
		h.write("log/tando/req/access.log", content)
		a, _ := h.l.app("req")
		for _, n := range []int{1, 2, 3, 5, 6, 7, 41, 100} {
			got, _ := h.rows(func(w *out.Writer) error { return h.l.ReqTail(ctx(), "req", fmt.Sprint(n), "", w, nil) })
			files := a.reqFiles(0)
			want, _ := h.rows(func(w *out.Writer) error { lastRows(files, n, reqlog.RowFilter{}, true, w); return nil })
			closeAll(files)
			if got != want {
				t.Fatalf("%d lines (partial %v), n %d:\n%s---\n%s", c.lines, c.partial, n, got, want)
			}
		}
	}
}
