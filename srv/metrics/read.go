package metrics

import (
	"bytes"
	"errors"
	"math"
	"os"
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
//	app:  m <bucket start> <mem avg> <cpu permille of one core, avg> <restarts max> <last state>
//	host: h <bucket start> <load x100 avg> <mem used avg> <mem total>
//
// over the last Points buckets. Only the newest lines that can fall in that window are read.
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
	var b bucket
	var prevT int64
	for len(data) > 0 {
		i := bytes.IndexByte(data, '\n')
		if i < 0 {
			break // a line still being written (bash's read dropped it too)
		}
		f := fields(string(data[:i]))
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
			b.flush(w, host)
			b = bucket{start: start}
		}
		b.n++
		b.s1 += cpu
		if host {
			b.s2 += v2
			b.total = v3
		} else {
			b.s2 += v1
			b.mx = max(b.mx, v3)
			b.last = f[4]
		}
	}
	b.flush(w, host)
}

// bucket sums the samples of one bucket.
type bucket struct {
	start, n, s1, s2 int64
	mx, total        int64  // app: most restarts; host: memory total of the last sample
	last             string // app: the last state letter
}

func (b *bucket) flush(w *out.Writer, host bool) {
	if b.n == 0 {
		return
	}
	if host {
		w.Row("h", decimal.Itoa(b.start), decimal.Itoa(b.s1/b.n), decimal.Itoa(b.s2/b.n), decimal.Itoa(b.total))
	} else {
		w.Row("m", decimal.Itoa(b.start), decimal.Itoa(b.s2/b.n), decimal.Itoa(b.s1/b.n), decimal.Itoa(b.mx), b.last)
	}
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
