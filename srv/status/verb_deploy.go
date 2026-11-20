package status

import (
	"bytes"
	"context"
	"io"
	"path/filepath"
	"strings"
	"time"

	"tando/srv/internal/bashread"
	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
	"tando/srv/internal/lock"
	"tando/srv/internal/run"
	"tando/srv/internal/valid"
)

// recoverTimeout bounds `tando-agent recover`, which may restart the app, verify it through
// Caddy and wait out its soak.
const recoverTimeout = 15 * time.Minute

// maxActLog bounds what is read of activation.log (the last 60 journal lines of a failed
// activation, or podman's stderr).
const maxActLog = 4 << 20

// maxHistory bounds the read of history.tsv when deploy-status looks up a release's result.
const maxHistory = 64 << 20

// DeployStatus is the verb `deploy-status <app> <id>`: how the activation of release id goes,
// polled by the client during a deploy. As root, an activation whose unit died without finishing
// (killed, out of memory) is recovered first, by `tando-agent recover <app>` (FAULT-REVIEW F1).
func (c *Collector) DeployStatus(ctx context.Context, w io.Writer, name, id string) error {
	ctx = ctxOr(ctx)
	a, err := c.selectApp(name)
	if err != nil {
		return err
	}
	if !valid.ID(id) {
		return die("bad id")
	}
	H := c.hostConf()
	actFile := filepath.Join(a.dir, "activation")
	P := loadKV(actFile)
	if P.get("id") == id && P.get("result") == "running" && c.Env.EUID == 0 && !c.activationAlive(ctx, name, id) {
		c.recover(ctx, name)
		a.state = loadKV(filepath.Join(a.dir, "state"))
		P = loadKV(actFile)
	}
	// reserved but its activation unit is gone (activate cut off, the unit killed or the server
	// restarted while it was queued): recover gives it up, so it is not "queued" for ever
	if P.get("id") != id && a.state.get("status_"+id) == "" && c.Env.EUID == 0 &&
		fsinfo.DirFollow(filepath.Join(a.dir, "releases", id)) && !c.activationAlive(ctx, name, id) {
		c.recover(ctx, name)
		a.state = loadKV(filepath.Join(a.dir, "state"))
		P = loadKV(actFile)
	}
	S := a.state
	s := newSink()
	lnk := link(name, a.conf, H)
	if P.get("id") != id { // a later rollback or deploy overwrote it: history has the end
		if h := lastResult(filepath.Join(a.dir, "history.tsv"), id); h != "" {
			s.kv("phase", "done")
			s.kv("result", strings.Replace(h, "ok", "verified", 1))
			s.kv("link", lnk)
			return s.to(w)
		}
	}
	switch {
	case P.get("id") == id:
		for _, k := range bashOrder(P.order) {
			s.kv(k, P.get(k)) // (the keys are the file's: cleaned too)
		}
		s.kv("link", lnk)
		if r := P.get("result"); r == "failed" || r == "rolledback" {
			for _, l := range actLog(filepath.Join(a.dir, "activation.log")) {
				s.kv("log", l)
			}
		}
	case fsinfo.DirFollow(filepath.Join(a.dir, "releases", id)) && S.get("status_"+id) == "":
		s.kv("phase", "queued")
		s.kv("result", "running")
		// what it waits for (read from state and progress, no lock: a deploy key reads this too)
		if S.or("phase", "idle") != "idle" && S.get("target") != id {
			wph := waitPhase(S, P)
			s.kv("waiting_for", S.get("target"))
			s.kv("waiting_phase", wph)
			if wph == "soak" && decimal.IsDigits(P.get("soak_end")) {
				s.kv("waiting_left", decimal.Itoa(left(P.get("soak_end"), c.now())))
			}
		}
	default:
		s.kv("phase", "done")
		s.kv("result", S.or("status_"+id, "unknown"))
	}
	return s.to(w)
}

// waitPhase: the phase of the activation that holds the app: the state's, or the finer one of
// its progress file (soak is a part of verify), and rollback for a rollback.
func waitPhase(S, P kv) string {
	ph := S.get("phase")
	if P.get("id") == S.get("target") && P.get("phase") != "" {
		ph = P.get("phase")
	}
	if S.get("kind") == "rollback" {
		ph = "rollback"
	}
	return ph
}

// left is $(( end > now ? end - now : 0 )).
func left(end string, now int64) int64 {
	e := int64(uatoi(strings.TrimLeft(end, "0")))
	if len(strings.TrimLeft(end, "0")) > 18 {
		e = 1 << 62
	}
	if e > now {
		return e - now
	}
	return 0
}

// activationAlive: the activation unit tando-<app>-act-<id> is active, activating or
// deactivating. A populated cgroup means a process of it still runs, so systemd is not asked on
// every poll of a running deploy; otherwise its ActiveState decides (the shell's `systemctl show
// -P ActiveState`; "" when systemd cannot be asked, which recovers, as the shell's empty answer did).
func (c *Collector) activationAlive(ctx context.Context, name, id string) bool {
	unit := "tando-" + name + "-act-" + id + ".service"
	if b, err := readBounded(filepath.Join(c.Env.Cgroup, "system.slice", unit, "cgroup.events"), 4096, false); err == nil {
		for _, l := range bashread.Lines(b) {
			if l == "populated 1" {
				return true
			}
		}
	}
	switch c.activeState(ctx, unit) {
	case "active", "activating", "deactivating":
		return true
	}
	return false
}

// recover runs the agent's recover for the app (it takes the app's lock itself, and does
// nothing while another verb holds it). Its messages reach the client, as the inline call's did.
func (c *Collector) recover(ctx context.Context, name string) {
	c.Env.Run.Output(ctx, run.Cmd{Argv: []string{c.bin("tando-agent"), "recover", name}, Env: c.AgentEnv,
		Stdout: io.Discard, Stderr: c.stderr(), Timeout: recoverTimeout})
}

// lastResult is `awk -F '\t' -v id="$2" '$2 == id { r = $4 } END { print r }' history.tsv`.
func lastResult(path, id string) string {
	b, _ := readBounded(path, maxHistory, false)
	r := ""
	for len(b) > 0 {
		var l []byte
		if i := bytes.IndexByte(b, '\n'); i >= 0 {
			l, b = b[:i], b[i+1:]
		} else {
			l, b = b, nil // (awk reads an unterminated last line too)
		}
		f := bytes.SplitN(l, []byte{'\t'}, 5)
		if len(f) >= 2 && string(f[1]) == id {
			r = ""
			if len(f) >= 4 {
				r = string(f[3])
			}
		}
	}
	return r
}

// actLog: the lines of activation.log when it is not empty (`[[ -s f && -r f ]]`, then `while
// IFS= read -r l`: an unterminated last line is dropped, NUL bytes too). activation.log is
// root's 600, written by the agent from the journal; read without following a link anyway.
func actLog(path string) []string {
	b, err := readBounded(path, maxActLog, true)
	if err != nil || len(b) == 0 {
		return nil
	}
	if bytes.IndexByte(b, 0) >= 0 {
		b = bytes.ReplaceAll(b, []byte{0}, nil)
	}
	return bashread.Lines(b)
}

// lockHeld: another process holds the app's lock (busy_info's `flock -n "$D/lock" true`, without
// taking it: lock.Held reads /proc/locks, so this probe never delays or fails a verb's own try).
func lockHeld(p string) bool { return lock.Held(p) }
