package watch

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
	"tando/srv/internal/run"
)

// event is one transition or notice of a run: fire, resolve, flap, reboot, rollback, restart,
// newerror. app is as displayed ("host"), detail cleaned.
type event struct{ kind, app, check, detail string }

// event records a transition. The history line and the incident are written once the run has
// committed (commit.go); the crash tail is read now, because a notification of this run may
// carry it.
func (t *tick) event(kind, a, c, d string) {
	e := event{kind: kind, app: display(a), check: c, detail: clean(d)}
	t.events = append(t.events, e)
	if e.app != "host" && incidentCheck(c) && ((kind == "fire" && (c == "down" || c == "restarts" || c == "oom")) || kind == "restart") {
		t.w.crashTail(t.ctx, e.app)
	}
}

// incidentCheck: availability checks are incidents in tando health (and liveness restarts).
func incidentCheck(c string) bool {
	switch c {
	case "down", "health", "oom", "restarts", "http", "slow", "errors":
		return true
	}
	return false
}

// appendLine appends one line with one write(2), creating the file root 600.
func appendLine(path, line string) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o600)
	if err != nil {
		return err
	}
	_, err = f.WriteString(line)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// recordEvents writes the history lines and the per-app incidents of committed events.
func (w Watch) recordEvents(now int64, evs []event) {
	if len(evs) == 0 {
		return
	}
	var b strings.Builder
	for _, e := range evs {
		fmt.Fprintf(&b, "%d\t%s\t%s\t%s\t%s\n", now, e.kind, e.app, e.check, e.detail)
	}
	appendLine(w.historyPath(), b.String())
	for _, e := range evs {
		if e.app != "host" {
			w.incident(now, e)
		}
	}
	w.trimHistory()
}

// incident keeps the app's incidents for tando health: $V/incidents/<app>.tsv, "start end check
// cause" with end "-" while it lasts, at most 200 lines (cut back from 250). Availability checks
// only, and liveness restarts (which have no end).
func (w Watch) incident(now int64, e event) {
	if !incidentCheck(e.check) || (e.kind != "fire" && e.kind != "resolve" && e.kind != "restart") {
		return
	}
	dir := filepath.Join(w.Dir, "incidents")
	os.Mkdir(dir, 0o700)
	f := filepath.Join(dir, e.app+".tsv")
	switch e.kind {
	case "fire":
		appendLine(f, fmt.Sprintf("%d\t-\t%s\t%s\n", now, e.check, e.detail))
	case "restart":
		appendLine(f, fmt.Sprintf("%d\t%d\trestart\t%s\n", now, now, e.detail))
	case "resolve":
		b, err := os.ReadFile(f)
		if err != nil {
			return
		}
		ls := strings.Split(strings.TrimSuffix(string(b), "\n"), "\n")
		last := -1
		for i, l := range ls {
			if p := strings.Split(l, "\t"); len(p) > 2 && p[2] == e.check && p[1] == "-" {
				last = i
			}
		}
		if last < 0 {
			return
		}
		p := strings.Split(ls[last], "\t")
		for len(p) < 4 {
			p = append(p, "")
		}
		ls[last] = strings.Join([]string{p[0], decimal.Itoa(now), p[2], p[3]}, "\t")
		atomicfile.Write(f, []byte(strings.Join(ls, "\n")+"\n"), atomicfile.Mode(0o600))
	}
	trimLines(f, 250, 200)
}

// trimLines keeps the last keep lines of a file once it has more than over.
func trimLines(path string, over, keep int) {
	b, err := os.ReadFile(path)
	if err != nil || bytes.Count(b, []byte("\n")) <= over {
		return
	}
	ls := bytes.SplitAfter(b, []byte("\n"))
	if len(ls[len(ls)-1]) == 0 {
		ls = ls[:len(ls)-1]
	}
	atomicfile.Write(path, bytes.Join(ls[len(ls)-keep:], nil), atomicfile.Mode(0o600))
}

// trimHistory keeps the last 1000 lines of the history once it has more than 2000.
func (w Watch) trimHistory() { trimLines(w.historyPath(), 2000, 1000) }

// crashTail keeps the last 10 lines the app wrote when it crashed or was restarted:
// $V/tail/<app> (root 600), "time line", control characters as "?", 200 bytes a line. Shown by
// tando health; sent to notifiers only with include_log_lines=on (log lines can hold secrets).
func (w Watch) crashTail(ctx context.Context, a string) {
	dir := filepath.Join(w.Dir, "tail")
	os.Mkdir(dir, 0o700)
	out, _ := w.Env.Run.Output(ctx, run.Cmd{
		Argv: []string{"journalctl", "--no-pager", "-q", "-o", "short-unix", "--namespace=tando-" + a,
			"-u", "tando-" + a + ".service", "-n", "10"},
		Env: cmdEnv, Timeout: 10 * time.Second,
	})
	var b strings.Builder
	for _, l := range bashread.Lines(out) {
		ts, _, _ := strings.Cut(l, " ")
		ts, _, _ = strings.Cut(ts, ".")
		m := l
		if i := strings.Index(l, "]: "); i >= 0 {
			m = l[i+3:]
		}
		mb := []byte(m) // bytes, as awk under LC_ALL=C
		for i, c := range mb {
			if (c > 0 && c < 0x20) || c == 0x7f {
				mb[i] = '?'
			}
		}
		m = string(mb)
		if len(m) > 200 {
			m = m[:199] + "~"
		}
		fmt.Fprintf(&b, "%d\t%s\n", num(ts, 0), m)
	}
	atomicfile.Write(filepath.Join(dir, a), []byte(b.String()), atomicfile.Mode(0o600))
}
