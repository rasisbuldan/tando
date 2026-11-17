// Package out writes what a server program prints for the client: tab-separated rows whose first
// field names the row type, and key=value lines. The client parses both and never evaluates
// them, but it does print them on the admin's terminal, so every field passes through Clean.
//
// Every byte a verb prints goes through the one Writer its main made. Row, Fields and KV clean
// what they are given; the two methods that do not are named for what they carry: Relay (output
// another Writer made and cleaned: tandod's answer, a tando program's rows) and Stream (text that
// is not rows and that the verb neutralised itself: tando-logs' journal lines and configuration
// snippets). srv/README.md, Output, lists who may call them.
//
// A leaf: standard library only (tando-gate links it).
package out

import (
	"bufio"
	"io"
	"strings"
	"unicode/utf8"
)

// Writer buffers output; call Flush at the end. After the first write error every later call
// does nothing and Flush returns that error.
type Writer struct {
	w *bufio.Writer
}

// New returns a Writer on w.
func New(w io.Writer) *Writer { return &Writer{w: bufio.NewWriter(w)} }

// NewSize returns a Writer on w with a buffer of size bytes.
func NewSize(w io.Writer, size int) *Writer { return &Writer{w: bufio.NewWriterSize(w, size)} }

// Row writes one tab-separated row. Each field is cleaned; an empty field becomes "-", so the
// client's `IFS=$'\t' read` keeps the columns (bash collapses empty tab-separated fields).
func (w *Writer) Row(fields ...string) {
	for i, f := range fields {
		if i > 0 {
			w.w.WriteByte('\t')
		}
		if f = Clean(f); f == "" {
			f = "-"
		}
		w.w.WriteString(f)
	}
	w.w.WriteByte('\n')
}

// Fields writes one tab-separated row whose empty fields stay empty: where the shell printed a
// line of fields as it was (awk's print of a history line, the gate passing on the agent's rows).
// Each field is cleaned.
func (w *Writer) Fields(fields ...string) {
	for i, f := range fields {
		if i > 0 {
			w.w.WriteByte('\t')
		}
		w.w.WriteString(Clean(f))
	}
	w.w.WriteByte('\n')
}

// KV writes "key=value", both cleaned (a key is usually the program's own constant, which
// cleaning leaves as it is; deploy-status prints the keys of a file).
func (w *Writer) KV(key, value string) {
	w.w.WriteString(Clean(key))
	w.w.WriteByte('=')
	w.w.WriteString(Clean(value))
	w.w.WriteByte('\n')
}

// Relay writes b as it is: output another Writer made, whose fields were cleaned there (tandod's
// answer to tando-watch and tando-status; tando-watch brief's and tando-metrics read's rows in
// tando-status's status). Cleaning it again would turn its tabs and newlines into "?".
func (w *Writer) Relay(b []byte) { w.w.Write(b) }

// Stream is the buffered output itself, for text that is not rows and that the verb neutralises
// itself before writing it (tando-logs: journal lines through journal.Filter, configuration
// snippets made of checked values). Rows written before are ahead of it in the same buffer.
func (w *Writer) Stream() *bufio.Writer { return w.w }

// Flush writes what is buffered and reports the first write error.
func (w *Writer) Flush() error { return w.w.Flush() }

// Clean makes s safe as one field of one line, like the agent's san_v: C0 controls (tab and
// newline included) and DEL become "?", and so do C1 controls (U+0080-U+009F, and a lone byte
// 0x80-0x9F that is not valid UTF-8: a terminal can read 0x9B as CSI). Bidirectional overrides
// (U+200E/F, U+202A-E, U+2066-9, U+061C) are dropped, as tando-watch's clean and the client's
// strip do: they make a line display differently from what it says. Other bytes, also invalid
// UTF-8, are kept.
func Clean(s string) string {
	if isPlain(s) {
		return s
	}
	return Cleaner{Ctrl: '?', LoneC1: true}.clean(s)
}

// isPlain: printable ASCII only, the common case (numbers, names), with nothing to replace.
func isPlain(s string) bool {
	for i := 0; i < len(s); i++ {
		if c := s[i]; c < 0x20 || c >= 0x7f {
			return false
		}
	}
	return true
}

// Cleaner is a rule that makes untrusted text one safe line. Clean is the client's rule; the
// shell versions of tando-watch and tando-gate had rules of their own, which their messages,
// state files and notifications keep (watch's clean, gate's clean), expressed as other values
// of these fields. Every rule turns C0 controls (tab and newline too), DEL and C1 controls
// (U+0080-U+009F) into Ctrl.
type Cleaner struct {
	Ctrl      byte // what a control character becomes
	LoneC1    bool // a lone byte 0x80-0x9F that is not UTF-8 becomes Ctrl too (else it is kept)
	ValidUTF8 bool // any other byte that is not UTF-8 becomes U+FFFD (else it is kept)
	KeepBidi  bool // bidirectional overrides are kept (else dropped, and not counted by MaxRunes)
	MaxRunes  int  // at most this many characters come out; 0: no limit
	MaxBytes  int  // the result is cut to this many bytes (a character may be cut); 0: no limit
}

// Clean applies the rule to s.
func (c Cleaner) Clean(s string) string { return c.clean(s) }

func (c Cleaner) clean(s string) string {
	var b strings.Builder
	b.Grow(len(s))
	n := 0
	for i := 0; i < len(s) && (c.MaxRunes <= 0 || n < c.MaxRunes); {
		r, w := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && w == 1:
			switch ch := s[i]; {
			case c.LoneC1 && ch >= 0x80 && ch <= 0x9f:
				b.WriteByte(c.Ctrl)
			case c.ValidUTF8:
				b.WriteRune(utf8.RuneError)
			default:
				b.WriteByte(ch)
			}
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f):
			b.WriteByte(c.Ctrl)
		case !c.KeepBidi && isBidi(r):
			i += w
			continue // dropped: not counted
		default:
			b.WriteString(s[i : i+w])
		}
		i += w
		n++
	}
	res := b.String()
	if c.MaxBytes > 0 && len(res) > c.MaxBytes {
		res = res[:c.MaxBytes]
	}
	return res
}

func isBidi(r rune) bool {
	return r == 0x200e || r == 0x200f || (r >= 0x202a && r <= 0x202e) || (r >= 0x2066 && r <= 0x2069) || r == 0x061c
}
