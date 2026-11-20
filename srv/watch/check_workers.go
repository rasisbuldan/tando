package watch

import (
	"path/filepath"
	"sort"
	"strings"

	"tando/srv/internal/decimal"
)

// Workers (worker.<name> in tando.conf): long-running processes beside the web one, one unit
// each, tando-<app>_worker-<name>.service, restarted by systemd for ever with a backoff (they never
// reach "failed"). One that keeps exiting must be seen: its unit's NRestarts, asked in the run's
// one `systemctl show` call, is compared with the last run's (state key <app>.worker.<name>.nr).
//
//	new automatic restarts in two runs in a row    fires, check "worker.<name>"; the detail names
//	                                               the worker, how many and how it last ended
//	no new restart and the worker runs             resolves
//	the app is stopped or deploying                not judged (a deploy restarts its workers)
//	no longer a worker of the live release         resolves ("no longer a worker"), state dropped
//
// One switch for all of an app's workers: worker=off, <app>.worker=off.

func workerUnit(app, n string) string { return "tando-" + app + "_worker-" + n + ".service" }

// workersOf: the workers of the app's live release (app.conf holds its settings).
func (w Watch) workersOf(a string) []string {
	conf, _ := w.Cache.load(filepath.Join(w.appDir(a), "app.conf"))
	var ws []string
	for k := range conf {
		if n, ok := strings.CutPrefix(k, "worker."); ok && jobNameRe.MatchString(n) {
			ws = append(ws, n)
		}
	}
	sort.Strings(ws)
	return ws
}

// checkWorkers: each worker of the app, by its restarts since the last run.
func checkWorkers(t *tick, a *appTick) {
	if !t.cfg.on("worker", a.name) {
		return
	}
	W := t.st
	for _, n := range t.workers[a.name] {
		u := t.units[workerUnit(a.name, n)]
		c := "worker." + n
		k := a.key(c)
		nr := u["NRestarts"]
		if !decimal.IsDigits(nr) {
			continue // systemd did not answer: nothing to judge
		}
		last, had := W.lookup(k + ".nr")
		if last != nr {
			W.set(k+".nr", nr)
		}
		if a.hold || a.stopped || !had || !decimal.IsDigits(last) {
			continue
		}
		if d := num(nr, 0) - num(last, 0); d > 0 {
			det := "worker " + n + " keeps exiting: " + decimal.Itoa(d) + " automatic restarts since the last check; last: " +
				jobEnd(u, or(a.conf["worker."+n+".memory"], a.conf["memory"])) + "; tando logs -a " + a.name + " --worker " + n
			t.sample(k, a.name, c, bad, det, 2)
		} else if u["ActiveState"] == "active" {
			t.sample(k, a.name, c, ok, "", 1)
		}
	}
}

// dropWorkers: the alerts of workers the live release no longer has (removed and deployed, or gone
// with a rollback). One that fires resolves, once; the rest of its state goes.
func dropWorkers(t *tick) {
	W := t.st
	for _, key := range W.keys() {
		a, rest, _ := strings.Cut(key, ".")
		wf, isW := strings.CutPrefix(rest, "worker.")
		if !isW || strings.HasPrefix(a, "_") {
			continue
		}
		n, field, _ := strings.Cut(wf, ".")
		if containsStr(t.workers[a], n) {
			continue
		}
		c := "worker." + n
		k := a + "." + c
		switch field {
		case "st":
			if W.get(key) == "firing" {
				t.resolved[k] = "no longer a worker of the live release"
				t.event("resolve", a, c, t.resolved[k])
			}
			if W.get(key) != "ok" {
				W.set(key, "ok")
			}
		case "ns", "nt", "fl", "flap":
		default:
			W.del(key)
		}
	}
}

func containsStr(l []string, s string) bool {
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}
