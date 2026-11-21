package dash

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Req: one run of the tando CLI
type Req struct {
	Argv    []string
	Host    string   // for the per-host cap (ssh sessions); "" for laptop-only runs
	Out     *os.File // writes: the child's stdout and stderr go to this file (it survives tando-dash)
	Stdin   []byte   // M4 env set: the value, never in argv
	OnStart func(pid int)
}

// Result of a run that ended
type Result struct {
	Stdout []byte
	Stderr string // the first lines
	Exit   int
	Pid    int
}

// Runner runs the tando CLI. ExecRunner is the real one; tests use FuncRunner.
type Runner interface {
	Run(ctx context.Context, r Req) (Result, error)
}

// FuncRunner: a Runner from a function (tests)
type FuncRunner func(ctx context.Context, r Req) (Result, error)

func (f FuncRunner) Run(ctx context.Context, r Req) (Result, error) { return f(ctx, r) }

// CLIError: a run that did not end well, with what the page shows
type CLIError struct {
	Code string // cli (non-zero exit), timeout, cancelled, too_large, start
	Exit int
	Msg  string
}

func (e *CLIError) Error() string { return e.Msg }

// ErrBusy: too many runs waiting already
var ErrBusy = errors.New("tando-dash is busy: too many tando commands waiting")

// ExecRunner: execve of the tando CLI only, argv checked against the allowlist, each child in
// its own process group (killed as a group on timeout or cancel), stdout capped, the first
// lines of stderr kept, a bounded number of children (in all and per host).
type ExecRunner struct {
	Path   func() string
	Env    []string // added to the environment
	MaxOut int      // stdout bytes kept; more kills the child
	Lim    *Limiter
}

const stderrKeep = 4096

func (x *ExecRunner) Run(ctx context.Context, r Req) (Result, error) {
	if _, err := Allowed(r.Argv); err != nil {
		return Result{}, err
	}
	path := x.Path()
	if path == "" {
		return Result{}, &CLIError{Code: "start", Msg: "tando not found (install tando, or start tando-dash with --tando PATH)"}
	}
	if x.Lim != nil {
		rel, err := x.Lim.Acquire(ctx, r.Host)
		if err != nil {
			return Result{}, err
		}
		defer rel()
	}
	cctx, cancel := context.WithCancel(ctx)
	defer cancel()
	cmd := exec.CommandContext(cctx, path, r.Argv...)
	cmd.Env = append(os.Environ(), x.Env...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.WaitDelay = 2 * time.Second
	if r.Stdin != nil {
		cmd.Stdin = bytes.NewReader(r.Stdin)
	}
	out := &capWriter{max: x.MaxOut, over: cancel}
	errw := &capWriter{max: stderrKeep}
	if r.Out != nil {
		cmd.Stdout, cmd.Stderr = r.Out, r.Out
	} else {
		cmd.Stdout, cmd.Stderr = out, errw
	}
	if err := cmd.Start(); err != nil {
		return Result{}, &CLIError{Code: "start", Msg: "could not run " + path + ": " + err.Error()}
	}
	res := Result{Pid: cmd.Process.Pid}
	if r.OnStart != nil {
		r.OnStart(res.Pid)
	}
	err := cmd.Wait()
	res.Stdout, res.Stderr = out.b.Bytes(), firstLines(errw.b.String(), 5)
	if cmd.ProcessState != nil {
		res.Exit = cmd.ProcessState.ExitCode()
	}
	switch {
	case out.overflow:
		return res, &CLIError{Code: "too_large", Exit: res.Exit, Msg: fmt.Sprintf("tando printed more than %d bytes", x.MaxOut)}
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		return res, &CLIError{Code: "timeout", Exit: res.Exit, Msg: "tando did not answer in time"}
	case ctx.Err() != nil:
		return res, &CLIError{Code: "cancelled", Exit: res.Exit, Msg: "cancelled"}
	case err != nil:
		msg := firstLine(res.Stderr)
		if msg == "" {
			msg = fmt.Sprintf("tando %s ended with status %d", r.Argv[0], res.Exit)
		}
		return res, &CLIError{Code: "cli", Exit: res.Exit, Msg: msg}
	}
	return res, nil
}

type capWriter struct {
	b        bytes.Buffer
	max      int
	overflow bool
	over     func()
}

func (c *capWriter) Write(p []byte) (int, error) {
	if c.max > 0 && c.b.Len()+len(p) > c.max {
		room := c.max - c.b.Len()
		if room > 0 {
			c.b.Write(p[:room])
		}
		if c.over != nil && !c.overflow {
			c.overflow = true
			c.over()
		}
		return len(p), nil
	}
	c.b.Write(p)
	return len(p), nil
}

var _ io.Writer = (*capWriter)(nil)

func firstLines(s string, n int) string {
	ls := strings.SplitN(strings.TrimSpace(s), "\n", n+1)
	if len(ls) > n {
		ls = ls[:n]
	}
	return strings.Join(ls, "\n")
}

func firstLine(s string) string {
	l, _, _ := strings.Cut(strings.TrimSpace(s), "\n")
	l = strings.TrimPrefix(l, "tando: ")
	if len(l) > 300 {
		l = l[:300]
	}
	return l
}

// Limiter: at most max children in all and maxPer per host (B3: the ssh master allows 10
// sessions and the CLI, the menu bar and deploys share it), with a bounded number waiting.
type Limiter struct {
	mu      sync.Mutex
	max     int
	maxPer  int
	maxWait int
	total   int
	waiting int
	per     map[string]int
	wake    chan struct{}
}

func NewLimiter(max, maxPer, maxWait int) *Limiter {
	return &Limiter{max: max, maxPer: maxPer, maxWait: maxWait, per: map[string]int{}, wake: make(chan struct{})}
}

// Acquire a slot for host; the returned func gives it back
func (l *Limiter) Acquire(ctx context.Context, host string) (func(), error) {
	l.mu.Lock()
	for {
		if l.total < l.max && (host == "" || l.per[host] < l.maxPer) {
			l.total++
			if host != "" {
				l.per[host]++
			}
			l.mu.Unlock()
			var once sync.Once
			return func() { once.Do(func() { l.release(host) }) }, nil
		}
		if l.waiting >= l.maxWait {
			l.mu.Unlock()
			return nil, ErrBusy
		}
		l.waiting++
		ch := l.wake
		l.mu.Unlock()
		select {
		case <-ch:
		case <-ctx.Done():
			l.mu.Lock()
			l.waiting--
			l.mu.Unlock()
			return nil, ctx.Err()
		}
		l.mu.Lock()
		l.waiting--
	}
}

func (l *Limiter) release(host string) {
	l.mu.Lock()
	l.total--
	if host != "" {
		if l.per[host]--; l.per[host] <= 0 {
			delete(l.per, host)
		}
	}
	close(l.wake)
	l.wake = make(chan struct{})
	l.mu.Unlock()
}

// Running: children now (tests)
func (l *Limiter) Running() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.total
}
