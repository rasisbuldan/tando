// Package outtest is for tests: hostile text to feed through a program's output paths, and a
// check that what came out is clean (srv/README.md, Output). It is imported by _test.go files
// only.
package outtest

import (
	"fmt"
	"unicode/utf8"
)

// Hostile holds what must never reach the client's terminal as it is: C0 controls (an escape
// sequence, a bell, a carriage return, a backspace), DEL, C1 controls in UTF-8 (U+0085,
// U+009B: CSI) and as lone bytes (0x9b), and bidirectional overrides (U+202E, U+2066, U+200F,
// U+061C). It has no tab or newline: those end a field or a row, so each test puts them where
// it means them.
const Hostile = "h\x1b[31m\x07\r\x08\x7f\u0085\u009b\x9b[2J‮evil⁦‏؜x"

// Check reports the first byte of b that a cleaned output may not hold: anything Clean of
// srv/internal/out removes, except the tab and newline between fields and rows. Bytes that
// are not UTF-8 but no C1 control may pass (Clean keeps them).
func Check(b []byte) error { return check(b, true) }

// CheckControls is Check without the bidi rule: for tando-logs' journal lines, which keep a
// bidi override as the shell's awk did (the client's lx_clean drops it).
func CheckControls(b []byte) error { return check(b, false) }

func check(b []byte, bidi bool) error {
	for i := 0; i < len(b); {
		r, n := utf8.DecodeRune(b[i:])
		switch {
		case r == utf8.RuneError && n == 1 && b[i] >= 0x80 && b[i] <= 0x9f:
			return fmt.Errorf("byte %d: a lone C1 byte %#x in %q", i, b[i], context(b, i))
		case r == '\t' || r == '\n':
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r <= 0x9f):
			return fmt.Errorf("byte %d: control %U in %q", i, r, context(b, i))
		case !bidi:
		case r == 0x200e || r == 0x200f || (r >= 0x202a && r <= 0x202e) || (r >= 0x2066 && r <= 0x2069) || r == 0x061c:
			return fmt.Errorf("byte %d: bidi override %U in %q", i, r, context(b, i))
		}
		i += n
	}
	return nil
}

func context(b []byte, i int) []byte { return b[max(0, i-40):min(len(b), i+40)] }
