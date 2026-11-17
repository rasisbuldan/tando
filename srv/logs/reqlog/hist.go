package reqlog

import "math"

// Hist is a log-scale latency histogram: bin 0 holds answers of 10 µs or less, bin i those up
// to 10 µs x 1.05^i. A percentile is read at its bin's geometric middle, so it is within about
// 2.5%; the bins need no memory per request.
type Hist struct {
	bins []int64
	n    int64
}

// lg is the width of a bin in log space.
var lg = math.Log(1.05)

// maxBin: 10 µs x 1.05^1000 is far beyond any real answer time; a larger value counts here.
const maxBin = 1000

// Add counts a duration in seconds.
func (h *Hist) Add(d float64) { h.AddBin(BinOf(d)) }

// BinOf is the bin of a duration in seconds.
func BinOf(d float64) int {
	us := d * 1000000
	if us <= 10 {
		return 0
	}
	v := math.Log(us/10) / lg
	if v >= maxBin || math.IsNaN(v) {
		return maxBin
	}
	return int(v) + 1
}

// AddBin counts one value of bin b (0..maxBin).
func (h *Hist) AddBin(b int) {
	if b >= len(h.bins) {
		h.bins = append(h.bins, make([]int64, b+1-len(h.bins))...)
	}
	h.bins[b]++
	h.n++
}

// Percentile p (0..1) in milliseconds; ok is false when no bin reaches it (the caller then uses
// the maximum).
func (h *Hist) Percentile(p float64) (ms float64, ok bool) {
	need := p * float64(h.n)
	var cum int64
	for i, c := range h.bins {
		cum += c
		if float64(cum) >= need {
			if i == 0 {
				return 0.01, true
			}
			return 0.01 * math.Exp((float64(i)-0.5)*lg), true
		}
	}
	return 0, false
}
