package gate

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"tando/srv/internal/bashread"
	"tando/srv/internal/buildinfo"
	"tando/srv/internal/out"
	"tando/srv/internal/run"
)

// Key is key mode: the deploy user's login shell running a key's forced command (args are the
// shell's: "-c", "<gate> key <id>"). One request per ssh session.
func (g *Gate) Key(args []string) (err error) {
	defer func() { g.logRefusal(err) }()
	keyID, err := ForcedKeyID(args, g.P.Gate)
	if err != nil {
		return err
	}
	if g.Caller.UID == 0 || g.Caller.EUID == 0 {
		return die("key mode never runs as root")
	}
	app, ok := g.CallerApp(g.Caller.UID)
	if !ok || g.Caller.UID != g.Caller.EUID {
		return die("this login is not a tando deploy user")
	}
	g.app, g.keyID = app, keyID
	req, err := ParseRequest(g.Caller.SSHCommand, Want{App: app, Agent: g.P.Agent, Incoming: g.incoming(app)})
	if err != nil {
		return err
	}
	return g.dispatchKey(app, req)
}

// dispatchKey runs a checked request: every argv is built here from constants, the caller's app
// and the request's checked values.
func (g *Gate) dispatchKey(app string, req Request) error {
	switch req.Verb {
	case VRsync:
		// checked here for a quick, clear refusal; root checks the session's request again, then
		// runs the receiver confined. stdin and stdout are the rsync stream. A child, not an
		// exec: root mode identifies the session by this process (session.go).
		return g.sudoRoot(app, "receive", g.Stdin, uploadTimeout+5*60)
	case VInfo:
		return g.info()
	case VBegin:
		return g.sudoRoot(app, "begin", nil, 10*60)
	case VEnd:
		tok := req.Token
		if !req.TokenSent {
			tok = g.readToken()
		}
		if !validToken(tok) {
			return die("bad request")
		}
		return g.sudoRoot(app, "end", strings.NewReader("token="+tok+"\n"), 10*60)
	case VActivate:
		tok := req.Token
		if !req.TokenSent {
			tok = g.readToken()
		}
		if !validToken(tok) {
			return die("bad request")
		}
		p := fmt.Sprintf("token=%s\nbuild=%s\nupload=%s\n", tok, req.Build, req.Upload)
		return g.sudoRoot(app, "activate", strings.NewReader(p), 2*60*60)
	case VDeployStatus:
		a := []string{"deploy-status", app, req.ID}
		if req.Wait != "" {
			a = append(a, req.Wait)
		}
		return g.agentRO(func(f []string, l string) bool { return deployStatusKey(l) }, a...)
	case VReleases:
		// (release rows only: never the origin row, user@machine:path of the last deployer)
		return g.agentRO(func(f []string, l string) bool { return f[0] == "rel" }, "releases", app)
	case VHistory:
		return g.agentRO(func(f []string, l string) bool { return f[0] == "hist" && len(f) > 1 && f[1] == app },
			"history", app, req.HistoryN)
	case VStatus:
		return g.agentRO(func(f []string, l string) bool {
			switch f[0] {
			case "host", "rel":
				return true
			case "app", "hist":
				return len(f) > 1 && f[1] == app
			}
			return false
		}, "status", app)
	}
	return die("bad request")
}

// sudoRoot asks root mode (through the exact sudo rule) for verb, with stdout and stderr passed
// through; its exit status is ours.
func (g *Gate) sudoRoot(app, verb string, stdin io.Reader, secs int) error {
	c := run.Cmd{Argv: []string{"sudo", "-n", "--", g.P.Gate, "root", app, verb}, Stdin: stdin,
		Stdout: g.Stdout, Stderr: g.Stderr, Timeout: time.Duration(secs) * time.Second}
	if _, err := g.Env.Run.Output(context.Background(), c); err != nil {
		return Exit{ExitCode(err)}
	}
	return nil
}

// readToken reads a token from stdin (`IFS= read -r -t 10 -n 64`): up to a newline or 64 bytes,
// within 10 s; "" at the end of the input or after the timeout.
// stdin is used for nothing else afterwards (root mode gets the token on a pipe of its own), so
// it may be switched to non-blocking for the deadline.
func (g *Gate) readToken() string {
	fd, err := syscall.Dup(int(g.Stdin.Fd()))
	if err != nil {
		return ""
	}
	syscall.CloseOnExec(fd)
	syscall.SetNonblock(fd, true) // (a pipe or socket gets the deadline; a file needs none)
	f := os.NewFile(uintptr(fd), "stdin")
	defer f.Close()
	f.SetReadDeadline(time.Now().Add(10 * time.Second))
	s, ok := readPiece(bufio.NewReaderSize(f, 64), 64)
	if !ok {
		return ""
	}
	return s
}

// info: the server's CPU and libc, for the client to pick its tools.
func (g *Gate) info() error {
	o, err := g.quiet(10*time.Second, "uname", "-m")
	if err != nil {
		return err
	}
	w := out.New(g.Stdout)
	// (proto first, as the agent prints it: a deploy key's client checks it like an admin's;
	// without it a client from after 0.1.1 took this server for 0.1.1 and refused every deploy)
	w.KV("proto", buildinfo.Proto)
	w.KV("arch", strings.TrimSpace(string(o)))
	libc := "glibc"
	if m, _ := filepath.Glob(g.P.Musl); len(m) > 0 {
		libc = "musl"
	}
	w.KV("libc", libc)
	// deploy-status takes wait=<phase> here (an older gate refuses it: the client asks first)
	w.KV("dswait", "1")
	return w.Flush()
}

var deployStatusKeys = []string{"id", "phase", "result", "message", "link", "venv", "started", "soak",
	"t_build", "t_upload", "t_copy", "t_preflight", "t_release", "t_switch", "t_verify", "waiting_for", "waiting_phase", "waiting_left", "waited"}

// deployStatusKey: a deploy-status line the key may see (no log= lines: they can carry
// customer data).
func deployStatusKey(l string) bool {
	k, _, ok := strings.Cut(l, "=")
	if !ok {
		return false
	}
	for _, w := range deployStatusKeys {
		if k == w {
			return true
		}
	}
	return false
}

// agentRO runs a read-only verb of tando-agent as this user (never as root) and passes on the
// lines keep accepts: rows of other apps and application log lines are dropped. At most 2000
// bytes of the agent's stderr pass. Each field is cleaned again (control characters) and the
// lines keep their columns; the agent's exit status is ours.
func (g *Gate) agentRO(keep func(f []string, l string) bool, args ...string) error {
	stderr := &capped{w: g.Stderr, left: 2000}
	o, err := g.Env.Run.Output(context.Background(), run.Cmd{Argv: append([]string{g.P.Agent}, args...),
		Stderr: stderr, Timeout: 2 * time.Minute})
	w := out.New(g.Stdout)
	for _, l := range bashread.LinesAll(o) {
		if f := strings.Split(l, "\t"); keep(f, l) {
			w.Fields(f...) // (the agent ran as the deploy user: its output is cleaned again)
		}
	}
	if ferr := w.Flush(); ferr != nil && err == nil {
		return ferr
	}
	if err != nil {
		return Exit{ExitCode(err)}
	}
	return nil
}

// capped passes on the first left bytes and drops the rest (head -c).
type capped struct {
	w    io.Writer
	left int
}

func (c *capped) Write(p []byte) (int, error) {
	if c.left > 0 {
		n := min(c.left, len(p))
		c.w.Write(p[:n])
		c.left -= n
	}
	return len(p), nil
}
