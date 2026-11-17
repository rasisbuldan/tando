// Package lines reads text line by line with a bound on memory: a line longer than the limit is
// returned cut to it (with its full length), never buffered whole. Every log tando-logs reads is
// written by an app, its visitors or journalctl on their behalf, so no line may make it grow.
// It also has awk's string-to-number rule, which several of the formats rely on.
//
// A parser of package logs: the standard library only (no files, no commands, no Env).
package lines

import (
	"bufio"
	"bytes"
	"errors"
	"io"
)

// Reader returns the lines of r. The slice Next returns is valid until the next call.
type Reader struct {
	br   *bufio.Reader
	max  int
	long []byte // the prefix of a line longer than the bufio buffer
	err  error
}

// NewReader reads r; lines longer than limit bytes come back cut to limit bytes.
func NewReader(r io.Reader, limit int) *Reader { return NewReaderSize(r, limit, 64<<10) }

// NewReaderSize is NewReader with a read buffer of size bytes (one read(2) per buffer).
func NewReaderSize(r io.Reader, limit, size int) *Reader {
	limit = max(limit, 1)
	if limit < size {
		size = max(limit, 16)
	}
	return &Reader{br: bufio.NewReaderSize(r, size), max: limit}
}

// Reset reads r from the start, keeping the buffers (a long-running caller reuses one Reader).
func (r *Reader) Reset(src io.Reader) {
	r.br.Reset(src)
	r.long = r.long[:0]
	if cap(r.long) > 64<<10 {
		r.long = nil // (one long line does not keep megabytes in a long-running caller)
	}
	r.err = nil
}

// Line is one line without its newline.
type Line struct {
	Text []byte // at most the Reader's max bytes
	Len  int    // the line's full length in bytes
	EOL  bool   // ended with "\n" (false: the input's last bytes, without one)
}

// Next returns the next line; ok is false at the end of the input (or on a read error, Err).
// An empty input after the last "\n" is not a line.
func (r *Reader) Next() (l Line, ok bool) {
	if r.err != nil {
		return Line{}, false
	}
	b, err := r.br.ReadSlice('\n')
	if err == nil || (err != bufio.ErrBufferFull && len(b) > 0) {
		if err != nil && err != io.EOF {
			r.err = err
		}
		eol := err == nil
		if eol {
			b = b[:len(b)-1]
		}
		n := len(b)
		if n > r.max {
			b = b[:r.max]
		}
		if err == io.EOF {
			r.err = io.EOF
		}
		return Line{Text: b, Len: n, EOL: eol}, true
	}
	if err != bufio.ErrBufferFull {
		r.err = err
		return Line{}, false
	}
	// a line longer than the buffer: keep up to max bytes of it, count the rest
	r.long = append(r.long[:0], b[:min(len(b), r.max)]...)
	n := len(b)
	for {
		b, err = r.br.ReadSlice('\n')
		eol := err == nil
		if eol {
			b = b[:len(b)-1]
		}
		if room := r.max - len(r.long); room > 0 {
			r.long = append(r.long, b[:min(room, len(b))]...)
		}
		n += len(b)
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil {
			r.err = err
		}
		return Line{Text: r.long, Len: n, EOL: eol}, true
	}
}

// Err is the read error that ended the input, nil at a clean end.
func (r *Reader) Err() error {
	if errors.Is(r.err, io.EOF) {
		return nil
	}
	return r.err
}

// Num is awk's value of a string used as a number: leading blanks are skipped, then the longest
// prefix that reads as a decimal number (sign, digits, a point, an exponent) counts; no number
// is 0. ("1794587950.123 host x[1]: m" is 1794587950.123, "abc" is 0.)
func Num(b []byte) float64 {
	i := 0
	for i < len(b) && (b[i] == ' ' || b[i] == '\t' || b[i] == '\n' || b[i] == '\r' || b[i] == '\f' || b[i] == '\v') {
		i++
	}
	j := numEnd(b, i)
	if j == i {
		return 0
	}
	return parseFloat(b[i:j])
}

// numEnd: the end of the decimal number that starts at b[i], i itself when there is none.
func numEnd(b []byte, i int) int {
	j := i
	if j < len(b) && (b[j] == '+' || b[j] == '-') {
		j++
	}
	d0 := j
	for j < len(b) && b[j] >= '0' && b[j] <= '9' {
		j++
	}
	digits := j - d0
	if j < len(b) && b[j] == '.' {
		k := j + 1
		for k < len(b) && b[k] >= '0' && b[k] <= '9' {
			k++
		}
		digits += k - j - 1
		j = k
	}
	if digits == 0 {
		return i
	}
	if j < len(b) && (b[j] == 'e' || b[j] == 'E') {
		k := j + 1
		if k < len(b) && (b[k] == '+' || b[k] == '-') {
			k++
		}
		e0 := k
		for k < len(b) && b[k] >= '0' && b[k] <= '9' {
			k++
		}
		if k > e0 {
			j = k
		}
	}
	return j
}

// Fields splits b at runs of blanks like awk's default field splitting (leading blanks ignored)
// into at most len(dst) fields; the last one holds the rest of b as it is. It returns how many.
func Fields(b []byte, dst [][]byte) int {
	n := 0
	i := 0
	for n < len(dst) {
		for i < len(b) && (b[i] == ' ' || b[i] == '\t') {
			i++
		}
		if i >= len(b) {
			break
		}
		if n == len(dst)-1 {
			dst[n] = b[i:]
			return n + 1
		}
		j := i
		for j < len(b) && b[j] != ' ' && b[j] != '\t' {
			j++
		}
		dst[n] = b[i:j]
		n++
		i = j
	}
	return n
}

// Cut returns s cut to n bytes (awk's substr(s, 1, n) in the C locale).
func Cut(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// HasPrefix is bytes.HasPrefix for a string prefix (no conversion of the line).
func HasPrefix(b []byte, p string) bool { return len(b) >= len(p) && string(b[:len(p)]) == p }

// Index is bytes.Index for a string needle.
func Index(b []byte, s string) int { return bytes.Index(b, []byte(s)) }

// IsNum reports whether s looks like a number to awk (a "strnum" field): blanks, one decimal
// number, blanks, nothing else. A field that does compares as a number, any other as text.
func IsNum(s string) bool {
	b := []byte(s)
	i := 0
	for i < len(b) && (b[i] == ' ' || b[i] == '\t' || b[i] == '\n') {
		i++
	}
	j := numEnd(b, i)
	if j == i {
		return false
	}
	for j < len(b) && (b[j] == ' ' || b[j] == '\t' || b[j] == '\n') {
		j++
	}
	return j == len(b)
}
