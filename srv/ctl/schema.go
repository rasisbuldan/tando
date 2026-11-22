package ctl

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"

	"tando/srv/internal/valid"
)

// Version is the schema version: a request names it ("v": 1), a response carries it. A change
// that an older control plane could misread gets a new version; fields are only ever added.
const Version = 1

// MaxRequest is the largest request accepted (bytes).
const MaxRequest = 256 << 10

// Request is one JSON object on stdin.
type Request struct {
	V         int             `json:"v"`
	Verb      string          `json:"verb"`
	App       string          `json:"app,omitempty"`
	RequestID string          `json:"request_id,omitempty"`
	Args      json.RawMessage `json:"args,omitempty"`
}

// Response is one JSON object on stdout, followed by a newline.
type Response struct {
	V         int    `json:"v"`
	OK        bool   `json:"ok"`
	Verb      string `json:"verb,omitempty"`
	App       string `json:"app,omitempty"`
	RequestID string `json:"request_id,omitempty"`
	// Replayed: the stored response of an earlier request with this id (nothing ran again).
	Replayed bool   `json:"replayed,omitempty"`
	Result   any    `json:"result,omitempty"`
	Error    *Error `json:"error,omitempty"`
	Warning  string `json:"warning,omitempty"`
}

// Error codes: bad_request, unsupported_version, unknown_verb, forbidden, not_found, conflict
// (a request_id reused for another request), pending (still running: ask again), busy (try
// again), failed (the verb ran and failed; message says why), interrupted (cut off by a crash),
// internal.
type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func fail(r Request, code, msg string) Response {
	return Response{V: Version, Verb: r.Verb, App: r.App, RequestID: r.RequestID, Error: &Error{Code: code, Message: msg}}
}

var requestIDRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{7,63}$`)

// ValidRequestID: 8 to 64 characters of letters, digits and . _ : - (a UUID or a ULID fits).
func ValidRequestID(s string) bool { return requestIDRe.MatchString(s) }

// Parse reads and checks a request: one JSON object, no unknown fields, a known version and verb,
// a valid app name where the verb takes one, a request_id on every mutating verb. The verb's own
// arguments are checked by the verb (decodeArgs).
func Parse(in []byte) (Request, *Error) {
	var r Request
	if len(in) > MaxRequest {
		return r, &Error{"bad_request", fmt.Sprintf("the request is over %d bytes", MaxRequest)}
	}
	dec := json.NewDecoder(bytes.NewReader(in))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&r); err != nil {
		return Request{}, &Error{"bad_request", "not a request object: " + clean(err.Error())}
	}
	if _, err := dec.Token(); err != io.EOF {
		return Request{}, &Error{"bad_request", "one request object per session"}
	}
	if r.V != Version {
		return r, &Error{"unsupported_version", fmt.Sprintf("schema version %d is not supported (this node speaks %d)", r.V, Version)}
	}
	v, ok := verbs[r.Verb]
	if !ok {
		r.Verb = clean(r.Verb)
		return r, &Error{"unknown_verb", "unknown verb: " + r.Verb + " (verbs: " + strings.Join(verbNames(), ", ") + ")"}
	}
	switch {
	case v.app == appRequired && r.App == "":
		return r, &Error{"bad_request", r.Verb + " needs an app"}
	case v.app == appNone && r.App != "":
		return r, &Error{"bad_request", r.Verb + " takes no app"}
	case r.App != "" && !valid.App(r.App):
		r.App = clean(r.App)
		return r, &Error{"bad_request", "bad app name"}
	}
	if v.write && !ValidRequestID(r.RequestID) {
		return r, &Error{"bad_request", "a mutating request needs a request_id: 8 to 64 of A-Z a-z 0-9 . _ : - (a UUID fits)"}
	}
	if r.RequestID != "" && !ValidRequestID(r.RequestID) {
		r.RequestID = ""
		return r, &Error{"bad_request", "bad request_id"}
	}
	return r, nil
}

// decodeArgs decodes a verb's arguments strictly into dst (absent: dst stays as it is).
func decodeArgs(r Request, dst any) *Error {
	if len(r.Args) == 0 || string(r.Args) == "null" {
		return nil
	}
	dec := json.NewDecoder(bytes.NewReader(r.Args))
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		return &Error{"bad_request", "args: " + clean(err.Error())}
	}
	return nil
}

// clean keeps a message to printable ASCII and 300 bytes (it may echo input).
func clean(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c < 0x20 || c > 0x7e {
			b[i] = '?'
		}
	}
	if len(b) > 300 {
		b = b[:300]
	}
	return string(b)
}
