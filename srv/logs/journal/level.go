package journal

import (
	"bytes"
	"regexp"

	"tando/srv/logs/lines"
)

// The level written in a message's text (tando logs --level and its ERR/WARN tags), when it is
// worse than the journal priority: JSON loggers ("level":"error", pino's "level":50), a level
// word (ERROR, WARN, ...), a line starting with [error] or error:, an exception line. A
// heuristic: "ERROR" in another sense counts too. Only the first 300 bytes are looked at.
var (
	reLevelWord  = regexp.MustCompile(`"(?:level|severity|lvl)": *"([A-Za-z]+)"`)
	reLevelNum   = regexp.MustCompile(`"level": *([0-9]+)`)
	reLevelUpper = regexp.MustCompile(`(?:^|[^A-Za-z])(FATAL|PANIC|CRITICAL|CRIT|ERROR|WARNING|WARN|NOTICE|INFO|DEBUG|TRACE)(?:[^A-Za-z]|$)`)
	reLevelLower = regexp.MustCompile(`^\[?(fatal|error|warn|warning|info|debug)[\]:]`)
	reLevelExc   = regexp.MustCompile(`^(?:Uncaught |Unhandled |[A-Z][A-Za-z]*Error: )`)
	upperWords   = []string{"FATAL", "PANIC", "CRIT", "ERROR", "WARN", "NOTICE", "INFO", "DEBUG", "TRACE"}
)

// TextLevel is the syslog priority a message's text claims, -1 for none.
func TextLevel(m []byte) int {
	h := m[:min(len(m), 300)]
	if bytes.Contains(h, []byte(`"`)) {
		if s := reLevelWord.FindSubmatchIndex(h); s != nil {
			return wordLevel(h[s[2]:s[3]])
		}
		if s := reLevelNum.FindSubmatchIndex(h); s != nil {
			switch w := lines.Num(h[s[2]:s[3]]); {
			case w >= 60:
				return 2
			case w >= 50:
				return 3
			case w >= 40:
				return 4
			case w >= 30:
				return 6
			default:
				return 7
			}
		}
	}
	for _, w := range upperWords {
		if bytes.Contains(h, []byte(w)) {
			if s := reLevelUpper.FindSubmatchIndex(h); s != nil {
				return wordLevel(h[s[2]:s[3]])
			}
			break
		}
	}
	if len(h) > 0 && (h[0] == '[' || (h[0] >= 'a' && h[0] <= 'z')) {
		if s := reLevelLower.FindSubmatchIndex(h); s != nil {
			return wordLevel(h[s[2]:s[3]])
		}
	}
	if len(h) > 0 && h[0] >= 'A' && h[0] <= 'Z' && reLevelExc.Match(h) {
		return 3
	}
	return -1
}

// wordLevel is the priority of a level word (any case), -1 when it is not one.
func wordLevel(w []byte) int {
	var b [16]byte
	if len(w) > len(b) {
		return -1
	}
	l := b[:len(w)]
	for i, c := range w {
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		l[i] = c
	}
	switch string(l) {
	case "emerg", "emergency", "alert", "fatal", "panic", "crit", "critical":
		return 2
	case "err", "error":
		return 3
	case "warn", "warning":
		return 4
	case "notice":
		return 5
	case "info":
		return 6
	case "debug", "trace":
		return 7
	}
	return -1
}
