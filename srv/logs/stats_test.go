package logs

import (
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"slices"
	"strconv"
	"strings"
	"testing"

	"tando/srv/internal/out"
	"tando/srv/logs/lines"
)

func goldenFile(t *testing.T, name string) []byte {
	f, err := os.Open("testdata/golden/" + name + ".gz")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	z, _ := gzip.NewReader(f)
	b, _ := io.ReadAll(z)
	return b
}

// the per-hour counts of the shell's AWK_STATS over the same short-unix lines
func TestGoldenStats(t *testing.T) {
	h := hourly{}
	cur := ""
	r := lines.NewReader(bytes.NewReader(goldenFile(t, "journal.short")), 64<<10)
	for {
		ln, ok := r.Next()
		if !ok {
			break
		}
		if lines.HasPrefix(ln.Text, "-- cursor: ") {
			cur = string(ln.Text[11:])
			continue
		}
		countLine(ln.Text, ln.Len, h)
	}
	var got []string
	for hr, c := range h {
		if c[0] > 0 {
			got = append(got, "H "+strconv.FormatInt(hr, 10)+" "+strconv.FormatInt(c[0], 10)+" "+strconv.FormatInt(c[1], 10))
		}
		if c[2] > 0 {
			got = append(got, "S "+strconv.FormatInt(hr, 10)+" "+strconv.FormatInt(c[2], 10))
		}
	}
	got = append(got, "C "+cur)
	slices.Sort(got)
	want := strings.Split(strings.TrimSuffix(string(goldenFile(t, "out-stats.out")), "\n"), "\n")
	if !slices.Equal(got, want) {
		t.Fatalf("got %q\nwant %q", got, want)
	}
}

func TestLogStats(t *testing.T) {
	h := newHost(t)
	h.app("flood", "log_max=16M", "log_keep=2d")
	h.write("etc/systemd/journald@tando-flood.conf", "x")
	h.write("log/journal/"+machineID+".tando-flood/system.journal", strings.Repeat("j", 5000))
	h.write("log/tando/flood/access.log", "x")
	hour := h.now / 3600 * 3600
	h.write("cache/flood.stats", "cursor s=old\nupdated "+strconv.FormatInt(h.now-120, 10)+"\nH "+strconv.FormatInt(hour, 10)+
		" 10 100\nH 5 1 1\nS "+strconv.FormatInt(hour-3600, 10)+" 4\n")
	h.cmd = func([]string) (string, error) {
		return strconv.FormatInt(h.now-5, 10) + ".5 host node[7]: hello\n" + strconv.FormatInt(h.now-4, 10) +
			".5 host systemd-journald[9]: Suppressed 7 messages from tando-flood.service\n-- cursor: s=new\n", nil
	}
	o, err := h.rows(func(w *out.Writer) error { return h.l.LogStats(ctx(), "flood", w) })
	f := strings.Split(strings.TrimSuffix(o, "\n"), "\t")
	if err != nil || len(f) != 14 || f[0] != "logs" || f[1] != "flood" || f[3] != "16777216" || f[5] != "11" || f[6] != "105" ||
		f[7] != "11" || f[10] != "0" || f[11] != "48" || f[12] != "4194304" || f[13] != "app" || !strings.HasSuffix(f[8], ",0,11") {
		t.Fatalf("%q %v", f, err)
	}
	if !strings.Contains(h.argvs("journalctl")[0], "--namespace=tando-flood --after-cursor=s=old -n 300000") {
		t.Fatal(h.argvs("journalctl"))
	}
	if c := h.read("cache/flood.stats"); !strings.HasPrefix(c, "cursor s=new\nupdated 1794590000\n") || strings.Contains(c, "H 5 ") {
		t.Fatalf("%q", c)
	}
	// within a minute: served from the cache
	h.calls = nil
	h.now += 30
	o, _ = h.rows(func(w *out.Writer) error { return h.l.LogStats(ctx(), "", w) })
	if len(h.argvs("journalctl")) != 0 || !strings.Contains(o, "\t30\t48\t") {
		t.Fatal(o, h.calls)
	}
}

func TestLogDoctor(t *testing.T) {
	h := newHost(t)
	h.app("aa", "log_max=16M", "request_log_max=8M")
	h.app("bb")
	h.write("etc/systemd/journald@tando-aa.conf", "x")
	h.cmd = func([]string) (string, error) {
		return "Archived and active journals take up 24.0M in the file system.\n", nil
	}
	o, _ := h.rows(func(w *out.Writer) error { h.l.LogDoctor(ctx(), w); return nil })
	// (the log budget row between them: its size is the test file system's)
	if !strings.HasPrefix(o, "check\twarn\tmain journal\tno tando cap: run tando host setup\ncheck\twarn\tapp logs\tno log cap yet for: bb (tando up applies it)\ncheck\tok\tlog budget\t24 MB of ") ||
		!strings.Contains(o, " MB (log_budget) for 2 apps\ncheck\tok\tlog caps\t24 MB of app log caps (0 MB used), ") {
		t.Fatalf("%q", o)
	}
	h.write("etc/systemd/journald.conf.d/tando.conf", "x")
	h.write("etc/systemd/journald@tando-bb.conf", "x")
	h.write("opt/logs.conf", "journal_max=0128M\n")
	o, _ = h.rows(func(w *out.Writer) error { h.l.LogDoctor(ctx(), w); return nil })
	if !strings.HasPrefix(o, "check\tok\tmain journal\tcapped at 128M (24.0M used)\ncheck\tok\tapp logs\t2 apps in their own capped journals\n") {
		t.Fatalf("%q", o)
	}
}
