package watch

import (
	"context"
	"os"
	"path/filepath"
	"time"

	"tando/srv/internal/apps"
	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/run"
)

// Before the checks of a tick (the shell's ExecStartPre lines of tando-watch.service): the
// metrics sample, then `tando-agent recover-all` for apps whose activation died or that systemd
// gave up on. recover-all is a bash program that forks for every app; it now runs only when one
// app needs it (what it would do is read here from the same files), which is almost never.

// pretick runs the sample and the recovery; neither failure stops the checks.
func (w Watch) pretick(ctx context.Context) {
	if w.Sample != nil {
		w.Sample(ctx)
	}
	if w.recoverNeeded() {
		w.agentOutside(ctx, "recover-all", "", "recover interrupted activations", 120*time.Second)
	}
}

// ExecSample is the one-shot's metrics sample: `tando-metrics sample`, when installed.
func (w Watch) ExecSample(ctx context.Context) {
	if b := w.bin("tando-metrics"); isExec(b) {
		w.Env.Run.Output(ctx, run.Cmd{Argv: []string{b, "sample"}, Env: cmdEnv, Timeout: 60 * time.Second})
	}
}

// recoverNeeded: an app has something for the agent's recover (see its recover()): an activation
// in a phase other than idle whose lock nobody holds (it died), a current link that disagrees
// with the state, or an app systemd gave up on (down) that is not stopped.
func (w Watch) recoverNeeded() bool {
	names, _ := apps.Names(w.Env.Root)
	for _, a := range names {
		s, _ := w.Cache.load(filepath.Join(w.appDir(a), "state"))
		d := w.appDir(a)
		if ph := or(s["phase"], "idle"); ph != "idle" {
			if !lockHeld(filepath.Join(d, "lock")) {
				return true
			}
			continue
		}
		cur, link := s["current"], ""
		if l, err := os.Readlink(filepath.Join(d, "current")); err == nil {
			link = filepath.Base(l)
		}
		switch {
		case cur != "" && link != cur && fsinfo.DirFollow(filepath.Join(d, "releases", cur)):
			return true
		case cur == "" && link != "" && fsinfo.DirFollow(filepath.Join(d, "releases", link)):
			return true
		case s["down"] != "" && s["stopped"] == "" && cur != "" && !w.isStatic(a):
			return true
		}
	}
	return false
}

// agentOutside runs `tando-agent <verb> [app]` in a transient unit of its own and waits for it:
// the agent rewrites Caddy's config, links and units, which the sandbox of tando-watch's units
// and tandod keeps read-only. It reports whether the agent succeeded.
func (w Watch) agentOutside(ctx context.Context, verb, app, why string, timeout time.Duration) bool {
	unit := "tando-watch-" + verb
	if app != "" {
		unit += "-" + app
	}
	argv := []string{"systemd-run", "--quiet", "--wait", "--collect", "--unit=" + unit + "-" + decimal.Itoa(w.now()),
		"-p", "Description=tando-watch: " + why, w.bin("tando-agent"), verb}
	if app != "" {
		argv = append(argv, app)
	}
	_, err := w.Env.Run.Output(ctx, run.Cmd{Argv: argv, Env: cmdEnv, Timeout: timeout})
	return err == nil
}

// execScanner is the one-shot's log scan: `nice tando-logs watch-scan`, when installed.
type execScanner struct {
	bin string
	run run.Runner
}

func (s execScanner) WatchScan(ctx context.Context) ([]byte, error) {
	if !isExec(s.bin) {
		return nil, nil
	}
	return s.run.Output(ctx, run.Cmd{Argv: []string{"nice", s.bin, "watch-scan"}, Env: cmdEnv, Timeout: 60 * time.Second})
}

// LogScanner is the per-minute scan of the apps' own logs, as the rows `tando-logs watch-scan`
// prints (they are the contract between the two: see check_logscan.go). The one-shot starts the
// program; tandod calls srv/logs in-process.
type LogScanner interface {
	WatchScan(ctx context.Context) ([]byte, error)
}
