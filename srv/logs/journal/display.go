package journal

import (
	"strconv"

	"tando/srv/logs/lines"
)

// Display is a MESSAGE value as tando logs shows it. Control characters never reach the
// operator's terminal: journald stores a message that is not printable UTF-8 as a byte array,
// and C0 controls become ^X (ESC is ^[), DEL ^?, bytes that are not printable UTF-8 (C1
// controls such as U+009B CSI included) \xHH; in a JSON string, \n and \r are shown as the two
// characters \n and \r and a tab stays a tab. journalctl writes null for a field over 4096
// bytes (unless --all); that is said instead of shown.
func Display(dst, raw []byte) []byte {
	switch {
	case len(raw) == 0:
		return dst
	case raw[0] == '[':
		return appendArray(dst, raw)
	case raw[0] == '"' && len(raw) >= 2:
		return appendUnescaped(dst, raw[1:len(raw)-1], true)
	case string(raw) == "null":
		return append(dst, "[message over 4096 bytes, not shown]"...)
	}
	return dst
}

// appendUnescaped: the content of a JSON string with its escapes made visible. journal: a \t
// escape (and \u0009) is a tab, and \b, \f are ^H, ^L (the request log's rule differs: there
// they stay \b, \f and \u0009 is ^I, see package reqlog).
func appendUnescaped(dst, s []byte, journal bool) []byte {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c != '\\' {
			dst = append(dst, c)
			continue
		}
		if i+1 >= len(s) {
			break // a lone backslash at the end: nothing (awk's substr past the end is "")
		}
		i++
		switch e := s[i]; e {
		case 'n', 'r':
			dst = append(dst, '\\', e)
		case 't':
			if journal {
				dst = append(dst, '\t')
			} else {
				dst = append(dst, '\\', 't')
			}
		case 'b', 'f':
			switch {
			case !journal:
				dst = append(dst, '\\', e)
			case e == 'b':
				dst = append(dst, '^', 'H')
			default:
				dst = append(dst, '^', 'L')
			}
		case 'u':
			h := s[i+1 : min(i+5, len(s))]
			dst = AppendCodePoint(dst, hexval(h), journal)
			i += len(h)
		default:
			dst = append(dst, e)
		}
	}
	return dst
}

// hexval reads up to 4 hex digits; -1 when one is not a hex digit, 0 for none (awk's hexval).
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

// AppendCodePoint is the display form of a \uXXXX escape: C0 as ^X (a tab as a tab when tab is
// set), DEL ^?, C1 \xHH, a surrogate or an unreadable escape "?", else the character in UTF-8.
func AppendCodePoint(dst []byte, cp int, tab bool) []byte {
	switch {
	case cp < 0:
		return append(dst, '?')
	case cp == 9 && tab:
		return append(dst, '\t')
	case cp < 32:
		return append(dst, '^', byte(cp+64))
	case cp == 127:
		return append(dst, '^', '?')
	case cp < 127:
		return append(dst, byte(cp))
	case cp < 160:
		return appendHexByte(dst, cp)
	case cp < 2048:
		return append(dst, byte(192+cp/64), byte(128+cp%64))
	case cp >= 0xd800 && cp <= 0xdfff:
		return append(dst, '?')
	}
	return append(dst, byte(224+cp/4096), byte(128+cp/64%64), byte(128+cp%64))
}

// appendHexByte: \xHH (more digits for a value over 255, as printf %02x).
func appendHexByte(dst []byte, b int) []byte {
	dst = append(dst, '\\', 'x')
	if b >= 0 && b < 16 {
		dst = append(dst, '0')
	}
	return strconv.AppendInt(dst, int64(b), 16)
}

// appendArray: journald's form of a message that is not printable UTF-8, "[104,105,27]". Valid
// UTF-8 sequences of printable characters are kept; every other byte is shown as above.
func appendArray(dst, raw []byte) []byte {
	// the numbers between the brackets, as awk's split(a, B, ",") after removing every [ and ]
	var stack [256]int
	bs := stack[:0]
	var fb [32]byte
	field := fb[:0]
	content := false
	add := func() {
		v := lines.Num(field)
		if v < 0 || v > 1<<20 {
			v = 1 << 20 // not a byte: shown as \xHH of something that is not one
		}
		bs = append(bs, int(v))
		field = field[:0]
	}
	for _, c := range raw {
		switch c {
		case '[', ']':
		case ',':
			content = true
			add()
		default:
			content = true
			if len(field) < cap(field) {
				field = append(field, c)
			}
		}
	}
	if !content {
		return dst
	}
	add()
	n := len(bs)
	for i := 0; i < n; i++ {
		b := bs[i]
		switch {
		case b == 9:
			dst = append(dst, '\t')
		case b < 32:
			dst = append(dst, '^', byte(b+64))
		case b == 127:
			dst = append(dst, '^', '?')
		case b < 128:
			dst = append(dst, byte(b))
		default:
			need := 0
			switch {
			case b >= 194 && b <= 223:
				need = 1
			case b >= 224 && b <= 239:
				need = 2
			case b >= 240 && b <= 244:
				need = 3
			}
			ok := need > 0 && i+need < n
			cp := 0
			if ok {
				cp = b - [4]int{0, 192, 224, 240}[need]
				for j := 1; j <= need; j++ {
					k := bs[i+j]
					if k < 128 || k > 191 {
						ok = false
						break
					}
					cp = cp*64 + k - 128
				}
			}
			// C1 controls, overlong forms, surrogates and values beyond U+10FFFF are not printable UTF-8
			if ok && (cp < 160 || (need == 2 && cp < 2048) || (need == 3 && cp < 65536) ||
				cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) {
				ok = false
			}
			if ok {
				for j := 0; j <= need; j++ {
					dst = append(dst, byte(bs[i+j]))
				}
				i += need
			} else {
				dst = appendHexByte(dst, b)
			}
		}
	}
	return dst
}
