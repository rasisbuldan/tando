// Package journal reads journalctl's output for tando-logs: the JSON entries of `tando logs`
// (-o json) and the short lines of the counts and the error scan (-o short-unix). Everything in
// an entry was written by the app, so it is parsed as data with a bound on every line, and a
// message is shown only after its control characters are neutralised (Display).
//
// A parser of package logs: it imports logs/lines and the standard library only (no files, no
// commands, no Env).
package journal

import (
	"bytes"
	"encoding/json/jsontext"
	"io"
)

// Entry holds the fields tando-logs reads from one `journalctl -o json` line, each as its raw
// JSON value (a string with its quotes and escapes, a byte array, null), sliced from the line:
// valid as long as the line is.
type Entry struct {
	Cursor, Realtime, Message, Priority, SystemdUnit, Unit, PID []byte
}

// Parser decodes entries; one Parser is reused for every line (no allocation per line).
type Parser struct {
	br  bytes.Reader
	dec *jsontext.Decoder
}

// opts: journalctl writes valid UTF-8 (other bytes become a byte array), but a line is never
// trusted to be what journalctl writes; a repeated field keeps its first value.
var opts = []jsontext.Options{jsontext.AllowInvalidUTF8(true), jsontext.AllowDuplicateNames(true)}

// NewParser returns a Parser.
func NewParser() *Parser {
	p := &Parser{}
	p.dec = jsontext.NewDecoder(&p.br, opts...)
	return p
}

// Parse fills e from line; false when line is not a JSON object.
func (p *Parser) Parse(line []byte, e *Entry) bool {
	*e = Entry{}
	p.br.Reset(line)
	p.dec.Reset(&p.br, opts...)
	if t, err := p.dec.ReadToken(); err != nil || t.Kind() != '{' {
		return false
	}
	for p.dec.PeekKind() != '}' {
		name, err := p.dec.ReadValue()
		if err != nil {
			return false
		}
		var dst *[]byte
		switch string(name) {
		case `"__CURSOR"`:
			dst = &e.Cursor
		case `"__REALTIME_TIMESTAMP"`:
			dst = &e.Realtime
		case `"MESSAGE"`:
			dst = &e.Message
		case `"PRIORITY"`:
			dst = &e.Priority
		case `"_SYSTEMD_UNIT"`:
			dst = &e.SystemdUnit
		case `"UNIT"`:
			dst = &e.Unit
		case `"_PID"`:
			dst = &e.PID
		}
		if dst == nil || *dst != nil {
			if err := p.dec.SkipValue(); err != nil {
				return false
			}
			continue
		}
		v, err := p.dec.ReadValue()
		if err != nil {
			return false
		}
		// the value as it is in the line (the decoder's own copy is reused by the next read)
		end := int(p.dec.InputOffset())
		*dst = line[end-len(v) : end]
	}
	// the object closes and nothing follows it: a line is one JSON object
	if t, err := p.dec.ReadToken(); err != nil || t.Kind() != '}' {
		return false
	}
	_, err := p.dec.ReadToken()
	return err == io.EOF
}

// Str is a raw value's text as the shell's jstr gave it: a string's content with its escapes
// left as they are, any other value as written (a number, null).
func Str(raw []byte) []byte {
	if len(raw) >= 2 && raw[0] == '"' {
		return raw[1 : len(raw)-1]
	}
	return raw
}
