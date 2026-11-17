package reqlog

import (
	"math"
	"sort"
)

// Chunk is what the per-minute scan learns from the request log written since its last run:
// requests, 5xx answers, p95 latency and the paths that failed most.
type Chunk struct {
	Total, E5 int64
	hist      Hist
	fails     map[string]*fail
	order     []string
	key, tmp  []byte
}

type fail struct {
	n      int64
	status float64
	first  int
}

// Add counts one request line.
func (c *Chunk) Add(r *Request) {
	if !r.Counted() {
		return
	}
	c.Total++
	c.hist.Add(r.Duration)
	if r.Status < 500 {
		return
	}
	c.key = AppendClean(c.key[:0], r.Method)
	c.key = append(c.key, ' ')
	c.tmp = AppendClean(c.tmp[:0], r.URI)
	c.key = AppendPath(c.key, c.tmp)
	c.fail(c.key, r.Status)
}

// AddRecord counts one record of the index as Add counts its line. key is the record's path
// key (PathKey: the method as logged); it is asked for only for a 5xx.
func (c *Chunk) AddRecord(r *Record, key func() string) {
	if r.Path == NotCounted {
		return
	}
	c.Total++
	c.hist.AddBin(int(r.Bin))
	if r.Status < 500 {
		return
	}
	// the top paths show the method cleaned, as Add does: the key's method part is cleaned here
	k := key()
	sp := 0
	for sp < len(k) && k[sp] != ' ' {
		sp++
	}
	c.key = AppendClean(c.key[:0], []byte(k[:sp]))
	c.key = append(c.key, k[sp:]...)
	c.fail(c.key, float64(r.Status))
}

func (c *Chunk) fail(key []byte, status float64) {
	c.E5++
	if c.fails == nil {
		c.fails = map[string]*fail{}
	}
	f, ok := c.fails[string(key)]
	if !ok {
		if len(c.fails) >= maxPaths {
			return // (a bound on memory: only the top 3 are reported)
		}
		f = &fail{first: len(c.order)}
		c.fails[string(key)] = f
		c.order = append(c.order, string(key))
	}
	f.n++
	f.status = status
}

// P95 is the 95th percentile latency in whole milliseconds (rounded), 0 without requests.
func (c *Chunk) P95() int64 {
	if c.Total == 0 {
		return 0
	}
	v, ok := c.hist.Percentile(0.95)
	if !ok {
		return 0
	}
	return int64(math.Floor(v + 0.5))
}

// Top is a failing path: how many 5xx, the last status, "METHOD path".
type Top struct {
	N      int64
	Status float64
	Key    string
}

// Tops returns the n paths with the most 5xx, most first (ties: the one seen first).
func (c *Chunk) Tops(n int) []Top {
	t := make([]Top, 0, len(c.order))
	for _, k := range c.order {
		f := c.fails[k]
		t = append(t, Top{N: f.n, Status: f.status, Key: k})
	}
	sort.SliceStable(t, func(i, j int) bool { return t[i].N > t[j].N })
	return t[:min(n, len(t))]
}
