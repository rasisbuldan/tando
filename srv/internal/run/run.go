// Package run is the only way tando server programs start another program. It takes an argv
// slice, never a command string, and never starts a shell: text that reaches a shell is parsed
// again, and every value tando handles (app names, log lines, settings) would become code there.
// It is also the only package that may import os/exec. Exec starts only the programs of
// Programs (check.go says how that is enforced); tools/srvlint checks on the syntax tree that
// nothing else starts a program or names a shell, and that the programs are constants.
//
// Layer: internal: the standard library only; never a domain package or daemon.
package run

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// BaseEnv is the environment of a command whose Cmd.Env is nil. Nothing is inherited from the
// caller (sudo, systemd or a CI login): LC_ALL=C keeps tool output parseable.
var BaseEnv = []string{"PATH=/usr/sbin:/usr/bin:/sbin:/bin", "LC_ALL=C"}

// defaultTimeout bounds a command whose Cmd.Timeout is zero.
const defaultTimeout = 30 * time.Second

// maxStderr is how much of a failed command's stderr goes into its error.
const maxStderr = 2000

// Cmd is one program to run.
type Cmd struct {
	Argv    []string      // Argv[0] is an absolute path, or a name looked up in Env's PATH
	Env     []string      // the whole environment, "KEY=value"; nil means BaseEnv
	Stdin   io.Reader     // nil: /dev/null
	Stdout  io.Writer     // nil: captured and returned by Output; else streamed here
	Timeout time.Duration // the command is killed after this; 0 means defaultTimeout
	// Dir is the working directory of the command. "" means "/": never the caller's directory,
	// which under sudo or a CI login may be one another user can write (python3 would import a
	// venv.py from it, any program would read a relative path from it).
	Dir string
	// Stderr, when set, receives the command's stderr as it is written (an *os.File is passed
	// to the command itself, as stdin and stdout are); the error then carries no stderr text.
	// nil: the start of stderr goes into the error of a failed command.
	Stderr io.Writer
}

// Runner runs commands. Exec is the real one; tests pass a Func.
type Runner interface {
	// Output runs c and returns its stdout (nil when c.Stdout is set). A non-zero exit, a
	// timeout or a missing program is an error that names the program and carries the start
	// of its stderr.
	Output(ctx context.Context, c Cmd) ([]byte, error)
}

// Func adapts a function to Runner (for tests).
type Func func(ctx context.Context, c Cmd) ([]byte, error)

// Output calls f.
func (f Func) Output(ctx context.Context, c Cmd) ([]byte, error) { return f(ctx, c) }

// Exec runs commands with os/exec.
type Exec struct{}

// Output implements Runner.
func (Exec) Output(ctx context.Context, c Cmd) ([]byte, error) {
	if len(c.Argv) == 0 || c.Argv[0] == "" {
		return nil, errors.New("run: empty argv")
	}
	name := c.Argv[0]
	if err := CheckArgv(c.Argv); err != nil {
		return nil, err
	}
	env := c.Env
	if env == nil {
		env = BaseEnv
	}
	env = scrubEnv(env)
	path, err := lookPath(name, env)
	if err != nil {
		return nil, err
	}
	timeout := c.Timeout
	if timeout == 0 {
		timeout = defaultTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, path, c.Argv[1:]...)
	cmd.Args[0] = name
	cmd.Env = env
	cmd.Dir = c.Dir
	if cmd.Dir == "" {
		cmd.Dir = "/"
	}
	cmd.Stdin = c.Stdin
	// a child that leaves a grandchild holding the pipes must not keep us waiting forever
	cmd.WaitDelay = time.Second
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	if c.Stdout != nil {
		cmd.Stdout = c.Stdout
	}
	cmd.Stderr = &limitedWriter{buf: &stderr, max: maxStderr}
	if c.Stderr != nil {
		cmd.Stderr = c.Stderr
	}

	err = cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, fmt.Errorf("%s: timed out after %s", name, timeout)
	}
	if err != nil {
		if msg := strings.TrimSpace(stderr.String()); msg != "" {
			return nil, fmt.Errorf("%s: %w: %s", name, err, msg)
		}
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	if c.Stdout != nil {
		return nil, nil
	}
	return stdout.Bytes(), nil
}

// lookPath finds name in the PATH of env (not of this process: under sudo or a CI login that
// PATH is not ours to trust).
func lookPath(name string, env []string) (string, error) {
	if strings.Contains(name, "/") {
		return name, nil
	}
	var dirs string
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			dirs = v
		}
	}
	for _, d := range filepath.SplitList(dirs) {
		if d == "" || !filepath.IsAbs(d) {
			continue // a relative PATH entry would depend on the working directory
		}
		p := filepath.Join(d, name)
		if fi, err := os.Stat(p); err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0 {
			return p, nil
		}
	}
	return "", fmt.Errorf("%s: not found in %s", name, dirs)
}

// limitedWriter keeps the first max bytes and drops the rest (a chatty failure must not grow
// without bound in memory).
type limitedWriter struct {
	buf *bytes.Buffer
	max int
}

func (w *limitedWriter) Write(p []byte) (int, error) {
	if room := w.max - w.buf.Len(); room > 0 {
		w.buf.Write(p[:min(room, len(p))])
	}
	return len(p), nil
}
