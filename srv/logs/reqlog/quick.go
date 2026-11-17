package reqlog

import (
	"bytes"
	"strconv"
)

// The quick reads take ts and status of a line without decoding it, when the line has the shape
// Caddy writes, so tail, errors and a short window skip the lines they would not show without
// paying for a JSON decode. In valid JSON the bytes `"ts":` and `"status":` can only be a key (a
// quote inside a string is escaped). A line of any other shape is decoded; a line the decoder
// refuses is skipped either way.

// QuickTS: ts from `{"level":"<word>","ts":<number>,` at the start of the line. Nothing before
// it opens an object, so it is the first top-level "ts", the one the decoder reads.
func QuickTS(line []byte) (float64, bool) {
	const lv = `{"level":"`
	if len(line) < 32 || string(line[:len(lv)]) != lv {
		return 0, false
	}
	i := len(lv)
	for i < len(line) && line[i] >= 'a' && line[i] <= 'z' {
		i++
	}
	const ts = `","ts":`
	if len(line)-i < len(ts) || string(line[i:i+len(ts)]) != ts {
		return 0, false
	}
	i += len(ts)
	j := i
	for j < len(line) && (line[j] >= '0' && line[j] <= '9' || line[j] == '.') {
		j++
	}
	if j == i || j >= len(line) || line[j] != ',' {
		return 0, false
	}
	t, err := strconv.ParseFloat(string(line[i:j]), 64)
	return t, err == nil
}

// QuickStatus: status from `,"status":<1-3 digits>}` at the end of the line, when it is the only
// `"status":` in it. The last "}" closes the top-level object, so that member is top-level; being
// the only one, it is the one the decoder reads.
func QuickStatus(line []byte) (float64, bool) {
	k := len(line) - 1
	if k < 12 || line[k] != '}' {
		return 0, false
	}
	d := k
	for d > k-3 && line[d-1] >= '0' && line[d-1] <= '9' {
		d--
	}
	const st = `,"status":`
	if d == k || d < len(st) || string(line[d-len(st):d]) != st {
		return 0, false
	}
	if bytes.Index(line, []byte(`"status":`)) != d-len(st)+1 {
		return 0, false
	}
	n := 0
	for _, c := range line[d:k] {
		n = n*10 + int(c-'0')
	}
	return float64(n), true
}

// Quick is both reads; ok when both succeed.
func Quick(line []byte) (ts, status float64, ok bool) {
	ts, ok1 := QuickTS(line)
	status, ok2 := QuickStatus(line)
	return ts, status, ok1 && ok2
}
