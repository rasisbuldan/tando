package reqlog

import (
	"strconv"

	"tando/srv/internal/out"
)

// maxPaths distinct "METHOD path" keys are kept per summary; later new ones count together as
// otherPaths (slugs would otherwise make one key per page).
const maxPaths = 2000

// otherPaths is the key of the requests beyond maxPaths.
const otherPaths = "* (other paths)"

// Summary is one pass over the lines of a window (req-summary): totals, status codes,
// per-bucket counts, the latency histogram and per-path aggregates. Memory is bounded by
// maxPaths and the number of buckets, whatever the number of lines.
type Summary struct {
	W, Now, From, NB int64 // window and its end (epoch seconds), buckets
	bw               float64

	total, bad    int64
	oldest        float64
	class         [10]int64
	codes         map[string]int // status -> index in codeOrder and codeN
	codeOrder     []string
	codeN         []int64
	rpm, e5       []int64
	hist          Hist
	dmax, dsum    float64
	paths         map[string]int
	path          []pathAgg
	np            int
	key, uri, tmp []byte
}

type pathAgg struct {
	key      string
	n, n5    int64
	sum, max float64
}

// NewSummary: a window of w seconds ending at now, in nb buckets.
func NewSummary(w, now, nb int64) *Summary {
	return &Summary{W: w, Now: now, From: now - w, NB: nb, bw: float64(w) / float64(nb),
		codes: map[string]int{}, rpm: make([]int64, nb), e5: make([]int64, nb), paths: map[string]int{}}
}

// Outside reports whether a line is outside the window by its Quick fields (then it needs no
// decoding); it still counts for the oldest line read.
func (s *Summary) Outside(line []byte) bool {
	t, ok := QuickTS(line)
	if !ok || (t >= float64(s.From) && t <= float64(s.Now+1)) {
		return false
	}
	if t > 0 && (s.oldest == 0 || t < s.oldest) {
		s.oldest = t
	}
	return true
}

// Add counts one request line (already parsed).
func (s *Summary) Add(r *Request) {
	if !s.inWindow(r.Ts, r.Counted()) {
		return
	}
	s.count(r.Ts, r.Status, r.Duration, BinOf(r.Duration))
	s.key = PathKey(s.key[:0], r.Method, r.URI, &s.uri)
	i, ok := s.paths[string(s.key)]
	if !ok {
		i = s.newPath(s.key)
	}
	s.addPath(i, r.Status, r.Duration)
}

// inWindow: the oldest line read, then whether the line counts (in the window and a request; a
// line in the window that is not a request is "unparsed").
func (s *Summary) inWindow(t float64, counted bool) bool {
	if t > 0 && (s.oldest == 0 || t < s.oldest) {
		s.oldest = t
	}
	if t < float64(s.From) || t > float64(s.Now+1) {
		return false
	}
	if !counted {
		s.bad++
		return false
	}
	return true
}

// count adds a request to the totals, codes, buckets and histogram.
func (s *Summary) count(t, st, d float64, bin int) {
	s.total++
	s.tmp = AppendNum(s.tmp[:0], st)
	if st == 0 {
		s.tmp = append(s.tmp[:0], "aborted"...)
	}
	ci, ok := s.codes[string(s.tmp)]
	if !ok {
		ci = len(s.codeOrder)
		s.codes[string(s.tmp)] = ci
		s.codeOrder = append(s.codeOrder, string(s.tmp))
		s.codeN = append(s.codeN, 0)
	}
	s.codeN[ci]++
	cls := int64(st / 100)
	if cls >= 0 && cls < int64(len(s.class)) {
		s.class[cls]++
	}
	b := int64((t - float64(s.From)) / s.bw)
	if b >= s.NB {
		b = s.NB - 1
	}
	if b < 0 {
		b = 0
	}
	s.rpm[b]++
	if cls == 5 {
		s.e5[b]++
	}
	s.hist.AddBin(bin)
	if d > s.dmax {
		s.dmax = d
	}
	s.dsum += d
}

// newPath: the aggregate a key not seen yet counts in: its own, or otherPaths beyond maxPaths.
func (s *Summary) newPath(key []byte) int {
	k := otherPaths
	if s.np < maxPaths {
		k = string(key) // (only a key that gets its own aggregate is copied)
		s.np++
	}
	i, ok := s.paths[k]
	if !ok {
		i = len(s.path)
		s.paths[k] = i
		s.path = append(s.path, pathAgg{key: k})
	}
	return i
}

func (s *Summary) addPath(i int, st, d float64) {
	p := &s.path[i]
	p.n++
	p.sum += d
	if d > p.max {
		p.max = d
	}
	if int64(st/100) == 5 {
		p.n5++
	}
}

// PathKey is a request's path key: the method as logged (only paths are folded), a space, the
// cleaned path with ids folded. tmp is scratch space.
func PathKey(dst, method, uri []byte, tmp *[]byte) []byte {
	dst = append(dst, method...)
	dst = append(dst, ' ')
	*tmp = AppendClean((*tmp)[:0], uri)
	return AppendPath(dst, *tmp)
}

func (s *Summary) pct(p float64) float64 {
	if s.total == 0 {
		return 0
	}
	if v, ok := s.hist.Percentile(p); ok {
		return v
	}
	return s.dmax * 1000
}

// Write prints the summary as req-summary's key=value lines and rows (docs/LOGGING.md).
func (s *Summary) Write(w *out.Writer) {
	w.KV("window", strconv.FormatInt(s.W, 10))
	w.KV("from", strconv.FormatInt(s.From, 10))
	w.KV("to", strconv.FormatInt(s.Now, 10))
	w.KV("bucket", strconv.FormatFloat(s.bw, 'g', 6, 64))
	w.KV("total", strconv.FormatInt(s.total, 10))
	for i := 1; i <= 5; i++ {
		w.KV("c"+strconv.Itoa(i)+"xx", strconv.FormatInt(s.class[i], 10))
	}
	w.KV("p50_ms", f2(s.pct(0.5)))
	w.KV("p95_ms", f2(s.pct(0.95)))
	w.KV("p99_ms", f2(s.pct(0.99)))
	w.KV("max_ms", f2(s.dmax*1000))
	avg := 0.0
	if s.total > 0 {
		avg = s.dsum * 1000 / float64(s.total)
	}
	w.KV("avg_ms", f2(avg))
	w.KV("counts", joinInts(s.rpm))
	w.KV("counts_5xx", joinInts(s.e5))
	w.KV("unparsed", strconv.FormatInt(s.bad, 10))
	w.KV("paths", strconv.Itoa(s.np))
	// the request log may hold less than the window (rotation by size): the oldest line read
	w.KV("oldest", strconv.FormatInt(int64(s.oldest), 10))
	for i, c := range s.codeOrder {
		w.Row("code", c, strconv.FormatInt(s.codeN[i], 10))
	}
	for _, p := range s.path {
		w.Row("path", p.key, strconv.FormatInt(p.n, 10), f2(p.sum*1000/float64(p.n)), f2(p.max*1000),
			strconv.FormatInt(p.n5, 10))
	}
}

func f2(v float64) string { return strconv.FormatFloat(v, 'f', 2, 64) }

func joinInts(v []int64) string {
	b := make([]byte, 0, len(v)*3)
	for i, n := range v {
		if i > 0 {
			b = append(b, ',')
		}
		b = strconv.AppendInt(b, n, 10)
	}
	return string(b)
}

// AppendNum appends a number as awk prints it in a string: an integral value as an integer, any
// other as %.6g.
func AppendNum(dst []byte, v float64) []byte {
	if v == float64(int64(v)) && v > -9e18 && v < 9e18 {
		return strconv.AppendInt(dst, int64(v), 10)
	}
	return strconv.AppendFloat(dst, v, 'g', 6, 64)
}
