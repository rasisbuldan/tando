package studio

import (
	"bufio"
	"strconv"
	"unicode/utf8"
)

// jw writes JSON by hand onto a buffered writer, so a large result streams to the browser as
// it arrives instead of being built in memory. Strings: < > & and U+2028/9 are escaped (the
// output is safe to embed anywhere), control characters as \u00XX, invalid UTF-8 becomes U+FFFD.
type jw struct {
	w     *bufio.Writer
	comma []bool // per open container: something was written in it
	key   bool   // a key was just written: the value needs no comma
}

const hexd = "0123456789abcdef"

func (j *jw) sep() {
	if j.key {
		j.key = false
		return
	}
	if n := len(j.comma); n > 0 {
		if j.comma[n-1] {
			j.w.WriteByte(',')
		}
		j.comma[n-1] = true
	}
}

func (j *jw) open(c byte) *jw  { j.sep(); j.w.WriteByte(c); j.comma = append(j.comma, false); return j }
func (j *jw) close(c byte) *jw { j.w.WriteByte(c); j.comma = j.comma[:len(j.comma)-1]; return j }
func (j *jw) obj() *jw         { return j.open('{') }
func (j *jw) end() *jw         { return j.close('}') }
func (j *jw) arr() *jw         { return j.open('[') }
func (j *jw) aend() *jw        { return j.close(']') }

func (j *jw) k(name string) *jw {
	j.sep()
	j.raw(name)
	j.w.WriteByte(':')
	j.key = true
	return j
}

func (j *jw) s(v string) *jw  { j.sep(); j.raw(v); return j }
func (j *jw) b(v []byte) *jw  { j.sep(); j.rawb(v); return j }
func (j *jw) i(v int64) *jw   { j.sep(); j.w.WriteString(strconv.FormatInt(v, 10)); return j }
func (j *jw) null() *jw       { j.sep(); j.w.WriteString("null"); return j }
func (j *jw) bool(v bool) *jw { j.sep(); j.w.WriteString(strconv.FormatBool(v)); return j }

func (j *jw) raw(s string) {
	j.w.WriteByte('"')
	for i := 0; i < len(s); {
		if c := s[i]; c < utf8.RuneSelf {
			j.ascii(c)
			i++
			continue
		}
		r, n := utf8.DecodeRuneInString(s[i:])
		if !j.special(r, n) {
			j.w.WriteString(s[i : i+n])
		}
		i += n
	}
	j.w.WriteByte('"')
}

func (j *jw) rawb(s []byte) {
	j.w.WriteByte('"')
	for i := 0; i < len(s); {
		if c := s[i]; c < utf8.RuneSelf {
			j.ascii(c)
			i++
			continue
		}
		r, n := utf8.DecodeRune(s[i:])
		if !j.special(r, n) {
			j.w.Write(s[i : i+n])
		}
		i += n
	}
	j.w.WriteByte('"')
}

// special writes the escape of an invalid byte (U+FFFD) or of U+2028/9 and says it did
func (j *jw) special(r rune, n int) bool {
	switch {
	case r == utf8.RuneError && n == 1:
		j.w.WriteString(`\ufffd`)
	case r == 0x2028 || r == 0x2029:
		j.w.WriteString(`\u202`)
		j.w.WriteByte(hexd[r&0xf])
	default:
		return false
	}
	return true
}

func (j *jw) ascii(c byte) {
	switch {
	case c == '"' || c == '\\':
		j.w.WriteByte('\\')
		j.w.WriteByte(c)
	case c == '\n':
		j.w.WriteString(`\n`)
	case c == '\t':
		j.w.WriteString(`\t`)
	case c < 0x20 || c == '<' || c == '>' || c == '&' || c == 0x7f:
		j.w.WriteString(`\u00`)
		j.w.WriteByte(hexd[c>>4])
		j.w.WriteByte(hexd[c&0xf])
	default:
		j.w.WriteByte(c)
	}
}
