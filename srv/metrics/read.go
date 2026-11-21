package metrics

import (
	"bytes"
	"errors"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"tando/srv/internal/decimal"
	"tando/srv/internal/out"
	"tando/srv/internal/valid"
)

// ReadArgs are the checked arguments of `read <app|host> <points> <bucket seconds>`.
type ReadArgs struct {
	Who    string // an app, or "host"
	Points int64  // buckets wanted, 1..2000
	Bucket int64  // seconds per bucket, 60..86400
}

// ParseReadArgs checks the words after `read`; a missing or empty points or bucket is 60.
// Further words are ignored, as the shell did.
func ParseReadArgs(args []string) (ReadArgs, error) {
	word := func(i int, def string) string {
		if i < len(args) && args[i] != "" {
			return args[i]
		}
		return def
	}
	a := ReadArgs{Who: word(0, "")}
	if a.Who != "host" && !valid.App(a.Who) {
		return a, errors.New("bad app name")
	}
	var ok bool
	if a.Points, ok = valid.Uint(word(1, "60"), 1, 2000); !ok {
		return a, errors.New("bad point count")
	}
	if a.Bucket, ok = valid.Uint(word(2, "60"), 60, 86400); !ok {
		return a, errors.New("bad bucket")
	}
	return a, nil
}

// Read writes "mx <bucket> <now>", then one row per bucket that has samples, oldest first:
//
//	app:  m <bucket start> <mem avg> <cpu permille of one core, avg> <restarts max> <last state> <disk bytes>
//	host: h <bucket start> <load x100 avg> <mem used avg> <mem total> <cpu permille of all cores, avg>
//	        <disk used avg> <disk total>
//
// over the last Points buckets. Only the newest lines that can fall in that window are read.
// "-" is a value not known: lines of older versions have no host cpu or disk; an app's disk is
// the newest walk (<app>.disk) at or before the bucket's end, if at most diskStale older than
// the bucket's start. Readers split on tabs and take the fields they know: columns are only
// ever added at the end.
func (m Metrics) Read(w *out.Writer, a ReadArgs) {
	now := m.Env.Now().Unix()
	from := (now/a.Bucket - a.Points + 1) * a.Bucket
	need := a.Points*a.Bucket/60 + 2 // lines: one a minute, and a little slack
	w.Row("mx", decimal.Itoa(a.Bucket), decimal.Itoa(now))

	// an unreadable file is a missing one (as `[[ -r ]]` in the shell)
	old, _ := os.ReadFile(m.file(a.Who) + ".1")
	cur, _ := os.ReadFile(m.file(a.Who))
	data := tail(append(tail(old, need), tail(cur, need)...), need)

	host := a.Who == "host"
	var disk []diskSample
	if !host {
		dn := a.Points*a.Bucket/diskEvery + 2
		dold, _ := os.ReadFile(m.diskFile(a.Who) + ".1")
		dcur, _ := os.ReadFile(m.diskFile(a.Who))
		disk = parseDisk(tail(append(tail(dold, dn), tail(dcur, dn)...), dn))
	}
	flush := func(b *bucket) {
		if !host {
			b.disk = diskAt(disk, b.start, a.Bucket)
		}
		b.flush(w, host)
	}
	var b bucket
	var prevT int64
	for len(data) > 0 {
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			break // a line still being written (bash's read dropped it too)
		}
		line := data[:i]
		f := fields(string(line))
		data = data[i+1:]
		t, ok := valid.Uint(f[0], 0, math.MaxInt64)
		if !ok {
			continue
		}
		v1, v2, v3 := num(f[1]), num(f[2]), num(f[3])
		cpu := v1 // host: the load
		if !host {
			// usec over dt seconds -> permille of one core
			dt := t - prevT
			if prevT == 0 || dt <= 0 || dt > 600 {
				dt = 60
			}
			cpu = v2 / (dt * 1000)
		}
		prevT = t
		if t < from {
			continue
		}
		if start := t / a.Bucket * a.Bucket; start != b.start {
			flush(&b)
			b = bucket{start: start, dTotal: -1}
		}
		b.n++
		b.s1 += cpu
		if host {
			b.s2 += v2
			b.total = v3
			h := hostExtra(string(line))
			if h[0] >= 0 {
				b.cN, b.cS = b.cN+1, b.cS+h[0]
			}
			if h[1] >= 0 {
				b.dN, b.dS = b.dN+1, b.dS+h[1]
			}
			if h[2] >= 0 {
				b.dTotal = h[2]
			}
		} else {
			b.s2 += v1
			b.mx = max(b.mx, v3)
			b.last = f[4]
		}
	}
	flush(&b)
}

// bucket sums the samples of one bucket.
type bucket struct {
	start, n, s1, s2 int64
	mx, total        int64  // app: most restarts; host: memory total of the last sample
	last             string // app: the last state letter
	cN, cS, dN, dS   int64  // host: cpu and disk-used samples that had a value, and their sums
	dTotal           int64  // host: disk total of the last sample that had one (-1: none)
	disk             int64  // app: disk bytes (-1: none)
}

func (b *bucket) flush(w *out.Writer, host bool) {
	if b.n == 0 {
		return
	}
	if host {
		w.Row("h", decimal.Itoa(b.start), decimal.Itoa(b.s1/b.n), decimal.Itoa(b.s2/b.n), decimal.Itoa(b.total),
			avgOrDash(b.cS, b.cN), avgOrDash(b.dS, b.dN), avgOrDash(b.dTotal, 1))
	} else {
		w.Row("m", decimal.Itoa(b.start), decimal.Itoa(b.s2/b.n), decimal.Itoa(b.s1/b.n), decimal.Itoa(b.mx), b.last, avgOrDash(b.disk, 1))
	}
}

// avgOrDash: s/n, or "-" without samples (n 0) or a value (s < 0)
func avgOrDash(s, n int64) string {
	if n <= 0 || s < 0 {
		return "-"
	}
	return decimal.Itoa(s / n)
}

// hostExtra: the cpu permille, disk used and disk total of a host line (fields 5 to 7); -1 where
// the line has none (an older version's line) or "-" (not known when it was sampled)
func hostExtra(line string) [3]int64 {
	r := [3]int64{-1, -1, -1}
	f := strings.FieldsFunc(line, func(c rune) bool { return c == '\t' })
	for i := 4; i < len(f) && i < 7; i++ {
		if n, ok := valid.Uint(f[i], 0, math.MaxInt64); ok {
			r[i-4] = n
		}
	}
	return r
}

// diskStale: how much older than its bucket an app's disk walk may be and still count
const diskStale = 1200

type diskSample struct{ t, bytes int64 }

func (m Metrics) diskFile(app string) string { return filepath.Join(m.Dir, app+".disk") }

// parseDisk: the "time bytes" lines of <app>.disk, in file order; damaged lines are skipped
func parseDisk(b []byte) []diskSample {
	var r []diskSample
	for _, l := range strings.Split(string(b), "\n") {
		ts, bs, ok := strings.Cut(l, "\t")
		t, ok1 := valid.Uint(ts, 0, math.MaxInt64)
		n, ok2 := valid.Uint(bs, 0, math.MaxInt64)
		if ok && ok1 && ok2 {
			r = append(r, diskSample{t, n})
		}
	}
	return r
}

// diskAt: the newest walk at or before the bucket's end, if not older than diskStale before its
// start; -1 when there is none
func diskAt(d []diskSample, start, bucket int64) int64 {
	v, at := int64(-1), int64(-1)
	for _, s := range d {
		if s.t < start+bucket && s.t >= at {
			v, at = s.bytes, s.t
		}
	}
	if at < start-diskStale {
		return -1
	}
	return v
}

// tail is the last n lines of b, as `tail -n`: a last line without a newline counts.
func tail(b []byte, n int64) []byte {
	i := len(b)
	if i > 0 && b[i-1] == '\n' {
		i--
	}
	for ; n > 0; n-- {
		j := bytes.LastIndexByte(b[:i], '\n')
		if j < 0 {
			return b
		}
		i = j
	}
	return b[i+1:]
}

// fields splits a line as `IFS=$'\t' read -r t a b c d` did: runs of tabs are one separator,
// and the fifth field takes the rest of the line. Missing fields are "".
func fields(l string) [5]string {
	var f [5]string
	l = strings.Trim(l, "\t")
	for i := 0; i < 4 && l != ""; i++ {
		f[i], l, _ = strings.Cut(l, "\t")
		l = strings.TrimLeft(l, "\t")
	}
	f[4] = l
	return f
}

// num: a field as a number; anything else counts 0 (bash arithmetic on an empty field).
func num(s string) int64 {
	n, _ := strconv.ParseInt(s, 10, 64)
	return n
}
