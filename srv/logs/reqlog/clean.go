package reqlog

import "tando/srv/logs/journal"

// AppendClean appends the printable text of a raw JSON string from the log: escapes shown
// (\u001b as ^[, \n as the two characters \n, \u0085 as \x85), then any byte below 0x20 or DEL,
// and a C1 control in UTF-8, as "?". No tab survives, so the text is one field of a row.
func AppendClean(dst, raw []byte) []byte {
	plain := true
	for _, c := range raw {
		if c < 0x20 || c > 0x7e || c == '\\' {
			plain = false
			break
		}
	}
	if plain {
		return append(dst, raw...)
	}
	start := len(dst)
	for i := 0; i < len(raw); i++ {
		c := raw[i]
		if c != '\\' {
			dst = append(dst, c)
			continue
		}
		if i+1 >= len(raw) {
			break
		}
		i++
		switch e := raw[i]; e {
		case 'n', 'r', 't', 'b', 'f':
			dst = append(dst, '\\', e)
		case 'u':
			h := raw[i+1 : min(i+5, len(raw))]
			dst = journal.AppendCodePoint(dst, hexval(h), false)
			i += len(h)
		default:
			dst = append(dst, e)
		}
	}
	s := dst[start:]
	w := 0
	for r := 0; r < len(s); r++ {
		c := s[r]
		switch {
		case c > 0 && c < 0x20 || c == 0x7f:
			c = '?'
		case c == 0xc2 && r+1 < len(s) && s[r+1] >= 0x80 && s[r+1] <= 0x9f:
			c = '?'
			r++
		}
		s[w] = c
		w++
	}
	return dst[:start+w]
}

func hexval(h []byte) int {
	n := 0
	for _, c := range h {
		switch {
		case c >= '0' && c <= '9':
			n = n*16 + int(c-'0')
		case c >= 'a' && c <= 'f':
			n = n*16 + int(c-'a') + 10
		case c >= 'A' && c <= 'F':
			n = n*16 + int(c-'A') + 10
		default:
			return -1
		}
	}
	return n
}

// AppendPath appends a cleaned path with its ids folded, so that requests group by route:
// /users/123/orders/9f86d081884c7d65 is /users/:n/orders/:id (numbers become :n, hex runs of 16
// or more characters, dashes allowed, :id). The query (already "?-" in the log) is dropped, the
// part before the first "/" too; the result is cut to 80 bytes ("~" marks the cut).
func AppendPath(dst, u []byte) []byte {
	for i, c := range u {
		if c == '?' {
			u = u[:i]
			break
		}
	}
	start := len(dst)
	// split(u, P, "/") and every element after the first, each with its "/" in front
	first := true
	seg := 0
	for i := 0; i <= len(u); i++ {
		if i < len(u) && u[i] != '/' {
			continue
		}
		if first {
			first = false
		} else if len(u) > 0 {
			dst = append(dst, '/')
			dst = appendSegment(dst, u[seg:i])
		}
		seg = i + 1
	}
	if len(dst) == start {
		dst = append(dst, '/')
	}
	if len(dst)-start > 80 {
		dst = append(dst[:start+79], '~')
	}
	return dst
}

func appendSegment(dst, s []byte) []byte {
	if len(s) == 0 {
		return dst
	}
	digits, hex := true, true
	for _, c := range s {
		if c < '0' || c > '9' {
			digits = false
			if !(c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F' || c == '-') {
				hex = false
			}
		}
	}
	switch {
	case digits:
		return append(dst, ":n"...)
	case hex && len(s) >= 16:
		return append(dst, ":id"...)
	}
	return append(dst, s...)
}
