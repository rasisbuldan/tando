package journal

import (
	"strconv"
	"time"

	"tando/srv/logs/lines"
)

// Filter decides which entries `tando logs` shows and how. Units are exact names: an entry is
// shown when it comes from one of them (_SYSTEMD_UNIT), or from PID 1 about one of them
// (systemd's own lines: start, stop, exit status). With namespaces, other apps' lines are not in
// the files read anyway; this is the second check.
type Filter struct {
	Roles  map[string]string // unit -> what the text output calls it: app, journald, job:<name>, act, venv, pre, release
	JSON   bool              // one JSON object per line instead of text
	Level  int               // show entries at this priority or worse; -1: all
	Match  func([]byte) bool // the grep, on the displayed message; nil: all
	Ranges [][2]float64      // microseconds [from, to): the periods a release was live; nil: all
	Cursor bool              // prefix each line with the entry's cursor and a tab
	TZOff  int64             // seconds east of UTC for the times shown
	TZS    string            // the same as "+07:00" (JSON times)
	msg    []byte
}

var levelNames = [8]string{"emerg", "alert", "crit", "err", "warning", "notice", "info", "debug"}

// Line appends e's output line (without the newline) to dst. ok is false when the entry is not
// shown; us is its time in microseconds.
func (f *Filter) Line(dst []byte, e *Entry) (out []byte, us float64, ok bool) {
	u, src, ok := f.source(e)
	if !ok {
		return dst, 0, false
	}
	us = lines.Num(Str(e.Realtime))
	if !f.inRanges(us) {
		return dst, 0, false
	}
	f.msg = Display(f.msg[:0], e.Message)
	m := f.msg
	pri := 6
	if p := Str(e.Priority); len(p) > 0 {
		pri = int(lines.Num(p))
	}
	eff := pri
	if src != "systemd" {
		if t := TextLevel(m); t >= 0 && t < eff {
			eff = t
		}
	}
	if f.Level >= 0 && eff > f.Level {
		return dst, 0, false
	}
	if f.Match != nil && !f.Match(m) {
		return dst, 0, false
	}
	if f.Cursor {
		dst = append(dst, Str(e.Cursor)...)
		dst = append(dst, '\t')
	}
	if f.JSON {
		return f.appendJSON(dst, us, src, u, eff, m), us, true
	}
	return f.appendText(dst, us, src, eff, m), us, true
}

// source is the unit of an entry and what the output calls it: an entry of one of the units, or
// one of PID 1 (systemd) about one of them; ok false for anything else.
func (f *Filter) source(e *Entry) (unit []byte, src string, ok bool) {
	u := Str(e.SystemdUnit)
	if src, ok = f.Roles[string(u)]; ok {
		return u, src, true
	}
	if string(Str(e.PID)) != "1" {
		return nil, "", false
	}
	u = Str(e.Unit)
	if _, ok = f.Roles[string(u)]; !ok {
		return nil, "", false
	}
	return u, "systemd", true
}

// inRanges: the time is in one of the release's live periods (or there are none).
func (f *Filter) inRanges(us float64) bool {
	if f.Ranges == nil {
		return true
	}
	for _, r := range f.Ranges {
		if us >= r[0] && us < r[1] {
			return true
		}
	}
	return false
}

// appendJSON: {"time","usec","src","unit","priority","level","msg"}; in msg a backslash, a quote
// and a tab are escaped (the message was neutralised by Display: no other control characters).
func (f *Filter) appendJSON(dst []byte, us float64, src string, u []byte, eff int, m []byte) []byte {
	dst = append(dst, `{"time":"`...)
	dst = f.appendTime(dst, us, true)
	dst = append(dst, `","usec":`...)
	dst = strconv.AppendFloat(dst, us, 'f', 0, 64)
	dst = append(dst, `,"src":"`...)
	dst = append(dst, src...)
	dst = append(dst, `","unit":"`...)
	dst = append(dst, u...)
	dst = append(dst, `","priority":`...)
	dst = strconv.AppendInt(dst, int64(eff), 10)
	dst = append(dst, `,"level":"`...)
	if eff >= 0 && eff < 8 {
		dst = append(dst, levelNames[eff]...)
	}
	dst = append(dst, `","msg":"`...)
	for _, c := range m {
		switch c {
		case '\\':
			dst = append(dst, '\\', '\\')
		case '"':
			dst = append(dst, '\\', '"')
		case '\t':
			dst = append(dst, '\\', 't')
		default:
			dst = append(dst, c)
		}
	}
	return append(dst, `"}`...)
}

// appendText: "<time> [ERR |WARN ][[src] ]<message>", a tab in the message as two spaces.
func (f *Filter) appendText(dst []byte, us float64, src string, eff int, m []byte) []byte {
	dst = f.appendTime(dst, us, false)
	dst = append(dst, ' ')
	switch {
	case eff <= 3:
		dst = append(dst, "ERR "...)
	case eff == 4:
		dst = append(dst, "WARN "...)
	}
	if src != "app" {
		dst = append(dst, '[')
		dst = append(dst, src...)
		dst = append(dst, "] "...)
	}
	for _, c := range m {
		if c == '\t' {
			dst = append(dst, ' ', ' ')
		} else {
			dst = append(dst, c)
		}
	}
	return dst
}

// appendTime: "2026-11-13 23:23:47" in the client's zone; for JSON with a T, milliseconds and
// the offset ("2026-11-13T16:23:47.047+00:00").
func (f *Filter) appendTime(dst []byte, us float64, json bool) []byte {
	s := int64(us / 1e6)
	layout := "2006-01-02 15:04:05"
	if json {
		layout = "2006-01-02T15:04:05"
	}
	dst = time.Unix(s+f.TZOff, 0).UTC().AppendFormat(dst, layout)
	if json {
		ms := int64(us/1000) % 1000
		dst = append(dst, '.', byte('0'+ms/100), byte('0'+ms/10%10), byte('0'+ms%10))
		dst = append(dst, f.TZS...)
	}
	return dst
}
