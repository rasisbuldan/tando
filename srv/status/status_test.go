package status

import (
	"bytes"
	"context"
	"io"
	"os"
	"strings"
	"testing"

	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
)

// (then the server row: the clock and the first line of VERSION, "unknown" without the file)
const hostRow = "host\tbox\t3\t0.52\t2048000000\t512000000\t1024000\t409600\t5000\nserver\t1800000000\tunknown"

func running(start string) map[string]string {
	return map[string]string{"ActiveState": "active", "MemoryMax": "134217728", "CPUUsageNSec": "2500000000",
		"NRestarts": "2", "ActiveEnterTimestampMonotonic": start}
}

func TestStatusAll(t *testing.T) {
	h := newHost(t)
	h.euid = 0
	h.program("tando-logs")
	h.program("tando-watch")
	h.app("web", "port=4100\nrecipe=node\nbackup=daily\ndatabase=postgres\ndomains=shop.example.com|redirect www.x.org|off\ncpu=50%\ntasks=200\n",
		"current=20261114-170102\nstatus_20261114-170102=verified\nlast_backup=20261115-030000-daily\nphase=idle\n")
	h.units["tando-web.service"] = running("3000000000") // up 2000 s
	os.MkdirAll(h.path("cgroup/tando.slice/tando-web.slice/tando-web.service"), 0o755)
	h.write("cgroup/tando.slice/tando-web.slice/tando-web.service/memory.stat", "anon 1000\nfile 99999\nshmem 24\nanon_thp 5\n")
	// stopped by the user; its unit is inactive
	h.app("halt", "port=4101\nrecipe=node\n", "current=20261114-170102\nstatus_20261114-170102=verified\nstopped=1\n")
	// systemd gave up on it (down), an old unit under system.slice
	h.app("crash", "port=4102\n", "current=20261114-170102\ndown=1\n")
	h.units["tando-crash.service"] = map[string]string{"ActiveState": "failed", "MemoryMax": "infinity", "CPUUsageNSec": "[not set]", "NRestarts": "9"}
	h.write("cgroup/system.slice/tando-crash.service/memory.stat", "anon 7\n")
	// deploying
	h.app("dep", "port=4103\nrecipe=next\npath=/demo\n", "phase=soak\ntarget=x\n")
	h.units["tando-dep.service"] = running("0")
	// static site: served by Caddy when it has a release
	h.app("site", "port=4104\nrecipe=static\n", "current=20261114-170102\nstatus_20261114-170102=verified\n")
	// adopted: its own link; a damaged state (last line unterminated, NUL byte, no "=")
	h.app("old", "port=4105\ncheck_url=https://old.example.net\npath=/p\nuser=www-data\n", "current=a\x00b\nnoequals\n=empty\nstopped=1")
	// app.conf without port (the shell's set -u dropped this row); a new app without state
	h.app("noport", "recipe=node\n", "")
	// not apps: no app.conf (half-destroyed), a bad name, an unreadable app.conf
	os.MkdirAll(h.path("root/apps/gone/releases"), 0o755)
	h.write("root/apps/Bad_Name/app.conf", "port=1\n")
	h.programs["tando-logs log-stats"] = rows(
		tab("logs", "web", "1000", "64M", "24", "300", "x", "y", "12", "a", "b", "7d", "16M", "app", "z"),
		tab("logs", "crash", "x", "-", "5", "-", "", "", "", "", "", "", "", "", ""),
		tab("other", "site", "1"),
		tab("logs", "dep", "1", "with space", "2", "3", "x", "y", "4"),
	) + "logs\tsite\t9" // unterminated: dropped by read
	h.programs["tando-watch brief"] = "alert\tweb\tmemory\tfiring\t1799999000\t90% of 128M\n"
	// the last minute's CPU from tando-metrics: 30 s of CPU in 60 s = 500 per mille; crash's last
	// sample is 10 minutes old and dep has one line only: "-"
	os.MkdirAll(h.path("lib/metrics"), 0o700)
	h.write("lib/metrics/web.tsv", "1799999880\t1\t9\t2\tr\n1799999940\t1\t30000000\t2\tr\n")
	h.write("lib/metrics/crash.tsv", "1799999340\t1\t9\t2\tr\n1799999400\t1\t30000000\t2\tf\n")
	h.write("lib/metrics/dep.tsv", "1799999940\t1\t30000000\t2\tr\n")
	got, err := h.out(func(c *Collector, b *bytes.Buffer) error { return c.Status(context.Background(), b, "") })
	if err != nil {
		t.Fatal(err)
	}
	eq(t, got, rows(hostRow,
		tab("app", "crash", "failed", "4102", "20261114-170102", "-", "7", "0", "0", "9", "0", "http://crash.example.org:8080", "-", "off", "-", "-", "5", "-", "-", "-", "-", "-", "1024", "256", "-", "-"),
		tab("app", "dep", "deploying", "4103", "-", "-", "0", "134217728", "2500000000", "2", "0", "http://dep.example.org:8080/demo", "next", "off", "-", "-", "3", "with", "space", "3", "4", "-", "-", "1024", "256", "-", "-"),
		tab("app", "halt", "stopped", "4101", "20261114-170102", "verified", "0", "0", "0", "0", "0", "http://halt.example.org:8080", "node", "off", "-", "-", "-", "-", "-", "-", "-", "-", "1024", "256", "-", "-"),
		tab("app", "noport", "inactive", "-", "-", "-", "0", "0", "0", "0", "0", "http://noport.example.org:8080", "node", "off", "-", "-", "-", "-", "-", "-", "-", "-", "1024", "256", "-", "-"),
		tab("app", "old", "inactive", "4105", "ab", "-", "0", "0", "0", "0", "0", "https://old.example.net/p", "-", "off", "-", "-", "-", "-", "-", "-", "-", "-", "1024", "256", "-", "-"),
		tab("app", "site", "active", "4104", "20261114-170102", "verified", "0", "0", "0", "0", "0", "http://site.example.org:8080", "static", "off", "-", "-", "-", "-", "-", "-", "-", "-", "1024", "256", "-", "-"),
		tab("app", "web", "active", "4100", "20261114-170102", "verified", "1024", "134217728", "2500000000", "2", "2000", "http://web.example.org:8080", "node", "daily", "20261115-030000-daily", "postgres", "1024", "64M", "300", "12", "shop.example.com,www.x.org", "50%", "200", "256", "-", "500"),
		"alert\tweb\tmemory\tfiring\t1799999000\t90% of 128M"))
	if n := h.called("systemctl show"); n != 1 {
		t.Errorf("systemctl show ran %d times, want 1", n)
	}
}

func TestStatusNoApps(t *testing.T) {
	h := newHost(t)
	h.program("tando-watch")
	h.programs["tando-watch brief"] = "alert\thost\tdisk\tfiring\t1\tx\n"
	got, err := h.out(func(c *Collector, b *bytes.Buffer) error { return c.Status(context.Background(), b, "") })
	if err != nil {
		t.Fatal(err)
	}
	eq(t, got, rows(hostRow)) // (the shell returned before the alerts when there was no app)
	if len(h.calls) != 0 {
		t.Errorf("ran %v", h.calls)
	}
}

func TestStatusNotRoot(t *testing.T) {
	h := newHost(t)
	h.euid = 1000
	h.program("tando-logs")
	h.app("web", "port=4100\n", "")
	h.app("secret", "port=4101\n", "")
	os.Chmod(h.path("root/apps/secret/app.conf"), 0)
	if f, err := os.Open(h.path("root/apps/secret/app.conf")); err == nil {
		f.Close()
		t.Skip("running as root: every file is readable")
	}
	got, _ := h.out(func(c *Collector, b *bytes.Buffer) error { return c.Status(context.Background(), b, "") })
	eq(t, got, rows(hostRow,
		tab("app", "web", "inactive", "4100", "-", "-", "0", "0", "0", "0", "0", "http://web.example.org:8080", "-", "off", "-", "-", "-", "-", "-", "-", "-", "-", "1024", "256", "-", "-")))
	if h.called(h.path("root/bin/tando-logs")) != 0 {
		t.Error("log-stats ran without root")
	}
}

func TestStatusSystemctlFails(t *testing.T) {
	h := newHost(t)
	h.showFails = true
	h.app("web", "port=4100\n", "")
	got, _ := h.out(func(c *Collector, b *bytes.Buffer) error { return c.Status(context.Background(), b, "") })
	eq(t, got, rows(hostRow,
		tab("app", "web", "inactive", "4100", "-", "-", "0", "0", "0", "0", "0", "http://web.example.org:8080", "-", "off", "-", "-", "-", "-", "-", "-", "-", "-", "1024", "256", "-", "-")))
	if !strings.Contains(h.stderr.String(), "tando-agent: systemctl: Failed to connect to bus") {
		t.Errorf("stderr %q", h.stderr.String())
	}
}

func TestStatusOne(t *testing.T) {
	h := newHost(t)
	h.euid = 0
	for _, p := range []string{"tando-logs", "tando-watch", "tando-metrics"} {
		h.program(p)
	}
	h.write("root/host.conf", "apps_domain=example.org\ntls=auto\n")
	h.app("web", "port=4100\ndomains=shop.example.com|redirect deep.a.example.com|off\n",
		"current=20261114-170102\nlast_good=20261114-170102\nstatus_20261114-170102=verified\nseq_20261114-170102=2\n"+
			"status_20261113-100000=bad\nseq_20261113-100000=1\nstatus_20261115-090000-2=rolledback\nseq_20261115-090000-2=10\n")
	h.app("other", "port=4101\n", "")
	for _, id := range []string{"20261114-170102", "20261113-100000", "20261115-090000-2", "20261101-000000", "junk", ".hidden"} {
		os.MkdirAll(h.path("root/apps/web/releases/"+id), 0o755)
	}
	h.write("root/apps/web/history.tsv", strings.Repeat("1\tbad line\n", 3)+
		tab("1799990000", "20261113-100000", "deploy", "failed", "3.1", "0", "0", "-", "-", "-", "-", "boom\x1b[31m")+"\n"+
		"short\tline\n"+
		tab("1799990100", "20261114-170102", "deploy", "ok", "9.0", "1.0", "0.5", "1", "2", "0.1", "3", "")+"\n")
	h.write("certs/acme-v02.example-directory/shop.example.com/shop.example.com.crt", testCert(t, 1_900_000_000))
	h.programs["tando-logs log-stats web"] = tab("logs", "web", "10", "64M", "5", "300", "x", "y", "12", "a", "b", "7d", "16M", "app") + "\n"
	h.programs["tando-metrics read web 16 60"] = "mx\t60\t1800000000\nm\t1799999940\t100\t5\t0\tr\n"
	h.programs["tando-watch brief web"] = ""
	h.programs["tando-watch brief web #stderr"] = "tando-watch: cannot read state\n"
	got, err := h.out(func(c *Collector, b *bytes.Buffer) error { return c.Status(context.Background(), b, "web") })
	if err != nil {
		t.Fatal(err)
	}
	eq(t, got, rows(hostRow,
		tab("app", "web", "inactive", "4100", "20261114-170102", "verified", "0", "0", "0", "0", "0", "https://web.example.org", "-", "off", "-", "-", "15", "64M", "300", "12", "shop.example.com,deep.a.example.com", "-", "1024", "256", "-", "-"),
		tab("logcfg", "web", "7d", "16M", "app"),
		tab("rel", "20261115-090000-2", "rolledback", "0", "0"),
		tab("rel", "20261114-170102", "verified", "1", "1"),
		tab("rel", "20261113-100000", "bad", "0", "0"),
		tab("rel", "20261101-000000", "pending", "0", "0"),
		tab("hist", "web", "1799990000", "20261113-100000", "deploy", "failed", "3.1", "0", "0", "-", "-", "-", "-", "boom?[31m"),
		tab("hist", "web", "1799990100", "20261114-170102", "deploy", "ok", "9.0", "1.0", "0.5", "1", "2", "0.1", "3", ""),
		tab("domain", "shop.example.com", "redirect", "1900000000"),
		tab("domain", "deep.a.example.com", "off", "-"),
		"mx\t60\t1800000000",
		"m\t1799999940\t100\t5\t0\tr"))
	eq(t, h.stderr.String(), "tando-watch: cannot read state\n")
	if n := h.called("systemctl show"); n != 1 {
		t.Errorf("systemctl show ran %d times", n)
	}
}

// With offsite copies on, one app's status has an offsite row from tando-offsite's state file
// (the agent's shell fallback prints the same); off (or no file): none.
func TestStatusOffsiteRow(t *testing.T) {
	h := newHost(t)
	h.euid = 0
	h.write("root/host.conf", "apps_domain=example.org\n")
	h.app("web", "port=4100\n", "")
	h.write("lib/offsite/state/web", "enabled=1\nalert_hours=6\npending=2\noldest_pending=1799990000\nlast_upload=1799980000\ncreds=ok\nerror=\n")
	got, err := h.out(func(c *Collector, b *bytes.Buffer) error { return c.Status(context.Background(), b, "web") })
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "\noffsite\t1799980000\t2\t1799990000\t6\tok\t-\n") {
		t.Fatalf("no offsite row:\n%s", got)
	}
	h.write("lib/offsite/state/web", "enabled=0\n")
	got, _ = h.out(func(c *Collector, b *bytes.Buffer) error { return c.Status(context.Background(), b, "web") })
	if strings.Contains(got, "offsite") {
		t.Fatalf("offsite row while off:\n%s", got)
	}
}

func TestStatusErrors(t *testing.T) {
	h := newHost(t)
	os.MkdirAll(h.path("root/apps/half"), 0o755)
	for _, c := range []struct{ app, want string }{
		{"Bad", "invalid app name"},
		{"../x", "invalid app name"},
		{"nope", "no such app: nope"},
		{"half", "the directory of half is incomplete (no app.conf): tando destroy -a half removes it, or tando up recreates it"},
	} {
		got, err := h.out(func(co *Collector, b *bytes.Buffer) error { return co.Status(context.Background(), b, c.app) })
		if err == nil || err.Error() != c.want || !isDie(err) || got != "" {
			t.Errorf("%s: %q %v", c.app, got, err)
		}
	}
}

// As root, a half-deleted app directory gets its skeleton back.
func TestSkeleton(t *testing.T) {
	h := newHost(t)
	h.write("root/apps/web/app.conf", "port=1\n")
	h.euid = 1000
	h.out(func(c *Collector, b *bytes.Buffer) error { return c.Releases(context.Background(), b, "web") })
	if fsinfo.ExistsFollow(h.path("root/apps/web/releases")) {
		t.Fatal("a caller without root made releases/")
	}
	h.euid = 0
	h.out(func(c *Collector, b *bytes.Buffer) error { return c.Releases(context.Background(), b, "web") })
	for _, d := range []string{"releases", "incoming"} {
		if fi, err := os.Stat(h.path("root/apps/web/" + d)); err != nil || !fi.IsDir() || fi.Mode().Perm() != 0o755 {
			t.Errorf("%s: %v %v", d, fi, err)
		}
	}
}

func TestReleasesOrder(t *testing.T) {
	S := parseKV([]byte("seq_20261101-000003=10\nseq_20261101-000002=9\nseq_20261101-000004=x\nseq_20261101-000005=-1\n" +
		"seq_20261101-000006=009\nseq_20261101-000007= 3\ncurrent=20261101-000003\nlast_good=20261101-000002\n"))
	ids := []string{"20261101-000003", "20261101-000002", "20261101-000004", "20261101-000005", "20261101-000006", "20261101-000007", "20261101-000001"}
	var got []string
	for _, r := range ReleaseRows(S, ids) {
		got = append(got, r[1]+":"+r[3]+r[4])
	}
	// sort -k1,1n -k2,2: -1, then 0 (x, none) by id, 3, 9, 009 by id, 10; newest first
	want := "20261101-000003:10 20261101-000006:00 20261101-000002:01 20261101-000007:00 20261101-000004:00 20261101-000001:00 20261101-000005:00"
	if strings.Join(got, " ") != want {
		t.Errorf("got  %s\nwant %s", strings.Join(got, " "), want)
	}
}

func TestHistory(t *testing.T) {
	h := newHost(t)
	line := func(id string) string {
		return tab("1799990000", id, "deploy", "ok", "1", "0", "0", "1", "2", "3", "4", "note")
	}
	h.write("root/apps/web/history.tsv", line("20261101-000001")+"\n"+line("20261101-000002")+"\n"+line("20261101-000003"))
	h.write("root/apps/api/history.tsv", line("20261101-000009")+"\n")
	h.write("root/apps/api/app.conf", "port=1\n")
	h.write("root/apps/Bad/history.tsv", line("20261101-000009")+"\n")
	all, err := h.out(func(c *Collector, b *bytes.Buffer) error { return c.History(context.Background(), b, "", "") })
	if err != nil {
		t.Fatal(err)
	}
	eq(t, all, rows("hist\tapi\t"+line("20261101-000009"), "hist\tweb\t"+line("20261101-000001"),
		"hist\tweb\t"+line("20261101-000002"), "hist\tweb\t"+line("20261101-000003")))
	two, _ := h.out(func(c *Collector, b *bytes.Buffer) error { return c.History(context.Background(), b, "web", "02") })
	eq(t, two, rows("hist\tweb\t"+line("20261101-000002"), "hist\tweb\t"+line("20261101-000003")))
	none, _ := h.out(func(c *Collector, b *bytes.Buffer) error { return c.History(context.Background(), b, "web", "0") })
	eq(t, none, "")
	// a deploy that ran a release command has a 13th field, its seconds; 11 or 14 fields: no record
	rel := line("20261101-000004") + "\t0.3"
	h.write("root/apps/web/history.tsv", rel+"\n"+rel+"\textra\n"+strings.TrimSuffix(line("20261101-000005"), "\tnote")+"\n")
	thirteen, _ := h.out(func(c *Collector, b *bytes.Buffer) error { return c.History(context.Background(), b, "web", "") })
	eq(t, thirteen, rows("hist\tweb\t"+rel))
	big, _ := h.out(func(c *Collector, b *bytes.Buffer) error {
		return c.History(context.Background(), b, "nosuch", "99999999999999999999999")
	})
	eq(t, big, "")
	for _, c := range []struct{ app, n, want string }{{"web", "-1", "bad count"}, {"web", "1x", "bad count"}, {"Bad", "x", "bad count"}, {"Bad", "5", "invalid app name"}} {
		_, err := h.out(func(co *Collector, b *bytes.Buffer) error { return co.History(context.Background(), b, c.app, c.n) })
		if err == nil || err.Error() != c.want {
			t.Errorf("%s %s: %v", c.app, c.n, err)
		}
	}
}

func TestTailLines(t *testing.T) {
	h := newHost(t)
	var b strings.Builder
	for i := 0; i < 5000; i++ {
		b.WriteString(strings.Repeat("x", i%37) + "\t" + decimal.Itoa(int64(i)) + "\n")
	}
	h.write("f", b.String())
	all := strings.Split(strings.TrimSuffix(b.String(), "\n"), "\n")
	for _, n := range []int64{1, 2, 100, 999, 4999, 5000, 9000} {
		got := tailLines(h.path("f"), n, maxHistTail)
		want := all[max(0, int64(len(all))-n):]
		if strings.Join(got, "\n") != strings.Join(want, "\n") {
			t.Errorf("n=%d: %d lines, want %d", n, len(got), len(want))
		}
	}
	h.write("g", "a\nb\nc") // the unterminated last line counts
	eq(t, strings.Join(tailLines(h.path("g"), 2, maxHistTail), ","), "b,c")
	h.write("e", "")
	if l := tailLines(h.path("e"), 3, maxHistTail); len(l) != 0 {
		t.Errorf("empty: %q", l)
	}
}

type fakeRows struct{ calls []string }

func (f *fakeRows) LogStats(ctx context.Context, app string, w io.Writer) {
	f.calls = append(f.calls, "logs "+app)
	io.WriteString(w, tab("logs", "web", "10", "64M", "5", "300", "x", "y", "12", "a", "b", "7d", "16M", "app")+"\n")
}
func (f *fakeRows) Brief(ctx context.Context, app string, w io.Writer) {
	f.calls = append(f.calls, "brief "+app)
	io.WriteString(w, "alert\tweb\tdown\tfiring\t1\tx\n")
}
func (f *fakeRows) Trend(ctx context.Context, app string, w io.Writer) {
	f.calls = append(f.calls, "trend "+app)
	io.WriteString(w, "mx\t60\t1\n")
}

// In-process rows (tandod): the same output, and no program started but systemctl.
func TestStatusRowsInProcess(t *testing.T) {
	h := newHost(t)
	h.euid = 0
	for _, p := range []string{"tando-logs", "tando-watch", "tando-metrics"} {
		h.program(p)
	}
	h.app("web", "port=4100\n", "")
	f := &fakeRows{}
	run := func(app string) string {
		got, err := h.out(func(c *Collector, b *bytes.Buffer) error {
			c.LogRows, c.AlertRows, c.TrendRows = f, f, f
			return c.Status(context.Background(), b, app)
		})
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	got := run("web")
	eq(t, got, rows(hostRow,
		tab("app", "web", "inactive", "4100", "-", "-", "0", "0", "0", "0", "0", "http://web.example.org:8080", "-", "off", "-", "-", "15", "64M", "300", "12", "-", "-", "1024", "256", "-", "-"),
		tab("logcfg", "web", "7d", "16M", "app"),
		"mx\t60\t1", "alert\tweb\tdown\tfiring\t1\tx"))
	run("")
	if strings.Join(f.calls, ",") != "logs web,trend web,brief web,logs ,brief " {
		t.Errorf("calls %v", f.calls)
	}
	for _, c := range h.calls {
		if !strings.HasPrefix(c, "systemctl") {
			t.Errorf("started %s", c)
		}
	}
}

// host care's counts (tando-host's summary file) follow the host row; a summary of another
// format or none at all: no row
func TestStatusHostcare(t *testing.T) {
	h := newHost(t)
	h.write("lib/hostcare/summary", "# tando-host summary, format 1 (docs/HOSTCARE.md)\nsummary\t1\t1800000000\t1799990000\t3\t1\t2\tbox\nalert\tupdates\tok\t0\tnormal\t0\t-\n")
	got, err := h.out(func(c *Collector, b *bytes.Buffer) error { return c.Status(context.Background(), b, "") })
	if err != nil {
		t.Fatal(err)
	}
	eq(t, got, rows(hostRow, tab("hostcare", "3", "1", "2", "1800000000")))
	h.write("lib/hostcare/summary", "summary\t2\t1\t1\t3\t1\t2\tbox\n")
	got, _ = h.out(func(c *Collector, b *bytes.Buffer) error { return c.Status(context.Background(), b, "") })
	eq(t, got, rows(hostRow))
}

// An app whose restore was cut off while it replaced the database has one restorecut row after its
// app row: the backup to restore again, the safety backup, what was being replaced (the agent's
// restore_cut_row); without restore_cut in its state there is none.
func TestStatusRestoreCut(t *testing.T) {
	h := newHost(t)
	h.euid = 0
	h.write("root/host.conf", "apps_domain=example.org\ntls=auto\n")
	h.app("web", "port=4100\n", "current=20261114-170102\nstatus_20261114-170102=verified\n"+
		"restore_cut=the restore stopped\nrestore_cut_id=20261114-180000-manual\nrestore_cut_safety=20261114-180100-safety\nrestore_cut_what=database\n")
	h.app("other", "port=4101\n", "")
	got, err := h.out(func(c *Collector, b *bytes.Buffer) error { return c.Status(context.Background(), b, "") })
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "\nrestorecut\tweb\t20261114-180000-manual\t20261114-180100-safety\tdatabase\n") ||
		strings.Count(got, "restorecut") != 1 {
		t.Fatalf("want one restorecut row for web, got:\n%s", got)
	}
}

// the server row: the clock and the first line of VERSION, for the client's skew line
func TestStatusServerRow(t *testing.T) {
	h := newHost(t)
	h.write("root/VERSION", "1.4.2\nsomething else\n")
	got, err := h.out(func(c *Collector, b *bytes.Buffer) error { return c.Status(context.Background(), b, "") })
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "\nserver\t1800000000\t1.4.2\n") {
		t.Errorf("no server row with the version: %q", got)
	}
}
