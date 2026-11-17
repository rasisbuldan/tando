package reqlog

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

	"tando/srv/internal/out"
	"tando/srv/logs/lines"
)

// Golden files: the shell version's awk under mawk over generated hostile request lines (see
// ../testdata/golden/gen.py and run.sh).

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

const now = 1794587950 + 3600

func each(t *testing.T, name string, fn func(lines.Line)) {
	r := lines.NewReader(bytes.NewReader(golden(t, name)), MaxLine)
	for {
		ln, ok := r.Next()
		if !ok {
			return
		}
		fn(ln)
	}
}

func split(s string) (kv []string, rows []string) {
	for l := range strings.SplitSeq(strings.TrimSuffix(s, "\n"), "\n") {
		if strings.Contains(l, "\t") {
			rows = append(rows, l)
		} else {
			kv = append(kv, l)
		}
	}
	slices.Sort(rows)
	return
}

func eqLines(t *testing.T, what string, got, want []string) {
	t.Helper()
	for i := 0; i < max(len(got), len(want)); i++ {
		var g, w string
		if i < len(got) {
			g = got[i]
		}
		if i < len(want) {
			w = want[i]
		}
		if g != w {
			t.Fatalf("%s: line %d (%d vs %d lines)\n got: %q\nwant: %q", what, i+1, len(got), len(want), g, w)
		}
	}
}

func TestGoldenSummary(t *testing.T) {
	for _, c := range []struct{ w, nb int64 }{{3600, 60}, {900, 15}, {125, 2}, {604800, 60}} {
		s := NewSummary(c.w, now, c.nb)
		p := NewParser()
		var r Request
		each(t, "access.log", func(ln lines.Line) {
			if !s.Outside(ln.Text) && p.Parse(ln.Text, &r) {
				s.Add(&r)
			}
		})
		var b bytes.Buffer
		w := out.New(&b)
		s.Write(w)
		w.Flush()
		gk, gr := split(b.String())
		wk, wr := split(string(golden(t, "out-summary."+strconv.FormatInt(c.w, 10))))
		eqLines(t, "key=value", gk, wk)
		// rows came in awk's hash order: compared sorted. Every field passes out.Clean, which
		// turns what awk printed raw (a path cut inside a UTF-8 character) into "?"
		for i := range wr {
			wr[i] = cleanRow(wr[i])
		}
		slices.Sort(wr)
		eqLines(t, "rows", gr, wr)
	}
}

func cleanRow(r string) string {
	f := strings.Split(r, "\t")
	for i := range f {
		if f[i] = out.Clean(f[i]); f[i] == "" {
			f[i] = "-"
		}
	}
	return strings.Join(f, "\t")
}

func rowsOf(t *testing.T, name string, n int, f RowFilter, perLine bool) []string {
	p := NewParser()
	var r Request
	var all []string
	each(t, name, func(ln lines.Line) {
		var row string
		if !f.Skips(ln.Text) && p.Parse(ln.Text, &r) {
			// the shell looked for `,"remote_ip":"`, but remote_ip is the first key of Caddy's
			// request object: it never found it, and showed no address without client_ip (Caddy
			// 2.6). The Go version shows remote_ip there; compared here the shell's way.
			r.RemoteIP = nil
			if x, ok := f.Make(&r); ok {
				row = cleanRow("req\t" + strings.Join(x[:], "\t"))
			}
		}
		if row != "" || perLine {
			all = append(all, row)
		}
	})
	if len(all) > n {
		all = all[len(all)-n:]
	}
	var res []string
	for _, r := range all {
		if r != "" {
			res = append(res, r)
		}
	}
	return res
}

func goldenRows(t *testing.T, name string) []string {
	var res []string
	for l := range strings.SplitSeq(strings.TrimSuffix(string(golden(t, name)), "\n"), "\n") {
		if l != "" {
			res = append(res, cleanRow(l))
		}
	}
	return res
}

func TestGoldenRows(t *testing.T) {
	eqLines(t, "tail 50", rowsOf(t, "access.log", 50, RowFilter{}, true), goldenRows(t, "out-rows.tail50"))
	eqLines(t, "errors 500", rowsOf(t, "access.log", 40, RowFilter{From: now - 3600, MinStatus: 500}, false), goldenRows(t, "out-rows.err500"))
	eqLines(t, "errors 400", rowsOf(t, "access.log", 9999, RowFilter{From: now - 7200, MinStatus: 400}, false), goldenRows(t, "out-rows.err400"))
}

func TestGoldenChunk(t *testing.T) {
	var c Chunk
	p := NewParser()
	var r Request
	var nb int64
	each(t, "access-chunk.log", func(ln lines.Line) {
		if !ln.EOL {
			return
		}
		nb += int64(ln.Len) + 1
		if p.Parse(ln.Text, &r) {
			c.Add(&r)
		}
	})
	got := []string{"B\t" + strconv.FormatInt(nb, 10),
		"Q\t" + strconv.FormatInt(c.Total, 10) + "\t" + strconv.FormatInt(c.E5, 10) + "\t" + strconv.FormatInt(c.P95(), 10)}
	want := strings.Split(strings.TrimSuffix(string(golden(t, "out-reqscan.out")), "\n"), "\n")
	eqLines(t, "B and Q", got, want[:2])
	// the top 3: counts and paths (ties were broken by awk's hash order)
	var tops []string
	for _, x := range c.Tops(3) {
		tops = append(tops, strconv.FormatInt(x.N, 10))
	}
	var wtops []string
	for _, l := range want[2:] {
		wtops = append(wtops, strings.Split(l, "\t")[1])
	}
	eqLines(t, "top counts", tops, wtops)
}
