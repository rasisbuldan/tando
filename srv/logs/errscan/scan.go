// Package errscan finds error events in an app's journal and groups them (tando-logs
// watch-scan and errors, tando errors, tando-watch's errors alert).
//
// An event is a line that looks like an error (level words, JSON levels, error/exception/panic/
// traceback/unhandled/fatal as a word) plus the lines of its stack trace that follow from the
// same process within 2 s: Node ("    at f (file:l:c)"), Python ("Traceback ...",
// '  File "f", line n, in g', the code lines, the final "KeyError: ..."), Go ("panic: ...",
// "goroutine 1 [running]:", functions and "\t/file.go:42 +0x1d"). Fingerprint: exception type +
// first frame of the app's own code (not node_modules, node:internal, site-packages, runtime.),
// numbers, hex and ids replaced, line numbers dropped, so a group survives redeploys; plain
// error lines: the message, normalised. The input is `journalctl -o short-unix --show-cursor`.
//
// A parser of package logs: it imports logs/lines and the standard library only (no files, no
// commands, no Env).
package errscan

import (
	"bytes"
	"regexp"
	"strconv"
	"strings"

	"tando/srv/logs/lines"
)

// Limits on what one event keeps (the shell version's): lines of a message read, lines of an
// event kept, lines an event may span, samples per scan.
const (
	MaxMessage   = 4000
	keptLines    = 30
	maxEventLen  = 400
	maxSamples   = 50
	continueSecs = 2
)

// Event is one error event.
type Event struct {
	T0                 int64  // the first line's time, whole seconds
	ID, Kind           string // group id; node, py, go or line
	Label, Fingerprint string // cleaned (cleanLine)
	Title              string // the first line, cleaned
	Sample             []string
}

// Scanner reads short-unix lines and calls Emit for every event.
type Scanner struct {
	Emit       func(Event)
	Read       int64  // lines read (cursor lines not counted)
	Events     int64  // events emitted
	Suppressed int64  // lines journald dropped ("Suppressed N messages")
	Cursor     string // the last "-- cursor: " seen

	kind   string
	ev     [keptLines]string
	nl     int
	pid    string
	t0     int64
	tl     float64
	pyEnd  bool
	pyType string
	goMsg  string // the first line of the last Go panic (awk's fpx, never reset)
	seen   map[string]bool
	nsamp  int
	low    []byte // the lower-cased line, reused
}

var (
	reTraceback = regexp.MustCompile(`^Traceback \(most recent call last\):`)
	reNodeStart = regexp.MustCompile(`^(Uncaught |Unhandled )?([A-Za-z_$][A-Za-z0-9_$]*\.)*[A-Za-z_$][A-Za-z0-9_$]*(Error|Exception)( \[[A-Z_]+\])?(: |:$|$)`)
	reJSONLevel = regexp.MustCompile(`"level": *(50|60)[,}]`)
	reExcName   = regexp.MustCompile(`(^|[^A-Za-z0-9_])[A-Z][A-Za-z0-9_]*(Error|Exception)(: |:$)`)
	reAt        = regexp.MustCompile(`^[ \t]+at `)
	rePyName    = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_.]*(: |:$|$)`)
	reGoroutine = regexp.MustCompile(`^goroutine [0-9]+ \[`)
	reGoFunc    = regexp.MustCompile(`^[A-Za-z0-9_./*()-]+\(.*\)$`)
	reExit      = regexp.MustCompile(`^exit status [0-9]+$`)
	reNodeLib   = regexp.MustCompile(`node_modules|node:|\(internal/|\(<anonymous>\)`)
	rePyLib     = regexp.MustCompile(`site-packages|dist-packages|lib/python[0-9.]*/`)
	rePyFrame   = regexp.MustCompile(`", line [0-9]+, in `)
	reSuppr     = regexp.MustCompile(`^Suppressed ([0-9]+) messages`)
)

// lowerInto: the ASCII lower case of the first 400 bytes (awk's tolower in the C locale), into a
// reused buffer.
func lowerInto(dst, m []byte) []byte {
	dst = dst[:0]
	for _, c := range m[:min(len(m), 400)] {
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		dst = append(dst, c)
	}
	return dst
}

var errorWords = [][]byte{[]byte("error"), []byte("exception"), []byte("panic"), []byte("traceback"),
	[]byte("unhandled"), []byte("fatal"), []byte("critical")}

// hasWord: one of the error words in l with no letter a-z right before or after it, the regex
// (^|[^a-z])(error|exception|...)([^a-z]|$) without running one on every line.
func hasWord(l []byte) bool {
	for _, w := range errorWords {
		for off := 0; ; {
			i := bytes.Index(l[off:], w)
			if i < 0 {
				break
			}
			i += off
			e := i + len(w)
			if (i == 0 || l[i-1] < 'a' || l[i-1] > 'z') && (e == len(l) || l[e] < 'a' || l[e] > 'z') {
				return true
			}
			off = i + 1
		}
	}
	return false
}

// start: the kind of event a message starts, "" for none. The regexes run only on lines that
// pass a cheap necessary condition; most lines are not errors.
func (s *Scanner) start(m []byte) string {
	switch {
	case bytes.HasPrefix(m, []byte("Traceback (most recent call last):")):
		return "py"
	case bytes.HasPrefix(m, []byte("panic: ")) || bytes.HasPrefix(m, []byte("fatal error: ")):
		return "go"
	}
	exc := bytes.Contains(m, []byte("Error")) || bytes.Contains(m, []byte("Exception"))
	if exc && reNodeStart.Match(m) {
		return "node"
	}
	s.low = lowerInto(s.low, m)
	if hasWord(s.low) || (bytes.Contains(s.low, []byte(`"level"`)) && reJSONLevel.Match(s.low)) {
		return "line"
	}
	// an exception name after a logger's prefix ("12:00:01 [api] TypeError: x"): "typeerror" has
	// no word break before "error", so the rule above does not see it
	if exc && reExcName.Match(m) {
		return "line"
	}
	return ""
}

// cont: whether m continues the open event (it may also change its kind: a logging.exception
// line followed by a Python traceback).
func (s *Scanner) cont(m string) bool {
	if reAt.MatchString(m) || strings.HasPrefix(m, `  File "`) || strings.HasPrefix(m, "\t") || strings.HasPrefix(m, "    ") {
		return true
	}
	if s.kind == "py" && (strings.HasPrefix(m, "During handling of the above exception") || strings.HasPrefix(m, "The above exception was")) {
		s.pyEnd = false
		return true
	}
	if s.kind == "py" && !s.pyEnd && strings.HasPrefix(m, "Traceback (most") {
		return true
	}
	if s.kind == "py" && !strings.HasPrefix(m, " ") && rePyName.MatchString(m) && !s.pyEnd {
		s.pyEnd = true
		s.pyType = m
		return true
	}
	if s.kind == "go" && (m == "" || reGoroutine.MatchString(m) || reGoFunc.MatchString(m) || reExit.MatchString(m) ||
		strings.HasPrefix(m, "[signal ") || strings.HasPrefix(m, "created by ")) {
		return true
	}
	if s.kind == "line" && s.nl == 1 && reTraceback.MatchString(m) { // logging.exception
		s.kind = "py"
		s.pyEnd = false
		return true
	}
	return strings.HasPrefix(m, "Caused by: ")
}

// Line reads one line of journalctl's output.
func (s *Scanner) Line(b []byte) {
	if lines.HasPrefix(b, "-- cursor: ") {
		s.Cursor = string(b[11:])
		return
	}
	s.Read++
	ts := lines.Num(b)
	p := lines.Index(b, "]: ")
	if p < 0 {
		return
	}
	hdr := b[:p+1]
	m := b[p+3:]
	if len(m) > MaxMessage {
		m = m[:MaxMessage]
	}
	pid := hdr
	if i := lastIndexByte(pid, '['); i >= 0 {
		pid = pid[i+1:]
	}
	pid = pid[:len(pid)-1] // the "]"
	if lines.Index(hdr, " systemd-journald[") >= 0 {
		if sm := reSuppr.FindSubmatch(m); sm != nil {
			s.Suppressed += int64(lines.Num(sm[1]))
		}
		return
	}
	if s.nl > 0 && string(pid) == s.pid && ts-s.tl <= continueSecs && s.nl < maxEventLen && s.cont(string(m)) {
		if s.nl < keptLines {
			s.ev[s.nl] = string(m)
		}
		s.nl++
		s.tl = ts
		return
	}
	s.flush()
	if k := s.start(m); k != "" {
		s.kind, s.nl, s.ev[0], s.pid = k, 1, string(m), string(pid)
		s.t0, s.tl = int64(ts), ts
		s.pyEnd, s.pyType = false, ""
	}
}

func lastIndexByte(b []byte, c byte) int {
	for i := len(b) - 1; i >= 0; i-- {
		if b[i] == c {
			return i
		}
	}
	return -1
}

// End emits the event still open.
func (s *Scanner) End() { s.flush() }

// line i (0-based) of the event; "" past the 30 kept (awk's unset EV[i])
func (s *Scanner) at(i int) string {
	if i < keptLines {
		return s.ev[i]
	}
	return ""
}

func (s *Scanner) flush() {
	if s.nl == 0 {
		return
	}
	typ, fr := "", ""
	switch s.kind {
	case "node":
		typ = s.ev[0]
		if strings.HasPrefix(typ, "Uncaught ") { // one prefix only, as sub(/^(Uncaught |Unhandled )/)
			typ = typ[len("Uncaught "):]
		} else if strings.HasPrefix(typ, "Unhandled ") {
			typ = typ[len("Unhandled "):]
		}
		typ = cutColon(typ)
		for i := 1; i < s.nl; i++ {
			l := s.at(i)
			if reAt.MatchString(l) && !reNodeLib.MatchString(l) {
				fr = reAt.ReplaceAllLiteralString(l, "")
				break
			}
		}
	case "py":
		typ = cutColon(s.pyType)
		if typ == "" {
			typ = "Traceback"
		}
		for i := 0; i < s.nl; i++ {
			l := s.at(i)
			if strings.HasPrefix(l, `  File "`) && !rePyLib.MatchString(l) {
				fr = strings.TrimPrefix(l, `  File "`)
				if loc := rePyFrame.FindStringIndex(fr); loc != nil {
					fr = fr[:loc[0]] + ":" + fr[loc[1]:]
				}
			}
		}
	case "go":
		typ = "Go panic"
		s.goMsg = s.ev[0]
		if strings.HasPrefix(s.goMsg, "panic: ") {
			s.goMsg = s.goMsg[len("panic: "):]
		} else if strings.HasPrefix(s.goMsg, "fatal error: ") {
			s.goMsg = s.goMsg[len("fatal error: "):]
		}
		for i := 1; i < s.nl; i++ {
			l := s.at(i)
			if reGoFunc.MatchString(l) && !strings.HasPrefix(l, "runtime.") {
				fr = l[:strings.IndexByte(l, '(')]
				break
			}
		}
	}
	if fr != "" {
		fr = frame(fr)
	}
	if len(fr) > 100 {
		fr = "~" + fr[len(fr)-99:]
	}
	var label, fp string
	if s.kind == "line" {
		label = "error line"
		fp = "line|" + lines.Cut(Norm(s.ev[0]), 140)
	} else {
		label = typ
		if fr != "" {
			label += " at " + fr
		}
		fp = s.kind + "|" + typ + "|" + fr
		if s.kind == "go" {
			fp += "|" + lines.Cut(Norm(s.goMsg), 80)
		}
	}
	label = strings.ReplaceAll(label, "\t", " ")
	fp = strings.ReplaceAll(fp, "\t", " ")
	e := Event{T0: s.t0, ID: ID(fp), Kind: s.kind, Label: cleanLine(label), Fingerprint: cleanLine(fp),
		Title: cleanLine(s.ev[0])}
	if s.seen == nil {
		s.seen = map[string]bool{}
	}
	if !s.seen[e.ID] && s.nsamp < maxSamples {
		s.seen[e.ID] = true
		s.nsamp++
		for i := 0; i < s.nl && i < keptLines; i++ {
			e.Sample = append(e.Sample, cleanLine(s.ev[i]))
		}
	}
	s.Events++
	if s.Emit != nil {
		s.Emit(e)
	}
	s.nl, s.kind, s.pyEnd, s.pyType = 0, "", false, ""
}

// cutColon: sub(/:.*/, "") — everything from the first ":" goes.
func cutColon(s string) string {
	if i := strings.IndexByte(s, ':'); i >= 0 {
		return s[:i]
	}
	return s
}

// String is the event as the shell version's scan file line (for tests and debugging).
func (e Event) String() string {
	return "E\t" + strconv.FormatInt(e.T0, 10) + "\t" + e.ID + "\t" + e.Kind + "\t" + e.Label + "\t" + e.Fingerprint + "\t" + e.Title
}
