package reqlog

import (
	"encoding/binary"
	"strconv"
)

// fastParse reads a line the way Caddy writes it, without the general decoder: one JSON object,
// compact (no blanks), whose values are strings, numbers, literals, or objects and arrays nested
// at most 16 deep. It fills r with exactly what the decoder would (Decode: the first of a
// repeated key, a string over maxStr bytes as absent, "request" only when it is an object) and
// returns true; on anything it does not fully check (blanks, a \u escape of a surrogate, deeper
// nesting, an error) it returns false and Parse asks the decoder, which then decides. FuzzFast
// holds the two to the same result. No allocation: r's strings are slices of line.
func fastParse(line []byte, r *Request) bool {
	*r = Request{}
	n := len(line)
	if n < 2 || line[0] != '{' || line[n-1] != '}' {
		return false
	}
	s := scanner{b: line, i: 1}
	var seen uint8
	if s.peek() == '}' {
		return s.i+1 == n
	}
	for {
		ks, ke, ok := s.str()
		if !ok || !s.byte(':') {
			return false
		}
		key := line[ks:ke]
		var dst *float64
		var bit uint8
		switch string(key) {
		case "ts":
			dst, bit = &r.Ts, 1
		case "duration":
			dst, bit = &r.Duration, 2
		case "status":
			dst, bit = &r.Status, 4
		case "size":
			dst, bit = &r.Size, 8
		case "request":
			if seen&16 == 0 && s.peek() == '{' {
				seen |= 16
				if !s.request(r) {
					return false
				}
				goto next
			}
		}
		if dst != nil && seen&bit == 0 && isNumStart(s.peek()) {
			vs, ve, ok := s.num()
			if !ok {
				return false
			}
			seen |= bit
			*dst = fastNumber(line[vs:ve])
		} else if !s.skip(0) {
			return false
		}
	next:
		switch s.peek() {
		case ',':
			s.i++
		case '}':
			return s.i+1 == n
		default:
			return false
		}
	}
}

func isNumStart(c byte) bool { return c == '-' || c >= '0' && c <= '9' }

type scanner struct {
	b []byte
	i int
}

func (s *scanner) peek() byte {
	if s.i < len(s.b) {
		return s.b[s.i]
	}
	return 0
}

func (s *scanner) byte(c byte) bool {
	if s.peek() != c {
		return false
	}
	s.i++
	return true
}

// strClass: 0 an ordinary byte of a string; 1 the quote; 2 the backslash; 3 a control character.
var strClass = func() (t [256]byte) {
	for c := 0; c < 0x20; c++ {
		t[c] = 3
	}
	t['"'], t['\\'] = 1, 2
	return
}()

const (
	lo8 = 0x0101010101010101
	hi8 = 0x8080808080808080
)

// special8: whether any of the 8 bytes of x is a quote, a backslash or below 0x20 (the bytes a
// string scan must stop at), without a loop.
func special8(x uint64) bool {
	q := x ^ (lo8 * '"')
	bs := x ^ (lo8 * '\\')
	return ((q-lo8)&^q|(bs-lo8)&^bs|(x-lo8*0x20)&^x)&hi8 != 0
}

// str reads a string at s.i; [start, end) is its content, escapes as written.
func (s *scanner) str() (int, int, bool) {
	if !s.byte('"') {
		return 0, 0, false
	}
	b := s.b
	start := s.i
	i := s.i
	for {
		for i+8 <= len(b) && !special8(binary.LittleEndian.Uint64(b[i:])) {
			i += 8
		}
		if i >= len(b) {
			return 0, 0, false
		}
		switch strClass[b[i]] {
		case 0:
			i++
		case 1:
			s.i = i + 1
			return start, i, true
		case 2:
			if i+1 >= len(b) {
				return 0, 0, false
			}
			switch b[i+1] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
				i += 2
			case 'u':
				if i+5 >= len(b) {
					return 0, 0, false
				}
				v := hexval(b[i+2 : i+6])
				if v < 0 || v >= 0xd800 && v <= 0xdfff {
					return 0, 0, false // (surrogates: the decoder's call)
				}
				i += 6
			default:
				return 0, 0, false
			}
		default:
			return 0, 0, false
		}
	}
}

// num reads a number by JSON's grammar: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?
func (s *scanner) num() (int, int, bool) {
	b, i := s.b, s.i
	start := i
	if i < len(b) && b[i] == '-' {
		i++
	}
	switch {
	case i < len(b) && b[i] == '0':
		i++
	case i < len(b) && b[i] >= '1' && b[i] <= '9':
		for i < len(b) && b[i] >= '0' && b[i] <= '9' {
			i++
		}
	default:
		return 0, 0, false
	}
	if i < len(b) && b[i] == '.' {
		i++
		d := i
		for i < len(b) && b[i] >= '0' && b[i] <= '9' {
			i++
		}
		if i == d {
			return 0, 0, false
		}
	}
	if i < len(b) && (b[i] == 'e' || b[i] == 'E') {
		i++
		if i < len(b) && (b[i] == '+' || b[i] == '-') {
			i++
		}
		d := i
		for i < len(b) && b[i] >= '0' && b[i] <= '9' {
			i++
		}
		if i == d {
			return 0, 0, false
		}
	}
	s.i = i
	return start, i, true
}

func (s *scanner) lit(w string) bool {
	if len(s.b)-s.i < len(w) || string(s.b[s.i:s.i+len(w)]) != w {
		return false
	}
	s.i += len(w)
	return true
}

// skip checks and passes one value.
func (s *scanner) skip(depth int) bool {
	switch c := s.peek(); {
	case c == '"':
		_, _, ok := s.str()
		return ok
	case isNumStart(c):
		_, _, ok := s.num()
		return ok
	case c == 't':
		return s.lit("true")
	case c == 'f':
		return s.lit("false")
	case c == 'n':
		return s.lit("null")
	case c == '{':
		if depth >= 16 {
			return false
		}
		s.i++
		if s.byte('}') {
			return true
		}
		for {
			if _, _, ok := s.str(); !ok || !s.byte(':') || !s.skip(depth+1) {
				return false
			}
			if s.byte('}') {
				return true
			}
			if !s.byte(',') {
				return false
			}
		}
	case c == '[':
		if depth >= 16 {
			return false
		}
		s.i++
		if s.byte(']') {
			return true
		}
		for {
			if !s.skip(depth + 1) {
				return false
			}
			if s.byte(']') {
				return true
			}
			if !s.byte(',') {
				return false
			}
		}
	}
	return false
}

// request reads the "request" object: method, uri, client_ip, remote_ip (strings; the first of
// each; one over maxStr bytes counts as absent).
func (s *scanner) request(r *Request) bool {
	s.i++ // {
	if s.byte('}') {
		return true
	}
	var got uint8
	for {
		ks, ke, ok := s.str()
		if !ok || !s.byte(':') {
			return false
		}
		var dst *[]byte
		var bit uint8
		switch string(s.b[ks:ke]) {
		case "method":
			dst, bit = &r.Method, 1
		case "uri":
			dst, bit = &r.URI, 2
		case "client_ip":
			dst, bit = &r.ClientIP, 4
		case "remote_ip":
			dst, bit = &r.RemoteIP, 8
		}
		if dst != nil && got&bit == 0 && s.peek() == '"' {
			vs, ve, ok := s.str()
			if !ok {
				return false
			}
			if ve-vs <= maxStr {
				got |= bit
				*dst = s.b[vs:ve:ve]
			}
		} else if !s.skip(1) {
			return false
		}
		if s.byte('}') {
			return true
		}
		if !s.byte(',') {
			return false
		}
	}
}

// fastNumber: a plain integer of up to 15 digits is exact as a float64 without strconv; anything
// else (a fraction, an exponent) through strconv, as the decoder.
func fastNumber(v []byte) float64 {
	if len(v) > 0 && len(v) <= 15 {
		n := int64(0)
		for _, c := range v {
			if c < '0' || c > '9' {
				f, _ := strconv.ParseFloat(string(v), 64)
				return f
			}
			n = n*10 + int64(c-'0')
		}
		return float64(n)
	}
	f, _ := strconv.ParseFloat(string(v), 64)
	return f
}
