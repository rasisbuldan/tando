package logs

import (
	"context"
	"errors"
	"io"
	"regexp"
	"strings"
	"time"

	"tando/srv/internal/run"
	"tando/srv/logs/lines"
)

// errStop closes the pipe of a command whose reader has read enough.
var errStop = errors.New("enough read")

// stream runs argv and hands its output to fn line by line (lines over max bytes cut). When fn
// returns false the pipe is closed and the command ends on its next write, as a shell pipeline
// into `awk '... exit'` did. The command's own failure is returned only when it was read to the
// end; stopping it early is not one.
func (l *Logs) stream(ctx context.Context, argv []string, timeout time.Duration, max int, fn func(lines.Line) bool) error {
	pr, pw := io.Pipe()
	done := make(chan error, 1)
	go func() {
		_, err := l.Env.Run.Output(ctx, run.Cmd{Argv: argv, Stdout: pw, Timeout: timeout})
		pw.Close()
		done <- err
	}()
	r := lines.NewReader(pr, max)
	stopped := false
	for {
		ln, ok := r.Next()
		if !ok {
			break
		}
		if !fn(ln) {
			stopped = true
			break
		}
	}
	pr.CloseWithError(errStop)
	err := <-done
	if stopped {
		return nil
	}
	return err
}

// forever is the timeout of a command that follows a log until the client goes away.
const forever = 100 * 365 * 24 * time.Hour

// reBareExit: a command that failed without a word, "journalctl: exit status 1". journalctl -g
// exits 1 when nothing matched; the shell version said nothing then.
var reBareExit = regexp.MustCompile(`^[^:]+: exit status [0-9]+$`)

// commandFailed passes on a command's failure that says something (its stderr, a timeout), the
// way the shell let journalctl's stderr through; its first line only.
func (l *Logs) commandFailed(err error) {
	if err == nil {
		return
	}
	s := err.Error()
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if !reBareExit.MatchString(s) {
		l.warn("tando-logs: %s", s)
	}
}
