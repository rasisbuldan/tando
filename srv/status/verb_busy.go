package status

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"strings"

	"tando/srv/internal/decimal"
	"tando/srv/internal/fsinfo"
)

// Busy is the verb `busy <app>` (root): when something holds the app's lock (an activation, its
// soak, a rollback, a backup, an env change), what and for about how long:
//
//	busy=<release id or ->  busy_phase=<copy..verify, soak, rollback or other>
//	busy_left=<seconds of soak left or ->  busy_soak=<the soak>
//	busy_waiting=<1: some call waits for the lock now>  busy_by=<what holds it, in words>
//
// Nothing when the app is free. The client says it while it waits (lib/deploy.sh: busy_text).
// Stale wait markers (lock.wait.<pid> of a process that is gone) are removed, as the shell did.
func (c *Collector) Busy(ctx context.Context, w io.Writer, name string) error {
	if c.Env.EUID != 0 {
		return die("this needs root (sudo)")
	}
	a, err := c.selectApp(name)
	if err != nil {
		return err
	}
	if !lockHeld(filepath.Join(a.dir, "lock")) {
		return nil
	}
	S, C, H := a.state, a.conf, c.hostConf()
	bid, bph, bleft := "-", "other", "-"
	if S.or("phase", "idle") != "idle" {
		P := loadKV(filepath.Join(a.dir, "activation"))
		bid, bph = S.or("target", "-"), S.get("phase")
		if P.get("id") == bid && P.get("phase") != "" {
			bph = P.get("phase") // (soak is a part of verify)
		}
		if S.get("kind") == "rollback" {
			bph = "rollback"
		}
		if bph == "soak" && decimal.IsDigits(P.get("soak_end")) {
			bleft = decimal.Itoa(left(P.get("soak_end"), c.now()))
		}
	}
	s := newSink()
	s.kv("busy", bid)
	s.kv("busy_phase", bph)
	s.kv("busy_left", bleft)
	s.kv("busy_soak", C.or("soak", H.or("soak", soakDefault)))
	s.kv("busy_waiting", c.waiting(a.dir))
	s.kv("busy_by", lockHolder(a.dir))
	return s.to(w)
}

// waiting: "1" when a lock.wait.<pid> marker's process is alive; markers of dead ones are removed.
func (c *Collector) waiting(dir string) string {
	ents, _ := os.ReadDir(dir)
	w := "0"
	for _, e := range ents {
		n := e.Name()
		if !strings.HasPrefix(n, "lock.wait.") {
			continue
		}
		if !fsinfo.ExistsFollow(filepath.Join(dir, n)) {
			continue // ([[ -e $f ]]: a dangling link is left alone)
		}
		if fsinfo.DirFollow(filepath.Join(c.Env.Proc, n[strings.LastIndexByte(n, '.')+1:])) {
			w = "1"
		} else {
			os.Remove(filepath.Join(dir, n))
		}
	}
	return w
}

// lockHolder is lock_holder: the verb that holds the lock (lock.holder: "<verb> <pid>"), in words.
func lockHolder(dir string) string {
	b, _ := readBounded(filepath.Join(dir, "lock.holder"), 4096, false)
	v := firstWord(b)
	switch v {
	case "run-activation", "activate", "configure":
		return "a deploy"
	case "rollback":
		return "a rollback"
	case "backup-run":
		return "a backup"
	case "backup-restore":
		return "a restore"
	case "env-set", "env-unset":
		return "an env change"
	case "start", "stop", "restart":
		return "a " + v
	case "domain-add", "domain-rm":
		return "a domain change"
	case "destroy":
		return "destroy"
	case "recover", "recover-all", "deploy-status", "app-down":
		return "a recovery check"
	}
	if strings.HasPrefix(v, "adopt-") {
		return "an adopt step"
	}
	return "another operation"
}
