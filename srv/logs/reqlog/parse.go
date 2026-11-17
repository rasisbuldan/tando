// Package reqlog reads the request log Caddy writes for each app (/var/log/tando/<app>/
// access.log and its rolled files): one JSON object per line, request headers, response
// headers, TLS details and query strings already removed by Caddy's log filter. It turns lines
// into the summary of `tando requests`, the rows of tail and errors, and the per-minute numbers
// of the error scan. Lines are parsed with encoding/json/jsontext, one reused decoder, without
// an allocation per line; the values a visitor controls (method, path, address) are kept raw and
// made printable only when shown (AppendClean).
//
// A parser of package logs: it imports logs/journal, internal/out and the standard library only
// (no files, no commands, no Env).
package reqlog

import (
	"bytes"
	"encoding/json/jsontext"
	"io"
	"strconv"
)

// MaxLine bounds the bytes of a line that are read (Caddy accepts request headers of up to
// 1 MB, so a path can be that long); a longer line is not a request.
const MaxLine = 2 << 20

// maxStr: a string value of more than this many bytes reads as empty. The shell version looked
// for the closing quote within 4096 bytes of the opening one; the same bound keeps a row's size
// bounded.
const maxStr = 4095

// Request is the part of a line tando reads. Strings are the raw JSON content, escapes intact;
// nil when absent, not a string, or too long. A number that is absent is 0.
type Request struct {
	Ts, Duration, Status, Size      float64
	Method, URI, ClientIP, RemoteIP []byte
}

// Parser decodes lines; reuse one for a whole file.
type Parser struct {
	br  bytes.Reader
	dec *jsontext.Decoder
	buf []byte // the request's strings, copied out of the decoder's buffer
}

var opts = []jsontext.Options{jsontext.AllowInvalidUTF8(true), jsontext.AllowDuplicateNames(true)}

// NewParser returns a Parser.
func NewParser() *Parser {
	p := &Parser{buf: make([]byte, 0, 1024)}
	p.dec = jsontext.NewDecoder(&p.br, opts...)
	return p
}

// Parse fills r from line; false when it is not a JSON object. r's strings are valid until the
// next call (and as long as line). Lines of the shape Caddy writes go through a hand-written
// scanner (fast.go); anything else through encoding/json/jsontext.
func (p *Parser) Parse(line []byte, r *Request) bool {
	if caddyParse(line, r) || fastParse(line, r) {
		return true
	}
	return p.Decode(line, r)
}

// Decode is Parse by the JSON decoder alone (the reference fastParse is held to).
func (p *Parser) Decode(line []byte, r *Request) bool {
	*r = Request{}
	p.buf = p.buf[:0]
	p.br.Reset(line)
	p.dec.Reset(&p.br, opts...)
	d := p.dec
	if t, err := d.ReadToken(); err != nil || t.Kind() != '{' {
		return false
	}
	var seen uint8 // a repeated key keeps its first value, as the shell's search did
	for d.PeekKind() != '}' {
		name, err := d.ReadValue()
		if err != nil {
			return false
		}
		var dst *float64
		var bit uint8
		switch string(name) {
		case `"ts"`:
			dst, bit = &r.Ts, 1
		case `"duration"`:
			dst, bit = &r.Duration, 2
		case `"status"`:
			dst, bit = &r.Status, 4
		case `"size"`:
			dst, bit = &r.Size, 8
		case `"request"`:
			if seen&16 == 0 && d.PeekKind() == '{' {
				seen |= 16
				if !p.request(r) {
					return false
				}
				continue
			}
		}
		if dst == nil || seen&bit != 0 || d.PeekKind() != '0' {
			if err := d.SkipValue(); err != nil {
				return false
			}
			continue
		}
		v, err := d.ReadValue()
		if err != nil {
			return false
		}
		seen |= bit
		*dst = number(v)
	}
	return end(d)
}

// end: the object closes and nothing but blanks follows it (a line is one JSON object).
func end(d *jsontext.Decoder) bool {
	if t, err := d.ReadToken(); err != nil || t.Kind() != '}' {
		return false
	}
	_, err := d.ReadToken()
	return err == io.EOF
}

// request reads the "request" object: method, uri, client_ip (Caddy 2.7+), remote_ip.
func (p *Parser) request(r *Request) bool {
	d := p.dec
	if _, err := d.ReadToken(); err != nil {
		return false
	}
	var pos [4][2]int
	for d.PeekKind() != '}' {
		name, err := d.ReadValue()
		if err != nil {
			return false
		}
		k := -1
		switch string(name) {
		case `"method"`:
			k = 0
		case `"uri"`:
			k = 1
		case `"client_ip"`:
			k = 2
		case `"remote_ip"`:
			k = 3
		}
		if k < 0 || pos[k][1] != 0 || d.PeekKind() != '"' {
			if err := d.SkipValue(); err != nil {
				return false
			}
			continue
		}
		v, err := d.ReadValue()
		if err != nil {
			return false
		}
		if s := v[1 : len(v)-1]; len(s) <= maxStr {
			pos[k] = [2]int{len(p.buf), len(p.buf) + len(s)}
			p.buf = append(p.buf, s...)
			if len(s) == 0 {
				pos[k][1] = -1 // present and empty
			}
		}
	}
	if _, err := d.ReadToken(); err != nil {
		return false
	}
	get := func(k int) []byte {
		switch {
		case pos[k][1] > 0:
			return p.buf[pos[k][0]:pos[k][1]]
		case pos[k][1] < 0:
			return []byte{}
		}
		return nil
	}
	r.Method, r.URI, r.ClientIP, r.RemoteIP = get(0), get(1), get(2), get(3)
	return true
}

// number: a JSON number (checked by the decoder). Out of range is ±Inf, as strtod gives.
func number(v []byte) float64 {
	f, _ := strconv.ParseFloat(string(v), 64)
	return f
}

// Addr is the client address shown: client_ip (Caddy 2.7+, the address after trusted proxies),
// else remote_ip.
func (r *Request) Addr() []byte {
	if len(r.ClientIP) > 0 {
		return r.ClientIP
	}
	return r.RemoteIP
}

// Counted reports whether a line is a request at all. Status 0 is a request the client closed
// before the answer (Caddy 2.6 logs no status), which the app still ran: it counts, as
// "aborted". Without a status and without a method the line is not a request.
func (r *Request) Counted() bool { return r.Status != 0 || len(r.Method) > 0 }
