// Package proto is the line protocol of tandod's socket, /run/tandod/tandod.sock (root 0600 in a
// root 0700 directory; the daemon also checks the peer's uid with SO_PEERCRED: 0 only).
//
// A client connects, writes one request line, "<verb> [arg]\n", at most MaxRequest bytes, and
// reads the answer until EOF: a header line, "ok" or "err <message>", then the rows the CLI verb
// prints. Verbs and their argument are checked here, by the client before it sends and by the
// daemon when it reads, with the same rules as the CLI's; a request that does not pass is not
// sent: the client runs the verb itself, so its error message is the CLI's word for word.
//
//	ping                 "last <epoch of the last tick> ticks <n> pid <pid> goroutines <n>"
//	tick                 run the checks now and wait for them (tando-watch run)
//	show [n]  history [n]  health [app]  brief [app]  status [app]
//	live [app]           the fast loop's latest point (srv/live: lhost, lapp rows)
//	ring [app]           its last hour (rhost, rapp rows)
//
// Layer: it imports internal/decimal and the standard library only, no domain package:
// tando-watch and tando-status link it (client.go: when they ask the daemon, with what timeouts).
package proto

import (
	"errors"
	"strings"

	"tando/srv/internal/decimal"
)

// Socket is where tandod listens.
const Socket = "/run/tandod/tandod.sock"

// MaxRequest bounds a request line, its newline included.
const MaxRequest = 128

// Request is a checked request.
type Request struct {
	Verb string
	Arg  string // "" when none
}

func (r Request) String() string {
	if r.Arg == "" {
		return r.Verb
	}
	return r.Verb + " " + r.Arg
}

// ErrBad: a request this protocol does not carry (the caller runs the verb itself).
var ErrBad = errors.New("bad request")

// argKinds: what each verb takes. "n" a count, "app" an app name (or "host" for brief).
var argKinds = map[string]string{"ping": "", "tick": "", "show": "n", "history": "n", "health": "app", "brief": "app", "status": "app", "live": "app", "ring": "app"}

// Parse checks a request line (without its newline).
func Parse(line string) (Request, error) {
	if len(line) >= MaxRequest {
		return Request{}, ErrBad
	}
	for i := 0; i < len(line); i++ {
		if line[i] < 0x20 || line[i] > 0x7e {
			return Request{}, ErrBad
		}
	}
	f := strings.Split(line, " ")
	kind, ok := argKinds[f[0]]
	if !ok || len(f) > 2 || (len(f) == 2 && kind == "") {
		return Request{}, ErrBad
	}
	r := Request{Verb: f[0]}
	if len(f) == 2 {
		r.Arg = f[1]
		switch kind {
		case "n":
			if !count(r.Arg) {
				return Request{}, ErrBad
			}
		case "app":
			if !appName(r.Arg) {
				return Request{}, ErrBad
			}
		}
	}
	return r, nil
}

// count: 1 to 9 decimal digits.
func count(s string) bool { _, ok := decimal.Parse(s, 9); return ok }

// appName: an app name as valid.App has it (^[a-z][a-z0-9-]{1,25}$), checked without regexp.
func appName(s string) bool {
	if len(s) < 2 || len(s) > 26 || s[0] < 'a' || s[0] > 'z' {
		return false
	}
	for i := 1; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

// FromArgs makes a request of a CLI verb and its arguments, or ErrBad when the protocol does not
// carry it (the caller then runs the verb itself).
func FromArgs(verb string, args []string) (Request, error) {
	switch len(args) {
	case 0:
		return Parse(verb)
	case 1:
		if args[0] == "" {
			return Request{}, ErrBad
		}
		return Parse(verb + " " + args[0])
	}
	return Request{}, ErrBad
}

// Header is the first line of an answer, framed: "ok <length of the body>" or "err <length>
// <message>". A client that gets fewer bytes than said (the daemon died while it wrote) has no
// answer and runs the verb itself, instead of printing part of one.
func Header(err error, bodyLen int) string {
	n := decimal.Itoa(int64(bodyLen))
	if err == nil {
		return "ok " + n + "\n"
	}
	// one line: the message of a verb, as the CLI would print it
	return "err " + n + " " + strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return ' '
		}
		return r
	}, err.Error()) + "\n"
}
