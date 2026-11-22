// Package ctl is the control plane's machine interface (docs/CONTROL-PLANE.md): one JSON request
// on stdin, one JSON response on stdout, over ssh, as the user tando-ctl.
//
// sshd admits tando-ctl only with an OpenSSH user certificate signed by the control plane's CA
// (TrustedUserCAKeys; validity, source-address and the revocation list are sshd's), and maps the
// certificate's principal to a forced command (tando-gate's ctl-principals): tando-ctl-read,
// tando-ctl-write, or tando-app-<app> for one app. tando-gate checks the session and hands the
// request to this package as root, with the identity sshd established (Ident): what the request
// may do comes from there, never from the request.
//
// Files: ctl.go (Serve, Ident, the access rule), schema.go (Request, Response, Parse), store.go
// (request ids: pending/result store, per-app order), verbs.go (the verbs), read.go (inventory,
// status, alerts).
//
// Layer: domain. It imports internal/* only.
package ctl

import (
	"context"
	"encoding/json"
	"io"
	"path/filepath"
	"regexp"
	"strconv"
	"time"

	"tando/srv/internal/env"
)

// Mode is what a certificate's principal allows.
type Mode string

const (
	ModeRead  Mode = "read"  // tando-ctl-read: the read verbs, every app
	ModeWrite Mode = "write" // tando-ctl-write: every verb, every app
	ModeApp   Mode = "app"   // tando-app-<app>: that app's read verbs and its safe mutating ones
)

// Ident is who sent the request, as sshd established it.
type Ident struct {
	Mode   Mode
	App    string // ModeApp's app
	Serial string // the certificate's serial ("-": unknown)
	KeyID  string // the certificate's key id ("-": unknown or unprintable)
}

// Ctl runs requests on this node.
type Ctl struct {
	Env    env.Env
	Dir    string // /var/lib/tando/ctl: the request store
	Usage  string // /var/lib/tando/usage: the metering ledger
	Mets   string // /var/lib/tando/metrics
	Alerts string // /var/lib/tando/watch/state
	// Caller is passed to tando-agent as SUDO_USER (its audit line names it).
	Caller string
	Log    func(msg string) // one line per request (the journal); nil: none
}

// agentPath is tando-agent (a constant: the argv the verbs build is reviewed, tools/srvlint).
const agentPath = "/opt/tando/bin/tando-agent"

// New is the node's Ctl.
func New(e env.Env) *Ctl {
	return &Ctl{Env: e, Dir: filepath.Join(e.Lib, "ctl"),
		Usage: filepath.Join(e.Lib, "usage"), Mets: filepath.Join(e.Lib, "metrics"),
		Alerts: filepath.Join(e.Lib, "watch", "state"), Caller: "tando-ctl"}
}

// Allowed says whether id may run r (r parsed: verb known, app valid).
func Allowed(id Ident, r *Request) *Error {
	v := verbs[r.Verb]
	switch id.Mode {
	case ModeWrite:
		return nil
	case ModeRead:
		if v.write {
			return &Error{"forbidden", r.Verb + " changes the node: it needs the principal tando-ctl-write"}
		}
		return nil
	case ModeApp:
		if v.app == appNone || v.nodeOnly {
			return &Error{"forbidden", r.Verb + " is about the whole node: an app's principal (tando-app-" + id.App + ") cannot ask it"}
		}
		if r.App == "" { // (alerts, usage: an app's principal sees its own app)
			r.App = id.App
		}
		if r.App != id.App {
			return &Error{"forbidden", "this certificate is for the app " + id.App + " only"}
		}
		if v.writeOnly {
			return &Error{"forbidden", r.Verb + " needs the principal tando-ctl-write"}
		}
		return nil
	}
	return &Error{"forbidden", "no access"}
}

// Serve answers one request: it writes the response and returns the exit status (0: ok).
func (c *Ctl) Serve(ctx context.Context, id Ident, in []byte, w io.Writer) int {
	start := c.Env.Now()
	ctx = withIdent(ctx, id)
	r, perr := Parse(in)
	var resp Response
	switch {
	case perr != nil:
		resp = Response{V: Version, Verb: r.Verb, App: r.App, RequestID: r.RequestID, Error: perr}
	default:
		if aerr := Allowed(id, &r); aerr != nil {
			resp = Response{V: Version, Verb: r.Verb, App: r.App, RequestID: r.RequestID, Error: aerr}
			break
		}
		r.ident = id
		v := verbs[r.Verb]
		do := func() Response { return c.run(ctx, v, r) }
		if v.write {
			st := &Store{Dir: c.Dir, Now: c.Env.Now, NS: Namespace(id)}
			resp = st.Do(r, v.timeout+time.Minute, do)
		} else {
			resp = do()
		}
	}
	resp.V = Version
	if c.Log != nil {
		res := "ok"
		if resp.Error != nil {
			res = resp.Error.Code
		}
		if resp.Replayed {
			res += " (replayed)"
		}
		// fields from the request may be anything on an error path: a value that is not a plain
		// word is quoted (Go syntax: no space, newline or control character reaches the journal raw)
		c.Log("ctl " + string(id.Mode) + appSuffix(id) + " serial=" + field(id.Serial) + " key=" + field(id.KeyID) +
			" verb=" + field(or(r.Verb, "?")) + " app=" + field(or(r.App, "-")) + " request_id=" + field(or(r.RequestID, "-")) + values(r) + " result=" + res +
			" secs=" + time.Duration(c.Env.Now().Sub(start)).Truncate(time.Millisecond).String())
	}
	b, err := json.Marshal(resp)
	if err != nil {
		b = []byte(`{"v":1,"ok":false,"error":{"code":"internal","message":"the response could not be encoded"}}`)
	}
	w.Write(append(b, '\n'))
	if resp.OK {
		return 0
	}
	return 1
}

var plainRe = regexp.MustCompile(`^[A-Za-z0-9._:@+-]{1,64}$`)

// field is a log field: as it is when it is a plain word, else quoted.
func field(s string) string {
	if plainRe.MatchString(s) {
		return s
	}
	if len(s) > 100 {
		s = s[:100]
	}
	return strconv.QuoteToASCII(s)
}

// values marks a request that reads secrets (app.export with values): " values=1".
func values(r Request) string {
	var a struct {
		Values bool `json:"values"`
	}
	if r.Verb == "app.export" && json.Unmarshal(r.Args, &a) == nil && a.Values {
		return " values=1"
	}
	return ""
}

// Namespace is the principal's part of the request store: write, read or app-<app>.
func Namespace(id Ident) string {
	if id.Mode == ModeApp {
		return "app-" + id.App
	}
	return string(id.Mode)
}

func appSuffix(id Ident) string {
	if id.Mode == ModeApp {
		return ":" + id.App
	}
	return ""
}

func or(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

// run runs a parsed, allowed request.
func (c *Ctl) run(ctx context.Context, v verb, r Request) Response {
	ctx, cancel := context.WithTimeout(ctx, v.timeout)
	defer cancel()
	res, err := v.run(c, ctx, r)
	if err != nil {
		return fail(r, err.Code, err.Message)
	}
	return Response{V: Version, OK: true, Verb: r.Verb, App: r.App, RequestID: r.RequestID, Result: res}
}
