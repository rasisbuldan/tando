package logs

import (
	"os"
	"strconv"
	"strings"
	"testing"

	"tando/srv/internal/out"
)

func TestScan(t *testing.T) {
	h := newHost(t)
	h.app("boom")
	h.write("opt/apps/boom/state", "phase=x\ncurrent=20261115-013512\n")
	h.app("idle")
	h.write("opt/apps/idle/state", "current=\n")
	h.write("etc/systemd/journald@tando-boom.conf", "x")
	h.write("opt/apps/boom/history.tsv", "1794580010\t20261115-013512\tdeploy\tok\t9\t-\t-\t1\t2\t0\t3\t-\n")
	ts := func(d int64) string { return strconv.FormatInt(h.now-d, 10) + ".000001 host node[7]: " }
	journal := ts(60) + "ERROR db timeout after 100 ms\n-- cursor: s=one\n"
	h.cmd = func(argv []string) (string, error) { return journal, nil }
	h.access("boom", "access.log", h.now, false, reqLine(float64(h.now), 500, "/api/fail/1"))
	scan := func() string {
		o, err := h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), nil, w) })
		if err != nil {
			t.Fatal(err)
		}
		return o
	}
	// the first scan learns: no newerr, no errtop, no error events counted (they are the last
	// 24 hours', not this minute's); the request log starts at its end
	o := scan()
	if o != "release\tboom\t20261115-013512\t1794580007\nscan\tboom\t1\t0\t0\t0\t0\t0\t0\n" {
		t.Fatalf("%q", o)
	}
	if !strings.Contains(h.argvs("journalctl")[0], "--since=-24h") || func() bool { c, _ := scanPosition(h.path("lib/logscan/boom"), nil); return c != "s=one" }() {
		t.Fatal(h.argvs("journalctl"), h.read("lib/logscan/boom/cursor"))
	}
	fi, _ := os.Stat(h.path("lib/logscan/boom/req"))
	// one group, and the cursor its counts reach (written with them)
	if g := h.read("lib/logscan/boom/groups.tsv"); strings.Count(g, "\n") != 2 || !strings.HasSuffix(g, "\ncursor\ts=one\n") || fi == nil {
		t.Fatalf("%q", g)
	}
	// new errors after the first scan are reported once; samples are kept
	journal = ts(30) + "TypeError: x is null\n" + ts(30) + "    at handler (/opt/tando/apps/boom/releases/20261115-013512/server.js:4:9)\n" +
		ts(20) + "ERROR db timeout after 101 ms\n" + ts(10) + "ERROR db timeout after 102 ms\n-- cursor: s=two\n"
	f, _ := os.OpenFile(h.path("log/tando/boom/access.log"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(reqLine(float64(h.now), 500, "/api/fail/2") + "\n" + reqLine(float64(h.now), 200, "/ok") + "\n" + `{"partial`)
	f.Close()
	o = scan()
	rows := strings.Split(strings.TrimSuffix(o, "\n"), "\n")
	if len(rows) != 5 || !strings.HasPrefix(rows[0], "newerr\tboom\t") || !strings.HasSuffix(rows[0], "\t1\tnode\tTypeError at handler (server.js)") ||
		!strings.HasPrefix(rows[1], "errtop\tboom\t2\terror line [") || rows[3] != "top\tboom\t1\t500\tGET /api/fail/:n" ||
		rows[4] != "scan\tboom\t4\t3\t0\t2\t1\t13\t0" {
		t.Fatalf("%q", rows)
	}
	if !strings.Contains(h.argvs("journalctl")[1], "--after-cursor=s=one") {
		t.Fatal(h.argvs("journalctl"))
	}
	id := strings.Split(rows[0], "\t")[2]
	if s := h.read("lib/logscan/boom/samples/" + id); s != "TypeError: x is null\n    at handler (/opt/tando/apps/boom/releases/20261115-013512/server.js:4:9)\n" {
		t.Fatalf("%q", s)
	}
	// the partial line waits for its newline; a roll starts the new file from its start
	req := strings.Fields(h.read("lib/logscan/boom/req"))
	if fi, _ := os.Stat(h.path("log/tando/boom/access.log")); req[1] != strconv.FormatInt(fi.Size()-int64(len(`{"partial`)), 10) {
		t.Fatal(req)
	}
	os.Rename(h.path("log/tando/boom/access.log"), h.path("log/tando/boom/access-1.log"))
	h.access("boom", "access.log", h.now, false, reqLine(float64(h.now), 502, "/after/roll"))
	journal = "-- cursor: s=three\n"
	o = scan()
	if o != "top\tboom\t1\t502\tGET /after/roll\nscan\tboom\t0\t0\t0\t1\t1\t13\t0\n" {
		t.Fatalf("%q", o)
	}
	// errors: the scan first, then the groups of the window, newest first, with samples
	o, err := h.rows(func(w *out.Writer) error { return h.l.Errors(ctx(), "boom", "", "", w) })
	rows = strings.Split(strings.TrimSuffix(o, "\n"), "\n")
	if err != nil || len(rows) != 5 || !strings.HasPrefix(rows[0], "err\t") || !strings.Contains(rows[0], "\t3\t3\t") ||
		!strings.HasPrefix(rows[2], "sample\t") {
		t.Fatalf("%q %v", rows, err)
	}
	_, err = h.rows(func(w *out.Writer) error { return h.l.Errors(ctx(), "boom", "1d", "", w) })
	wantErr(t, err, "bad window or count")
	_, err = h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), []string{"nope", "boom"}, w) })
	if err != nil || !strings.Contains(h.stderr.String(), "tando-logs: no such app: nope") {
		t.Fatal(err, h.stderr.String())
	}
}

// the request numbers come from the index: the first scan learns where it ends (the history is
// indexed, not reported), later ones count what was written since, all of it (no cap)
func TestScanFromIndex(t *testing.T) {
	h := newHost(t)
	h.app("big")
	h.write("log/tando/big/access.log", strings.Repeat(reqLine(float64(h.now), 200, "/x")+"\n", 40000))
	h.write("lib/logscan/big/req", "0 0\n") // a shell scan's position: not used any more
	o, _ := h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), []string{"big"}, w) })
	if o != "scan\tbig\t0\t0\t0\t0\t0\t0\t0\n" {
		t.Fatalf("%q", o)
	}
	f, _ := os.OpenFile(h.path("log/tando/big/access.log"), os.O_APPEND|os.O_WRONLY, 0)
	f.WriteString(strings.Repeat(reqLine(float64(h.now), 503, "/y/1")+"\n", 30000))
	f.Close()
	o, _ = h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), []string{"big"}, w) })
	if o != "top\tbig\t30000\t503\tGET /y/:n\nscan\tbig\t0\t0\t0\t30000\t30000\t13\t0\n" {
		t.Fatalf("%q", o)
	}
	fi, _ := os.Stat(h.path("log/tando/big/access.log"))
	if r := strings.Fields(h.read("lib/logscan/big/req")); len(r) != 2 || r[1] != strconv.FormatInt(fi.Size(), 10) {
		t.Fatalf("the shell's position file is kept for a downgrade: %q", r)
	}
}

// an idle app: unchanged journal files, no journalctl
func TestScanIdleJournal(t *testing.T) {
	h := newHost(t)
	h.app("idle")
	h.write("etc/systemd/journald@tando-idle.conf", "x")
	h.write("log/journal/"+machineID+".tando-idle/system.journal", "j1")
	h.cmd = func([]string) (string, error) { return "-- cursor: s=1\n", nil }
	scan := func() { h.rows(func(w *out.Writer) error { return h.l.WatchScan(ctx(), []string{"idle"}, w) }) }
	scan() // learns
	scan() // the stamp is saved with the cursor
	n := len(h.argvs("journalctl"))
	scan()
	if len(h.argvs("journalctl")) != n {
		t.Fatal("journalctl ran for an unchanged journal")
	}
	h.write("log/journal/"+machineID+".tando-idle/system.journal", "j2 more")
	scan()
	if len(h.argvs("journalctl")) != n+1 {
		t.Fatal("journalctl did not run after a write")
	}
}
