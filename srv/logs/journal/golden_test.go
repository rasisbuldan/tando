package journal

import (
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"tando/srv/logs/lines"
)

// Golden files: the shell version's AWK_JOURNAL under mawk over generated journalctl -o json
// entries (../testdata/golden/gen.py, run.sh): byte arrays, escapes, levels in the text, units of
// other apps, PID 1 lines.

func golden(t *testing.T, name string) []byte {
	t.Helper()
	f, err := os.Open(filepath.Join("..", "testdata", "golden", name+".gz"))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	z, err := gzip.NewReader(f)
	if err != nil {
		t.Fatal(err)
	}
	b, err := io.ReadAll(z)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

const t0 = 1794587950

func TestGoldenQueries(t *testing.T) {
	roles := map[string]string{"tando-boom.service": "app", "systemd-journald@tando-boom.service": "journald",
		"tando-boom-job-backup.service": "job:backup"}
	fixed := func(p string) func([]byte) bool { return func(m []byte) bool { return bytes.Contains(m, []byte(p)) } }
	ifixed := func(p string) func([]byte) bool {
		return func(m []byte) bool { return bytes.Contains(bytes.ToLower(m), []byte(p)) }
	}
	re := func(p string) func([]byte) bool { return regexp.MustCompile(p).Match }
	for _, c := range []struct {
		name string
		f    Filter
	}{
		{"text", Filter{Level: -1, TZS: "+00:00"}},
		{"json", Filter{JSON: true, Level: -1, Cursor: true, TZOff: 25200, TZS: "+07:00"}},
		{"lvl3", Filter{Level: 3, TZOff: -18000, TZS: "-05:00"}},
		{"lvl4json", Filter{JSON: true, Level: 4, TZS: "+00:00"}},
		{"fixed", Filter{Level: -1, Match: fixed("Alpha"), TZS: "+00:00"}},
		{"ifixed", Filter{Level: -1, Match: ifixed("alpha"), Cursor: true, TZS: "+00:00"}},
		{"regex", Filter{Level: -1, Match: re(`^A[0-9] (alpha|Alpha)|ERR?OR [a-z]+$`), TZS: "+00:00"}},
		{"iregex", Filter{JSON: true, Level: -1, Match: re(`(?i)alpha (beta|x)`), TZS: "+00:00"}},
		{"ranges", Filter{Level: -1, TZS: "+00:00", Ranges: [][2]float64{{(t0 - 500) * 1e6, (t0 - 300) * 1e6}, {(t0 - 200) * 1e6, (t0 - 100) * 1e6}}}},
	} {
		t.Run(c.name, func(t *testing.T) {
			f := c.f
			f.Roles = roles
			p := NewParser()
			var e Entry
			var b, buf []byte
			r := lines.NewReader(bytes.NewReader(golden(t, "journal.json")), 1<<20)
			for {
				ln, ok := r.Next()
				if !ok {
					break
				}
				if !p.Parse(ln.Text, &e) {
					t.Fatalf("not parsed: %q", ln.Text)
				}
				var shown bool
				if buf, _, shown = f.Line(buf[:0], &e); shown {
					b = append(append(b, buf...), '\n')
				}
			}
			want := golden(t, "out-journal."+c.name)
			if !bytes.Equal(b, want) {
				g, w := strings.Split(string(b), "\n"), strings.Split(string(want), "\n")
				for i := range max(len(g), len(w)) {
					if i >= len(g) || i >= len(w) || g[i] != w[i] {
						t.Fatalf("line %d (%d vs %d)\n got: %q\nwant: %q", i+1, len(g), len(w), at(g, i), at(w, i))
					}
				}
			}
		})
	}
}

func at(s []string, i int) string {
	if i < len(s) {
		return s[i]
	}
	return "<none>"
}
