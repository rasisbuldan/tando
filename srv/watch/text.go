package watch

import (
	"fmt"
	"strings"
	"unicode/utf8"

	"tando/srv/internal/decimal"
	"tando/srv/internal/out"
)

// maxText is how long an alert detail, a history line or a notification line may be, in
// characters (the shell's clean: `${s:0:300}` in C.UTF-8).
const maxText = 300

// clean makes s one safe line for the state, the history and the notifications (the shell's
// clean): bidi overrides (U+200E/F, U+202A-E, U+2066-9, U+061C) are dropped, control characters
// (C0, DEL and C1) become a space, and it is cut at 300 characters. A byte that is not UTF-8
// becomes a space when it is a C1 control on its own (0x9b is an 8-bit CSI to a terminal), else
// U+FFFD: what comes out is valid UTF-8, which receivers such as Telegram require (the shell
// kept such bytes, and a notifier rejecting them failed for good). Rows for the client go
// through out.Clean as well. (Not out.Clean's rule: a space, the cut and U+FFFD are what the
// shell's state files and messages had, and the receivers' need.)
func clean(s string) string { return textRule(maxText).Clean(s) }

// cleanAll is clean without the length limit: what compose does to every line it reads from a
// queue file, in case an older version queued it unclean.
func cleanAll(s string) string { return textRule(0).Clean(s) }

// textRule is clean's rule, at most max characters (0: no limit).
func textRule(max int) out.Cleaner {
	return out.Cleaner{Ctrl: ' ', LoneC1: true, ValidUTF8: true, MaxRunes: max}
}

// cut is the first n bytes of s (bash `${s:0:n}` under LC_ALL=C).
func cut(s string, n int) string {
	if len(s) > n {
		return s[:n]
	}
	return s
}

// dur: seconds as "1m 31s", "2h 05m", "3d 4h" (the shell's dur).
func dur(s int64) string {
	switch {
	case s < 60:
		return fmt.Sprintf("%ds", s)
	case s < 3600:
		return fmt.Sprintf("%dm %ds", s/60, s%60)
	case s < 86400:
		return fmt.Sprintf("%dh %02dm", s/3600, s%3600/60)
	default:
		return fmt.Sprintf("%dd %dh", s/86400, s%86400/3600)
	}
}

// jsonString quotes s as the shell's json() did, byte by byte under LC_ALL=C: backslash and
// quote escaped, newline as \n, tab and other control bytes (0x00-0x1f, 0x7f) as a space. Bytes
// that are not UTF-8 (a detail a shell version wrote into the state) become U+FFFD: the result
// is always valid JSON.
func jsonString(s string) string {
	if !utf8.ValidString(s) {
		s = strings.ToValidUTF8(s, "\uFFFD")
	}
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '\\':
			b.WriteString(`\\`)
		case c == '"':
			b.WriteString(`\"`)
		case c == '\n':
			b.WriteString(`\n`)
		case c < 0x20 || c == 0x7f:
			b.WriteByte(' ')
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// mask shows only the scheme and host of a URL: its path and query are secrets (webhook URLs).
func mask(u string) string {
	s, h, ok := strings.Cut(u, "://")
	if !ok {
		h = u
	}
	h, _, _ = strings.Cut(h, "/")
	if i := strings.LastIndexByte(h, '@'); i >= 0 {
		h = h[i+1:]
	}
	return s + "://" + h + "/…"
}

// signame: a signal number as its name (the common ones).
func signame(n string) string {
	switch n {
	case "1":
		return "SIGHUP"
	case "2":
		return "SIGINT"
	case "6":
		return "SIGABRT"
	case "9":
		return "SIGKILL"
	case "11":
		return "SIGSEGV"
	case "13":
		return "SIGPIPE"
	case "15":
		return "SIGTERM"
	}
	return "signal " + n
}

// num reads a decimal number the way the shell used values it had already validated: digits
// (any count; at most 18 are used), an optional leading "-"; anything else is def.
func num(s string, def int64) int64 {
	neg := strings.HasPrefix(s, "-")
	if neg {
		s = s[1:]
	}
	n, ok := decimal.Parse(s, 18)
	if !ok {
		return def
	}
	if neg {
		return -n
	}
	return n
}
