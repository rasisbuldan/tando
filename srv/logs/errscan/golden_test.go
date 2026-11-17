package errscan

import (
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"tando/srv/logs/lines"
)

// The golden files are the shell version's awk programs run under mawk 1.3.4 (LC_ALL=C, as on the
// server) over hostile generated input: testdata/golden/gen.py makes the input, run.sh the
// outputs (out-*). Group ids are stored on servers and shown to users: they must not change.

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

const (
	t0  = 1794587950
	now = t0 + 3600
)

// scanAll runs the scanner over the corpus and renders what awk printed: E and L lines, and the
// summary (S N V C).
func scanAll(t *testing.T, emit func(Event)) (string, string) {
	var b strings.Builder
	s := &Scanner{Emit: func(e Event) {
		b.WriteString(e.String() + "\n")
		for _, l := range e.Sample {
			b.WriteString("L\t" + e.ID + "\t" + l + "\n")
		}
		if emit != nil {
			emit(e)
		}
	}}
	r := lines.NewReader(bytes.NewReader(golden(t, "journal.short")), MaxMessage+1024)
	for {
		ln, ok := r.Next()
		if !ok {
			break
		}
		s.Line(ln.Text)
	}
	s.End()
	sum := "S " + strconv.FormatInt(s.Suppressed, 10) + "\nN " + strconv.FormatInt(s.Read, 10) + "\nV " +
		strconv.FormatInt(s.Events, 10) + "\n"
	if s.Cursor != "" {
		sum += "C " + s.Cursor + "\n"
	}
	return b.String(), sum
}

func diffLines(t *testing.T, what, got, want string) {
	t.Helper()
	if got == want {
		return
	}
	g, w := strings.Split(got, "\n"), strings.Split(want, "\n")
	for i := 0; i < max(len(g), len(w)); i++ {
		var gl, wl string
		if i < len(g) {
			gl = g[i]
		}
		if i < len(w) {
			wl = w[i]
		}
		if gl != wl {
			t.Fatalf("%s: first difference at line %d (%d vs %d lines)\n got: %q\nwant: %q", what, i+1, len(g), len(w), gl, wl)
		}
	}
}

func TestGoldenScan(t *testing.T) {
	got, sum := scanAll(t, nil)
	diffLines(t, "events and samples", got, string(golden(t, "out-errscan.out")))
	diffLines(t, "summary", sum, string(golden(t, "out-errscan.sum")))
}

func sortedLines(s string, prefixes ...string) []string {
	var out []string
	for l := range strings.SplitSeq(strings.TrimSuffix(s, "\n"), "\n") {
		for _, p := range prefixes {
			if strings.HasPrefix(l, p) {
				out = append(out, l)
			}
		}
	}
	slices.Sort(out)
	return out
}

func TestGoldenMerge(t *testing.T) {
	rels := []Switch{{t0 - 100, "20261115-013512"}, {t0 + 2000, "20261116-090000-2"}}
	for _, c := range []struct {
		name string
		base bool
		max  int
	}{{"base0", false, 200}, {"base1", true, 200}, {"max5", false, 5}} {
		t.Run(c.name, func(t *testing.T) {
			tb := &Table{Now: now, Live: "20261116-090000-2", Rels: rels, Base: c.base, Max: c.max}
			tb.Load(golden(t, "groups.tsv"))
			scanAll(t, tb.Add)
			r := tb.Result()
			if c.max < 200 {
				// (not the shell's: it dropped by last seen alone; see MaxGroups)
				checkEviction(t, golden(t, "groups.tsv"), r, c.max)
				return
			}
			diffLines(t, "groups.tsv", string(r.Data), string(golden(t, "out-merge."+c.name+".groups")))
			var b strings.Builder
			for _, id := range r.Dropped {
				b.WriteString("DROP\t" + id + "\n")
			}
			for _, g := range r.New {
				b.WriteString("NEW\t" + g.ID + "\t" + strconv.FormatInt(g.T, 10) + "\t" + strconv.FormatInt(g.N, 10) + "\t" + g.Kind + "\t" + g.Label + "\n")
			}
			for _, g := range r.Counts {
				b.WriteString("CNT\t" + g.ID + "\t" + strconv.FormatInt(g.N, 10) + "\t" + g.Label + "\n")
			}
			want := string(golden(t, "out-merge."+c.name+".out"))
			// DROP in order; NEW and CNT came in awk's hash order: compared as sets
			diffLines(t, "dropped", strings.Join(sortedLines(b.String(), "DROP"), "\n"), strings.Join(sortedLines(want, "DROP"), "\n"))
			if g, w := sortedLines(b.String(), "NEW", "CNT"), sortedLines(want, "NEW", "CNT"); !slices.Equal(g, w) {
				diffLines(t, "new and counts", strings.Join(g, "\n"), strings.Join(w, "\n"))
			}
		})
	}
}

func TestGoldenWindow(t *testing.T) {
	data := golden(t, "out-merge.base0.groups")
	for _, c := range []struct{ w, n int64 }{{86400, 20}, {3600, 5}, {999999, 999}} {
		var b strings.Builder
		for _, r := range Window(data, now-c.w, int(c.n)) {
			b.WriteString("err\t" + strings.Join(r, "\t") + "\n")
		}
		diffLines(t, "window", b.String(), string(golden(t, "out-window."+strconv.FormatInt(c.w, 10)+"."+strconv.FormatInt(c.n, 10))))
	}
}

// checkEviction: the groups known before the scan and seen in the last KeepDays days are kept
// before any first seen in it; the rest by last seen; the table stays sorted by last seen.
func checkEviction(t *testing.T, before []byte, r Result, max int) {
	t.Helper()
	known := map[string]bool{}
	for l := range strings.SplitSeq(string(before), "\n") {
		if f := strings.Split(l, "\t"); len(f) >= 10 {
			if n, _ := strconv.ParseInt(f[3], 10, 64); n >= now-KeepDays*86400 {
				known[f[0]] = true
			}
		}
	}
	kept := strings.Split(strings.TrimSuffix(string(r.Data), "\n"), "\n")
	if len(kept) != max {
		t.Fatalf("kept %d", len(kept))
	}
	nKnown, last := 0, int64(1<<62)
	for _, l := range kept {
		f := strings.Split(l, "\t")
		n, _ := strconv.ParseInt(f[3], 10, 64)
		if n > last {
			t.Fatalf("not by last seen: %q", r.Data)
		}
		last = n
		if known[f[0]] {
			nKnown++
		}
	}
	if nKnown != min(max, len(known)) {
		t.Fatalf("kept %d of %d known groups: %q dropped %v", nKnown, len(known), r.Data, r.Dropped)
	}
}
