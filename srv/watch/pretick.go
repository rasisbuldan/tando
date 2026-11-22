package watch

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"time"

	"tando/srv/internal/apps"
	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/run"
	"tando/srv/internal/valid"
)

// Before the checks of a tick (the shell's ExecStartPre lines of tando-watch.service): the
// metrics sample, then `tando-agent recover-all` for apps whose activation died or that systemd
// gave up on. recover-all is a bash program that forks for every app; it now runs only when one
// app needs it (what it would do is read here from the same files), which is almost never.

// pretick runs the sample and the recovery; neither failure stops the checks.
func (w Watch) pretick(ctx context.Context) {
	if w.Sample != nil {
		w.Cost.Time("metrics sample", func() { w.Sample(ctx) })
	}
	end := w.Cost.Start("recover")
	defer end()
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

// recoverNeeded: an app has something for the agent's recover (see its recover()): an operation
// in a phase other than idle whose lock nobody holds (it died), a current link that disagrees
// with the state, an app systemd gave up on (down) that is not stopped, a release reserved by
// an activation that will never run, or an operation whose end was not written out.
func (w Watch) recoverNeeded() bool {
	if w.goneDirLeft() {
		return true
	}
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
		case s["down"] == "" && s["stopped"] == "" && cur != "" && w.wakeGone(a):
			// an idle app (idle_stop) whose wake socket failed (its start failed again and again,
			// systemd stopped triggering): recover-all starts the socket again, or Caddy answers 502
			return true
		case w.reservationOrphaned(d, a, s):
			return true
		case w.leaseOrphaned(d):
			return true
		case w.rollbackCut(d):
			// a rollback that died after it wrote its progress file and before its first state
			// write: the state is idle, nothing holds the lock, and the file says running for ever
			return true
		case s["outcome"] != "" && s["outcome"] != s["outcome_done"]:
			// an operation ended (its result committed) but what follows it was cut off: its
			// history line, its progress file, the job units, a refused release's directory
			return true
		}
	}
	return false
}

// goneDirLeft: a destroy renames the app's directory to .gone-<app>.<pid> and then removes it; a
// destroy cut off in between leaves it, and the agent's recover-all removes it (once the pid is
// gone, as it checks too). A destroy that still runs is left alone.
func (w Watch) goneDirLeft() bool {
	ents, _ := os.ReadDir(filepath.Join(w.Env.Root, "apps"))
	for _, e := range ents {
		n := e.Name()
		if !strings.HasPrefix(n, ".gone-") || !e.IsDir() {
			continue
		}
		pid := n[strings.LastIndexByte(n, '.')+1:]
		if _, err := os.Stat(filepath.Join(w.Env.Proc, pid)); err != nil {
			return true
		}
	}
	return false
}

// leaseOrphaned: an upload lease with no release id whose holder is gone (the agent's
// lease_orphaned): taken in an earlier boot, or the activate that holds it ("<pid> <start time>")
// no longer runs. The agent also checks that no upload writes into incoming/ before it clears it.
func (w Watch) leaseOrphaned(d string) bool {
	l, _ := w.Cache.load(filepath.Join(d, "upload"))
	if l["token"] == "" || l["id"] != "" {
		return false
	}
	if b := l["boot"]; b != "" {
		cur, _ := os.ReadFile(filepath.Join(w.Env.Proc, "sys/kernel/random/boot_id"))
		if c := strings.TrimSpace(string(cur)); c != "" && c != b {
			return true
		}
	}
	pid, start, ok := strings.Cut(l["holder"], " ")
	n, okp := valid.Uint(pid, 1, 1<<31)
	if _, oks := valid.Uint(start, 0, 1<<62); !ok || !okp || !oks {
		return false
	}
	return procStart(w.Env.Proc, int(n)) != start
}

// rollbackCut: the activation file says a rollback is running (cmd_rollback writes it with the
// app's lock held) and nobody holds the lock.
func (w Watch) rollbackCut(d string) bool {
	p, _ := w.Cache.load(filepath.Join(d, "activation"))
	return p["kind"] == "rollback" && p["result"] == "running" && !lockHeld(filepath.Join(d, "lock"))
}

// reservationOrphaned: a release directory with no status (activate reserves one before it
// starts the activation's unit) whose activation unit has no process: activate was cut off before
// it started the unit, or the unit ended before it began (killed, the server restarted while it
// was queued). The agent's recover gives it up (rec_reap).
func (w Watch) reservationOrphaned(d, app string, s map[string]string) bool {
	ents, err := os.ReadDir(filepath.Join(d, "releases"))
	if err != nil {
		return false
	}
	for _, e := range ents {
		id := e.Name()
		if !e.IsDir() || !valid.ID(id) || s["status_"+id] != "" || id == s["current"] {
			continue
		}
		ev := filepath.Join(w.Env.Cgroup, "system.slice", "tando-"+app+"-act-"+id+".service", "cgroup.events")
		if b, err := os.ReadFile(ev); err == nil && bytes.Contains(b, []byte("populated 1")) {
			continue
		}
		return true
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

// wakeGone: the app has idle_stop (not static, not a container) and its wake socket is not there
// (systemd removes the file when the socket stops or fails).
func (w Watch) wakeGone(a string) bool {
	c, _ := w.Cache.load(filepath.Join(w.appDir(a), "app.conf"))
	if is := c["idle_stop"]; is == "" || is == "off" || c["recipe"] == "static" || c["recipe"] == "container" {
		return false
	}
	_, err := os.Lstat(filepath.Join("/run/tando-wake", a+".sock"))
	return err != nil
}
