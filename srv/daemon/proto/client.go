package proto

// The client side: how the CLIs ask tandod first and when they do the work themselves. The
// policy is here, in one place, for tando-watch and tando-status (their main calls Ask*).

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"strings"
	"time"

	"tando/srv/internal/decimal"
)

// connectTimeout: a CLI gives up on the daemon after this long without a connection and runs the
// verb itself.
const connectTimeout = 100 * time.Millisecond

// delegated is how a CLI verb is asked of the daemon: the request's verb and how long the whole
// exchange may take.
type delegated struct {
	Verb    string
	Timeout time.Duration
}

// watchVerb says whether tando-watch asks tandod for verb: show, history, health and brief are
// answered from the daemon's state (35 s: more than its 30 per verb). `run` goes through RunTick.
func watchVerb(verb string) (delegated, bool) {
	switch verb {
	case "show", "history", "health", "brief":
		return delegated{verb, 35 * time.Second}, true
	}
	return delegated{}, false
}

// The time budget of `tando-watch run` (TimeoutStartSec of its units is 300 s): tandod's tick may
// take up to 250 s, waited for 260; when nothing answers, the run here gets what is left of
// runBudget (never more than the tick limit the caller gives).
const (
	runBudget = 290 * time.Second
	tickWait  = 260 * time.Second
)

// RunTick is `tando-watch run`: tandod runs the tick when it answers (one at a time, its own
// sample); when it is not there, refuses (degraded), or dies without an answer, local runs it,
// with what is left of the budget.
func RunTick(ctx context.Context, maxLocal time.Duration, local func(context.Context) error) error {
	return runTick(ctx, Socket, runBudget, tickWait, maxLocal, local)
}

func runTick(ctx context.Context, path string, budget, wait, maxLocal time.Duration, local func(context.Context) error) error {
	start := time.Now()
	a, err := Call(ctx, path, Request{Verb: "tick"}, connectTimeout, min(wait, budget))
	if err == nil {
		if !a.OK {
			return errors.New(a.Err)
		}
		return nil
	}
	left := budget - time.Since(start)
	if left <= 0 {
		return errors.New("no time left for the checks: tandod did not answer")
	}
	lctx, cancel := context.WithTimeout(ctx, min(left, maxLocal))
	defer cancel()
	return local(lctx)
}

// AskWatch asks tandod for a verb of tando-watch. ok false: not a delegated verb, a request the
// protocol does not carry (FromArgs), or nothing answered: tando-watch runs the verb itself, so
// every message is its own. An "err" answer is an answer (ok true, a.OK false): the daemon ran
// the verb and it failed.
func AskWatch(ctx context.Context, verb string, args []string) (a Answer, ok bool) {
	d, ok := watchVerb(verb)
	if !ok {
		return Answer{}, false
	}
	return ask(ctx, d, args)
}

// AskStatus asks tandod for `status [app]` (srv/status's Collector, in the daemon; 35 s: more
// than the daemon's 30 per verb, so a slow status is not computed twice). ok is
// true only for an "ok" answer: with no daemon, a refusal, an error or an "err" answer
// tando-status collects itself, so its error messages stay its own.
func AskStatus(ctx context.Context, app string) ([]byte, bool) {
	var args []string
	if app != "" {
		args = []string{app}
	}
	a, ok := ask(ctx, delegated{"status", 35 * time.Second}, args)
	if !ok || !a.OK {
		return nil, false
	}
	return a.Body, true
}

// AskLive asks tandod for `live [app]`, the fast loop's latest point (5 s). ok is true only for
// an "ok" answer: an older daemon does not know the verb, and one on a host without cgroup v2
// answers "err"; either way the caller has no live rows (tando-status follow: the client polls).
func AskLive(ctx context.Context, app string) ([]byte, bool) {
	var args []string
	if app != "" {
		args = []string{app}
	}
	a, ok := ask(ctx, delegated{"live", 5 * time.Second}, args)
	if !ok || !a.OK {
		return nil, false
	}
	return a.Body, true
}

func ask(ctx context.Context, d delegated, args []string) (Answer, bool) {
	r, err := FromArgs(d.Verb, args)
	if err != nil {
		return Answer{}, false
	}
	a, err := Call(ctx, Socket, r, connectTimeout, d.Timeout)
	return a, err == nil
}

// ErrNoDaemon: nothing answers on the socket (not running, not root, an old server).
var ErrNoDaemon = errors.New("tandod is not running")

// Answer is what the daemon said.
type Answer struct {
	OK   bool
	Err  string // the message of an "err" header
	Body []byte
}

// maxAnswer bounds what a client reads.
const maxAnswer = 16 << 20

// Call sends r to the daemon at path and reads its answer. Connecting gives up after
// connectTimeout (ErrNoDaemon); the whole exchange after timeout.
func Call(ctx context.Context, path string, r Request, connectTimeout, timeout time.Duration) (Answer, error) {
	d := net.Dialer{Timeout: connectTimeout}
	c, err := d.DialContext(ctx, "unix", path)
	if err != nil {
		return Answer{}, ErrNoDaemon
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(timeout))
	io.WriteString(c, r.String()+"\n") // (a failed write still leaves an answer to read, if any)
	return ReadAnswer(c)
}

// ReadAnswer reads a framed answer (Header). Anything short of it, a closed connection before the
// header (refused, shutting down) or a body shorter than its header said (the daemon died while
// writing), is ErrNoDaemon: the client does the work itself and prints no part of an answer.
func ReadAnswer(r io.Reader) (Answer, error) {
	br := bufio.NewReaderSize(io.LimitReader(r, maxAnswer+512), 4096)
	head, err := br.ReadString('\n')
	if err != nil || len(head) > 512 {
		return Answer{}, ErrNoDaemon
	}
	head = strings.TrimSuffix(head, "\n")
	kind, rest, _ := strings.Cut(head, " ")
	lenField, msg, _ := strings.Cut(rest, " ")
	n, ok := decimal.Parse(lenField, 9)
	if !ok || n > maxAnswer || (kind == "ok" && msg != "") || (kind != "ok" && kind != "err") {
		return Answer{}, ErrNoDaemon
	}
	body := make([]byte, n)
	if _, err := io.ReadFull(br, body); err != nil {
		return Answer{}, ErrNoDaemon
	}
	if kind == "ok" {
		return Answer{OK: true, Body: body}, nil
	}
	return Answer{Err: msg, Body: body}, nil
}
