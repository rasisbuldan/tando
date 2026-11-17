package reqlog

import "strconv"

// caddyParse reads a line in the exact layout Caddy 2.6-2.11 writes with tando's log filter:
//
//	{"level":S,"ts":N,"logger":S,"msg":S,"request":{"remote_ip":S,"remote_port":S[,"client_ip":S],
//	 "proto":S,"method":S,"host":S,"uri":S},"bytes_read":N[,"user_id":S],"duration":N,"size":N,
//	 "status":N}
//
// Keys are compared as literals and only the values are scanned, so a line costs one pass over
// its values. Every value is checked as JSON (escapes, no control bytes, the number grammar), so
// a line it accepts is one the decoder accepts with the same fields (FuzzFast). Anything else
// returns false: fastParse, then the decoder, decide.
func caddyParse(b []byte, r *Request) bool {
	*r = Request{}
	i := lit(b, 0, `{"level":`)
	i, _, _ = strVal(b, i)
	i = lit(b, i, `,"ts":`)
	i, r.Ts = numVal(b, i)
	i = lit(b, i, `,"logger":`)
	i, _, _ = strVal(b, i)
	i = lit(b, i, `,"msg":`)
	i, _, _ = strVal(b, i)
	i = lit(b, i, `,"request":{"remote_ip":`)
	var s, e int
	i, s, e = strVal(b, i)
	r.RemoteIP = cut(b, s, e)
	i = lit(b, i, `,"remote_port":`)
	i, _, _ = strVal(b, i)
	if j := lit(b, i, `,"client_ip":`); j >= 0 {
		i, s, e = strVal(b, j)
		r.ClientIP = cut(b, s, e)
	}
	i = lit(b, i, `,"proto":`)
	i, _, _ = strVal(b, i)
	i = lit(b, i, `,"method":`)
	i, s, e = strVal(b, i)
	r.Method = cut(b, s, e)
	i = lit(b, i, `,"host":`)
	i, _, _ = strVal(b, i)
	i = lit(b, i, `,"uri":`)
	i, s, e = strVal(b, i)
	r.URI = cut(b, s, e)
	i = lit(b, i, `},"bytes_read":`)
	i, _ = numVal(b, i)
	if j := lit(b, i, `,"user_id":`); j >= 0 {
		i, _, _ = strVal(b, j)
	}
	i = lit(b, i, `,"duration":`)
	i, r.Duration = numVal(b, i)
	i = lit(b, i, `,"size":`)
	i, r.Size = numVal(b, i)
	i = lit(b, i, `,"status":`)
	i, r.Status = numVal(b, i)
	return i >= 0 && i == len(b)-1 && b[i] == '}'
}

// lit: b[i:] starts with l; the index after it, -1 when not (or when i is already -1).
func lit(b []byte, i int, l string) int {
	if i < 0 || len(b)-i < len(l) || string(b[i:i+len(l)]) != l {
		return -1
	}
	return i + len(l)
}

// cut: the string's content as the decoder gives it (a non-nil empty slice for "", nothing for
// one over maxStr bytes); -1 bounds (a failed read) give nil, and the line fails anyway.
func cut(b []byte, s, e int) []byte {
	if s < 0 || e-s > maxStr {
		return nil
	}
	return b[s:e:e]
}

// strVal reads a JSON string at b[i]; it returns the index after it and its content's bounds.
func strVal(b []byte, i int) (int, int, int) {
	if i < 0 || i >= len(b) || b[i] != '"' {
		return -1, -1, -1
	}
	i++
	s := i
	for i < len(b) {
		c := b[i]
		switch {
		case c == '"':
			return i + 1, s, i
		case c < 0x20:
			return -1, -1, -1
		case c == '\\':
			if i+1 >= len(b) {
				return -1, -1, -1
			}
			switch b[i+1] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
				i += 2
			case 'u':
				if i+5 >= len(b) {
					return -1, -1, -1
				}
				v := hexval(b[i+2 : i+6])
				if v < 0 || v >= 0xd800 && v <= 0xdfff {
					return -1, -1, -1
				}
				i += 6
			default:
				return -1, -1, -1
			}
		default:
			i++
		}
	}
	return -1, -1, -1
}

// numVal reads a JSON number at b[i] (its grammar checked) and its value, as strconv.ParseFloat
// rounds it, in one pass.
func numVal(b []byte, i int) (int, float64) {
	if i < 0 || i >= len(b) {
		return -1, 0
	}
	start := i
	neg := b[i] == '-'
	if neg {
		i++
	}
	var m uint64
	nd := 0 // digits accumulated in m (leading zeros of the value not counted)
	frac := 0
	switch {
	case i < len(b) && b[i] == '0':
		i++
	case i < len(b) && b[i] >= '1' && b[i] <= '9':
		for i < len(b) && b[i] >= '0' && b[i] <= '9' {
			if nd < 19 {
				m = m*10 + uint64(b[i]-'0')
			}
			nd++
			i++
		}
	default:
		return -1, 0
	}
	if i < len(b) && b[i] == '.' {
		i++
		d := i
		for i < len(b) && b[i] >= '0' && b[i] <= '9' {
			if nd < 19 {
				m = m*10 + uint64(b[i]-'0')
				frac++
			}
			if m != 0 {
				nd++
			}
			i++
		}
		if i == d {
			return -1, 0
		}
	}
	exp := false
	if i < len(b) && (b[i] == 'e' || b[i] == 'E') {
		exp = true
		i++
		if i < len(b) && (b[i] == '+' || b[i] == '-') {
			i++
		}
		d := i
		for i < len(b) && b[i] >= '0' && b[i] <= '9' {
			i++
		}
		if i == d {
			return -1, 0
		}
	}
	// m / 10^frac is correctly rounded by one IEEE division when both are exact in a float64
	// (m <= 2^53, frac <= 22): the classic fast path, as strconv's own. Anything else: strconv.
	if exp || nd >= 19 || m > 1<<53 || frac >= len(pow10) {
		f, _ := strconv.ParseFloat(string(b[start:i]), 64)
		return i, f
	}
	f := float64(m)
	if frac > 0 {
		f /= pow10[frac]
	}
	if neg {
		f = -f
	}
	return i, f
}

var pow10 = [...]float64{1, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12, 1e13, 1e14, 1e15,
	1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22}

// decimal: the value of a checked JSON number (numVal's rule).
func decimal(v []byte) float64 {
	_, f := numVal(v, 0)
	return f
}
