package metrics

import (
	"bytes"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"tando/srv/internal/decimal"
	"tando/srv/internal/out"
	"tando/srv/internal/valid"
)

// appCols are the slice's columns of an app line (6 to 10), as `read` merges them.
var appCols = []col{{"throttled_pct", 'a', 10}, {"oom_kills", 's', 1}, {"tasks", 'm', 1}, {"tasks_max", 'm', 1}, {"memory_pressure_pct", 'a', 100}}

// xFiles are the x files `read` takes by name, with their columns.
var xFiles = map[string][]col{hostXFile: hostXCols, selfFile: selfXCols}

// xsum merges the minutes of one bucket, column by column; a "-" (or missing) value is left out
// of its column only.
type xsum struct{ n, sum, mx []int64 }

func (s *xsum) add(f []string) {
	for len(s.n) < len(f) {
		s.n, s.sum, s.mx = append(s.n, 0), append(s.sum, 0), append(s.mx, 0)
	}
	for i := range f {
		x, ok := valid.Uint(f[i], 0, math.MaxInt64)
		if !ok {
			continue
		}
		s.n[i]++
		s.sum[i] += x
		s.mx[i] = max(s.mx[i], x)
	}
}

// values renders the bucket: per column its average, sum or maximum, "-" where no minute had one.
func (s *xsum) values(cols []col) []string {
	r := make([]string, len(cols))
	for i, c := range cols {
		switch {
		case i >= len(s.n) || s.n[i] == 0:
			r[i] = "-"
		case c.agg == 's':
			r[i] = decimal.Itoa(s.sum[i])
		case c.agg == 'm':
			r[i] = decimal.Itoa(s.mx[i])
		default:
			r[i] = decimal.Itoa(s.sum[i] / s.n[i])
		}
	}
	return r
}

// IsX says whether who is an x file `read` serves (host.x, tandod.x).
func IsX(who string) bool { _, ok := xFiles[who]; return ok }

// readX writes "mx <bucket> <now>", "xc <name>:<agg>:<scale> ..." (the columns: a avg, s sum, m
// max; scale 10 or 100 is a value shown divided by it), then "x <bucket start> <value>..." per
// bucket with samples, oldest first; "-" where no minute of the bucket had a value.
func (m Metrics) readX(w *out.Writer, a ReadArgs) {
	cols := xFiles[a.Who]
	now := m.Env.Now().Unix()
	from := (now/a.Bucket - a.Points + 1) * a.Bucket
	need := a.Points*a.Bucket/60 + 2
	w.Row("mx", decimal.Itoa(a.Bucket), decimal.Itoa(now))
	hdr := []string{"xc"}
	for _, c := range cols {
		hdr = append(hdr, c.name+":"+string(c.agg)+":"+strconv.Itoa(c.scale))
	}
	w.Row(hdr...)
	f := filepath.Join(m.Dir, a.Who)
	old, _ := os.ReadFile(f + ".1")
	cur, _ := os.ReadFile(f)
	data := tail(append(tail(old, need), tail(cur, need)...), need)
	var start int64 = -1
	var s xsum
	flush := func() {
		if start >= 0 {
			w.Row(append([]string{"x", decimal.Itoa(start)}, s.values(cols)...)...)
		}
	}
	for len(data) > 0 {
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			break // a line still being written
		}
		f := strings.Split(string(data[:i]), "\t")
		data = data[i+1:]
		t, ok := valid.Uint(f[0], 0, math.MaxInt64)
		if !ok || t < from {
			continue
		}
		if b := t / a.Bucket * a.Bucket; b != start {
			flush()
			start, s = b, xsum{}
		}
		vals := f[1:]
		if len(vals) > len(cols) {
			vals = vals[:len(cols)] // (columns of a later version)
		}
		s.add(vals)
	}
	flush()
}
