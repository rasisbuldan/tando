package watch

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"tando/srv/internal/atomicfile"
	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
)

// maxQueued bounds the queue of a notifier that keeps failing: the oldest are dropped (and
// counted in _nf.<name>.dropped).
const maxQueued = 100

// messages are the lines this run sends: events that are notices (flapping and a reboot always;
// a rollback, a liveness restart and a new error unless the app is silenced), then what
// reconcile decided. With include_log_lines=on a crash carries the app's last lines (they can
// hold secrets: off by default).
func (t *tick) messages() []string {
	var res []string
	for _, e := range t.events {
		switch e.kind {
		case "flap", "reboot", "monitor":
		case "rollback", "restart", "newerror":
			if t.silenced(e.app) {
				continue
			}
		default:
			continue
		}
		res = append(res, message{e.kind, e.app, e.check, e.detail, t.now}.line())
	}
	logs := t.cfg.str("include_log_lines") == "on"
	for _, m := range t.out {
		res = append(res, m.line())
		if m.kind != "firing" || !logs || (m.check != "down" && m.check != "restarts" && m.check != "oom") {
			continue
		}
		b, err := os.ReadFile(filepath.Join(t.w.Dir, "tail", m.app))
		if err != nil {
			continue
		}
		for _, l := range bashread.Lines(b) {
			f := bashread.Fields(l, 2)
			res = append(res, "log\t"+m.app+"\t"+m.check+"\t"+clean(f[1])+"\t"+f[0]+"\n")
		}
	}
	return res
}

// notifiers are the names of the configured notifiers ($SEC/notify-<name>), sorted.
func (w Watch) notifiers() []string {
	ents, err := os.ReadDir(w.Sec)
	if err != nil {
		return nil
	}
	var res []string
	for _, e := range ents {
		n, ok := strings.CutPrefix(e.Name(), "notify-")
		if ok && fsinfo.RegularFollow(filepath.Join(w.Sec, e.Name())) {
			res = append(res, n)
		}
	}
	sort.Strings(res)
	return res
}

func (w Watch) queueDir(name string) string { return filepath.Join(w.Dir, "out", name) }

// queued are the message files waiting for a notifier, oldest first (their names start with the
// time). A file still being written (.tmp) is not one.
func (w Watch) queued(name string) []string {
	ents, err := os.ReadDir(w.queueDir(name))
	if err != nil {
		return nil
	}
	var res []string
	for _, e := range ents {
		if n := e.Name(); !strings.HasPrefix(n, ".") && !strings.HasSuffix(n, ".tmp") {
			res = append(res, filepath.Join(w.queueDir(name), n))
		}
	}
	sort.Strings(res)
	return res
}

// enqueue writes one message file for a notifier and bounds its queue.
func (w Watch) enqueue(name, file string, data []byte, st *store) {
	d := w.queueDir(name)
	if err := os.MkdirAll(d, 0o700); err != nil {
		return
	}
	os.Chmod(d, 0o700)
	// created, never replaced: the name is unique to the commit, and a commit applied a second time
	// (recovered after a kill) finds its file there already. A temp file and a link give the
	// O_EXCL of the final name with a whole file behind it
	p := filepath.Join(d, file)
	if fsinfo.ExistsNoFollow(p) {
		return
	}
	tmp := filepath.Join(d, "."+file+".tmp")
	if atomicfile.Write(tmp, data, atomicfile.Mode(0o644)) != nil {
		return
	}
	err := os.Link(tmp, p)
	os.Remove(tmp)
	if err != nil {
		return
	}
	q := w.queued(name)
	if len(q) > maxQueued {
		drop := len(q) - maxQueued
		for _, f := range q[:drop] {
			os.Remove(f)
		}
		st.set("_nf."+name+".dropped", decimal.Itoa(st.n("_nf."+name+".dropped", 0)+int64(drop)))
	}
}

// sweepTemp removes queue temp files (".<name>.tmp") older than 10 minutes: a run killed between
// writing one and linking it in left it behind (a run takes at most TickTimeout).
func (w Watch) sweepTemp() {
	ents, err := os.ReadDir(filepath.Join(w.Dir, "out"))
	if err != nil {
		return
	}
	for _, e := range ents {
		d := filepath.Join(w.Dir, "out", e.Name())
		fs, _ := os.ReadDir(d)
		for _, f := range fs {
			if n := f.Name(); strings.HasPrefix(n, ".") && strings.HasSuffix(n, ".tmp") {
				if fi, err := f.Info(); err == nil && w.Env.Now().Sub(fi.ModTime()) > 10*time.Minute {
					os.Remove(filepath.Join(d, n))
				}
			}
		}
	}
}
