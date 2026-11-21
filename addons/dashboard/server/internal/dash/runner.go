package dash

import (
	"bufio"
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
	// streams: how long to wait for a free ssh slot of Host before giving up with ErrNoSlot
	SlotWait time.Duration
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

// Streamer: a Runner that also hands out the child's stdout line by line, while it runs
// (`tando logs -f`). line gets a slice it must copy to keep; it is never called after Stream
// returns.
type Streamer interface {
	Stream(ctx context.Context, r Req, line func([]byte)) (Result, error)
}

// ErrNoSlot: every ssh session tando-dash may use on that host is taken
var ErrNoSlot = errors.New("all 3 ssh sessions tando-dash may use on this server are busy (other log streams or reads)")

// MaxLine: a longer stdout line is cut there (and is then not JSON: the stream drops it)
const MaxLine = 64 << 10

// Stream: like Run, but stdout goes to line as it comes. The child's slot is held until it
// ends. Ends when the child exits (its process group is then killed too: an ssh it left behind
// would keep the pipe open) or when ctx ends (the group is killed).
func (x *ExecRunner) Stream(ctx context.Context, r Req, line func([]byte)) (Result, error) {
	if _, err := Allowed(r.Argv); err != nil {
		return Result{}, err
	}
	path := x.Path()
	if path == "" {
		return Result{}, &CLIError{Code: "start", Msg: "tando not found (install tando, or start tando-dash with --tando PATH)"}
	}
	if x.Lim != nil {
		actx, cancel := ctx, context.CancelFunc(func() {})
		if r.SlotWait > 0 {
			actx, cancel = context.WithTimeout(ctx, r.SlotWait)
		}
		rel, err := x.Lim.Acquire(actx, r.Host)
		cancel()
		if err != nil {
			if ctx.Err() != nil {
				return Result{}, ctx.Err()
			}
			return Result{}, ErrNoSlot
		}
		defer rel()
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		return Result{}, &CLIError{Code: "start", Msg: "could not run tando: " + err.Error()}
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		outR.Close()
		outW.Close()
		return Result{}, &CLIError{Code: "start", Msg: "could not run tando: " + err.Error()}
	}
	cmd := exec.Command(path, r.Argv...)
	cmd.Env = append(os.Environ(), x.Env...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Stdout, cmd.Stderr = outW, errW // files: Wait has no copying of its own to wait for
	err = cmd.Start()
	outW.Close()
	errW.Close()
	if err != nil {
		outR.Close()
		errR.Close()
		return Result{}, &CLIError{Code: "start", Msg: "could not run " + path + ": " + err.Error()}
	}
	pid := cmd.Process.Pid
	res := Result{Pid: pid}
	if r.OnStart != nil {
		r.OnStart(pid)
	}
	outDone, errDone := make(chan struct{}), make(chan struct{})
	errw := &capWriter{max: stderrKeep}
	go func() { defer close(outDone); readLines(outR, line) }()
	go func() { defer close(errDone); _, _ = io.Copy(errw, errR) }()
	waited := make(chan error, 1)
	go func() { waited <- cmd.Wait() }()
	var werr error
	select {
	case werr = <-waited:
	case <-ctx.Done():
		_ = syscall.Kill(-pid, syscall.SIGKILL)
		werr = <-waited
	}
	// what the CLI left in its group (an ssh) holds the pipes: the group goes too
	_ = syscall.Kill(-pid, syscall.SIGKILL)
	for _, c := range []struct {
		done chan struct{}
		f    *os.File
	}{{outDone, outR}, {errDone, errR}} {
		select {
		case <-c.done:
		case <-time.After(2 * time.Second):
			c.f.Close() // a child that left the group: stop reading what it writes
			<-c.done
		}
		c.f.Close()
	}
	res.Stderr = firstLines(errw.b.String(), 5)
	if cmd.ProcessState != nil {
		res.Exit = cmd.ProcessState.ExitCode()
	}
	switch {
	case ctx.Err() != nil:
		return res, &CLIError{Code: "cancelled", Exit: res.Exit, Msg: "cancelled"}
	case werr != nil:
		msg := firstLine(res.Stderr)
		if msg == "" {
			msg = fmt.Sprintf("tando %s ended with status %d", r.Argv[0], res.Exit)
		}
		return res, &CLIError{Code: "cli", Exit: res.Exit, Msg: msg}
	}
	return res, &CLIError{Code: "ended", Msg: "the log stream ended"}
}

// readLines: r's lines to line, without the newline; a line longer than MaxLine is cut there
func readLines(r io.Reader, line func([]byte)) {
	br := bufio.NewReaderSize(r, MaxLine)
	long := false
	for {
		b, err := br.ReadSlice('\n')
		if err == bufio.ErrBufferFull {
			if !long {
				line(b)
			}
			long = true
			continue
		}
		if len(b) > 0 && !long {
			line(bytes.TrimRight(b, "\r\n"))
		}
		long = false
		if err != nil {
			return
		}
	}
}
